import Foundation

/// The common shape of the assistant's tool executors: proposal for the
/// confirmation card, execution, and the read-only activity label.
@MainActor
protocol AssistantToolExecutor: AnyObject {
    func makeProposal(for call: ToolCallRequest) throws -> ToolProposal
    func perform(_ call: ToolCallRequest) throws -> String
    func activityLabel(for call: ToolCallRequest) -> String
}

extension PromptLibraryToolExecutor: AssistantToolExecutor {}
extension EngineToolExecutor: AssistantToolExecutor {}

/// Drives the Settings Assistant: owns the conversation, runs the agent
/// loop (send → tool calls → confirm/execute → repeat until plain text), and
/// exposes a UI transcript. Mutating tools pause the loop for a confirmation
/// card via a `CheckedContinuation`. Tool calls dispatch to two executors:
/// the prompt library (`PromptLibraryToolExecutor`) and the Magic Button
/// engine (`EngineToolExecutor`), unioned into one registry per request.
@MainActor
@Observable
final class SettingsAssistantService {

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

    /// The assistant dispatches through the `chat.assistant` engine role
    /// (§14) — same store the Magic settings edit, persisted in roles.yaml.
    private var roleStore: EngineRoleStore? { appState?.magicCoordinator.roleStore }

    /// Provider chosen for this chat (nil = follow the app default). Only
    /// tool-calling-capable providers are offered.
    var selectedProviderID: UUID? { roleStore?.mapping[.chatAssistant] }

    /// All configured providers that can drive the assistant.
    var toolCallingProviders: [AIProviderConfig] {
        appState?.providerStore.providers.filter { $0.providerType.supportsToolCalling } ?? []
    }

    /// The provider the assistant will actually use, via role resolution:
    /// the bound provider if still valid, else the app default when it
    /// qualifies, else the first tool-calling provider. `nil` means none
    /// can do tool calling.
    var activeProvider: AIProviderConfig? {
        guard let appState, let roleStore else { return nil }
        return roleStore.provider(for: .chatAssistant, in: appState.providerStore)
    }

    func selectProvider(_ id: UUID) {
        roleStore?.setProvider(id, for: .chatAssistant)
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
        let engineExecutor = EngineToolExecutor(
            stores: .init(
                workflowStore: appState.magicCoordinator.workflowStore,
                coreStore: appState.magicCoordinator.coreStore,
                configStore: appState.magicCoordinator.configStore,
                roleStore: appState.magicCoordinator.roleStore,
                providerStore: appState.providerStore
            )
        )
        let systemPrompt = AssistantSystemPrompt.build(
            providerNames: appState.providerStore.providers.map(\.name)
        )
        let tools = PromptLibraryTools.all + EngineTools.all

        for _ in 0..<maxIterations {
            if Task.isCancelled { phase = .idle; return }

            phase = .thinking
            let reply: AssistantReply
            do {
                reply = try await service.send(
                    messages: history,
                    systemPrompt: systemPrompt,
                    tools: tools,
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
                let target: any AssistantToolExecutor =
                    EngineTools.contains(call.name) ? engineExecutor : executor
                results.append(await execute(call, executor: target))
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

    private func execute(_ call: ToolCallRequest, executor: any AssistantToolExecutor) async -> ToolResult {
        let isMutating = EngineTools.contains(call.name)
            ? EngineTools.isMutating(call.name)
            : PromptLibraryTools.isMutating(call.name)
        // Read-only tools run immediately with a small activity row.
        guard isMutating else {
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
