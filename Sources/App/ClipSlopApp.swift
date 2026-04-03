import SwiftUI
import KeyboardShortcuts
import LaunchAtLogin

@main
struct ClipSlopApp: App {
    @State private var appState = AppState()
    @State private var menuBarVisible = !UserDefaults.standard.bool(forKey: "hideMenuBarIcon")
    @State private var didSetup = false

    var body: some Scene {
        MenuBarExtra("ClipSlop", systemImage: "doc.on.clipboard", isInserted: $menuBarVisible) {
            MenuBarView(appState: appState)
                .onAppear {
                    if !didSetup {
                        didSetup = true
                        appState.setup()
                        NSApplication.shared.setActivationPolicy(.accessory)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .menuBarVisibilityChanged)) { _ in
                    menuBarVisible = !UserDefaults.standard.bool(forKey: "hideMenuBarIcon")
                }
        }
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
