import Testing
@testable import ClipSlop

@Suite("Prompt assembler")
struct PromptAssemblerTests {
    private let core = CoreFileSet(
        identity: "Name: Nikita\nRole: Engineer",
        writingStyle: "## General\n- Be direct.",
        constraintsText: "- Never invent facts.",
        aliases: "- Vika = Viktoria Lahtinen",
        constraints: [],
        systemPromptOverride: nil
    )

    private func assemble(
        workflow: ResolvedWorkflow = MagicTestSupport.makeWorkflow(id: "test"),
        snapshot: MagicSnapshot = MagicTestSupport.makeSnapshot(),
        core: CoreFileSet? = nil,
        classification: SelectionClassification? = nil,
        hint: String? = nil,
        outputMaxChars: Int = 1200,
        surroundingMaxTokens: Int = MagicEngineConfig.default.surroundingMaxTokens
    ) -> AssembledPrompt {
        PromptAssembler.assemble(
            workflow: workflow, snapshot: snapshot,
            core: core ?? self.core, classification: classification, hint: hint,
            outputMaxChars: outputMaxChars,
            surroundingMaxTokens: surroundingMaxTokens
        )
    }

    @Test func allFiveSlotsArePresentAndOrdered() {
        let prompt = assemble(snapshot: MagicTestSupport.makeSnapshot(surroundingContent: "A post."))
        #expect(prompt.slots.map(\.id) == [.pinned, .workflowBody, .fewShot, .surrounding, .fieldInput])
    }

    @Test func fewShotSlotIsEmptyInV0() {
        let prompt = assemble()
        let fewShot = prompt.slots.first { $0.id == .fewShot }
        #expect(fewShot?.text == "")
        #expect(fewShot?.tokensEstimated == 0)
    }

    @Test func surroundingIsFencedAsUntrusted() {
        let prompt = assemble(snapshot: MagicTestSupport.makeSnapshot(
            surroundingContent: "Some post content.",
            surroundingAuthor: "Ville Korhonen"
        ))
        let slot = prompt.slots.first { $0.id == .surrounding }!
        #expect(slot.untrusted)
        #expect(slot.text.hasPrefix(PromptAssembler.untrustedFenceOpen))
        #expect(slot.text.hasSuffix(PromptAssembler.untrustedFenceClose))
        #expect(slot.text.contains("Author: Ville Korhonen"))
        #expect(prompt.userMessage.contains(PromptAssembler.untrustedFenceOpen))
    }

    @Test func slotBudgetsAreHonored() {
        let huge = String(repeating: "lorem ipsum dolor sit amet ", count: 2000)
        let prompt = assemble(
            workflow: MagicTestSupport.makeWorkflow(id: "big", body: huge),
            snapshot: MagicTestSupport.makeSnapshot(value: huge, surroundingContent: huge),
            core: CoreFileSet(
                identity: huge, writingStyle: huge, constraintsText: "- Never invent facts.",
                aliases: huge, constraints: [], systemPromptOverride: nil
            ),
            surroundingMaxTokens: 800
        )
        for slot in prompt.slots {
            // Small tolerance for section headers added after trimming. The
            // surrounding slot's budget is the threaded config value.
            let budget = slot.id == .surrounding ? 800 : slot.id.budgetTokens
            #expect(slot.tokensEstimated <= budget + 30, "\(slot.id) over budget: \(slot.tokensEstimated)")
        }
    }

    @Test func pinnedTrimsAliasesFirstAndNeverConstraints() {
        let huge = String(repeating: "style rule. ", count: 800)
        let prompt = assemble(core: CoreFileSet(
            identity: "Short identity.",
            writingStyle: huge,
            constraintsText: "- NEVER-TRIM-MARKER stays.",
            aliases: "- ALIAS-MARKER = Somebody",
            constraints: [],
            systemPromptOverride: nil
        ))
        let pinned = prompt.slots.first { $0.id == .pinned }!
        #expect(pinned.truncated)
        #expect(!pinned.text.contains("ALIAS-MARKER"))
        #expect(pinned.text.contains("NEVER-TRIM-MARKER"))
    }

    @Test func workflowBodyTrimsAntiExamplesBeforeRules() {
        let body = """
        ## Rules
        \(String(repeating: "- RULE-MARKER keep this rule line.\n", count: 80))
        ## Examples
        \(String(repeating: "- example line\n", count: 20))
        ## Anti-examples
        - ANTI-MARKER never this.
        """
        let prompt = assemble(workflow: MagicTestSupport.makeWorkflow(id: "big", body: body))
        let slot = prompt.slots.first { $0.id == .workflowBody }!
        #expect(slot.truncated)
        #expect(!slot.text.contains("ANTI-MARKER"))
        #expect(slot.text.contains("RULE-MARKER"))
    }

    @Test func lengthCeilingReachesTheModelAndSurvivesTrimming() {
        let hugeBody = "## Rules\n" + String(repeating: "- filler rule line to overflow the slot budget.\n", count: 120)
        let prompt = assemble(
            workflow: MagicTestSupport.makeWorkflow(id: "big", body: hugeBody),
            outputMaxChars: 3000
        )
        let slot = prompt.slots.first { $0.id == .workflowBody }!
        #expect(slot.truncated)
        #expect(slot.text.contains("never exceed 3000 characters"))
    }

    @Test func selectionAndHintAreNeverTruncated() {
        let hugeEdge = String(repeating: "draft text before ", count: 500)
        let selection = "SELECTED-REQUEST: вставь сюда таблицу тарифов Pro и Enterprise"
        let prompt = assemble(
            snapshot: MagicTestSupport.makeSnapshot(
                value: hugeEdge + selection + hugeEdge,
                selection: .init(range: hugeEdge.count..<(hugeEdge.count + selection.count), text: selection)
            ),
            classification: SelectionClassifier.classify(selection),
            hint: "HINT-MARKER keep the tone light"
        )
        let slot = prompt.slots.first { $0.id == .fieldInput }!
        #expect(slot.truncated)
        #expect(slot.text.contains(selection))
        #expect(slot.text.contains("HINT-MARKER"))
        #expect(slot.text.contains("[reads as:"))
    }

    @Test func draftOverflowKeepsTheEnd() {
        let draft = String(repeating: "early text ", count: 400) + "FINAL-WORDS-AT-CARET"
        let prompt = assemble(snapshot: MagicTestSupport.makeSnapshot(value: draft))
        let slot = prompt.slots.first { $0.id == .fieldInput }!
        #expect(slot.truncated)
        // The caret end survives; the far start is what got cut.
        #expect(slot.text.contains("FINAL-WORDS-AT-CARET"))
        #expect(slot.text.contains(PromptAssembler.truncationMarker))
        #expect(!slot.text.contains(draft))
        #expect(slot.text.count < draft.count / 2)
    }

    @Test func emptyFieldMentionsPlaceholder() {
        let prompt = assemble(snapshot: MagicTestSupport.makeSnapshot(placeholder: "Add a comment…"))
        let slot = prompt.slots.first { $0.id == .fieldInput }!
        #expect(slot.text.contains("EMPTY"))
        #expect(slot.text.contains("Add a comment…"))
    }

    @Test func workflowCapSqueezesInstructionsButNeverSurrounding() {
        // A card's `budget.prompt_tokens_total` bounds the instruction
        // slots; the surroundings are governed solely by the user's global
        // `surrounding_max_tokens` — a card can never silently shrink the
        // screen context.
        let surrounding = String(repeating: "thread message content ", count: 200)
        let hugeBody = String(repeating: "workflow rule text ", count: 500)
        let prompt = assemble(
            workflow: MagicTestSupport.makeWorkflow(
                id: "capped",
                budget: BudgetSpec(promptTokensTotal: 700, ms: 6000),
                body: hugeBody
            ),
            snapshot: MagicTestSupport.makeSnapshot(value: "My draft.", surroundingContent: surrounding)
        )
        let surroundingSlot = prompt.slots.first { $0.id == .surrounding }!
        #expect(!surroundingSlot.truncated)
        let instructionTokens = prompt.slots
            .filter { $0.id != .surrounding }
            .reduce(0) { $0 + $1.tokensEstimated }
        #expect(instructionTokens <= 700 + 30)
        // The user's own field content survives the cross-slot trim.
        let fieldSlot = prompt.slots.first { $0.id == .fieldInput }!
        #expect(fieldSlot.text.contains("My draft."))
    }

    @Test func surroundingOverflowKeepsTheTail() {
        // The AX walk reads top-to-bottom: sidebar noise first, the thread's
        // newest message (the one being answered) last. Overflow must drop
        // the head, never the pending message at the tail.
        let sidebar = String(repeating: "sidebar preview noise ", count: 300)
        let pending = "PENDING-QUESTION do you know when"
        let prompt = assemble(
            snapshot: MagicTestSupport.makeSnapshot(surroundingContent: sidebar + pending),
            surroundingMaxTokens: 800
        )
        let slot = prompt.slots.first { $0.id == .surrounding }!
        #expect(slot.truncated)
        #expect(slot.text.contains(pending))
    }

    @Test func zeroContextLimitPassesEverythingUntrimmed() {
        // `surrounding_max_tokens: 0` — the whole captured screen goes in,
        // head to tail, and even a card's own budget cannot cut it.
        let head = "HEAD-MARKER the very first thing on screen"
        let tail = "TAIL-MARKER the pending message by the field"
        let filler = String(repeating: "long conversation line ", count: 3000)
        let prompt = assemble(
            workflow: MagicTestSupport.makeWorkflow(
                id: "capped",
                budget: BudgetSpec(promptTokensTotal: 1000, ms: 6000)
            ),
            snapshot: MagicTestSupport.makeSnapshot(surroundingContent: head + filler + tail),
            surroundingMaxTokens: 0
        )
        let slot = prompt.slots.first { $0.id == .surrounding }!
        #expect(!slot.truncated)
        #expect(slot.text.contains(head))
        #expect(slot.text.contains(tail))
    }

    /// A large structured capture for the tree-mode slot tests: a feed of
    /// posts with the field inside the middle post's comment list.
    private func bigTree(postCount: Int = 12) -> SurroundingNode {
        let fieldPost = postCount / 2
        let posts = (1...postCount).map { index -> SurroundingNode in
            var comments: [SurroundingNode] = [
                SurroundingNode(role: "AXStaticText", text: "COMMENT-\(index) some earlier remark on this post"),
            ]
            if index == fieldPost {
                comments.append(SurroundingNode(role: "AXTextArea", isField: true))
            }
            return SurroundingNode(role: "AXGroup", label: "post \(index)", children: [
                SurroundingNode(role: "AXStaticText", text: "POST-\(index) " + String(repeating: "body text ", count: 40)),
                SurroundingNode(role: "AXList", label: "comments", children: comments),
            ])
        }
        return SurroundingNode(role: "AXWebArea", label: "feed", children: posts)
    }

    @Test func treeModeSlotObeysBudgetAndKeepsFencesAndMarker() {
        let prompt = assemble(
            snapshot: MagicTestSupport.makeSnapshot(
                placeholder: "Add a comment…", surroundingTree: bigTree()
            ),
            surroundingMaxTokens: 300
        )
        let slot = prompt.slots.first { $0.id == .surrounding }!
        #expect(slot.truncated)
        #expect(slot.untrusted)
        // Budget + tolerance for the fences and estimate granularity.
        #expect(slot.tokensEstimated <= 300 + 60, "slot over budget: \(slot.tokensEstimated)")
        #expect(slot.text.hasPrefix(PromptAssembler.untrustedFenceOpen))
        #expect(slot.text.hasSuffix(PromptAssembler.untrustedFenceClose))
        #expect(slot.text.contains(SurroundingTreeRenderer.fieldMarkerPrefix))
        // The field note ties the marker to the empty box.
        #expect(slot.text.contains("empty \"Add a comment…\" box"))
        // The chain still says WHICH post the field belongs to.
        #expect(slot.text.contains("YOU ARE WRITING IN: feed › post 6 › comments"))
        // The nearest comment survives; the far posts went first.
        #expect(slot.text.contains("COMMENT-6"))
        #expect(!slot.text.contains("POST-1 "))
    }

    @Test func treeModeZeroLimitRendersEverythingUntrimmed() {
        let prompt = assemble(
            workflow: MagicTestSupport.makeWorkflow(
                id: "capped",
                budget: BudgetSpec(promptTokensTotal: 1000, ms: 6000)
            ),
            snapshot: MagicTestSupport.makeSnapshot(surroundingTree: bigTree()),
            surroundingMaxTokens: 0
        )
        let slot = prompt.slots.first { $0.id == .surrounding }!
        #expect(!slot.truncated)
        #expect(slot.text.contains("POST-1 "))
        #expect(slot.text.contains("POST-12 "))
        #expect(slot.text.contains(SurroundingTreeRenderer.fieldMarkerPrefix))
        #expect(!slot.text.contains(SurroundingTreeRenderer.trimMarker))
    }

    @Test func trustAndUntrustPoolsSeparateCorrectly() {
        let prompt = assemble(
            snapshot: MagicTestSupport.makeSnapshot(
                value: "TRUSTED-DRAFT",
                surroundingContent: "UNTRUSTED-POST"
            ),
            hint: "TRUSTED-HINT"
        )
        #expect(prompt.trustedContext.contains("TRUSTED-DRAFT"))
        #expect(prompt.trustedContext.contains("TRUSTED-HINT"))
        #expect(!prompt.trustedContext.contains("UNTRUSTED-POST"))
        #expect(prompt.untrustedContext.contains("UNTRUSTED-POST"))
    }

    @Test func systemPromptIsTheTemplateByDefault() {
        let prompt = assemble()
        #expect(prompt.systemPrompt == PromptAssembler.systemPromptTemplate)
        #expect(prompt.systemPrompt.contains("Return ONLY the text to insert"))
        #expect(prompt.systemPrompt.contains("LANGUAGE"))
    }

    @Test func systemPromptOverrideWinsWhenPresent() {
        let prompt = assemble(core: CoreFileSet(
            identity: "", writingStyle: "", constraintsText: "", aliases: "",
            constraints: [], systemPromptOverride: "CUSTOM SYSTEM PROMPT"
        ))
        #expect(prompt.systemPrompt == "CUSTOM SYSTEM PROMPT")
    }

    @Test func removeSectionRemovesHeadingThroughNextHeading() {
        let text = "## Rules\n- a\n\n## Examples\n- b\n\n## Anti-examples\n- c"
        let result = PromptAssembler.removeSection(named: "Examples", from: text)
        #expect(!result.contains("- b"))
        #expect(result.contains("- a"))
        #expect(result.contains("- c"))
    }
}
