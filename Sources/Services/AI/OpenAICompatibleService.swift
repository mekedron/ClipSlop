import Foundation

/// Works with OpenAI, Ollama, and any OpenAI-compatible API
struct OpenAICompatibleService: AIService {
    func process(text: String, systemPrompt: String, config: AIProviderConfig) async throws -> String {
        let request = try buildRequest(text: text, systemPrompt: systemPrompt, config: config, stream: false)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIServiceError.networkError(URLError(.badServerResponse))
        }
        guard httpResponse.statusCode == 200 else {
            throw AIServiceError.httpError(
                statusCode: httpResponse.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }

        let decoded = try JSONDecoder().decode(OpenAIResponse.self, from: data)
        guard let text = decoded.choices.first?.message.content, !text.isEmpty else {
            throw AIServiceError.emptyResponse
        }
        return text
    }

    func stream(text: String, systemPrompt: String, config: AIProviderConfig) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try buildRequest(text: text, systemPrompt: systemPrompt, config: config, stream: true)
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw AIServiceError.networkError(URLError(.badServerResponse))
                    }
                    guard httpResponse.statusCode == 200 else {
                        var body = ""
                        for try await line in bytes.lines { body += line }
                        throw AIServiceError.httpError(statusCode: httpResponse.statusCode, body: body)
                    }

                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard line.hasPrefix("data: ") else { continue }
                        let json = String(line.dropFirst(6))
                        guard json != "[DONE]",
                              let data = json.data(using: .utf8),
                              let chunk = try? JSONDecoder().decode(OpenAIStreamChunk.self, from: data),
                              let delta = chunk.choices.first?.delta.content
                        else { continue }
                        continuation.yield(delta)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    // MARK: - Private

    private func buildRequest(
        text: String,
        systemPrompt: String,
        config: AIProviderConfig,
        stream: Bool
    ) throws -> URLRequest {
        // Ollama doesn't require an API key
        if config.providerType.requiresAPIKey {
            guard let apiKey = KeychainService.load(key: config.apiKeyRef), !apiKey.isEmpty else {
                throw AIServiceError.missingAPIKey
            }
        }

        let chatPath = config.providerType == .ollama ? "/v1/chat/completions" : "/v1/chat/completions"
        guard let url = URL(string: config.baseURL + chatPath) else {
            throw AIServiceError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let apiKey = KeychainService.load(key: config.apiKeyRef), !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let body = OpenAIRequest(
            model: config.modelID,
            messages: [
                .init(role: "system", content: systemPrompt),
                .init(role: "user", content: text),
            ],
            maxTokens: config.maxTokens,
            temperature: config.temperature,
            stream: stream
        )

        request.httpBody = try JSONEncoder().encode(body)
        return request
    }
}

// MARK: - API Models

private struct OpenAIRequest: Encodable {
    let model: String
    let messages: [Message]
    let maxTokens: Int
    let temperature: Double
    let stream: Bool

    struct Message: Encodable {
        let role: String
        let content: String
    }

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature, stream
        case maxTokens = "max_tokens"
    }
}

private struct OpenAIResponse: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let message: Message
    }

    struct Message: Decodable {
        let content: String?
    }
}

private struct OpenAIStreamChunk: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let delta: Delta
    }

    struct Delta: Decodable {
        let content: String?
    }
}
