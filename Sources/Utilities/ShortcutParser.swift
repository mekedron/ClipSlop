import Carbon.HIToolbox
import Foundation

/// Converts between human-readable shortcut strings ("cmd+shift+g") and the
/// Carbon key-code/modifier form stored in `ShortcutConfig`. Lets the prompt
/// assistant specify shortcuts as plain text that we validate app-side.
///
/// Key codes reuse the layout-independent maps in `MnemonicModifiers.swift`
/// (`keyCodeToCharacter` / `keyCodeToIdentifier`); modifiers use the Carbon
/// masks that `KeyboardShortcuts.Shortcut(carbonKeyCode:carbonModifiers:)`
/// expects.
enum ShortcutParser {

    /// Parses "cmd+shift+g", "ctrl+opt+f5", "cmd+delete", etc. Returns `nil`
    /// for anything unparseable or missing a Command/Control/Option modifier
    /// (a global hotkey needs at least one — Shift alone won't register).
    static func parse(_ string: String) -> ShortcutConfig? {
        let tokens = string
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }

        var modifiers = 0
        var keyToken: String?

        for token in tokens {
            switch token {
            case "cmd", "command", "meta", "super", "win":
                modifiers |= cmdKey
            case "shift":
                modifiers |= shiftKey
            case "ctrl", "control":
                modifiers |= controlKey
            case "opt", "option", "alt":
                modifiers |= optionKey
            default:
                // Only one non-modifier key is allowed.
                if keyToken != nil { return nil }
                keyToken = token
            }
        }

        guard let keyToken else { return nil }

        let hasNonShiftModifier = (modifiers & (cmdKey | controlKey | optionKey)) != 0
        guard hasNonShiftModifier else { return nil }

        guard let keyCode = keyCode(for: keyToken) else { return nil }
        return ShortcutConfig(carbonKeyCode: keyCode, carbonModifiers: modifiers)
    }

    /// Renders a `ShortcutConfig` as "⌘⇧G" for display in proposal cards.
    static func display(_ config: ShortcutConfig) -> String {
        var result = ""
        if config.carbonModifiers & controlKey != 0 { result += "⌃" }
        if config.carbonModifiers & optionKey != 0 { result += "⌥" }
        if config.carbonModifiers & shiftKey != 0 { result += "⇧" }
        if config.carbonModifiers & cmdKey != 0 { result += "⌘" }

        let code = UInt16(config.carbonKeyCode)
        if let identifier = keyCodeToIdentifier(code),
           let symbol = specialKeyDisplaySymbol(identifier) {
            result += symbol
        } else if let character = keyCodeToCharacter(code) {
            result += character.uppercased()
        } else {
            result += "?"
        }
        return result
    }

    // MARK: - Key lookup

    private static func keyCode(for token: String) -> Int? {
        if let code = characterToKeyCode[token] { return code }
        if let code = identifierToKeyCode[token] { return code }
        if let code = aliasToKeyCode[token] { return code }
        return nil
    }

    /// Inverse of `keyCodeToCharacter` — "g" → 5, "9" → 25, "/" → 44, …
    private static let characterToKeyCode: [String: Int] = {
        var map: [String: Int] = [:]
        for code in UInt16(0)...127 {
            if let character = keyCodeToCharacter(code) {
                map[character] = Int(code)
            }
        }
        return map
    }()

    /// Inverse of `keyCodeToIdentifier` — "delete" → 51, "tab" → 48, "f5" → 96, …
    private static let identifierToKeyCode: [String: Int] = {
        var map: [String: Int] = [:]
        for code in UInt16(0)...127 {
            if let identifier = keyCodeToIdentifier(code), map[identifier] == nil {
                map[identifier] = Int(code)
            }
        }
        map["space"] = 49
        return map
    }()

    /// Friendly names for keys that aren't in the character/identifier maps.
    private static let aliasToKeyCode: [String: Int] = [
        "return": 36,
        "esc": 53, "escape": 53,
        "spacebar": 49,
        "backspace": 51, "del": 51,
        "comma": 43,
        "period": 47, "dot": 47,
        "slash": 44,
        "minus": 27, "hyphen": 27, "dash": 27,
        "equal": 24, "equals": 24, "plus": 24,
        "semicolon": 41,
        "quote": 39,
        "backslash": 42,
        "leftbracket": 33, "rightbracket": 30,
        "grave": 50, "backtick": 50,
    ]
}
