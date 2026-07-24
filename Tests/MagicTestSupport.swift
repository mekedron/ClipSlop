import Foundation
@testable import ClipSlop

/// Shared factories for engine tests. Everything is pure — no disk, no
/// main-actor stores.
enum MagicTestSupport {
    static func makeSnapshot(
        bundleId: String? = "com.example.app",
        appName: String? = "Example",
        windowTitle: String? = nil,
        url: String? = nil,
        role: String = "AXTextArea",
        editable: Bool = true,
        secure: Bool = false,
        value: String = "",
        selection: MagicSnapshot.SelectionInfo? = nil,
        placeholder: String? = nil,
        surroundingContent: String? = nil,
        surroundingAuthor: String? = nil,
        hasField: Bool = true
    ) -> MagicSnapshot {
        MagicSnapshot(
            app: .init(name: appName, bundleId: bundleId, pid: 1),
            windowTitle: windowTitle,
            url: url,
            field: hasField ? .init(
                role: role,
                subrole: nil,
                editable: editable,
                secure: secure,
                value: value,
                selection: selection,
                placeholder: placeholder
            ) : nil,
            surrounding: surroundingContent.map { .axTree(content: $0, author: surroundingAuthor) },
            locale: "en",
            ts: Date(timeIntervalSince1970: 1_750_000_000),
            focusedElement: nil
        )
    }

    /// A resolved workflow built directly, bypassing files.
    static func makeWorkflow(
        id: String,
        priority: Int = 50,
        surface: WorkflowCard.Surface = .private,
        summary: String? = "Test workflow",
        intents: [String] = ["test"],
        when: WhenPredicate? = nil,
        budget: BudgetSpec = .default,
        output: OutputSpec = .default,
        body: String = "## Rules\n- Be brief.",
        chain: [String]? = nil
    ) -> ResolvedWorkflow {
        ResolvedWorkflow(
            card: WorkflowCard(
                id: id, version: 1, extends: nil, isAbstract: false,
                priority: priority, surface: surface, summary: summary,
                intents: intents, when: when, budget: budget, output: output
            ),
            body: body,
            chain: chain ?? [id]
        )
    }

    /// The seeded workflow set, parsed and resolved exactly as the store
    /// would — pure, no file system.
    static func seedCatalog() throws -> (workflows: [ResolvedWorkflow], errors: [WorkflowLoadError]) {
        var raws: [RawWorkflow] = []
        var errors: [WorkflowLoadError] = []
        for (path, content) in EngineSeedContent.seeds where path.hasPrefix("workflows/") {
            let document = try FrontmatterParser.parse(content)
            let (card, explicitKeys, warnings) = try WorkflowCardParser.make(from: document)
            for warning in warnings {
                errors.append(WorkflowLoadError(fileURL: nil, workflowID: card.id, message: warning, isWarning: true))
            }
            raws.append(RawWorkflow(
                card: card, explicitKeys: explicitKeys, body: document.body,
                fileURL: URL(fileURLWithPath: "/seeds/\(path)")
            ))
        }
        let (resolved, resolveErrors) = WorkflowResolver.resolve(raws)
        errors.append(contentsOf: resolveErrors)
        return (resolved, errors)
    }

    static func seedRoute(
        _ snapshot: MagicSnapshot,
        classification: SelectionClassification? = nil
    ) throws -> RoutingDecision {
        let (workflows, _) = try seedCatalog()
        return EngineRouter.route(
            catalog: WorkflowCatalog(workflows: workflows, loadedAt: Date(timeIntervalSince1970: 0)),
            snapshot: snapshot,
            classification: classification
        )
    }
}
