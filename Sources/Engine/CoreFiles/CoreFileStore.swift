import Foundation

/// A machine-checkable rule extracted from `core/constraints.md`. The file is
/// prose the user owns; only bullets in the two recognized shapes become
/// verifier rules — everything else still ships to the model as pinned text.
struct ConstraintRule: Sendable, Equatable {
    enum Kind: Sendable { case phrase, regex }
    let kind: Kind
    let pattern: String
    /// 1-based line in constraints.md, cited in verifier warnings.
    let sourceLine: Int
}

/// The pinned core files (§9.1): the user-visible, user-editable "wiki" that
/// enters every generation prompt.
struct CoreFileSet: Sendable {
    let identity: String
    let writingStyle: String
    let constraintsText: String
    let aliases: String
    let constraints: [ConstraintRule]
    /// `~/.clipslop/system-prompt.md` — replaces the built-in system prompt
    /// when present and non-empty (edited from the Magic settings tab).
    let systemPromptOverride: String?

    static let empty = CoreFileSet(
        identity: "", writingStyle: "", constraintsText: "", aliases: "",
        constraints: [], systemPromptOverride: nil
    )
}

@MainActor
@Observable
final class CoreFileStore {
    private(set) var files: CoreFileSet = .empty

    @ObservationIgnored private var signature: [String: Date] = [:]
    @ObservationIgnored private var hasLoaded = false

    private nonisolated static let fileNames = ["identity.md", "writing-style.md", "constraints.md", "aliases.md"]

    init() {
        reloadIfChanged()
    }

    func reloadIfChanged() {
        let currentSignature = Self.currentSignature()
        guard currentSignature != signature || !hasLoaded else { return }
        signature = currentSignature
        hasLoaded = true

        func read(_ name: String) -> String {
            (try? String(
                contentsOf: Constants.Engine.coreDirectory.appendingPathComponent(name),
                encoding: .utf8
            )) ?? ""
        }

        let constraintsText = read("constraints.md")
        let overrideText = (try? String(contentsOf: Self.systemPromptURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        files = CoreFileSet(
            identity: read("identity.md"),
            writingStyle: read("writing-style.md"),
            constraintsText: constraintsText,
            aliases: read("aliases.md"),
            constraints: Self.parseConstraints(constraintsText),
            systemPromptOverride: (overrideText?.isEmpty == false) ? overrideText : nil
        )
    }

    nonisolated static let systemPromptURL =
        Constants.Engine.rootDirectory.appendingPathComponent("system-prompt.md")

    /// Recognized bullet shapes, anywhere in the file:
    ///   - never say: "some phrase"     → case/diacritic-insensitive substring rule
    ///   - never match: /some regex/    → NSRegularExpression rule
    /// Lines inside `<!-- -->` comments are skipped, so the seeded examples
    /// stay inert until the user uncomments them.
    nonisolated static func parseConstraints(_ text: String) -> [ConstraintRule] {
        var rules: [ConstraintRule] = []
        var inComment = false
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let lineNumber = index + 1

            if inComment {
                if trimmed.contains("-->") { inComment = false }
                continue
            }
            if trimmed.contains("<!--") && !trimmed.contains("-->") {
                inComment = true
                continue
            }

            if let phrase = extract(from: trimmed, prefix: "- never say:", delimiter: "\"") {
                rules.append(ConstraintRule(kind: .phrase, pattern: phrase, sourceLine: lineNumber))
            } else if let pattern = extract(from: trimmed, prefix: "- never match:", delimiter: "/") {
                // Only keep patterns that actually compile; a broken regex in a
                // hand-edited file must not take the verifier down.
                if (try? NSRegularExpression(pattern: pattern)) != nil {
                    rules.append(ConstraintRule(kind: .regex, pattern: pattern, sourceLine: lineNumber))
                }
            }
        }
        return rules
    }

    private nonisolated static func extract(from line: String, prefix: String, delimiter: Character) -> String? {
        guard line.lowercased().hasPrefix(prefix) else { return nil }
        let rest = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        guard rest.first == delimiter,
              let closing = rest.dropFirst().firstIndex(of: delimiter)
        else { return nil }
        let content = String(rest[rest.index(after: rest.startIndex)..<closing])
        return content.isEmpty ? nil : content
    }

    private nonisolated static func currentSignature() -> [String: Date] {
        var signature: [String: Date] = [:]
        for name in fileNames {
            let url = Constants.Engine.coreDirectory.appendingPathComponent(name)
            signature[name] = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
        }
        signature["system-prompt.md"] = (try? systemPromptURL.resourceValues(
            forKeys: [.contentModificationDateKey]
        ))?.contentModificationDate ?? .distantPast
        return signature
    }
}
