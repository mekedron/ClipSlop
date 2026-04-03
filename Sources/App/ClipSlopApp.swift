import SwiftUI
import KeyboardShortcuts
import LaunchAtLogin
import Sparkle

@main
struct ClipSlopApp: App {
    @State private var appState = AppState()
    @State private var updater = SparkleUpdater()
    @State private var menuBarVisible = !UserDefaults.standard.bool(forKey: "hideMenuBarIcon")
    @State private var didSetup = false

    var body: some Scene {
        MenuBarExtra("ClipSlop", systemImage: "doc.on.clipboard", isInserted: $menuBarVisible) {
            MenuBarView(appState: appState, updater: updater)
                .task {
                    guard !didSetup else { return }
                    didSetup = true
                    NSApplication.shared.setActivationPolicy(.accessory)
                    switch appState.settings.appColorScheme {
                    case .system: NSApp.appearance = nil
                    case .light: NSApp.appearance = NSAppearance(named: .aqua)
                    case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
                    }
                    updater.start()
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
