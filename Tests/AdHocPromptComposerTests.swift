import Testing
@testable import ClipSlop

@MainActor
struct AdHocPromptComposerTests {
    @Test func replacesPlaceholderWithInstruction() {
        let result = AdHocPromptComposer.compose(
            template: "Do this:\n{instruction}\nOnly output text.",
            instruction: "Make it shorter"
        )
        #expect(result == "Do this:\nMake it shorter\nOnly output text.")
    }

    @Test func replacesEveryPlaceholderOccurrence() {
        let result = AdHocPromptComposer.compose(
            template: "{instruction} — {instruction}",
            instruction: "X"
        )
        #expect(result == "X — X")
    }

    @Test func appendsInstructionWhenPlaceholderMissing() {
        let result = AdHocPromptComposer.compose(
            template: "You transform text.",
            instruction: "Translate to German"
        )
        #expect(result == "You transform text.\n\nInstruction:\nTranslate to German")
    }

    @Test func trimsInstructionWhitespace() {
        let result = AdHocPromptComposer.compose(
            template: "{instruction}",
            instruction: "  fix typos \n"
        )
        #expect(result == "fix typos")
    }

    @Test func defaultTemplateContainsPlaceholder() {
        #expect(AppSettings.defaultAdHocSystemPrompt.contains(AdHocPromptComposer.instructionPlaceholder))
    }

    @Test func stepNameUsesFirstLineOnly() {
        #expect(AdHocPromptComposer.stepName(for: "fix grammar\nand style") == "fix grammar")
    }

    @Test func stepNameTruncatesLongInstructions() {
        let long = String(repeating: "a", count: 60)
        let name = AdHocPromptComposer.stepName(for: long)
        #expect(name.count == 41)
        #expect(name.hasSuffix("…"))
    }

    @Test func stepNameKeepsShortInstructionIntact() {
        #expect(AdHocPromptComposer.stepName(for: "  shorten  ") == "shorten")
    }
}
