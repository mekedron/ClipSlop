import SwiftUI
import KeyboardShortcuts
import LaunchAtLogin
import Sparkle

@main
struct ClipSlopApp: App {
    @State private var appState: AppState
    @State private var updater: SparkleUpdater
    @State private var menuBarVisible: Bool

    init() {
        // Must run BEFORE AppState/AppSettings touch UserDefaults or Keychain.
        V1MigrationService.runSynchronousMigration()

        let state = AppState()
        let upd = SparkleUpdater()
        _appState = State(wrappedValue: state)
        _updater = State(wrappedValue: upd)
        _menuBarVisible = State(wrappedValue: !UserDefaults.standard.bool(forKey: "hideMenuBarIcon"))

        NSApplication.shared.setActivationPolicy(.accessory)
        switch state.settings.appColorScheme {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        upd.start()
        state.setup()

        Task.detached(priority: .utility) {
            await V1MigrationService.runICloudMigration()
        }
    }

    var body: some Scene {
        MenuBarExtra("ClipSlop", systemImage: "doc.on.clipboard", isInserted: $menuBarVisible) {
            MenuBarView(appState: appState, updater: updater)
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
