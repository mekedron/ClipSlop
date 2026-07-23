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

    @Test func panelGoesBelowTheAnchorWhenRoomExists() {
        let origin = CaretLocator.panelOrigin(
            anchor: NSRect(x: 100, y: 500, width: 10, height: 20),
            panelSize: NSSize(width: 300, height: 100),
            visibleFrame: NSRect(x: 0, y: 0, width: 1600, height: 900)
        )
        #expect(origin == NSPoint(x: 100, y: 392))  // 500 - 8 - 100
    }

    @Test func panelFlipsAboveWhenNoRoomBelow() {
        let origin = CaretLocator.panelOrigin(
            anchor: NSRect(x: 100, y: 40, width: 10, height: 20),
            panelSize: NSSize(width: 300, height: 100),
            visibleFrame: NSRect(x: 0, y: 0, width: 1600, height: 900)
        )
        #expect(origin.y == 68)  // anchor.maxY (60) + gap
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
}
