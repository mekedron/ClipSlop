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
