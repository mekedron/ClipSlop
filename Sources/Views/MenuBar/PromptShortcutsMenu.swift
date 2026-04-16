import SwiftUI
import KeyboardShortcuts

struct PromptShortcutsMenu: View {
    let appState: AppState
    /// Forces SwiftUI to re-evaluate this view when shortcuts change.
    let version: Int
    private let loc = Loc.shared

    var body: some View {
        let items = appState.promptShortcutService.promptsWithShortcuts()
        if !items.isEmpty {
            Divider()
            Menu(loc.t("menu.prompt_shortcuts")) {
                ForEach(items, id: \.prompt.id) { item in
                    if let qp = item.quickPaste,
                       let keyEq = qp.swiftUIKeyEquivalent() {
                        Button {
                            appState.promptShortcutService.handleQuickPaste(promptID: item.prompt.id)
                        } label: {
                            Text("\(item.prompt.name) — Quick Paste")
                        }
                        .keyboardShortcut(keyEq, modifiers: qp.swiftUIModifiers())
                    }

                    if let or = item.openRun,
                       let keyEq = or.swiftUIKeyEquivalent() {
                        Button {
                            appState.promptShortcutService.handleOpenRun(promptID: item.prompt.id)
                        } label: {
                            Text("\(item.prompt.name) — Open & Run")
                        }
                        .keyboardShortcut(keyEq, modifiers: or.swiftUIModifiers())
                    }
                }
            }
        }
    }
}
