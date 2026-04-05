import Foundation

/// AIService implementation for ChatGPT OAuth-authenticated requests.
/// Uses the Responses API (/v1/responses) with Bearer token + ChatGPT-Account-Id header.
struct ChatGPTService: AIService {
    func process(text: String, systemPrompt: String, config: AIProviderConfig) async throws -> String {
        // ChatGPT Codex backend requires stream=true; collect all deltas into a single result.
        var result = ""
        for try await chunk in stream(text: text, systemPrompt: systemPrompt, config: config) {
            result += chunk
        }
        guard !result.isEmpty else {
            throw AIServiceError.emptyResponse
        }
        return result
    }

    func stream(text: String, systemPrompt: String, config: AIProviderConfig) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try await buildRequest(text: text, systemPrompt: systemPrompt, config: config, stream: true)
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw AIServiceError.networkError(URLError(.badServerResponse))
                    }
                    guard httpResponse.statusCode == 200 else {
                        var body = ""
                        for try await line in bytes.lines { body += line }
                        throw AIServiceError.httpError(statusCode: httpResponse.statusCode, body: body)
                    }

                    // Responses API uses SSE with typed events
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard line.hasPrefix("data: ") else { continue }
                        let json = String(line.dropFirst(6))
                        guard let data = json.data(using: .utf8),
                              let event = try? JSONDecoder().decode(ResponsesSSEEvent.self, from: data)
                        else { continue }

                        switch event.type {
                        case "response.output_text.delta":
                            if let delta = event.delta {
                                continuation.yield(delta)
                            }
                        case "response.completed":
                            break
                        case "response.failed":
                            if let message = event.response?.error?.message {
                                throw AIServiceError.httpError(statusCode: 0, body: message)
                            }
                        default:
                            continue
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

    @MainActor
    private static var tokenManager: ChatGPTTokenManager {
        ChatGPTTokenManager.shared
    }

    private func buildRequest(
        text: String,
        systemPrompt: String,
        config: AIProviderConfig,
        stream: Bool = true  // ChatGPT Codex backend requires stream=true
    ) async throws -> URLRequest {
        let (accessToken, accountID) = try await Self.getToken(for: config.id)

        let endpoint = config.baseURL + "/responses"
        guard let url = URL(string: endpoint) else {
            throw AIServiceError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        if let accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let reasoning: ResponsesAPIRequest.Reasoning? = config.reasoningEffort.map {
            ResponsesAPIRequest.Reasoning(effort: $0.rawValue)
        }

        let body = ResponsesAPIRequest(
            model: config.modelID,
            instructions: systemPrompt,
            input: [
                .init(
                    type: "message",
                    role: "user",
                    content: [.init(type: "input_text", text: text)]
                ),
            ],
            reasoning: reasoning,
            stream: stream,
            store: false
        )

        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    @MainActor
    private static func getToken(for providerID: UUID) async throws -> (accessToken: String, accountID: String?) {
        try await tokenManager.getValidAccessToken(for: providerID)
    }
}

// MARK: - Responses API Request Models

private struct ResponsesAPIRequest: Encodable {
    let model: String
    let instructions: String
    let input: [InputItem]
    let reasoning: Reasoning?
    let stream: Bool
    let store: Bool

    struct InputItem: Encodable {
        let type: String
        let role: String
        let content: [ContentPart]
    }

    struct ContentPart: Encodable {
        let type: String
        let text: String
    }

    struct Reasoning: Encodable {
        let effort: String
    }
}

// MARK: - Responses API Response Models

private struct ResponsesAPIResponse: Decodable {
    let output: [OutputItem]

    struct OutputItem: Decodable {
        let type: String
        let content: [ContentPart]?
    }

    struct ContentPart: Decodable {
        let type: String
        let text: String?
    }
}

// MARK: - Responses API SSE Event

private struct ResponsesSSEEvent: Decodable {
    let type: String
    let delta: String?
    let response: ResponseInfo?

    struct ResponseInfo: Decodable {
        let error: ErrorInfo?
    }

    struct ErrorInfo: Decodable {
        let message: String?
    }
}
