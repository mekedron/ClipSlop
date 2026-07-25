import Foundation
import Testing
@testable import ClipSlop

@Suite("Caret locator geometry")
struct CaretLocatorMathTests {
    @Test func flipsAXTopLeftToAppKitBottomLeft() {
        // A 20pt-tall rect whose top edge sits 100pt below the top of a
        // 1000pt-tall primary screen → its bottom edge is 880pt above the
        // AppKit origin.
        let flipped = CaretLocator.flipToAppKit(
            CGRect(x: 50, y: 100, width: 200, height: 20),
            primaryScreenHeight: 1000
        )
        #expect(flipped == NSRect(x: 50, y: 880, width: 200, height: 20))
    }

    @Test func panelGoesAboveTheAnchorWhenRoomExists() {
        let origin = CaretLocator.panelOrigin(
            anchor: NSRect(x: 100, y: 500, width: 10, height: 20),
            panelSize: NSSize(width: 300, height: 100),
            visibleFrame: NSRect(x: 0, y: 0, width: 1600, height: 900)
        )
        #expect(origin == NSPoint(x: 100, y: 528))  // anchor.maxY (520) + gap
    }

    @Test func panelFallsBelowWhenNoRoomAbove() {
        let origin = CaretLocator.panelOrigin(
            anchor: NSRect(x: 100, y: 840, width: 10, height: 20),
            panelSize: NSSize(width: 300, height: 100),
            visibleFrame: NSRect(x: 0, y: 0, width: 1600, height: 900)
        )
        #expect(origin.y == 732)  // 840 - 8 - 100
    }

    @Test func panelClampsToScreenEdges() {
        let origin = CaretLocator.panelOrigin(
            anchor: NSRect(x: 1590, y: 500, width: 10, height: 20),
            panelSize: NSSize(width: 300, height: 100),
            visibleFrame: NSRect(x: 0, y: 0, width: 1600, height: 900)
        )
        #expect(origin.x == 1300)  // clamped to maxX - width
    }
}

@Suite("Pasteboard transaction logic")
struct PasteboardTransactionLogicTests {
    @Test func restoresOnlyWhenNobodyWroteSinceUs() {
        #expect(PasteboardTransaction.shouldRestore(currentCount: 7, ourWriteCount: 7))
        // A clipboard manager or the user wrote after us → leave it alone.
        #expect(!PasteboardTransaction.shouldRestore(currentCount: 9, ourWriteCount: 7))
    }
}

@Suite("Surrounding-content assembly")
struct SurroundingAssemblyTests {
    @Test func dedupsConsecutiveAndCollapsesWhitespace() {
        let result = AXSnapshotService.assembleContent(
            pieces: ["Hello   world", "Hello world", "Next \n line", ""],
            maxChars: 1000
        )
        #expect(result == "Hello world\nNext line")
    }

    @Test func capsTotalLength() {
        let result = AXSnapshotService.assembleContent(
            pieces: [String(repeating: "abc ", count: 100)],
            maxChars: 50
        )
        #expect(result.count == 50)
    }

    @Test func webContentKeepsTailBeforeFieldAndHeadAfter() {
        // A chat: many old messages, the composer, a little footer. The
        // kept window is the newest messages right above the field.
        let before = (1...50).map { "message \($0) with some padding text here" }
        let after = ["footer line one", "footer line two", "footer line three"]
        let result = AXSnapshotService.assembleWebContent(
            before: before, after: after,
            beforeKeepChars: 200, afterKeepChars: 20, maxChars: 6000
        )
        #expect(result.contains("message 50"))
        #expect(result.contains("message 46"))
        #expect(!result.contains("message 1 "))
        #expect(result.contains("footer line one"))
        #expect(!result.contains("footer line three"))
        // Document order is preserved: newest-kept message still precedes the footer.
        let posMessage = result.range(of: "message 50")!.lowerBound
        let posFooter = result.range(of: "footer line one")!.lowerBound
        #expect(posMessage < posFooter)
    }
}

@MainActor
@Suite("Selection capture trigger")
struct MagicSelectionCaptureTests {
    /// The ⌘C probe must fire only when the app CLAIMS a selection AX would
    /// not hand over. "Editable and non-empty" was true of every draft, and in
    /// a copy-current-line target the probe returns text with nothing
    /// selected — `refine` then promoted that to a real selection while the
    /// paste still landed at the caret, rewriting a line nobody addressed.
    @Test func firesOnlyOnAClaimedButUnreadableSelection() {
        // A plain draft: no range, nothing to recover.
        #expect(!MagicSelectionCapture.isNeeded(for: MagicTestSupport.makeSnapshot(
            value: "Some draft the user is writing"
        )))
        // A caret is not a selection.
        #expect(!MagicSelectionCapture.isNeeded(for: MagicTestSupport.makeSnapshot(
            value: "Some draft", selectedRange: 4..<4
        )))
        // A non-empty range with no recovered text: this is the real case.
        #expect(MagicSelectionCapture.isNeeded(for: MagicTestSupport.makeSnapshot(
            value: "Some draft", selectedRange: 0..<4
        )))
        // Already recovered — nothing to do.
        #expect(!MagicSelectionCapture.isNeeded(for: MagicTestSupport.makeSnapshot(
            value: "Some draft",
            selection: .init(range: 0..<4, text: "Some"), selectedRange: 0..<4
        )))
        // Non-editable areas publish no range in many apps, and nothing is
        // ever pasted back into them, so the probe stays the fallback there.
        #expect(MagicSelectionCapture.isNeeded(for: MagicTestSupport.makeSnapshot(
            role: "AXStaticText", editable: false, value: "Page text"
        )))
        // Secure fields are never probed.
        #expect(!MagicSelectionCapture.isNeeded(for: MagicTestSupport.makeSnapshot(
            role: "AXSecureTextField", secure: true, value: "hunter2", selectedRange: 0..<7
        )))
    }
}

@Suite("Selection range re-encoding")
struct SelectionRangeEncodingTests {
    /// Snapshots store selections as character offsets (AXSnapshotService
    /// converts on the way in); `kAXSelectedTextRangeAttribute` speaks UTF-16
    /// in both directions. Restoring a dropped selection therefore has to
    /// translate back — handing AX the character numbers verbatim reselects a
    /// span shifted by every astral or composed character before it, and the
    /// paste that follows overwrites text the user never selected.
    @Test func reEncodesCharacterOffsetsAsUTF16() {
        // One emoji = one Character, two UTF-16 units.
        let emoji = MagicPressCoordinator.utf16Range(1..<3, in: "🙂ab")
        #expect(emoji?.location == 2)
        #expect(emoji?.length == 2)

        // A ZWJ family is still one Character, but eight UTF-16 units — the
        // worst case for treating the two as interchangeable.
        let family = MagicPressCoordinator.utf16Range(1..<3, in: "👩‍👩‍👦xy")
        #expect(family?.location == 8)
        #expect(family?.length == 2)

        // Decomposed "café": four Characters, five UTF-16 units.
        let composed = MagicPressCoordinator.utf16Range(5..<8, in: "cafe\u{301} bar")
        #expect(composed?.location == 6)
        #expect(composed?.length == 3)

        // Pure ASCII: the two spaces coincide, which is exactly why the bug
        // survived every hand test.
        let ascii = MagicPressCoordinator.utf16Range(4..<7, in: "the quick fox")
        #expect(ascii?.location == 4)
        #expect(ascii?.length == 3)
    }

    /// A range that no longer fits the field's current value describes text
    /// that is gone; the caller must fall back to the clipboard rather than
    /// select something arbitrary and paste over it.
    @Test func refusesRangesOutsideTheCurrentValue() {
        #expect(MagicPressCoordinator.utf16Range(5..<7, in: "🙂ab") == nil)
        #expect(MagicPressCoordinator.utf16Range(0..<4, in: "abc") == nil)
        #expect(MagicPressCoordinator.utf16Range(-1..<2, in: "abc") == nil)
        // An empty value is the "field was cleared while chips were up" case.
        #expect(MagicPressCoordinator.utf16Range(0..<1, in: "") == nil)
    }

    /// The two conversions are inverses: what the snapshot recorded is what
    /// gets reselected, span for span.
    @Test func roundTripsThroughTheSnapshotConversion() {
        let value = "🙂 hei Dana — kiitos"
        let original = 2..<9
        guard let encoded = MagicPressCoordinator.utf16Range(original, in: value) else {
            Issue.record("expected a UTF-16 range")
            return
        }
        #expect(AXSnapshotService.characterRange(encoded, in: value) == original)
    }
}
