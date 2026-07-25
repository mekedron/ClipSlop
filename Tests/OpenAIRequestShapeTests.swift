import Foundation
import Testing
@testable import ClipSlop

@Suite("OpenAI request shape")
struct OpenAIRequestShapeTests {

    private func openAI(model: String, temperature: Double = 1.0) -> AIProviderConfig {
        AIProviderConfig(
            name: "OpenAI",
            providerType: .openAI,
            modelID: model,
            temperature: temperature
        )
    }

    // MARK: - Opening guess

    @Test("OpenAI's own host always gets the new token-limit spelling")
    func openAIHostUsesMaxCompletionTokens() {
        for model in ["gpt-4o", "gpt-4.1-mini", "gpt-5", "o3", "o4-mini"] {
            let shape = OpenAIRequestShape.starting(for: openAI(model: model))
            #expect(shape.tokenLimitKey == OpenAIRequestShape.maxCompletionTokensKey)
        }
    }

    @Test("Servers that only imitate the API get the original spelling")
    func otherHostsUseMaxTokens() {
        let ollama = AIProviderConfig(name: "Ollama", providerType: .ollama, modelID: "llama3.2")
        #expect(OpenAIRequestShape.starting(for: ollama).tokenLimitKey
            == OpenAIRequestShape.maxTokensKey)

        let compatible = AIProviderConfig(
            name: "Groq",
            providerType: .openAICompatible,
            baseURL: "https://api.groq.com/openai",
            modelID: "llama-3.3-70b"
        )
        #expect(OpenAIRequestShape.starting(for: compatible).tokenLimitKey
            == OpenAIRequestShape.maxTokensKey)
    }

    @Test("A compatible entry aimed at OpenAI is treated as OpenAI")
    func compatibleEntryOnOpenAIHost() {
        let config = AIProviderConfig(
            name: "Manual",
            providerType: .openAICompatible,
            baseURL: "https://api.openai.com",
            modelID: "gpt-5"
        )
        #expect(OpenAIRequestShape.isOpenAIHosted(config))
        #expect(OpenAIRequestShape.starting(for: config).sendsTemperature == false)
    }

    @Test("Reasoning families are recognised by the shape of the id")
    func reasoningFamilyDetection() {
        for model in ["o1", "o1-mini", "o3", "o3-mini", "o4-mini", "gpt-5", "gpt-5.1-codex", "gpt-6"] {
            #expect(OpenAIRequestShape.isReasoningModel(model), "\(model) is a reasoning model")
        }
        for model in ["gpt-4o", "gpt-4.1", "gpt-3.5-turbo", "omni-moderation-latest", "gpt-oss-120b"] {
            #expect(!OpenAIRequestShape.isReasoningModel(model), "\(model) is not a reasoning model")
        }
    }

    @Test("A route prefix does not hide the family")
    func routePrefixIsStripped() {
        #expect(OpenAIRequestShape.normalizedModelID("openai/GPT-5") == "gpt-5")
        #expect(OpenAIRequestShape.isReasoningModel(OpenAIRequestShape.normalizedModelID("openai/gpt-5")))
    }

    @Test("Only the models without a system role fold the prompt into the user turn")
    func systemRolePlacement() {
        #expect(OpenAIRequestShape.starting(for: openAI(model: "gpt-5")).systemRole == "system")
        #expect(OpenAIRequestShape.starting(for: openAI(model: "o1-mini")).systemRole == nil)

        let folded = OpenAIRequestShape.starting(for: openAI(model: "o1-preview"))
        #expect(folded.systemMessage("Be brief") == nil)
        #expect(folded.firstUserText("Hello", systemPrompt: "Be brief") == "Be brief\n\nHello")

        let kept = OpenAIRequestShape.starting(for: openAI(model: "gpt-4o"))
        #expect(kept.systemMessage("Be brief") != nil)
        #expect(kept.firstUserText("Hello", systemPrompt: "Be brief") == "Hello")
    }

    // MARK: - Emitted parameters

    @Test("The default temperature is never sent")
    func defaultTemperatureOmitted() {
        let config = openAI(model: "gpt-4o", temperature: 1.0)
        let parameters = OpenAIRequestShape.starting(for: config).tuningParameters(for: config)
        #expect(parameters["temperature"] == nil)
        #expect(parameters[OpenAIRequestShape.maxCompletionTokensKey] == .int(config.maxTokens))
    }

    @Test("A non-default temperature reaches models that accept one")
    func customTemperatureSent() {
        let config = openAI(model: "gpt-4o", temperature: 0.3)
        let parameters = OpenAIRequestShape.starting(for: config).tuningParameters(for: config)
        #expect(parameters["temperature"] == .number(0.3))
    }

    @Test("A non-default temperature is withheld from reasoning models")
    func reasoningModelDropsTemperature() {
        let config = openAI(model: "gpt-5", temperature: 0.3)
        let parameters = OpenAIRequestShape.starting(for: config).tuningParameters(for: config)
        #expect(parameters["temperature"] == nil)
    }

    // MARK: - Learning from a rejection

    @Test("The reported max_tokens rejection flips the spelling")
    func maxTokensRejectionFlipsSpelling() {
        var shape = OpenAIRequestShape.starting(for: openAI(model: "llama3"))
        shape.tokenLimitKey = OpenAIRequestShape.maxTokensKey

        let body = """
        {"error":{"message":"Unsupported parameter: 'max_tokens' is not supported with this model. \
        Use 'max_completion_tokens' instead.","type":"invalid_request_error","param":"max_tokens",\
        "code":"unsupported_parameter"}}
        """
        let relaxed = shape.relaxed(afterRejection: body)
        #expect(relaxed?.tokenLimitKey == OpenAIRequestShape.maxCompletionTokensKey)
    }

    @Test("A server that knows only the old spelling flips back")
    func maxCompletionTokensRejectionFlipsBack() {
        var shape = OpenAIRequestShape.starting(for: openAI(model: "gpt-5"))
        shape.tokenLimitKey = OpenAIRequestShape.maxCompletionTokensKey

        let body = """
        {"error":{"message":"Unrecognized request argument supplied: max_completion_tokens",\
        "param":"max_completion_tokens","type":"invalid_request_error"}}
        """
        #expect(shape.relaxed(afterRejection: body)?.tokenLimitKey == OpenAIRequestShape.maxTokensKey)
    }

    @Test("An unsupported temperature is dropped, not retried")
    func temperatureRejectionDropsTheField() {
        var shape = OpenAIRequestShape.starting(for: openAI(model: "gpt-4o"))
        shape.sendsTemperature = true

        let body = """
        {"error":{"message":"Unsupported value: 'temperature' does not support 0.3 with this model. \
        Only the default (1) value is supported.","type":"invalid_request_error",\
        "param":"temperature","code":"unsupported_value"}}
        """
        let relaxed = shape.relaxed(afterRejection: body)
        #expect(relaxed?.sendsTemperature == false)
        #expect(relaxed?.tokenLimitKey == shape.tokenLimitKey)
    }

    @Test("A rejected system role moves the prompt into the user turn")
    func systemRoleRejectionFoldsThePrompt() {
        let shape = OpenAIRequestShape.starting(for: openAI(model: "gpt-4o"))
        let body = """
        {"error":{"message":"Unsupported value: 'messages[0].role' does not support 'system' with \
        this model.","type":"invalid_request_error","param":"messages[0].role",\
        "code":"unsupported_value"}}
        """
        #expect(shape.relaxed(afterRejection: body)?.systemRole == nil)
    }

    @Test("A rejected reasoning effort is dropped")
    func reasoningEffortRejectionDropsTheField() {
        let shape = OpenAIRequestShape.starting(for: openAI(model: "gpt-4o"))
        let body = """
        {"error":{"message":"Unrecognized request argument supplied: reasoning_effort",\
        "param":"reasoning_effort","type":"invalid_request_error"}}
        """
        #expect(shape.relaxed(afterRejection: body)?.sendsReasoningEffort == false)
    }

    @Test("Rejections no reshape can fix stop the retry loop")
    func unrelatedRejectionsDoNotReshape() {
        let shape = OpenAIRequestShape.starting(for: openAI(model: "gpt-5"))
        let bodies = [
            #"{"error":{"message":"Incorrect API key provided.","code":"invalid_api_key"}}"#,
            #"{"error":{"message":"The model `gpt-9` does not exist.","param":"model"}}"#,
            "<html>502 Bad Gateway</html>",
            "",
        ]
        for body in bodies {
            #expect(shape.relaxed(afterRejection: body) == nil, "no reshape for \(body)")
        }
    }

    @Test("Every reshape is progress, so the loop terminates")
    func reshapingConverges() {
        var shape = OpenAIRequestShape.starting(for: openAI(model: "gpt-4o"))
        let body = """
        {"error":{"message":"Unsupported parameter: 'max_completion_tokens' is not supported.",\
        "param":"max_completion_tokens","code":"unsupported_parameter"}}
        """
        // The same complaint twice: the second one asks for a spelling already
        // in use, which is not a change and therefore not a retry.
        shape = try! #require(shape.relaxed(afterRejection: body))
        #expect(shape.tokenLimitKey == OpenAIRequestShape.maxTokensKey)
        #expect(shape.relaxed(afterRejection: body) == nil)
    }
}
