import SwiftUI

struct QuickAccessSettingsView: View {
    let appState: AppState
    @State private var expandedFolders: Set<UUID> = []

    private let loc = Loc.shared
    private var promptStore: PromptStore { appState.promptStore }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List {
                    promptTree(promptStore.prompts)
                }

                Divider()

                Text(loc.t("settings.quick_access.left_pane_hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: 240, maxWidth: 320)

            QuickAccessGridConfigurator(appState: appState)
        }
    }

    private func promptTree(_ nodes: [PromptNode]) -> AnyView {
        AnyView(
            ForEach(nodes) { node in
                if node.isFolder {
                    DisclosureGroup(
                        isExpanded: Binding(
                            get: { expandedFolders.contains(node.id) },
                            set: { isExpanded in
                                if isExpanded {
                                    expandedFolders.insert(node.id)
                                } else {
                                    expandedFolders.remove(node.id)
                                }
                            }
                        )
                    ) {
                        if let children = node.children {
                            promptTree(children)
                        }
                    } label: {
                        promptRow(node)
                    }
                } else {
                    promptRow(node)
                        .onDrag {
                            NSItemProvider(object: PromptDragPayload.encode(promptID: node.id) as NSString)
                        }
                }
            }
        )
    }

    private func promptRow(_ node: PromptNode) -> some View {
        let inUse = node.isPrompt && isUsedInQuickAccess(node.id)

        return HStack(spacing: 8) {
            Text(node.mnemonicDisplay)
                .font(.system(.caption, design: .rounded, weight: .bold))
                .foregroundStyle(.white)
                .frame(minWidth: 22, minHeight: 22)
                .padding(.horizontal, 2)
                .background(node.isFolder ? Color.blue : Color.purple)
                .clipShape(RoundedRectangle(cornerRadius: 4))

            Text(node.name)
                .lineLimit(1)

            if node.isFolder {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            Spacer(minLength: 4)

            if inUse {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
                    .help(loc.t("settings.quick_access.tile.in_use_badge"))
            }
        }
        .opacity(inUse ? 0.6 : 1.0)
        .contentShape(Rectangle())
    }

    private func isUsedInQuickAccess(_ promptID: UUID) -> Bool {
        appState.quickAccessStore.tiles.contains { $0.promptID == promptID }
    }
}
