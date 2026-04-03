import SwiftUI
import KeyboardShortcuts
import LaunchAtLogin

@main
struct ClipSlopApp: App {
    @State private var appState = AppState()
    @State private var menuBarVisible = true

    var body: some Scene {
        MenuBarExtra("ClipSlop", systemImage: "doc.on.clipboard", isInserted: $menuBarVisible) {
            MenuBarView(appState: appState)
        }
    }

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)

        // Read initial value directly from UserDefaults (not @Observable)
        _menuBarVisible = State(initialValue: !UserDefaults.standard.bool(forKey: "hideMenuBarIcon"))

        // Setup hotkeys on next run loop
        DispatchQueue.main.async { [self] in
            appState.setup()
        }

        // Watch for hide menu bar changes
        NotificationCenter.default.addObserver(
            forName: .menuBarVisibilityChanged,
            object: nil,
            queue: .main
        ) { [self] _ in
            menuBarVisible = !UserDefaults.standard.bool(forKey: "hideMenuBarIcon")
        }

        // Handle app reopen
        NSAppleEventManager.shared().setEventHandler(
            ReopenHandler.shared,
            andSelector: #selector(ReopenHandler.handleReopen(_:withReply:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEReopenApplication)
        )
    }
}

final class ReopenHandler: NSObject, @unchecked Sendable {
    static let shared = ReopenHandler()

    @objc func handleReopen(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        NotificationCenter.default.post(name: .clipSlopOpenSettings, object: nil)
    }
}

extension Notification.Name {
    static let clipSlopOpenSettings = Notification.Name("clipSlopOpenSettings")
    static let menuBarVisibilityChanged = Notification.Name("menuBarVisibilityChanged")
}
