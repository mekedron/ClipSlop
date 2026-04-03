import SwiftUI

struct SamplesView: View {
    let appState: AppState
    @State private var showRestoreConfirmation = false
    @State private var statusMessage: String?

    private var promptStore: PromptStore { appState.promptStore }

    var body: some View {
        Form {
            Section("Default Prompt Structure") {
                let flat = flattenTree(loadDefaultPrompts(), indent: 0)
                ForEach(flat) { item in
                    HStack(spacing: 8) {
                        Text(String(repeating: "      ", count: item.indent))
                            .font(.caption2)

                        Text(item.node.mnemonicKey.uppercased())
                            .font(.system(.caption2, design: .rounded, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 18, height: 18)
                            .background(item.node.isFolder ? Color.blue : Color.purple)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

                        Text(item.node.name)
                            .font(.subheadline)

                        if item.node.isFolder {
                            Image(systemName: "folder")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Actions") {
                Button("Restore Defaults...") {
                    showRestoreConfirmation = true
                }

                Button("Export Prompts...") { exportPrompts() }

                Button("Import Prompts...") { importPrompts() }

                if let msg = statusMessage {
                    Label(msg, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                }
            }
        }
        .formStyle(.grouped)
        .alert("Restore Defaults?", isPresented: $showRestoreConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Restore", role: .destructive) {
                promptStore.restoreDefaults()
                statusMessage = "Defaults restored!"
            }
        } message: {
            Text("This will replace all your current prompts with the default set. This cannot be undone.")
        }
    }

    private struct FlatTreeItem: Identifiable {
        let id: UUID
        let node: PromptNode
        let indent: Int
    }

    private func flattenTree(_ nodes: [PromptNode], indent: Int) -> [FlatTreeItem] {
        var result: [FlatTreeItem] = []
        for node in nodes {
            result.append(FlatTreeItem(id: node.id, node: node, indent: indent))
            if let children = node.children {
                result.append(contentsOf: flattenTree(children, indent: indent + 1))
            }
        }
        return result
    }

    private func loadDefaultPrompts() -> [PromptNode] {
        guard let url = Bundle.module.url(forResource: "DefaultPrompts", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let nodes = try? JSONDecoder().decode([PromptNode].self, from: data)
        else { return [] }
        return nodes
    }

    private func exportPrompts() {
        guard let data = promptStore.exportJSON() else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "clipslop-prompts.json"
        panel.allowedContentTypes = [.json]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? data.write(to: url)
            statusMessage = "Prompts exported!"
        }
    }

    private func importPrompts() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.begin { response in
            guard response == .OK, let url = panel.url,
                  let data = try? Data(contentsOf: url)
            else { return }
            do {
                try promptStore.importJSON(from: data)
                statusMessage = "Prompts imported!"
            } catch {
                statusMessage = "Import failed: \(error.localizedDescription)"
            }
        }
    }
}
