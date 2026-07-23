import Foundation
import KeyboardShortcuts

@MainActor
final class HotkeyService {
    private static let shortcutNames: [KeyboardShortcuts.Name] = [
        .triggerClipSlop,
        .triggerFromClipboard,
        .triggerBlankEditor,
        .triggerScreenCapture,
        .triggerOCRToClipboard,
        .triggerQuickAccess,
        .toggleSettingsAssistant,
        .triggerMagic,
        .triggerMagicChips,
        .dismissMagicOverlay,
        .confirmMagicInsert,
    ]

    private let shortcutDidChangeNotification = Notification.Name("KeyboardShortcuts_shortcutByNameDidChange")
    private var shortcutChangeObserver: NSObjectProtocol?
    private var isRegistered = false

    var onTrigger: (() -> Void)?
    var onTriggerFromClipboard: (() -> Void)?
    var onTriggerBlankEditor: (() -> Void)?
    var onTriggerScreenCapture: (() -> Void)?
    var onTriggerOCRToClipboard: (() -> Void)?
    var onTriggerQuickAccess: (() -> Void)?
    var onTriggerPromptAssistant: (() -> Void)?
    var onTriggerMagic: (() -> Void)?
    var onTriggerMagicChips: (() -> Void)?
    var onDismissMagicOverlay: (() -> Void)?
    var onConfirmMagicInsert: (() -> Void)?

    func register() {
        registerHandlers()
        startObservingShortcutChanges()
    }

    func unregister() {
        unregisterHandlers()
        stopObservingShortcutChanges()
    }

    private func registerHandlers() {
        unregisterHandlers()

        KeyboardShortcuts.onKeyUp(for: .triggerClipSlop) { [weak self] in
            self?.onTrigger?()
        }
        KeyboardShortcuts.onKeyUp(for: .triggerFromClipboard) { [weak self] in
            self?.onTriggerFromClipboard?()
        }
        KeyboardShortcuts.onKeyUp(for: .triggerBlankEditor) { [weak self] in
            self?.onTriggerBlankEditor?()
        }
        KeyboardShortcuts.onKeyUp(for: .triggerScreenCapture) { [weak self] in
            self?.onTriggerScreenCapture?()
        }
        KeyboardShortcuts.onKeyUp(for: .triggerOCRToClipboard) { [weak self] in
            self?.onTriggerOCRToClipboard?()
        }
        KeyboardShortcuts.onKeyUp(for: .triggerQuickAccess) { [weak self] in
            self?.onTriggerQuickAccess?()
        }
        KeyboardShortcuts.onKeyUp(for: .toggleSettingsAssistant) { [weak self] in
            self?.onTriggerPromptAssistant?()
        }
        KeyboardShortcuts.onKeyUp(for: .triggerMagic) { [weak self] in
            self?.onTriggerMagic?()
        }
        KeyboardShortcuts.onKeyUp(for: .triggerMagicChips) { [weak self] in
            self?.onTriggerMagicChips?()
        }
        KeyboardShortcuts.onKeyDown(for: .dismissMagicOverlay) { [weak self] in
            self?.onDismissMagicOverlay?()
        }
        // On key UP: the synthetic ⌘V that follows must not race the user's
        // still-held Return.
        KeyboardShortcuts.onKeyUp(for: .confirmMagicInsert) { [weak self] in
            self?.onConfirmMagicInsert?()
        }
        // Registering a handler arms the hotkey, and neither bare Escape nor
        // ⌘↩ may be armed while no Magic overlay is up — the coordinator
        // enables each around its overlay's lifetime. (If handlers are
        // re-registered while an overlay happens to be visible, that overlay
        // loses its key — rare enough to accept.)
        KeyboardShortcuts.disable(.dismissMagicOverlay)
        KeyboardShortcuts.disable(.confirmMagicInsert)

        isRegistered = true
    }

    private func unregisterHandlers() {
        for name in Self.shortcutNames {
            KeyboardShortcuts.removeHandler(for: name)
        }
        isRegistered = false
    }

    private func startObservingShortcutChanges() {
        guard shortcutChangeObserver == nil else { return }

        shortcutChangeObserver = NotificationCenter.default.addObserver(
            forName: shortcutDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshHandlers()
            }
        }
    }

    private func stopObservingShortcutChanges() {
        if let shortcutChangeObserver {
            NotificationCenter.default.removeObserver(shortcutChangeObserver)
            self.shortcutChangeObserver = nil
        }
    }

    private func refreshHandlers() {
        guard isRegistered else { return }
        registerHandlers()
    }
}
