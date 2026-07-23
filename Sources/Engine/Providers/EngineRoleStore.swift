import Foundation

/// Model roles the engine can bind providers to (§14). V0 routes only the
/// generation role; the enum exists so later roles (planner.fallback,
/// verification, …) are additive.
enum EngineRole: String, Codable, Sendable, CaseIterable {
    case generationMagic = "generation.magic"
}

/// Role → provider mapping, persisted as roles.json beside providers.json.
/// Providers and credentials stay in the existing `ProviderStore`; a role is
/// only a pointer into it.
@MainActor
@Observable
final class EngineRoleStore {
    private(set) var mapping: [EngineRole: UUID] = [:]

    init() {
        mapping = Self.loadFromDisk() ?? [:]
    }

    func setProvider(_ id: UUID?, for role: EngineRole) {
        if let id {
            mapping[role] = id
        } else {
            mapping.removeValue(forKey: role)
        }
        saveToDisk()
    }

    func provider(for role: EngineRole, in store: ProviderStore) -> AIProviderConfig? {
        Self.resolve(role: role, mapping: mapping, providers: store.providers)
    }

    /// Pure resolution, mirroring `ProviderStore.resolve`: the configured
    /// provider when it still exists, else the app default, else the first.
    /// A stale mapping (provider deleted in Settings) falls through rather
    /// than failing — the "fallback role" in V0 *is* the default provider.
    nonisolated static func resolve(
        role: EngineRole,
        mapping: [EngineRole: UUID],
        providers: [AIProviderConfig]
    ) -> AIProviderConfig? {
        ProviderStore.resolve(preferring: mapping[role], in: providers)
    }

    // MARK: - Persistence

    private nonisolated static func loadFromDisk() -> [EngineRole: UUID]? {
        guard let data = try? Data(contentsOf: Constants.Engine.rolesFileURL),
              let raw = try? JSONDecoder().decode([String: UUID].self, from: data)
        else { return nil }
        var mapping: [EngineRole: UUID] = [:]
        for (key, value) in raw {
            if let role = EngineRole(rawValue: key) { mapping[role] = value }
        }
        return mapping
    }

    private func saveToDisk() {
        let raw = Dictionary(uniqueKeysWithValues: mapping.map { ($0.key.rawValue, $0.value) })
        try? JSONEncoder.pretty.encode(raw).write(to: Constants.Engine.rolesFileURL)
    }
}
