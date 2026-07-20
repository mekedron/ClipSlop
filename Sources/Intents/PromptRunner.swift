import Foundation

/// Everything needed to run a prompt without touching the main actor. `Sendable`
/// so it can cross out of the `MainActor.run` hop and into the network call.
struct PromptRunPlan: Sendable {
    let promptID: UUID
    let promptName: String
    let systemPrompt: String
    let provider: AIProviderConfig
    let displayMode: EditorMode?
}

/// Headless prompt execution.
///
/// The app's existing paths (`AppState.applyPrompt`, `PromptShortcutService.runInline`)
/// are both UI-coupled — they own streaming, session history and pasteboard
/// side effects, and neither returns a value. Intents need the opposite: a plain
/// `String` in, a plain `String` out, no windows. This is that primitive.
enum PromptRunner {
    /// Reads the stores on the main actor and extracts a `Sendable` plan.
    @MainActor
    static func plan(
        promptID: UUID,
        promptStore: PromptStore,
        providerStore: ProviderStore
    ) throws -> PromptRunPlan {
        guard let node = promptStore.findNode(byID: promptID),
              node.isPrompt,
              let systemPrompt = node.systemPrompt
        else { throw ClipSlopIntentError.promptNotFound }

        guard let provider = providerStore.provider(preferring: node.providerID) else {
            throw ClipSlopIntentError.noProviderConfigured
        }

        return PromptRunPlan(
            promptID: node.id,
            promptName: node.name,
            systemPrompt: systemPrompt,
            provider: provider,
            displayMode: node.displayMode
        )
    }

    /// `nonisolated` on purpose — the AI call must not occupy the main actor.
    /// A `.cliTool` provider shells out and can take many seconds; parking that
    /// on `@MainActor` would freeze the popup and menu bar.
    ///
    /// Non-streaming: there is nothing to stream into from an intent.
    static func run(_ plan: PromptRunPlan, input: String) async throws -> String {
        let service = AIServiceFactory.service(for: plan.provider.providerType)
        let raw = try await service.process(
            text: input,
            systemPrompt: plan.systemPrompt,
            config: plan.provider
        )
        let result = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { throw AIServiceError.emptyResponse }
        return result
    }
}
