import Testing
@testable import ClipSlop

/// The Inserter's "is the field still the field we planned for" decision
/// table. Pure — every AX read has already happened by the time it is called,
/// which is why it is worth pinning down here: the live behaviour it guards
/// (a paste refused, an undo withheld) is otherwise only observable against a
/// real app.
@Suite("Magic insert field-drift guard")
struct MagicInserterGuardTests {
    private func agrees(
        expected: String?, expectedRange: Range<Int>? = nil,
        current: String?, currentRange: Range<Int>? = nil
    ) -> Bool {
        MagicInserter.fieldStateAgrees(
            expectedValue: expected, expectedRange: expectedRange,
            currentValue: current, currentRange: currentRange
        )
    }

    // MARK: - The fast path must stay fast

    @Test func untouchedFieldWithUnmovedCaretAgrees() {
        #expect(agrees(
            expected: "Dear Ville,", expectedRange: 11..<11,
            current: "Dear Ville,", currentRange: 11..<11
        ))
    }

    @Test func untouchedFieldWithoutAnyCaretReadingAgrees() {
        // Web composers routinely publish a value and no selected range at
        // all. Missing evidence must not read as evidence of a change.
        #expect(agrees(expected: "Dear Ville,", current: "Dear Ville,"))
    }

    @Test func unreadableValuesNeverFail() {
        // Both sides opaque, and the empty-value case capture cannot tell
        // apart from an opaque one: neither may cost the user their paste.
        #expect(agrees(expected: nil, current: nil))
        #expect(agrees(expected: "", current: "typed while the model ran"))
        #expect(agrees(expected: "Dear Ville,", current: nil))
    }

    @Test func unchangedSelectionAgrees() {
        #expect(agrees(
            expected: "rewrite this bit", expectedRange: 8..<16,
            current: "rewrite this bit", currentRange: 8..<16
        ))
    }

    // MARK: - Drift during generation

    @Test func typingAtTheEndIsRefused() {
        #expect(!agrees(
            expected: "Dear Ville,", expectedRange: 11..<11,
            current: "Dear Ville, thanks for", currentRange: 22..<22
        ))
    }

    @Test func typingAtTheEndIsRefusedWithoutCaretEvidenceToo() {
        // No range published on either side: an extension is then
        // indistinguishable from a clipped capture, and the tie goes against
        // pasting.
        #expect(!agrees(expected: "Dear Ville,", current: "Dear Ville, thanks"))
    }

    @Test func editingTheMiddleIsRefused() {
        #expect(!agrees(
            expected: "Dear Ville,", expectedRange: 11..<11,
            current: "Dear dear Ville,", currentRange: 16..<16
        ))
    }

    @Test func deletingIsRefused() {
        #expect(!agrees(
            expected: "Dear Ville,", expectedRange: 11..<11,
            current: "Dear", currentRange: 4..<4
        ))
    }

    @Test func movedCaretAloneIsRefused() {
        // Same text, different insertion point: the result was assembled for
        // the old caret and would land somewhere nobody asked for.
        #expect(!agrees(
            expected: "Dear Ville,", expectedRange: 11..<11,
            current: "Dear Ville,", currentRange: 4..<4
        ))
    }

    @Test func reselectingSomethingElseIsRefused() {
        #expect(!agrees(
            expected: "rewrite this bit", expectedRange: 8..<16,
            current: "rewrite this bit", currentRange: 0..<7
        ))
    }

    @Test func emptyFieldTypedIntoIsRefusedWhenTheCaretSaysSo() {
        // The value cannot decide ("" reads the same whether the field was
        // empty or opaque), so the caret has to.
        #expect(!agrees(expected: "", expectedRange: 0..<0, current: "hi", currentRange: 2..<2))
    }

    // MARK: - The clipped-capture ambiguity

    @Test func clippedCaptureWithAnUnmovedCaretStillAgrees() {
        // `maxFieldValueChars` cut the tail off a long document. The current
        // value extends the expected one exactly as typing at the end would —
        // but the caret has not moved, and typing always moves it.
        #expect(agrees(
            expected: "chapter one", expectedRange: 4..<4,
            current: "chapter one, and everything capture had to drop",
            currentRange: 4..<4
        ))
    }

    /// The other shape `AXSnapshotService.retainedWindow` produces: with the
    /// caret past `field_value_max_chars` the kept window *ends* at the caret,
    /// so the captured value is a mid-string slice rather than a prefix. Read
    /// as a changed field, this sent every press in a >50k-character document
    /// to the clipboard.
    @Test func caretAnchoredCaptureWindowStillAgrees() {
        let head = String(repeating: "a", count: 40)
        let kept = "the sentence the caret follows"
        #expect(agrees(
            expected: kept, expectedRange: (head.count + kept.count)..<(head.count + kept.count),
            current: head + kept + " and the tail beyond it",
            currentRange: (head.count + kept.count)..<(head.count + kept.count)
        ))
    }

    @Test func caretAnchoredWindowThatNoLongerMatchesIsRefused() {
        // Same geometry, but the text immediately before the caret changed —
        // the user edited inside the window we planned against.
        let head = String(repeating: "a", count: 40)
        let kept = "the sentence the caret follows"
        #expect(!agrees(
            expected: kept, expectedRange: (head.count + kept.count)..<(head.count + kept.count),
            current: head + "a different sentence entirely" + " and the tail beyond it",
            currentRange: (head.count + kept.count)..<(head.count + kept.count)
        ))
    }
}
