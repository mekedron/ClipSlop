import Foundation

/// The dialect one OpenAI-style `/v1/chat/completions` endpoint speaks for one
/// model.
///
/// The path is shared but the vocabulary is not: the reasoning families
/// (o-series, gpt-5 and later) spell the length cap `max_completion_tokens`,
/// accept only the default `temperature`, and the earliest of them have no
/// `system` role at all, while gpt-4-class models and most self-hosted servers
/// take the original spelling. A field aimed at the wrong dialect is a 400
/// before a single token is generated, so the shape is decided per model
/// rather than fixed at one spelling.
///
/// `starting(for:)` is only a guess. `relaxed(afterRejection:)` turns the
/// endpoint's own 400 into the next guess, which is what lets a model this
/// build has never heard of converge on a request that works instead of
/// failing forever.
struct OpenAIRequestShape: Sendable, Hashable {
    static let maxTokensKey = "max_tokens"
    static let maxCompletionTokensKey = "max_completion_tokens"

    /// Spelling of the response-length cap.
    var tokenLimitKey: String
    /// Whether `temperature` may go on the wire at all.
    var sendsTemperature: Bool
    /// Role carrying the system prompt, or nil when the model has no system
    /// role and the prompt rides on the first user message instead.
    var systemRole: String?
    var sendsReasoningEffort: Bool

    /// Reshapes worth attempting for a single request. Four knobs, so a
    /// request that keeps being rejected is being rejected for a reason no
    /// reshape addresses — a missing key, no quota, a model the account
    /// cannot reach — and must surface as the error it is.
    static let maxReshapes = 4

    // MARK: - Opening guess

    static func starting(for config: AIProviderConfig) -> Self {
        let model = normalizedModelID(config.modelID)
        let openAIHosted = isOpenAIHosted(config)
        return Self(
            // Every model OpenAI still serves accepts the new spelling and
            // only the reasoning families reject the old one, so their own
            // host gets `max_completion_tokens` outright. Third-party and
            // self-hosted servers are the mirror image: most implement the
            // original spelling and nothing else.
            tokenLimitKey: openAIHosted ? maxCompletionTokensKey : maxTokensKey,
            sendsTemperature: !(openAIHosted && isReasoningModel(model)),
            systemRole: openAIHosted && hasNoSystemRole(model) ? nil : "system",
            sendsReasoningEffort: true
        )
    }

    /// True when the request lands on OpenAI's own API — the built-in OpenAI
    /// provider, or a compatible entry pointed at their host.
    static func isOpenAIHosted(_ config: AIProviderConfig) -> Bool {
        if config.providerType == .openAI { return true }
        guard let host = URL(string: config.baseURL)?.host?.lowercased() else { return false }
        return host == "openai.com" || host.hasSuffix(".openai.com")
    }

    /// Strips the route prefix an aggregator prepends (`openai/gpt-4o`) so the
    /// family tests below see the bare id.
    static func normalizedModelID(_ modelID: String) -> String {
        let lowercased = modelID.lowercased()
        guard let slash = lowercased.lastIndex(of: "/") else { return lowercased }
        return String(lowercased[lowercased.index(after: slash)...])
    }

    /// o-series and gpt-5-or-later ids. Matched on the shape of the id rather
    /// than against a list of names, so a model released after this build
    /// still gets the right opening guess.
    static func isReasoningModel(_ model: String) -> Bool {
        if model.first == "o", model.dropFirst().first?.isNumber == true { return true }
        guard model.hasPrefix("gpt-") else { return false }
        guard let major = Int(model.dropFirst(4).prefix(while: \.isNumber)) else { return false }
        return major >= 5
    }

    /// The two reasoning models that reject a `system` message outright rather
    /// than folding it into the developer instructions.
    static func hasNoSystemRole(_ model: String) -> Bool {
        model.hasPrefix("o1-mini") || model.hasPrefix("o1-preview")
    }

    // MARK: - Learning from a rejection

    /// A strictly more permissive shape to retry with, or nil when the
    /// rejection is about something no reshape fixes.
    ///
    /// Returning nil on "no change" is what bounds the retry loop: every
    /// non-nil result drops or renames a field, and there are finitely many.
    func relaxed(afterRejection body: String) -> Self? {
        guard let rejection = Rejection(body: body) else { return nil }
        var next = self

        // The rejection of one spelling is the endorsement of the other. Read
        // `param` in preference to the message: the message that rejects
        // `max_tokens` names `max_completion_tokens` too, as the remedy.
        if rejection.names(tokenLimitKey) {
            next.tokenLimitKey = tokenLimitKey == Self.maxTokensKey
                ? Self.maxCompletionTokensKey
                : Self.maxTokensKey
        }
        if sendsTemperature, rejection.names("temperature") {
            next.sendsTemperature = false
        }
        if sendsReasoningEffort, rejection.names("reasoning_effort") {
            next.sendsReasoningEffort = false
        }
        if systemRole != nil, rejection.rejectsSystemRole {
            next.systemRole = nil
        }

        return next == self ? nil : next
    }

    /// What an endpoint said when it turned a request down, reduced to the two
    /// things worth acting on. `param` is authoritative when present; the
    /// message is the fallback for servers that imitate the API without
    /// filling the field in.
    private struct Rejection {
        let param: String?
        let message: String

        init?(body: String) {
            guard let data = body.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(Envelope.self, from: data)
            else { return nil }
            param = decoded.error.param?.lowercased()
            message = (decoded.error.message ?? "").lowercased()
            if param == nil, message.isEmpty { return nil }
        }

        /// Whether the rejection is about this field.
        func names(_ field: String) -> Bool {
            if let param { return param == field }
            return message.contains("'\(field)'")
        }

        /// A rejected `system` message is reported against the message index
        /// (`messages[0].role`), never against a field name.
        var rejectsSystemRole: Bool {
            if let param, param.hasPrefix("messages["), param.hasSuffix(".role") { return true }
            return message.contains("does not support 'system'")
        }

        private struct Envelope: Decodable {
            let error: ErrorBody

            struct ErrorBody: Decodable {
                let message: String?
                let param: String?
            }
        }
    }

    // MARK: - Emitting the request

    /// Length, sampling and reasoning fields for this shape.
    func tuningParameters(for config: AIProviderConfig) -> [String: JSONValue] {
        var parameters: [String: JSONValue] = [tokenLimitKey: .int(config.maxTokens)]
        // 1 is the API default, so omitting it is indistinguishable from
        // sending it — except that an omitted field cannot be the one a
        // reasoning model rejects.
        if sendsTemperature, config.temperature != 1 {
            parameters["temperature"] = .number(config.temperature)
        }
        if sendsReasoningEffort, let effort = config.effectiveReasoningEffort {
            parameters["reasoning_effort"] = .string(effort)
        }
        return parameters
    }

    /// The leading system message, or nil when this model has no system role
    /// — then `firstUserText` carries the prompt instead.
    func systemMessage(_ prompt: String) -> JSONValue? {
        guard let systemRole, !prompt.isEmpty else { return nil }
        return .object(["role": .string(systemRole), "content": .string(prompt)])
    }

    /// Text of the first user message, carrying the system prompt when the
    /// model has no system role to put it in. Dropping the prompt instead
    /// would answer a different question than the one the workflow asked.
    func firstUserText(_ text: String, systemPrompt: String) -> String {
        guard systemRole == nil, !systemPrompt.isEmpty else { return text }
        return "\(systemPrompt)\n\n\(text)"
    }
}

/// Shapes proven to work, so discovering a model's dialect costs one extra
/// round trip per model per launch instead of one per press.
///
/// Keyed by endpoint and model together: the same id means different things on
/// api.openai.com and on a server imitating it.
actor OpenAIShapeMemo {
    static let shared = OpenAIShapeMemo()

    private var learned: [String: OpenAIRequestShape] = [:]

    func shape(for config: AIProviderConfig) -> OpenAIRequestShape {
        learned[Self.key(config)] ?? .starting(for: config)
    }

    /// Records a shape the endpoint accepted. Only ever called after a 200: a
    /// shape that has not survived a request is a guess, and caching guesses
    /// would make one bad guess permanent for the session.
    func remember(_ shape: OpenAIRequestShape, for config: AIProviderConfig) {
        learned[Self.key(config)] = shape
    }

    private static func key(_ config: AIProviderConfig) -> String {
        "\(config.baseURL)\u{1}\(config.modelID)"
    }
}
