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

    static let triggerQuickAccess = Self(
        "triggerQuickAccess",
        default: .init(.space, modifiers: [.option, .shift])
    )

    static let togglePromptAssistant = Self(
        "togglePromptAssistant",
        default: .init(.p, modifiers: [.command, .control, .option])
    )

    static let triggerMagic = Self(
        "triggerMagic",
        default: .init(.m, modifiers: [.command, .control])
    )

    /// Modifier variant that always shows the chip panel (§3.3 override).
    static let triggerMagicChips = Self(
        "triggerMagicChips",
        default: .init(.m, modifiers: [.command, .control, .shift])
    )
}
