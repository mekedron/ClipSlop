import Foundation
import Testing
@testable import ClipSlop

@Suite("Workflow card parsing")
struct WorkflowCardParsingTests {
    private func card(_ text: String) throws -> (card: WorkflowCard, explicitKeys: Set<String>, warnings: [String]) {
        try WorkflowCardParser.make(from: FrontmatterParser.parse(text))
    }

    @Test func parsesFullCard() throws {
        let (parsed, _, warnings) = try card("""
        ---
        id: comment.social
        kind: workflow
        mode: direct
        version: 3
        extends: base.generation
        priority: 70
        surface: public
        summary: "LinkedIn comment"
        intents: [comment, reply]
        when:
          app: [com.google.Chrome]
          url: "linkedin\\\\.com/feed"
          field.state: [empty, draft]
          selection: [instruction, mixed]
        budget: {prompt_tokens_total: 3000, ms: 1500}
        output: {lang: match_context, max_chars: 400, format: plain}
        ---
        Body.
        """)
        #expect(parsed.id == "comment.social")
        #expect(parsed.version == 3)
        #expect(parsed.extends == "base.generation")
        #expect(parsed.priority == 70)
        #expect(parsed.surface == .public)
        #expect(parsed.intents == ["comment", "reply"])
        #expect(parsed.when?.apps == ["com.google.Chrome"])
        #expect(parsed.when?.urlPattern == "linkedin\\.com/feed")
        #expect(parsed.when?.fieldStates == [.empty, .draft])
        #expect(parsed.when?.selectionClasses == [.instruction, .mixed])
        #expect(parsed.budget == BudgetSpec(promptTokensTotal: 3000, ms: 1500))
        #expect(parsed.output.maxChars == 400)
        #expect(parsed.tier == .exact)
        #expect(warnings.isEmpty)
    }

    @Test func defaultsApply() throws {
        let (parsed, _, _) = try card("""
        ---
        id: minimal
        kind: workflow
        mode: direct
        version: 1
        summary: "Minimal"
        intents: [write]
        ---
        """)
        #expect(parsed.priority == 50)
        #expect(parsed.surface == .private)
        #expect(parsed.budget == .default)
        #expect(parsed.output == .default)
        #expect(parsed.tier == .base)
    }

    @Test func unknownKeyFailsWithSuggestion() {
        do {
            _ = try card("""
            ---
            id: x
            kind: workflow
            mode: direct
            version: 1
            summary: "X"
            intent: [write]
            ---
            """)
            Issue.record("expected an error")
        } catch let error as FrontmatterError {
            #expect(error.message.contains("intent"))
            #expect(error.message.contains("intents"))
        } catch {
            Issue.record("unexpected error type")
        }
    }

    @Test func needsIsIgnoredWithWarning() throws {
        let (_, _, warnings) = try card("""
        ---
        id: x
        kind: workflow
        mode: direct
        version: 1
        summary: "X"
        intents: [write]
        needs:
          - ax.surrounding
        ---
        """)
        #expect(warnings.count == 1)
        #expect(warnings[0].contains("needs"))
    }

    @Test func invalidURLRegexFails() {
        #expect(throws: FrontmatterError.self) {
            _ = try card("""
            ---
            id: x
            kind: workflow
            mode: direct
            version: 1
            summary: "X"
            intents: [write]
            when:
              url: "([unclosed"
            ---
            """)
        }
    }

    @Test func abstractCardNeedsNoSummary() throws {
        let (parsed, _, _) = try card("""
        ---
        id: base.generation
        kind: workflow
        mode: direct
        version: 1
        abstract: true
        ---
        Rules.
        """)
        #expect(parsed.isAbstract)
    }

    @Test func nonAbstractCardRequiresSummary() {
        #expect(throws: FrontmatterError.self) {
            _ = try card("""
            ---
            id: x
            kind: workflow
            mode: direct
            version: 1
            intents: [write]
            ---
            """)
        }
    }
}

@Suite("Workflow resolution")
struct WorkflowResolutionTests {
    private func raw(
        id: String, extends: String? = nil, abstract: Bool = false,
        priority: Int? = nil, surface: WorkflowCard.Surface? = nil,
        intents: [String]? = nil, body: String = ""
    ) -> RawWorkflow {
        var explicit: Set<String> = ["id", "kind", "mode", "version"]
        if extends != nil { explicit.insert("extends") }
        if abstract { explicit.insert("abstract") }
        if priority != nil { explicit.insert("priority") }
        if surface != nil { explicit.insert("surface") }
        if intents != nil { explicit.insert("intents") }
        if !abstract { explicit.insert("summary") }
        return RawWorkflow(
            card: WorkflowCard(
                id: id, version: 1, extends: extends, isAbstract: abstract,
                priority: priority ?? 50, surface: surface ?? .private,
                summary: abstract ? nil : "Summary of \(id)",
                intents: intents ?? [], when: nil, budget: .default, output: .default
            ),
            explicitKeys: explicit,
            body: body,
            fileURL: URL(fileURLWithPath: "/w/\(id).md")
        )
    }

    @Test func inheritsUnsetFieldsFromAncestors() throws {
        let (resolved, errors) = WorkflowResolver.resolve([
            raw(id: "base", abstract: true, priority: 40, surface: .public, intents: ["reply"], body: "Base rules."),
            raw(id: "child", extends: "base", body: "Child rules."),
        ])
        #expect(errors.isEmpty)
        let child = try #require(resolved.first { $0.id == "child" })
        #expect(child.card.priority == 40)
        #expect(child.card.surface == .public)
        #expect(child.card.intents == ["reply"])
        #expect(child.body == "Base rules.\n\nChild rules.")
        #expect(child.chain == ["base", "child"])
    }

    @Test func childExplicitFieldsWin() throws {
        let (resolved, _) = WorkflowResolver.resolve([
            raw(id: "base", abstract: true, priority: 40, intents: ["reply"]),
            raw(id: "child", extends: "base", priority: 70, intents: ["comment"]),
        ])
        let child = try #require(resolved.first { $0.id == "child" })
        #expect(child.card.priority == 70)
        #expect(child.card.intents == ["comment"])
    }

    @Test func abstractWorkflowsAreNotRouted() {
        let (resolved, errors) = WorkflowResolver.resolve([
            raw(id: "base", abstract: true, intents: ["x"]),
        ])
        #expect(resolved.isEmpty)
        #expect(errors.isEmpty)
    }

    @Test func cycleIsDetected() {
        let (resolved, errors) = WorkflowResolver.resolve([
            raw(id: "a", extends: "b", intents: ["x"]),
            raw(id: "b", extends: "a", intents: ["x"]),
        ])
        #expect(resolved.isEmpty)
        #expect(errors.count == 2)
        #expect(errors.allSatisfy { $0.message.contains("cycle") })
    }

    @Test func missingParentDisablesWorkflow() {
        let (resolved, errors) = WorkflowResolver.resolve([
            raw(id: "child", extends: "ghost", intents: ["x"]),
        ])
        #expect(resolved.isEmpty)
        #expect(errors.count == 1)
        #expect(errors[0].message.contains("ghost"))
    }

    @Test func duplicateIDsDisableBothClaimants() {
        var second = raw(id: "dup", intents: ["x"])
        second = RawWorkflow(
            card: second.card, explicitKeys: second.explicitKeys,
            body: second.body, fileURL: URL(fileURLWithPath: "/w/other.md")
        )
        let (resolved, errors) = WorkflowResolver.resolve([raw(id: "dup", intents: ["x"]), second])
        #expect(resolved.isEmpty)
        #expect(errors.count == 2)
        #expect(errors.allSatisfy { $0.message.contains("duplicate") })
    }

    @Test func missingIntentsEverywhereIsAnError() {
        let (resolved, errors) = WorkflowResolver.resolve([
            raw(id: "orphan"),
        ])
        #expect(resolved.isEmpty)
        #expect(errors.count == 1)
        #expect(errors[0].message.contains("intents"))
    }
}

@Suite("Seed content")
struct SeedContentTests {
    /// Guards against ever shipping a seed the engine itself refuses to load.
    @Test func allSeedWorkflowsParseAndResolve() throws {
        let (workflows, errors) = try MagicTestSupport.seedCatalog()
        #expect(errors.filter { !$0.isWarning }.isEmpty, "seed errors: \(errors.map(\.message))")
        // 12 files minus 1 abstract base.generation.
        #expect(workflows.count == 11)
        #expect(workflows.allSatisfy { !$0.card.intents.isEmpty })
        #expect(workflows.allSatisfy { $0.card.summary?.isEmpty == false })
        // Every non-base seed chains back to base.generation's conduct rules.
        for workflow in workflows {
            #expect(workflow.chain.first == "base.generation", "\(workflow.id) chain: \(workflow.chain)")
        }
    }

    @Test func seededURLPatternsEscapeCorrectly() throws {
        let (workflows, _) = try MagicTestSupport.seedCatalog()
        let social = try #require(workflows.first { $0.id == "comment.social" })
        // The file holds "linkedin\\.com" which must parse to the regex linkedin\.com
        #expect(social.card.when?.urlPattern?.contains("linkedin\\.com") == true)
        #expect(social.card.when?.urlPattern?.contains("\\\\") == false)
    }

    @Test func coreSeedsProduceNoActiveConstraintRules() {
        // The seeded constraints.md examples are inside HTML comments and
        // must stay inert until the user uncomments them.
        let seeded = EngineSeedContent.constraints
        #expect(CoreFileStore.parseConstraints(seeded).isEmpty)
    }

    @Test func constraintRuleParsingRecognizesBothShapes() {
        let rules = CoreFileStore.parseConstraints("""
        # Constraints
        - never say: "best regards"
        - never match: /\\bAI\\b/
        - Prose rule the checker ignores.
        """)
        #expect(rules.count == 2)
        #expect(rules[0].kind == .phrase)
        #expect(rules[0].pattern == "best regards")
        #expect(rules[0].sourceLine == 2)
        #expect(rules[1].kind == .regex)
        #expect(rules[1].pattern == "\\bAI\\b")
    }
}
