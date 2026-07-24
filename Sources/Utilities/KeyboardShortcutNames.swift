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

    /// The Settings Assistant window. The raw value keeps the pre-rename
    /// name — user-recorded shortcuts persist in UserDefaults under it, and
    /// changing it would silently drop them.
    static let toggleSettingsAssistant = Self(
        "togglePromptAssistant",
        default: .init(.p, modifiers: [.command, .control, .option])
    )

    static let triggerMagic = Self(
        "triggerMagic",
        default: .init(.m, modifiers: [.command, .control])
    )

    /// Bare Escape, armed ONLY while a Magic overlay (chip panel or toast)
    /// is on screen — the coordinator enables/disables it around their
    /// lifetime. A Carbon hotkey consumes the event, so the page under the
    /// overlay never loses focus or closes its own dialogs on the Escape
    /// that dismissed ours. Never shown in Settings, not user-recordable.
    static let dismissMagicOverlay = Self(
        "dismissMagicOverlay",
        default: .init(.escape)
    )

    /// ⌘↩, armed ONLY while the toast shows the hold-to-insert affordance
    /// (verifier warnings pending) — the keyboard equivalent of the hold.
    /// Never shown in Settings, not user-recordable.
    static let confirmMagicInsert = Self(
        "confirmMagicInsert",
        default: .init(.return, modifiers: [.command])
    )

    /// Modifier variant that always shows the chip panel (§3.3 override).
    static let triggerMagicChips = Self(
        "triggerMagicChips",
        default: .init(.m, modifiers: [.command, .control, .shift])
    )
}
