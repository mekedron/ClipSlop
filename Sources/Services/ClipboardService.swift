import AppKit

@MainActor
enum ClipboardService {
    static func getText() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    /// Read clipboard content based on the rich text processing mode.
    static func getTextForMode(_ mode: RichTextMode) -> String? {
        switch mode {
        case .plainText:
            return getText()
        case .html, .markdownAI:
            return getHTML() ?? getText()
        case .markdown:
            return getAsMarkdown() ?? getText()
        }
    }

    /// Check if clipboard contains rich text (HTML or RTF).
    static func hasRichText() -> Bool {
        let pb = NSPasteboard.general
        return pb.data(forType: .html) != nil || pb.data(forType: .rtf) != nil
    }

    /// Read raw HTML from clipboard.
    static func getHTML() -> String? {
        guard let htmlData = NSPasteboard.general.data(forType: .html),
              let htmlString = String(data: htmlData, encoding: .utf8)
        else { return nil }
        return htmlString
    }

    /// Read rich text from clipboard and convert to Markdown.
    private static func getAsMarkdown() -> String? {
        let pb = NSPasteboard.general

        // Try HTML first (Chrome, web apps put HTML on the pasteboard)
        if let htmlData = pb.data(forType: .html),
           let htmlString = String(data: htmlData, encoding: .utf8),
           let markdown = MarkdownConverter.markdown(fromHTML: htmlString),
           !markdown.isEmpty {
            return markdown
        }

        // Try RTF (Word, TextEdit, native apps)
        if let rtfData = pb.data(forType: .rtf),
           let attrStr = NSAttributedString(rtf: rtfData, documentAttributes: nil),
           attrStr.length > 0 {
            let markdown = MarkdownConverter.markdown(from: attrStr)
            if !markdown.isEmpty {
                return markdown
            }
        }

        return nil
    }

    static func setText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Copy HTML content — puts rendered HTML + plain text on pasteboard.
    static func setHTMLContent(_ html: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(html, forType: .string)
        if let htmlData = html.data(using: .utf8) {
            pb.setData(htmlData, forType: .html)
        }
    }

    static func setRichText(_ markdown: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(markdown, forType: .string)
        if let htmlData = MarkdownConverter.styledHTML(from: markdown).data(using: .utf8) {
            pb.setData(htmlData, forType: .html)
        }
        if let rtfData = MarkdownConverter.rtfData(from: markdown) {
            pb.setData(rtfData, forType: .rtf)
        }
    }

    static func simulatePaste() {
        // Small delay to let the popup dismiss first
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let source = CGEventSource(stateID: .combinedSessionState)
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true) // V key
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
            keyDown?.flags = .maskCommand
            keyUp?.flags = .maskCommand
            keyDown?.post(tap: .cghidEventTap)
            keyUp?.post(tap: .cghidEventTap)
        }
    }
}
