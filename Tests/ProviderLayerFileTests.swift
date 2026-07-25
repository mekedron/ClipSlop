import Foundation
import Testing
@testable import ClipSlop

@Suite("providers.yaml codec")
struct ProvidersFileTests {
    @Test func roundTripPreservesEveryField() {
        let providers = [
            AIProviderConfig(
                name: "Anthropic \"Main\"", providerType: .anthropic,
                modelID: "claude-sonnet-5", isDefault: true,
                maxTokens: 2_048, temperature: 0.3
            ),
            AIProviderConfig(
                name: "Local Llama", providerType: .ollama,
                modelID: "llama3.2", reasoningEffort: .high,
                locality: .local, costClass: .local
            ),
            AIProviderConfig(name: "ChatGPT", providerType: .openAIChatGPT),
        ]
        let result = ProvidersFile.parse(ProvidersFile.serialize(providers))
        #expect(result.warnings.isEmpty, "warnings: \(result.warnings)")
        #expect(result.providers == providers)
    }

    @Test func emptyListRoundTrips() {
        let result = ProvidersFile.parse(ProvidersFile.serialize([]))
        #expect(result.providers.isEmpty)
        #expect(result.warnings.isEmpty)
    }

    @Test func brokenRecordIsSkippedWithWarningOthersSurvive() {
        let good = AIProviderConfig(name: "Good", providerType: .anthropic, isDefault: true)
        let text = """
        ---
        providers:
          - id: not-a-uuid
            name: "Broken"
            type: anthropic
          - id: \(good.id.uuidString)
            name: "Good"
            type: anthropic
            max_tokens: \(good.maxTokens)
            temperature: \(good.temperature)
            default: 1
        ---
        """
        let result = ProvidersFile.parse(text)
        #expect(result.providers.count == 1)
        #expect(result.providers.first?.name == "Good")
        #expect(result.warnings.count == 1)
        #expect(result.warnings[0].contains("id"))
    }

    @Test func unknownTypeAndKeysWarn() {
        let id = UUID().uuidString
        let result = ProvidersFile.parse("""
        ---
        providers:
          - id: \(id)
            type: skynet
          - id: \(UUID().uuidString)
            type: anthropic
            favourite_color: blue
        ---
        """)
        #expect(result.providers.count == 1)
        #expect(result.warnings.contains { $0.contains("skynet") })
        #expect(result.warnings.contains { $0.contains("favourite_color") })
    }

    /// `max_tokens: -1` / `: 0` used to be copied straight into the config and
    /// put on the wire, so every generation failed at the API — from a file the
    /// app advertises as validated and hot-reloaded.
    @Test func nonPositiveMaxTokensIsRejectedAndTheDefaultKept() {
        for bad in ["-1", "0", "nine", "99999999"] {
            let result = ProvidersFile.parse("""
            ---
            providers:
              - id: \(UUID().uuidString)
                type: anthropic
                max_tokens: \(bad)
            ---
            """)
            #expect(result.providers.count == 1)
            #expect(result.providers[0].maxTokens == Constants.Defaults.maxTokens)
            #expect(result.warnings.contains { $0.contains("max_tokens") }, "no warning for '\(bad)'")
        }

        let ok = ProvidersFile.parse("""
        ---
        providers:
          - id: \(UUID().uuidString)
            type: anthropic
            max_tokens: 8192
        ---
        """)
        #expect(ok.providers[0].maxTokens == 8192)
        #expect(ok.warnings.isEmpty)
    }

    /// The legacy providers.json is the only copy of this configuration until
    /// providers.yaml is verifiably on disk; an atomic write reports success
    /// from the rename, not from the bytes.
    @Test func providerMigrationVerificationCatchesALostWrite() {
        let configs = [
            AIProviderConfig(name: "A", providerType: .anthropic, isDefault: true),
            AIProviderConfig(name: "B", providerType: .ollama),
        ]
        #expect(ProviderStore.migrationRoundTrips(ProvidersFile.serialize(configs), expected: configs))
        #expect(!ProviderStore.migrationRoundTrips("", expected: configs))
        #expect(!ProviderStore.migrationRoundTrips(ProvidersFile.serialize([configs[0]]), expected: configs))
    }

    @Test func secondDefaultIsDemotedWithWarning() {
        var a = AIProviderConfig(name: "A", providerType: .anthropic, isDefault: true)
        var b = AIProviderConfig(name: "B", providerType: .openAI, isDefault: true)
        let result = ProvidersFile.parse(ProvidersFile.serialize([a, b]))
        #expect(result.warnings.count == 1)
        #expect(result.providers.filter(\.isDefault).count == 1)
        a.isDefault = true
        b.isDefault = false
        #expect(result.providers == [a, b])
    }

    @Test func localityAndCostClassDerivation() {
        #expect(AIProviderConfig(name: "o", providerType: .ollama).effectiveLocality == .local)
        #expect(AIProviderConfig(name: "a", providerType: .anthropic).effectiveLocality == .cloud)
        // CLI tools run locally but call cloud APIs — data-path locality.
        #expect(AIProviderConfig(name: "c", providerType: .cliTool).effectiveLocality == .cloud)
        #expect(AIProviderConfig(
            name: "x", providerType: .openAICompatible, baseURL: "http://localhost:8080/v1"
        ).effectiveLocality == .local)

        #expect(AIProviderConfig(name: "a", providerType: .anthropic).effectiveCostClass == .premium)
        #expect(AIProviderConfig(name: "o", providerType: .ollama).effectiveCostClass == .local)
        // Explicit override beats derivation.
        #expect(AIProviderConfig(
            name: "a", providerType: .anthropic, locality: .local
        ).effectiveLocality == .local)
    }
}

@Suite("roles.yaml codec")
struct RolesFileTests {
    @Test func roundTripPreservesBindings() {
        let bindings: [EngineRole: RoleBinding] = [
            .generationMagic: RoleBinding(
                provider: UUID(), fallbacks: [UUID(), UUID()],
                timeoutSeconds: 60, minCostClass: .premium
            ),
            .chatAssistant: RoleBinding(provider: UUID()),
        ]
        let result = RolesFile.parse(RolesFile.serialize(bindings))
        #expect(result.warnings.isEmpty, "warnings: \(result.warnings)")
        #expect(result.bindings == bindings)
    }

    @Test func emptyBindingsRoundTrip() {
        let result = RolesFile.parse(RolesFile.serialize([:]))
        #expect(result.bindings.isEmpty)
        #expect(result.warnings.isEmpty)
    }

    /// Same contract as the provider migration: roles.json only retires once
    /// roles.yaml reads back with every binding intact.
    @Test func roleMigrationVerificationCatchesALostWrite() {
        let bindings: [EngineRole: RoleBinding] = [
            .generationMagic: RoleBinding(provider: UUID()),
            .chatAssistant: RoleBinding(provider: UUID()),
        ]
        #expect(EngineRoleStore.migrationRoundTrips(RolesFile.serialize(bindings), expected: bindings))
        #expect(!EngineRoleStore.migrationRoundTrips("", expected: bindings))
        #expect(!EngineRoleStore.migrationRoundTrips(RolesFile.serialize([:]), expected: bindings))
    }

    @Test func unknownRoleSkippedBadValuesIgnoredWithWarnings() {
        let id = UUID().uuidString
        let result = RolesFile.parse("""
        ---
        roles:
          - role: time.travel
            provider: \(id)
          - role: generation.magic
            provider: \(id)
            timeout_seconds: 9000
            min_cost_class: platinum
        ---
        """)
        #expect(result.bindings.count == 1)
        let binding = result.bindings[.generationMagic]
        #expect(binding?.provider?.uuidString == id)
        #expect(binding?.timeoutSeconds == nil)
        #expect(binding?.minCostClass == nil)
        #expect(result.warnings.count == 3)
    }
}
