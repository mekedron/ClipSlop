import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let triggerClipSlop = Self(
        "triggerClipSlop",
        default: .init(.c, modifiers: [.command, .control])
    )

    static let triggerFromClipboard = Self(
        "triggerFromClipboard",
        default: .init(.v, modifiers: [.command, .control])
    )

    static let triggerBlankEditor = Self(
        "triggerBlankEditor",
        default: .init(.n, modifiers: [.command, .control])
    )

    static let triggerScreenCapture = Self(
        "triggerScreenCapture",
        default: .init(.two, modifiers: [.command, .shift])
    )

    static let triggerOCRToClipboard = Self(
        "triggerOCRToClipboard",
        default: .init(.one, modifiers: [.command, .shift])
    )
}
