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
        func snapshot(value: String, selection: MagicSnapshot.SelectionInfo?) -> MagicSnapshot {
            MagicSnapshot(
                app: .init(name: "TextEdit", bundleId: "com.apple.TextEdit", pid: 1),
                windowTitle: nil, url: nil,
                field: .init(role: "AXTextArea", subrole: nil, editable: true, secure: false,
                             value: value, selection: selection, placeholder: nil),
                surrounding: nil, locale: "en", ts: .init(timeIntervalSince1970: 0),
                focusedElement: nil
            )
        }

        // Draft, no range → seam joins after the last character.
        let draft = snapshot(value: "Release is red.", selection: nil)
        #expect(ContinuationSeam.adjust(output: "We need time.", for: draft) == " We need time.")

        // Draft with a mid-text caret range → seam looks at the char before the caret.
        let midCaret = snapshot(
            value: "Hello world",
            selection: .init(range: 5..<5, text: "")
        )
        #expect(ContinuationSeam.adjust(output: "there", for: midCaret) == " there")

        // Selection row (rewrite) must never be touched.
        let selection = snapshot(
            value: "Fix this text",
            selection: .init(range: 0..<13, text: "Fix this text")
        )
        #expect(ContinuationSeam.adjust(output: "Rewritten.", for: selection) == "Rewritten.")

        // Empty field → untouched.
        let empty = snapshot(value: "", selection: nil)
        #expect(ContinuationSeam.adjust(output: "Fresh.", for: empty) == "Fresh.")
    }
}
