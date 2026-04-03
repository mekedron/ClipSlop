import SwiftUI

struct ProvidersSettingsView: View {
    let appState: AppState
    @State private var selectedProviderID: UUID?
    @State private var showAddProvider = false

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

                HStack(spacing: 8) {
                    Button { showAddProvider = true } label: {
                        Image(systemName: "plus")
                    }.buttonStyle(.borderless)

                    Button {
                        if let id = selectedProviderID {
                            providerStore.removeProvider(id: id)
                            selectedProviderID = nil
                        }
                    } label: {
                        Image(systemName: "minus")
                    }
                    .buttonStyle(.borderless)
                    .disabled(selectedProviderID == nil)

                    Spacer()
                }
                .padding(8)
            }
            .frame(minWidth: 180, maxWidth: 220)

            // Detail
            if let id = selectedProviderID,
               let provider = providerStore.providers.first(where: { $0.id == id }) {
                ProviderDetailView(provider: provider, providerStore: providerStore)
                    .id(provider.id)
            } else {
                VStack {
                    Text("Select a provider").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(isPresented: $showAddProvider) {
            AddProviderSheet(providerStore: providerStore, isPresented: $showAddProvider)
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

    var body: some View {
        Form {
            Section("Provider") {
                TextField("Name", text: $name)
                LabeledContent("Type", value: provider.providerType.displayName)
            }

            Section("Connection") {
                TextField("Base URL", text: $baseURL)
                TextField("Model ID", text: $modelID)
                TextField("Max Tokens", value: $maxTokens, format: .number)
            }

            if provider.providerType.requiresAPIKey {
                Section("Authentication") {
                    SecureField("API Key", text: $apiKey)
                }
            }

            Section {
                HStack {
                    if !provider.isDefault {
                        Button("Set as Default") {
                            providerStore.setDefault(id: provider.id)
                        }
                    } else {
                        Label("Default Provider", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    }
                    Spacer()
                    Button("Save") { save() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { loadValues() }
    }

    private func loadValues() {
        name = provider.name
        baseURL = provider.baseURL
        modelID = provider.modelID
        maxTokens = provider.maxTokens
        apiKey = providerStore.getAPIKey(for: provider)
    }

    private func save() {
        var updated = provider
        updated.name = name
        updated.baseURL = baseURL
        updated.modelID = modelID
        updated.maxTokens = maxTokens
        providerStore.updateProvider(updated)
        providerStore.setAPIKey(apiKey, for: updated)
    }
}

struct AddProviderSheet: View {
    let providerStore: ProviderStore
    @Binding var isPresented: Bool
    @State private var selectedType: AIProviderType = .openAICompatible
    @State private var name: String = ""

    var body: some View {
        VStack(spacing: 16) {
            Text("Add Provider").font(.headline)

            Picker("Type", selection: $selectedType) {
                ForEach(AIProviderType.allCases) { type in
                    Text(type.displayName).tag(type)
                }
            }

            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("Cancel") { isPresented = false }
                Spacer()
                Button("Add") {
                    let config = AIProviderConfig(
                        name: name.isEmpty ? selectedType.displayName : name,
                        providerType: selectedType
                    )
                    providerStore.addProvider(config)
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 350)
    }
}
