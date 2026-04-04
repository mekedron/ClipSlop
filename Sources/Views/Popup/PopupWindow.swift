import AppKit
import SwiftUI

final class PopupWindow: NSPanel {
    private let appState: AppState

    @MainActor
    init(appState: AppState) {
        self.appState = appState

        let w = appState.settings.popupWidth
        let h = appState.settings.popupHeight

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: w, height: h),
            styleMask: [.nonactivatingPanel, .titled, .closable, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )

        title = "ClipSlop"
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        minSize = NSSize(width: 500, height: 350)

        let hostingView = NSHostingView(rootView: PopupContentView(appState: appState))
        contentView = hostingView
    }

    @MainActor
    func showAtCenter() {
        // Use the screen where the mouse cursor is, not NSScreen.main
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }

        let screenFrame = screen.visibleFrame
        let windowFrame = frame
        let x = screenFrame.midX - windowFrame.width / 2
        let y = screenFrame.midY - windowFrame.height / 2
        setFrameOrigin(NSPoint(x: x, y: y))
        makeKeyAndOrderFront(nil)
    }

    override func cancelOperation(_ sender: Any?) {
        Task { @MainActor in
            appState.dismissPopup()
        }
    }

    override var canBecomeKey: Bool { true }
}
