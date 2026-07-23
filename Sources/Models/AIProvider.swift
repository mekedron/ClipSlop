import Foundation

enum AIProviderType: String, Codable, Sendable, CaseIterable, Identifiable {
    case openAIChatGPT
    case openAI
    case anthropic
    case ollama
    case openAICompatible
    case cliTool

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAIChatGPT: "OpenAI (Sign In)"
        case .openAI: "OpenAI (API Key)"
        case .anthropic: "Anthropic (API Key)"
        case .ollama: "Ollama (Local)"
        case .openAICompatible: "OpenAI Compatible"
        case .cliTool: "CLI Tool"
        }
    }

    var iconName: String {
        switch self {
        case .openAIChatGPT: "provider-openai"
        case .openAI: "provider-openai"
        case .anthropic: "provider-anthropic"
        case .ollama: "provider-ollama"
        case .openAICompatible: "globe"         // SF Symbol
        case .cliTool: "apple.terminal"          // SF Symbol
        }
    }

    /// Whether `iconName` refers to a bundled asset (true) or SF Symbol (false).
    var usesAssetIcon: Bool {
        switch self {
        case .openAICompatible, .cliTool: false
        default: true
        }
    }

    /// Resolves the icon name for a specific provider config (uses CLI tool icon if available).
    func resolvedIconName(modelID: String? = nil) -> (name: String, isAsset: Bool) {
        if self == .cliTool, let modelID,
           let tool = CLIToolDefinition.find(byID: modelID) {
            return (tool.iconName, true)
        }
        return (iconName, usesAssetIcon)
    }

    @MainActor
    var providerDescription: String {
        Loc.shared.t("settings.providers.desc.\(rawValue)")
    }

    var requiresAPIKey: Bool {
        switch self {
        case .ollama, .cliTool, .openAIChatGPT: false
        default: true
        }
    }

    var requiresOAuth: Bool {
        self == .openAIChatGPT
    }

    var defaultBaseURL: String {
        switch self {
        case .anthropic: Constants.Anthropic.baseURL
        case .openAI: Constants.OpenAI.baseURL
        case .openAIChatGPT: Constants.ChatGPT.baseURL
        case .ollama: Constants.Ollama.baseURL
        case .openAICompatible: ""
        case .cliTool: ""
        }
    }

    var defaultModel: String {
        switch self {
        case .anthropic: Constants.Anthropic.defaultModel
        case .openAI: Constants.OpenAI.defaultModel
        case .openAIChatGPT: Constants.ChatGPT.defaultModel
        case .ollama: Constants.Ollama.defaultModel
        case .openAICompatible: ""
        case .cliTool: ""
        }
    }

    /// Whether this provider uses the Anthropic Messages API format
    var usesAnthropicAPI: Bool {
        self == .anthropic
    }

    var supportsReasoningEffort: Bool {
        !supportedReasoningEfforts.isEmpty
    }

    /// The reasoning-effort values this provider type accepts, empty when the
    /// provider has no reasoning control. All types share the single
    /// `AIProviderConfig.reasoningEffort` field; only the allowed values differ.
    var supportedReasoningEfforts: [ReasoningEffort] {
        switch self {
        case .openAIChatGPT: [.low, .medium, .high, .xhigh]
        case .ollama: [.none, .low, .medium, .high, .max]
        default: []
        }
    }

    /// Effort a freshly created provider entry starts with. ChatGPT keeps its
    /// historical `.low` default; everything else starts unset so the field is
    /// omitted from requests and the provider's own default applies.
    var defaultReasoningEffort: ReasoningEffort? {
        self == .openAIChatGPT ? .low : nil
    }

    /// Whether this provider can drive the prompt-library assistant, which
    /// relies on function/tool calling. The CLI-tool provider shells out to an
    /// external binary with no structured tool protocol, so it's excluded.
    var supportsToolCalling: Bool {
        switch self {
        case .anthropic, .openAI, .ollama, .openAICompatible, .openAIChatGPT: true
        case .cliTool: false
        }
    }
}

enum ReasoningEffort: String, Codable, Sendable, CaseIterable, Identifiable {
    case none
    case low
    case medium
    case high
    case xhigh
    case max

    var id: String { rawValue }

    @MainActor
    var displayName: String {
        Loc.shared.t("settings.providers.reasoning_effort.\(rawValue)")
    }
}

extension AIProviderConfig {
    /// The effort value to put on the wire, or nil when the effort is unset or
    /// the stored value isn't valid for this provider type.
    var effectiveReasoningEffort: String? {
        guard let effort = reasoningEffort,
              providerType.supportedReasoningEfforts.contains(effort) else { return nil }
        return effort.rawValue
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
    var temperature: Double
    /// nil means unset: no effort field is sent and the provider's own default applies.
    var reasoningEffort: ReasoningEffort?

    init(
        id: UUID = UUID(),
        name: String,
        providerType: AIProviderType,
        baseURL: String? = nil,
        apiKeyRef: String? = nil,
        modelID: String? = nil,
        isDefault: Bool = false,
        maxTokens: Int = Constants.Defaults.maxTokens,
        temperature: Double = Constants.Defaults.temperature,
        reasoningEffort: ReasoningEffort? = nil
    ) {
        self.id = id
        self.name = name
        self.providerType = providerType
        self.baseURL = baseURL ?? providerType.defaultBaseURL
        self.apiKeyRef = apiKeyRef ?? "clipslop.api-key.\(id.uuidString)"
        self.modelID = modelID ?? providerType.defaultModel
        self.isDefault = isDefault
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.reasoningEffort = reasoningEffort ?? providerType.defaultReasoningEffort
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, providerType, baseURL, apiKeyRef, modelID, isDefault, maxTokens, temperature
        case reasoningEffortSetting
        case legacyReasoningEffort = "reasoningEffort"
        case legacyOllamaReasoningEffort = "ollamaReasoningEffort"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        providerType = try container.decode(AIProviderType.self, forKey: .providerType)
        baseURL = try container.decode(String.self, forKey: .baseURL)
        apiKeyRef = try container.decode(String.self, forKey: .apiKeyRef)
        modelID = try container.decode(String.self, forKey: .modelID)
        isDefault = try container.decode(Bool.self, forKey: .isDefault)
        maxTokens = try container.decode(Int.self, forKey: .maxTokens)
        temperature = try container.decode(Double.self, forKey: .temperature)

        // Older builds persisted an inert `.low` under "reasoningEffort" for
        // every provider type while only ChatGPT honored it, so the unified
        // value lives under a fresh key and the legacy one is trusted for
        // ChatGPT alone. "ollamaReasoningEffort" was written by pre-merge
        // builds of the Ollama reasoning-effort branch ("unset" and unknown
        // values degrade to nil rather than failing the provider-list decode).
        let storedEffort: String? = if let unified = try container.decodeIfPresent(
            String.self, forKey: .reasoningEffortSetting
        ) {
            unified
        } else if providerType == .openAIChatGPT {
            try container.decodeIfPresent(String.self, forKey: .legacyReasoningEffort)
        } else if providerType == .ollama {
            try container.decodeIfPresent(String.self, forKey: .legacyOllamaReasoningEffort)
        } else {
            nil
        }
        reasoningEffort = storedEffort.flatMap(ReasoningEffort.init(rawValue:))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(providerType, forKey: .providerType)
        try container.encode(baseURL, forKey: .baseURL)
        try container.encode(apiKeyRef, forKey: .apiKeyRef)
        try container.encode(modelID, forKey: .modelID)
        try container.encode(isDefault, forKey: .isDefault)
        try container.encode(maxTokens, forKey: .maxTokens)
        try container.encode(temperature, forKey: .temperature)
        try container.encodeIfPresent(reasoningEffort, forKey: .reasoningEffortSetting)
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
