import AppKit
@preconcurrency import ApplicationServices

enum TextCaptureService {
    static func captureSelectedText() -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedElement: AnyObject?

        let appResult = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedApplicationAttribute as CFString,
            &focusedElement
        )
        guard appResult == .success, let app = focusedElement else { return nil }

        var focusedUI: AnyObject?
        let uiResult = AXUIElementCopyAttributeValue(
            app as! AXUIElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedUI
        )
        guard uiResult == .success, let element = focusedUI else { return nil }

        var selectedText: AnyObject?
        let textResult = AXUIElementCopyAttributeValue(
            element as! AXUIElement,
            kAXSelectedTextAttribute as CFString,
            &selectedText
        )
        guard textResult == .success, let text = selectedText as? String, !text.isEmpty else {
            return nil
        }
        return text
    }

    static func isAccessibilityEnabled() -> Bool {
        PermissionService.isAccessibilityGranted
    }

    static func requestAccessibility() {
        PermissionService.requestAccessibility()
    }
}
