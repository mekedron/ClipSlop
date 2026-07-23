import Foundation

/// A workflow file as parsed from disk, before `extends` resolution.
struct RawWorkflow: Sendable {
    let card: WorkflowCard
    /// Which frontmatter keys the file set explicitly — inheritance gives a
    /// child its ancestor's value only for fields it did not set itself.
    let explicitKeys: Set<String>
    let body: String
    let fileURL: URL
}

/// A routable workflow after `extends` resolution: effective card + the
/// concatenated body (ancestor rules first, own body last).
struct ResolvedWorkflow: Sendable, Identifiable {
    let card: WorkflowCard
    let body: String
    /// Ids root-first, ending with this workflow — shown in dry-run/traces.
    let chain: [String]

    var id: String { card.id }
}

/// A workflow file the engine refused to load. Failure is never silent
/// (§15.3): the workflow is disabled, and the error is retained for display.
struct WorkflowLoadError: Error, Sendable, Identifiable {
    let id = UUID()
    let fileURL: URL?
    let workflowID: String?
    let line: Int?
    let message: String
    let isWarning: Bool

    init(fileURL: URL?, workflowID: String?, line: Int? = nil, message: String, isWarning: Bool = false) {
        self.fileURL = fileURL
        self.workflowID = workflowID
        self.line = line
        self.message = message
        self.isWarning = isWarning
    }
}

/// Pure `extends` resolution: chain walking, cycle detection, field
/// inheritance, body concatenation.
enum WorkflowResolver {
    private static let maxChainDepth = 8

    static func resolve(
        _ raws: [RawWorkflow]
    ) -> (resolved: [ResolvedWorkflow], errors: [WorkflowLoadError]) {
        var errors: [WorkflowLoadError] = []

        // Duplicate ids disable every claimant — deterministic, no silent shadowing.
        let byID = Dictionary(grouping: raws, by: { $0.card.id })
        var valid: [String: RawWorkflow] = [:]
        for (id, group) in byID {
            if group.count > 1 {
                for raw in group {
                    errors.append(WorkflowLoadError(
                        fileURL: raw.fileURL, workflowID: id,
                        message: "duplicate workflow id '\(id)' — also defined in \(group.filter { $0.fileURL != raw.fileURL }.map(\.fileURL.lastPathComponent).joined(separator: ", "))"
                    ))
                }
            } else {
                valid[id] = group[0]
            }
        }

        var resolved: [ResolvedWorkflow] = []
        for raw in raws where valid[raw.card.id] != nil && !raw.card.isAbstract {
            switch buildChain(for: raw, in: valid) {
            case .failure(let error):
                errors.append(error)
            case .success(let chain):
                let effective = mergeChain(chain)
                guard !effective.card.intents.isEmpty else {
                    errors.append(WorkflowLoadError(
                        fileURL: raw.fileURL, workflowID: raw.card.id,
                        message: "no 'intents' set here or on any ancestor"
                    ))
                    continue
                }
                resolved.append(effective)
            }
        }

        resolved.sort { $0.card.id < $1.card.id }
        return (resolved, errors)
    }

    // MARK: - Chain building

    /// Root-first chain ending with the workflow itself.
    private static func buildChain(
        for raw: RawWorkflow,
        in valid: [String: RawWorkflow]
    ) -> Result<[RawWorkflow], WorkflowLoadError> {
        var chain: [RawWorkflow] = [raw]
        var visited: Set<String> = [raw.card.id]
        var current = raw

        while let parentID = current.card.extends {
            guard let parent = valid[parentID] else {
                return .failure(WorkflowLoadError(
                    fileURL: raw.fileURL, workflowID: raw.card.id,
                    message: "extends '\(parentID)', which does not exist (or failed to load)"
                ))
            }
            guard visited.insert(parentID).inserted else {
                return .failure(WorkflowLoadError(
                    fileURL: raw.fileURL, workflowID: raw.card.id,
                    message: "'extends' cycle through '\(parentID)'"
                ))
            }
            guard chain.count < maxChainDepth else {
                return .failure(WorkflowLoadError(
                    fileURL: raw.fileURL, workflowID: raw.card.id,
                    message: "'extends' chain exceeds \(maxChainDepth) levels"
                ))
            }
            chain.append(parent)
            current = parent
        }
        return .success(chain.reversed())
    }

    // MARK: - Merge

    /// Child wins per explicitly-set field. `id`, `when`, `summary`,
    /// `abstract`, and `version` are never inherited — a predicate belongs to
    /// exactly one card. `budget`/`output` inherit at whole-field granularity
    /// (a child that sets `output:` at all replaces the ancestor's spec).
    private static func mergeChain(_ chain: [RawWorkflow]) -> ResolvedWorkflow {
        let leaf = chain.last!

        func lastExplicit<T>(_ key: String, _ value: (RawWorkflow) -> T) -> T? {
            chain.last(where: { $0.explicitKeys.contains(key) }).map(value)
        }

        let card = WorkflowCard(
            id: leaf.card.id,
            version: leaf.card.version,
            extends: leaf.card.extends,
            isAbstract: false,
            priority: lastExplicit("priority", { $0.card.priority }) ?? 50,
            surface: lastExplicit("surface", { $0.card.surface }) ?? .private,
            summary: leaf.card.summary,
            intents: lastExplicit("intents", { $0.card.intents }) ?? [],
            when: leaf.card.when,
            budget: lastExplicit("budget", { $0.card.budget }) ?? .default,
            output: lastExplicit("output", { $0.card.output }) ?? .default
        )

        let body = chain
            .map { $0.body.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")

        return ResolvedWorkflow(card: card, body: body, chain: chain.map(\.card.id))
    }
}
