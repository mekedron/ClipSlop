import SwiftUI

/// Settings over the Magic Button engine (§15: "files first"). The tab is an
/// editor over `~/.clipslop/` — the system prompt, the core memory files,
/// and every workflow — with reset-to-default wherever a shipped default
/// exists. Nothing here is a parallel store: every edit writes the file, and
/// the engine picks it up on the next press.
struct MagicSettingsView: View {
    let appState: AppState

    @State private var selectedID: String?
    @State private var editorText = ""
    @State private var loadedID: String?
    @State private var saveTask: Task<Void, Never>?

    private let loc = Loc.shared

    private var coordinator: MagicPressCoordinator { appState.magicCoordinator }

    var body: some View {
        VStack(spacing: 0) {
            // Role → provider binding (§14, generation.magic).
            HStack {
                Text(loc.t("settings.providers.magic_role"))
                    .font(.subheadline)
                Picker("", selection: magicProviderBinding) {
                    Text(loc.t("settings.providers.magic_role.default")).tag(UUID?.none)
                    ForEach(appState.providerStore.providers) { provider in
                        Text(provider.name).tag(UUID?.some(provider.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 260)
                Spacer()
                // Full-content debug logging: complete prompts, screen
                // content, and model output per press — unlike the always-on
                // contentless traces. Off by default.
                Toggle(loc.t("settings.magic.debug_log"), isOn: Bindable(appState.settings).magicDebugLogging)
                    .toggleStyle(.checkbox)
                    .help(loc.t("settings.magic.debug_log.help"))
                Button(loc.t("settings.magic.reveal_folder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([Constants.Engine.rootDirectory])
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            HSplitView {
                List(selection: $selectedID) {
                    Section(loc.t("settings.magic.section.system")) {
                        ForEach(items.filter { $0.section == .system }) { fileRow($0) }
                    }
                    Section(loc.t("settings.magic.section.engine")) {
                        ForEach(items.filter { $0.section == .engine }) { fileRow($0) }
                    }
                    Section(loc.t("settings.magic.section.core")) {
                        ForEach(items.filter { $0.section == .core }) { fileRow($0) }
                    }
                    Section(loc.t("settings.magic.section.workflows")) {
                        ForEach(items.filter { $0.section == .workflows }) { fileRow($0) }
                    }
                }
                .frame(minWidth: 200, maxWidth: 260)

                editorPane
            }
        }
        .onChange(of: selectedID) { flushPendingSave(); loadSelection() }
        .onDisappear { flushPendingSave() }
        .onAppear { if selectedID == nil { selectedID = items.first?.id } }
    }

    // MARK: - File inventory

    struct FileItem: Identifiable, Hashable {
        enum Section { case system, engine, core, workflows }
        let id: String
        let title: String
        let url: URL
        let defaultContent: String?
        let section: Section
    }

    private var items: [FileItem] {
        let seedByPath = Dictionary(uniqueKeysWithValues: EngineSeedContent.seeds)
        var result: [FileItem] = [
            FileItem(
                id: "system-prompt",
                title: loc.t("settings.magic.system_prompt"),
                url: CoreFileStore.systemPromptURL,
                defaultContent: PromptAssembler.systemPromptTemplate,
                section: .system
            ),
            FileItem(
                id: "config.yaml",
                title: "config.yaml",
                url: EngineConfigStore.fileURL,
                defaultContent: seedByPath["config.yaml"],
                section: .engine
            ),
        ]
        for name in ["identity.md", "writing-style.md", "constraints.md", "aliases.md"] {
            result.append(FileItem(
                id: "core/\(name)",
                title: name,
                url: Constants.Engine.coreDirectory.appendingPathComponent(name),
                defaultContent: seedByPath["core/\(name)"],
                section: .core
            ))
        }
        for url in WorkflowStore.markdownFiles(in: Constants.Engine.workflowsDirectory) {
            let relative = url.path.replacingOccurrences(
                of: Constants.Engine.rootDirectory.path + "/", with: ""
            )
            result.append(FileItem(
                id: relative,
                title: url.deletingPathExtension().lastPathComponent,
                url: url,
                defaultContent: seedByPath[relative],
                section: .workflows
            ))
        }
        return result
    }

    private func fileRow(_ item: FileItem) -> some View {
        HStack(spacing: 6) {
            Text(item.title)
                .lineLimit(1)
            Spacer()
            if !problems(for: item).isEmpty {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .font(.caption)
            }
        }
        .tag(item.id)
    }

    private func problems(for item: FileItem) -> [String] {
        if item.section == .engine {
            return coordinator.configStore.warnings
        }
        return coordinator.workflowStore.loadErrors
            .filter { $0.fileURL == item.url && !$0.isWarning }
            .map { error in
                error.line.map { "Line \($0): " + error.message } ?? error.message
            }
    }

    // MARK: - Editor

    private var selectedItem: FileItem? {
        items.first { $0.id == selectedID }
    }

    private var editorPane: some View {
        Group {
            if let item = selectedItem {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text(item.url.lastPathComponent)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(loc.t("settings.magic.reveal")) {
                            NSWorkspace.shared.activateFileViewerSelecting([item.url])
                        }
                        .controlSize(.small)
                        if item.defaultContent != nil {
                            Button(loc.t("settings.magic.reset")) {
                                resetToDefault(item)
                            }
                            .controlSize(.small)
                            .disabled(editorText == item.defaultContent)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)

                    Divider()

                    TextEditor(text: $editorText)
                        .font(.system(.body, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .onChange(of: editorText) { scheduleSave(for: item) }

                    ForEach(problems(for: item), id: \.self) { message in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.yellow)
                            Text(message)
                                .font(.caption)
                                .textSelection(.enabled)
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 6)
                    }
                }
            } else {
                Text(loc.t("settings.magic.select_file"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Load / save

    private func loadSelection() {
        guard let item = selectedItem else { return }
        let onDisk = try? String(contentsOf: item.url, encoding: .utf8)
        editorText = onDisk ?? item.defaultContent ?? ""
        loadedID = item.id
    }

    /// Debounced write-through: the file is the store (§15.1), so an edit is
    /// a save. Validation runs on reload and surfaces as the badge — the
    /// file is never blocked from saving.
    private func scheduleSave(for item: FileItem) {
        guard loadedID == item.id else { return }
        saveTask?.cancel()
        let text = editorText
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            write(text, to: item)
        }
    }

    private func flushPendingSave() {
        guard let task = saveTask else { return }
        task.cancel()
        saveTask = nil
        if let item = items.first(where: { $0.id == loadedID }) {
            write(editorText, to: item)
        }
    }

    private func write(_ text: String, to item: FileItem) {
        try? text.write(to: item.url, atomically: true, encoding: .utf8)
        coordinator.workflowStore.reloadIfChanged()
        coordinator.coreStore.reloadIfChanged()
        coordinator.configStore.reloadIfChanged()
    }

    private func resetToDefault(_ item: FileItem) {
        guard let defaultContent = item.defaultContent else { return }
        saveTask?.cancel()
        saveTask = nil
        editorText = defaultContent
        write(defaultContent, to: item)
    }

    private var magicProviderBinding: Binding<UUID?> {
        Binding(
            get: { coordinator.roleStore.mapping[.generationMagic] },
            set: { coordinator.roleStore.setProvider($0, for: .generationMagic) }
        )
    }
}
