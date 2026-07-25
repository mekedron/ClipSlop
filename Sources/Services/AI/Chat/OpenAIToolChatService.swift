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

        var shape = await OpenAIShapeMemo.shared.shape(for: config)
        var reshapes = 0

        while true {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            // See AnthropicToolChatService: the chat.assistant role's timeout
            // is read by the streaming services too.
            if let timeout = config.requestTimeout { request.timeoutInterval = timeout }
            if let apiKey = KeychainService.load(key: config.apiKeyRef), !apiKey.isEmpty {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }

            var bodyObject: [String: JSONValue] = [
                "model": .string(config.modelID),
                "messages": .array(
                    Self.messagesJSON(system: systemPrompt, turns: messages, shape: shape)
                ),
                "tools": .array(tools.map(Self.toolJSON)),
            ]
            bodyObject.merge(shape.tuningParameters(for: config)) { _, tuning in tuning }
            request.httpBody = try JSONEncoder().encode(JSONValue.object(bodyObject))

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

    private static func messagesJSON(
        system: String,
        turns: [ChatTurn],
        shape: OpenAIRequestShape
    ) -> [JSONValue] {
        var messages: [JSONValue] = []
        if let systemMessage = shape.systemMessage(system) {
            messages.append(systemMessage)
        }
        // Without a system role the instructions ride on the first user turn,
        // so `pendingSystem` is spent exactly once and only if there is a user
        // turn to carry it.
        var pendingSystem = shape.systemRole == nil ? system : ""
        for turn in turns {
            switch turn {
            case .user(let text):
                messages.append(.object([
                    "role": .string("user"),
                    "content": .string(shape.firstUserText(text, systemPrompt: pendingSystem)),
                ]))
                pendingSystem = ""

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
