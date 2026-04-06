import AppKit

struct MnemonicModifiers: OptionSet, Codable, Hashable, Sendable {
    let rawValue: Int

    init(rawValue: Int) {
        self.rawValue = rawValue
    }

    static let shift   = MnemonicModifiers(rawValue: 1 << 0)
    static let control = MnemonicModifiers(rawValue: 1 << 1)
    static let option  = MnemonicModifiers(rawValue: 1 << 2)
    static let command = MnemonicModifiers(rawValue: 1 << 3)

    /// Build from NSEvent modifier flags (only includes the 4 supported modifiers).
    init(eventFlags: NSEvent.ModifierFlags) {
        var raw = 0
        if eventFlags.contains(.shift)   { raw |= MnemonicModifiers.shift.rawValue }
        if eventFlags.contains(.control)  { raw |= MnemonicModifiers.control.rawValue }
        if eventFlags.contains(.option)   { raw |= MnemonicModifiers.option.rawValue }
        if eventFlags.contains(.command)  { raw |= MnemonicModifiers.command.rawValue }
        self.rawValue = raw
    }

    /// Symbols for display, e.g. "⇧⌘" for shift+command.
    var symbolString: String {
        var s = ""
        if contains(.control) { s += "⌃" }
        if contains(.option)  { s += "⌥" }
        if contains(.shift)   { s += "⇧" }
        if contains(.command) { s += "⌘" }
        return s
    }
}

// MARK: - Key code → QWERTY character map

/// Maps a macOS virtual key code to its QWERTY letter/symbol.
/// Works regardless of the active keyboard layout.
func keyCodeToCharacter(_ keyCode: UInt16) -> String? {
    let map: [UInt16: String] = [
        0: "a",   1: "s",   2: "d",   3: "f",   4: "h",   5: "g",
        6: "z",   7: "x",   8: "c",   9: "v",  11: "b",  12: "q",
       13: "w",  14: "e",  15: "r",  16: "y",  17: "t",  18: "1",
       19: "2",  20: "3",  21: "4",  22: "6",  23: "5",  24: "=",
       25: "9",  26: "7",  27: "-",  28: "8",  29: "0",  30: "]",
       31: "o",  32: "u",  33: "[",  34: "i",  35: "p",  37: "l",
       38: "j",  39: "'",  40: "k",  41: ";",  42: "\\", 43: ",",
       44: "/",  45: "n",  46: "m",  47: ".",
    ]
    return map[keyCode]
}

// MARK: - Special key code → identifier map

/// Maps a macOS virtual key code to a special key identifier string.
/// Covers non-character keys: Delete, Tab, Enter, F1–F12, etc.
func keyCodeToIdentifier(_ keyCode: UInt16) -> String? {
    let map: [UInt16: String] = [
        51: "delete",        // Backspace / Delete
       117: "forwarddelete", // Forward Delete (Fn+Delete)
        48: "tab",
        36: "enter",         // Return
        76: "enter",         // Numpad Enter
       122: "f1",  120: "f2",   99: "f3",  118: "f4",
        96: "f5",   97: "f6",   98: "f7",  100: "f8",
       101: "f9",  109: "f10", 103: "f11", 111: "f12",
    ]
    return map[keyCode]
}

/// Returns a display symbol for a special key identifier, e.g. "delete" → "⌫".
func specialKeyDisplaySymbol(_ identifier: String) -> String? {
    let map: [String: String] = [
        "delete": "⌫",
        "forwarddelete": "⌦",
        "tab": "⇥",
        "enter": "↩",
        "f1": "F1",   "f2": "F2",   "f3": "F3",   "f4": "F4",
        "f5": "F5",   "f6": "F6",   "f7": "F7",   "f8": "F8",
        "f9": "F9",   "f10": "F10", "f11": "F11", "f12": "F12",
    ]
    return map[identifier]
}

/// Whether the given mnemonicKey is a special key identifier (multi-char, known).
func isSpecialKeyIdentifier(_ key: String) -> Bool {
    key.count > 1 && specialKeyDisplaySymbol(key) != nil
}
