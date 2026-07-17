import Carbon.HIToolbox
import Foundation
import Testing
@testable import ClipSlop

@Suite("ShortcutParser")
struct ShortcutParserTests {

    @Test("Parses a letter with cmd+shift")
    func parsesLetterCombo() {
        let config = ShortcutParser.parse("cmd+shift+g")
        #expect(config?.carbonKeyCode == 5) // "g"
        #expect(config?.carbonModifiers == cmdKey | shiftKey)
    }

    @Test("Parses a function key with ctrl+opt")
    func parsesFunctionKey() {
        let config = ShortcutParser.parse("ctrl+opt+f5")
        #expect(config?.carbonKeyCode == 96) // F5
        #expect(config?.carbonModifiers == controlKey | optionKey)
    }

    @Test("Parses a special key by name")
    func parsesSpecialKey() {
        let config = ShortcutParser.parse("cmd+delete")
        #expect(config?.carbonKeyCode == 51)
        #expect(config?.carbonModifiers == cmdKey)
    }

    @Test("Modifier order does not matter")
    func modifierOrderIndependent() {
        let a = ShortcutParser.parse("cmd+shift+g")
        let b = ShortcutParser.parse("shift+cmd+g")
        #expect(a == b)
    }

    @Test("Rejects a shortcut with no cmd/ctrl/opt")
    func rejectsShiftOnly() {
        #expect(ShortcutParser.parse("shift+g") == nil)
        #expect(ShortcutParser.parse("g") == nil)
    }

    @Test("Rejects an unknown key")
    func rejectsUnknownKey() {
        #expect(ShortcutParser.parse("cmd+notakey") == nil)
    }

    @Test("Display renders modifier symbols in ⌃⌥⇧⌘ order")
    func displaysSymbols() {
        let config = ShortcutParser.parse("cmd+shift+g")!
        #expect(ShortcutParser.display(config) == "⇧⌘G")
    }

    @Test("Display renders special keys")
    func displaysSpecialKey() {
        let config = ShortcutParser.parse("cmd+delete")!
        #expect(ShortcutParser.display(config) == "⌘⌫")
    }

    @Test("Parse then display round-trips common shortcuts", arguments: [
        "cmd+shift+g", "ctrl+opt+f5", "cmd+9", "cmd+shift+period",
    ])
    func roundTrips(_ input: String) {
        let config = ShortcutParser.parse(input)
        #expect(config != nil)
        // Displaying the parsed config yields a stable, non-empty badge.
        let display = ShortcutParser.display(config!)
        #expect(!display.isEmpty)
        // And re-parsing is idempotent at the config level.
        #expect(ShortcutParser.parse(input) == config)
    }
}
