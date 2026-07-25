import CoreFoundation
import Testing
@testable import ClipSlop

@Suite("Continuation seam")
struct ContinuationSeamTests {
    @Test(arguments: [
        // (preceding char, output, expected)
        ("." as Character?, "We need more time.", " We need more time."),
        ("d", "and then some", " and then some"),
        ("7", "items remain", " items remain"),
        (")", "Next point", " Next point"),
        ("?", "Да, конечно.", " Да, конечно."),
    ])
    func insertsJoiningSpace(_ prev: Character?, _ output: String, _ expected: String) {
        #expect(ContinuationSeam.join(output: output, afterPrecedingCharacter: prev) == expected)
    }

    @Test(arguments: [
        // Glue punctuation stays fused: the model continued mid-sentence.
        ("d" as Character?, ", so we wait", ", so we wait"),
        ("d", ". Done.", ". Done."),
        ("d", ")", ")"),
        // After whitespace or an opening bracket/quote nothing is added.
        (" ", "We need", "We need"),
        ("\n", "New paragraph", "New paragraph"),
        ("(", "aside", "aside"),
        ("«", "цитата", "цитата"),
        // Empty field / caret at position 0.
        (nil, "Fresh start", "Fresh start"),
    ])
    func leavesOutputAlone(_ prev: Character?, _ output: String, _ expected: String) {
        #expect(ContinuationSeam.join(output: output, afterPrecedingCharacter: prev) == expected)
    }

    @Test func noSpaceBetweenCJK() {
        #expect(ContinuationSeam.join(output: "続きです", afterPrecedingCharacter: "本") == "続きです")
        // Latin after CJK still gets the space (mixed-script sentence).
        #expect(ContinuationSeam.join(output: "OK then", afterPrecedingCharacter: "本") == " OK then")
    }

    @Test func adjustAppliesOnlyToDraftRow() {
        func snapshot(
            value: String,
            selection: MagicSnapshot.SelectionInfo? = nil,
            selectedRange: Range<Int>? = nil
        ) -> MagicSnapshot {
            MagicTestSupport.makeSnapshot(
                value: value, selection: selection, selectedRange: selectedRange
            )
        }

        // Draft, no range → seam joins after the last character.
        let draft = snapshot(value: "Release is red.")
        #expect(ContinuationSeam.adjust(output: "We need time.", for: draft) == " We need time.")

        // Draft with a mid-text caret → the seam reads the character before
        // the CARET, not the end of the field. The draft row has no selected
        // text by definition, so `selection` is always nil here: reading
        // `selection?.range` meant this branch could never run and every
        // mid-field paste was joined against the last character instead.
        // A caret right after a space must add nothing; the end of the field
        // ("...world") would add one, so this discriminates.
        let midCaret = snapshot(value: "Hello world", selectedRange: 6..<6)
        #expect(ContinuationSeam.adjust(output: "there", for: midCaret) == "there")

        let afterWord = snapshot(value: "Hello world", selectedRange: 5..<5)
        #expect(ContinuationSeam.adjust(output: "there", for: afterWord) == " there")

        // Caret at 0 → nothing precedes it.
        let atStart = snapshot(value: "world", selectedRange: 0..<0)
        #expect(ContinuationSeam.adjust(output: "Hello", for: atStart) == "Hello")

        // Selection row (rewrite) must never be touched.
        let selection = snapshot(
            value: "Fix this text",
            selection: .init(range: 0..<13, text: "Fix this text"),
            selectedRange: 0..<13
        )
        #expect(ContinuationSeam.adjust(output: "Rewritten.", for: selection) == "Rewritten.")

        // Empty field → untouched.
        let empty = snapshot(value: "")
        #expect(ContinuationSeam.adjust(output: "Fresh.", for: empty) == "Fresh.")
    }
}

@Suite("AX range conversion")
struct AXCharacterRangeTests {
    /// AX reports UTF-16 offsets. Bounds-checking them against `value.count`
    /// and slicing with grapheme-based `index(_:offsetBy:)` shifted the
    /// recovered text by one position per astral character before it.
    @Test func utf16OffsetsMapOntoCharacterOffsets() {
        // "👋" is one character but two UTF-16 units.
        let value = "👋 hello world"
        // UTF-16 offsets 3..<8 == "hello" (1 emoji unit pair + space).
        let range = try! #require(
            AXSnapshotService.characterRange(CFRange(location: 3, length: 5), in: value)
        )
        let start = value.index(value.startIndex, offsetBy: range.lowerBound)
        let end = value.index(value.startIndex, offsetBy: range.upperBound)
        #expect(String(value[start..<end]) == "hello")
        // The character range is shifted relative to the UTF-16 one.
        #expect(range == 2..<7)
    }

    @Test func plainASCIIIsUnchanged() {
        #expect(AXSnapshotService.characterRange(CFRange(location: 2, length: 3), in: "abcdef") == 2..<5)
        // A caret keeps its position and stays empty.
        #expect(AXSnapshotService.characterRange(CFRange(location: 4, length: 0), in: "abcdef") == 4..<4)
    }

    @Test func outOfBoundsAndNegativeRangesAreRejected() {
        #expect(AXSnapshotService.characterRange(CFRange(location: 10, length: 1), in: "abc") == nil)
        #expect(AXSnapshotService.characterRange(CFRange(location: 1, length: 99), in: "abc") == nil)
        #expect(AXSnapshotService.characterRange(CFRange(location: -1, length: 2), in: "abc") == nil)
        // Landing inside a surrogate pair has no character index.
        #expect(AXSnapshotService.characterRange(CFRange(location: 1, length: 1), in: "👋a") == nil)
    }
}
