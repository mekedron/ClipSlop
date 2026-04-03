import SwiftUI

struct OnboardingProviderView: View {
    let appState: AppState

    @State private var selectedType: AIProviderType = .anthropic
    @State private var apiKey: String = ""
    @State private var ollamaModel: String = Constants.Ollama.defaultModel
    @State private var customBaseURL: String = ""
    @State private var customModel: String = ""
    @State private var isTesting = false
    @State private var testResult: TestResult?
    @State private var configuredProviderIDs: Set<UUID> = []

    private let loc = Loc.shared
    private var providerStore: ProviderStore { appState.providerStore }

    enum TestResult {
        case success
        case error(String)
    }

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "brain")
                .font(.system(size: 48))
                .foregroundStyle(.blue)

            Text(loc.t("onboarding.provider.title"))
                .font(.title.bold())

            Text(loc.t("onboarding.provider.subtitle"))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            // Provider picker
            Picker(loc.t("settings.providers.provider"), selection: $selectedType) {
                ForEach(AIProviderType.allCases) { type in
                    Text(type.displayName).tag(type)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 420)
            .onChange(of: selectedType) {
                testResult = nil
                loadExistingKey()
            }

            // Provider-specific config
            VStack(spacing: 12) {
                switch selectedType {
                case .anthropic:
                    apiKeyField(placeholder: "sk-ant-...")
                    providerHint(loc.t("onboarding.provider.hint.anthropic"))

                case .openAI:
                    apiKeyField(placeholder: "sk-...")
                    providerHint(loc.t("onboarding.provider.hint.openai"))

                case .ollama:
                    HStack {
                        Text(loc.t("onboarding.provider.model"))
                            .frame(width: 80, alignment: .trailing)
                        TextField("llama3.2", text: $ollamaModel)
                            .textFieldStyle(.roundedBorder)
                    }
                    providerHint(loc.t("onboarding.provider.hint.ollama"))

                case .openAICompatible:
                    HStack {
                        Text(loc.t("onboarding.provider.base_url"))
                            .frame(width: 80, alignment: .trailing)
                        TextField("https://api.example.com", text: $customBaseURL)
                            .textFieldStyle(.roundedBorder)
                    }
                    HStack {
                        Text(loc.t("onboarding.provider.model"))
                            .frame(width: 80, alignment: .trailing)
                        TextField("model-name", text: $customModel)
                            .textFieldStyle(.roundedBorder)
                    }
                    apiKeyField(placeholder: "API key (if required)")
                }
            }
            .frame(maxWidth: 420)

            // Test connection button
            HStack(spacing: 12) {
                Button {
                    testConnection()
                } label: {
                    HStack(spacing: 6) {
                        if isTesting {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(isTesting ? loc.t("onboarding.provider.testing") : loc.t("onboarding.provider.test_connection"))
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isTesting || !canTest)

                Button(loc.t("onboarding.provider.save")) {
                    saveProvider()
                    refocusOnboarding()
                }
                .buttonStyle(AlwaysProminentButtonStyle())
                .disabled(!canSave)

                // Test result
                if let result = testResult {
                    switch result {
                    case .success:
                        Label(loc.t("onboarding.provider.connected"), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    case .error(let msg):
                        Label(msg, systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                            .lineLimit(1)
                    }
                }
            }

            // Configured providers — pick default (uses cached state, no Keychain reads in body)
            let configured = providerStore.providers.filter { configuredProviderIDs.contains($0.id) }
            if !configured.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(loc.t("onboarding.provider.default_label"))
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        ForEach(configured) { p in
                            Button {
                                providerStore.setDefault(id: p.id)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: p.isDefault ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(p.isDefault ? .green : .secondary)
                                    Text(p.name)
                                }
                                .font(.caption)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(p.isDefault ? Color.green.opacity(0.1) : Color.secondary.opacity(0.1))
                                .clipShape(Capsule())
                                .overlay(
                                    Capsule().strokeBorder(p.isDefault ? Color.green.opacity(0.3) : Color.clear)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxWidth: 420)
            }

            Spacer()
        }
        .padding(32)
        .onAppear {
            loadExistingKey()
            refreshConfiguredProviders()
        }
    }

    // MARK: - Subviews

    private func apiKeyField(placeholder: String) -> some View {
        HStack {
            Text(loc.t("onboarding.provider.api_key"))
                .frame(width: 80, alignment: .trailing)
            SecureField(placeholder, text: $apiKey)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func providerHint(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    // MARK: - Logic

    private var canTest: Bool {
        switch selectedType {
        case .anthropic, .openAI:
            !apiKey.isEmpty
        case .ollama:
            !ollamaModel.isEmpty
        case .openAICompatible:
            !customBaseURL.isEmpty && !customModel.isEmpty
        }
    }

    private var canSave: Bool {
        canTest
    }

    private func refreshConfiguredProviders() {
        var ids = Set<UUID>()
        for provider in providerStore.providers {
            if provider.providerType == .ollama {
                ids.insert(provider.id)
            } else if let key = KeychainService.load(key: provider.apiKeyRef), !key.isEmpty {
                ids.insert(provider.id)
            }
        }
        configuredProviderIDs = ids
    }

    private func loadExistingKey() {
        if let provider = providerStore.providers.first(where: { $0.providerType == selectedType }) {
            apiKey = providerStore.getAPIKey(for: provider)
            if selectedType == .ollama {
                ollamaModel = provider.modelID
            }
            if selectedType == .openAICompatible {
                customBaseURL = provider.baseURL
                customModel = provider.modelID
            }
        }
    }

    private func saveProvider() {
        let providerID: UUID

        if var existing = providerStore.providers.first(where: { $0.providerType == selectedType }) {
            applyConfig(to: &existing)
            providerStore.updateProvider(existing)
            if !apiKey.isEmpty {
                providerStore.setAPIKey(apiKey, for: existing)
            }
            providerID = existing.id
        } else {
            var newProvider = AIProviderConfig(name: selectedType.displayName, providerType: selectedType)
            applyConfig(to: &newProvider)
            providerStore.addProvider(newProvider)
            if !apiKey.isEmpty {
                providerStore.setAPIKey(apiKey, for: newProvider)
            }
            providerID = newProvider.id
        }

        refreshConfiguredProviders()

        // Auto-set as default if no default is configured yet
        let currentDefault = providerStore.defaultProvider
        if currentDefault == nil || !configuredProviderIDs.contains(currentDefault!.id) {
            providerStore.setDefault(id: providerID)
        }
    }

    private func applyConfig(to provider: inout AIProviderConfig) {
        switch selectedType {
        case .ollama:
            provider.modelID = ollamaModel
        case .openAICompatible:
            provider.baseURL = customBaseURL
            provider.modelID = customModel
        default:
            break
        }
    }

    private func refocusOnboarding() {
        // Keychain dialog steals focus — bring onboarding window back.
        // The window is .floating level so it stays on top; just re-activate the app.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    private func testConnection() {
        saveProvider()

        guard let provider = providerStore.providers.first(where: { $0.providerType == selectedType }) else {
            testResult = .error(loc.t("error.provider_not_found"))
            return
        }

        isTesting = true
        testResult = nil

        let service = AIServiceFactory.service(for: provider.providerType)

        Task {
            do {
                let result = try await service.process(
                    text: "Say 'hello' in one word.",
                    systemPrompt: "Respond with exactly one word.",
                    config: provider
                )
                testResult = result.isEmpty ? .error(loc.t("error.empty_response")) : .success
            } catch {
                testResult = .error(error.localizedDescription)
            }
            isTesting = false
            refocusOnboarding()
        }
    }
}
