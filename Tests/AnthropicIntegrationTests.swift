import Foundation
import Testing
@testable import ClipSlop

/// Integration tests for the Anthropic provider.
///
/// Requires: ANTHROPIC_API_KEY environment variable.
///
/// Run: ANTHROPIC_API_KEY=sk-ant-... swift test --filter Anthropic
/// Or:  ./Scripts/extract-anthropic-key.sh --run-tests

// MARK: - Test Helpers

private func skipUnlessAnthropicKeyAvailable() throws -> String {
    guard let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !key.isEmpty else {
        throw SkipError("ANTHROPIC_API_KEY not set.")
    }
    return key
}

private struct SkipError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { self.description = message }
}

// MARK: - Model Fetcher Tests

@Suite("Anthropic Model Fetcher")
struct AnthropicModelFetcherTests {

    @Test("Fetches models from Anthropic API")
    func fetchModels() async throws {
        let apiKey = try skipUnlessAnthropicKeyAvailable()

        // Store key temporarily in Keychain for the fetcher
        let testRef = "clipslop.test.anthropic-key"
        try KeychainService.save(key: testRef, value: apiKey)
        defer { KeychainService.delete(key: testRef) }

        let config = AIProviderConfig(
            name: "Test Anthropic",
            providerType: .anthropic,
            apiKeyRef: testRef
        )

        let models = await ModelFetcher.fetchModels(for: config)

        #expect(!models.isEmpty, "Should fetch at least one model")
        // Should contain Claude models
        let hasClaude = models.contains { $0.contains("claude") }
        #expect(hasClaude, "Should contain claude models, got: \(models)")
    }

    @Test("Models are sorted alphabetically")
    func modelsSorted() async throws {
        let apiKey = try skipUnlessAnthropicKeyAvailable()

        let testRef = "clipslop.test.anthropic-key-sort"
        try KeychainService.save(key: testRef, value: apiKey)
        defer { KeychainService.delete(key: testRef) }

        let config = AIProviderConfig(
            name: "Test Anthropic",
            providerType: .anthropic,
            apiKeyRef: testRef
        )

        let models = await ModelFetcher.fetchModels(for: config)
        let sorted = models.sorted()
        #expect(models == sorted, "Models should be sorted")
    }

    @Test("Fallback models are returned when no API key")
    func fallbackModels() async {
        let config = AIProviderConfig(
            name: "Test Anthropic No Key",
            providerType: .anthropic,
            apiKeyRef: "clipslop.test.nonexistent-key"
        )

        let models = await ModelFetcher.fetchModels(for: config)
        let known = ModelFetcher.knownModels(for: .anthropic)

        #expect(models == known, "Should return fallback known models")
    }

    @Test("Known models use non-dated aliases")
    func knownModelsAreAliases() {
        let models = ModelFetcher.knownModels(for: .anthropic)

        for model in models {
            // Dated models contain 8-digit date like -20250514
            let hasDate = model.range(of: #"-\d{8}$"#, options: .regularExpression) != nil
            #expect(!hasDate, "Model '\(model)' should not have a date suffix")
        }
    }
}

// MARK: - Anthropic API Tests

@Suite("Anthropic API Integration")
struct AnthropicAPITests {

    @Test("Non-streaming request returns text")
    func nonStreamingRequest() async throws {
        let apiKey = try skipUnlessAnthropicKeyAvailable()

        let testRef = "clipslop.test.anthropic-api"
        try KeychainService.save(key: testRef, value: apiKey)
        defer { KeychainService.delete(key: testRef) }

        let config = AIProviderConfig(
            name: "Test Anthropic",
            providerType: .anthropic,
            apiKeyRef: testRef,
            modelID: Constants.Anthropic.defaultModel
        )

        let service = AIServiceFactory.service(for: .anthropic)
        let result = try await service.process(
            text: "Reply with exactly: ANTHROPIC_TEST_OK",
            systemPrompt: "Follow instructions exactly.",
            config: config
        )

        #expect(result.contains("ANTHROPIC_TEST_OK"))
    }

    @Test("Streaming request yields deltas")
    func streamingRequest() async throws {
        let apiKey = try skipUnlessAnthropicKeyAvailable()

        let testRef = "clipslop.test.anthropic-stream"
        try KeychainService.save(key: testRef, value: apiKey)
        defer { KeychainService.delete(key: testRef) }

        let config = AIProviderConfig(
            name: "Test Anthropic",
            providerType: .anthropic,
            apiKeyRef: testRef,
            modelID: Constants.Anthropic.defaultModel
        )

        let service = AIServiceFactory.service(for: .anthropic)
        var chunks: [String] = []
        for try await chunk in service.stream(
            text: "Count from 1 to 3, each on a new line.",
            systemPrompt: "You are a test assistant.",
            config: config
        ) {
            chunks.append(chunk)
        }

        let fullText = chunks.joined()
        #expect(!chunks.isEmpty, "Should yield at least one chunk")
        #expect(fullText.contains("1"))
        #expect(fullText.contains("3"))
    }

    @Test("Default model alias works")
    func defaultModelWorks() async throws {
        let apiKey = try skipUnlessAnthropicKeyAvailable()

        let testRef = "clipslop.test.anthropic-default"
        try KeychainService.save(key: testRef, value: apiKey)
        defer { KeychainService.delete(key: testRef) }

        // Use the non-dated alias
        let config = AIProviderConfig(
            name: "Test Anthropic",
            providerType: .anthropic,
            apiKeyRef: testRef,
            modelID: "claude-sonnet-4"
        )

        let service = AIServiceFactory.service(for: .anthropic)
        let result = try await service.process(
            text: "Say OK",
            systemPrompt: "Reply with just OK",
            config: config
        )

        #expect(!result.isEmpty)
    }
}
