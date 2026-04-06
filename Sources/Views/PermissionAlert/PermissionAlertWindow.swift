import AppKit
import SwiftUI

final class PermissionAlertWindow: NSWindow {
    @MainActor
    init(appState: AppState) {
        let rootView = PermissionAlertView(appState: appState)
        let hostingView = DragSafeHostingView(rootView: rootView)

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
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
