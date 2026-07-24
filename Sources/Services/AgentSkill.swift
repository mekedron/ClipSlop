import Foundation

/// The bundled ClipSlop Agent Skill (Agent Skills open standard,
/// agentskills.io): `clipslop/SKILL.md` + `references/`, shipped inside the
/// app's resource bundle with its directory shape preserved (see the
/// `.copy("AgentSkill/clipslop")` rule in Package.swift).
///
/// The skill is the single source of truth for engine knowledge:
///
/// - External agents (Claude Code, Codex CLI, …) get it via Settings →
///   Magic → "Install Agent Skill…", which copies the directory to
///   `~/.claude/skills/clipslop/` or a user-chosen export location.
/// - The in-app Settings Assistant loads the `engine-reference` region of
///   SKILL.md into its system prompt (`AssistantSystemPrompt.build`), so
///   the assistant and the exported skill can never teach two different
///   engines.
///
/// Drift tests (`AgentSkillTests`) regenerate the key tables from the
/// engine's own parsers (`MagicEngineConfig`, `WorkflowCardParser`,
/// `ProvidersFile`, `RolesFile`, `PressTrace`) and assert the bundled
/// markdown still names every key — the skill cannot rot silently.
enum AgentSkill {
    /// Directory name; the Agent Skills spec requires it to equal the
    /// frontmatter `name`.
    static let directoryName = "clipslop"

    /// Marker comments in SKILL.md delimiting the engine-knowledge region
    /// the Settings Assistant embeds. `referenceBegin` opens an HTML comment
    /// (explanatory text follows before `-->`), so extraction skips to the
    /// comment's close.
    static let referenceBegin = "<!-- engine-reference:begin"
    static let referenceEnd = "<!-- engine-reference:end -->"

    /// The bundled skill directory (SKILL.md + references/).
    nonisolated static var bundledSkillURL: URL? {
        Bundle.module.url(forResource: directoryName, withExtension: nil)
    }

    nonisolated static func skillMarkdown() -> String? {
        guard let url = bundledSkillURL?.appendingPathComponent("SKILL.md") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// The shared engine-knowledge block for the Settings Assistant's
    /// system prompt.
    nonisolated static func engineReference() -> String? {
        skillMarkdown().flatMap(extractEngineReference(from:))
    }

    nonisolated static func extractEngineReference(from markdown: String) -> String? {
        guard let begin = markdown.range(of: referenceBegin),
              let commentClose = markdown.range(of: "-->", range: begin.upperBound..<markdown.endIndex),
              let end = markdown.range(of: referenceEnd, range: commentClose.upperBound..<markdown.endIndex)
        else { return nil }
        return markdown[commentClose.upperBound..<end.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Versioning

    /// The bundled skill's `metadata.version`.
    nonisolated static var bundledVersion: String? {
        skillMarkdown().flatMap(parseVersion(from:))
    }

    /// Version of a skill installed at `directory` (a `clipslop/` dir), or
    /// nil when none is installed / it carries no version.
    nonisolated static func installedVersion(at directory: URL) -> String? {
        guard let text = try? String(
            contentsOf: directory.appendingPathComponent("SKILL.md"), encoding: .utf8
        ) else { return nil }
        return parseVersion(from: text)
    }

    /// Reads `version:` from the frontmatter's `metadata:` map. Frontmatter
    /// only — scanning stops at the closing fence so a `version:` in the
    /// body can never win.
    nonisolated static func parseVersion(from markdown: String) -> String? {
        var insideFrontmatter = false
        for line in markdown.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" {
                if insideFrontmatter { return nil }
                insideFrontmatter = true
                continue
            }
            guard insideFrontmatter, trimmed.hasPrefix("version:") else { continue }
            return trimmed.dropFirst("version:".count)
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return nil
    }

    // MARK: - Install / export

    /// Claude Code's user-scope skills directory (deliberately the real
    /// home, not sandbox-relative — dev builds install to the same place).
    nonisolated static var claudeCodeSkillsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
            .appendingPathComponent("skills")
    }

    struct InstallError: LocalizedError {
        let errorDescription: String?
    }

    /// Copies the bundled skill into `parent/clipslop/`, replacing any
    /// existing installation. Callers are responsible for confirming an
    /// overwrite first (`installedVersion(at:)` tells them what is there).
    /// The copy is staged inside `parent` and swapped in, so a failed copy
    /// never leaves a half-written skill at the destination.
    @discardableResult
    nonisolated static func install(intoParent parent: URL) throws -> URL {
        guard let source = bundledSkillURL else {
            throw InstallError(errorDescription: "Bundled skill resources are missing.")
        }
        let fm = FileManager.default
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)

        let destination = parent.appendingPathComponent(directoryName, isDirectory: true)
        let staging = parent.appendingPathComponent(".\(directoryName)-staging-\(UUID().uuidString)")
        try fm.copyItem(at: source, to: staging)
        do {
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: staging)
            } else {
                try fm.moveItem(at: staging, to: destination)
            }
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        return destination
    }
}
