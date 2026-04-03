import Foundation

enum AIProviderType: String, Codable, Sendable, CaseIterable, Identifiable {
    case anthropic
    case openAI
    case ollama
    case openAICompatible
    case cliTool

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .anthropic: "Anthropic (Claude)"
        case .openAI: "OpenAI (GPT)"
        case .ollama: "Ollama (Local)"
        case .openAICompatible: "OpenAI Compatible"
        case .cliTool: "CLI Tool"
        }
    }

    var requiresAPIKey: Bool {
        switch self {
        case .ollama, .cliTool: false
        default: true
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .anthropic: Constants.Anthropic.baseURL
        case .openAI: Constants.OpenAI.baseURL
        case .ollama: Constants.Ollama.baseURL
        case .openAICompatible: ""
        case .cliTool: ""
        }
    }

    var defaultModel: String {
        switch self {
        case .anthropic: Constants.Anthropic.defaultModel
        case .openAI: Constants.OpenAI.defaultModel
        case .ollama: Constants.Ollama.defaultModel
        case .openAICompatible: ""
        case .cliTool: ""
        }
    }

    /// Whether this provider uses the Anthropic Messages API format
    var usesAnthropicAPI: Bool {
        self == .anthropic
    }
}

struct AIProviderConfig: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var providerType: AIProviderType
    var baseURL: String
    var apiKeyRef: String  // Keychain reference key, not the actual secret
    var modelID: String
    var isDefault: Bool
    var maxTokens: Int

    init(
        id: UUID = UUID(),
        name: String,
        providerType: AIProviderType,
        baseURL: String? = nil,
        apiKeyRef: String? = nil,
        modelID: String? = nil,
        isDefault: Bool = false,
        maxTokens: Int = Constants.Defaults.maxTokens
    ) {
        self.id = id
        self.name = name
        self.providerType = providerType
        self.baseURL = baseURL ?? providerType.defaultBaseURL
        self.apiKeyRef = apiKeyRef ?? "clipslop.api-key.\(id.uuidString)"
        self.modelID = modelID ?? providerType.defaultModel
        self.isDefault = isDefault
        self.maxTokens = maxTokens
    }

    static let builtInAnthropic = AIProviderConfig(
        name: "Anthropic",
        providerType: .anthropic,
        isDefault: true
    )

    static let builtInOpenAI = AIProviderConfig(
        name: "OpenAI",
        providerType: .openAI
    )

    static let builtInOllama = AIProviderConfig(
        name: "Ollama",
        providerType: .ollama,
        modelID: "llama3.2"
    )
}
