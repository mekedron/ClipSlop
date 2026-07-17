import Foundation

/// Drives the prompt-library assistant: owns the conversation, runs the agent
/// loop (send → tool calls → confirm/execute → repeat until plain text), and
/// exposes a UI transcript. Mutating tools pause the loop for a confirmation
/// card via a `CheckedContinuation`.
@MainActor
@Observable
final class PromptAssistantService {

    /// What the chat window renders, in order.
    enum ChatItem: Identifiable {
        case userText(id: UUID, text: String)
        case assistantText(id: UUID, text: String)
        case toolActivity(id: UUID, text: String)
        case proposal(ToolProposal)

        var id: UUID {
            switch self {
            case .userText(let id, _): id
            case .assistantText(let id, _): id
            case .toolActivity(let id, _): id
            case .proposal(let proposal): proposal.id
            }
        }
    }

    enum Phase: Equatable {
        case idle
        case thinking
        case awaitingConfirmation
    }

    // MARK: - Observable state

    private(set) var items: [ChatItem] = []
    private(set) var phase: Phase = .idle
    private(set) var errorMessage: String?
    /// Bound to the chat input field.
    var draft: String = ""

    /// Set by AppState after init (same pattern as PromptShortcutService).
    weak var appState: AppState?

    /// Provider chosen for this chat (nil = follow the app default). Only
    /// tool-calling-capable providers are offered.
    var selectedProviderID: UUID?

    /// All configured providers that can drive the assistant.
    var toolCallingProviders: [AIProviderConfig] {
        appState?.providerStore.providers.filter { $0.providerType.supportsToolCalling } ?? []
    }

    /// The provider the assistant will actually use: the explicit selection if
    /// it's still valid, otherwise the app default when it qualifies, otherwise
    /// the first tool-calling provider. `nil` means none can do tool calling.
    var activeProvider: AIProviderConfig? {
        let candidates = toolCallingProviders
        if let id = selectedProviderID, let match = candidates.first(where: { $0.id == id }) {
            return match
        }
        if let defaultProvider = appState?.providerStore.defaultProvider,
           candidates.contains(where: { $0.id == defaultProvider.id }) {
            return defaultProvider
        }
        return candidates.first
    }

    func selectProvider(_ id: UUID) {
        selectedProviderID = id
    }

    // MARK: - Loop internals (not observed)

    @ObservationIgnored private var history: [ChatTurn] = []
    @ObservationIgnored private var currentTask: Task<Void, Never>?
    @ObservationIgnored private var pendingConfirmation: CheckedContinuation<Bool, Never>?

    private let maxIterations = 15

    var isBusy: Bool { phase != .idle }

    // MARK: - Public API

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, phase == .idle else { return }

        errorMessage = nil
        draft = ""
        items.append(.userText(id: UUID(), text: trimmed))
        history.append(.user(trimmed))

        currentTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    /// Called by the Approve/Reject buttons on a proposal card.
    func resolveConfirmation(approved: Bool) {
        guard let continuation = pendingConfirmation else { return }
        pendingConfirmation = nil
        continuation.resume(returning: approved)
    }

    /// Cancels the in-flight run. Any pending confirmation is auto-rejected so
    /// the loop can unwind cleanly.
    func cancel() {
        if let continuation = pendingConfirmation {
            pendingConfirmation = nil
            continuation.resume(returning: false)
        }
        currentTask?.cancel()
    }

    /// Clears the conversation for a fresh chat.
    func reset() {
        cancel()
        currentTask = nil
        items = []
        history = []
        errorMessage = nil
        draft = ""
        phase = .idle
    }

    // MARK: - Agent loop

    private func runLoop() async {
        guard let appState else { phase = .idle; return }
        guard let provider = activeProvider,
              let service = ToolChatServiceFactory.service(for: provider.providerType)
        else {
            errorMessage = Loc.shared.t("assistant.error.no_provider")
            phase = .idle
            return
        }

        let executor = PromptLibraryToolExecutor(
            store: appState.promptStore,
            providerStore: appState.providerStore,
            shortcutService: appState.promptShortcutService
        )
        let systemPrompt = AssistantSystemPrompt.build(
            providerNames: appState.providerStore.providers.map(\.name)
        )

        for _ in 0..<maxIterations {
            if Task.isCancelled { phase = .idle; return }

            phase = .thinking
            let reply: AssistantReply
            do {
                reply = try await service.send(
                    messages: history,
                    systemPrompt: systemPrompt,
                    tools: PromptLibraryTools.all,
                    config: provider
                )
            } catch {
                if !Task.isCancelled {
                    errorMessage = errorText(error)
                }
                phase = .idle
                return
            }

            if Task.isCancelled { phase = .idle; return }

            let assistantText = reply.text.flatMap { $0.isEmpty ? nil : $0 }
            history.append(.assistant(text: reply.text, toolCalls: reply.toolCalls))
            if let assistantText {
                items.append(.assistantText(id: UUID(), text: assistantText))
            }

            // No tool calls → the assistant is done.
            guard !reply.toolCalls.isEmpty else {
                // A reply with neither text nor tool calls would otherwise leave
                // the window blank — surface it instead of silently stopping.
                if assistantText == nil {
                    errorMessage = Loc.shared.t("assistant.error.empty")
                }
                phase = .idle
                return
            }

            var results: [ToolResult] = []
            for call in reply.toolCalls {
                if Task.isCancelled { break }
                results.append(await execute(call, executor: executor))
            }

            if Task.isCancelled { phase = .idle; return }
            history.append(.toolResults(results))
        }

        // Fell out of the loop → hit the iteration cap mid-task.
        if !Task.isCancelled {
            items.append(.assistantText(
                id: UUID(),
                text: Loc.shared.t("assistant.error.max_steps")
            ))
        }
        phase = .idle
    }

    private func execute(_ call: ToolCallRequest, executor: PromptLibraryToolExecutor) async -> ToolResult {
        // Read-only tools run immediately with a small activity row.
        guard PromptLibraryTools.isMutating(call.name) else {
            do {
                let output = try executor.perform(call)
                items.append(.toolActivity(id: UUID(), text: executor.activityLabel(for: call)))
                return ToolResult(toolCallID: call.id, content: output)
            } catch {
                items.append(.toolActivity(id: UUID(), text: "⚠︎ " + errorText(error)))
                return ToolResult(toolCallID: call.id, content: errorText(error), isError: true)
            }
        }

        // Mutating tools: build the proposal, show a card, wait for the user.
        let proposal: ToolProposal
        do {
            proposal = try executor.makeProposal(for: call)
        } catch {
            items.append(.toolActivity(id: UUID(), text: "⚠︎ " + errorText(error)))
            return ToolResult(toolCallID: call.id, content: errorText(error), isError: true)
        }

        items.append(.proposal(proposal))
        phase = .awaitingConfirmation
        let approved = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            pendingConfirmation = continuation
        }
        updateProposalResolution(id: proposal.id, to: approved ? .approved : .rejected)

        guard approved else {
            return ToolResult(
                toolCallID: call.id,
                content: "User declined this change. Do not retry unless asked."
            )
        }

        do {
            let output = try executor.perform(call)
            return ToolResult(toolCallID: call.id, content: output)
        } catch {
            return ToolResult(toolCallID: call.id, content: errorText(error), isError: true)
        }
    }

    // MARK: - Helpers

    private func updateProposalResolution(id: UUID, to resolution: ProposalResolution) {
        for index in items.indices {
            if case .proposal(var proposal) = items[index], proposal.id == id {
                proposal.resolution = resolution
                items[index] = .proposal(proposal)
                return
            }
        }
    }

    private func errorText(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
