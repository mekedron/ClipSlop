import Foundation

/// Works with OpenAI, Ollama, and any OpenAI-compatible API.
///
/// The request body is assembled per model by `OpenAIRequestShape`, and a 400
/// that complains about the shape is answered with a reshaped retry rather
/// than surfaced — see that type for why one endpoint needs several dialects.
struct OpenAICompatibleService: AIService {
    func process(text: String, systemPrompt: String, config: AIProviderConfig) async throws -> String {
        try await processWithUsage(text: text, systemPrompt: systemPrompt, config: config).text
    }

    func processWithUsage(text: String, systemPrompt: String, config: AIProviderConfig) async throws -> AIGenerationResult {
        var shape = await OpenAIShapeMemo.shared.shape(for: config)
        var reshapes = 0

        while true {
            let request = try buildRequest(
                text: text, systemPrompt: systemPrompt, config: config, shape: shape, stream: false
            )
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw AIServiceError.networkError(URLError(.badServerResponse))
            }
            guard httpResponse.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? ""
                if httpResponse.statusCode == 400, reshapes < OpenAIRequestShape.maxReshapes,
                   let next = shape.relaxed(afterRejection: body) {
                    shape = next
                    reshapes += 1
                    continue
                }
                throw AIServiceError.httpError(statusCode: httpResponse.statusCode, body: body)
            }
            await OpenAIShapeMemo.shared.remember(shape, for: config)

            let decoded = try JSONDecoder().decode(OpenAIResponse.self, from: data)
            guard let choice = decoded.choices.first else {
                throw AIServiceError.emptyResponse
            }
            guard let text = choice.message.content, !text.isEmpty else {
                // A reasoning model spends the same budget on thinking and on
                // answering, so a cap sized for the answer alone runs out
                // before the answer starts and returns a well-formed response
                // with nothing in it. Naming the cap is the difference between
                // a setting the user can raise and an inexplicable blank.
                if choice.finishReason == "length" {
                    throw AIServiceError.generationStopped(
                        reason: "the \(config.maxTokens)-token limit ran out before any text was produced"
                            + " — raise Max Tokens for this provider"
                    )
                }
                throw AIServiceError.emptyResponse
            }
            return AIGenerationResult(
                text: text,
                inputTokens: decoded.usage?.promptTokens,
                outputTokens: decoded.usage?.completionTokens
            )
        }
    }

    func stream(text: String, systemPrompt: String, config: AIProviderConfig) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let bytes: URLSession.AsyncBytes
                    do {
                        bytes = try await openStream(text: text, systemPrompt: systemPrompt, config: config)
                    } catch let error as AIServiceError where Self.deniesStreaming(error) {
                        // Streaming is gated per organization on some models
                        // while the same request unstreamed is allowed. The
                        // whole answer arriving at once is a worse experience
                        // than a refusal only in theory.
                        let result = try await processWithUsage(
                            text: text, systemPrompt: systemPrompt, config: config
                        )
                        continuation.yield(result.text)
                        continuation.finish()
                        return
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

    /// Opens the SSE stream, reshaping the body for as long as the endpoint is
    /// rejecting the dialect rather than the request.
    private func openStream(
        text: String,
        systemPrompt: String,
        config: AIProviderConfig
    ) async throws -> URLSession.AsyncBytes {
        var shape = await OpenAIShapeMemo.shared.shape(for: config)
        var reshapes = 0

        while true {
            let request = try buildRequest(
                text: text, systemPrompt: systemPrompt, config: config, shape: shape, stream: true
            )
            let (bytes, response) = try await URLSession.shared.bytes(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw AIServiceError.networkError(URLError(.badServerResponse))
            }
            if httpResponse.statusCode == 200 {
                await OpenAIShapeMemo.shared.remember(shape, for: config)
                return bytes
            }

            var body = ""
            for try await line in bytes.lines { body += line }
            if httpResponse.statusCode == 400, reshapes < OpenAIRequestShape.maxReshapes,
               let next = shape.relaxed(afterRejection: body) {
                shape = next
                reshapes += 1
                continue
            }
            throw AIServiceError.httpError(statusCode: httpResponse.statusCode, body: body)
        }
    }

    /// Whether the endpoint refused this request *because* it asked to stream.
    private static func deniesStreaming(_ error: AIServiceError) -> Bool {
        guard case .httpError(400, let body) = error else { return false }
        let lowercased = body.lowercased()
        return lowercased.contains("verified to stream")
            || (lowercased.contains("'stream'") && lowercased.contains("unsupported"))
    }

    private func buildRequest(
        text: String,
        systemPrompt: String,
        config: AIProviderConfig,
        shape: OpenAIRequestShape,
        stream: Bool
    ) throws -> URLRequest {
        // Ollama doesn't require an API key
        if config.providerType.requiresAPIKey {
            guard let apiKey = KeychainService.load(key: config.apiKeyRef), !apiKey.isEmpty else {
                throw AIServiceError.missingAPIKey
            }
        }

        guard let url = URL(string: config.baseURL + "/v1/chat/completions") else {
            throw AIServiceError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        if let timeout = config.requestTimeout { request.timeoutInterval = timeout }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let apiKey = KeychainService.load(key: config.apiKeyRef), !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        var messages: [JSONValue] = []
        if let systemMessage = shape.systemMessage(systemPrompt) {
            messages.append(systemMessage)
        }
        messages.append(.object([
            "role": .string("user"),
            "content": .string(shape.firstUserText(text, systemPrompt: systemPrompt)),
        ]))

        var body: [String: JSONValue] = [
            "model": .string(config.modelID),
            "messages": .array(messages),
            "stream": .bool(stream),
        ]
        body.merge(shape.tuningParameters(for: config)) { _, tuning in tuning }

        request.httpBody = try JSONEncoder().encode(JSONValue.object(body))
        return request
    }
}

// MARK: - API Models

private struct OpenAIResponse: Decodable {
    let choices: [Choice]
    let usage: Usage?

    struct Choice: Decodable {
        let message: Message
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case message
            case finishReason = "finish_reason"
        }
    }

    struct Message: Decodable {
        let content: String?
    }

    struct Usage: Decodable {
        let promptTokens: Int?
        let completionTokens: Int?

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
        }
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
