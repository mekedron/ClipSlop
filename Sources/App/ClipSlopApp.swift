import SwiftUI
import KeyboardShortcuts
import LaunchAtLogin

@main
struct ClipSlopApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra("ClipSlop", systemImage: "doc.on.clipboard") {
            MenuBarView(appState: appState)
                .onAppear {
                    appState.setup()
                }
        }

        Settings {
            SettingsView(appState: appState)
        }
    }

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }
}
