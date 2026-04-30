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
    ]

    private let shortcutDidChangeNotification = Notification.Name("KeyboardShortcuts_shortcutByNameDidChange")
    private var shortcutChangeObserver: NSObjectProtocol?
    private var isRegistered = false

    var onTrigger: (() -> Void)?
    var onTriggerFromClipboard: (() -> Void)?
    var onTriggerBlankEditor: (() -> Void)?
    var onTriggerScreenCapture: (() -> Void)?
    var onTriggerOCRToClipboard: (() -> Void)?

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
