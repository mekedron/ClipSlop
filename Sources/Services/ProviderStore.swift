import Foundation

@MainActor
@Observable
final class ProviderStore {
    private(set) var providers: [AIProviderConfig] = []
    /// Parse warnings from the last providers.yaml load — shown in Settings
    /// → Providers, never silent (§15.3).
    private(set) var loadWarnings: [String] = []

    @ObservationIgnored private var fileModified: Date?

    var defaultProvider: AIProviderConfig? {
        providers.first(where: \.isDefault) ?? providers.first
    }

    /// Resolves the provider a prompt should run on: its own override when set and
    /// still present, otherwise the default.
    func provider(preferring id: UUID?) -> AIProviderConfig? {
        Self.resolve(preferring: id, in: providers)
    }

    /// Pure form of `provider(preferring:)`, extracted so the fallback chain can be
    /// tested without a disk-backed store. A prompt's `providerID` can outlive the
    /// provider it points at (the user deletes it in Settings), so a stale override
    /// has to fall through to the default rather than fail.
    nonisolated static func resolve(
        preferring id: UUID?,
        in providers: [AIProviderConfig]
    ) -> AIProviderConfig? {
        if let id, let specific = providers.first(where: { $0.id == id }) {
            return specific
        }
        return providers.first(where: \.isDefault) ?? providers.first
    }

    init() {
        load()
    }

    /// Re-reads providers.yaml when it changed on disk (hand edits). Called
    /// on press (`MagicPressPipeline.plan`) and when Settings opens — the
    /// same reload-on-use model as the other engine stores.
    func reloadIfChanged() {
        guard let modified = Self.modificationDate(of: Constants.Engine.providersFileURL),
              modified != fileModified
        else { return }
        load()
    }

    func save() {
        saveToDisk(providers)
    }

    func addProvider(_ provider: AIProviderConfig) {
        var newProvider = provider
        // First provider with an actual configuration becomes the default automatically
        let hasDefault = providers.contains(where: \.isDefault)
        if !hasDefault {
            newProvider.isDefault = true
        }
        var updated = providers
        updated.append(newProvider)
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

    private func load() {
        let url = Constants.Engine.providersFileURL
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            let result = ProvidersFile.parse(text)
            providers = result.providers
            loadWarnings = result.warnings
            fileModified = Self.modificationDate(of: url)
            // A file that exists but yields nothing is likely a broken hand
            // edit — preserve it before any Settings save overwrites it.
            if result.providers.isEmpty, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let backup = url.appendingPathExtension("broken")
                try? FileManager.default.removeItem(at: backup)
                try? FileManager.default.copyItem(at: url, to: backup)
                loadWarnings.append("providers.yaml parsed to an empty list — original kept as providers.yaml.broken")
            }
            return
        }
        providers = migrateFromLegacyJSON() ?? []
        loadWarnings = []
    }

    /// One-time move from Application Support/providers.json (pre-M3). The
    /// JSON is kept as `.bak`; Keychain refs ride along unchanged because
    /// the ids are preserved.
    private func migrateFromLegacyJSON() -> [AIProviderConfig]? {
        let legacy = Constants.Engine.legacyProvidersFileURL
        guard FileManager.default.fileExists(atPath: legacy.path),
              let data = try? Data(contentsOf: legacy),
              let configs = try? JSONDecoder().decode([AIProviderConfig].self, from: data)
        else { return nil }
        saveToDisk(configs)
        let backup = legacy.appendingPathExtension("bak")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: legacy, to: backup)
        return configs
    }

    private func saveToDisk(_ configs: [AIProviderConfig]) {
        let url = Constants.Engine.providersFileURL
        Constants.Engine.ensureDirectoriesExist()
        try? ProvidersFile.serialize(configs).write(to: url, atomically: true, encoding: .utf8)
        fileModified = Self.modificationDate(of: url)
    }

    private nonisolated static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
