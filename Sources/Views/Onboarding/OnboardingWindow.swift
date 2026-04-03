import AppKit
import SwiftUI

final class OnboardingWindow: NSWindow {
    @MainActor
    init(appState: AppState) {
        let rootView = OnboardingView(appState: appState)
        let hostingView = DragSafeHostingView(rootView: rootView)

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 720),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        level = .floating
        contentView = hostingView

        center()
    }

    /// Slide window to the left so system dialogs are not covered.
    func moveAside() {
        guard let screen = screen ?? NSScreen.main else { return }
        var frame = self.frame
        frame.origin.x = screen.visibleFrame.minX + 20
        setFrame(frame, display: true, animate: true)
    }
}

/// An NSHostingView that disables window dragging when the mouse is over
/// interactive controls (buttons, text fields, sliders, pickers, etc.).
final class DragSafeHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if let hit, isInteractiveControl(hit) {
            window?.isMovableByWindowBackground = false
        } else {
            window?.isMovableByWindowBackground = true
        }
        return hit
    }

    private func isInteractiveControl(_ view: NSView) -> Bool {
        var current: NSView? = view
        for _ in 0..<6 {
            guard let v = current else { break }
            if v is NSButton || v is NSTextField || v is NSSlider
                || v is NSSegmentedControl || v is NSPopUpButton
                || v is NSSecureTextField || v is NSStepper {
                return true
            }
            current = v.superview
        }
        return false
    }
}
