import Foundation

/// Tool-calling chat over the OpenAI Responses API (`/responses`) using the
/// ChatGPT OAuth backend. The Codex backend requires `stream: true`, so we
/// consume the SSE stream and buffer the final `response.completed` event into
/// a single `AssistantReply`. Mirrors `ChatGPTService`'s auth conventions.
struct ChatGPTToolChatService: ToolChatService {
    func send(
        messages: [ChatTurn],
        systemPrompt: String,
        tools: [ToolDefinition],
        config: AIProviderConfig
    ) async throws -> AssistantReply {
        let (accessToken, accountID) = try await ChatGPTTokenManager.shared
            .getValidAccessToken(for: config.id)

        guard let url = URL(string: config.baseURL + "/responses") else {
            throw AIServiceError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        var bodyObject: [String: JSONValue] = [
            "model": .string(config.modelID),
            "instructions": .string(systemPrompt),
            "input": .array(Self.inputJSON(messages)),
            "tools": .array(tools.map(Self.toolJSON)),
            "stream": .bool(true),
            "store": .bool(false),
        ]
        if let effort = config.reasoningEffort {
            bodyObject["reasoning"] = .object(["effort": .string(effort.rawValue)])
        }
        request.httpBody = try JSONEncoder().encode(JSONValue.object(bodyObject))

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIServiceError.networkError(URLError(.badServerResponse))
        }
        guard httpResponse.statusCode == 200 else {
            var errorBody = ""
            for try await line in bytes.lines { errorBody += line }
            throw AIServiceError.httpError(statusCode: httpResponse.statusCode, body: errorBody)
        }

        // Accumulate assistant text from the streamed text deltas (the proven
        // path in ChatGPTService — the Codex backend always streams these) and
        // collect function calls from output-item events. The final
        // `response.completed` event is used only as a fallback for anything the
        // deltas didn't surface.
        var text = ""
        var toolCalls: [ToolCallRequest] = []
        var seenCallIDs = Set<String>()

        func addToolCall(_ item: SSEEvent.OutputItem?) {
            guard let item, item.type == "function_call",
                  let callID = item.callID, let name = item.name,
                  seenCallIDs.insert(callID).inserted
            else { return }
            toolCalls.append(ToolCallRequest(id: callID, name: name, argumentsJSON: item.arguments ?? "{}"))
        }

        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let json = String(line.dropFirst(6))
            guard json != "[DONE]",
                  let data = json.data(using: .utf8),
                  let event = try? JSONDecoder().decode(SSEEvent.self, from: data)
            else { continue }

            switch event.type {
            case "response.output_text.delta":
                if let delta = event.delta { text += delta }
            case "response.output_item.done", "response.output_item.added":
                addToolCall(event.item)
            case "response.completed":
                // Fallback: pull anything the deltas/items missed.
                for item in event.response?.output ?? [] {
                    if item.type == "message", text.isEmpty {
                        for part in item.content ?? [] where part.type == "output_text" {
                            if let partText = part.text { text += partText }
                        }
                    }
                    addToolCall(item)
                }
                return AssistantReply(text: text.isEmpty ? nil : text, toolCalls: toolCalls)
            case "response.failed":
                let message = event.response?.error?.message ?? "Request failed"
                throw AIServiceError.httpError(statusCode: 0, body: message)
            default:
                continue
            }
        }

        // Stream ended without an explicit completed event — return whatever we
        // gathered rather than losing a valid response.
        if !text.isEmpty || !toolCalls.isEmpty {
            return AssistantReply(text: text.isEmpty ? nil : text, toolCalls: toolCalls)
        }
        throw AIServiceError.emptyResponse
    }

    // MARK: - Request encoding

    private static func toolJSON(_ tool: ToolDefinition) -> JSONValue {
        .object([
            "type": .string("function"),
            "name": .string(tool.name),
            "description": .string(tool.description),
            "parameters": JSONValue.parse(tool.parametersSchemaJSON),
        ])
    }

    private static func inputJSON(_ turns: [ChatTurn]) -> [JSONValue] {
        var items: [JSONValue] = []
        for turn in turns {
            switch turn {
            case .user(let text):
                items.append(.object([
                    "type": .string("message"),
                    "role": .string("user"),
                    "content": .array([.object([
                        "type": .string("input_text"),
                        "text": .string(text),
                    ])]),
                ]))

            case .assistant(let text, let toolCalls):
                if let text, !text.isEmpty {
                    items.append(.object([
                        "type": .string("message"),
                        "role": .string("assistant"),
                        "content": .array([.object([
                            "type": .string("output_text"),
                            "text": .string(text),
                        ])]),
                    ]))
                }
                for call in toolCalls {
                    items.append(.object([
                        "type": .string("function_call"),
                        "call_id": .string(call.id),
                        "name": .string(call.name),
                        "arguments": .string(call.argumentsJSON),
                    ]))
                }

            case .toolResults(let results):
                for result in results {
                    items.append(.object([
                        "type": .string("function_call_output"),
                        "call_id": .string(result.toolCallID),
                        "output": .string(result.content),
                    ]))
                }
            }
        }
        return items
    }

    // MARK: - SSE decoding

    private struct SSEEvent: Decodable {
        let type: String
        let response: ResponseObject?
        let delta: String?
        let item: OutputItem?

        struct ResponseObject: Decodable {
            let output: [OutputItem]?
            let error: ErrorObject?
        }

        struct OutputItem: Decodable {
            let type: String
            let role: String?
            let content: [ContentPart]?
            let name: String?
            let arguments: String?
            let callID: String?

            enum CodingKeys: String, CodingKey {
                case type, role, content, name, arguments
                case callID = "call_id"
            }
        }

        struct ContentPart: Decodable {
            let type: String
            let text: String?
        }

        struct ErrorObject: Decodable {
            let message: String?
        }
    }
}
