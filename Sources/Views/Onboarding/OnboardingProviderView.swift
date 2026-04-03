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

            Text("AI Provider")
                .font(.title.bold())

            Text("Choose your AI provider and enter your API key.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            // Provider picker
            Picker("Provider", selection: $selectedType) {
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
                    providerHint("Get your key at console.anthropic.com")

                case .openAI:
                    apiKeyField(placeholder: "sk-...")
                    providerHint("Get your key at platform.openai.com")

                case .ollama:
                    HStack {
                        Text("Model")
                            .frame(width: 80, alignment: .trailing)
                        TextField("llama3.2", text: $ollamaModel)
                            .textFieldStyle(.roundedBorder)
                    }
                    providerHint("Make sure Ollama is running locally (ollama serve)")

                case .openAICompatible:
                    HStack {
                        Text("Base URL")
                            .frame(width: 80, alignment: .trailing)
                        TextField("https://api.example.com", text: $customBaseURL)
                            .textFieldStyle(.roundedBorder)
                    }
                    HStack {
                        Text("Model")
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
                        Text(isTesting ? "Testing..." : "Test Connection")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isTesting || !canTest)

                Button("Save Provider") {
                    saveProvider()
                    refocusOnboarding()
                }
                .buttonStyle(AlwaysProminentButtonStyle())
                .disabled(!canSave)

                // Test result
                if let result = testResult {
                    switch result {
                    case .success:
                        Label("Connected!", systemImage: "checkmark.circle.fill")
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

            // Configured providers — pick default
            let configured = providerStore.providers.filter { hasKeyFor($0) }
            if !configured.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Default provider for processing:")
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
        .onAppear { loadExistingKey() }
    }

    // MARK: - Subviews

    private func apiKeyField(placeholder: String) -> some View {
        HStack {
            Text("API Key")
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

    private func hasKeyFor(_ provider: AIProviderConfig) -> Bool {
        if provider.providerType == .ollama { return true }
        let key = KeychainService.load(key: provider.apiKeyRef) ?? ""
        return !key.isEmpty
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

        // Auto-set as default if no default is configured yet
        let currentDefault = providerStore.defaultProvider
        if currentDefault == nil || !hasKeyFor(currentDefault!) {
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
        // Keychain dialog steals focus — watch for app becoming active again
        var observer: Any?
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            if let observer { NotificationCenter.default.removeObserver(observer) }
            NSApp.windows.first { $0 is OnboardingWindow }?.makeKeyAndOrderFront(nil)
        }
        // Also try immediately in case Keychain dialog was instant
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    private func testConnection() {
        saveProvider()

        guard let provider = providerStore.providers.first(where: { $0.providerType == selectedType }) else {
            testResult = .error("Provider not found")
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
                testResult = result.isEmpty ? .error("Empty response") : .success
            } catch {
                testResult = .error(error.localizedDescription)
            }
            isTesting = false
            refocusOnboarding()
        }
    }
}
