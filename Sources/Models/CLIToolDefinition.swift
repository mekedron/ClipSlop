import Foundation

struct CLIToolDefinition: Sendable, Identifiable {
    let id: String
    let displayName: String
    let binaryNames: [String]
    let iconName: String
    /// If true, the service writes output to a temp file via `-o` and reads it back.
    /// Needed for tools (like codex) that dump agent logs to stdout.
    let usesOutputFile: Bool
    let buildArguments: @Sendable (_ text: String, _ systemPrompt: String, _ outputFilePath: String?) -> [String]

    static let knownTools: [CLIToolDefinition] = [
        CLIToolDefinition(
            id: "claude",
            displayName: "Claude Code",
            binaryNames: ["claude"],
            iconName: "provider-claude",
            usesOutputFile: false,
            buildArguments: { text, systemPrompt, _ in
                let combined = systemPrompt.isEmpty ? text : "\(systemPrompt)\n\n\(text)"
                return ["-p", combined, "--output-format", "text"]
            }
        ),
        CLIToolDefinition(
            id: "codex",
            displayName: "Codex CLI",
            binaryNames: ["codex"],
            iconName: "provider-codex",
            usesOutputFile: true,
            buildArguments: { text, systemPrompt, outputFile in
                let combined = systemPrompt.isEmpty ? text : "\(systemPrompt)\n\n\(text)"
                var args = [
                    "exec", combined,
                    "--skip-git-repo-check",
                    "--sandbox", "read-only",
                    "--ephemeral",
                ]
                if let outputFile {
                    args += ["-o", outputFile]
                }
                return args
            }
        ),
    ]

    static func find(byID id: String) -> CLIToolDefinition? {
        knownTools.first { $0.id == id }
    }
}
