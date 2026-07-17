import AppKit
import Markdown

// MARK: - Markdown Source Highlighter

/// Styles raw Markdown source in place — like a syntax highlighter, not a
/// renderer. The syntax characters stay visible; bold spans render bold,
/// emphasis renders italic, links get `.link`/`.toolTip` attributes so the
/// text view can open them with ⌘-click and show a hover hint. Bare URLs and
/// email addresses outside Markdown links are detected and linkified too.
@MainActor
enum MarkdownSourceHighlighter {
    static let baseFontSize: CGFloat = 13
    /// Documents beyond this many UTF-16 units keep base styling only, so a
    /// full re-parse per keystroke can't make typing sluggish.
    static let maxHighlightLength = 200_000

    static let linkTooltipHint = "⌘-Click to open link"

    static func highlight(_ textStorage: NSTextStorage) {
        let string = textStorage.string
        let fullRange = NSRange(location: 0, length: (string as NSString).length)
        guard fullRange.length > 0 else { return }

        let baseFont = NSFont.monospacedSystemFont(ofSize: baseFontSize, weight: .regular)
        textStorage.beginEditing()
        defer { textStorage.endEditing() }

        textStorage.setAttributes([
            .font: baseFont,
            .foregroundColor: NSColor.labelColor,
        ], range: fullRange)

        guard fullRange.length <= maxHighlightLength else { return }

        let converter = SourceRangeConverter(string: string)
        let visitor = StyleVisitor(textStorage: textStorage, converter: converter, baseFont: baseFont)
        visitor.visit(Document(parsing: string))

        detectBareLinks(in: textStorage, string: string, fullRange: fullRange)
    }

    static func tooltip(for url: URL) -> String {
        "\(url.absoluteString)\n\(linkTooltipHint)"
    }

    static func addLinkAttributes(
        to textStorage: NSTextStorage,
        range: NSRange,
        url: URL,
        styleAsLink: Bool
    ) {
        textStorage.addAttributes([
            .link: url,
            .toolTip: tooltip(for: url),
            .cursor: NSCursor.pointingHand,
        ], range: range)
        if styleAsLink {
            textStorage.addAttributes([
                .foregroundColor: NSColor.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ], range: range)
        }
    }

    /// Linkifies bare URLs and email addresses that the Markdown parser left
    /// as plain text (`https://…`, `www.…`, `mail@example.com`).
    private static func detectBareLinks(
        in textStorage: NSTextStorage,
        string: String,
        fullRange: NSRange
    ) {
        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue
        ) else { return }

        detector.enumerateMatches(in: string, range: fullRange) { result, _, _ in
            guard let result, let url = result.url else { return }
            // Skip anything already covered by a Markdown link.
            var covered = false
            textStorage.enumerateAttribute(.link, in: result.range) { value, _, stop in
                if value != nil {
                    covered = true
                    stop.pointee = true
                }
            }
            guard !covered else { return }
            addLinkAttributes(to: textStorage, range: result.range, url: url, styleAsLink: true)
        }
    }
}

// MARK: - Markup tree → attributes

@MainActor
private struct StyleVisitor {
    let textStorage: NSTextStorage
    let converter: SourceRangeConverter
    let baseFont: NSFont

    /// Recursive tree walk; child styling composes on top of the parent's
    /// (e.g. bold inside a heading, emphasis inside a link label).
    func visit(_ markup: Markup) {
        switch markup {
        case let heading as Heading:
            if let range = converter.nsRange(heading.range) {
                let scale: CGFloat = switch heading.level {
                case 1: 1.5
                case 2: 1.3
                case 3: 1.15
                default: 1.05
                }
                applyTraits(.bold, in: range)
                setFontSize(baseFont.pointSize * scale, in: range)
            }

        case let strong as Strong:
            if let range = converter.nsRange(strong.range) {
                applyTraits(.bold, in: range)
            }

        case let emphasis as Emphasis:
            if let range = converter.nsRange(emphasis.range) {
                applyTraits(.italic, in: range)
            }

        case let strikethrough as Strikethrough:
            if let range = converter.nsRange(strikethrough.range) {
                textStorage.addAttribute(
                    .strikethroughStyle,
                    value: NSUnderlineStyle.single.rawValue,
                    range: range
                )
            }

        case is InlineCode, is CodeBlock:
            if let range = converter.nsRange(markup.range) {
                textStorage.addAttribute(.backgroundColor, value: NSColor.quaternarySystemFill, range: range)
            }

        case let blockQuote as BlockQuote:
            if let range = converter.nsRange(blockQuote.range) {
                textStorage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range)
            }

        case let link as Link:
            if let nodeRange = converter.nsRange(link.range),
               let destination = link.destination,
               let url = URL(string: destination) {
                // Dim the `[…](…)` syntax and the destination…
                textStorage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: nodeRange)
                // …then paint the label like a classic link. Autolinks
                // (`<https://…>`) have the URL itself as their label.
                var styledLabel = false
                for child in link.children {
                    if let childRange = converter.nsRange(child.range) {
                        textStorage.addAttributes([
                            .foregroundColor: NSColor.linkColor,
                            .underlineStyle: NSUnderlineStyle.single.rawValue,
                        ], range: childRange)
                        styledLabel = true
                    }
                }
                MarkdownSourceHighlighter.addLinkAttributes(
                    to: textStorage,
                    range: nodeRange,
                    url: url,
                    styleAsLink: !styledLabel
                )
            }

        case is Image, is ThematicBreak:
            if let range = converter.nsRange(markup.range) {
                textStorage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range)
            }

        default:
            break
        }

        for child in markup.children {
            visit(child)
        }
    }

    private func applyTraits(_ trait: NSFontDescriptor.SymbolicTraits, in range: NSRange) {
        textStorage.enumerateAttribute(.font, in: range) { value, subRange, _ in
            let font = (value as? NSFont) ?? baseFont
            let traits = font.fontDescriptor.symbolicTraits.union(trait)
            let newFont = NSFont(
                descriptor: font.fontDescriptor.withSymbolicTraits(traits),
                size: font.pointSize
            ) ?? font
            textStorage.addAttribute(.font, value: newFont, range: subRange)
            if trait.contains(.italic), !newFont.fontDescriptor.symbolicTraits.contains(.italic) {
                // Monospaced system font has no italic face on some systems.
                textStorage.addAttribute(.obliqueness, value: 0.18, range: subRange)
            }
        }
    }

    private func setFontSize(_ size: CGFloat, in range: NSRange) {
        textStorage.enumerateAttribute(.font, in: range) { value, subRange, _ in
            let font = (value as? NSFont) ?? baseFont
            let newFont = NSFont(descriptor: font.fontDescriptor, size: size) ?? font
            textStorage.addAttribute(.font, value: newFont, range: subRange)
        }
    }
}

// MARK: - SourceRange → NSRange

/// swift-markdown reports positions as 1-based line numbers plus 1-based
/// UTF-8 byte columns; NSAttributedString wants UTF-16 offsets. Bridges the
/// two via a per-line index table.
struct SourceRangeConverter {
    private let string: String
    private let lineStarts: [String.Index]

    init(string: String) {
        self.string = string
        var starts: [String.Index] = [string.startIndex]
        var searchFrom = string.startIndex
        while let newline = string[searchFrom...].firstIndex(of: "\n") {
            let next = string.index(after: newline)
            starts.append(next)
            searchFrom = next
        }
        lineStarts = starts
    }

    func nsRange(_ range: SourceRange?) -> NSRange? {
        guard let range,
              let start = stringIndex(of: range.lowerBound),
              let end = stringIndex(of: range.upperBound),
              start < end else { return nil }
        let utf16 = string.utf16
        return NSRange(
            location: utf16.distance(from: utf16.startIndex, to: start),
            length: utf16.distance(from: start, to: end)
        )
    }

    private func stringIndex(of location: SourceLocation) -> String.Index? {
        let lineNumber = location.line - 1
        guard lineNumber >= 0, lineNumber < lineStarts.count else { return nil }
        let lineStart = lineStarts[lineNumber]
        let lineEnd = lineNumber + 1 < lineStarts.count
            ? string.index(before: lineStarts[lineNumber + 1]) // the newline itself
            : string.endIndex

        let utf8 = string.utf8
        guard let index = utf8.index(
            lineStart,
            offsetBy: location.column - 1,
            limitedBy: lineEnd
        ) else { return lineEnd }
        return index.samePosition(in: string)
    }
}

// MARK: - ⌘-click link opening

/// NSTextView that opens `.link` ranges with ⌘-click only. A plain click
/// places the caret like regular text — both when editable and read-only —
/// so links never hijack normal editing or selection.
final class MarkdownSourceTextView: NSTextView {
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), let url = linkURL(at: event) {
            NSWorkspace.shared.open(url)
            return
        }
        super.mouseDown(with: event)
    }

    override func clicked(onLink link: Any, at charIndex: Int) {
        // Reached on plain click (⌘-click is intercepted in mouseDown):
        // place the caret instead of following the link.
        setSelectedRange(NSRange(location: charIndex, length: 0))
    }

    private func linkURL(at event: NSEvent) -> URL? {
        guard let layoutManager, let textContainer, let textStorage else { return nil }
        let viewPoint = convert(event.locationInWindow, from: nil)
        let containerPoint = NSPoint(
            x: viewPoint.x - textContainerOrigin.x,
            y: viewPoint.y - textContainerOrigin.y
        )
        var fraction: CGFloat = 0
        let index = layoutManager.characterIndex(
            for: containerPoint,
            in: textContainer,
            fractionOfDistanceBetweenInsertionPoints: &fraction
        )
        guard index < textStorage.length else { return nil }

        // characterIndex(for:) snaps to the nearest character; require the
        // click to land on the glyph itself so ⌘-clicking empty space after
        // a line ending in a link doesn't open it.
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: index, length: 1),
            actualCharacterRange: nil
        )
        let glyphRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        guard glyphRect.insetBy(dx: -2, dy: -2).contains(containerPoint) else { return nil }

        let value = textStorage.attribute(.link, at: index, effectiveRange: nil)
        if let url = value as? URL { return url }
        if let urlString = value as? String { return URL(string: urlString) }
        return nil
    }
}
