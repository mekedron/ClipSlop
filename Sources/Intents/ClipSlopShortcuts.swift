import AppIntents

/// App Shortcuts — Siri phrases, and the entries Spotlight promotes for the app.
///
/// Phrases are parameterised over `PromptEntity`, so the system expands them across
/// the user's actual prompts. Two constraints that fail *silently* if broken:
/// every phrase must contain the `\(.applicationName)` token, and the entity query
/// must implement `suggestedEntities()` (it does, via `EnumerableEntityQuery`).
///
/// Kept to two shortcuts deliberately: there is a per-app cap, and each
/// parameterised shortcut expands across every prompt in the library.
///
/// Order matters — when the user picks an indexed prompt in Spotlight, the system
/// offers intents accepting that entity type and prefers the ones declared here.
/// Listing the headless intent first makes "just run it" the default gesture.
struct ClipSlopShortcuts: AppShortcutsProvider {
    /// Only the two clipboard-driven intents get phrases. The text-input variants
    /// are fully available in Spotlight and Shortcuts, but a phrase for them would
    /// have nothing sensible to say out loud — the text has to come from somewhere,
    /// and Siri prompting for a paragraph of input is not a real workflow.
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RunPromptOnClipboardIntent(),
            phrases: [
                "Run \(\.$prompt) with \(.applicationName)",
                "\(.applicationName) \(\.$prompt)",
            ],
            shortTitle: "Run Prompt on Clipboard",
            systemImageName: "sparkles"
        )
        AppShortcut(
            intent: OpenPromptInEditorFromClipboardIntent(),
            phrases: [
                "Open \(\.$prompt) in \(.applicationName)",
            ],
            shortTitle: "Open Prompt in Editor",
            systemImageName: "macwindow"
        )
    }
}
