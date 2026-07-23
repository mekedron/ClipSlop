import Foundation
import Testing
@testable import ClipSlop

@Suite("AI provider config")
struct AIProviderConfigTests {

    @Test("Supported reasoning efforts map to wire values")
    func supportedEffortsAreSent() {
        for type in [AIProviderType.ollama, .openAIChatGPT] {
            for effort in type.supportedReasoningEfforts {
                let config = AIProviderConfig(
                    name: "\(type.rawValue) \(effort.rawValue)",
                    providerType: type,
                    reasoningEffort: effort
                )
                #expect(config.effectiveReasoningEffort == effort.rawValue)
            }
        }
    }

    @Test("Unset reasoning effort omits the field")
    func unsetEffortIsOmitted() {
        var config = AIProviderConfig(name: "Ollama", providerType: .ollama)
        #expect(config.effectiveReasoningEffort == nil)

        config.reasoningEffort = nil
        #expect(config.effectiveReasoningEffort == nil)
    }

    @Test("Providers without reasoning support never send an effort value")
    func unsupportedProvidersDoNotSend() {
        for type in [AIProviderType.openAI, .anthropic, .openAICompatible, .cliTool] {
            let config = AIProviderConfig(
                name: type.rawValue,
                providerType: type,
                reasoningEffort: .high
            )
            #expect(config.effectiveReasoningEffort == nil)
        }
    }

    @Test("Values outside the provider's supported set are not sent")
    func unsupportedValueIsNotSent() {
        var config = AIProviderConfig(name: "ChatGPT", providerType: .openAIChatGPT)
        config.reasoningEffort = .max  // Ollama-only value
        #expect(config.effectiveReasoningEffort == nil)
    }

    @Test("New ChatGPT entries default to low, others to unset")
    func initDefaults() {
        #expect(AIProviderConfig(name: "GPT", providerType: .openAIChatGPT).reasoningEffort == .low)
        #expect(AIProviderConfig(name: "Ollama", providerType: .ollama).reasoningEffort == nil)
        #expect(AIProviderConfig(name: "Claude", providerType: .anthropic).reasoningEffort == nil)
    }

    // MARK: - Stored-format migration

    @Test("Legacy inert reasoningEffort is dropped for non-ChatGPT providers")
    func legacyEffortDroppedForOllama() throws {
        let config = try decode(providerType: "ollama", extraField: "\"reasoningEffort\": \"low\"")
        #expect(config.reasoningEffort == nil)
    }

    @Test("Legacy reasoningEffort is honored for ChatGPT")
    func legacyEffortKeptForChatGPT() throws {
        let config = try decode(providerType: "openAIChatGPT", extraField: "\"reasoningEffort\": \"medium\"")
        #expect(config.reasoningEffort == .medium)
    }

    @Test("Pre-merge ollamaReasoningEffort key migrates to the unified field")
    func ollamaBranchKeyMigrates() throws {
        let none = try decode(providerType: "ollama", extraField: "\"ollamaReasoningEffort\": \"none\"")
        #expect(none.reasoningEffort == ReasoningEffort.none)

        let unset = try decode(providerType: "ollama", extraField: "\"ollamaReasoningEffort\": \"unset\"")
        #expect(unset.reasoningEffort == nil)
    }

    @Test("Unknown stored values degrade to unset instead of failing decode")
    func unknownValueDegrades() throws {
        let config = try decode(providerType: "openAIChatGPT", extraField: "\"reasoningEffortSetting\": \"turbo\"")
        #expect(config.reasoningEffort == nil)
    }

    @Test("Encode/decode round-trip keeps the unified value")
    func roundTrip() throws {
        var original = AIProviderConfig(name: "Ollama", providerType: .ollama)
        original.reasoningEffort = .max

        let data = try JSONEncoder().encode(original)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"reasoningEffortSetting\":\"max\""))
        #expect(!json.contains("\"ollamaReasoningEffort\""))

        let decoded = try JSONDecoder().decode(AIProviderConfig.self, from: data)
        #expect(decoded.reasoningEffort == .max)
    }

    // MARK: - Helpers

    private func decode(providerType: String, extraField: String) throws -> AIProviderConfig {
        let json = """
        {
            "id": "00000000-0000-0000-0000-000000000001",
            "name": "Test",
            "providerType": "\(providerType)",
            "baseURL": "http://localhost:11434",
            "apiKeyRef": "clipslop.api-key.test",
            "modelID": "test-model",
            "isDefault": false,
            "maxTokens": 4096,
            "temperature": 1.0,
            \(extraField)
        }
        """
        return try JSONDecoder().decode(AIProviderConfig.self, from: Data(json.utf8))
    }
}
