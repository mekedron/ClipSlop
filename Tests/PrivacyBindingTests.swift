import Foundation
import Testing
@testable import ClipSlop

@Suite("Privacy binding (no_cloud)")
struct PrivacyBindingTests {
    private let cloud = AIProviderConfig(name: "Anthropic", providerType: .anthropic, isDefault: true)
    private let local = AIProviderConfig(name: "Ollama", providerType: .ollama)

    private func allowed(_ outcome: PrivacyBinding.Outcome) -> AIProviderConfig? {
        if case .allowed(let provider) = outcome { return provider }
        return nil
    }

    @Test func matching() {
        // Bundle-id substring, host exact, host suffix.
        #expect(PrivacyBinding.matchesNoCloud(
            entries: ["telegram"], bundleId: "ru.keepcoder.Telegram", urlHost: nil
        ))
        #expect(PrivacyBinding.matchesNoCloud(
            entries: ["gmail.com"], bundleId: "com.google.Chrome", urlHost: "gmail.com"
        ))
        #expect(PrivacyBinding.matchesNoCloud(
            entries: ["google.com"], bundleId: nil, urlHost: "mail.google.com"
        ))
        // A domain entry must not match an unrelated host that merely
        // contains the string.
        #expect(!PrivacyBinding.matchesNoCloud(
            entries: ["google.com"], bundleId: nil, urlHost: "notgoogle.com"
        ))
        #expect(!PrivacyBinding.matchesNoCloud(
            entries: [], bundleId: "any", urlHost: "any.com"
        ))
    }

    /// Matching folds the ENTRIES too, not just the surface. `MagicEngineConfig`
    /// happens to hand over a lower-cased list today, so this passed by
    /// accident; the point of pinning it is that the method is public and the
    /// failure mode of an unfolded caller is silent — "Telegram" would stop
    /// matching "ru.keepcoder.Telegram" and the surface would quietly lose its
    /// no-cloud protection instead of erroring (P7).
    @Test func entriesAreMatchedCaseInsensitivelyWhateverTheCallerPassed() {
        #expect(PrivacyBinding.matchesNoCloud(
            entries: ["Telegram"], bundleId: "ru.keepcoder.Telegram", urlHost: nil
        ))
        #expect(PrivacyBinding.matchesNoCloud(
            entries: ["GMail.com"], bundleId: nil, urlHost: "mail.gmail.com"
        ))
        // And the refusal path sees the same match: an unfolded entry must not
        // let a cloud provider serve a protected surface.
        let outcome = PrivacyBinding.enforce(
            resolved: cloud, binding: RoleBinding(), providers: [cloud],
            noCloud: ["TextEdit"], bundleId: "com.apple.TextEdit", urlHost: nil
        )
        guard case .refused = outcome else {
            Issue.record("expected refusal, got allowed")
            return
        }
    }

    @Test func nonMatchingSurfacePassesThrough() {
        let outcome = PrivacyBinding.enforce(
            resolved: cloud, binding: RoleBinding(), providers: [cloud, local],
            noCloud: ["telegram"], bundleId: "com.apple.TextEdit", urlHost: nil
        )
        #expect(allowed(outcome)?.id == cloud.id)
    }

    @Test func matchingSurfaceSwapsToLocalProvider() {
        let outcome = PrivacyBinding.enforce(
            resolved: cloud, binding: RoleBinding(timeoutSeconds: 30), providers: [cloud, local],
            noCloud: ["textedit"], bundleId: "com.apple.TextEdit", urlHost: nil
        )
        #expect(allowed(outcome)?.id == local.id)
        // The role's timeout survives the swap.
        #expect(allowed(outcome)?.requestTimeout == 30)
    }

    @Test func localProviderNeedsNoSwap() {
        let outcome = PrivacyBinding.enforce(
            resolved: local, binding: RoleBinding(), providers: [cloud, local],
            noCloud: ["textedit"], bundleId: "com.apple.TextEdit", urlHost: nil
        )
        #expect(allowed(outcome)?.id == local.id)
    }

    @Test func refusesWhenNoLocalProviderExists() {
        let outcome = PrivacyBinding.enforce(
            resolved: cloud, binding: RoleBinding(), providers: [cloud],
            noCloud: ["textedit"], bundleId: "com.apple.TextEdit", urlHost: nil
        )
        guard case .refused = outcome else {
            Issue.record("expected refusal, got allowed")
            return
        }
    }

    /// A domain rule can only be honoured when the host is known, and on a web
    /// surface the host comes from an AX read that is allowed to fail. Left
    /// alone that is a silent fail-open: the page the user marked no-cloud goes
    /// to a cloud provider and nothing anywhere records that the rule was
    /// skipped. So an unreadable host is treated as a host that might match.
    @Test func unreadableWebHostTakesTheProtectedPath() {
        // Nothing changes when the host IS readable and simply does not match.
        #expect(!PrivacyBinding.matchesNoCloud(
            entries: ["gmail.com"], bundleId: "com.google.Chrome", urlHost: "example.com",
            webSurfaceWithUnknownHost: false
        ))
        // Unreadable host + a rule that could be a domain → protected.
        #expect(PrivacyBinding.matchesNoCloud(
            entries: ["gmail.com"], bundleId: "com.google.Chrome", urlHost: nil,
            webSurfaceWithUnknownHost: true
        ))
        // Narrowed by the one rule that cannot decay: a single-label entry is a
        // bundle-id substring by construction, and would have matched above if
        // it applied to this app. It must not refuse every browser press.
        #expect(!PrivacyBinding.matchesNoCloud(
            entries: ["telegram"], bundleId: "com.google.Chrome", urlHost: nil,
            webSurfaceWithUnknownHost: true
        ))
        // A native app with an unreadable URL is not a web surface at all —
        // there was never a domain rule to honour, so nothing is withheld.
        #expect(!PrivacyBinding.matchesNoCloud(
            entries: ["gmail.com"], bundleId: "com.apple.TextEdit", urlHost: nil,
            webSurfaceWithUnknownHost: false
        ))
        // An empty list is still an empty list: the guard may not invent a rule.
        #expect(!PrivacyBinding.matchesNoCloud(
            entries: [], bundleId: "com.google.Chrome", urlHost: nil,
            webSurfaceWithUnknownHost: true
        ))
        // And the swap really happens on the enforce path, rather than the
        // match being reported and then ignored.
        let outcome = PrivacyBinding.enforce(
            resolved: cloud, binding: RoleBinding(), providers: [cloud, local],
            noCloud: ["gmail.com"], bundleId: "com.google.Chrome", urlHost: nil,
            webSurfaceWithUnknownHost: true
        )
        #expect(allowed(outcome)?.id == local.id)
    }

    /// `EngineRouter.urlHost` drops a leading "www." before anything compares
    /// hosts, so an entry carrying one has to lose it too. "www.gmail.com" is
    /// what a user copies out of the address bar, and left unfolded it is a
    /// privacy rule that can never fire and never says why.
    @Test func entriesDropTheirOwnWWWPrefix() {
        #expect(PrivacyBinding.matchesNoCloud(
            entries: ["www.gmail.com"], bundleId: nil, urlHost: "gmail.com"
        ))
        #expect(PrivacyBinding.matchesNoCloud(
            entries: ["www.google.com"], bundleId: nil, urlHost: "mail.google.com"
        ))
        // Still not a substring match: the suffix rule survives the fold.
        #expect(!PrivacyBinding.matchesNoCloud(
            entries: ["www.google.com"], bundleId: nil, urlHost: "notgoogle.com"
        ))
    }

    /// The dry run sends nothing, so it does not need the binding to be safe —
    /// it needs it to be honest. Reporting the role's configured cloud provider
    /// on a surface where a real press refuses, or swaps to a local one, is a
    /// diagnostic that misleads on the only surface where the answer matters.
    @Test func dryRunReportsThePrivacyVerdictAndTheProviderAPressWouldUse() throws {
        let (workflows, _) = try MagicTestSupport.seedCatalog()
        func plan(_ providers: [AIProviderConfig]) -> MagicPressPlan {
            var plan = MagicPressPlan(
                catalog: WorkflowCatalog(
                    workflows: workflows, loadedAt: Date(timeIntervalSince1970: 0)
                ),
                core: .empty,
                provider: cloud,
                workflowLoadErrors: []
            )
            plan.providers = providers
            plan.noCloud = ["textedit"]
            return plan
        }
        let onProtectedSurface = MagicTestSupport.makeSnapshot(
            bundleId: "com.apple.TextEdit", value: "a draft to continue"
        )
        let elsewhere = MagicTestSupport.makeSnapshot(
            bundleId: "com.example.other", value: "a draft to continue"
        )

        // A local provider in the pool: the press would swap, so the report
        // names the substitute rather than the binding's own provider.
        let swapped = try #require(MagicPressPipeline.dryRun(
            plan: plan([cloud, local]), snapshot: onProtectedSurface
        ))
        #expect(swapped.privacy == "no_cloud:local_substitute")
        #expect(swapped.providerName == local.name)

        // Nothing local to swap to: the press refuses (P9), and so does the
        // report — naming the binding that could not serve the surface.
        let refused = try #require(MagicPressPipeline.dryRun(
            plan: plan([cloud]), snapshot: onProtectedSurface
        ))
        #expect(refused.privacy == "no_cloud:refused")
        #expect(refused.providerName == cloud.name)

        // An unprotected surface is unchanged.
        let allowed = try #require(MagicPressPipeline.dryRun(
            plan: plan([cloud, local]), snapshot: elsewhere
        ))
        #expect(allowed.privacy == "allowed")
        #expect(allowed.providerName == cloud.name)
    }

    @Test func costFloorStillHoldsDuringSwap() {
        // The only local provider sits below the role's min cost class →
        // refuse rather than silently degrade (P9 beats convenience).
        let outcome = PrivacyBinding.enforce(
            resolved: cloud, binding: RoleBinding(minCostClass: .premium),
            providers: [cloud, local],
            noCloud: ["textedit"], bundleId: "com.apple.TextEdit", urlHost: nil
        )
        guard case .refused = outcome else {
            Issue.record("expected refusal, got allowed")
            return
        }
    }
}
