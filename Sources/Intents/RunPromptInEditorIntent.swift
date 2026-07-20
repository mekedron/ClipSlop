import AppIntents
import AppKit
import Foundation

/// Opens the ClipSlop editor seeded from the clipboard and runs a prompt in it.
///
/// The counterpart to the headless intents: use this when the result is a starting
/// point to iterate on rather than a value to hand back.
struct OpenPromptInEditorFromClipboardIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Prompt in Editor from Clipboard"

    static let description = IntentDescription(
        "Opens the ClipSlop editor with your clipboard contents and runs the chosen prompt.",
        categoryName: "Prompts",
        searchKeywords: ["editor", "popup", "edit", "clipboard", "prompt", "clipslop"]
    )

    static let openAppWhenRun = true

    @Parameter(title: "Prompt")
    var prompt: PromptEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$prompt) in the ClipSlop editor with the clipboard")
    }

    /// `@MainActor` is correct here — unlike the headless intents this is pure UI
    /// work and awaits nothing long-running. The AI call it kicks off runs in a
    /// task owned by `applyPrompt`.
    @MainActor
    func perform() async throws -> some IntentResult {
        guard await AppStateBridge.waitUntilReady(), let appState = AppState.shared else {
            throw ClipSlopIntentError.appNotReady
        }
        try appState.runPromptInEditorFromIntent(promptID: prompt.id, text: nil)
        return .result()
    }
}

/// Opens the ClipSlop editor seeded from caller-supplied text and runs a prompt.
struct OpenPromptInEditorWithTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Prompt in Editor with Text"

    static let description = IntentDescription(
        "Opens the ClipSlop editor with the text you provide and runs the chosen prompt.",
        categoryName: "Prompts",
        searchKeywords: ["editor", "popup", "edit", "text", "prompt", "clipslop"]
    )

    static let openAppWhenRun = true

    @Parameter(title: "Prompt")
    var prompt: PromptEntity

    @Parameter(title: "Text", inputOptions: String.IntentInputOptions(multiline: true))
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$prompt) in the ClipSlop editor with \(\.$text)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard await AppStateBridge.waitUntilReady(), let appState = AppState.shared else {
            throw ClipSlopIntentError.appNotReady
        }
        try appState.runPromptInEditorFromIntent(promptID: prompt.id, text: text)
        return .result()
    }
}

extension AppState {
    /// App Intents entry point for the window-based flows.
    ///
    /// - Parameter text: explicit input, or `nil` to take the clipboard. Never the
    ///   current selection — see `RunPromptOnClipboardIntent` for why a synthetic
    ///   ⌘C cannot work when the invocation comes from Spotlight.
    func runPromptInEditorFromIntent(promptID: UUID, text: String?) throws {
        guard let node = promptStore.findNode(byID: promptID),
              node.isPrompt,
              let systemPrompt = node.systemPrompt
        else { throw ClipSlopIntentError.promptNotFound }

        guard providerStore.provider(preferring: node.providerID) != nil else {
            openSettingsToProviders()
            throw ClipSlopIntentError.noProviderConfigured
        }

        if let text {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ClipSlopIntentError.noInputText
            }
            startSessionForIntent(text: text)
            showPopup()
        } else {
            // Seeds the session from the clipboard and shows the popup. Surfaces
            // its own error UI when the clipboard is empty.
            triggerFromClipboard()
            guard currentSession != nil else { throw ClipSlopIntentError.noInputText }
        }

        // The popup is a non-activating panel, so it opens behind whatever invoked
        // it unless the app is explicitly activated. Focus is handed back on
        // dismissal by the existing yield in `dismissPopup()`.
        NSApplication.shared.activate()

        if let displayMode = node.displayMode {
            activeEditorMode = displayMode
        }
        applyPrompt(name: node.name, systemPrompt: systemPrompt, providerID: node.providerID)
    }
}
