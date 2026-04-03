import Foundation

struct AnthropicService: AIService {
    func process(text: String, systemPrompt: String, config: AIProviderConfig) async throws -> String {
        let (request, _) = try buildRequest(text: text, systemPrompt: systemPrompt, config: config, stream: false)

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

        let decoded = try JSONDecoder().decode(AnthropicResponse.self, from: data)
        guard let text = decoded.content.first?.text, !text.isEmpty else {
            throw AIServiceError.emptyResponse
        }
        return text
    }

    func stream(text: String, systemPrompt: String, config: AIProviderConfig) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (request, _) = try buildRequest(text: text, systemPrompt: systemPrompt, config: config, stream: true)
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
                              let event = try? JSONDecoder().decode(AnthropicStreamEvent.self, from: data)
                        else { continue }

                        if case .contentBlockDelta = event.type,
                           let delta = event.delta,
                           let text = delta.text {
                            continuation.yield(text)
                        }
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
    ) throws -> (URLRequest, Data) {
        guard let apiKey = KeychainService.load(key: config.apiKeyRef), !apiKey.isEmpty else {
            throw AIServiceError.missingAPIKey
        }

        let url = URL(string: config.baseURL)!
            .appendingPathComponent("v1/messages")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Constants.Anthropic.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let body = AnthropicRequest(
            model: config.modelID,
            maxTokens: config.maxTokens,
            system: systemPrompt,
            stream: stream,
            messages: [.init(role: "user", content: text)]
        )

        let bodyData = try JSONEncoder().encode(body)
        request.httpBody = bodyData
        return (request, bodyData)
    }
}

// MARK: - API Models

private struct AnthropicRequest: Encodable {
    let model: String
    let maxTokens: Int
    let system: String
    let stream: Bool
    let messages: [Message]

    struct Message: Encodable {
        let role: String
        let content: String
    }

    enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case system, stream, messages
    }
}

private struct AnthropicResponse: Decodable {
    let content: [ContentBlock]

    struct ContentBlock: Decodable {
        let type: String
        let text: String?
    }
}

private struct AnthropicStreamEvent: Decodable {
    let type: EventType
    let delta: Delta?

    enum EventType: String, Decodable {
        case messageStart = "message_start"
        case contentBlockStart = "content_block_start"
        case contentBlockDelta = "content_block_delta"
        case contentBlockStop = "content_block_stop"
        case messageDelta = "message_delta"
        case messageStop = "message_stop"
        case ping
        case error
    }

    struct Delta: Decodable {
        let type: String?
        let text: String?
    }
}
