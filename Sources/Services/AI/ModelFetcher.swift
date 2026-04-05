import Foundation

enum ModelFetcher {
    /// Fetches available model IDs from a provider's API.
    /// Falls back to well-known models if the API call fails.
    static func fetchModels(for config: AIProviderConfig) async -> [String] {
        let fetched: [String]
        switch config.providerType {
        case .openAI, .openAICompatible:
            fetched = await fetchOpenAIModels(baseURL: config.baseURL, apiKeyRef: config.apiKeyRef)
        case .openAIChatGPT:
            fetched = await fetchChatGPTModels(config: config)
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
                "claude-opus-4",
                "claude-sonnet-4",
                "claude-haiku-4",
                "claude-3-7-sonnet",
                "claude-3-5-sonnet",
                "claude-3-5-haiku",
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
        case .openAIChatGPT:
            [
                "gpt-5.3-codex",
                "gpt-5.4",
                "gpt-5.2-codex",
                "gpt-5.1-codex-max",
                "gpt-5.2",
                "gpt-5.1-codex-mini",
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

    // MARK: - ChatGPT (OAuth)

    @MainActor
    private static func fetchChatGPTModels(config: AIProviderConfig) async -> [String] {
        guard let (accessToken, accountID) = try? await ChatGPTTokenManager.shared.getValidAccessToken(for: config.id),
              let url = URL(string: config.baseURL + "/models?client_version=1.0.0")
        else { return [] }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONDecoder().decode(ChatGPTModelsResponse.self, from: data)
        else { return [] }

        return json.models
            .filter { $0.visibility == "list" }
            .sorted { $0.priority < $1.priority }
            .map(\.slug)
    }

    // MARK: - Anthropic

    private static func fetchAnthropicModels(baseURL: String, apiKeyRef: String) async -> [String] {
        guard let apiKey = KeychainService.load(key: apiKeyRef), !apiKey.isEmpty else { return [] }

        var allModels: [String] = []
        var afterID: String?

        // Paginate through all models
        while true {
            var urlString = baseURL + "/v1/models?limit=1000"
            if let afterID {
                urlString += "&after_id=\(afterID)"
            }
            guard let url = URL(string: urlString) else { break }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 10
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue(Constants.Anthropic.apiVersion, forHTTPHeaderField: "anthropic-version")

            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try? JSONDecoder().decode(AnthropicModelsResponse.self, from: data)
            else { break }

            allModels.append(contentsOf: json.data.map(\.id))

            if json.hasMore, let lastID = json.lastID {
                afterID = lastID
            } else {
                break
            }
        }

        return allModels.sorted()
    }
}

// MARK: - Response Models

private struct OpenAIModelsResponse: Decodable {
    let data: [Model]

    struct Model: Decodable {
        let id: String
    }
}

private struct ChatGPTModelsResponse: Decodable {
    let models: [Model]

    struct Model: Decodable {
        let slug: String
        let visibility: String
        let priority: Int
    }
}

private struct AnthropicModelsResponse: Decodable {
    let data: [Model]
    let hasMore: Bool
    let lastID: String?

    struct Model: Decodable {
        let id: String
    }

    enum CodingKeys: String, CodingKey {
        case data
        case hasMore = "has_more"
        case lastID = "last_id"
    }
}
