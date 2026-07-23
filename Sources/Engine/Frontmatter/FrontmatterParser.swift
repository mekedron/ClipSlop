import Foundation

/// A parsed frontmatter value. The engine's schema is closed and shallow, so
/// the value tree is too: scalars, lists of scalars, and maps whose values are
/// scalars, lists, or one further map level (used by `when:`).
enum FrontmatterValue: Sendable, Equatable {
    case scalar(String)
    case list([String])
    case map([String: FrontmatterValue])
}

struct FrontmatterDocument: Sendable {
    let fields: [String: FrontmatterValue]
    /// 1-based file line for each key ("when.url" for nested keys) — carried
    /// into validation errors so a hand-edited file fails with a location.
    let fieldLines: [String: Int]
    let body: String
}

struct FrontmatterError: Error, Sendable, Equatable {
    let line: Int
    let message: String
}

/// Parser for the deliberately small YAML subset the engine's workflow and
/// data files use: `key: value` scalars (optionally quoted), flow lists
/// `[a, b]`, flow maps `{k: v}`, one level of block nesting (two-space
/// indent), block lists of scalars (`- item`), and `#` comments.
///
/// Hand-rolled instead of a YAML dependency on purpose: the schema is closed,
/// the files are hand-edited so errors must carry line numbers and speak the
/// schema's language, and the app should not grow a C-library dependency to
/// read a dozen small files. Constructs outside the subset (anchors, multiline
/// scalars, deeper nesting) are rejected with an explicit message.
enum FrontmatterParser {
    static func parse(_ text: String) throws -> FrontmatterDocument {
        var lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            throw FrontmatterError(line: 1, message: "file must start with a '---' frontmatter fence")
        }
        lines.removeFirst()

        guard let closingIndex = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "---"
        }) else {
            throw FrontmatterError(line: lines.count + 1, message: "missing closing '---' fence")
        }

        let frontmatterLines = Array(lines[..<closingIndex])
        let body = lines[(closingIndex + 1)...].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var fields: [String: FrontmatterValue] = [:]
        var fieldLines: [String: Int] = [:]

        var index = 0
        while index < frontmatterLines.count {
            let rawLine = frontmatterLines[index]
            let fileLine = index + 2  // +1 for the opening fence, +1 for 1-basing
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                index += 1
                continue
            }
            if rawLine.first == " " {
                throw FrontmatterError(
                    line: fileLine,
                    message: "unexpected indented line — nested keys are only allowed directly under a 'key:' header"
                )
            }

            let (key, rest) = try splitKey(trimmed, line: fileLine)

            if rest.isEmpty {
                // Block form: nested map or block list on the following indented lines.
                let (value, consumed) = try parseBlock(
                    lines: frontmatterLines, startIndex: index + 1,
                    parentKey: key, fieldLines: &fieldLines
                )
                fields[key] = value
                fieldLines[key] = fileLine
                index += 1 + consumed
            } else {
                fields[key] = try parseInlineValue(rest, line: fileLine)
                fieldLines[key] = fileLine
                index += 1
            }
        }

        return FrontmatterDocument(fields: fields, fieldLines: fieldLines, body: body)
    }

    // MARK: - Block structures

    /// Parses the indented lines following a bare `key:` header. Returns the
    /// value and how many lines were consumed.
    private static func parseBlock(
        lines: [String],
        startIndex: Int,
        parentKey: String,
        fieldLines: inout [String: Int]
    ) throws -> (FrontmatterValue, Int) {
        var map: [String: FrontmatterValue] = [:]
        var listItems: [String] = []
        var consumed = 0
        var index = startIndex

        while index < lines.count {
            let rawLine = lines[index]
            let fileLine = index + 2
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                index += 1
                consumed += 1
                continue
            }
            guard rawLine.hasPrefix("  ") else { break }  // dedent ends the block

            if trimmed.hasPrefix("- ") {
                guard map.isEmpty else {
                    throw FrontmatterError(line: fileLine, message: "cannot mix '- item' entries with 'key: value' entries under '\(parentKey):'")
                }
                listItems.append(try parseScalar(String(trimmed.dropFirst(2)), line: fileLine))
            } else {
                guard listItems.isEmpty else {
                    throw FrontmatterError(line: fileLine, message: "cannot mix 'key: value' entries with '- item' entries under '\(parentKey):'")
                }
                let (key, rest) = try splitKey(trimmed, line: fileLine)
                guard !rest.isEmpty else {
                    throw FrontmatterError(
                        line: fileLine,
                        message: "'\(parentKey).\(key)' has no value — only one level of block nesting is supported"
                    )
                }
                map[key] = try parseInlineValue(rest, line: fileLine)
                fieldLines["\(parentKey).\(key)"] = fileLine
            }
            index += 1
            consumed += 1
        }

        if map.isEmpty && listItems.isEmpty {
            throw FrontmatterError(line: startIndex + 1, message: "'\(parentKey):' has no value")
        }
        return (listItems.isEmpty ? .map(map) : .list(listItems), consumed)
    }

    // MARK: - Inline values

    private static func parseInlineValue(_ raw: String, line: Int) throws -> FrontmatterValue {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("[") {
            guard trimmed.hasSuffix("]") else {
                throw FrontmatterError(line: line, message: "flow list is missing its closing ']'")
            }
            let inner = String(trimmed.dropFirst().dropLast())
            let items = try splitFlowItems(inner, line: line).map { try parseScalar($0, line: line) }
            return .list(items.filter { !$0.isEmpty })
        }
        if trimmed.hasPrefix("{") {
            guard trimmed.hasSuffix("}") else {
                throw FrontmatterError(line: line, message: "flow map is missing its closing '}'")
            }
            let inner = String(trimmed.dropFirst().dropLast())
            var map: [String: FrontmatterValue] = [:]
            for item in try splitFlowItems(inner, line: line) where !item.isEmpty {
                let (key, rest) = try splitKey(item, line: line)
                guard !rest.isEmpty else {
                    throw FrontmatterError(line: line, message: "flow map entry '\(key)' has no value")
                }
                map[key] = .scalar(try parseScalar(rest, line: line))
            }
            return .map(map)
        }
        return .scalar(try parseScalar(trimmed, line: line))
    }

    /// Splits `key: rest`. The key may contain dots (`field.role`).
    private static func splitKey(_ text: String, line: Int) throws -> (key: String, rest: String) {
        guard let colonIndex = text.firstIndex(of: ":") else {
            throw FrontmatterError(line: line, message: "expected 'key: value'")
        }
        let key = String(text[..<colonIndex]).trimmingCharacters(in: .whitespaces)
        let keyCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")
        guard !key.isEmpty, key.unicodeScalars.allSatisfy(keyCharacters.contains) else {
            throw FrontmatterError(line: line, message: "invalid key '\(key)'")
        }
        let rest = String(text[text.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
        return (key, rest)
    }

    /// Unquotes a scalar. Quoted values keep '#' verbatim; unquoted values
    /// have a trailing ` # comment` stripped. Double-quoted scalars process
    /// backslash escapes the way YAML does (`\\` → `\`, `\"` → `"`, `\n`,
    /// `\t`); single-quoted scalars are verbatim.
    private static func parseScalar(_ raw: String, line: Int) throws -> String {
        var text = raw.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("\"") || text.hasPrefix("'") {
            let quote = text.first!
            let processesEscapes = (quote == "\"")
            var content = ""
            var escaped = false
            var closed = false
            var index = text.index(after: text.startIndex)
            while index < text.endIndex {
                let character = text[index]
                index = text.index(after: index)
                if escaped {
                    switch character {
                    case "n": content.append("\n")
                    case "t": content.append("\t")
                    case "\\", "\"", "'": content.append(character)
                    default:
                        content.append("\\")
                        content.append(character)
                    }
                    escaped = false
                } else if processesEscapes && character == "\\" {
                    escaped = true
                } else if character == quote {
                    closed = true
                    break
                } else {
                    content.append(character)
                }
            }
            guard closed else {
                throw FrontmatterError(line: line, message: "unterminated quoted string")
            }
            let remainder = text[index...].trimmingCharacters(in: .whitespaces)
            guard remainder.isEmpty || remainder.hasPrefix("#") else {
                throw FrontmatterError(line: line, message: "unexpected text after closing quote")
            }
            return content
        }
        // Strip trailing comment on unquoted scalars (YAML requires the space).
        if let range = text.range(of: " #") {
            text = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        if text.hasPrefix("&") || text.hasPrefix("*") || text == "|" || text == ">" {
            throw FrontmatterError(
                line: line,
                message: "YAML anchors, aliases, and multiline scalars are outside the supported subset"
            )
        }
        return text
    }

    /// Splits flow-collection items on top-level commas, honoring quotes
    /// (including backslash-escaped quotes inside double-quoted items).
    private static func splitFlowItems(_ text: String, line: Int) throws -> [String] {
        var items: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false

        for character in text {
            if let activeQuote = quote {
                current.append(character)
                if escaped {
                    escaped = false
                } else if activeQuote == "\"" && character == "\\" {
                    escaped = true
                } else if character == activeQuote {
                    quote = nil
                }
            } else if character == "\"" || character == "'" {
                current.append(character)
                quote = character
            } else if character == "," {
                items.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        if quote != nil {
            throw FrontmatterError(line: line, message: "unterminated quoted string in flow collection")
        }
        items.append(current.trimmingCharacters(in: .whitespaces))
        return items
    }
}
