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
    ///
    /// All three sides are folded here, entries included. Today every entry
    /// arrives already folded — `MagicEngineConfig.normalized` lower-cases the
    /// list as it parses config.yaml — so folding again looks like duplication.
    /// It is not: this method is the only place that decides whether a surface
    /// is protected, it is public, and it already has two callers
    /// (`enforce` below and `MagicPlanner.resolveProvider`). A third one that
    /// hands over a list from somewhere the parser never touched — a tool
    /// argument, a test fixture, a future settings path — would not fail
    /// loudly: a "Telegram" entry simply stops matching "ru.keepcoder.Telegram"
    /// and privacy switches itself off in silence for that surface. The cost of
    /// the invariant living here is one `lowercased()` per entry per press; the
    /// cost of it living in the caller is protected screen content sent to a
    /// cloud provider with nothing to notice it (§14, P7).
    static func matchesNoCloud(
        entries: [String],
        bundleId: String?,
        urlHost: String?,
        webSurfaceWithUnknownHost: Bool = false
    ) -> Bool {
        guard !entries.isEmpty else { return false }
        let bundle = bundleId?.lowercased()
        let host = urlHost?.lowercased()
        let matched = entries.contains { rawEntry in
            let entry = rawEntry.lowercased()
            if let bundle, bundle.contains(entry) { return true }
            // `EngineRouter.urlHost` hands over the host with a leading "www."
            // already dropped, so an entry carrying one has to lose it too —
            // otherwise "www.gmail.com", which is what a user copies out of the
            // address bar, is a rule that can never fire and never says so.
            let hostEntry = entry.hasPrefix("www.") ? String(entry.dropFirst(4)) : entry
            if let host, host == hostEntry || host.hasSuffix("." + hostEntry) { return true }
            return false
        }
        if matched { return true }
        return protectedByUnreadableHost(entries: entries, webSurfaceWithUnknownHost: webSurfaceWithUnknownHost)
    }

    /// The fail-open this closes: a domain rule can only be honoured when the
    /// host is known, and on a web surface the host comes from an `AXURL` /
    /// `AXDocument` read that is allowed to fail — a page whose tree has not
    /// been built yet, a capture that spent its budget, an app that publishes
    /// no URL at all. `urlHost` is then nil, no domain entry matches, and the
    /// press goes to a cloud provider carrying the very page the user marked
    /// no-cloud, with nothing anywhere recording that the rule was skipped.
    ///
    /// So an unreadable host on a web surface is treated as a host that MIGHT
    /// match, and the press takes the protected path: a local provider from the
    /// chain, or an honest refusal (P9). Over-refusing is visible and one
    /// keypress from being understood; under-protecting is silent and permanent.
    ///
    /// Deliberately over-inclusive, and narrowed by exactly one rule that
    /// cannot decay: only entries containing a '.' can be domain rules. A
    /// single-label entry is a bundle-id substring by construction — "telegram"
    /// hitting "ru.keepcoder.Telegram" is the documented shorthand — and it
    /// would have matched above if it applied to this app. Reverse-DNS bundle
    /// ids and hostnames are otherwise indistinguishable as strings, so a
    /// dotted bundle-id rule for a DIFFERENT app does protect browser presses
    /// whose URL could not be read. That is the cost of the guard, and it is
    /// the direction to be wrong in.
    private static func protectedByUnreadableHost(
        entries: [String], webSurfaceWithUnknownHost: Bool
    ) -> Bool {
        guard webSurfaceWithUnknownHost else { return false }
        return entries.contains { $0.contains(".") }
    }

    /// The one place that decides whether a snapshot is a web surface whose
    /// host could not be read, so the press path and the planner cannot drift
    /// into disagreeing about it.
    ///
    /// `AXWebArea` among the ancestor roles is the same walk that reads the
    /// URL (`AXSnapshotService` takes both from the ancestor spine), so a web
    /// surface with no host here means every one of those reads — the web
    /// area's, the window's, and the warm collector's backfill — came back
    /// empty.
    static func hasUnreadableWebHost(_ snapshot: MagicSnapshot) -> Bool {
        snapshot.ancestorRoles.contains("AXWebArea")
            && EngineRouter.urlHost(of: snapshot.url) == nil
    }

    static func enforce(
        resolved: AIProviderConfig,
        binding: RoleBinding,
        providers: [AIProviderConfig],
        noCloud: [String],
        bundleId: String?,
        urlHost: String?,
        webSurfaceWithUnknownHost: Bool = false
    ) -> Outcome {
        guard matchesNoCloud(
            entries: noCloud, bundleId: bundleId, urlHost: urlHost,
            webSurfaceWithUnknownHost: webSurfaceWithUnknownHost
        ) else {
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
