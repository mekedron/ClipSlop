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
        hint: String? = nil
    ) -> AssembledPrompt {
        PromptAssembler.assemble(
            workflow: workflow, snapshot: snapshot,
            core: core ?? self.core, classification: classification, hint: hint
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
            )
        )
        for slot in prompt.slots {
            // Small tolerance for section headers added after trimming.
            #expect(slot.tokensEstimated <= slot.id.budgetTokens + 30, "\(slot.id) over budget: \(slot.tokensEstimated)")
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

    @Test func workflowCapBelowTableTrimsSurroundingFirst() {
        let surrounding = String(repeating: "thread message content ", count: 200)
        let prompt = assemble(
            workflow: MagicTestSupport.makeWorkflow(
                id: "capped",
                budget: BudgetSpec(promptTokensTotal: 1000, ms: 6000)
            ),
            snapshot: MagicTestSupport.makeSnapshot(value: "My draft.", surroundingContent: surrounding)
        )
        #expect(prompt.totalTokensEstimated <= 1000 + 30)
        let surroundingSlot = prompt.slots.first { $0.id == .surrounding }!
        #expect(surroundingSlot.truncated)
        // The user's own field content survives the cross-slot trim.
        let fieldSlot = prompt.slots.first { $0.id == .fieldInput }!
        #expect(fieldSlot.text.contains("My draft."))
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
