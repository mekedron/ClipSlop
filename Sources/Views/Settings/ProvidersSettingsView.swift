import SwiftUI

struct ProvidersSettingsView: View {
    let appState: AppState
    @State private var selectedProviderID: UUID?
    @State private var showAddProvider = false

    private let loc = Loc.shared
    private var providerStore: ProviderStore { appState.providerStore }

    var body: some View {
        HSplitView {
            // Provider list
            VStack(spacing: 0) {
                List(providerStore.providers, selection: $selectedProviderID) { provider in
                    HStack {
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

                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .frame(minWidth: 180, maxWidth: 220)

            // Detail
            if let id = selectedProviderID,
               let provider = providerStore.providers.first(where: { $0.id == id }) {
                ProviderDetailView(provider: provider, providerStore: providerStore)
                    .id(provider.id)
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
                selectedProviderID = id
            })
        }
    }
}

struct ProviderDetailView: View {
    let provider: AIProviderConfig
    let providerStore: ProviderStore

    @State private var name: String = ""
    @State private var baseURL: String = ""
    @State private var modelID: String = ""
    @State private var maxTokens: Int = 4096
    @State private var apiKey: String = ""
    @State private var cliToolAvailable: Bool = true
    @State private var availableModels: [String] = []
    @State private var isFetchingModels = false

    private let loc = Loc.shared

    private var supportsModelFetch: Bool {
        [.anthropic, .openAI, .ollama, .openAICompatible].contains(provider.providerType)
    }

    var body: some View {
        Form {
            Section(loc.t("settings.providers.provider")) {
                TextField(loc.t("settings.providers.name"), text: $name)
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

                    modelField

                    TextField(loc.t("settings.providers.max_tokens"), value: $maxTokens, format: .number)
                }

                if provider.providerType.requiresAPIKey {
                    Section(loc.t("settings.providers.authentication")) {
                        SecureField(loc.t("settings.providers.api_key"), text: $apiKey)
                            .onChange(of: apiKey) {
                                // Re-fetch models when API key changes (user might paste a new key)
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
                    Button(loc.t("settings.providers.save")) { save() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { loadValues() }
    }

    @ViewBuilder
    private var modelField: some View {
        HStack {
            if !availableModels.isEmpty {
                Picker(loc.t("settings.providers.model_id"), selection: $modelID) {
                    // Allow current value even if not in the fetched list
                    if !modelID.isEmpty && !availableModels.contains(modelID) {
                        Text(modelID).tag(modelID)
                    }
                    ForEach(availableModels, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
            } else {
                TextField(loc.t("settings.providers.model_id"), text: $modelID)
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

    private func loadValues() {
        name = provider.name
        baseURL = provider.baseURL
        modelID = provider.modelID
        maxTokens = provider.maxTokens
        apiKey = providerStore.getAPIKey(for: provider)
        if provider.providerType == .cliTool {
            cliToolAvailable = CLIToolDetector.isAvailable(at: provider.baseURL)
        } else if supportsModelFetch {
            fetchModels()
        }
    }

    private func fetchModels() {
        isFetchingModels = true
        // Build a temporary config with current (possibly unsaved) values
        var tempConfig = provider
        tempConfig.baseURL = baseURL
        // Save API key temporarily so the fetcher can read it
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
            save()
        } else {
            cliToolAvailable = false
        }
    }

    private func save() {
        var updated = provider
        updated.name = name
        updated.baseURL = baseURL
        updated.modelID = modelID
        updated.maxTokens = maxTokens
        providerStore.updateProvider(updated)
        if provider.providerType != .cliTool {
            providerStore.setAPIKey(apiKey, for: updated)
        }
    }
}

struct AddProviderSheet: View {
    let providerStore: ProviderStore
    @Binding var isPresented: Bool
    var onAdded: ((UUID) -> Void)?
    @State private var selectedType: AIProviderType = .openAICompatible
    @State private var name: String = ""
    @State private var detectedCLITools: [CLIToolDetector.DetectionResult] = []
    @State private var selectedCLIToolID: String = ""

    private let loc = Loc.shared

    var body: some View {
        VStack(spacing: 16) {
            Text(loc.t("settings.providers.add")).font(.headline)

            Picker(loc.t("settings.providers.type"), selection: $selectedType) {
                ForEach(AIProviderType.allCases) { type in
                    Text(type.displayName).tag(type)
                }
            }

            if selectedType == .cliTool {
                if detectedCLITools.isEmpty {
                    Text(loc.t("onboarding.provider.cli.none_found"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Picker(loc.t("onboarding.provider.cli.select_tool"), selection: $selectedCLIToolID) {
                        ForEach(detectedCLITools, id: \.definition.id) { result in
                            Text(result.definition.displayName).tag(result.definition.id)
                        }
                    }
                }
            } else {
                TextField(loc.t("settings.providers.name_optional"), text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Button(loc.t("settings.providers.cancel")) { isPresented = false }
                Spacer()
                Button(loc.t("settings.providers.add_button")) {
                    addProvider()
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedType == .cliTool && selectedCLIToolID.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 350)
        .onChange(of: selectedType) {
            if selectedType == .cliTool {
                detectedCLITools = CLIToolDetector.detectAll()
                selectedCLIToolID = detectedCLITools.first?.definition.id ?? ""
            }
        }
    }

    private func addProvider() {
        let config: AIProviderConfig
        if selectedType == .cliTool {
            guard let result = detectedCLITools.first(where: { $0.definition.id == selectedCLIToolID }) else { return }
            config = AIProviderConfig(
                name: result.definition.displayName,
                providerType: .cliTool,
                baseURL: result.binaryPath,
                modelID: result.definition.id
            )
        } else {
            config = AIProviderConfig(
                name: name.isEmpty ? selectedType.displayName : name,
                providerType: selectedType
            )
        }
        providerStore.addProvider(config)
        onAdded?(config.id)
    }
}
