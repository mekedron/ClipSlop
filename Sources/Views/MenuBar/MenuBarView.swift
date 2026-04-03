import SwiftUI
import KeyboardShortcuts

struct MenuBarView: View {
    let appState: AppState

    var body: some View {
        Button("Trigger ClipSlop") {
            appState.triggerFromSelection()
        }
        .keyboardShortcut("v", modifiers: [.command, .shift])

        Button("Copy & Process") {
            appState.triggerCopyAndProcess()
        }

        Button("From Clipboard") {
            appState.triggerFromClipboard()
        }

        Button("Screen Capture (OCR)") {
            appState.triggerFromScreenCapture()
        }

        Divider()

        if let provider = appState.providerStore.defaultProvider {
            Text("Provider: \(provider.name)")
                .font(.caption)
            Text("Model: \(provider.modelID)")
                .font(.caption)
        }

        Divider()

        SettingsLink {
            Text("Settings...")
        }

        Button("Show Onboarding...") {
            appState.showOnboarding()
        }

        Divider()

        Button("Quit ClipSlop") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
