import Foundation

// MARK: - JSONValue

/// A minimal JSON tree. Used to embed hand-authored tool schemas into request
/// bodies and to re-encode a model's structured tool arguments back to a
/// string. Encodes/decodes to plain JSON with no wrapper keys.
enum JSONValue: Codable, Sendable, Hashable {
    case string(String)
    case int(Int)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let int = try? container.decode(Int.self) {
            self = .int(int)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    /// Parses a JSON string into a `JSONValue` (defaults to an empty object).
    static func parse(_ jsonString: String) -> JSONValue {
        guard let data = jsonString.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return .object([:]) }
        return value
    }

    /// Serializes back to a compact JSON string.
    func jsonString() -> String {
        guard let data = try? JSONEncoder().encode(self),
              let string = String(data: data, encoding: .utf8)
        else { return "{}" }
        return string
    }

    // MARK: - Convenience accessors (for reading decoded tool arguments)

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }
}

// MARK: - Tool call / result

/// A single tool invocation requested by the model.
struct ToolCallRequest: Sendable, Hashable, Identifiable {
    /// Provider-specific correlation id (Anthropic `tool_use.id`,
    /// OpenAI `tool_calls[].id`, Responses `call_id`).
    let id: String
    let name: String
    /// The tool arguments as a JSON object string.
    let argumentsJSON: String
}

/// The outcome of running a tool, fed back to the model on the next turn.
struct ToolResult: Sendable, Hashable {
    let toolCallID: String
    let content: String
    var isError: Bool = false
}

// MARK: - Conversation turns

/// A provider-neutral conversation turn. Each `ToolChatService` maps these to
/// its own wire format.
enum ChatTurn: Sendable {
    case user(String)
    case assistant(text: String?, toolCalls: [ToolCallRequest])
    case toolResults([ToolResult])
}

// MARK: - Tool definition

/// A tool the model may call, plus whether running it mutates the library
/// (mutating tools pause for user confirmation; read-only tools auto-run).
struct ToolDefinition: Sendable {
    let name: String
    let description: String
    /// A JSON Schema object describing the parameters, as a JSON string.
    let parametersSchemaJSON: String
    let isMutating: Bool
}

// MARK: - Assistant reply

/// One decoded response from the model: any assistant text plus any tool calls.
struct AssistantReply: Sendable {
    let text: String?
    let toolCalls: [ToolCallRequest]
}

// MARK: - Service protocol

/// Non-streaming, tool-calling chat. Separate from the one-shot `AIService`;
/// only providers that support function calling implement it.
protocol ToolChatService: Sendable {
    func send(
        messages: [ChatTurn],
        systemPrompt: String,
        tools: [ToolDefinition],
        config: AIProviderConfig
    ) async throws -> AssistantReply
}

enum ToolChatServiceFactory {
    /// Returns a tool-calling chat service for the provider, or `nil` if the
    /// provider type can't do tool calling.
    static func service(for providerType: AIProviderType) -> ToolChatService? {
        switch providerType {
        case .anthropic:
            AnthropicToolChatService()
        case .openAI, .ollama, .openAICompatible:
            OpenAIToolChatService()
        case .openAIChatGPT:
            ChatGPTToolChatService()
        case .cliTool:
            nil
        }
    }
}
