import SwiftUI
import KeyboardShortcuts

struct PromptShortcutsMenu: View {
    let appState: AppState
    /// Forces SwiftUI to re-evaluate this view when shortcuts change.
    let version: Int
    private let loc = Loc.shared

    var body: some View {
        let openRunEntries = collectEntries(kind: .openRun, from: appState.promptStore.prompts)
        let quickPasteEntries = collectEntries(kind: .quickPaste, from: appState.promptStore.prompts)

        if !openRunEntries.isEmpty || !quickPasteEntries.isEmpty {
            Divider()
            Menu(loc.t("menu.prompt_shortcuts")) {
                if !openRunEntries.isEmpty {
                    Menu(loc.t("menu.prompt_shortcuts.open_run")) {
                        ForEach(openRunEntries) { entry in
                            entryView(entry, kind: .openRun)
                        }
                    }
                }
                if !quickPasteEntries.isEmpty {
                    Menu(loc.t("menu.prompt_shortcuts.quick_paste")) {
                        ForEach(quickPasteEntries) { entry in
                            entryView(entry, kind: .quickPaste)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Model

    private enum ShortcutKind {
        case quickPaste
        case openRun
    }

    private func shortcutName(kind: ShortcutKind, for promptID: UUID) -> KeyboardShortcuts.Name {
        switch kind {
        case .quickPaste: return PromptShortcutService.quickPasteName(for: promptID)
        case .openRun:    return PromptShortcutService.openRunName(for: promptID)
        }
    }

    private struct ShortcutEntry: Identifiable {
        let id: String
        let content: Content

        enum Content {
            case prompt(PromptNode, KeyboardShortcuts.Shortcut)
            case folder(String, [ShortcutEntry])
        }
    }

    /// Walk the prompt tree and collect prompts (or folders containing prompts)
    /// that have the requested shortcut kind assigned. Preserves the folder
    /// hierarchy so the menu retains the user's grouping.
    private func collectEntries(kind: ShortcutKind, from nodes: [PromptNode]) -> [ShortcutEntry] {
        var result: [ShortcutEntry] = []
        for node in nodes {
            if node.isFolder {
                let children = collectEntries(kind: kind, from: node.children ?? [])
                if !children.isEmpty {
                    result.append(ShortcutEntry(
                        id: node.id.uuidString,
                        content: .folder(node.name, children)
                    ))
                }
            } else if node.isPrompt,
                      let shortcut = KeyboardShortcuts.getShortcut(for: shortcutName(kind: kind, for: node.id)) {
                result.append(ShortcutEntry(
                    id: node.id.uuidString,
                    content: .prompt(node, shortcut)
                ))
            }
        }
        return result
    }

    // MARK: - View builders (AnyView to break recursive type inference)

    private func entryView(_ entry: ShortcutEntry, kind: ShortcutKind) -> AnyView {
        switch entry.content {
        case .folder(let name, let children):
            return AnyView(
                Section(name) {
                    ForEach(children) { child in
                        entryView(child, kind: kind)
                    }
                }
            )
        case .prompt(let node, let shortcut):
            return AnyView(promptButton(node: node, shortcut: shortcut, kind: kind))
        }
    }

    @ViewBuilder
    private func promptButton(
        node: PromptNode,
        shortcut: KeyboardShortcuts.Shortcut,
        kind: ShortcutKind
    ) -> some View {
        if let keyEq = shortcut.swiftUIKeyEquivalent() {
            Button {
                switch kind {
                case .quickPaste:
                    appState.promptShortcutService.handleQuickPaste(promptID: node.id)
                case .openRun:
                    appState.promptShortcutService.handleOpenRun(promptID: node.id)
                }
            } label: {
                Text(node.name)
            }
            .keyboardShortcut(keyEq, modifiers: shortcut.swiftUIModifiers())
        }
    }
}
