import KeyboardShortcuts

@MainActor
final class HotkeyService {
    var onTrigger: (() -> Void)?
    var onTriggerFromClipboard: (() -> Void)?
    var onTriggerBlankEditor: (() -> Void)?
    var onTriggerScreenCapture: (() -> Void)?

    func register() {
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
    }

    func unregister() {
        KeyboardShortcuts.disable(.triggerClipSlop)
        KeyboardShortcuts.disable(.triggerFromClipboard)
        KeyboardShortcuts.disable(.triggerBlankEditor)
        KeyboardShortcuts.disable(.triggerScreenCapture)
    }
}
