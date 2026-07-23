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

        menuButton(loc.t("menu.ocr_clipboard"), shortcut: .triggerOCRToClipboard) {
            appState.triggerOCRToClipboard()
        }

        menuButton(loc.t("menu.ocr"), shortcut: .triggerScreenCapture) {
            appState.triggerFromScreenCapture()
        }

        menuButton(loc.t("menu.quick_access"), shortcut: .triggerQuickAccess) {
            appState.showQuickAccess()
        }

        PromptShortcutsMenu(appState: appState, version: appState.promptShortcutsVersion)

        #if DEBUG
        Divider()
        // Dry-run (§17): capture + route + assemble for the focused field,
        // report to the clipboard, execute nothing.
        Button("Magic Dry-Run to Clipboard") {
            appState.magicCoordinator.dryRunToClipboard()
        }
        Button("Magic Trace Stats to Clipboard") {
            appState.magicCoordinator.traceStatsToClipboard()
        }
        // R1 spike: real inserter, canned string, no LLM call.
        Button("Magic Insert Test String") {
            appState.magicCoordinator.insertTestString()
        }
        #endif

        Divider()

        if let provider = appState.providerStore.defaultProvider {
            Text(loc.t("menu.provider", provider.name))
                .font(.caption)
            Text(loc.t("menu.model", provider.modelID))
                .font(.caption)
        }

        Divider()

        // The assistant sits next to Settings on purpose: it IS the
        // conversational way to change settings.
        menuButton(loc.t("menu.assistant"), shortcut: .toggleSettingsAssistant) {
            appState.showAssistant()
        }

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
    /// Human-readable shortcut string, e.g. "⌃⌘C".
    var displayString: String {
        var parts = ""
        if modifiers.contains(.control) { parts += "⌃" }
        if modifiers.contains(.option) { parts += "⌥" }
        if modifiers.contains(.shift) { parts += "⇧" }
        if modifiers.contains(.command) { parts += "⌘" }

        let keyMap: [Int: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 25: "9", 26: "7", 28: "8", 29: "0", 31: "O", 32: "U",
            34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 43: ",", 45: "N",
            46: "M", 24: "=", 27: "-", 30: "]", 33: "[", 39: "'", 41: ";",
            42: "\\", 44: "/", 47: ".",
            36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋",
            123: "←", 124: "→", 125: "↓", 126: "↑",
        ]
        parts += keyMap[carbonKeyCode] ?? "?"
        return parts
    }

    func swiftUIKeyEquivalent() -> KeyEquivalent? {
        let code = Int(carbonKeyCode)

        let charMap: [Int: Character] = [
            0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x",
            8: "c", 9: "v", 11: "b", 12: "q", 13: "w", 14: "e", 15: "r",
            16: "y", 17: "t", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 25: "9", 26: "7", 28: "8", 29: "0", 31: "o", 32: "u",
            34: "i", 35: "p", 37: "l", 38: "j", 40: "k", 43: ",", 45: "n",
            46: "m", 24: "=", 27: "-", 30: "]", 33: "[", 39: "'", 41: ";",
            42: "\\", 44: "/", 47: ".",
        ]
        if let char = charMap[code] {
            return KeyEquivalent(char)
        }

        let specialMap: [Int: KeyEquivalent] = [
            36: .return, 48: .tab, 49: .space, 51: .delete, 53: .escape,
            123: .leftArrow, 124: .rightArrow, 125: .downArrow, 126: .upArrow,
        ]
        return specialMap[code]
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
