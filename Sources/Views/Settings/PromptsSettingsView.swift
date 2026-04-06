import SwiftUI

struct PromptsSettingsView: View {
    let appState: AppState
    @State private var selectedNodeID: UUID?
    @State private var expandedFolders: Set<UUID> = []
    @State private var deleteTarget: PromptNode?
    @State private var showDeleteConfirmation = false
    @State private var showRestoreDefaults = false
    @State private var statusMessage: String?

    private let loc = Loc.shared
    private var promptStore: PromptStore { appState.promptStore }

    var body: some View {
        HSplitView {
            // Tree outline
            VStack(spacing: 0) {
                List(selection: $selectedNodeID) {
                    promptTree(promptStore.prompts)
                }

                Divider()

                HStack(spacing: 0) {
                    Button {
                        addNode(type: .prompt, parentID: selectedFolderID)
                    } label: {
                        Image(systemName: "doc.badge.plus")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .frame(width: 32, height: 28)
                    .help(loc.t("settings.prompts.new_prompt"))

                    Button {
                        addNode(type: .folder, parentID: selectedFolderID)
                    } label: {
                        Image(systemName: "folder.badge.plus")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .frame(width: 32, height: 28)
                    .help(loc.t("settings.prompts.new_folder"))

                    Divider().frame(height: 16)

                    Button {
                        if let id = selectedNodeID,
                           let node = findNode(id: id, in: promptStore.prompts) {
                            confirmDelete(node)
                        }
                    } label: {
                        Image(systemName: "trash")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .frame(width: 32, height: 28)
                    .disabled(selectedNodeID == nil)

                    Divider().frame(height: 16)

                    Button {
                        if let id = selectedNodeID {
                            promptStore.moveNode(id: id, direction: .up)
                        }
                    } label: {
                        Image(systemName: "arrow.up")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .frame(width: 32, height: 28)
                    .disabled(selectedNodeID == nil)
                    .help(loc.t("settings.prompts.move_up"))

                    Button {
                        if let id = selectedNodeID {
                            promptStore.moveNode(id: id, direction: .down)
                        }
                    } label: {
                        Image(systemName: "arrow.down")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .frame(width: 32, height: 28)
                    .disabled(selectedNodeID == nil)
                    .help(loc.t("settings.prompts.move_down"))

                    Spacer()

                    Button { importPrompts() } label: {
                        Image(systemName: "square.and.arrow.down")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .frame(width: 32, height: 28)
                    .help(loc.t("settings.prompts.import"))

                    Button { exportPrompts() } label: {
                        Image(systemName: "square.and.arrow.up")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .frame(width: 32, height: 28)
                    .help(loc.t("settings.prompts.export"))

                    Button { showRestoreDefaults = true } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .frame(width: 32, height: 28)
                    .help(loc.t("settings.prompts.restore"))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .frame(minWidth: 250, maxWidth: 320)

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
                    Text(loc.t("settings.prompts.select"))
                        .foregroundStyle(.secondary)
                    Text(loc.t("settings.prompts.expand_hint"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .alert(loc.t("settings.prompts.delete_title", deleteTarget?.name ?? ""), isPresented: $showDeleteConfirmation) {
            Button(loc.t("settings.prompts.cancel"), role: .cancel) { deleteTarget = nil }
            Button(loc.t("settings.prompts.delete"), role: .destructive) {
                if let node = deleteTarget {
                    promptStore.removeNode(withID: node.id)
                    if selectedNodeID == node.id { selectedNodeID = nil }
                    deleteTarget = nil
                }
            }
        } message: {
            if let node = deleteTarget, node.isFolder {
                let count = countChildren(node)
                Text(loc.t("settings.prompts.delete_folder_message", count))
            } else {
                Text(loc.t("settings.prompts.delete_prompt_message"))
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
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { return }
                try? data.write(to: url)
            }
        } else {
            panel.begin { response in
                guard response == .OK, let url = panel.url else { return }
                try? data.write(to: url)
            }
        }
    }

    private func importPrompts() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url,
                      let data = try? Data(contentsOf: url)
                else { return }
                try? promptStore.importJSON(from: data)
            }
        } else {
            panel.begin { response in
                guard response == .OK, let url = panel.url,
                      let data = try? Data(contentsOf: url)
                else { return }
                try? promptStore.importJSON(from: data)
            }
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
                .padding(.horizontal, node.mnemonicModifiers == nil && !isSpecialKeyIdentifier(node.mnemonicKey) ? 0 : 2)
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
                Label(loc.t("settings.prompts.new_prompt_here"), systemImage: "plus.circle")
            }

            Button {
                addNode(type: .folder, parentID: node.id)
            } label: {
                Label(loc.t("settings.prompts.new_subfolder"), systemImage: "folder.badge.plus")
            }

            Divider()
        }

        Button {
            promptStore.moveNode(id: node.id, direction: .up)
        } label: {
            Label(loc.t("settings.prompts.move_up"), systemImage: "arrow.up")
        }

        Button {
            promptStore.moveNode(id: node.id, direction: .down)
        } label: {
            Label(loc.t("settings.prompts.move_down"), systemImage: "arrow.down")
        }

        moveToMenu(for: node)

        Divider()

        Button(role: .destructive) {
            confirmDelete(node)
        } label: {
            Label(loc.t("settings.prompts.delete"), systemImage: "trash")
        }
    }

    @ViewBuilder
    private func moveToMenu(for node: PromptNode) -> some View {
        let folders = promptStore.allFolders().filter { $0.id != node.id }

        Menu {
            // Move to root
            Button {
                promptStore.moveNode(id: node.id, toFolderID: nil)
            } label: {
                Label(loc.t("settings.prompts.root"), systemImage: "tray")
            }

            if !folders.isEmpty {
                Divider()
                ForEach(folders, id: \.id) { folder in
                    Button {
                        promptStore.moveNode(id: node.id, toFolderID: folder.id)
                    } label: {
                        let indent = String(repeating: "  ", count: folder.depth)
                        Label("\(indent)\(folder.name)", systemImage: "folder")
                    }
                }
            }
        } label: {
            Label(loc.t("settings.prompts.move_to"), systemImage: "folder.badge.plus")
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
            name: type == .folder ? loc.t("settings.prompts.new_folder") : loc.t("settings.prompts.new_prompt"),
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

    private let loc = Loc.shared

    var body: some View {
        Form {
            Section(loc.t("settings.prompts.editor.general")) {
                TextField(loc.t("settings.prompts.editor.name"), text: $node.name)
                    .onChange(of: node.name) { autoSave() }

                LabeledContent(loc.t("settings.prompts.editor.mnemonic")) {
                    MnemonicKeyCaptureView(mnemonicKey: $node.mnemonicKey) { autoSave() }
                        .frame(width: 120, height: 24)
                }

                HStack(spacing: 12) {
                    Text(loc.t("settings.prompts.editor.modifiers"))
                    Spacer()
                    modifierToggle("⇧", flag: .shift)
                    modifierToggle("⌃", flag: .control)
                    modifierToggle("⌥", flag: .option)
                    modifierToggle("⌘", flag: .command)
                }
                .onChange(of: node.mnemonicModifiers) { autoSave() }

                HStack {
                    Text(loc.t("settings.prompts.editor.type"))
                    Spacer()
                    Label(
                        node.isFolder ? loc.t("settings.prompts.editor.folder") : loc.t("settings.prompts.editor.prompt"),
                        systemImage: node.isFolder ? "folder" : "text.bubble"
                    )
                    .foregroundStyle(.secondary)
                }

                if node.isPrompt {
                    Picker(loc.t("settings.prompts.editor.provider"), selection: $node.providerID) {
                        Text(loc.t("settings.prompts.editor.provider_default"))
                            .tag(UUID?.none)
                        Divider()
                        ForEach(appState.providerStore.providers) { provider in
                            Text(provider.name).tag(UUID?.some(provider.id))
                        }
                    }
                    .onChange(of: node.providerID) { autoSave() }

                    Picker(loc.t("settings.prompts.editor.display_mode"), selection: $node.displayMode) {
                        Text(loc.t("settings.prompts.editor.display_mode_default"))
                            .tag(EditorMode?.none)
                        Divider()
                        Text("Plain text").tag(EditorMode?.some(.plainText))
                        Text("HTML").tag(EditorMode?.some(.html))
                        Text("Markdown").tag(EditorMode?.some(.markdown))
                    }
                    .onChange(of: node.displayMode) { autoSave() }
                }
            }

            if node.isPrompt {
                Section(loc.t("settings.prompts.editor.system_prompt")) {
                    TextEditor(text: Binding(
                        get: { node.systemPrompt ?? "" },
                        set: { node.systemPrompt = $0 }
                    ))
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 120)
                    .onChange(of: node.systemPrompt) { autoSave() }
                }

                Section(loc.t("settings.prompts.editor.generate_section")) {
                    TextEditor(text: $aiDescription)
                        .font(.system(.body))
                        .frame(height: 50)
                        .overlay(alignment: .topLeading) {
                            if aiDescription.isEmpty {
                                Text(loc.t("settings.prompts.editor.generate_placeholder"))
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
                                Text(isGenerating ? loc.t("settings.prompts.editor.generating") : loc.t("settings.prompts.editor.generate_button"))
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(aiDescription.isEmpty || isGenerating)

                        Text(loc.t("settings.prompts.editor.ai_hint"))
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
                    You are an expert prompt engineer for a text transformation tool called ClipSlop.

                    The user will describe what they want a prompt to do. Generate a system prompt that will instruct an AI to transform user text.

                    The generated prompt MUST follow this structure:
                    1. Role assignment: "You are a [specific role]."
                    2. Task description: One clear sentence about what to do.
                    3. Numbered rules (5-10 rules) covering:
                       - What exactly to do and how
                       - What to preserve (language, formatting, meaning, tone, content)
                       - What NOT to do (don't summarize, don't add opinions, don't change X)
                       - Edge cases (what if the input is already correct, empty, or ambiguous)
                       - Output format: "Return ONLY the [output type]."
                       - Final rule: "Do NOT add notes, explanations, or commentary."

                    Critical guidelines:
                    - Be SPECIFIC — vague prompts produce inconsistent results
                    - Always include "Preserve the original language" unless translation is the goal
                    - Always include a rule about preserving formatting (Markdown, HTML, line breaks)
                    - Always end with "Do NOT add notes, explanations, or commentary."
                    - The prompt should work for ANY text length (one word to many pages)

                    Return ONLY the system prompt text. No explanations, no wrapper, no quotes around it.
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

    private let loc = Loc.shared

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: 28))
                .foregroundStyle(.orange)

            Text(loc.t("settings.prompts.restore_title"))
                .font(.headline)

            Text(loc.t("settings.prompts.restore_message"))
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
                Button(loc.t("settings.prompts.cancel")) { isPresented = false }
                Spacer()
                Button(loc.t("settings.prompts.restore_button")) {
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
