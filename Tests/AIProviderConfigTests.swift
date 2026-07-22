import Foundation
import Testing
@testable import ClipSlop

@Suite("AI provider config")
struct AIProviderConfigTests {

    @Test("Ollama reasoning effort maps to OpenAI-compatible request values")
    func ollamaReasoningEffort() {
        let unset = AIProviderConfig(
            name: "Ollama default",
            providerType: .ollama,
            ollamaReasoningEffort: .unset
        )
        #expect(unset.ollamaOpenAICompatibleReasoningEffort == nil)

        for effort in [OllamaReasoningEffort.none, .low, .medium, .high, .max] {
            let config = AIProviderConfig(
                name: "Ollama \(effort.rawValue)",
                providerType: .ollama,
                ollamaReasoningEffort: effort
            )

            #expect(config.ollamaOpenAICompatibleReasoningEffort == effort.rawValue)
        }
    }

    @Test("Ollama reasoning effort defaults to unset for existing provider entries")
    func ollamaReasoningEffortDefault() {
        let config = AIProviderConfig(
            name: "Ollama",
            providerType: .ollama,
            ollamaReasoningEffort: nil
        )

        #expect(config.ollamaOpenAICompatibleReasoningEffort == nil)
    }

    @Test("Legacy Ollama thinking settings decode to matching reasoning effort")
    func legacyOllamaThinkingDecode() throws {
        let id = UUID()
        let json = """
        {
          "id": "\(id.uuidString)",
          "name": "Ollama",
          "providerType": "ollama",
          "baseURL": "http://localhost:11434",
          "apiKeyRef": "clipslop.api-key.\(id.uuidString)",
          "modelID": "llama3.2",
          "isDefault": false,
          "maxTokens": 4096,
          "temperature": 1,
          "ollamaThinkingEnabled": false
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(AIProviderConfig.self, from: json)

        #expect(config.ollamaReasoningEffort == OllamaReasoningEffort.none)
        #expect(config.ollamaOpenAICompatibleReasoningEffort == "none")
    }

    @Test("Non-Ollama providers do not receive Ollama reasoning overrides")
    func nonOllamaThinking() {
        let config = AIProviderConfig(
            name: "OpenAI",
            providerType: .openAI,
            ollamaReasoningEffort: OllamaReasoningEffort.none
        )

        #expect(config.ollamaOpenAICompatibleReasoningEffort == nil)
    }
}
