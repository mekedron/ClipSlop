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

/// The other half of the pre-paste guard: the selection re-assert a press runs
/// immediately before handing text to the inserter. The AX reads behind it now
/// happen inside `MagicInserter`'s reader actor (they used to block the main
/// actor for up to three 0.35 s round-trips while the user waited for the
/// paste), which leaves the decision itself pure — and worth pinning down,
/// because both of its refusals look identical from outside: the text quietly
/// goes to the toast instead of into the field.
@Suite("Magic pre-paste selection re-assert")
struct MagicSelectionReassertTests {
    private func verdict(
        captured: Range<Int>,
        value: String,
        hasLiveSelection: Bool = false,
        liveRange: Range<Int>? = nil
    ) -> MagicSelectionVerdict {
        MagicPressCoordinator.selectionVerdict(
            captured: captured,
            probe: MagicSelectionProbe(
                value: value, hasLiveSelection: hasLiveSelection, liveRange: liveRange
            )
        )
    }

    // MARK: - A selection that survived

    @Test func ourOwnSelectionStillLiveProceeds() {
        #expect(verdict(
            captured: 8..<16, value: "rewrite this bit",
            hasLiveSelection: true, liveRange: 8..<16
        ) == .proceed)
    }

    @Test func aDifferentLiveSelectionIsRefused() {
        // The user re-selected while chips or generation were up. The plan was
        // written for the OLD span, so pasting would replace text nobody
        // addressed — clipboard + toast instead.
        #expect(verdict(
            captured: 8..<16, value: "rewrite this bit",
            hasLiveSelection: true, liveRange: 0..<7
        ) == .refuse)
    }

    @Test func aLiveSelectionOutsideTheCurrentValueIsRefused() {
        // The probe could not map the live UTF-16 range into the value it read
        // in the same breath: the field moved underneath the reading, so the
        // range describes a field state nobody planned against.
        #expect(verdict(
            captured: 8..<16, value: "rewrite this bit",
            hasLiveSelection: true, liveRange: nil
        ) == .refuse)
    }

    // MARK: - A selection the target dropped

    @Test func aDroppedSelectionIsReassertedInUTF16() {
        // The whole point of routing this through `utf16Range`: the captured
        // offsets are characters, AX wants UTF-16, and handing over the
        // character numbers verbatim reselects a span shifted by every astral
        // character before it — the paste then overwrites text the user never
        // selected.
        #expect(verdict(captured: 1..<3, value: "🙂ab") == .reassert(location: 2, length: 2))
        #expect(verdict(captured: 0..<4, value: "Some draft") == .reassert(location: 0, length: 4))
    }

    @Test func aDroppedSelectionThatNoLongerFitsIsRefused() {
        // Deleted text while the model ran: our offsets now point past the end
        // of the field. Re-asserting a range that points nowhere would paste at
        // whatever AX clamps it to, so this refuses like a re-selection does.
        #expect(verdict(captured: 5..<7, value: "🙂ab") == .refuse)
        #expect(verdict(captured: 0..<4, value: "abc") == .refuse)
    }

    @Test func anUnreadableFieldFallsBackToTheCapturedValue() {
        // `value` is the probe's already-resolved reading: live when AX
        // published one, the captured (truncated) snapshot value when it did
        // not. The decision must still be taken — refusing every press in a
        // field with an opaque AXValue would remove the feature from most web
        // composers — so an empty fallback simply refuses the ranges that do
        // not fit it, and accepts the degenerate one that does.
        #expect(verdict(captured: 0..<4, value: "") == .refuse)
        #expect(verdict(captured: 0..<0, value: "") == .reassert(location: 0, length: 0))
    }
}
