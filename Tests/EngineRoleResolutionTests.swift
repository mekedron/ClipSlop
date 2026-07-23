import Foundation
import Testing
@testable import ClipSlop

@Suite("Engine role resolution")
struct EngineRoleResolutionTests {
    private func provider(name: String, isDefault: Bool = false) -> AIProviderConfig {
        AIProviderConfig(
            name: name, providerType: .anthropic,
            baseURL: Constants.Anthropic.baseURL,
            modelID: "claude-sonnet-4", isDefault: isDefault
        )
    }

    @Test func mappedProviderWins() {
        let mapped = provider(name: "Mapped")
        let fallback = provider(name: "Default", isDefault: true)
        let resolved = EngineRoleStore.resolve(
            role: .generationMagic,
            mapping: [.generationMagic: mapped.id],
            providers: [fallback, mapped]
        )
        #expect(resolved?.id == mapped.id)
    }

    @Test func staleMappingFallsToDefault() {
        let fallback = provider(name: "Default", isDefault: true)
        let resolved = EngineRoleStore.resolve(
            role: .generationMagic,
            mapping: [.generationMagic: UUID()],
            providers: [provider(name: "Other"), fallback]
        )
        #expect(resolved?.id == fallback.id)
    }

    @Test func noMappingUsesDefaultChain() {
        let first = provider(name: "First")
        let resolved = EngineRoleStore.resolve(
            role: .generationMagic, mapping: [:], providers: [first]
        )
        #expect(resolved?.id == first.id)
    }

    @Test func emptyProvidersResolvesToNil() {
        #expect(EngineRoleStore.resolve(role: .generationMagic, mapping: [:], providers: []) == nil)
    }
}
