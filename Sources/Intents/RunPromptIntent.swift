import AppIntents
import Foundation

/// Shared body of the two headless intents.
///
/// They exist as separate actions rather than one action with an optional `text`
/// parameter so both show up ready-to-use in Spotlight: an optional parameter
/// reads as an empty field the user has to understand, whereas "on Clipboard" and
/// "on Text" say what they do.
enum PromptIntentExecutor {
    static func run(promptID: UUID, explicitText: String?, copyResult: Bool) async throws -> String {
        guard await AppStateBridge.waitUntilReady() else {
            throw ClipSlopIntentError.appNotReady
        }

        // One hop: the plan and the input are read as a single consistent snapshot
        // of the stores, rather than racing a library edit between two hops.
        let (plan, input) = try await MainActor.run { () -> (PromptRunPlan, String) in
            guard let appState = AppState.shared else { throw ClipSlopIntentError.appNotReady }
            let plan = try PromptRunner.plan(
                promptID: promptID,
                promptStore: appState.promptStore,
                providerStore: appState.providerStore
            )
            return (plan, explicitText ?? ClipboardService.getText() ?? "")
        }

        let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty else { throw ClipSlopIntentError.noInputText }

        let result: String
        do {
            result = try await PromptRunner.run(plan, input: trimmedInput)
        } catch is CancellationError {
            // Rethrow unchanged so App Intents treats it as a cancel, not a failure.
            throw CancellationError()
        } catch {
            throw ClipSlopIntentError.wrap(error)
        }

        if copyResult {
            await MainActor.run { ClipboardService.setText(result) }
        }
        return result
    }
}

/// Runs a prompt over the clipboard and returns the result — no window, no app switch.
///
/// Clipboard rather than current selection, deliberately: selection capture posts a
/// synthetic ⌘C into the frontmost app, and when the trigger comes from Spotlight,
/// *Spotlight* is frontmost — the keystroke would land in its search field. Reading
/// the pasteboard has no such dependency and needs no Accessibility permission.
struct RunPromptOnClipboardIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Prompt on Clipboard"

    static let description = IntentDescription(
        "Runs one of your ClipSlop prompts over the current clipboard contents and returns the result.",
        categoryName: "Prompts",
        searchKeywords: ["ai", "rewrite", "summarize", "translate", "clipboard", "prompt"]
    )

    /// Headless: foregrounding a menu-bar accessory app to run a prompt would be
    /// worse than useless.
    static let openAppWhenRun = false

    @Parameter(title: "Prompt")
    var prompt: PromptEntity

    @Parameter(title: "Copy Result to Clipboard", default: true)
    var copyResult: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Run \(\.$prompt) on the clipboard") {
            \.$copyResult
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let result = try await PromptIntentExecutor.run(
            promptID: prompt.id,
            explicitText: nil,
            copyResult: copyResult
        )
        return .result(
            value: result,
            dialog: IntentDialog(stringLiteral: IntentDialogFormatter.summarize(result))
        )
    }
}

/// Runs a prompt over text supplied by the caller. The Shortcuts-friendly variant:
/// chain it after any action that produces text.
struct RunPromptOnTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Prompt on Text"

    static let description = IntentDescription(
        "Runs one of your ClipSlop prompts over the text you provide and returns the result.",
        categoryName: "Prompts",
        searchKeywords: ["ai", "rewrite", "summarize", "translate", "text", "prompt"]
    )

    static let openAppWhenRun = false

    @Parameter(title: "Prompt")
    var prompt: PromptEntity

    @Parameter(title: "Text", inputOptions: String.IntentInputOptions(multiline: true))
    var text: String

    @Parameter(title: "Copy Result to Clipboard", default: false)
    var copyResult: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Run \(\.$prompt) on \(\.$text)") {
            \.$copyResult
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let result = try await PromptIntentExecutor.run(
            promptID: prompt.id,
            explicitText: text,
            copyResult: copyResult
        )
        return .result(
            value: result,
            dialog: IntentDialog(stringLiteral: IntentDialogFormatter.summarize(result))
        )
    }
}
