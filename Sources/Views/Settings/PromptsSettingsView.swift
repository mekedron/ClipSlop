import SwiftUI

struct PromptsSettingsView: View {
    let appState: AppState
    @State private var selectedNodeID: UUID?
    @State private var expandedFolders: Set<UUID> = []
    @State private var deleteTarget: PromptNode?
    @State private var showDeleteConfirmation = false
    @State private var showRestoreDefaults = false
    @State private var statusMessage: String?

    private var promptStore: PromptStore { appState.promptStore }

    var body: some View {
        HSplitView {
            // Tree outline
            VStack(spacing: 0) {
                List(selection: $selectedNodeID) {
                    promptTree(promptStore.prompts)
                }

                Divider()

                HStack(spacing: 6) {
                    Menu {
                        Button("New Prompt") {
                            addNode(type: .prompt, parentID: selectedFolderID)
                        }
                        Button("New Folder") {
                            addNode(type: .folder, parentID: selectedFolderID)
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()

                    Button {
                        if let id = selectedNodeID,
                           let node = findNode(id: id, in: promptStore.prompts) {
                            confirmDelete(node)
                        }
                    } label: {
                        Image(systemName: "minus")
                    }
                    .buttonStyle(.borderless)
                    .disabled(selectedNodeID == nil)

                    Spacer()

                    Button { importPrompts() } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderless)
                    .help("Import prompts")

                    Button { exportPrompts() } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderless)
                    .help("Export prompts")

                    Button { showRestoreDefaults = true } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Restore defaults")
                }
                .padding(8)
            }
            .frame(minWidth: 200, maxWidth: 250)

            // Editor
            if let node = findNode(id: selectedNodeID, in: promptStore.prompts) {
                PromptEditorView(
                    node: node,
                    appState: appState,
                    promptStore: promptStore
                )
                .id(node.id)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "text.bubble")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text("Select a prompt to edit")
                        .foregroundStyle(.secondary)
                    Text("Double-click a folder to expand it")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .alert("Delete \"\(deleteTarget?.name ?? "")\"?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) { deleteTarget = nil }
            Button("Delete", role: .destructive) {
                if let node = deleteTarget {
                    promptStore.removeNode(withID: node.id)
                    if selectedNodeID == node.id { selectedNodeID = nil }
                    deleteTarget = nil
                }
            }
        } message: {
            if let node = deleteTarget, node.isFolder {
                let count = countChildren(node)
                Text("This folder contains \(count) item\(count == 1 ? "" : "s"). Everything inside will be permanently deleted.")
            } else {
                Text("This prompt will be permanently deleted.")
            }
        }
        .sheet(isPresented: $showRestoreDefaults) {
            RestoreDefaultsSheet(promptStore: promptStore, isPresented: $showRestoreDefaults)
        }
    }

    // MARK: - Import / Export

    private func exportPrompts() {
        guard let data = promptStore.exportJSON() else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "clipslop-prompts.json"
        panel.allowedContentTypes = [.json]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? data.write(to: url)
        }
    }

    private func importPrompts() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.begin { response in
            guard response == .OK, let url = panel.url,
                  let data = try? Data(contentsOf: url)
            else { return }
            try? promptStore.importJSON(from: data)
        }
    }

    // MARK: - Tree

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
                        promptTreeRow(node)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) {
                                selectedNodeID = node.id
                                if expandedFolders.contains(node.id) {
                                    expandedFolders.remove(node.id)
                                } else {
                                    expandedFolders.insert(node.id)
                                }
                            }
                            .onTapGesture(count: 1) {
                                selectedNodeID = node.id
                            }
                            .contextMenu { contextMenu(for: node) }
                    }
                } else {
                    promptTreeRow(node)
                        .contextMenu { contextMenu(for: node) }
                }
            }
        )
    }

    private func promptTreeRow(_ node: PromptNode) -> some View {
        HStack(spacing: 8) {
            Text(node.mnemonicDisplay)
                .font(.system(.caption, design: .rounded, weight: .bold))
                .foregroundStyle(.white)
                .frame(minWidth: 22, minHeight: 22)
                .padding(.horizontal, node.mnemonicModifiers == nil ? 0 : 2)
                .background(node.isFolder ? Color.blue : Color.purple)
                .clipShape(RoundedRectangle(cornerRadius: 4))

            Text(node.name)
                .lineLimit(1)

            if node.isFolder {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func contextMenu(for node: PromptNode) -> some View {
        if node.isFolder {
            Button {
                addNode(type: .prompt, parentID: node.id)
            } label: {
                Label("New Prompt Here", systemImage: "plus.circle")
            }

            Button {
                addNode(type: .folder, parentID: node.id)
            } label: {
                Label("New Subfolder", systemImage: "folder.badge.plus")
            }

            Divider()
        }

        Button {
            promptStore.moveNode(id: node.id, direction: .up)
        } label: {
            Label("Move Up", systemImage: "arrow.up")
        }

        Button {
            promptStore.moveNode(id: node.id, direction: .down)
        } label: {
            Label("Move Down", systemImage: "arrow.down")
        }

        Divider()

        Button(role: .destructive) {
            confirmDelete(node)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    // MARK: - Actions

    /// Determine the folder to add into based on current selection
    private var selectedFolderID: UUID? {
        guard let id = selectedNodeID,
              let node = findNode(id: id, in: promptStore.prompts)
        else { return nil }
        return node.isFolder ? node.id : nil
    }

    private func addNode(type: PromptNode.NodeType, parentID: UUID?) {
        let node = PromptNode(
            name: type == .folder ? "New Folder" : "New Prompt",
            mnemonicKey: "?",
            nodeType: type,
            systemPrompt: type == .prompt ? "Enter your prompt here..." : nil,
            children: type == .folder ? [] : nil
        )
        promptStore.addNode(node, toFolderWithID: parentID)
        selectedNodeID = node.id
    }

    private func confirmDelete(_ node: PromptNode) {
        deleteTarget = node
        showDeleteConfirmation = true
    }

    private func countChildren(_ node: PromptNode) -> Int {
        guard let children = node.children else { return 0 }
        return children.count + children.reduce(0) { $0 + countChildren($1) }
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
    let appState: AppState
    let promptStore: PromptStore

    @State private var aiDescription = ""
    @State private var isGenerating = false

    var body: some View {
        Form {
            Section("General") {
                TextField("Name", text: $node.name)
                    .onChange(of: node.name) { autoSave() }

                TextField("Mnemonic Key", text: $node.mnemonicKey)
                    .onChange(of: node.mnemonicKey) { autoSave() }

                HStack(spacing: 12) {
                    Text("Modifiers")
                    Spacer()
                    modifierToggle("⇧", flag: .shift)
                    modifierToggle("⌃", flag: .control)
                    modifierToggle("⌥", flag: .option)
                    modifierToggle("⌘", flag: .command)
                }
                .onChange(of: node.mnemonicModifiers) { autoSave() }

                HStack {
                    Text("Type")
                    Spacer()
                    Label(
                        node.isFolder ? "Folder" : "Prompt",
                        systemImage: node.isFolder ? "folder" : "text.bubble"
                    )
                    .foregroundStyle(.secondary)
                }
            }

            if node.isPrompt {
                Section("System Prompt") {
                    TextEditor(text: Binding(
                        get: { node.systemPrompt ?? "" },
                        set: { node.systemPrompt = $0 }
                    ))
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 120)
                    .onChange(of: node.systemPrompt) { autoSave() }
                }

                Section("Generate with AI") {
                    TextEditor(text: $aiDescription)
                        .font(.system(.body))
                        .frame(height: 50)
                        .overlay(alignment: .topLeading) {
                            if aiDescription.isEmpty {
                                Text("Describe what this prompt should do...")
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 8)
                                    .padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                        }

                    HStack {
                        Button {
                            generatePrompt()
                        } label: {
                            HStack(spacing: 4) {
                                if isGenerating {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                                Text(isGenerating ? "Generating..." : "Generate Prompt")
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(aiDescription.isEmpty || isGenerating)

                        Text("Uses your default AI provider")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func modifierToggle(_ symbol: String, flag: MnemonicModifiers) -> some View {
        Toggle(symbol, isOn: Binding(
            get: { (node.mnemonicModifiers ?? []).contains(flag) },
            set: { isOn in
                var mods = node.mnemonicModifiers ?? []
                if isOn { mods.insert(flag) } else { mods.remove(flag) }
                node.mnemonicModifiers = mods.isEmpty ? nil : mods
            }
        ))
        .toggleStyle(.checkbox)
    }

    private func autoSave() {
        promptStore.updateNode(node)
    }

    private func generatePrompt() {
        guard let provider = appState.providerStore.defaultProvider else { return }

        isGenerating = true
        let service = AIServiceFactory.service(for: provider.providerType)
        let description = aiDescription

        Task {
            do {
                let result = try await service.process(
                    text: description,
                    systemPrompt: """
                    You are a prompt engineer. The user will describe what they want a text transformation prompt to do. \
                    Generate a system prompt that will be used to transform user text. \
                    The prompt should be clear, concise, and follow this pattern:
                    "You are a [role]. [Instruction]. Preserve the original [what to preserve]. Return only the [output]. \
                    Do not ask any questions or add any commentary."
                    Return ONLY the system prompt text, nothing else.
                    """,
                    config: provider
                )
                node.systemPrompt = result
                autoSave()
            } catch {
                node.systemPrompt = "Error: \(error.localizedDescription)"
            }
            isGenerating = false
        }
    }
}

// MARK: - Restore Defaults Sheet

struct RestoreDefaultsSheet: View {
    let promptStore: PromptStore
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: 28))
                .foregroundStyle(.orange)

            Text("Restore Default Prompts?")
                .font(.headline)

            Text("This will replace all your current prompts with the defaults below. This cannot be undone.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            // Preview
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    let flat = flattenDefaults()
                    ForEach(flat, id: \.id) { item in
                        HStack(spacing: 6) {
                            Text(String(repeating: "      ", count: item.indent))
                                .font(.caption2)

                            Text(item.node.mnemonicKey.uppercased())
                                .font(.system(.caption2, design: .rounded, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 16, height: 16)
                                .background(item.node.isFolder ? Color.blue : Color.purple)
                                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))

                            Text(item.node.name)
                                .font(.caption)

                            if item.node.isFolder {
                                Image(systemName: "folder")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(12)
            }
            .frame(maxHeight: 200)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            HStack {
                Button("Cancel") { isPresented = false }
                Spacer()
                Button("Restore Defaults") {
                    promptStore.restoreDefaults()
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }
        }
        .padding(24)
        .frame(width: 400)
    }

    private struct FlatItem: Identifiable {
        let id: UUID
        let node: PromptNode
        let indent: Int
    }

    private func flattenDefaults() -> [FlatItem] {
        guard let url = Bundle.module.url(forResource: "DefaultPrompts", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let nodes = try? JSONDecoder().decode([PromptNode].self, from: data)
        else { return [] }
        return flatten(nodes, indent: 0)
    }

    private func flatten(_ nodes: [PromptNode], indent: Int) -> [FlatItem] {
        var result: [FlatItem] = []
        for node in nodes {
            result.append(FlatItem(id: node.id, node: node, indent: indent))
            if let children = node.children {
                result.append(contentsOf: flatten(children, indent: indent + 1))
            }
        }
        return result
    }
}
