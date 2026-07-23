import Testing
@testable import ClipSlop

/// The §0 interaction table as literal test cases.
@Suite("Magic grammar")
struct MagicGrammarTests {
    private func field(
        editable: Bool = true,
        secure: Bool = false,
        value: String = "",
        selectionText: String? = nil
    ) -> MagicSnapshot.FieldInfo {
        MagicSnapshot.FieldInfo(
            role: "AXTextArea", subrole: nil, editable: editable, secure: secure,
            value: value,
            selection: selectionText.map { .init(range: nil, text: $0) },
            placeholder: nil
        )
    }

    @Test func emptyEditableFieldIsEmptyRow() {
        #expect(MagicGrammar.classify(field: field()) == .emptyField)
    }

    @Test func whitespaceOnlyValueCountsAsEmpty() {
        #expect(MagicGrammar.classify(field: field(value: "  \n ")) == .emptyField)
    }

    @Test func unselectedDraftIsDraftRow() {
        #expect(MagicGrammar.classify(field: field(value: "Dear Ville,")) == .draft)
    }

    @Test func selectionInEditableFieldIsEditableSelection() {
        #expect(MagicGrammar.classify(
            field: field(value: "note here", selectionText: "note here")
        ) == .editableSelection)
    }

    @Test func selectionInNonEditableAreaIsNonEditableSelection() {
        #expect(MagicGrammar.classify(
            field: field(editable: false, value: "article text", selectionText: "article text")
        ) == .nonEditableSelection)
    }

    @Test func secureFieldIsDeadNoExceptions() {
        #expect(MagicGrammar.classify(field: field(secure: true)) == .secure)
        #expect(MagicGrammar.classify(
            field: field(secure: true, value: "hunter2", selectionText: "hunter2")
        ) == .secure)
    }

    @Test func noFocusIsNoTarget() {
        #expect(MagicGrammar.classify(field: nil) == .noTarget)
    }

    @Test func nonEditableWithoutSelectionIsNoTarget() {
        #expect(MagicGrammar.classify(field: field(editable: false, value: "text")) == .noTarget)
    }

    @Test func emptySelectionTextDoesNotCountAsSelection() {
        #expect(MagicGrammar.classify(
            field: field(value: "draft", selectionText: "")
        ) == .draft)
    }

    @Test func fullSelectionIsDetected() {
        let info = MagicSnapshot.FieldInfo(
            role: "AXTextArea", subrole: nil, editable: true, secure: false,
            value: "rewrite all of this",
            selection: .init(range: 0..<19, text: "rewrite all of this"),
            placeholder: nil
        )
        #expect(info.isFullSelection)
    }

    @Test func partialSelectionIsNotFull() {
        let info = MagicSnapshot.FieldInfo(
            role: "AXTextArea", subrole: nil, editable: true, secure: false,
            value: "keep this part",
            selection: .init(range: 0..<4, text: "keep"),
            placeholder: nil
        )
        #expect(!info.isFullSelection)
    }

    @Test func fieldStateReflectsGrammar() {
        #expect(MagicTestSupport.makeSnapshot(value: "").fieldState == .empty)
        #expect(MagicTestSupport.makeSnapshot(value: "text").fieldState == .draft)
        #expect(MagicTestSupport.makeSnapshot(
            value: "text", selection: .init(range: nil, text: "text")
        ).fieldState == .selection)
    }
}
