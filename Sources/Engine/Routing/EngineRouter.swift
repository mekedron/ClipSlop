import Foundation

/// The router's answer for one press: what matched, at which tier, and
/// whether the press may proceed silently or must show chips.
struct RoutingDecision: Sendable {
    /// Candidates at the highest matching tier, deduplicated by primary
    /// intent (two workflows that both mean "continue" are ranking, not
    /// ambiguity), ranked best-first.
    let counted: [ResolvedWorkflow]
    /// Everything else that matched — lower tiers and same-intent runners-up.
    /// Chip panels draw extra options from here; never counted as ambiguity.
    let alternatives: [ResolvedWorkflow]
    let tier: MatchTier
    let presentation: Presentation
    /// Coarse situation key for traces, e.g. "exact/linkedin.com/empty".
    let situationClass: String

    enum Presentation: Sendable {
        case silent(chosen: ResolvedWorkflow)
        case chips(ranked: [ResolvedWorkflow])
    }

    /// Ranked list for a chip panel (also used by the forced-chips
    /// override): counted first, then alternatives, capped at 4 — and
    /// deduplicated by *primary intent*, not id: `instruct.selection` and
    /// its `base.instruct` parent mean the same thing and carry the same
    /// summary, so showing both reads as two identical buttons.
    var chipCandidates: [ResolvedWorkflow] {
        var seenIntents = Set<String>()
        var result: [ResolvedWorkflow] = []
        for workflow in counted + alternatives {
            let intent = workflow.card.intents.first ?? workflow.id
            guard seenIntents.insert(intent).inserted else { continue }
            result.append(workflow)
            if result.count == 4 { break }
        }
        return result
    }

    var top: ResolvedWorkflow? { counted.first ?? alternatives.first }
}

/// Deterministic tiered matching (§6.1) plus the fixed V0 silent-vs-chips
/// rule (§3.3 day-0 form — no self-tuning, no logged-accuracy gate).
enum EngineRouter {
    static func route(
        catalog: WorkflowCatalog,
        snapshot: MagicSnapshot,
        classification: SelectionClassification?
    ) -> RoutingDecision {
        // Cards without `when:` never enter routing (§7.3): they are
        // deterministic workflows — library prompts and other id/uuid-bound
        // cards — with no situation predicate to match. Every routable seed
        // declares an explicit `when:`.
        let matches = catalog.workflows.filter {
            $0.card.when != nil
                && matchesWhen($0.card.when, snapshot: snapshot, classification: classification)
        }

        let topTier = matches.map(\.card.tier).max() ?? .base
        let topTierMatches = matches.filter { $0.card.tier == topTier }
        let lowerTierMatches = matches.filter { $0.card.tier != topTier }

        let ranked = rank(topTierMatches, snapshot: snapshot)

        // Dedup by primary intent: ambiguity means "the press could *mean*
        // different things", not "several files implement the same thing".
        var counted: [ResolvedWorkflow] = []
        var runnersUp: [ResolvedWorkflow] = []
        var seenIntents = Set<String>()
        for workflow in ranked {
            let intent = workflow.card.intents.first ?? workflow.id
            if seenIntents.insert(intent).inserted {
                counted.append(workflow)
            } else {
                runnersUp.append(workflow)
            }
        }

        let alternatives = runnersUp + rank(lowerTierMatches, snapshot: snapshot)

        // Fixed structural rule: silent iff exactly one counted candidate and
        // the selection classification (when there is one) was decisive.
        var decision = RoutingDecision(
            counted: counted,
            alternatives: alternatives,
            tier: topTier,
            presentation: .chips(ranked: []),
            situationClass: situationClass(
                tier: topTier, snapshot: snapshot, classification: classification
            )
        )
        // A context-blind press (no surroundings, empty field — the app gave
        // us nothing to read) never proceeds silently: the model has no
        // grounding, so the user must steer with a chip or a hint.
        if counted.count == 1, classification?.isTie != true, !snapshot.contextBlind {
            decision = RoutingDecision(
                counted: counted, alternatives: alternatives, tier: topTier,
                presentation: .silent(chosen: counted[0]),
                situationClass: decision.situationClass
            )
        } else {
            decision = RoutingDecision(
                counted: counted, alternatives: alternatives, tier: topTier,
                presentation: .chips(ranked: decision.chipCandidates),
                situationClass: decision.situationClass
            )
        }
        return decision
    }

    // MARK: - Predicate matching

    static func matchesWhen(
        _ when: WhenPredicate?,
        snapshot: MagicSnapshot,
        classification: SelectionClassification?
    ) -> Bool {
        guard let when else { return true }

        if let apps = when.apps {
            guard let bundleId = snapshot.app.bundleId, apps.contains(bundleId) else { return false }
        }
        if let pattern = when.urlPattern {
            guard let url = snapshot.url,
                  let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil
            else { return false }
        }
        if let roles = when.fieldRoles {
            guard let role = snapshot.field?.role,
                  roles.contains(where: { $0.caseInsensitiveCompare(role) == .orderedSame })
            else { return false }
        }
        if let states = when.fieldStates {
            guard states.contains(snapshot.fieldState) else { return false }
        }
        if let classes = when.selectionClasses {
            guard let top = classification?.top, classes.contains(top) else { return false }
        }
        return true
    }

    // MARK: - Ranking

    /// Priority first; then a contextual nudge for the empty-field base pair
    /// (a visible conversation favors "reply", a blank context favors
    /// "write"); id last for determinism.
    private static func rank(
        _ workflows: [ResolvedWorkflow], snapshot: MagicSnapshot
    ) -> [ResolvedWorkflow] {
        let hasSurroundings = !(snapshot.surrounding?.content.isEmpty ?? true)

        func contextBoost(_ workflow: ResolvedWorkflow) -> Int {
            guard snapshot.fieldState == .empty else { return 0 }
            let intent = workflow.card.intents.first
            if intent == "reply" { return hasSurroundings ? 1 : 0 }
            if intent == "write" { return hasSurroundings ? 0 : 1 }
            return 0
        }

        return workflows.sorted { lhs, rhs in
            if lhs.card.priority != rhs.card.priority { return lhs.card.priority > rhs.card.priority }
            let lhsBoost = contextBoost(lhs), rhsBoost = contextBoost(rhs)
            if lhsBoost != rhsBoost { return lhsBoost > rhsBoost }
            return lhs.id < rhs.id
        }
    }

    // MARK: - Situation class

    static func situationClass(
        tier: MatchTier,
        snapshot: MagicSnapshot,
        classification: SelectionClassification?
    ) -> String {
        let location = urlHost(of: snapshot.url) ?? snapshot.app.bundleId ?? "unknown"
        var state = snapshot.fieldState.rawValue
        if let top = classification?.top, snapshot.fieldState == .selection {
            state += ".\(top.rawValue)"
        }
        return "\(tier)/\(location)/\(state)"
    }

    static func urlHost(of url: String?) -> String? {
        guard let url, let host = URL(string: url)?.host() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
