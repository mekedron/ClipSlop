import AppKit

// MARK: - Source syntax dispatch

/// Which grammar a source editor colours. Chosen per file (the Magic tab
/// picks by extension); `markdownWithFrontmatter` splits at the `---` fences
/// exactly where `FrontmatterParser` does and styles each half with its own
/// highlighter.
enum SourceSyntax: Hashable {
    case markdown
    case yaml
    case markdownWithFrontmatter

    @MainActor
    func highlight(_ textStorage: NSTextStorage) {
        switch self {
        case .markdown:
            MarkdownSourceHighlighter.highlight(textStorage)
        case .yaml:
            YAMLSourceHighlighter.highlight(textStorage)
        case .markdownWithFrontmatter:
            Self.highlightFrontmatterDocument(textStorage)
        }
    }

    @MainActor
    private static func highlightFrontmatterDocument(_ textStorage: NSTextStorage) {
        let string = textStorage.string as NSString
        let fullRange = NSRange(location: 0, length: string.length)
        guard fullRange.length > 0 else { return }

        textStorage.beginEditing()
        defer { textStorage.endEditing() }
        MarkdownSourceHighlighter.applyBaseAttributes(to: textStorage, in: fullRange)
        guard fullRange.length <= MarkdownSourceHighlighter.maxHighlightLength else { return }

        guard let bodyStart = frontmatterBodyStart(in: string) else {
            // No opening fence: the whole document is Markdown.
            MarkdownSourceHighlighter.highlightMarkdown(textStorage, in: fullRange)
            return
        }
        YAMLSourceHighlighter.highlightLines(
            textStorage, in: NSRange(location: 0, length: bodyStart)
        )
        let bodyRange = NSRange(location: bodyStart, length: fullRange.length - bodyStart)
        if bodyRange.length > 0 {
            MarkdownSourceHighlighter.highlightMarkdown(textStorage, in: bodyRange)
        }
    }

    /// UTF-16 offset where the Markdown body begins — right after the closing
    /// fence's newline — or nil when line 1 is not a `---` fence
    /// (`FrontmatterParser`'s opening rule). A document still missing its
    /// closing fence is all head: mid-typing, every line styles as YAML.
    private static func frontmatterBodyStart(in string: NSString) -> Int? {
        var lineStart = 0
        var sawOpeningFence = false
        while lineStart < string.length {
            var lineEnd = 0
            var contentsEnd = 0
            string.getLineStart(
                nil, end: &lineEnd, contentsEnd: &contentsEnd,
                for: NSRange(location: lineStart, length: 0)
            )
            let line = string.substring(
                with: NSRange(location: lineStart, length: contentsEnd - lineStart)
            )
            let isFence = line.trimmingCharacters(in: .whitespaces) == "---"
            if !sawOpeningFence {
                guard isFence else { return nil }
                sawOpeningFence = true
            } else if isFence {
                return lineEnd
            }
            lineStart = lineEnd
        }
        return sawOpeningFence ? string.length : nil
    }
}

// MARK: - YAML Source Highlighter

/// unichar for an ASCII scalar. The scanner compares UTF-16 units against
/// ASCII directly, which is safe: no non-ASCII character contains an
/// ASCII-valued code unit.
private func ascii(_ scalar: Unicode.Scalar) -> unichar {
    unichar(scalar.value)
}

/// Colours raw YAML source in place — covering the small subset
/// `FrontmatterParser` accepts: block nesting, `- ` lists, flow `[…]`/`{…}`,
/// quoted scalars, `#` comments, `---` fences. A per-line scanner rather
/// than a reuse of the parser: the parser throws at the first bad line,
/// while a highlighter must keep styling a half-typed document.
@MainActor
enum YAMLSourceHighlighter {
    // Adaptive system colours, so dark mode comes free — same approach as
    // the Markdown highlighter's semantic colours.
    static let keyColor = NSColor.systemBlue
    static let stringColor = NSColor.systemRed
    static let literalColor = NSColor.systemPurple
    static let punctuationColor = NSColor.secondaryLabelColor
    static let commentColor = NSColor.secondaryLabelColor
    static let fenceColor = NSColor.tertiaryLabelColor

    static func highlight(_ textStorage: NSTextStorage) {
        let fullRange = NSRange(location: 0, length: (textStorage.string as NSString).length)
        guard fullRange.length > 0 else { return }

        textStorage.beginEditing()
        defer { textStorage.endEditing() }
        MarkdownSourceHighlighter.applyBaseAttributes(to: textStorage, in: fullRange)
        guard fullRange.length <= MarkdownSourceHighlighter.maxHighlightLength else { return }
        highlightLines(textStorage, in: fullRange)
    }

    /// Styles every line in `range` (which must start at a line boundary).
    /// Base attributes are the caller's job — the frontmatter mode resets
    /// the whole document once and then styles the two halves.
    static func highlightLines(_ textStorage: NSTextStorage, in range: NSRange) {
        let string = textStorage.string as NSString
        let end = min(range.location + range.length, string.length)
        var lineStart = range.location
        while lineStart < end {
            var lineEnd = 0
            var contentsEnd = 0
            string.getLineStart(
                nil, end: &lineEnd, contentsEnd: &contentsEnd,
                for: NSRange(location: lineStart, length: 0)
            )
            let contentRange = NSRange(
                location: lineStart, length: min(contentsEnd, end) - lineStart
            )
            highlightLine(
                textStorage,
                line: string.substring(with: contentRange) as NSString,
                at: lineStart
            )
            lineStart = lineEnd
        }
    }

    // MARK: - Line scanning

    private static func highlightLine(_ storage: NSTextStorage, line: NSString, at origin: Int) {
        let length = line.length
        var i = 0
        while i < length, isSpace(line.character(at: i)) { i += 1 }
        guard i < length else { return }

        if line.trimmingCharacters(in: .whitespaces) == "---" {
            paint(storage, NSRange(location: origin, length: length), fenceColor)
            return
        }
        if line.character(at: i) == ascii("#") {
            paint(storage, NSRange(location: origin + i, length: length - i), commentColor)
            return
        }
        // `- ` block-list marker (also `- key: value` entries).
        if line.character(at: i) == ascii("-"),
           i + 1 == length || isSpace(line.character(at: i + 1)) {
            paint(storage, NSRange(location: origin + i, length: 1), punctuationColor)
            i += 1
            while i < length, isSpace(line.character(at: i)) { i += 1 }
        }
        i = paintKeyIfPresent(storage, line: line, from: i, origin: origin)
        paintValue(storage, line: line, from: i, origin: origin)
    }

    /// Colours a leading `key:` — key charset and colon rule as in
    /// `FrontmatterParser.splitKey` — and returns the index after the colon;
    /// without a key match returns `start`, so the rest scans as a value.
    private static func paintKeyIfPresent(
        _ storage: NSTextStorage, line: NSString, from start: Int, origin: Int
    ) -> Int {
        var j = start
        while j < line.length, isKeyChar(line.character(at: j)) { j += 1 }
        guard j > start, j < line.length,
              line.character(at: j) == ascii(":"),
              j + 1 == line.length || isSpace(line.character(at: j + 1))
        else { return start }
        paint(storage, NSRange(location: origin + start, length: j - start), keyColor)
        paint(storage, NSRange(location: origin + j, length: 1), punctuationColor)
        return j + 1
    }

    /// Scans a value region — after `key:` or a list dash — for quoted
    /// strings, flow punctuation, flow-map keys, literals, and a trailing
    /// comment. Anything else keeps the base colour.
    private static func paintValue(
        _ storage: NSTextStorage, line: NSString, from start: Int, origin: Int
    ) {
        let length = line.length
        var flowDepth = 0
        var i = start
        while i < length {
            let u = line.character(at: i)
            if isSpace(u) {
                i += 1
                continue
            }
            switch u {
            case ascii("\""), ascii("'"):
                i = paintQuoted(storage, line: line, from: i, origin: origin)
            case ascii("#") where i == start || isSpace(line.character(at: i - 1)):
                paint(storage, NSRange(location: origin + i, length: length - i), commentColor)
                return
            case ascii("["), ascii("{"):
                flowDepth += 1
                paint(storage, NSRange(location: origin + i, length: 1), punctuationColor)
                i += 1
            case ascii("]"), ascii("}"):
                flowDepth = max(0, flowDepth - 1)
                paint(storage, NSRange(location: origin + i, length: 1), punctuationColor)
                i += 1
            case ascii(","), ascii(":"):
                if flowDepth > 0 {
                    paint(storage, NSRange(location: origin + i, length: 1), punctuationColor)
                }
                i += 1
            default:
                i = paintToken(storage, line: line, from: i, origin: origin, inFlow: flowDepth > 0)
            }
        }
    }

    /// Scans one bare token. In flow context it stops at flow delimiters and
    /// may turn out to be a flow-map key; in block context it runs to the
    /// trailing comment or end of line (a plain scalar is one token, spaces
    /// and all). Number/boolean/null literals get the literal colour; other
    /// scalars keep the base colour.
    private static func paintToken(
        _ storage: NSTextStorage, line: NSString, from start: Int, origin: Int, inFlow: Bool
    ) -> Int {
        let length = line.length
        var j = start
        while j < length {
            let u = line.character(at: j)
            if inFlow,
               u == ascii(",") || u == ascii("]")
                   || u == ascii("}") || u == ascii(":") {
                break
            }
            if u == ascii("#"), j > start, isSpace(line.character(at: j - 1)) {
                break
            }
            j += 1
        }
        var tokenEnd = j
        while tokenEnd > start, isSpace(line.character(at: tokenEnd - 1)) { tokenEnd -= 1 }
        guard tokenEnd > start else { return j }

        let token = line.substring(with: NSRange(location: start, length: tokenEnd - start))
        let range = NSRange(location: origin + start, length: tokenEnd - start)
        if inFlow, j < length, line.character(at: j) == ascii(":") {
            paint(storage, range, keyColor)
        } else if isLiteral(token) {
            paint(storage, range, literalColor)
        }
        return j
    }

    private static func paintQuoted(
        _ storage: NSTextStorage, line: NSString, from start: Int, origin: Int
    ) -> Int {
        let length = line.length
        let quote = line.character(at: start)
        var j = start + 1
        while j < length {
            let u = line.character(at: j)
            // Escapes exist in double quotes only; single quotes are verbatim.
            if quote == ascii("\""), u == ascii("\\"), j + 1 < length {
                j += 2
                continue
            }
            j += 1
            if u == quote { break }
        }
        // An unterminated string colours to the end of the line — live
        // feedback while the closing quote is still untyped.
        paint(storage, NSRange(location: origin + start, length: j - start), stringColor)
        return j
    }

    private static func isLiteral(_ token: String) -> Bool {
        switch token {
        case "true", "false", "null", "~": return true
        default: return Int(token) != nil || Double(token) != nil
        }
    }

    private static func isSpace(_ u: unichar) -> Bool {
        u == ascii(" ") || u == ascii("\t")
    }

    /// `FrontmatterParser`'s key charset: `[A-Za-z0-9_.-]`.
    private static func isKeyChar(_ u: unichar) -> Bool {
        (u >= ascii("a") && u <= ascii("z"))
            || (u >= ascii("A") && u <= ascii("Z"))
            || (u >= ascii("0") && u <= ascii("9"))
            || u == ascii("_") || u == ascii(".") || u == ascii("-")
    }

    private static func paint(_ storage: NSTextStorage, _ range: NSRange, _ color: NSColor) {
        guard range.length > 0 else { return }
        storage.addAttribute(.foregroundColor, value: color, range: range)
    }
}
