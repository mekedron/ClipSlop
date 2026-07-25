import AppKit
import SwiftUI

/// Always-on-top floating chat window for the Settings Assistant.
///
/// Modeled on `PopupWindow` (titled, resizable, floating). Two deliberate
/// differences: `hidesOnDeactivate = false` so the window survives clicking
/// into other apps, and it does not auto-dismiss on losing key focus — the
/// whole point is to stay up while the user works elsewhere.
final class AssistantWindow: NSPanel, NSWindowDelegate {
    private let appState: AppState
    private var hasPositioned = false

    @MainActor
    init(appState: AppState) {
        self.appState = appState
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 580),
            styleMask: [.nonactivatingPanel, .titled, .closable, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )

        title = Loc.shared.t("assistant.window.title")
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = false
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        minSize = NSSize(width: 380, height: 420)
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        delegate = self
        setFrameAutosaveName("AssistantWindow")

        contentView = NSHostingView(rootView: AssistantChatView(appState: appState))
    }

    @MainActor
    func showAtCenter() {
        // Restore the saved frame the first time; only center when there's no
        // autosaved position yet.
        if !hasPositioned {
            hasPositioned = true
            if UserDefaults.standard.string(forKey: "NSWindow Frame AssistantWindow") == nil {
                centerOnMouseScreen()
            }
        }
        makeKeyAndOrderFront(nil)
        // See PopupWindow.showAtCenter for why activation is required for a
        // hotkey-summoned panel, and why dismissal must yield focus back
        // (AppState.dismissAssistant replicates that handoff).
        NSApplication.shared.activate()
        // Put the caret in the input on every open. The text view focuses
        // itself only when first created (`makeNSView`); on later shows the
        // view is reused, so we refocus here once the window is key.
        DispatchQueue.main.async { [weak self] in
            self?.focusInput()
        }
    }

    /// Makes the chat input the first responder so the user can type at once.
    @MainActor
    func focusInput() {
        guard let textView = Self.firstTextView(in: contentView) else { return }
        makeFirstResponder(textView)
    }

    private static func firstTextView(in view: NSView?) -> NSTextView? {
        guard let view else { return nil }
        if let textView = view as? NSTextView { return textView }
        for subview in view.subviews {
            if let found = firstTextView(in: subview) { return found }
        }
        return nil
    }

    private func centerOnMouseScreen() {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }
        let visible = screen.visibleFrame
        let x = visible.midX - frame.width / 2
        let y = visible.midY - frame.height / 2
        setFrameOrigin(NSPoint(x: x, y: y))
    }

    override func cancelOperation(_ sender: Any?) {
        Task { @MainActor in
            appState.dismissAssistant()
        }
    }

    func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            appState.assistantWindowWillClose()
        }
    }

    override var canBecomeKey: Bool { true }
}
