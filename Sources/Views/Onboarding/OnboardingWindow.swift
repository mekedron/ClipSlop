import AppKit
import SwiftUI

final class OnboardingWindow: NSWindow {
    @MainActor
    init(appState: AppState) {
        let rootView = OnboardingView(appState: appState)
        let hostingView = NSHostingView(rootView: rootView)

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 600),
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
}
