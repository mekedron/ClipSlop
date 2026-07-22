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
