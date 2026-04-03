import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let triggerClipSlop = Self(
        "triggerClipSlop",
        default: .init(.v, modifiers: [.command, .shift])
    )

    static let triggerFromClipboard = Self(
        "triggerFromClipboard",
        default: .init(.v, modifiers: [.command, .option])
    )

    static let triggerCopyAndProcess = Self(
        "triggerCopyAndProcess",
        default: .init(.c, modifiers: [.command, .control])
    )

    static let triggerScreenCapture = Self(
        "triggerScreenCapture",
        default: .init(.two, modifiers: [.command, .shift])
    )
}
