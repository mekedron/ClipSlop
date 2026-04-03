import SwiftUI

struct PromptsSettingsView: View {
    let appState: AppState
    @State private var selectedNodeID: UUID?
    @State private var editingNode: PromptNode?

    private var promptStore: PromptStore { appState.promptStore }

    var body: some View {
        HSplitView {
            // Tree outline
            VStack(spacing: 0) {
                List(selection: $selectedNodeID) {
                    OutlineGroup(promptStore.prompts, id: \.id, children: \.children) { node in
                        promptTreeRow(node)
                    }
                }

                Divider()

                HStack {
                    Menu {
                        Button("New Prompt") {
                            addNode(type: .prompt)
                        }
                        Button("New Folder") {
                            addNode(type: .folder)
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()

                    Button {
                        if let id = selectedNodeID {
                            promptStore.removeNode(withID: id)
                            selectedNodeID = nil
                            editingNode = nil
                        }
                    } label: {
                        Image(systemName: "minus")
                    }
                    .buttonStyle(.borderless)
                    .disabled(selectedNodeID == nil)

                    Spacer()
                }
                .padding(8)
            }
            .frame(minWidth: 200, maxWidth: 250)

            // Editor
            if let node = editingNode {
                PromptEditorView(
                    node: node,
                    onSave: { updated in
                        promptStore.updateNode(updated)
                        editingNode = updated
                    }
                )
            } else {
                VStack {
                    Text("Select a prompt to edit")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: selectedNodeID) {
            editingNode = findNode(id: selectedNodeID, in: promptStore.prompts)
        }
    }

    private func promptTreeRow(_ node: PromptNode) -> some View {
        HStack(spacing: 8) {
            Text(node.mnemonicKey.uppercased())
                .font(.system(.caption, design: .rounded, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(node.isFolder ? Color.blue : Color.purple)
                .clipShape(RoundedRectangle(cornerRadius: 4))

            Text(node.name)

            if node.isFolder {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
    }

    private func addNode(type: PromptNode.NodeType) {
        let node = PromptNode(
            name: type == .folder ? "New Folder" : "New Prompt",
            mnemonicKey: "?",
            nodeType: type,
            systemPrompt: type == .prompt ? "Enter your prompt here..." : nil,
            children: type == .folder ? [] : nil
        )
        promptStore.addNode(node, toFolderWithID: selectedNodeID)
        selectedNodeID = node.id
        editingNode = node
    }

    private func findNode(id: UUID?, in nodes: [PromptNode]) -> PromptNode? {
        guard let id else { return nil }
        for node in nodes {
            if node.id == id { return node }
            if let found = findNode(id: id, in: node.children ?? []) { return found }
        }
        return nil
    }
}

struct PromptEditorView: View {
    @State var node: PromptNode
    let onSave: (PromptNode) -> Void

    var body: some View {
        Form {
            Section("General") {
                TextField("Name", text: $node.name)

                HStack {
                    TextField("Mnemonic Key", text: $node.mnemonicKey)
                        .frame(width: 80)
                    Text("Single character that triggers this item")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Picker("Type", selection: $node.nodeType) {
                    Text("Prompt").tag(PromptNode.NodeType.prompt)
                    Text("Folder").tag(PromptNode.NodeType.folder)
                }
            }

            if node.isPrompt {
                Section("System Prompt") {
                    TextEditor(text: Binding(
                        get: { node.systemPrompt ?? "" },
                        set: { node.systemPrompt = $0 }
                    ))
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 150)
                }
            }

            Section {
                Button("Save") {
                    onSave(node)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .formStyle(.grouped)
    }
}
