import Foundation

/// Tool-calling chat over the Anthropic Messages API (`/v1/messages`),
/// non-streaming. Mirrors `AnthropicService`'s request/auth conventions.
struct AnthropicToolChatService: ToolChatService {
    func send(
        messages: [ChatTurn],
        systemPrompt: String,
        tools: [ToolDefinition],
        config: AIProviderConfig
    ) async throws -> AssistantReply {
        guard let apiKey = KeychainService.load(key: config.apiKeyRef), !apiKey.isEmpty else {
            throw AIServiceError.missingAPIKey
        }

        let url = URL(string: config.baseURL)!.appendingPathComponent("v1/messages")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Constants.Anthropic.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let body: JSONValue = .object([
            "model": .string(config.modelID),
            "max_tokens": .int(config.maxTokens),
            "temperature": .number(config.temperature),
            "system": .string(systemPrompt),
            "tools": .array(tools.map(Self.toolJSON)),
            "messages": .array(Self.messagesJSON(messages)),
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
        var text = ""
        var toolCalls: [ToolCallRequest] = []
        for block in decoded.content {
            switch block.type {
            case "text":
                if let blockText = block.text { text += blockText }
            case "tool_use":
                if let id = block.id, let name = block.name {
                    toolCalls.append(ToolCallRequest(
                        id: id,
                        name: name,
                        argumentsJSON: (block.input ?? .object([:])).jsonString()
                    ))
                }
            default:
                continue
            }
        }
        return AssistantReply(text: text.isEmpty ? nil : text, toolCalls: toolCalls)
    }

    // MARK: - Request encoding

    private static func toolJSON(_ tool: ToolDefinition) -> JSONValue {
        .object([
            "name": .string(tool.name),
            "description": .string(tool.description),
            "input_schema": JSONValue.parse(tool.parametersSchemaJSON),
        ])
    }

    private static func messagesJSON(_ turns: [ChatTurn]) -> [JSONValue] {
        var messages: [JSONValue] = []
        for turn in turns {
            switch turn {
            case .user(let text):
                messages.append(.object([
                    "role": .string("user"),
                    "content": .string(text),
                ]))

            case .assistant(let text, let toolCalls):
                var blocks: [JSONValue] = []
                if let text, !text.isEmpty {
                    blocks.append(.object([
                        "type": .string("text"),
                        "text": .string(text),
                    ]))
                }
                for call in toolCalls {
                    blocks.append(.object([
                        "type": .string("tool_use"),
                        "id": .string(call.id),
                        "name": .string(call.name),
                        "input": JSONValue.parse(call.argumentsJSON),
                    ]))
                }
                messages.append(.object([
                    "role": .string("assistant"),
                    "content": .array(blocks),
                ]))

            case .toolResults(let results):
                let blocks: [JSONValue] = results.map { result in
                    var block: [String: JSONValue] = [
                        "type": .string("tool_result"),
                        "tool_use_id": .string(result.toolCallID),
                        "content": .string(result.content),
                    ]
                    if result.isError { block["is_error"] = .bool(true) }
                    return .object(block)
                }
                messages.append(.object([
                    "role": .string("user"),
                    "content": .array(blocks),
                ]))
            }
        }
        return messages
    }

    // MARK: - Response decoding

    private struct Response: Decodable {
        let content: [Block]

        struct Block: Decodable {
            let type: String
            let text: String?
            let id: String?
            let name: String?
            let input: JSONValue?
        }
    }
}
