import AppKit
import SwiftUI

/// A key capture field that intercepts any key press (including special keys like
/// Delete, Tab, Enter, F1–F12) and stores the result as a mnemonic identifier.
/// Pressing Escape clears the mnemonic.
struct MnemonicKeyCaptureView: NSViewRepresentable {
    @Binding var mnemonicKey: String
    var onChanged: () -> Void

    func makeNSView(context: Context) -> KeyCaptureNSView {
        let view = KeyCaptureNSView()
        view.mnemonicKey = mnemonicKey
        view.onKeyCapture = { newKey in
            mnemonicKey = newKey
            onChanged()
        }
        return view
    }

    func updateNSView(_ nsView: KeyCaptureNSView, context: Context) {
        nsView.mnemonicKey = mnemonicKey
        nsView.needsDisplay = true
    }
}

final class KeyCaptureNSView: NSView {
    var mnemonicKey = ""
    var onKeyCapture: ((String) -> Void)?

    private var isFocused = false

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { isFocused = true; needsDisplay = true }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { isFocused = false; needsDisplay = true }
        return result
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 120, height: 22)
    }

    // MARK: - Key Handling

    override func keyDown(with event: NSEvent) {
        let code = event.keyCode

        // Escape → clear mnemonic
        if code == 53 {
            mnemonicKey = ""
            onKeyCapture?("")
            window?.makeFirstResponder(nil)
            return
        }

        // Delete/Backspace → clear mnemonic (same as Escape)
        if code == 51 || code == 117 {
            mnemonicKey = ""
            onKeyCapture?("")
            window?.makeFirstResponder(nil)
            return
        }

        // Special key → store identifier
        if let identifier = keyCodeToIdentifier(code) {
            mnemonicKey = identifier
            onKeyCapture?(identifier)
            window?.makeFirstResponder(nil)
            return
        }

        // Regular character via keyCode map (layout-independent)
        if let char = keyCodeToCharacter(code) {
            mnemonicKey = char
            onKeyCapture?(char)
            window?.makeFirstResponder(nil)
            return
        }

        // Fallback: use event.characters
        if let chars = event.characters, let first = chars.first, !first.isNewline {
            let char = String(first).lowercased()
            mnemonicKey = char
            onKeyCapture?(char)
            window?.makeFirstResponder(nil)
            return
        }
    }

    // Prevent Tab from moving focus before keyDown fires
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isFocused else { return super.performKeyEquivalent(with: event) }
        let code = event.keyCode
        if code == 48 || code == 36 || code == 76 || keyCodeToIdentifier(code) != nil {
            keyDown(with: event)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // Click to focus
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)

        // Background
        if isFocused {
            NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
        } else {
            NSColor.controlBackgroundColor.setFill()
        }
        path.fill()

        // Border
        if isFocused {
            NSColor.controlAccentColor.withAlphaComponent(0.5).setStroke()
        } else {
            NSColor.separatorColor.setStroke()
        }
        path.lineWidth = 1
        path.stroke()

        // Text
        let displayText: String
        let textColor: NSColor

        if isFocused {
            displayText = NSLocalizedString("settings.prompts.editor.mnemonic_press_key", value: "Press a key...", comment: "")
            textColor = .secondaryLabelColor
        } else if mnemonicKey.isEmpty {
            displayText = NSLocalizedString("settings.prompts.editor.mnemonic_not_set", value: "Not set", comment: "")
            textColor = .tertiaryLabelColor
        } else if let symbol = specialKeyDisplaySymbol(mnemonicKey) {
            displayText = symbol
            textColor = .labelColor
        } else {
            displayText = mnemonicKey.uppercased()
            textColor = .labelColor
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: textColor,
        ]
        let size = (displayText as NSString).size(withAttributes: attrs)
        let point = NSPoint(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2
        )
        (displayText as NSString).draw(at: point, withAttributes: attrs)
    }
}
