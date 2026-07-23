import Foundation

/// Router tier of a `when` predicate (§6.1): matching is counted at the
/// highest tier that produced a candidate, so a URL-specific workflow
/// suppresses the generic layer from the ambiguity count.
enum MatchTier: Int, Sendable, Comparable, CustomStringConvertible {
    case base = 0
    case domain = 1
    case exact = 2

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var description: String {
        switch self {
        case .base: "base"
        case .domain: "domain"
        case .exact: "exact"
        }
    }
}

struct WhenPredicate: Sendable, Equatable {
    let apps: [String]?
    /// NSRegularExpression pattern, validated compilable at load time.
    let urlPattern: String?
    let fieldRoles: [String]?
    let fieldStates: [FieldState]?
    let selectionClasses: [SelectionClass]?

    var tier: MatchTier {
        if urlPattern != nil { return .exact }
        if apps != nil { return .domain }
        return .base
    }
}

struct BudgetSpec: Sendable, Equatable {
    let promptTokensTotal: Int
    let ms: Int

    static let `default` = BudgetSpec(promptTokensTotal: 3500, ms: 6000)
}

struct OutputSpec: Sendable, Equatable {
    enum Lang: Sendable, Equatable {
        case matchContext
        case fixed(String)
    }

    let lang: Lang
    let maxChars: Int
    let format: String

    static let `default` = OutputSpec(lang: .matchContext, maxChars: 1200, format: "plain")
}

/// The YAML frontmatter of a workflow file, typed and validated. The card is
/// what the router matches on; the markdown body loads into the prompt only
/// when the workflow is chosen.
struct WorkflowCard: Sendable, Equatable {
    let id: String
    let version: Int
    let extends: String?
    /// Abstract cards exist only as `extends` targets (base.generation) and
    /// are never routed.
    let isAbstract: Bool
    let priority: Int
    /// Parsed and carried into traces; the surface *gate* (§13.2) is not
    /// enforced in V0 — there are no private-derived loadable items yet.
    let surface: Surface
    let summary: String?
    let intents: [String]
    let when: WhenPredicate?
    let budget: BudgetSpec
    let output: OutputSpec

    enum Surface: String, Sendable {
        case `public`, team, `private`
    }

    var tier: MatchTier { when?.tier ?? .base }
}

/// Builds a `WorkflowCard` from parsed frontmatter, enforcing the V0 schema.
/// Unknown keys are errors (typo protection for hand-edited files) except
/// forward-compatible ones the doc defines for later milestones (`needs`),
/// which produce warnings and are ignored.
enum WorkflowCardParser {
    static let knownKeys: Set<String> = [
        "id", "kind", "mode", "version", "extends", "abstract", "priority",
        "surface", "when", "summary", "intents", "budget", "output",
    ]
    static let ignoredForwardKeys: Set<String> = ["needs", "authorship", "execution", "permissions"]
    static let knownWhenKeys: Set<String> = ["app", "url", "field.role", "field.state", "selection"]

    static func make(
        from document: FrontmatterDocument
    ) throws -> (card: WorkflowCard, explicitKeys: Set<String>, warnings: [String]) {
        var warnings: [String] = []

        for key in document.fields.keys where !knownKeys.contains(key) {
            let line = document.fieldLines[key] ?? 0
            if ignoredForwardKeys.contains(key) {
                warnings.append("'\(key)' (line \(line)) is not supported yet and was ignored")
            } else {
                throw FrontmatterError(line: line, message: "unknown key '\(key)'\(didYouMean(key))")
            }
        }

        let id = try requireScalar("id", in: document)
        let idPattern = /^[a-z][a-z0-9.-]*$/
        guard id.wholeMatch(of: idPattern) != nil else {
            throw error("id", document, "'\(id)' — must be lowercase letters, digits, dots, dashes")
        }

        let kind = try requireScalar("kind", in: document)
        guard kind == "workflow" else {
            throw error("kind", document, "'\(kind)' — V0 supports only 'workflow'")
        }
        let mode = try requireScalar("mode", in: document)
        guard mode == "direct" else {
            throw error("mode", document, "'\(mode)' — V0 supports only 'direct'")
        }

        guard let version = Int(try requireScalar("version", in: document)) else {
            throw error("version", document, "must be an integer")
        }

        let isAbstract = try boolValue("abstract", in: document) ?? false
        let priority = try intValue("priority", in: document) ?? 50
        guard (0...100).contains(priority) else {
            throw error("priority", document, "must be between 0 and 100")
        }

        let surfaceRaw = try scalarValue("surface", in: document) ?? "private"
        guard let surface = WorkflowCard.Surface(rawValue: surfaceRaw) else {
            throw error("surface", document, "'\(surfaceRaw)' — expected public, team, or private")
        }

        let summary = try scalarValue("summary", in: document)
        let intents = try listValue("intents", in: document) ?? []
        if !isAbstract {
            // `summary` is never inherited — every routable card labels its own
            // chip. `intents` may come from an ancestor; the resolver checks
            // the effective value.
            guard summary?.isEmpty == false else {
                throw FrontmatterError(line: 1, message: "'summary' is required (it becomes the chip label)")
            }
        }

        let when = try parseWhen(document)
        let budget = try parseBudget(document)
        let output = try parseOutput(document)

        let card = WorkflowCard(
            id: id,
            version: version,
            extends: try scalarValue("extends", in: document),
            isAbstract: isAbstract,
            priority: priority,
            surface: surface,
            summary: summary,
            intents: intents,
            when: when,
            budget: budget,
            output: output
        )
        return (card, Set(document.fields.keys), warnings)
    }

    // MARK: - Sections

    private static func parseWhen(_ document: FrontmatterDocument) throws -> WhenPredicate? {
        guard let value = document.fields["when"] else { return nil }
        guard case .map(let map) = value else {
            throw error("when", document, "must be a nested block of conditions")
        }
        for key in map.keys where !knownWhenKeys.contains(key) {
            let line = document.fieldLines["when.\(key)"] ?? document.fieldLines["when"] ?? 0
            throw FrontmatterError(line: line, message: "unknown 'when' condition '\(key)'\(didYouMean(key, among: knownWhenKeys))")
        }

        let urlPattern = try scalarValue(map["url"], key: "when.url", document)
        if let urlPattern {
            do {
                _ = try NSRegularExpression(pattern: urlPattern)
            } catch {
                let line = document.fieldLines["when.url"] ?? 0
                throw FrontmatterError(line: line, message: "'when.url' is not a valid regular expression: \(error.localizedDescription)")
            }
        }

        var fieldStates: [FieldState]?
        if let raw = try listValue(map["field.state"], key: "when.field.state", document) {
            fieldStates = try raw.map {
                guard let state = FieldState(rawValue: $0) else {
                    let line = document.fieldLines["when.field.state"] ?? 0
                    throw FrontmatterError(line: line, message: "unknown field.state '\($0)' — expected empty, draft, or selection")
                }
                return state
            }
        }

        var selectionClasses: [SelectionClass]?
        if let raw = try listValue(map["selection"], key: "when.selection", document) {
            selectionClasses = try raw.map {
                guard let cls = SelectionClass(rawValue: $0) else {
                    let line = document.fieldLines["when.selection"] ?? 0
                    throw FrontmatterError(line: line, message: "unknown selection class '\($0)' — expected instruction, material, or mixed")
                }
                return cls
            }
        }

        return WhenPredicate(
            apps: try listValue(map["app"], key: "when.app", document),
            urlPattern: urlPattern,
            fieldRoles: try listValue(map["field.role"], key: "when.field.role", document),
            fieldStates: fieldStates,
            selectionClasses: selectionClasses
        )
    }

    private static func parseBudget(_ document: FrontmatterDocument) throws -> BudgetSpec {
        guard let value = document.fields["budget"] else { return .default }
        guard case .map(let map) = value else {
            throw error("budget", document, "must be a flow map like {prompt_tokens_total: 3500, ms: 6000}")
        }
        return BudgetSpec(
            promptTokensTotal: try intValue(map["prompt_tokens_total"], key: "budget.prompt_tokens_total", document)
                ?? BudgetSpec.default.promptTokensTotal,
            ms: try intValue(map["ms"], key: "budget.ms", document) ?? BudgetSpec.default.ms
        )
    }

    private static func parseOutput(_ document: FrontmatterDocument) throws -> OutputSpec {
        guard let value = document.fields["output"] else { return .default }
        guard case .map(let map) = value else {
            throw error("output", document, "must be a flow map like {lang: match_context, max_chars: 400, format: plain}")
        }
        let langRaw = try scalarValue(map["lang"], key: "output.lang", document) ?? "match_context"
        let lang: OutputSpec.Lang = langRaw == "match_context" ? .matchContext : .fixed(langRaw)
        let format = try scalarValue(map["format"], key: "output.format", document) ?? "plain"
        guard format == "plain" else {
            throw error("output", document, "format '\(format)' — V0 supports only 'plain'")
        }
        return OutputSpec(
            lang: lang,
            maxChars: try intValue(map["max_chars"], key: "output.max_chars", document) ?? OutputSpec.default.maxChars,
            format: format
        )
    }

    // MARK: - Field access helpers

    private static func requireScalar(_ key: String, in document: FrontmatterDocument) throws -> String {
        guard let value = try scalarValue(key, in: document), !value.isEmpty else {
            throw FrontmatterError(line: document.fieldLines[key] ?? 1, message: "'\(key)' is required")
        }
        return value
    }

    private static func scalarValue(_ key: String, in document: FrontmatterDocument) throws -> String? {
        try scalarValue(document.fields[key], key: key, document)
    }

    private static func scalarValue(
        _ value: FrontmatterValue?, key: String, _ document: FrontmatterDocument
    ) throws -> String? {
        guard let value else { return nil }
        guard case .scalar(let scalar) = value else {
            throw error(key, document, "must be a single value")
        }
        return scalar
    }

    /// Lists accept both `[a, b]` and a bare scalar (a one-item list).
    private static func listValue(_ key: String, in document: FrontmatterDocument) throws -> [String]? {
        try listValue(document.fields[key], key: key, document)
    }

    private static func listValue(
        _ value: FrontmatterValue?, key: String, _ document: FrontmatterDocument
    ) throws -> [String]? {
        switch value {
        case nil: return nil
        case .scalar(let scalar): return [scalar]
        case .list(let items): return items
        case .map, .mapList: throw error(key, document, "must be a list")
        }
    }

    private static func intValue(_ key: String, in document: FrontmatterDocument) throws -> Int? {
        try intValue(document.fields[key], key: key, document)
    }

    private static func intValue(
        _ value: FrontmatterValue?, key: String, _ document: FrontmatterDocument
    ) throws -> Int? {
        guard let scalar = try scalarValue(value, key: key, document) else { return nil }
        guard let int = Int(scalar) else { throw error(key, document, "must be an integer") }
        return int
    }

    private static func boolValue(_ key: String, in document: FrontmatterDocument) throws -> Bool? {
        guard let scalar = try scalarValue(key, in: document) else { return nil }
        switch scalar {
        case "true": return true
        case "false": return false
        default: throw error(key, document, "must be true or false")
        }
    }

    private static func error(_ key: String, _ document: FrontmatterDocument, _ message: String) -> FrontmatterError {
        FrontmatterError(line: document.fieldLines[key] ?? 0, message: "'\(key)' \(message)")
    }

    private static func didYouMean(_ key: String, among candidates: Set<String> = knownKeys) -> String {
        // Cheap suggestion: a known key that is a superset/subset or shares a prefix.
        let lowered = key.lowercased()
        let suggestion = candidates.first {
            $0.hasPrefix(lowered) || lowered.hasPrefix($0) || $0.contains(lowered) || lowered.contains($0)
        }
        return suggestion.map { " — did you mean '\($0)'?" } ?? ""
    }
}
