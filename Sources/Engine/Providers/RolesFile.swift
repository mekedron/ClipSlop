import Foundation

/// Codec for `~/.clipslop/roles.yaml` (§14): which provider serves each
/// engine role, with fallback chains, per-role timeouts, and the
/// no-silent-downgrade cost floor. Lenient like the other engine files —
/// a broken record warns and is skipped, never silently dropped (§15.3).
enum RolesFile {
    struct ParseResult: Sendable {
        var bindings: [EngineRole: RoleBinding] = [:]
        var warnings: [String] = []
    }

    static let knownKeys: Set<String> = [
        "role", "provider", "fallbacks", "timeout_seconds", "min_cost_class",
    ]

    static func parse(_ text: String) -> ParseResult {
        var result = ParseResult()
        let document: FrontmatterDocument
        do {
            document = try FrontmatterParser.parse(text)
        } catch let error as FrontmatterError {
            result.warnings.append("roles.yaml line \(error.line): \(error.message)")
            return result
        } catch {
            result.warnings.append("roles.yaml: \(error.localizedDescription)")
            return result
        }

        guard let value = document.fields["roles"] else {
            result.warnings.append("roles.yaml: missing 'roles:' list")
            return result
        }
        if case .list(let items) = value, items.isEmpty { return result }  // `roles: []`
        guard case .mapList(let records) = value else {
            result.warnings.append("roles.yaml: 'roles:' must be a list of records ('- role: …')")
            return result
        }

        for (index, record) in records.enumerated() {
            func line(_ key: String) -> String {
                document.fieldLines["roles.\(index).\(key)"].map { "line \($0)" } ?? "record \(index + 1)"
            }
            func scalar(_ key: String) -> String? {
                if case .scalar(let s) = record[key] { return s }
                return nil
            }

            for key in record.keys where !knownKeys.contains(key) {
                result.warnings.append("roles.yaml \(line(key)): unknown key '\(key)' ignored")
            }

            guard let roleText = scalar("role"), let role = EngineRole(rawValue: roleText) else {
                let valid = EngineRole.allCases.map(\.rawValue).joined(separator: ", ")
                result.warnings.append("roles.yaml \(line("role")): unknown role '\(scalar("role") ?? "")' (valid: \(valid)) — skipped")
                continue
            }
            guard result.bindings[role] == nil else {
                result.warnings.append("roles.yaml \(line("role")): duplicate role '\(roleText)' — first record kept")
                continue
            }

            var binding = RoleBinding()
            if let providerText = scalar("provider") {
                if let id = UUID(uuidString: providerText) {
                    binding.provider = id
                } else {
                    result.warnings.append("roles.yaml \(line("provider")): 'provider' must be a provider id (UUID) — ignored")
                }
            }
            if let fallbacks = record["fallbacks"] {
                if case .list(let items) = fallbacks {
                    for item in items {
                        if let id = UUID(uuidString: item) {
                            binding.fallbacks.append(id)
                        } else {
                            result.warnings.append("roles.yaml \(line("fallbacks")): fallback '\(item)' is not a provider id (UUID) — ignored")
                        }
                    }
                } else {
                    result.warnings.append("roles.yaml \(line("fallbacks")): 'fallbacks' must be a list like [id, id]")
                }
            }
            if let raw = scalar("timeout_seconds") {
                if let seconds = Int(raw), (1...600).contains(seconds) {
                    binding.timeoutSeconds = seconds
                } else {
                    result.warnings.append("roles.yaml \(line("timeout_seconds")): 'timeout_seconds' must be 1–600 — ignored")
                }
            }
            if let raw = scalar("min_cost_class") {
                if let minClass = ProviderCostClass(rawValue: raw) {
                    binding.minCostClass = minClass
                } else {
                    result.warnings.append("roles.yaml \(line("min_cost_class")): min_cost_class must be local|mid|premium — ignored")
                }
            }
            result.bindings[role] = binding
        }
        return result
    }

    static func serialize(_ bindings: [EngineRole: RoleBinding]) -> String {
        var out = """
        ---
        # ClipSlop model roles (§14): which provider serves each engine role.
        # `provider`/`fallbacks` are provider ids from providers.yaml, tried
        # in order (the app default is always the implicit last resort).
        # `timeout_seconds` bounds one request; `min_cost_class`
        # (local|mid|premium) refuses generation instead of silently using a
        # cheaper provider when nothing qualified is available.

        """
        let active = EngineRole.allCases.filter { !(bindings[$0] ?? RoleBinding()).isEmpty }
        out += active.isEmpty ? "roles: []\n" : "roles:\n"
        for role in active {
            guard let binding = bindings[role] else { continue }
            out += "  - role: \(role.rawValue)\n"
            if let provider = binding.provider {
                out += "    provider: \(provider.uuidString)\n"
            }
            if !binding.fallbacks.isEmpty {
                out += "    fallbacks: [\(binding.fallbacks.map(\.uuidString).joined(separator: ", "))]\n"
            }
            if let timeout = binding.timeoutSeconds {
                out += "    timeout_seconds: \(timeout)\n"
            }
            if let minClass = binding.minCostClass {
                out += "    min_cost_class: \(minClass.rawValue)\n"
            }
        }
        out += "---\n"
        return out
    }
}
