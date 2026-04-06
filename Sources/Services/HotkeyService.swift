import KeyboardShortcuts

@MainActor
final class HotkeyService {
    var onTrigger: (() -> Void)?
    var onTriggerFromClipboard: (() -> Void)?
    var onTriggerBlankEditor: (() -> Void)?
    var onTriggerScreenCapture: (() -> Void)?
    var onTriggerOCRToClipboard: (() -> Void)?

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
        KeyboardShortcuts.onKeyUp(for: .triggerOCRToClipboard) { [weak self] in
            self?.onTriggerOCRToClipboard?()
        }
    }

    func unregister() {
        KeyboardShortcuts.disable(.triggerClipSlop)
        KeyboardShortcuts.disable(.triggerFromClipboard)
        KeyboardShortcuts.disable(.triggerBlankEditor)
        KeyboardShortcuts.disable(.triggerScreenCapture)
        KeyboardShortcuts.disable(.triggerOCRToClipboard)
    }
}
