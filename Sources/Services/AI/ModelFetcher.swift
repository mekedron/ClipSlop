import Foundation

enum ModelFetcher {
    /// Fetches available model IDs from a provider's API.
    /// Falls back to well-known models if the API call fails.
    static func fetchModels(for config: AIProviderConfig) async -> [String] {
        let fetched: [String]
        switch config.providerType {
        case .openAI, .openAICompatible:
            fetched = await fetchOpenAIModels(baseURL: config.baseURL, apiKeyRef: config.apiKeyRef)
        case .ollama:
            fetched = await fetchOpenAIModels(baseURL: config.baseURL, apiKeyRef: config.apiKeyRef)
        case .anthropic:
            fetched = await fetchAnthropicModels(baseURL: config.baseURL, apiKeyRef: config.apiKeyRef)
        case .cliTool:
            return []
        }

        if !fetched.isEmpty { return fetched }

        // Fallback to well-known models when API is unreachable or key not configured
        return knownModels(for: config.providerType)
    }

    /// Well-known models per provider type, used as fallback.
    static func knownModels(for providerType: AIProviderType) -> [String] {
        switch providerType {
        case .anthropic:
            [
                "claude-opus-4-20250514",
                "claude-sonnet-4-20250514",
                "claude-haiku-4-5-20251001",
                "claude-3-7-sonnet-20250219",
                "claude-3-5-sonnet-20241022",
                "claude-3-5-haiku-20241022",
                "claude-3-opus-20240229",
            ]
        case .openAI:
            [
                "gpt-4.1",
                "gpt-4.1-mini",
                "gpt-4.1-nano",
                "gpt-4o",
                "gpt-4o-mini",
                "o3",
                "o3-mini",
                "o4-mini",
            ]
        default:
            []
        }
    }

    // MARK: - OpenAI / Compatible / Ollama

    private static func fetchOpenAIModels(baseURL: String, apiKeyRef: String) async -> [String] {
        guard let url = URL(string: baseURL + "/v1/models") else { return [] }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10

        if let apiKey = KeychainService.load(key: apiKeyRef), !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONDecoder().decode(OpenAIModelsResponse.self, from: data)
        else { return [] }

        return json.data
            .map(\.id)
            .sorted()
    }

    // MARK: - Anthropic

    private static func fetchAnthropicModels(baseURL: String, apiKeyRef: String) async -> [String] {
        guard let apiKey = KeychainService.load(key: apiKeyRef), !apiKey.isEmpty,
              let url = URL(string: baseURL + "/v1/models")
        else { return [] }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Constants.Anthropic.apiVersion, forHTTPHeaderField: "anthropic-version")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONDecoder().decode(AnthropicModelsResponse.self, from: data)
        else { return [] }

        return json.data
            .map(\.id)
            .sorted()
    }
}

// MARK: - Response Models

private struct OpenAIModelsResponse: Decodable {
    let data: [Model]

    struct Model: Decodable {
        let id: String
    }
}

private struct AnthropicModelsResponse: Decodable {
    let data: [Model]

    struct Model: Decodable {
        let id: String
    }
}
