import Testing
@testable import ClipSlop

@Suite("Selection classifier")
struct SelectionClassifierTests {
    @Test(arguments: [
        "напиши ответ сюда",
        "вставь сюда наши тарифы таблицей",
        "переведи это письмо",
        "write a polite decline here",
        "insert the pricing table here",
        "kirjoita vastaus tähän",
        "korjaa tämä",
    ])
    func imperativeSeedsClassifyAsInstruction(seed: String) {
        let result = SelectionClassifier.classify(seed)
        #expect(result.top == .instruction, "\(seed) → \(result.ranked)")
        #expect(!result.isTie)
    }

    @Test func longProseClassifiesAsMaterial() {
        let paragraph = """
        The quarterly numbers came in above plan for the third time running. \
        Renewals held at 96 percent and the pipeline for the enterprise tier \
        doubled after the webinar series. The board asked for a deeper look at \
        churn drivers in the SMB segment before we commit to the new pricing. \
        Overall the team feels the strategy is working and wants to keep the \
        current course through the end of the year.
        """
        let result = SelectionClassifier.classify(paragraph)
        #expect(result.top == .material)
        #expect(!result.isTie)
    }

    @Test func mixedSeedClassifiesAsMixed() {
        let result = SelectionClassifier.classify(
            "согласен + упомяни бенчмарки из поста и наш опыт с миграцией на новую версию. мягко про сроки"
        )
        #expect(result.top == .mixed)
    }

    @Test func imperativeWithMaterialBulkIsMixed() {
        let result = SelectionClassifier.classify("""
        write a reply that covers these points. We shipped the migration two \
        weeks early. The benchmark suite now runs in nine minutes instead of \
        forty. Two customers already asked about the enterprise tier.
        """)
        #expect(result.top == .mixed)
    }

    @Test func shortDeclarativeMultiSentenceMessageIsATie() {
        // The 2026-07-23 live-test case: a plain status message selected for
        // rewriting must not silently classify as an instruction — the tie
        // forces chips and the user decides.
        let result = SelectionClassifier.classify(
            "Я вернулся из отпуска и уже два дня в работе. Со следующей недели можно возобновить наши встречи и вернуться к обычному рабочему ритму."
        )
        #expect(result.isTie)
    }

    @Test func indeterminateMidLengthTextIsTie() {
        // ~250 chars, one line, no imperative, no deixis: no signal fires.
        let text = String(repeating: "word ", count: 50)
        let result = SelectionClassifier.classify(text)
        #expect(result.isTie)
        #expect(result.top == .instruction)  // tie breaks toward instruction (§3.4)
    }

    @Test func signalsAreReported() {
        let result = SelectionClassifier.classify("напиши это сюда")
        #expect(result.signals.leadingImperative)
        #expect(result.signals.containsDeixis)
        #expect(result.signals.lineCount == 1)
    }
}
