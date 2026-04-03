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
                    Text(loc.t("settings.providers.select")).foregroundStyle(.secondary)
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

    private let loc = Loc.shared

    var body: some View {
        Form {
            Section(loc.t("settings.providers.provider")) {
                TextField(loc.t("settings.providers.name"), text: $name)
                LabeledContent(loc.t("settings.providers.type"), value: provider.providerType.displayName)
            }

            Section(loc.t("settings.providers.connection")) {
                TextField(loc.t("settings.providers.base_url"), text: $baseURL)
                TextField(loc.t("settings.providers.model_id"), text: $modelID)
                TextField(loc.t("settings.providers.max_tokens"), value: $maxTokens, format: .number)
            }

            if provider.providerType.requiresAPIKey {
                Section(loc.t("settings.providers.authentication")) {
                    SecureField(loc.t("settings.providers.api_key"), text: $apiKey)
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

    private let loc = Loc.shared

    var body: some View {
        VStack(spacing: 16) {
            Text(loc.t("settings.providers.add")).font(.headline)

            Picker(loc.t("settings.providers.type"), selection: $selectedType) {
                ForEach(AIProviderType.allCases) { type in
                    Text(type.displayName).tag(type)
                }
            }

            TextField(loc.t("settings.providers.name"), text: $name)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button(loc.t("settings.providers.cancel")) { isPresented = false }
                Spacer()
                Button(loc.t("settings.providers.add_button")) {
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
