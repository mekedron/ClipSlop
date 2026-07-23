import Foundation

/// The Settings Assistant's Magic-engine tools: definitions, name registry,
/// and the single path-confinement gate every file argument passes through.
/// Execution lives in `EngineToolExecutor`; the prompt-library tools stay in
/// `PromptLibraryTools` (their storage moves in §7.3 — the seam is the
/// executor, the model-facing names and schemas here never change).
enum EngineTools {

    /// Core files writable by name — the whitelist *is* the schema enum.
    static let coreFileNames = [
        "identity.md", "writing-style.md", "constraints.md", "aliases.md",
        "system-prompt.md",
    ]

    /// Top-level engine files readable by relative path.
    static let topLevelReadable: Set<String> = [
        "config.yaml", "providers.yaml", "roles.yaml", "system-prompt.md",
    ]

    static func contains(_ toolName: String) -> Bool {
        all.contains { $0.name == toolName }
    }

    static func isMutating(_ toolName: String) -> Bool {
        all.first { $0.name == toolName }?.isMutating ?? false
    }

    static let all: [ToolDefinition] = [
        // MARK: Read-only
        ToolDefinition(
            name: "list_engine_files",
            description: "List the Magic Button engine tree (~/.clipslop): config.yaml, system-prompt.md, providers.yaml, roles.yaml, core/*.md, and every workflow markdown file with its parsed id and any load error. Call this before referencing any engine file by path.",
            parametersSchemaJSON: #"{"type":"object","properties":{},"additionalProperties":false}"#,
            isMutating: false
        ),
        ToolDefinition(
            name: "read_engine_file",
            description: "Read one engine file. path is relative to the engine root, e.g. \"config.yaml\", \"core/writing-style.md\", \"workflows/base/reply.md\". Only engine files are readable — no other filesystem access.",
            parametersSchemaJSON: #"{"type":"object","properties":{"path":{"type":"string","description":"Engine-relative path from list_engine_files."}},"required":["path"],"additionalProperties":false}"#,
            isMutating: false
        ),
        ToolDefinition(
            name: "engine_status",
            description: "Engine health report: how many workflows loaded and every load error/warning, config.yaml parse warnings, providers.yaml/roles.yaml parse warnings, the provider list (no secrets), and how each engine role currently resolves (which provider serves it, or why it refuses).",
            parametersSchemaJSON: #"{"type":"object","properties":{},"additionalProperties":false}"#,
            isMutating: false
        ),
        ToolDefinition(
            name: "read_traces",
            description: "Read recent Magic Button press traces (contentless: routing, verifier, latency, outcome — never any text content), newest first. Use this plus explain_press to answer why a press behaved the way it did.",
            parametersSchemaJSON: #"""
            {"type":"object","properties":{"count":{"type":"integer","description":"How many traces to return (default 20, max 200)."},"app":{"type":"string","description":"Only traces whose app bundle id contains this (case-insensitive)."},"outcome_prefix":{"type":"string","description":"Only traces whose outcome starts with this, e.g. \"error\", \"dead\", \"insertedAnyway\"."},"presentation":{"type":"string","enum":["silent","chips","chips_forced"]},"situation_contains":{"type":"string","description":"Only traces whose situationClass contains this."},"verifier_failed":{"type":"boolean","description":"true → only traces where the verifier flagged the output."}},"additionalProperties":false}
            """#,
            isMutating: false
        ),
        ToolDefinition(
            name: "explain_press",
            description: "Explain one Magic Button press from its trace: what was captured, how it routed (tier, candidates, silent vs chips), what generated, what the verifier said, latency vs SLO, and what the outcome string means. Defaults to the most recent press.",
            parametersSchemaJSON: #"{"type":"object","properties":{"trace_id":{"type":"string","description":"traceID (or unique prefix) from read_traces; omit for the latest press."}},"additionalProperties":false}"#,
            isMutating: false
        ),
        ToolDefinition(
            name: "trace_stats",
            description: "Aggregate all stored press traces into the gate report: latency percentiles vs SLO, chip top-1 rate, silent/undo/insert-anyway rates, warm-observer hit rate, accessibility error counts, outcome distribution.",
            parametersSchemaJSON: #"{"type":"object","properties":{},"additionalProperties":false}"#,
            isMutating: false
        ),
        ToolDefinition(
            name: "spend_summary",
            description: "Token spend per engine role, today and this month, from the spend ledger. Estimated counts (no usage reported by the API) are flagged.",
            parametersSchemaJSON: #"{"type":"object","properties":{},"additionalProperties":false}"#,
            isMutating: false
        ),

        // MARK: Mutating
        ToolDefinition(
            name: "write_workflow",
            description: "Create or overwrite a workflow markdown file (YAML frontmatter card + body). path must be under workflows/ and end in .md, e.g. \"workflows/comment.social.md\". The content is validated with the engine's own parser against the whole catalog (duplicate ids, extends chains) BEFORE writing — a validation error is returned with its line number and nothing is written.",
            parametersSchemaJSON: #"{"type":"object","properties":{"path":{"type":"string","description":"Engine-relative path under workflows/."},"content":{"type":"string","description":"Full file content: --- frontmatter --- then the markdown body."}},"required":["path","content"],"additionalProperties":false}"#,
            isMutating: true
        ),
        ToolDefinition(
            name: "delete_workflow",
            description: "Delete a workflow file. Warns when other workflows extend the id defined in it (they would be disabled).",
            parametersSchemaJSON: #"{"type":"object","properties":{"path":{"type":"string","description":"Engine-relative path under workflows/."}},"required":["path"],"additionalProperties":false}"#,
            isMutating: true
        ),
        ToolDefinition(
            name: "write_core_file",
            description: "Write one of the pinned core files that enter every Magic generation prompt (identity.md, writing-style.md, constraints.md, aliases.md) or the system-prompt.md override. For constraints.md the result reports how many machine-checkable rules ('- never say: \"…\"' / '- never match: /…/') were recognized.",
            parametersSchemaJSON: #"{"type":"object","properties":{"name":{"type":"string","enum":["identity.md","writing-style.md","constraints.md","aliases.md","system-prompt.md"]},"content":{"type":"string","description":"Full new file content (markdown)."}},"required":["name","content"],"additionalProperties":false}"#,
            isMutating: true
        ),
        ToolDefinition(
            name: "set_config",
            description: "Change engine tuning values in config.yaml. values maps key → new value: an integer for numeric keys, a list of strings for no_cloud, or null to remove the line (falling back to the default). Comments in the file are preserved. Out-of-range or unknown keys are rejected with the valid range BEFORE anything is written.",
            parametersSchemaJSON: #"{"type":"object","properties":{"values":{"type":"object","description":"config key → new value (integer, list for no_cloud, or null to reset to default)."}},"required":["values"],"additionalProperties":false}"#,
            isMutating: true
        ),
        ToolDefinition(
            name: "set_role",
            description: "Change a role binding in roles.yaml: which provider serves an engine role, its fallback chain, request timeout, and minimum cost class. Providers are referenced by name (or id) from engine_status. Never touches API keys.",
            parametersSchemaJSON: #"""
            {"type":"object","properties":{"role":{"type":"string","enum":["generation.magic","chat.assistant"]},"provider":{"type":"string","description":"Provider name or id; \"default\" clears the binding (follow the app default)."},"fallbacks":{"type":"array","items":{"type":"string"},"description":"Provider names or ids, tried in order; [] clears."},"timeout_seconds":{"type":"integer","description":"1–600; 0 clears the per-role timeout."},"min_cost_class":{"type":"string","enum":["local","mid","premium","none"],"description":"Cost floor — generation refuses instead of silently downgrading; \"none\" clears."}},"required":["role"],"additionalProperties":false}
            """#,
            isMutating: true
        ),
        ToolDefinition(
            name: "set_provider_metadata",
            description: "Edit a provider's engine metadata in providers.yaml: locality (the data path: local|cloud) and cost_class (local|mid|premium). \"derived\" restores automatic derivation. Nothing else about a provider is editable here — API keys, endpoints and models are managed in Settings and the Keychain.",
            parametersSchemaJSON: #"{"type":"object","properties":{"provider":{"type":"string","description":"Provider name or id."},"locality":{"type":"string","enum":["local","cloud","derived"]},"cost_class":{"type":"string","enum":["local","mid","premium","derived"]}},"required":["provider"],"additionalProperties":false}"#,
            isMutating: true
        ),
    ]

    // MARK: - Path confinement

    /// Resolves an engine-relative path against `root`, rejecting anything
    /// that could reach outside the engine tree. This is the only gate file
    /// arguments pass through — there is no tool that takes an absolute path.
    nonisolated static func confine(_ relativePath: String, under root: URL) throws -> URL {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ToolError(message: "Empty path.")
        }
        guard !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~") else {
            throw ToolError(message: "Paths must be relative to the engine root, like \"workflows/reply.md\".")
        }
        guard !trimmed.components(separatedBy: "/").contains("..") else {
            throw ToolError(message: "Path must not contain '..'.")
        }
        let rootPath = root.standardizedFileURL.path
        let candidate = root.appendingPathComponent(trimmed).standardizedFileURL
        guard candidate.path.hasPrefix(rootPath + "/") else {
            throw ToolError(message: "Path escapes the engine directory.")
        }
        return candidate
    }

    /// Readable whitelist: the four top-level engine files, core/*.md, and
    /// workflows/**.md. Logs are served by the trace tools only; the
    /// full-content debug logs are deliberately unreachable.
    nonisolated static func confineReadable(_ relativePath: String, under root: URL) throws -> URL {
        let url = try confine(relativePath, under: root)
        let relative = String(url.path.dropFirst(root.standardizedFileURL.path.count + 1))
        let parts = relative.components(separatedBy: "/")

        if parts.count == 1, topLevelReadable.contains(parts[0]) { return url }
        if parts.first == "core", parts.count == 2, url.pathExtension == "md" { return url }
        if parts.first == "workflows", parts.count >= 2, url.pathExtension == "md" { return url }
        throw ToolError(message: "'\(relativePath)' is not a readable engine file. Readable: config.yaml, providers.yaml, roles.yaml, system-prompt.md, core/*.md, workflows/**.md.")
    }

    /// Writable workflow paths: under workflows/, .md extension.
    nonisolated static func confineWorkflow(_ relativePath: String, under root: URL) throws -> URL {
        let url = try confine(relativePath, under: root)
        let relative = String(url.path.dropFirst(root.standardizedFileURL.path.count + 1))
        let parts = relative.components(separatedBy: "/")
        guard parts.first == "workflows", parts.count >= 2, url.pathExtension == "md" else {
            throw ToolError(message: "Workflow paths must be under workflows/ and end in .md, like \"workflows/comment.social.md\".")
        }
        return url
    }
}
