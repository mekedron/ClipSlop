import AppKit
import WebKit

/// Unified interface for detecting, copying, and clearing text selections
/// across all view types (NSTextView, WKWebView, Textual's NSTextInteractionView).
enum SelectionService {

    /// Whether the given (or current key) window's first responder has a non-empty text selection.
    static func hasSelection(in window: NSWindow? = nil) -> Bool {
        guard let responder = resolveResponder(in: window) else { return false }
        return checkSelection(responder)
    }

    /// Convenience property using the current key window.
    static var hasSelection: Bool { hasSelection() }

    /// Copies the current selection via the responder chain.
    /// Returns `true` if a selection was copied, `false` if there was nothing to copy.
    @discardableResult
    static func copySelection(in window: NSWindow? = nil) -> Bool {
        guard hasSelection(in: window) else { return false }
        NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
        return true
    }

    /// Clears the current text selection.
    /// Returns `true` if a selection was cleared, `false` if there was nothing to clear.
    @discardableResult
    static func clearSelection(in window: NSWindow? = nil) -> Bool {
        guard let responder = resolveResponder(in: window),
              checkSelection(responder) else { return false }

        // NSTextView: zero-length selection
        if let textView = responder as? NSTextView {
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            return true
        }

        // Textual's NSTextInteractionView: nil out selectedRange on the model
        if isTextInteractionView(responder) {
            return clearTextualSelection(responder)
        }

        // WKWebView: clear selection via JavaScript
        if let webView = findWebView(from: responder) {
            webView.evaluateJavaScript("window.getSelection().removeAllRanges()")
            return true
        }

        return false
    }

    // MARK: - Private

    /// Find the first responder, trying the given window first, then keyWindow, then any visible window.
    private static func resolveResponder(in window: NSWindow?) -> NSView? {
        if let r = window?.firstResponder as? NSView { return r }
        if let r = NSApp.keyWindow?.firstResponder as? NSView { return r }
        for w in NSApp.orderedWindows where w.isVisible {
            if let r = w.firstResponder as? NSView { return r }
        }
        return nil
    }

    private static func checkSelection(_ responder: NSView) -> Bool {
        if let textView = responder as? NSTextView {
            return textView.selectedRange().length > 0
        }
        if responder.responds(to: #selector(NSText.copy(_:))),
           let validator = responder as? NSUserInterfaceValidations {
            let probe = NSMenuItem(title: "", action: #selector(NSText.copy(_:)), keyEquivalent: "")
            return validator.validateUserInterfaceItem(probe)
        }
        return false
    }

    private static func isTextInteractionView(_ view: NSView) -> Bool {
        String(describing: type(of: view)).contains("TextInteractionView")
    }

    /// Clear selection in Textual's NSTextInteractionView by writing nil to
    /// model.selectedRange via ObjC runtime ivar access.
    /// Both TextSelectionModel and TextRange are plain Swift classes (not NSObject),
    /// so KVC cannot be used — direct ivar manipulation is required.
    /// Clear Textual selection by sending a synthetic mouse click, which triggers
    /// NSTextInteractionView's own resetSelection() through the proper @Observable path.
    private static func clearTextualSelection(_ view: NSView) -> Bool {
        guard let window = view.window else { return false }
        let locationInWindow = view.convert(CGPoint(x: 1, y: 1), to: nil)
        guard let down = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: locationInWindow,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        ) else { return false }
        view.mouseDown(with: down)
        return true
    }

    private static func findWebView(from responder: NSResponder) -> WKWebView? {
        var current = responder as? NSView
        while let view = current {
            if let webView = view as? WKWebView { return webView }
            current = view.superview
        }
        return nil
    }
}
