import Foundation

@MainActor
@Observable
final class ProviderStore {
    private(set) var providers: [AIProviderConfig] = []

    var defaultProvider: AIProviderConfig? {
        providers.first(where: \.isDefault) ?? providers.first
    }

    init() {
        providers = loadFromDisk() ?? Self.defaultProviders
    }

    func save() {
        saveToDisk(providers)
    }

    func addProvider(_ provider: AIProviderConfig) {
        var updated = providers
        updated.append(provider)
        providers = updated
        saveToDisk(updated)
    }

    func updateProvider(_ provider: AIProviderConfig) {
        guard let index = providers.firstIndex(where: { $0.id == provider.id }) else { return }
        var updated = providers
        updated[index] = provider
        providers = updated
        saveToDisk(updated)
    }

    func removeProvider(id: UUID) {
        var updated = providers
        updated.removeAll { $0.id == id }
        providers = updated
        saveToDisk(updated)
    }

    func setDefault(id: UUID) {
        let updated = providers.map { provider in
            var p = provider
            p.isDefault = (p.id == id)
            return p
        }
        providers = updated
        saveToDisk(updated)
    }

    func getAPIKey(for provider: AIProviderConfig) -> String {
        KeychainService.load(key: provider.apiKeyRef) ?? ""
    }

    func setAPIKey(_ key: String, for provider: AIProviderConfig) {
        if key.isEmpty {
            KeychainService.delete(key: provider.apiKeyRef)
        } else {
            try? KeychainService.save(key: provider.apiKeyRef, value: key)
        }
    }

    // MARK: - Private

    private static let defaultProviders: [AIProviderConfig] = [
        .builtInAnthropic,
        .builtInOpenAI,
        .builtInOllama,
    ]

    private func loadFromDisk() -> [AIProviderConfig]? {
        guard FileManager.default.fileExists(atPath: Constants.providersFileURL.path),
              let data = try? Data(contentsOf: Constants.providersFileURL),
              let configs = try? JSONDecoder().decode([AIProviderConfig].self, from: data)
        else { return nil }
        return configs
    }

    private func saveToDisk(_ configs: [AIProviderConfig]) {
        try? JSONEncoder.pretty.encode(configs).write(to: Constants.providersFileURL)
    }
}
