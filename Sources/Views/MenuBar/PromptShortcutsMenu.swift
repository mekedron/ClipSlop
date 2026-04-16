import SwiftUI
import KeyboardShortcuts

struct PromptShortcutsMenu: View {
    let appState: AppState
    /// Forces SwiftUI to re-evaluate this view when shortcuts change.
    let version: Int
    private let loc = Loc.shared

    var body: some View {
        let topLevel = groupedShortcuts(from: appState.promptStore.prompts)
        if !topLevel.isEmpty {
            Divider()
            Menu(loc.t("menu.prompt_shortcuts")) {
                ForEach(topLevel) { entry in
                    entryView(entry)
                }
            }
        }
    }

    // MARK: - Grouped model

    private struct ShortcutEntry: Identifiable {
        let id: String
        let content: Content

        enum Content {
            case prompt(PromptNode, quickPaste: KeyboardShortcuts.Shortcut?, openRun: KeyboardShortcuts.Shortcut?)
            case folder(String, [ShortcutEntry])
        }
    }

    /// Walk the prompt tree and collect only nodes (or folders containing nodes)
    /// that have at least one shortcut assigned.
    private func groupedShortcuts(from nodes: [PromptNode]) -> [ShortcutEntry] {
        var result: [ShortcutEntry] = []
        for node in nodes {
            if node.isFolder {
                let children = groupedShortcuts(from: node.children ?? [])
                if !children.isEmpty {
                    result.append(ShortcutEntry(
                        id: node.id.uuidString,
                        content: .folder(node.name, children)
                    ))
                }
            } else if node.isPrompt {
                let qp = KeyboardShortcuts.getShortcut(
                    for: PromptShortcutService.quickPasteName(for: node.id))
                let or = KeyboardShortcuts.getShortcut(
                    for: PromptShortcutService.openRunName(for: node.id))
                if qp != nil || or != nil {
                    result.append(ShortcutEntry(
                        id: node.id.uuidString,
                        content: .prompt(node, quickPaste: qp, openRun: or)
                    ))
                }
            }
        }
        return result
    }

    // MARK: - View builders (AnyView to break recursive type inference)

    private func entryView(_ entry: ShortcutEntry) -> AnyView {
        switch entry.content {
        case .folder(let name, let children):
            return AnyView(
                Section(name) {
                    ForEach(children) { child in
                        entryView(child)
                    }
                }
            )
        case .prompt(let node, let qp, let or):
            return AnyView(promptButtons(node: node, quickPaste: qp, openRun: or))
        }
    }

    @ViewBuilder
    private func promptButtons(
        node: PromptNode,
        quickPaste: KeyboardShortcuts.Shortcut?,
        openRun: KeyboardShortcuts.Shortcut?
    ) -> some View {
        if let qp = quickPaste, let keyEq = qp.swiftUIKeyEquivalent() {
            Button {
                appState.promptShortcutService.handleQuickPaste(promptID: node.id)
            } label: {
                Text("\(node.name) — Quick Paste")
            }
            .keyboardShortcut(keyEq, modifiers: qp.swiftUIModifiers())
        }

        if let or = openRun, let keyEq = or.swiftUIKeyEquivalent() {
            Button {
                appState.promptShortcutService.handleOpenRun(promptID: node.id)
            } label: {
                Text("\(node.name) — Open & Run")
            }
            .keyboardShortcut(keyEq, modifiers: or.swiftUIModifiers())
        }
    }
}
