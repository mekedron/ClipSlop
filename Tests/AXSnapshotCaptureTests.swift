import CoreFoundation
import Testing
@testable import ClipSlop

/// The pure half of the press-time capture: how an over-long field value is
/// truncated, and what that leaves the downstream consumers holding. The AX
/// reads themselves need a live target and are covered by the live E2E rig.
@Suite("AX snapshot capture")
struct AXSnapshotCaptureTests {
    // MARK: - Retained window (§5.1 field_value_max_chars)

    @Test func keepsShortValuesWhole() {
        #expect(AXSnapshotService.retainedWindow(valueCount: 40, around: nil, maxChars: 100) == 0..<40)
        #expect(
            AXSnapshotService.retainedWindow(valueCount: 40, around: 3..<9, maxChars: 100) == 0..<40
        )
    }

    /// A caret inside the leading `maxChars` keeps the historical prefix, so
    /// the reported offsets still index `field.value` directly — the cheap
    /// consumers (`PromptAssembler.split` slicing, `ContinuationSeam`) stay
    /// exact, and nothing about the common case moves.
    @Test func keepsPrefixWhileTheRangeFitsInside() {
        #expect(AXSnapshotService.retainedWindow(valueCount: 500, around: 10..<20, maxChars: 100) == 0..<100)
        #expect(AXSnapshotService.retainedWindow(valueCount: 500, around: 99..<100, maxChars: 100) == 0..<100)
        #expect(AXSnapshotService.retainedWindow(valueCount: 500, around: nil, maxChars: 100) == 0..<100)
    }

    /// The regression: with a bare prefix, a caret past the cap was thrown
    /// away with the text around it. The window now ends exactly at the caret,
    /// which is the position every consumer assumes when no range survives.
    @Test func slidesTheWindowToEndAtTheCaret() {
        #expect(AXSnapshotService.retainedWindow(valueCount: 500, around: 400..<400, maxChars: 100) == 300..<400)
        #expect(AXSnapshotService.retainedWindow(valueCount: 500, around: 500..<500, maxChars: 100) == 400..<500)
        // A selection ends the window at its upper bound: what precedes the
        // selection is the context the press needs.
        #expect(AXSnapshotService.retainedWindow(valueCount: 500, around: 380..<420, maxChars: 100) == 320..<420)
    }

    /// A stale range that does not fit the value at all must not drag the
    /// window somewhere arbitrary.
    @Test func ignoresRangesOutsideTheValue() {
        #expect(AXSnapshotService.retainedWindow(valueCount: 200, around: 300..<340, maxChars: 100) == 0..<100)
        #expect(AXSnapshotService.retainedWindow(valueCount: 200, around: nil, maxChars: 0) == 0..<0)
    }

    // MARK: - Slicing

    @Test func slicesOnCharacterBoundaries() {
        let value = String(repeating: "🙂", count: 20) + "x."
        let window = AXSnapshotService.retainedWindow(
            valueCount: value.count, around: 22..<22, maxChars: 5
        )
        #expect(window == 17..<22)
        // Grapheme-safe: a naive UTF-16 slice here would cut a surrogate pair.
        #expect(AXSnapshotService.retainedValue(value, window: window) == "🙂🙂🙂x.")
    }

    @Test func returnsTheWholeValueForAFullWindow() {
        let value = "short enough"
        let window = AXSnapshotService.retainedWindow(
            valueCount: value.count, around: nil, maxChars: 100
        )
        #expect(AXSnapshotService.retainedValue(value, window: window) == value)
    }

    // MARK: - Range conversion

    /// AX speaks UTF-16 and the snapshot speaks characters; the conversion is
    /// done against the WHOLE value, before any truncation, or the offsets
    /// mean nothing.
    @Test func convertsUTF16RangesAgainstTheWholeValue() {
        let value = "🙂abc"
        #expect(AXSnapshotService.characterRange(CFRange(location: 2, length: 3), in: value) == 1..<4)
        // Mid-surrogate and out-of-bounds ranges have no character answer.
        #expect(AXSnapshotService.characterRange(CFRange(location: 1, length: 1), in: value) == nil)
        #expect(AXSnapshotService.characterRange(CFRange(location: 40, length: 1), in: value) == nil)
    }

    // MARK: - What the consumers see

    /// `ContinuationSeam` clamps the caret to `value.count`. Because the
    /// window ends at the caret, that clamp now lands on the character the
    /// user's caret actually follows — with the old prefix it landed on
    /// whatever happened to sit at character 50 000.
    @Test func continuationSeamJoinsAgainstTheRealCaret() {
        let full = String(repeating: "a", count: 100) + " ("
        let range = full.count..<full.count
        let window = AXSnapshotService.retainedWindow(
            valueCount: full.count, around: range, maxChars: 10
        )
        let value = AXSnapshotService.retainedValue(full, window: window)
        let snapshot = MagicTestSupport.makeSnapshot(value: value, selectedRange: range)

        #expect(snapshot.grammarRow == .draft)
        // The caret follows an opening bracket, so no joining space is added.
        // Against the prefix the preceding character was "a" and the seam
        // wrongly inserted one.
        #expect(ContinuationSeam.adjust(output: "aside", for: snapshot) == "aside")
    }

    /// The retained offsets are absolute (into the field's whole value), which
    /// is what the coordinator's re-assert path needs. Consumers that index
    /// into `field.value` instead are protected by their own bounds check: a
    /// shifted window always has `upperBound > value.count`, so they fall back
    /// to text search rather than slicing at a wrong offset — and the text
    /// search now finds the selection because the retained text surrounds it.
    @Test func assemblerStillPositionsASelectionPastTheCap() throws {
        let full = String(repeating: "a", count: 100) + "hello"
        let range = 100..<105
        let window = AXSnapshotService.retainedWindow(
            valueCount: full.count, around: range, maxChars: 12
        )
        let value = AXSnapshotService.retainedValue(full, window: window)
        #expect(value == String(repeating: "a", count: 7) + "hello")

        // The retained text contains the selection exactly once, so the
        // assembler's unambiguous-match fallback still positions it.
        let selection = MagicSnapshot.SelectionInfo(range: range, text: "hello")
        let (before, after) = try #require(PromptAssembler.split(value: value, around: selection))
        #expect(before == String(repeating: "a", count: 7))
        #expect(after == "")
    }

    /// Unshifted windows keep the fast path: the absolute range is also a
    /// valid index into `value`, and the assembler slices with it directly.
    @Test func assemblerSlicesDirectlyWhenTheWindowIsUnshifted() throws {
        let full = "Dear Ada, thank you for the note."
        let range = 5..<8
        let window = AXSnapshotService.retainedWindow(
            valueCount: full.count, around: range, maxChars: 1_000
        )
        #expect(window.lowerBound == 0)
        let value = AXSnapshotService.retainedValue(full, window: window)
        let (before, after) = try #require(PromptAssembler.split(
            value: value, around: MagicSnapshot.SelectionInfo(range: range, text: "Ada")
        ))
        #expect(before == "Dear ")
        #expect(after == ", thank you for the note.")
    }
}
