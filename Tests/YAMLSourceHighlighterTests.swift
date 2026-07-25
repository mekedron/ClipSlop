import AppKit
import Testing
@testable import ClipSlop

/// Verifies the YAML line scanner colours the FrontmatterParser subset —
/// keys, quoted strings, literals, comments, fences, flow punctuation — and
/// that the frontmatter mode splits a document into a YAML head and a
/// Markdown body at the right offsets.

@Suite("YAMLSourceHighlighter")
@MainActor
struct YAMLSourceHighlighterTests {

    private func highlighted(_ yaml: String) -> NSTextStorage {
        let storage = NSTextStorage(string: yaml)
        YAMLSourceHighlighter.highlight(storage)
        return storage
    }

    private func color(_ storage: NSTextStorage, at location: Int) -> NSColor? {
        storage.attribute(.foregroundColor, at: location, effectiveRange: nil) as? NSColor
    }

    private func nsLocation(of substring: String, in string: String) -> Int {
        (string as NSString).range(of: substring).location
    }

    @Test("Keys and colons are coloured, plain scalar values are not")
    func keyStyling() {
        let source = "chip_count: some plain text"
        let storage = highlighted(source)
        #expect(color(storage, at: 0) == YAMLSourceHighlighter.keyColor)
        #expect(color(storage, at: nsLocation(of: ":", in: source)) == YAMLSourceHighlighter.punctuationColor)
        #expect(color(storage, at: nsLocation(of: "plain", in: source)) == NSColor.labelColor)
    }

    @Test("Numbers, booleans, and negatives get the literal colour")
    func literals() {
        let source = "retries: 2\nenabled: true\noffset: -3.5\nname: fast"
        let storage = highlighted(source)
        #expect(color(storage, at: nsLocation(of: "2", in: source)) == YAMLSourceHighlighter.literalColor)
        #expect(color(storage, at: nsLocation(of: "true", in: source)) == YAMLSourceHighlighter.literalColor)
        #expect(color(storage, at: nsLocation(of: "-3.5", in: source)) == YAMLSourceHighlighter.literalColor)
        #expect(color(storage, at: nsLocation(of: "fast", in: source)) == NSColor.labelColor)
    }

    @Test("Quoted scalars are string-coloured, quotes hide nothing")
    func quotedStrings() {
        let source = "title: \"hello: world\" # tail\nmotto: 'ad # astra'"
        let storage = highlighted(source)
        #expect(color(storage, at: nsLocation(of: "\"hello", in: source)) == YAMLSourceHighlighter.stringColor)
        #expect(color(storage, at: nsLocation(of: "world", in: source)) == YAMLSourceHighlighter.stringColor)
        #expect(color(storage, at: nsLocation(of: "# tail", in: source)) == YAMLSourceHighlighter.commentColor)
        // The `#` inside single quotes is part of the string, not a comment.
        #expect(color(storage, at: nsLocation(of: "# astra", in: source)) == YAMLSourceHighlighter.stringColor)
    }

    @Test("Fences and full-line comments")
    func fencesAndComments() {
        let source = "---\n# top comment\nkey: value\n---"
        let storage = highlighted(source)
        #expect(color(storage, at: 0) == YAMLSourceHighlighter.fenceColor)
        #expect(color(storage, at: nsLocation(of: "# top", in: source)) == YAMLSourceHighlighter.commentColor)
        #expect(color(storage, at: nsLocation(of: "key", in: source)) == YAMLSourceHighlighter.keyColor)
        let closing = (source as NSString).length - 1
        #expect(color(storage, at: closing) == YAMLSourceHighlighter.fenceColor)
    }

    @Test("Flow lists: punctuation, literals, plain entries")
    func flowList() {
        let source = "tags: [alpha, 42]"
        let storage = highlighted(source)
        #expect(color(storage, at: nsLocation(of: "[", in: source)) == YAMLSourceHighlighter.punctuationColor)
        #expect(color(storage, at: nsLocation(of: "alpha", in: source)) == NSColor.labelColor)
        #expect(color(storage, at: nsLocation(of: ",", in: source)) == YAMLSourceHighlighter.punctuationColor)
        #expect(color(storage, at: nsLocation(of: "42", in: source)) == YAMLSourceHighlighter.literalColor)
        #expect(color(storage, at: nsLocation(of: "]", in: source)) == YAMLSourceHighlighter.punctuationColor)
    }

    @Test("Flow maps colour their keys")
    func flowMap() {
        let source = "route: {model: fast, retries: 2}"
        let storage = highlighted(source)
        #expect(color(storage, at: nsLocation(of: "model", in: source)) == YAMLSourceHighlighter.keyColor)
        #expect(color(storage, at: nsLocation(of: "fast", in: source)) == NSColor.labelColor)
        #expect(color(storage, at: nsLocation(of: "retries", in: source)) == YAMLSourceHighlighter.keyColor)
        #expect(color(storage, at: nsLocation(of: "2", in: source)) == YAMLSourceHighlighter.literalColor)
    }

    @Test("Block lists: dash is punctuation, entries scan as values")
    func blockList() {
        let source = "steps:\n  - alpha\n  - \"beta\"\n  - kind: chip"
        let storage = highlighted(source)
        #expect(color(storage, at: nsLocation(of: "- alpha", in: source)) == YAMLSourceHighlighter.punctuationColor)
        #expect(color(storage, at: nsLocation(of: "alpha", in: source)) == NSColor.labelColor)
        #expect(color(storage, at: nsLocation(of: "\"beta\"", in: source)) == YAMLSourceHighlighter.stringColor)
        #expect(color(storage, at: nsLocation(of: "kind", in: source)) == YAMLSourceHighlighter.keyColor)
    }

    @Test("A URL value keeps the base colour; its # fragment is no comment")
    func urlValue() {
        let source = "docs: https://example.com/x#frag"
        let storage = highlighted(source)
        #expect(color(storage, at: nsLocation(of: "example", in: source)) == NSColor.labelColor)
        #expect(color(storage, at: nsLocation(of: "#frag", in: source)) == NSColor.labelColor)
    }

    @Test("Empty and oversized documents don't crash")
    func edgeCases() {
        _ = highlighted("")
        let big = String(repeating: "key: value\n", count: 30_000)
        let storage = highlighted(big)
        #expect(storage.length == (big as NSString).length)
    }
}

@Suite("SourceSyntax frontmatter mode")
@MainActor
struct FrontmatterHighlightingTests {

    private func highlighted(_ text: String) -> NSTextStorage {
        let storage = NSTextStorage(string: text)
        SourceSyntax.markdownWithFrontmatter.highlight(storage)
        return storage
    }

    private func color(_ storage: NSTextStorage, at location: Int) -> NSColor? {
        storage.attribute(.foregroundColor, at: location, effectiveRange: nil) as? NSColor
    }

    private func font(_ storage: NSTextStorage, at location: Int) -> NSFont? {
        storage.attribute(.font, at: location, effectiveRange: nil) as? NSFont
    }

    private func nsLocation(of substring: String, in string: String) -> Int {
        (string as NSString).range(of: substring).location
    }

    @Test("Head styles as YAML, body styles as Markdown")
    func splitDocument() {
        let source = "---\nname: alpha\n---\n\n# Title\n\nSome **bold** text"
        let storage = highlighted(source)
        #expect(color(storage, at: nsLocation(of: "name", in: source)) == YAMLSourceHighlighter.keyColor)
        let titleFont = font(storage, at: nsLocation(of: "Title", in: source))
        #expect(titleFont?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        #expect((titleFont?.pointSize ?? 0) > MarkdownSourceHighlighter.baseFontSize)
        let boldFont = font(storage, at: nsLocation(of: "bold", in: source))
        #expect(boldFont?.fontDescriptor.symbolicTraits.contains(.bold) == true)
    }

    @Test("A '#' comment in the head is not a Markdown heading")
    func hashInHead() {
        let source = "---\n# just a comment\n---\nbody"
        let storage = highlighted(source)
        let index = nsLocation(of: "# just", in: source)
        #expect(color(storage, at: index) == YAMLSourceHighlighter.commentColor)
        #expect(font(storage, at: index)?.pointSize == MarkdownSourceHighlighter.baseFontSize)
    }

    @Test("Without an opening fence the whole document is Markdown")
    func noFence() {
        let source = "# Heading\n\nkey: value"
        let storage = highlighted(source)
        let headingFont = font(storage, at: nsLocation(of: "Heading", in: source))
        #expect((headingFont?.pointSize ?? 0) > MarkdownSourceHighlighter.baseFontSize)
        // Not YAML: the key stays at the base colour.
        #expect(color(storage, at: nsLocation(of: "key", in: source)) == NSColor.labelColor)
    }

    @Test("A still-unterminated fence styles everything as YAML")
    func unterminatedFence() {
        let source = "---\nname: alpha\nmode: 2"
        let storage = highlighted(source)
        #expect(color(storage, at: nsLocation(of: "name", in: source)) == YAMLSourceHighlighter.keyColor)
        #expect(color(storage, at: nsLocation(of: "2", in: source)) == YAMLSourceHighlighter.literalColor)
    }

    @Test("Non-ASCII head text keeps body offsets correct")
    func cyrillicOffsets() {
        let source = "---\ntitle: Привет мир\n---\nтело **жирный** конец"
        let storage = highlighted(source)
        let boldFont = font(storage, at: nsLocation(of: "жирный", in: source))
        #expect(boldFont?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        let tailFont = font(storage, at: nsLocation(of: "конец", in: source))
        #expect(tailFont?.fontDescriptor.symbolicTraits.contains(.bold) == false)
    }
}
