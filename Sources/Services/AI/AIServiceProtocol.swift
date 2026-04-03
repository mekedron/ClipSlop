import Foundation

protocol AIService: Sendable {
    func process(text: String, systemPrompt: String, config: AIProviderConfig) async throws -> String
    func stream(text: String, systemPrompt: String, config: AIProviderConfig) -> AsyncThrowingStream<String, Error>
}

enum AIServiceError: LocalizedError {
    case invalidURL
    case missingAPIKey
    case httpError(statusCode: Int, body: String)
    case decodingError(String)
    case networkError(Error)
    case emptyResponse
    case cancelled
    case cliToolNotFound(String)
    case cliToolFailed(exitCode: Int32, stderr: String)
    case cliToolTimeout

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Invalid API endpoint URL"
        case .missingAPIKey:
            "API key is not configured. Please add it in Settings."
        case .httpError(let code, let body):
            switch code {
            case 401: "Invalid API key. Please check your key in Settings."
            case 429: "Rate limited. Please wait a moment and try again."
            case 500...599: "Server error (\(code)). Please try again later."
            default: "HTTP error \(code): \(body)"
            }
        case .decodingError(let detail):
            "Failed to parse response: \(detail)"
        case .networkError(let error):
            "Network error: \(error.localizedDescription)"
        case .emptyResponse:
            "The AI returned an empty response. Try rephrasing your text."
        case .cancelled:
            "Request was cancelled"
        case .cliToolNotFound(let name):
            "CLI tool '\(name)' not found. Please reinstall it."
        case .cliToolFailed(_, let stderr):
            "CLI tool error: \(stderr.isEmpty ? "unknown error" : stderr)"
        case .cliToolTimeout:
            "CLI tool timed out. The request may be too large."
        }
    }
}

enum AIServiceFactory {
    static func service(for providerType: AIProviderType) -> AIService {
        switch providerType {
        case .anthropic:
            AnthropicService()
        case .cliTool:
            CLIToolService()
        case .openAI, .ollama, .openAICompatible:
            OpenAICompatibleService()
        }
    }
}
