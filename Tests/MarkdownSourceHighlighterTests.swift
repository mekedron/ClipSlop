import AppKit
import Testing
@testable import ClipSlop

/// Verifies that the source highlighter maps swift-markdown's line/byte-column
/// positions onto the right UTF-16 ranges and applies the expected attributes,
/// including on non-ASCII text where byte and UTF-16 offsets diverge.

@Suite("MarkdownSourceHighlighter")
@MainActor
struct MarkdownSourceHighlighterTests {

    private func highlighted(_ markdown: String) -> NSTextStorage {
        let storage = NSTextStorage(string: markdown)
        MarkdownSourceHighlighter.highlight(storage)
        return storage
    }

    private func font(_ storage: NSTextStorage, at location: Int) -> NSFont? {
        storage.attribute(.font, at: location, effectiveRange: nil) as? NSFont
    }

    private func nsLocation(of substring: String, in string: String) -> Int {
        (string as NSString).range(of: substring).location
    }

    @Test("Bold spans get a bold font, plain text stays regular")
    func boldStyling() {
        let source = "This is **bold** here"
        let storage = highlighted(source)
        let boldIndex = nsLocation(of: "bold", in: source)
        #expect(font(storage, at: boldIndex)?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        #expect(font(storage, at: 0)?.fontDescriptor.symbolicTraits.contains(.bold) == false)
    }

    @Test("Emphasis is italicized (via trait or fallback obliqueness)")
    func italicStyling() {
        let source = "an *italic* word"
        let storage = highlighted(source)
        let index = nsLocation(of: "italic", in: source)
        let isItalic = font(storage, at: index)?.fontDescriptor.symbolicTraits.contains(.italic) == true
        let isOblique = storage.attribute(.obliqueness, at: index, effectiveRange: nil) != nil
        #expect(isItalic || isOblique)
    }

    @Test("Byte columns map correctly on Cyrillic text")
    func cyrillicBold() {
        let source = "Привет **жирный** мир"
        let storage = highlighted(source)
        let boldIndex = nsLocation(of: "жирный", in: source)
        #expect(font(storage, at: boldIndex)?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        let tailIndex = nsLocation(of: "мир", in: source)
        #expect(font(storage, at: tailIndex)?.fontDescriptor.symbolicTraits.contains(.bold) == false)
    }

    @Test("Markdown links carry .link, tooltip, and label styling")
    func markdownLink() {
        let source = "see [docs](https://example.com/x) now"
        let storage = highlighted(source)
        let labelIndex = nsLocation(of: "docs", in: source)
        let url = storage.attribute(.link, at: labelIndex, effectiveRange: nil) as? URL
        #expect(url?.absoluteString == "https://example.com/x")
        let tooltip = storage.attribute(.toolTip, at: labelIndex, effectiveRange: nil) as? String
        #expect(tooltip?.contains(MarkdownSourceHighlighter.linkTooltipHint) == true)
        #expect(storage.attribute(.underlineStyle, at: labelIndex, effectiveRange: nil) != nil)
    }

    @Test("Bare URLs and emails are linkified")
    func bareLinks() {
        let source = "go to https://bare.example/page or mail me@example.com ok"
        let storage = highlighted(source)
        let urlIndex = nsLocation(of: "bare.example", in: source)
        let url = storage.attribute(.link, at: urlIndex, effectiveRange: nil) as? URL
        #expect(url?.host == "bare.example")
        let mailIndex = nsLocation(of: "me@example.com", in: source)
        let mail = storage.attribute(.link, at: mailIndex, effectiveRange: nil) as? URL
        #expect(mail?.scheme == "mailto")
    }

    @Test("Headings on later lines are enlarged and bold")
    func headingStyling() {
        let source = "intro\n\n## Section title\n\nbody"
        let storage = highlighted(source)
        let index = nsLocation(of: "Section", in: source)
        let headingFont = font(storage, at: index)
        #expect(headingFont?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        #expect((headingFont?.pointSize ?? 0) > MarkdownSourceHighlighter.baseFontSize)
        #expect(font(storage, at: nsLocation(of: "body", in: source))?.pointSize == MarkdownSourceHighlighter.baseFontSize)
    }

    @Test("Strikethrough and inline code get their attributes")
    func strikethroughAndCode() {
        let source = "a ~~gone~~ and `code` end"
        let storage = highlighted(source)
        let goneIndex = nsLocation(of: "gone", in: source)
        #expect(storage.attribute(.strikethroughStyle, at: goneIndex, effectiveRange: nil) != nil)
        let codeIndex = nsLocation(of: "code", in: source)
        #expect(storage.attribute(.backgroundColor, at: codeIndex, effectiveRange: nil) != nil)
    }

    @Test("Empty and oversized documents don't crash")
    func edgeCases() {
        _ = highlighted("")
        let big = String(repeating: "word **bold** ", count: 20_000)
        let storage = highlighted(big)
        #expect(storage.length == (big as NSString).length)
    }
}
