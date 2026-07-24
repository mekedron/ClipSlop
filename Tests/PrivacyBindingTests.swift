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
