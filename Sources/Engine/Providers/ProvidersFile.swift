import Foundation

/// Codec for `~/.clipslop/providers.yaml` (§14): the provider list as a
/// hand-editable engine file. Secrets never appear here — API keys live in
/// Keychain (referenced by the provider id) and OAuth state stays
/// app-internal. Parsing is lenient the same way config.yaml is: a broken
/// record is skipped with a warning naming the line, never a silent drop of
/// the whole file (§15.3).
enum ProvidersFile {
    struct ParseResult: Sendable {
        var providers: [AIProviderConfig] = []
        var warnings: [String] = []
    }

    static let knownKeys: Set<String> = [
        "id", "name", "type", "base_url", "api_key_ref", "model", "max_tokens",
        "temperature", "reasoning_effort", "default", "locality", "cost_class",
    ]

    /// Accepted `max_tokens` values. The lower bound is the point of the
    /// check: `0` and `-1` copied straight into `AIProviderConfig` go on the
    /// wire from the Anthropic / OpenAI-compatible request builders, and *every*
    /// generation then fails at the API — from a file the app advertises as
    /// validated and hot-reloaded. The upper bound is a loose
    /// sanity rail, well above any model's output ceiling, so a slipped digit
    /// is caught but a future model is not.
    static let maxTokensRange = 1...1_000_000

    /// Whether a hand-written `base_url` can actually be turned into a request.
    ///
    /// The request builders append their path to this value and hand the result
    /// to `URLRequest`, so an unusable one breaks generation for that provider.
    /// `base_url: ""` is the trap worth naming: `URL(string: "")` is nil, and an
    /// empty *scalar* is not the same as an absent key, so `AIProviderConfig`'s
    /// "fall back to the type's default endpoint" does not engage for it. Stop
    /// it at the door — a validated, hot-reloaded config file must not be able
    /// to break generation from a typo (the same reasoning as `maxTokensRange`).
    ///
    /// A scheme and a host are both required, not just parseability:
    /// `URL(string: "api.example.com")` succeeds and yields a *relative* URL
    /// with no host, which `appendingPathComponent` turns into a nonsense
    /// request — and `AIProviderConfig.effectiveLocality` reads `.host` to
    /// decide whether the endpoint is this machine, so a hostless URL silently
    /// derives `.cloud` and the P7 privacy binding stops recognising a local
    /// provider as local.
    static func isUsableBaseURL(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return false }
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            return false
        }
        return !(url.host ?? "").isEmpty
    }

    // MARK: - Parse

    static func parse(_ text: String) -> ParseResult {
        var result = ParseResult()
        let document: FrontmatterDocument
        do {
            document = try FrontmatterParser.parse(text)
        } catch let error as FrontmatterError {
            result.warnings.append("providers.yaml line \(error.line): \(error.message)")
            return result
        } catch {
            result.warnings.append("providers.yaml: \(error.localizedDescription)")
            return result
        }

        guard let value = document.fields["providers"] else {
            result.warnings.append("providers.yaml: missing 'providers:' list")
            return result
        }
        if case .list(let items) = value, items.isEmpty { return result }  // `providers: []`
        guard case .mapList(let records) = value else {
            result.warnings.append("providers.yaml: 'providers:' must be a list of records ('- id: …')")
            return result
        }

        for (index, record) in records.enumerated() {
            func line(_ key: String) -> String {
                document.fieldLines["providers.\(index).\(key)"].map { "line \($0)" } ?? "record \(index + 1)"
            }
            func scalar(_ key: String) -> String? {
                if case .scalar(let s) = record[key] { return s }
                return nil
            }

            for key in record.keys where !knownKeys.contains(key) {
                result.warnings.append("providers.yaml \(line(key)): unknown key '\(key)' ignored")
            }

            guard let idText = scalar("id"), let id = UUID(uuidString: idText) else {
                result.warnings.append("providers.yaml \(line("id")): record \(index + 1) needs a valid 'id' (UUID) — skipped")
                continue
            }
            guard result.providers.allSatisfy({ $0.id != id }) else {
                result.warnings.append("providers.yaml \(line("id")): duplicate id \(idText) — skipped")
                continue
            }
            guard let typeText = scalar("type"), let type = AIProviderType(rawValue: typeText) else {
                let valid = AIProviderType.allCases.map(\.rawValue).joined(separator: ", ")
                result.warnings.append("providers.yaml \(line("type")): unknown type '\(scalar("type") ?? "")' (valid: \(valid)) — skipped")
                continue
            }

            var maxTokens = Constants.Defaults.maxTokens
            if let raw = scalar("max_tokens") {
                if let parsed = Int(raw), maxTokensRange.contains(parsed) {
                    maxTokens = parsed
                } else {
                    result.warnings.append("providers.yaml \(line("max_tokens")): 'max_tokens' must be an integer between \(maxTokensRange.lowerBound) and \(maxTokensRange.upperBound) — default \(Constants.Defaults.maxTokens) kept")
                }
            }
            var temperature = Constants.Defaults.temperature
            if let raw = scalar("temperature") {
                if let parsed = Double(raw) {
                    temperature = parsed
                } else {
                    result.warnings.append("providers.yaml \(line("temperature")): 'temperature' must be a number — default kept")
                }
            }
            var effort: ReasoningEffort?
            if let raw = scalar("reasoning_effort") {
                if let parsed = ReasoningEffort(rawValue: raw) {
                    effort = parsed
                } else {
                    result.warnings.append("providers.yaml \(line("reasoning_effort")): unknown reasoning_effort '\(raw)' ignored")
                }
            }
            var locality: ProviderLocality?
            if let raw = scalar("locality") {
                if let parsed = ProviderLocality(rawValue: raw) {
                    locality = parsed
                } else {
                    result.warnings.append("providers.yaml \(line("locality")): locality must be local|cloud — derived value kept")
                }
            }
            var costClass: ProviderCostClass?
            if let raw = scalar("cost_class") {
                if let parsed = ProviderCostClass(rawValue: raw) {
                    costClass = parsed
                } else {
                    result.warnings.append("providers.yaml \(line("cost_class")): cost_class must be local|mid|premium — derived value kept")
                }
            }

            // nil is "not set", which the memberwise init backfills with the
            // type's default endpoint. An unusable value is reported and mapped
            // back to nil so it takes that same path — keeping the record on a
            // working endpoint, the way an out-of-range `max_tokens` keeps the
            // default rather than skipping the provider.
            var baseURL = scalar("base_url")
            if let raw = baseURL, !isUsableBaseURL(raw) {
                result.warnings.append("providers.yaml \(line("base_url")): 'base_url' must be an absolute http(s) URL like \"https://api.anthropic.com\" — default \(type.defaultBaseURL) kept")
                baseURL = nil
            }

            let isDefault = ["1", "true"].contains(scalar("default") ?? "")
            var config = AIProviderConfig(
                id: id,
                name: scalar("name") ?? type.displayName,
                providerType: type,
                baseURL: baseURL,
                apiKeyRef: scalar("api_key_ref"),
                modelID: scalar("model"),
                isDefault: isDefault,
                maxTokens: maxTokens,
                temperature: temperature,
                reasoningEffort: effort,
                locality: locality,
                costClass: costClass
            )
            // The memberwise init backfills a type default for ChatGPT; a
            // file without the key means "unset", so restore that meaning.
            if scalar("reasoning_effort") == nil { config.reasoningEffort = nil }
            result.providers.append(config)
        }

        let defaults = result.providers.filter(\.isDefault)
        if defaults.count > 1 {
            result.warnings.append("providers.yaml: more than one 'default: 1' — keeping '\(defaults[0].name)'")
            result.providers = result.providers.map { provider in
                var p = provider
                p.isDefault = (p.id == defaults[0].id)
                return p
            }
        }
        return result
    }

    // MARK: - Serialize

    static func serialize(_ providers: [AIProviderConfig]) -> String {
        var out = """
        ---
        # ClipSlop providers (§14). Hand-editable; the app reloads on change
        # and re-writes this file when providers are edited in Settings.
        # API keys are NOT stored here — they live in the macOS Keychain,
        # referenced by the provider id. `locality` (local|cloud) and
        # `cost_class` (local|mid|premium) are derived from the type and
        # base_url when omitted.

        """
        out += providers.isEmpty ? "providers: []\n" : "providers:\n"
        for provider in providers {
            out += "  - id: \(provider.id.uuidString)\n"
            out += "    name: \(quoted(provider.name))\n"
            out += "    type: \(provider.providerType.rawValue)\n"
            if !provider.baseURL.isEmpty {
                out += "    base_url: \(quoted(provider.baseURL))\n"
            }
            if provider.apiKeyRef != "clipslop.api-key.\(provider.id.uuidString)" {
                out += "    api_key_ref: \(quoted(provider.apiKeyRef))\n"
            }
            if !provider.modelID.isEmpty {
                out += "    model: \(quoted(provider.modelID))\n"
            }
            out += "    max_tokens: \(provider.maxTokens)\n"
            out += "    temperature: \(formatted(provider.temperature))\n"
            if let effort = provider.reasoningEffort {
                out += "    reasoning_effort: \(effort.rawValue)\n"
            }
            if provider.isDefault {
                out += "    default: 1\n"
            }
            if let locality = provider.locality {
                out += "    locality: \(locality.rawValue)\n"
            }
            if let costClass = provider.costClass {
                out += "    cost_class: \(costClass.rawValue)\n"
            }
        }
        out += "---\n"
        return out
    }

    private static func quoted(_ text: String) -> String {
        "\"" + text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            + "\""
    }

    private static func formatted(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1_000
            ? String(format: "%.1f", value)
            : String(format: "%g", value)
    }
}
