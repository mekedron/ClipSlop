import Foundation

/// Tool-calling chat over the OpenAI Chat Completions API
/// (`/v1/chat/completions`), non-streaming. Covers `.openAI`, `.ollama`, and
/// `.openAICompatible`. Mirrors `OpenAICompatibleService`'s request/auth.
struct OpenAIToolChatService: ToolChatService {
    func send(
        messages: [ChatTurn],
        systemPrompt: String,
        tools: [ToolDefinition],
        config: AIProviderConfig
    ) async throws -> AssistantReply {
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
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey = KeychainService.load(key: config.apiKeyRef), !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let body: JSONValue = .object([
            "model": .string(config.modelID),
            "messages": .array(Self.messagesJSON(system: systemPrompt, turns: messages)),
            "max_tokens": .int(config.maxTokens),
            "temperature": .number(config.temperature),
            "tools": .array(tools.map(Self.toolJSON)),
        ])
        request.httpBody = try JSONEncoder().encode(body)

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

        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard let message = decoded.choices.first?.message else {
            throw AIServiceError.emptyResponse
        }
        let text = message.content?.isEmpty == false ? message.content : nil
        let toolCalls = (message.toolCalls ?? []).map { call in
            ToolCallRequest(
                id: call.id,
                name: call.function.name,
                argumentsJSON: call.function.arguments
            )
        }
        return AssistantReply(text: text, toolCalls: toolCalls)
    }

    // MARK: - Request encoding

    private static func toolJSON(_ tool: ToolDefinition) -> JSONValue {
        .object([
            "type": .string("function"),
            "function": .object([
                "name": .string(tool.name),
                "description": .string(tool.description),
                "parameters": JSONValue.parse(tool.parametersSchemaJSON),
            ]),
        ])
    }

    private static func messagesJSON(system: String, turns: [ChatTurn]) -> [JSONValue] {
        var messages: [JSONValue] = [
            .object(["role": .string("system"), "content": .string(system)]),
        ]
        for turn in turns {
            switch turn {
            case .user(let text):
                messages.append(.object([
                    "role": .string("user"),
                    "content": .string(text),
                ]))

            case .assistant(let text, let toolCalls):
                var message: [String: JSONValue] = ["role": .string("assistant")]
                message["content"] = (text?.isEmpty == false) ? .string(text!) : .null
                if !toolCalls.isEmpty {
                    message["tool_calls"] = .array(toolCalls.map { call in
                        .object([
                            "id": .string(call.id),
                            "type": .string("function"),
                            "function": .object([
                                "name": .string(call.name),
                                "arguments": .string(call.argumentsJSON),
                            ]),
                        ])
                    })
                }
                messages.append(.object(message))

            case .toolResults(let results):
                for result in results {
                    messages.append(.object([
                        "role": .string("tool"),
                        "tool_call_id": .string(result.toolCallID),
                        "content": .string(result.content),
                    ]))
                }
            }
        }
        return messages
    }

    // MARK: - Response decoding

    private struct Response: Decodable {
        let choices: [Choice]

        struct Choice: Decodable {
            let message: Message
        }

        struct Message: Decodable {
            let content: String?
            let toolCalls: [ToolCall]?

            enum CodingKeys: String, CodingKey {
                case content
                case toolCalls = "tool_calls"
            }
        }

        struct ToolCall: Decodable {
            let id: String
            let function: Function
        }

        struct Function: Decodable {
            let name: String
            let arguments: String
        }
    }
}
