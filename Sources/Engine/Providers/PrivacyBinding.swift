import Foundation

/// Provenance-aware privacy binding (§14, P7): presses in apps/domains the
/// user marked `no_cloud` are served only by `locality: local` providers.
/// When the resolved provider is cloud, the role's chain is scanned for a
/// local one; if none qualifies the press is refused honestly (P9) — never
/// a silent send, never a silent downgrade below the role's cost floor.
enum PrivacyBinding {
    enum Outcome: Sendable {
        case allowed(AIProviderConfig)
        /// The surface is no-cloud and no local provider can serve the role.
        case refused
    }

    /// True when the press's surface matches an entry of the `no_cloud`
    /// list. Entries match a substring of the bundle id ("telegram" hits
    /// "ru.keepcoder.Telegram") or the URL host exactly / by suffix
    /// ("google.com" hits "mail.google.com").
    static func matchesNoCloud(entries: [String], bundleId: String?, urlHost: String?) -> Bool {
        guard !entries.isEmpty else { return false }
        let bundle = bundleId?.lowercased()
        let host = urlHost?.lowercased()
        return entries.contains { entry in
            if let bundle, bundle.contains(entry) { return true }
            if let host, host == entry || host.hasSuffix("." + entry) { return true }
            return false
        }
    }

    static func enforce(
        resolved: AIProviderConfig,
        binding: RoleBinding,
        providers: [AIProviderConfig],
        noCloud: [String],
        bundleId: String?,
        urlHost: String?
    ) -> Outcome {
        guard matchesNoCloud(entries: noCloud, bundleId: bundleId, urlHost: urlHost) else {
            return .allowed(resolved)
        }
        if resolved.effectiveLocality == .local { return .allowed(resolved) }

        // Chain order first, then any other configured local provider —
        // locality is the hard constraint here, the cost floor still holds.
        var candidates: [AIProviderConfig] = []
        var seen = Set<UUID>()
        func add(_ provider: AIProviderConfig?) {
            guard let provider, seen.insert(provider.id).inserted else { return }
            candidates.append(provider)
        }
        add(binding.provider.flatMap { id in providers.first { $0.id == id } })
        for id in binding.fallbacks { add(providers.first { $0.id == id }) }
        for provider in providers { add(provider) }

        let qualified = candidates.first { candidate in
            candidate.effectiveLocality == .local
                && (binding.minCostClass.map { candidate.effectiveCostClass >= $0 } ?? true)
        }
        guard var local = qualified else { return .refused }
        if let timeout = binding.timeoutSeconds {
            local.requestTimeout = TimeInterval(timeout)
        }
        return .allowed(local)
    }
}
