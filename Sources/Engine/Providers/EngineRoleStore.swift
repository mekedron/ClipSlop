import Foundation

/// Model roles the engine can bind providers to (§14). Additive by design;
/// roles without a consumer yet (planner.fallback, verification, …) are not
/// listed until something dispatches through them.
enum EngineRole: String, Codable, Sendable, CaseIterable {
    case generationMagic = "generation.magic"
    case chatAssistant = "chat.assistant"

    /// Capability the bound provider must have to serve this role at all.
    var requiresToolCalling: Bool {
        self == .chatAssistant
    }
}

/// Everything a role binds beyond the primary provider (§14): an explicit
/// fallback chain, a per-role request timeout, and the cost floor that
/// forbids silent downgrade (P9).
struct RoleBinding: Sendable, Equatable {
    var provider: UUID?
    var fallbacks: [UUID] = []
    var timeoutSeconds: Int?
    var minCostClass: ProviderCostClass?

    var isEmpty: Bool { self == RoleBinding() }
}

enum RoleResolutionOutcome: Sendable {
    case resolved(AIProviderConfig)
    /// Candidates exist but every one sits below the role's cost floor —
    /// the engine refuses honestly instead of degrading quality silently.
    case refusedBelowMinCost(min: ProviderCostClass)
    case noneAvailable
}

/// Role → binding store, persisted as `~/.clipslop/roles.yaml` (migrated
/// from the App Support roles.json). Providers and credentials stay in
/// `ProviderStore`; a binding only points into it.
@MainActor
@Observable
final class EngineRoleStore {
    private(set) var bindings: [EngineRole: RoleBinding] = [:]
    /// Parse warnings from the last roles.yaml load — surfaced in Settings.
    private(set) var loadWarnings: [String] = []

    @ObservationIgnored private var fileModified: Date?

    /// Compatibility view for UI code that binds "the provider for a role".
    var mapping: [EngineRole: UUID] {
        bindings.compactMapValues(\.provider)
    }

    init() {
        load()
    }

    func reloadIfChanged() {
        guard let modified = Self.modificationDate(of: Constants.Engine.rolesYamlURL),
              modified != fileModified
        else { return }
        load()
    }

    func binding(for role: EngineRole) -> RoleBinding {
        bindings[role] ?? RoleBinding()
    }

    func setBinding(_ binding: RoleBinding, for role: EngineRole) {
        if binding.isEmpty {
            bindings.removeValue(forKey: role)
        } else {
            bindings[role] = binding
        }
        saveToDisk()
    }

    func setProvider(_ id: UUID?, for role: EngineRole) {
        var binding = self.binding(for: role)
        binding.provider = id
        setBinding(binding, for: role)
    }

    func provider(for role: EngineRole, in store: ProviderStore) -> AIProviderConfig? {
        if case .resolved(let provider) = resolution(for: role, in: store) {
            return provider
        }
        return nil
    }

    func resolution(for role: EngineRole, in store: ProviderStore) -> RoleResolutionOutcome {
        Self.resolve(role: role, binding: binding(for: role), providers: store.providers)
    }

    /// Pure resolution. Order: the bound provider, then the explicit
    /// fallback chain, then the app default, then the first provider — the
    /// pre-M3 fallthrough preserved as the chain's implicit tail. Candidates
    /// missing a required capability are skipped; `min_cost_class` filters
    /// last and refuses rather than downgrading (P9). The winner carries the
    /// role's request timeout.
    nonisolated static func resolve(
        role: EngineRole,
        binding: RoleBinding,
        providers: [AIProviderConfig]
    ) -> RoleResolutionOutcome {
        var candidates: [AIProviderConfig] = []
        var seen = Set<UUID>()
        func add(_ provider: AIProviderConfig?) {
            guard let provider, seen.insert(provider.id).inserted else { return }
            if role.requiresToolCalling && !provider.providerType.supportsToolCalling { return }
            candidates.append(provider)
        }

        add(binding.provider.flatMap { id in providers.first { $0.id == id } })
        for id in binding.fallbacks {
            add(providers.first { $0.id == id })
        }
        add(providers.first(where: \.isDefault))
        add(providers.first)
        // Capability-constrained roles keep their pre-M3 last resort: the
        // first provider that can actually serve the role (the assistant's
        // old "first tool-calling provider" chain).
        if role.requiresToolCalling {
            add(providers.first { $0.providerType.supportsToolCalling })
        }

        guard !candidates.isEmpty else { return .noneAvailable }

        var chosen: AIProviderConfig
        if let min = binding.minCostClass {
            guard let qualified = candidates.first(where: { $0.effectiveCostClass >= min }) else {
                return .refusedBelowMinCost(min: min)
            }
            chosen = qualified
        } else {
            chosen = candidates[0]
        }
        if let timeout = binding.timeoutSeconds {
            chosen.requestTimeout = TimeInterval(timeout)
        }
        return .resolved(chosen)
    }

    // MARK: - Persistence

    private func load() {
        let url = Constants.Engine.rolesYamlURL
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            let result = RolesFile.parse(text)
            bindings = result.bindings
            loadWarnings = result.warnings
            fileModified = Self.modificationDate(of: url)
            return
        }
        bindings = migrateFromLegacyJSON() ?? [:]
        loadWarnings = []
    }

    /// One-time move from Application Support/roles.json (pre-M3 flat
    /// role → provider map).
    private func migrateFromLegacyJSON() -> [EngineRole: RoleBinding]? {
        let legacy = Constants.Engine.legacyRolesFileURL
        guard let data = try? Data(contentsOf: legacy),
              let raw = try? JSONDecoder().decode([String: UUID].self, from: data)
        else { return nil }
        var migrated: [EngineRole: RoleBinding] = [:]
        for (key, value) in raw {
            if let role = EngineRole(rawValue: key) {
                migrated[role] = RoleBinding(provider: value)
            }
        }
        saveToDisk(migrated)
        let backup = legacy.appendingPathExtension("bak")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: legacy, to: backup)
        return migrated
    }

    private func saveToDisk(_ override: [EngineRole: RoleBinding]? = nil) {
        Constants.Engine.ensureDirectoriesExist()
        let url = Constants.Engine.rolesYamlURL
        try? RolesFile.serialize(override ?? bindings)
            .write(to: url, atomically: true, encoding: .utf8)
        fileModified = Self.modificationDate(of: url)
    }

    private nonisolated static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
