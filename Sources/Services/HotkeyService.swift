import KeyboardShortcuts

@MainActor
final class HotkeyService {
    var onTrigger: (() -> Void)?
    var onTriggerFromClipboard: (() -> Void)?
    var onTriggerCopyAndProcess: (() -> Void)?
    var onTriggerScreenCapture: (() -> Void)?

    func register() {
        KeyboardShortcuts.onKeyUp(for: .triggerClipSlop) { [weak self] in
            self?.onTrigger?()
        }
        KeyboardShortcuts.onKeyUp(for: .triggerFromClipboard) { [weak self] in
            self?.onTriggerFromClipboard?()
        }
        KeyboardShortcuts.onKeyUp(for: .triggerCopyAndProcess) { [weak self] in
            self?.onTriggerCopyAndProcess?()
        }
        KeyboardShortcuts.onKeyUp(for: .triggerScreenCapture) { [weak self] in
            self?.onTriggerScreenCapture?()
        }
    }

    func unregister() {
        KeyboardShortcuts.disable(.triggerClipSlop)
        KeyboardShortcuts.disable(.triggerFromClipboard)
        KeyboardShortcuts.disable(.triggerCopyAndProcess)
        KeyboardShortcuts.disable(.triggerScreenCapture)
    }
}
