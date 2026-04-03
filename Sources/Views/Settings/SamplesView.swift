import SwiftUI

struct SamplesView: View {
    let appState: AppState
    @State private var showRestoreConfirmation = false
    @State private var showImportPicker = false
    @State private var showExportPicker = false
    @State private var statusMessage: String?

    private var promptStore: PromptStore { appState.promptStore }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Prompt Samples & Templates")
                        .font(.headline)
                    Text("View the default prompt structure, restore defaults, or import/export configurations.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()

            Divider()

            // Default prompt tree preview
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Default Prompt Structure")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal)

                    defaultTreePreview
                        .padding(.horizontal)

                    if let msg = statusMessage {
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(.green)
                            .padding(.horizontal)
                    }
                }
                .padding(.vertical)
            }

            Divider()

            // Action buttons
            HStack(spacing: 12) {
                Button("Restore Defaults") {
                    showRestoreConfirmation = true
                }

                Button("Export Prompts...") {
                    exportPrompts()
                }

                Button("Import Prompts...") {
                    importPrompts()
                }

                Spacer()
            }
            .padding()
        }
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

    private var defaultTreePreview: some View {
        VStack(alignment: .leading, spacing: 4) {
            let nodes = loadDefaultPrompts()
            let flat = flattenTree(nodes, indent: 0)
            ForEach(flat) { item in
                HStack(spacing: 6) {
                    Text(String(repeating: "  ", count: item.indent))
                    Text("[\(item.node.mnemonicKey)]")
                        .font(.system(.caption, design: .monospaced, weight: .bold))
                        .foregroundStyle(item.node.isFolder ? .blue : .purple)
                    Text(item.node.name)
                        .font(.caption)
                    if item.node.isFolder {
                        Image(systemName: "folder")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(12)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.quaternary)
        )
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
