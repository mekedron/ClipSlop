import SwiftUI
import KeyboardShortcuts

struct MenuBarView: View {
    let appState: AppState
    let updater: SparkleUpdater
    private let loc = Loc.shared

    var body: some View {
        menuButton(loc.t("menu.trigger"), shortcut: .triggerClipSlop) {
            appState.triggerFromSelection()
        }

        menuButton(loc.t("menu.clipboard"), shortcut: .triggerFromClipboard) {
            appState.triggerFromClipboard()
        }

        menuButton(loc.t("menu.blank"), shortcut: .triggerBlankEditor) {
            appState.triggerBlankEditor()
        }

        menuButton(loc.t("menu.ocr"), shortcut: .triggerScreenCapture) {
            appState.triggerFromScreenCapture()
        }

        Divider()

        if let provider = appState.providerStore.defaultProvider {
            Text(loc.t("menu.provider", provider.name))
                .font(.caption)
            Text(loc.t("menu.model", provider.modelID))
                .font(.caption)
        }

        Divider()

        Button(loc.t("menu.settings")) {
            appState.openSettings()
        }
        .keyboardShortcut(",", modifiers: .command)

        Button(loc.t("menu.onboarding")) {
            appState.showOnboarding()
        }

        Divider()

        Button(loc.t("menu.coffee")) {
            NSWorkspace.shared.open(URL(string: "https://buymeacoffee.com/mekedron")!)
        }

        Button(loc.t("menu.updates")) {
            updater.checkForUpdates()
        }

        Button(loc.t("menu.about")) {
            appState.showAbout()
        }

        Divider()

        Button(loc.t("menu.quit")) {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    @ViewBuilder
    private func menuButton(
        _ title: String,
        shortcut name: KeyboardShortcuts.Name,
        action: @escaping () -> Void
    ) -> some View {
        if let shortcut = KeyboardShortcuts.getShortcut(for: name),
           let keyEq = shortcut.swiftUIKeyEquivalent() {
            Button(title, action: action)
                .keyboardShortcut(keyEq, modifiers: shortcut.swiftUIModifiers())
        } else {
            Button(title, action: action)
        }
    }
}

// MARK: - KeyboardShortcuts.Shortcut → SwiftUI conversion

extension KeyboardShortcuts.Shortcut {
    func swiftUIKeyEquivalent() -> KeyEquivalent? {
        let code = carbonKeyCode

        let map: [Int: Character] = [
            0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x",
            8: "c", 9: "v", 11: "b", 12: "q", 13: "w", 14: "e", 15: "r",
            16: "y", 17: "t", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 25: "9", 26: "7", 28: "8", 29: "0", 31: "o", 32: "u",
            34: "i", 35: "p", 37: "l", 38: "j", 40: "k", 43: ",", 45: "n",
            46: "m", 24: "=", 27: "-", 30: "]", 33: "[", 39: "'", 41: ";",
            42: "\\", 44: "/", 47: ".",
        ]

        guard let char = map[Int(code)] else { return nil }
        return KeyEquivalent(char)
    }

    func swiftUIModifiers() -> SwiftUI.EventModifiers {
        var result: SwiftUI.EventModifiers = []
        if modifiers.contains(.command) { result.insert(.command) }
        if modifiers.contains(.option) { result.insert(.option) }
        if modifiers.contains(.control) { result.insert(.control) }
        if modifiers.contains(.shift) { result.insert(.shift) }
        return result
    }
}
