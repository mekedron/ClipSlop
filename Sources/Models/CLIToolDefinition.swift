import Foundation

struct CLIToolDefinition: Sendable, Identifiable {
    let id: String
    let displayName: String
    let binaryNames: [String]
    let iconName: String
    /// If true, the service writes output to a temp file via `-o` and reads it back.
    /// Needed for tools (like codex) that dump agent logs to stdout.
    let usesOutputFile: Bool
    /// `model`/`effort` come from the provider config (`model: "claude/sonnet"`,
    /// `reasoning_effort:`); nil means "let the tool use its own default".
    let buildArguments: @Sendable (
        _ text: String, _ systemPrompt: String, _ outputFilePath: String?,
        _ model: String?, _ effort: String?
    ) -> [String]

    static let knownTools: [CLIToolDefinition] = [
        CLIToolDefinition(
            id: "claude",
            displayName: "Claude Code",
            binaryNames: ["claude"],
            iconName: "provider-claude",
            usesOutputFile: false,
            buildArguments: { text, systemPrompt, _, model, effort in
                let combined = systemPrompt.isEmpty ? text : "\(systemPrompt)\n\n\(text)"
                // --strict-mcp-config: a press needs one text generation,
                // never the user's MCP servers — loading them costs seconds
                // of startup and hands screen content to tools that have no
                // business seeing it.
                var args = ["-p", combined, "--output-format", "text", "--strict-mcp-config"]
                // Without an explicit model the CLI inherits the user's
                // Claude Code session default — which may be a deep-thinking
                // configuration that turns a one-comment generation into a
                // 30-second wait.
                if let model { args += ["--model", model] }
                if let effort, effort != "none" { args += ["--effort", effort] }
                return args
            }
        ),
        CLIToolDefinition(
            id: "codex",
            displayName: "Codex CLI",
            binaryNames: ["codex"],
            iconName: "provider-codex",
            usesOutputFile: true,
            buildArguments: { text, systemPrompt, outputFile, model, _ in
                let combined = systemPrompt.isEmpty ? text : "\(systemPrompt)\n\n\(text)"
                var args = [
                    "exec", combined,
                    "--skip-git-repo-check",
                    "--sandbox", "read-only",
                    "--ephemeral",
                ]
                if let model { args += ["-m", model] }
                if let outputFile {
                    args += ["-o", outputFile]
                }
                return args
            }
        ),
    ]

    /// A cliTool provider's `model` field addresses the tool, optionally
    /// followed by the underlying model the tool should run: "claude" or
    /// "claude/sonnet". One home for the split, so the service, the settings
    /// UI, and the icon resolver all read the same identity.
    static func parseModelID(_ modelID: String) -> (toolID: String, model: String?) {
        guard let slash = modelID.firstIndex(of: "/") else { return (modelID, nil) }
        let model = String(modelID[modelID.index(after: slash)...])
        return (String(modelID[..<slash]), model.isEmpty ? nil : model)
    }

    static func find(byID id: String) -> CLIToolDefinition? {
        let toolID = parseModelID(id).toolID
        return knownTools.first { $0.id == toolID }
    }
}
