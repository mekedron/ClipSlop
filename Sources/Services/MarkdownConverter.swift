import AppKit
import Markdown

@MainActor
enum MarkdownConverter {

    // MARK: - Public API

    static func html(from markdown: String) -> String {
        let document = Document(parsing: markdown)
        var visitor = HTMLVisitor()
        let body = visitor.visit(document)
        return """
        <html><head><style>
        body { font-family: -apple-system, Helvetica Neue, sans-serif; font-size: 13px; line-height: 1.5; color: #1d1d1f; }
        code { font-family: Menlo, monospace; font-size: 12px; background: #f0f0f0; padding: 1px 4px; border-radius: 3px; }
        pre { background: #f0f0f0; padding: 10px; border-radius: 6px; overflow-x: auto; }
        pre code { background: none; padding: 0; }
        blockquote { border-left: 3px solid #c0c0c0; margin-left: 0; padding-left: 12px; color: #555; }
        img { max-width: 100%; }
        </style></head><body>\(body)</body></html>
        """
    }

    /// HTML-based conversion (for clipboard RTF/HTML export only).
    static func rtfData(from markdown: String) -> Data? {
        let htmlString = html(from: markdown)
        guard let data = htmlString.data(using: .utf8),
              let attrStr = NSAttributedString(html: data, documentAttributes: nil)
        else { return nil }
        let range = NSRange(location: 0, length: attrStr.length)
        return attrStr.rtf(from: range, documentAttributes: [:])
    }

    // MARK: - HTML → Markdown

    static func markdown(fromHTML html: String) -> String? {
        let processed = preprocessHTML(html)

        guard let data = processed.data(using: .utf8),
              let doc = try? XMLDocument(data: data, options: [.documentTidyHTML]),
              let root = doc.rootElement()
        else { return nil }

        let body = findElement(named: "body", in: root) ?? root
        let result = convertNode(body)
        return cleanupMarkdown(result)
    }

    /// Pre-process HTML before Tidy to prevent encoding corruption and structural issues.
    private static func preprocessHTML(_ html: String) -> String {
        var result = html

        // 1. Strip ALL <span> tags (keep content). Spans are presentational —
        //    semantic formatting uses <strong>, <em>, <a>, etc.
        result = result.replacingOccurrences(
            of: #"</?span[^>]*>"#,
            with: "",
            options: .regularExpression
        )

        // 2. UNIVERSAL ENCODING FIX: Convert all non-ASCII characters to HTML
        //    numeric entities BEFORE passing to Tidy. Tidy defaults to Latin-1
        //    and corrupts multi-byte UTF-8 (smart quotes, emoji, accented chars).
        //    With entities, Tidy sees only ASCII — nothing to misinterpret.
        //    XMLDocument converts entities back to characters after parsing.
        result = escapeNonASCII(result)

        return result
    }

    /// Fallback: convert NSAttributedString (RTF) to Markdown via font traits
    static func markdown(from attrStr: NSAttributedString) -> String {
        var result = ""
        let fullRange = NSRange(location: 0, length: attrStr.length)
        let string = attrStr.string

        attrStr.enumerateAttributes(in: fullRange, options: []) { attrs, range, _ in
            let substring = (string as NSString).substring(with: range)
            let font = attrs[.font] as? NSFont
            let traits = font?.fontDescriptor.symbolicTraits ?? []
            let isBold = traits.contains(.bold)
            let isItalic = traits.contains(.italic)
            let isMonospace = font?.fontDescriptor.symbolicTraits.contains(.monoSpace) ?? false
            let link = attrs[.link] as? URL
            let fontSize = font?.pointSize ?? 13

            let headingLevel: Int? = if fontSize >= 32 { 1 }
                else if fontSize >= 24 { 2 }
                else if fontSize >= 20 { 3 }
                else { nil }

            var text = substring
            let isWhitespace = text.allSatisfy(\.isWhitespace)

            if isMonospace && !isWhitespace {
                text = "`\(text)`"
            } else {
                if isBold && headingLevel == nil && !isWhitespace { text = "**\(text)**" }
                if isItalic && !isWhitespace { text = "*\(text)*" }
            }

            if let link, !link.absoluteString.isEmpty {
                text = "[\(substring)](\(link.absoluteString))"
            }

            if let level = headingLevel, result.isEmpty || result.hasSuffix("\n") {
                text = String(repeating: "#", count: level) + " " + text
            }

            result += text
        }

        return cleanupMarkdown(result)
    }

    // MARK: - XML → Markdown recursive converter

    private static func findElement(named name: String, in element: XMLElement?) -> XMLElement? {
        guard let element else { return nil }
        if element.localName?.lowercased() == name { return element }
        for child in element.children ?? [] {
            if let el = child as? XMLElement,
               let found = findElement(named: name, in: el) {
                return found
            }
        }
        return nil
    }

    private static func convertChildren(_ node: XMLNode) -> String {
        (node.children ?? []).map { convertNode($0) }.joined()
    }

    private static func convertNode(_ node: XMLNode) -> String {
        // Text node
        if node.kind == .text {
            return node.stringValue ?? ""
        }

        guard let element = node as? XMLElement,
              let tag = element.localName?.lowercased()
        else {
            return convertChildren(node)
        }

        switch tag {
        // Headings
        case "h1": return "\n# \(convertChildren(element).trimmed)\n\n"
        case "h2": return "\n## \(convertChildren(element).trimmed)\n\n"
        case "h3": return "\n### \(convertChildren(element).trimmed)\n\n"
        case "h4": return "\n#### \(convertChildren(element).trimmed)\n\n"
        case "h5": return "\n##### \(convertChildren(element).trimmed)\n\n"
        case "h6": return "\n###### \(convertChildren(element).trimmed)\n\n"

        // Inline formatting
        case "strong", "b":
            let content = convertChildren(element).trimmed
            return content.isEmpty ? "" : "**\(content)**"
        case "em", "i":
            let content = convertChildren(element).trimmed
            return content.isEmpty ? "" : "*\(content)*"
        case "s", "del", "strike":
            let content = convertChildren(element).trimmed
            return content.isEmpty ? "" : "~~\(content)~~"
        case "code":
            // Inside <pre> — handled by the "pre" case
            if element.parent?.localName?.lowercased() == "pre" {
                return element.stringValue ?? ""
            }
            let content = element.stringValue ?? ""
            guard !content.isEmpty else { return "" }
            // Detect highlighted code blocks (hljs, language-*, data-highlighted)
            // that might not be wrapped in <pre> — render as fenced block
            let className = element.attribute(forName: "class")?.stringValue ?? ""
            let isHighlighted = element.attribute(forName: "data-highlighted") != nil
                || className.contains("hljs") || className.contains("language-")
            let isMultiline = content.contains("\n")
            if isHighlighted || isMultiline {
                let lang = extractLanguage(from: className)
                return "\n```\(lang)\n\(content.trimmed)\n```\n\n"
            }
            return "`\(content)`"

        // Code blocks
        case "pre":
            let code = element.stringValue ?? convertChildren(element)
            let codeClass = (element.children ?? [])
                .compactMap { $0 as? XMLElement }
                .first { $0.localName?.lowercased() == "code" }
                .flatMap { $0.attribute(forName: "class")?.stringValue } ?? ""
            let lang = extractLanguage(from: codeClass)
            return "\n```\(lang)\n\(code.trimmed)\n```\n\n"

        // Links and images
        case "a":
            let href = element.attribute(forName: "href")?.stringValue ?? ""
            // If the link wraps only an image, output image + link separately
            // ([![]()]() nesting doesn't render in most Markdown viewers)
            let childElements = (element.children ?? []).compactMap { $0 as? XMLElement }
            if let img = childElements.first,
               childElements.count == 1,
               img.localName?.lowercased() == "img" {
                let imgSrc = img.attribute(forName: "src")?.stringValue ?? ""
                let imgAlt = img.attribute(forName: "alt")?.stringValue ?? ""
                // Delegate to img handler which handles dimensions
                let image = convertNode(img)
                // If link points to the same or similar URL as the image, just show the image
                let imgFilename = imgSrc.components(separatedBy: "/").last ?? "___"
                if href == imgSrc || href.contains(imgFilename) {
                    return image
                }
                // Otherwise show image with a link below
                return "\(image)\n[\(imgAlt.isEmpty ? "Link" : imgAlt)](\(href))"
            }
            let content = convertChildren(element).trimmed
            if href.isEmpty || content.isEmpty { return content }
            return "[\(content)](\(href))"
        case "img":
            let src = element.attribute(forName: "src")?.stringValue ?? ""
            let alt = element.attribute(forName: "alt")?.stringValue ?? ""
            return "![\(alt)](\(src))"

        // Lists
        case "ul":
            return "\n" + convertListItems(element, ordered: false) + "\n"
        case "ol":
            return "\n" + convertListItems(element, ordered: true) + "\n"
        case "li":
            // Handled by convertListItems; fallback for standalone
            return "- \(convertChildren(element).trimmed)\n"

        // Blockquote
        case "blockquote":
            let content = convertChildren(element).trimmed
            let quoted = content.components(separatedBy: "\n")
                .map { "> \($0)" }
                .joined(separator: "\n")
            return "\n\(quoted)\n\n"

        // Table
        case "table":
            // Skip presentation/layout tables (common in email HTML) — just extract content
            if element.attribute(forName: "role")?.stringValue?.lowercased() == "presentation" {
                return convertChildren(element)
            }
            return "\n" + convertTable(element) + "\n"

        // Block elements
        case "p":
            return "\n\(convertChildren(element).trimmed)\n\n"
        case "br":
            return "\n"
        case "hr":
            return "\n---\n\n"
        case "div", "section", "article", "main", "header", "footer", "nav":
            return convertChildren(element)

        // Spans and other inline
        case "span":
            return convertChildren(element)

        // Skip style/script/head
        case "style", "script", "head", "meta", "link", "title":
            return ""

        default:
            return convertChildren(element)
        }
    }

    // MARK: - Lists

    private static func convertListItems(_ list: XMLElement, ordered: Bool) -> String {
        var result = ""
        var index = 1
        for child in list.children ?? [] {
            guard let el = child as? XMLElement,
                  el.localName?.lowercased() == "li"
            else { continue }

            let prefix = ordered ? "\(index). " : "- "
            let content = convertChildren(el).trimmed
            // Handle nested lists: indent sub-lines
            let lines = content.components(separatedBy: "\n")
            for (i, line) in lines.enumerated() {
                if i == 0 {
                    result += "\(prefix)\(line)\n"
                } else if !line.isEmpty {
                    result += "  \(line)\n"
                }
            }
            index += 1
        }
        return result
    }

    // MARK: - Tables

    private static func convertTable(_ table: XMLElement) -> String {
        var rows: [[String]] = []

        // Collect all rows from thead, tbody, or directly
        func collectRows(from parent: XMLElement) {
            for child in parent.children ?? [] {
                guard let el = child as? XMLElement else { continue }
                let name = el.localName?.lowercased() ?? ""
                if name == "tr" {
                    let cells = (el.children ?? [])
                        .compactMap { $0 as? XMLElement }
                        .filter { ["td", "th"].contains($0.localName?.lowercased()) }
                        .map { convertChildren($0).trimmed.replacingOccurrences(of: "|", with: "\\|") }
                    if !cells.isEmpty { rows.append(cells) }
                } else if name == "thead" || name == "tbody" || name == "tfoot" {
                    collectRows(from: el)
                }
            }
        }

        collectRows(from: table)
        guard !rows.isEmpty else { return "" }

        // Normalize column count
        let colCount = rows.map(\.count).max() ?? 0
        let normalized = rows.map { row in
            row + Array(repeating: "", count: max(0, colCount - row.count))
        }

        var result = ""
        // Header row
        result += "| " + normalized[0].joined(separator: " | ") + " |\n"
        // Separator
        result += "| " + Array(repeating: "---", count: colCount).joined(separator: " | ") + " |\n"
        // Data rows
        for row in normalized.dropFirst() {
            result += "| " + row.joined(separator: " | ") + " |\n"
        }
        return result
    }

    // MARK: - Cleanup

    /// Extract programming language from CSS class like "language-swift", "hljs language-python"
    /// Extract a CSS property value from an inline style string.
    private static func extractStyleValue(_ style: String, property: String) -> String? {
        guard let range = style.range(of: "\(property):", options: .caseInsensitive) else { return nil }
        let afterProperty = style[range.upperBound...].trimmingCharacters(in: .whitespaces)
        let value = afterProperty.prefix(while: { $0 != ";" && $0 != "\"" })
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func extractLanguage(from className: String) -> String {
        className.components(separatedBy: .whitespaces)
            .compactMap { component -> String? in
                if component.hasPrefix("language-") {
                    return String(component.dropFirst(9))
                }
                return nil
            }
            .first ?? ""
    }

    /// Replace all non-ASCII characters with HTML numeric entities.
    /// This prevents Tidy from misinterpreting UTF-8 multi-byte sequences.
    /// XMLDocument converts entities back to Unicode characters after parsing.
    private static func escapeNonASCII(_ html: String) -> String {
        var result = ""
        result.reserveCapacity(html.count)
        for scalar in html.unicodeScalars {
            if scalar.value > 127 {
                result += "&#x\(String(scalar.value, radix: 16));"
            } else {
                result += String(scalar)
            }
        }
        return result
    }

    private static func cleanupMarkdown(_ text: String) -> String {
        var cleaned = text
        // Remove empty fenced code blocks (```\n\n``` or ```\n```)
        cleaned = cleaned.replacingOccurrences(
            of: #"```\w*\s*```"#,
            with: "",
            options: .regularExpression
        )
        // Collapse 3+ newlines to 2
        while cleaned.contains("\n\n\n") {
            cleaned = cleaned.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - String helpers

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - HTML Visitor (used for clipboard RTF export only)

private struct HTMLVisitor: MarkupVisitor {
    typealias Result = String

    mutating func defaultVisit(_ markup: any Markup) -> String {
        markup.children.map { visit($0) }.joined()
    }

    // MARK: Block-level

    mutating func visitDocument(_ document: Document) -> String {
        document.children.map { visit($0) }.joined()
    }

    mutating func visitParagraph(_ paragraph: Paragraph) -> String {
        "<p>" + paragraph.children.map { visit($0) }.joined() + "</p>\n"
    }

    mutating func visitHeading(_ heading: Heading) -> String {
        let level = min(heading.level, 6)
        let content = heading.children.map { visit($0) }.joined()
        return "<h\(level)>\(content)</h\(level)>\n"
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) -> String {
        "<blockquote>" + blockQuote.children.map { visit($0) }.joined() + "</blockquote>\n"
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) -> String {
        "<pre><code>" + escapeHTML(codeBlock.code) + "</code></pre>\n"
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) -> String {
        "<hr>\n"
    }

    // MARK: Lists

    mutating func visitUnorderedList(_ unorderedList: UnorderedList) -> String {
        "<ul>\n" + unorderedList.children.map { visit($0) }.joined() + "</ul>\n"
    }

    mutating func visitOrderedList(_ orderedList: OrderedList) -> String {
        "<ol>\n" + orderedList.children.map { visit($0) }.joined() + "</ol>\n"
    }

    mutating func visitListItem(_ listItem: ListItem) -> String {
        // Unwrap paragraphs inside list items to avoid <li><p>...</p></li>
        // which causes NSAttributedString to render double bullet markers.
        let content = listItem.children.map { child -> String in
            if let paragraph = child as? Paragraph {
                return paragraph.children.map { visit($0) }.joined()
            }
            return visit(child)
        }.joined()
        return "<li>\(content)</li>\n"
    }

    // MARK: Inline

    mutating func visitText(_ text: Markdown.Text) -> String {
        escapeHTML(text.string)
    }

    mutating func visitStrong(_ strong: Strong) -> String {
        "<strong>" + strong.children.map { visit($0) }.joined() + "</strong>"
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) -> String {
        "<em>" + emphasis.children.map { visit($0) }.joined() + "</em>"
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) -> String {
        "<code>" + escapeHTML(inlineCode.code) + "</code>"
    }

    mutating func visitLink(_ link: Markdown.Link) -> String {
        let href = link.destination ?? ""
        let content = link.children.map { visit($0) }.joined()
        return "<a href=\"\(escapeHTML(href))\">\(content)</a>"
    }

    mutating func visitImage(_ image: Markdown.Image) -> String {
        let src = image.source ?? ""
        let alt = image.children.map { visit($0) }.joined()

        // Inline local images as base64 data URIs for clipboard compatibility
        if src.hasPrefix("file://"),
           let url = URL(string: src),
           let data = try? Data(contentsOf: url) {
            let mime = mimeType(for: url.pathExtension)
            let base64 = data.base64EncodedString()
            return "<img src=\"data:\(mime);base64,\(base64)\" alt=\"\(escapeHTML(alt))\">"
        }

        return "<img src=\"\(escapeHTML(src))\" alt=\"\(escapeHTML(alt))\">"
    }

    mutating func visitSoftBreak(_ softBreak: SoftBreak) -> String {
        "\n"
    }

    mutating func visitLineBreak(_ lineBreak: LineBreak) -> String {
        "<br>\n"
    }

    // MARK: Helpers

    private func escapeHTML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private func mimeType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "webp": "image/webp"
        default: "image/png"
        }
    }
}
