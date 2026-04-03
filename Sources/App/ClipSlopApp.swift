import SwiftUI
import KeyboardShortcuts
import LaunchAtLogin

@main
struct ClipSlopApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra(
            "ClipSlop",
            systemImage: "doc.on.clipboard",
            isInserted: Binding(
                get: { !appState.settings.hideMenuBarIcon },
                set: { appState.settings.hideMenuBarIcon = !$0 }
            )
        ) {
            MenuBarView(appState: appState)
        }
    }

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)

        DispatchQueue.main.async { [self] in
            appState.setup()
        }

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
}
