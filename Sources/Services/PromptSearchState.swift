import Foundation

/// One scored hit in the prompt-search result list.
struct PromptSearchResult: Identifiable, Hashable {
    let node: PromptNode
    let path: [String]
    let score: Int
    var id: UUID { node.id }
}

/// Drives the "/" prompt-search overlay: tracks query, selection, and computes
/// scored matches across every prompt in the library. Mirrors the FindBarState
/// shape (isVisible/searchQuery/focusToken) so the two search experiences feel
/// consistent.
@MainActor
@Observable
final class PromptSearchState {
    var isActive = false
    var query = "" {
        didSet { selectedIndex = 0 }
    }
    var selectedIndex = 0

    /// Incremented each time activate() runs so the SwiftUI view can re-focus
    /// its TextField even when isActive was already true.
    var focusToken = 0

    weak var promptStore: PromptStore?

    func activate() {
        if !isActive {
            query = ""
            selectedIndex = 0
        }
        isActive = true
        focusToken += 1
    }

    func deactivate() {
        isActive = false
        query = ""
        selectedIndex = 0
    }

    func selectNext() {
        let count = results.count
        guard count > 0 else { return }
        selectedIndex = min(clampedSelectedIndex + 1, count - 1)
    }

    func selectPrevious() {
        let count = results.count
        guard count > 0 else { return }
        selectedIndex = max(clampedSelectedIndex - 1, 0)
    }

    /// Safe accessor that always points inside `results` (or 0 when empty).
    var clampedSelectedIndex: Int {
        let count = results.count
        guard count > 0 else { return 0 }
        return min(max(selectedIndex, 0), count - 1)
    }

    func selectedNode() -> PromptNode? {
        let list = results
        guard !list.isEmpty else { return nil }
        return list[clampedSelectedIndex].node
    }

    /// Scored, filtered, sorted result list. Pure function of `promptStore` +
    /// `query`; SwiftUI re-renders whenever either changes.
    var results: [PromptSearchResult] {
        guard let store = promptStore else { return [] }
        let pairs = store.allPromptNodesWithPaths()
        let tokens = Self.tokenize(query)

        if tokens.isEmpty {
            return pairs
                .map { PromptSearchResult(node: $0.node, path: $0.path, score: 1) }
                .sorted { lhs, rhs in
                    lhs.node.name.localizedCaseInsensitiveCompare(rhs.node.name) == .orderedAscending
                }
        }

        var scored: [PromptSearchResult] = []
        scored.reserveCapacity(pairs.count)
        for pair in pairs {
            if let score = Self.score(name: pair.node.name, path: pair.path, tokens: tokens) {
                scored.append(PromptSearchResult(node: pair.node, path: pair.path, score: score))
            }
        }
        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.node.name.localizedCaseInsensitiveCompare(rhs.node.name) == .orderedAscending
        }
        return scored
    }

    // MARK: - Scoring (pure functions, callable from any isolation context)

    nonisolated static func tokenize(_ query: String) -> [String] {
        query
            .split(whereSeparator: { $0.isWhitespace })
            .map { String($0) }
            .filter { !$0.isEmpty }
    }

    /// Returns `nil` when any token fails to match (excludes the prompt from
    /// the result list). Otherwise the cumulative score.
    nonisolated static func score(name: String, path: [String], tokens: [String]) -> Int? {
        let haystackName = name
        let haystackPath = path.joined(separator: " / ")
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

        var total = 0
        for token in tokens {
            let nameRange = haystackName.range(of: token, options: opts)
            let pathRange = haystackPath.range(of: token, options: opts)

            if nameRange == nil && pathRange == nil {
                return nil
            }

            if let range = nameRange {
                total += token.count * 10
                if isAtWordStart(in: haystackName, range: range) {
                    total += 5
                }
            } else if let range = pathRange {
                total += token.count * 3
                if isAtWordStart(in: haystackPath, range: range) {
                    total += 1
                }
            }
        }
        return total
    }

    nonisolated private static func isAtWordStart(in string: String, range: Range<String.Index>) -> Bool {
        if range.lowerBound == string.startIndex { return true }
        let prev = string.index(before: range.lowerBound)
        let ch = string[prev]
        return ch.isWhitespace || ch.isPunctuation || ch == "/"
    }
}
