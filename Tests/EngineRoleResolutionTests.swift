import Foundation
import Testing
@testable import ClipSlop

@Suite("Engine role resolution")
struct EngineRoleResolutionTests {
    private func provider(
        name: String,
        type: AIProviderType = .anthropic,
        isDefault: Bool = false,
        costClass: ProviderCostClass? = nil
    ) -> AIProviderConfig {
        AIProviderConfig(
            name: name, providerType: type,
            baseURL: type == .anthropic ? Constants.Anthropic.baseURL : nil,
            modelID: "test-model", isDefault: isDefault, costClass: costClass
        )
    }

    private func resolved(_ outcome: RoleResolutionOutcome) -> AIProviderConfig? {
        if case .resolved(let provider) = outcome { return provider }
        return nil
    }

    @Test func boundProviderWins() {
        let bound = provider(name: "Bound")
        let fallback = provider(name: "Default", isDefault: true)
        let outcome = EngineRoleStore.resolve(
            role: .generationMagic,
            binding: RoleBinding(provider: bound.id),
            providers: [fallback, bound]
        )
        #expect(resolved(outcome)?.id == bound.id)
    }

    @Test func staleBindingFallsToDefault() {
        let fallback = provider(name: "Default", isDefault: true)
        let outcome = EngineRoleStore.resolve(
            role: .generationMagic,
            binding: RoleBinding(provider: UUID()),
            providers: [provider(name: "Other"), fallback]
        )
        #expect(resolved(outcome)?.id == fallback.id)
    }

    @Test func emptyBindingUsesDefaultChain() {
        let first = provider(name: "First")
        let outcome = EngineRoleStore.resolve(
            role: .generationMagic, binding: RoleBinding(), providers: [first]
        )
        #expect(resolved(outcome)?.id == first.id)
    }

    @Test func emptyProvidersIsNoneAvailable() {
        let outcome = EngineRoleStore.resolve(
            role: .generationMagic, binding: RoleBinding(), providers: []
        )
        guard case .noneAvailable = outcome else {
            Issue.record("expected noneAvailable, got \(outcome)")
            return
        }
    }

    @Test func explicitFallbackChainBeatsAppDefault() {
        let dead = UUID()  // bound provider was deleted
        let chained = provider(name: "Chained")
        let appDefault = provider(name: "Default", isDefault: true)
        let outcome = EngineRoleStore.resolve(
            role: .generationMagic,
            binding: RoleBinding(provider: dead, fallbacks: [chained.id]),
            providers: [appDefault, chained]
        )
        #expect(resolved(outcome)?.id == chained.id)
    }

    @Test func toolCallingRoleSkipsCLITool() {
        let cli = provider(name: "CLI", type: .cliTool, isDefault: true)
        let capable = provider(name: "Capable")
        let outcome = EngineRoleStore.resolve(
            role: .chatAssistant,
            binding: RoleBinding(provider: cli.id),
            providers: [cli, capable]
        )
        #expect(resolved(outcome)?.id == capable.id)
    }

    @Test func minCostClassRefusesInsteadOfDowngrading() {
        let local = provider(name: "Ollama", type: .ollama, isDefault: true)
        let outcome = EngineRoleStore.resolve(
            role: .generationMagic,
            binding: RoleBinding(minCostClass: .premium),
            providers: [local]
        )
        guard case .refusedBelowMinCost(let min) = outcome else {
            Issue.record("expected refusal, got \(outcome)")
            return
        }
        #expect(min == .premium)
    }

    @Test func minCostClassPicksQualifiedFallback() {
        let local = provider(name: "Ollama", type: .ollama)
        let premium = provider(name: "Anthropic")  // derived premium
        let outcome = EngineRoleStore.resolve(
            role: .generationMagic,
            binding: RoleBinding(provider: local.id, fallbacks: [premium.id], minCostClass: .premium),
            providers: [local, premium]
        )
        #expect(resolved(outcome)?.id == premium.id)
    }

    @Test func timeoutIsStampedOnTheWinner() {
        let bound = provider(name: "Bound", isDefault: true)
        let outcome = EngineRoleStore.resolve(
            role: .generationMagic,
            binding: RoleBinding(provider: bound.id, timeoutSeconds: 45),
            providers: [bound]
        )
        #expect(resolved(outcome)?.requestTimeout == 45)
    }
}
