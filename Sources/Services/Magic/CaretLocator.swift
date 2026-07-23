import AppKit
@preconcurrency import ApplicationServices

/// Screen anchoring for the chip panel and toast (R2): caret bounds when the
/// app exposes them, field bounds otherwise, mouse position as the last
/// resort. AX reports global *top-left-origin* coordinates; AppKit windows
/// use bottom-left — the flip is against the primary screen's height.
@MainActor
enum CaretLocator {
    static func anchorRect(for snapshot: MagicSnapshot) -> NSRect {
        if let element = snapshot.focusedElement?.element {
            if let caret = caretBounds(of: element, snapshot: snapshot) { return caret }
            if let field = elementBounds(of: element) { return field }
        }
        let mouse = NSEvent.mouseLocation
        return NSRect(x: mouse.x, y: mouse.y, width: 1, height: 1)
    }

    /// Places a panel just below the anchor, clamped to the screen holding
    /// it. Pure geometry, extracted for tests.
    nonisolated static func panelOrigin(
        anchor: NSRect,
        panelSize: NSSize,
        visibleFrame: NSRect,
        gap: CGFloat = 8
    ) -> NSPoint {
        var x = anchor.minX
        var y = anchor.minY - gap - panelSize.height  // below the anchor
        if y < visibleFrame.minY {
            y = anchor.maxY + gap  // no room below → above
        }
        x = max(visibleFrame.minX, min(x, visibleFrame.maxX - panelSize.width))
        y = max(visibleFrame.minY, min(y, visibleFrame.maxY - panelSize.height))
        return NSPoint(x: x, y: y)
    }

    static func screenFor(anchor: NSRect) -> NSScreen? {
        NSScreen.screens.first { $0.frame.intersects(anchor) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    // MARK: - AX geometry

    /// `AXBoundsForRange` for the selection (or caret). Chromium frequently
    /// returns nothing here (R2) — callers fall through to field bounds.
    private static func caretBounds(of element: AXUIElement, snapshot: MagicSnapshot) -> NSRect? {
        var location = 0
        var length = 0
        if let range = snapshot.field?.selection?.range {
            location = range.lowerBound
            length = max(1, range.count)
        } else {
            var rangeRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                element, kAXSelectedTextRangeAttribute as CFString, &rangeRef
            ) == .success, let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID() else { return nil }
            var cfRange = CFRange()
            guard AXValueGetValue((rangeRef as! AXValue), .cfRange, &cfRange) else { return nil }
            location = cfRange.location
            length = max(1, cfRange.length)
        }

        var cfRange = CFRange(location: location, length: length)
        guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var boundsRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, rangeValue, &boundsRef
        ) == .success, let boundsRef, CFGetTypeID(boundsRef) == AXValueGetTypeID() else { return nil }

        var rect = CGRect.zero
        guard AXValueGetValue((boundsRef as! AXValue), .cgRect, &rect), rect.width >= 0, rect.height > 0 else {
            return nil
        }
        return flipToAppKit(rect)
    }

    private static func elementBounds(of element: AXUIElement) -> NSRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionRef, let sizeRef,
              CFGetTypeID(positionRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID()
        else { return nil }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue((positionRef as! AXValue), .cgPoint, &position),
              AXValueGetValue((sizeRef as! AXValue), .cgSize, &size),
              size.width > 0, size.height > 0
        else { return nil }
        return flipToAppKit(CGRect(origin: position, size: size))
    }

    /// Global top-left AX coordinates → AppKit bottom-left, flipped against
    /// the primary screen (the classic AX coordinate bug lives here).
    nonisolated static func flipToAppKit(_ axRect: CGRect, primaryScreenHeight: CGFloat? = nil) -> NSRect {
        let height = primaryScreenHeight ?? primaryHeight
        return NSRect(
            x: axRect.origin.x,
            y: height - axRect.origin.y - axRect.height,
            width: axRect.width,
            height: axRect.height
        )
    }

    private nonisolated static var primaryHeight: CGFloat {
        // Screens' AppKit coordinate space is anchored to the primary
        // screen's frame (origin 0,0, positive Y up).
        NSScreen.screens.first?.frame.maxY ?? 0
    }
}
