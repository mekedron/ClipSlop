import SwiftUI

struct ProvidersSettingsView: View {
    let appState: AppState
    @State private var selectedProviderID: UUID?
    @State private var showAddProvider = false
    @State private var showDuplicateSheet = false
    @State private var duplicateSourceID: UUID?
    @State private var justAddedChatGPTProviderID: UUID?

    private let loc = Loc.shared
    private var providerStore: ProviderStore { appState.providerStore }

    var body: some View {
        HSplitView {
            // Provider list
            VStack(spacing: 0) {
                List(providerStore.providers, selection: $selectedProviderID) { provider in
                    HStack(spacing: 8) {
                        ProviderIconView(providerType: provider.providerType, modelID: provider.modelID)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(provider.name)
                                .font(.subheadline).fontWeight(.medium)
                            Text(provider.modelID)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if provider.isDefault {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                        }
                    }
                    .contextMenu {
                        if !provider.isDefault {
                            Button {
                                providerStore.setDefault(id: provider.id)
                            } label: {
                                Label(loc.t("settings.providers.set_default"), systemImage: "checkmark.circle")
                            }
                        }

                        Button {
                            duplicateSourceID = provider.id
                            showDuplicateSheet = true
                        } label: {
                            Label(loc.t("settings.providers.duplicate"), systemImage: "doc.on.doc")
                        }

                        Divider()

                        Button(role: .destructive) {
                            if selectedProviderID == provider.id {
                                selectedProviderID = nil
                            }
                            providerStore.removeProvider(id: provider.id)
                        } label: {
                            Label(loc.t("settings.providers.delete"), systemImage: "trash")
                        }
                    }
                }

                Divider()

                HStack(spacing: 0) {
                    Button { showAddProvider = true } label: {
                        Image(systemName: "plus")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .frame(width: 36, height: 28)

                    Divider().frame(height: 16)

                    Button {
                        if let id = selectedProviderID {
                            providerStore.removeProvider(id: id)
                            selectedProviderID = nil
                        }
                    } label: {
                        Image(systemName: "minus")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .frame(width: 36, height: 28)
                    .disabled(selectedProviderID == nil)

                    Divider().frame(height: 16)

                    Button {
                        if let id = selectedProviderID {
                            duplicateSourceID = id
                            showDuplicateSheet = true
                        }
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .frame(width: 36, height: 28)
                    .disabled(selectedProviderID == nil)
                    .help(loc.t("settings.providers.duplicate"))

                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .frame(minWidth: 180, maxWidth: 220)

            // Detail
            if let id = selectedProviderID,
               let provider = providerStore.providers.first(where: { $0.id == id }) {
                ProviderDetailView(
                    provider: provider,
                    providerStore: providerStore,
                    autoStartSignIn: justAddedChatGPTProviderID == provider.id
                )
                .id(provider.id)
                .onAppear {
                    if justAddedChatGPTProviderID == provider.id {
                        justAddedChatGPTProviderID = nil
                    }
                }
            } else {
                VStack(spacing: 12) {
                    if providerStore.providers.isEmpty {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 32))
                            .foregroundStyle(.secondary)
                        Button(loc.t("settings.providers.add_first")) {
                            showAddProvider = true
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Text(loc.t("settings.providers.select")).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(isPresented: $showAddProvider) {
            AddProviderSheet(providerStore: providerStore, isPresented: $showAddProvider, onAdded: { id in
                if let provider = providerStore.providers.first(where: { $0.id == id }),
                   provider.providerType == .openAIChatGPT {
                    justAddedChatGPTProviderID = id
                }
                selectedProviderID = id
            })
        }
        .sheet(isPresented: $showDuplicateSheet) {
            if let sourceID = duplicateSourceID,
               let source = providerStore.providers.first(where: { $0.id == sourceID }) {
                DuplicateProviderSheet(
                    providerStore: providerStore,
                    source: source,
                    isPresented: $showDuplicateSheet,
                    onDuplicated: { id in selectedProviderID = id }
                )
            }
        }
    }

    private func nextDuplicateName(for baseName: String) -> String {
        let existingNames = Set(providerStore.providers.map(\.name))
        var candidate = "\(baseName) (1)"
        var counter = 1
        while existingNames.contains(candidate) {
            counter += 1
            candidate = "\(baseName) (\(counter))"
        }
        return candidate
    }
}

struct ProviderDetailView: View {
    let provider: AIProviderConfig
    let providerStore: ProviderStore
    var autoStartSignIn: Bool = false

    @State private var name: String = ""
    @State private var baseURL: String = ""
    @State private var modelID: String = ""
    @State private var maxTokens: Int = 4096
    @State private var temperature: Double = 1.0
    @State private var reasoningEffort: ReasoningEffort = .medium
    @State private var apiKey: String = ""
    @State private var cliToolAvailable: Bool = true
    @State private var availableModels: [String] = []
    @State private var isFetchingModels = false
    @State private var isSigningIn = false
    @State private var signInError: String?
    @State private var signInAuthURL: URL?
    @State private var signInTask: Task<Void, Never>?
    @State private var isTesting = false
    @State private var testResult: TestResult?
    @State private var showSignInAlert = false

    private let loc = Loc.shared
    private var tokenManager: ChatGPTTokenManager { .shared }

    private var supportsModelFetch: Bool {
        [.anthropic, .openAI, .openAIChatGPT, .ollama, .openAICompatible].contains(provider.providerType)
    }

    var body: some View {
        Form {
            Section(loc.t("settings.providers.provider")) {
                TextField(loc.t("settings.providers.name"), text: $name)
                    .onChange(of: name) { autoSave() }
                LabeledContent(loc.t("settings.providers.type"), value: provider.providerType.displayName)
            }

            if provider.providerType == .cliTool {
                Section(loc.t("settings.providers.cli.tool")) {
                    LabeledContent(loc.t("settings.providers.cli.binary_path"), value: baseURL)

                    HStack {
                        if cliToolAvailable {
                            Label(loc.t("settings.providers.cli.available"), systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                        } else {
                            Label(loc.t("settings.providers.cli.not_found"), systemImage: "xmark.circle.fill")
                                .foregroundStyle(.red)
                                .font(.caption)
                        }
                        Spacer()
                        Button(loc.t("settings.providers.cli.redetect")) {
                            redetectCLITool()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            } else {
                Section(loc.t("settings.providers.connection")) {
                    TextField(loc.t("settings.providers.base_url"), text: $baseURL)
                        .onChange(of: baseURL) { autoSave() }

                    modelField

                    TextField(loc.t("settings.providers.max_tokens"), value: $maxTokens, format: .number)
                        .onChange(of: maxTokens) { autoSave() }

                    if provider.providerType != .openAIChatGPT {
                        HStack {
                            Text(loc.t("settings.providers.temperature"))
                            Spacer()
                            Text(String(format: "%.1f", temperature))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .frame(width: 30)
                        }
                        Slider(value: $temperature, in: 0...2, step: 0.1)
                            .onChange(of: temperature) { autoSave() }
                    }

                    if provider.providerType.supportsReasoningEffort {
                        Picker(loc.t("settings.providers.reasoning_effort"), selection: $reasoningEffort) {
                            ForEach(ReasoningEffort.allCases) { effort in
                                Text(effort.displayName).tag(effort)
                            }
                        }
                        .onChange(of: reasoningEffort) { autoSave() }
                    }
                }

                if provider.providerType.requiresOAuth {
                    chatGPTAuthSection
                } else if provider.providerType.requiresAPIKey {
                    Section(loc.t("settings.providers.authentication")) {
                        SecureField(loc.t("settings.providers.api_key"), text: $apiKey)
                            .onChange(of: apiKey) {
                                autoSave()
                                availableModels = []
                            }
                    }
                }
            }

            Section {
                HStack {
                    if !provider.isDefault {
                        Button(loc.t("settings.providers.set_default")) {
                            providerStore.setDefault(id: provider.id)
                        }
                    } else {
                        Label(loc.t("settings.providers.default_label"), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    }

                    Spacer()

                    if isTesting {
                        ProgressView()
                            .controlSize(.small)
                    } else if let result = testResult {
                        Label(
                            result.success ? loc.t("settings.providers.test_ok") : result.message,
                            systemImage: result.success ? "checkmark.circle.fill" : "xmark.circle.fill"
                        )
                        .foregroundStyle(result.success ? .green : .red)
                        .font(.caption)
                    }

                    Button(loc.t("settings.providers.test")) { testProvider() }
                        .disabled(isTesting)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            loadValues()
            if autoStartSignIn && provider.providerType == .openAIChatGPT {
                showSignInAlert = true
            }
        }
        .alert(loc.t("settings.providers.chatgpt.sign_in_title"), isPresented: $showSignInAlert) {
            Button(loc.t("settings.providers.chatgpt.sign_in_continue")) {
                startChatGPTLogin()
            }
            .keyboardShortcut(.defaultAction)
        } message: {
            Text(loc.t("settings.providers.chatgpt.sign_in_message"))
        }
    }

    // MARK: - Model Field

    @ViewBuilder
    private var modelField: some View {
        HStack {
            if !availableModels.isEmpty {
                Picker(loc.t("settings.providers.model_id"), selection: $modelID) {
                    if !modelID.isEmpty && !availableModels.contains(modelID) {
                        Text(modelID).tag(modelID)
                    }
                    ForEach(availableModels, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                .onChange(of: modelID) { autoSave() }
            } else {
                TextField(loc.t("settings.providers.model_id"), text: $modelID)
                    .onChange(of: modelID) { autoSave() }
            }

            if isFetchingModels {
                ProgressView()
                    .controlSize(.small)
            } else if supportsModelFetch {
                Button {
                    fetchModels()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(loc.t("settings.providers.fetch_models"))
            }
        }
    }

    // MARK: - ChatGPT Auth Section

    @ViewBuilder
    private var chatGPTAuthSection: some View {
        Section(loc.t("settings.providers.authentication")) {
            if tokenManager.isAuthenticated(for: provider.id) {
                let info = tokenManager.getUserInfo(for: provider.id)
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        if let email = info.email {
                            Label(email, systemImage: "person.circle.fill")
                                .font(.subheadline)
                        }
                        if let plan = info.planType {
                            Text(plan.capitalized)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                    Spacer()
                    Button(loc.t("settings.providers.chatgpt.sign_out")) {
                        tokenManager.clearTokens(for: provider.id)
                        availableModels = []
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            } else if isSigningIn {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text(loc.t("settings.providers.chatgpt.signing_in"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(loc.t("settings.providers.cancel")) {
                            cancelChatGPTLogin()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    if let authURL = signInAuthURL {
                        HStack(spacing: 4) {
                            Text(authURL.absoluteString)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(authURL.absoluteString, forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.caption2)
                            }
                            .buttonStyle(.borderless)
                            .help(loc.t("settings.providers.chatgpt.copy_url"))
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Button(loc.t("settings.providers.chatgpt.sign_in")) {
                        startChatGPTLogin()
                    }
                    .buttonStyle(.borderedProminent)

                    if let error = signInError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func autoSave() {
        var updated = provider
        updated.name = name
        updated.baseURL = baseURL
        updated.modelID = modelID
        updated.maxTokens = maxTokens
        updated.temperature = temperature
        updated.reasoningEffort = provider.providerType.supportsReasoningEffort ? reasoningEffort : nil
        providerStore.updateProvider(updated)
        if provider.providerType.requiresAPIKey {
            providerStore.setAPIKey(apiKey, for: updated)
        }
    }

    private func testProvider() {
        // Ensure latest values are persisted before testing
        autoSave()
        isTesting = true
        testResult = nil
        Task {
            do {
                let service = AIServiceFactory.service(for: provider.providerType)
                var testConfig = provider
                testConfig.name = name
                testConfig.baseURL = baseURL
                testConfig.modelID = modelID
                testConfig.maxTokens = maxTokens
                testConfig.temperature = temperature
                testConfig.reasoningEffort = provider.providerType.supportsReasoningEffort ? reasoningEffort : nil
                let result = try await service.process(
                    text: "Reply with OK",
                    systemPrompt: "Reply with just OK, nothing else.",
                    config: testConfig
                )
                isTesting = false
                testResult = TestResult(success: !result.isEmpty, message: loc.t("settings.providers.test_ok"))
            } catch {
                isTesting = false
                testResult = TestResult(success: false, message: error.localizedDescription)
            }
        }
    }

    private func startChatGPTLogin() {
        isSigningIn = true
        signInError = nil
        signInAuthURL = nil
        signInTask = Task {
            do {
                let authService = ChatGPTAuthService()
                let tokens = try await authService.startLogin { [self] url in
                    Task { @MainActor in
                        self.signInAuthURL = url
                    }
                }
                tokenManager.saveTokens(tokens, for: provider.id)
                isSigningIn = false
                signInAuthURL = nil
                NSApp.activate(ignoringOtherApps: true)
                fetchModels()
            } catch is CancellationError {
                isSigningIn = false
                signInAuthURL = nil
            } catch {
                isSigningIn = false
                signInAuthURL = nil
                signInError = error.localizedDescription
            }
        }
    }

    private func cancelChatGPTLogin() {
        signInTask?.cancel()
        signInTask = nil
        isSigningIn = false
        signInAuthURL = nil
    }

    private func loadValues() {
        name = provider.name
        baseURL = provider.baseURL
        modelID = provider.modelID
        maxTokens = provider.maxTokens
        temperature = provider.temperature
        reasoningEffort = provider.reasoningEffort ?? .medium
        apiKey = providerStore.getAPIKey(for: provider)
        if provider.providerType == .cliTool {
            cliToolAvailable = CLIToolDetector.isAvailable(at: provider.baseURL)
        } else if supportsModelFetch {
            fetchModels()
        }
    }

    private func fetchModels() {
        isFetchingModels = true
        var tempConfig = provider
        tempConfig.baseURL = baseURL
        if !apiKey.isEmpty {
            providerStore.setAPIKey(apiKey, for: provider)
        }
        Task {
            let models = await ModelFetcher.fetchModels(for: tempConfig)
            availableModels = models
            isFetchingModels = false
        }
    }

    private func redetectCLITool() {
        guard let definition = CLIToolDefinition.find(byID: provider.modelID) else { return }
        if let newPath = CLIToolDetector.resolvePath(for: definition) {
            baseURL = newPath
            cliToolAvailable = true
            autoSave()
        } else {
            cliToolAvailable = false
        }
    }
}

// MARK: - Test Result

private struct TestResult {
    let success: Bool
    let message: String
}

// MARK: - Add Provider Sheet

/// Represents a selectable option in the Add Provider sheet —
/// either a standard provider type or a specific detected CLI tool.
private enum ProviderOption: Equatable, Identifiable {
    case standard(AIProviderType)
    case cliTool(CLIToolDetector.DetectionResult)

    var id: String {
        switch self {
        case .standard(let type): "type-\(type.rawValue)"
        case .cliTool(let result): "cli-\(result.definition.id)"
        }
    }

    static func == (lhs: ProviderOption, rhs: ProviderOption) -> Bool { lhs.id == rhs.id }
}

struct AddProviderSheet: View {
    let providerStore: ProviderStore
    @Binding var isPresented: Bool
    var onAdded: ((UUID) -> Void)?
    @State private var selected: ProviderOption?
    @State private var options: [ProviderOption] = []

    private let loc = Loc.shared

    var body: some View {
        VStack(spacing: 16) {
            Text(loc.t("settings.providers.add")).font(.headline)

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(options) { option in
                        optionRow(option)
                    }
                }
            }
            .frame(maxHeight: 340)

            HStack {
                Button(loc.t("settings.providers.cancel")) { isPresented = false }
                Spacer()
                Button(loc.t("settings.providers.add_button")) {
                    addProvider()
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(selected == nil)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { buildOptions() }
    }

    private func buildOptions() {
        let detectedCLI = CLIToolDetector.detectAll()
        var result: [ProviderOption] = []
        for type in AIProviderType.allCases {
            if type == .cliTool {
                // Replace generic CLI Tool with individual detected tools
                for tool in detectedCLI {
                    result.append(.cliTool(tool))
                }
            } else {
                result.append(.standard(type))
            }
        }
        options = result
    }

    private func optionRow(_ option: ProviderOption) -> some View {
        let isSelected = selected == option
        return Button {
            selected = option
        } label: {
            HStack(spacing: 12) {
                optionIcon(option, isSelected: isSelected)
                VStack(alignment: .leading, spacing: 2) {
                    Text(optionTitle(option))
                        .font(.body)
                    Text(optionSubtitle(option))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.blue)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(isSelected ? Color.accentColor.opacity(0.1) : .clear,
                        in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func optionIcon(_ option: ProviderOption, isSelected: Bool) -> some View {
        switch option {
        case .standard(let type):
            ProviderIconView(providerType: type, size: 22)
                .foregroundStyle(isSelected ? .blue : .secondary)
        case .cliTool(let result):
            Image(result.definition.iconName, bundle: .module)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 22, height: 22)
                .foregroundStyle(isSelected ? .blue : .secondary)
        }
    }

    private func optionTitle(_ option: ProviderOption) -> String {
        switch option {
        case .standard(let type): type.displayName
        case .cliTool(let result): result.definition.displayName
        }
    }

    private func optionSubtitle(_ option: ProviderOption) -> String {
        switch option {
        case .standard(let type): type.providerDescription
        case .cliTool(let result): result.binaryPath
        }
    }

    private func addProvider() {
        guard let selected else { return }
        let config: AIProviderConfig
        switch selected {
        case .standard(let type):
            config = AIProviderConfig(
                name: type.displayName,
                providerType: type
            )
        case .cliTool(let result):
            config = AIProviderConfig(
                name: result.definition.displayName,
                providerType: .cliTool,
                baseURL: result.binaryPath,
                modelID: result.definition.id
            )
        }
        providerStore.addProvider(config)
        onAdded?(config.id)
    }
}

// MARK: - Duplicate Provider Sheet

struct DuplicateProviderSheet: View {
    let providerStore: ProviderStore
    let source: AIProviderConfig
    @Binding var isPresented: Bool
    var onDuplicated: ((UUID) -> Void)?
    @State private var name: String = ""

    private let loc = Loc.shared

    var body: some View {
        VStack(spacing: 16) {
            Text(loc.t("settings.providers.duplicate")).font(.headline)

            TextField(loc.t("settings.providers.name"), text: $name)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button(loc.t("settings.providers.cancel")) { isPresented = false }
                Spacer()
                Button(loc.t("settings.providers.duplicate_button")) {
                    duplicate()
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 350)
        .onAppear {
            name = nextDuplicateName(for: source.name)
        }
    }

    private func duplicate() {
        let config = AIProviderConfig(
            name: name,
            providerType: source.providerType,
            baseURL: source.baseURL,
            modelID: source.modelID,
            maxTokens: source.maxTokens,
            temperature: source.temperature,
            reasoningEffort: source.reasoningEffort
        )
        providerStore.addProvider(config)
        // Copy API key if present
        let apiKey = providerStore.getAPIKey(for: source)
        if !apiKey.isEmpty {
            providerStore.setAPIKey(apiKey, for: config)
        }
        onDuplicated?(config.id)
    }

    private func nextDuplicateName(for baseName: String) -> String {
        let existingNames = Set(providerStore.providers.map(\.name))
        var candidate = "\(baseName) (1)"
        var counter = 1
        while existingNames.contains(candidate) {
            counter += 1
            candidate = "\(baseName) (\(counter))"
        }
        return candidate
    }
}
