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
                .task {
                    guard !didSetup else { return }
                    didSetup = true
                    NSApplication.shared.setActivationPolicy(.accessory)
                    appState.setup()
                }
                .onReceive(NotificationCenter.default.publisher(for: .menuBarVisibilityChanged)) { _ in
                    menuBarVisible = !UserDefaults.standard.bool(forKey: "hideMenuBarIcon")
                }
        }
    }
}

extension Notification.Name {
    static let clipSlopOpenSettings = Notification.Name("clipSlopOpenSettings")
    static let menuBarVisibilityChanged = Notification.Name("menuBarVisibilityChanged")
}
