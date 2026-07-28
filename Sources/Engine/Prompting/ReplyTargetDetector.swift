import Foundation

/// Detects the reply-target mention threaded sites pre-fill into a comment
/// composer: pressing "Reply" on LinkedIn (and surfaces like it) puts the
/// target's display name — "Dave V ", "Oleksandr Malka " — into the field
/// before the user types anything. Framed as an ordinary draft, that name
/// reads as prose to continue and the model answers whatever text happens to
/// sit next to the field marker; framed as a target, it says exactly which
/// person's message the reply belongs to.
///
/// Pure and deterministic — no model call, so the one-call-per-press
/// principle (P1) holds. Fires only when BOTH gates pass:
///
/// 1. The field value is shaped like a bare person name (short, 2–5 words,
///    name casing, no sentence punctuation). A real draft fails on length,
///    casing, or punctuation.
/// 2. The exact name matches at least one text leaf in the captured tree —
///    a name the page itself displays. A short real draft ("ok sure",
///    "Sounds good") almost never equals a captured name leaf, and the
///    casing gate removes the rest; this is what keeps the detector from
///    misfiring on surfaces that do not pre-fill mentions.
///
/// The worst surviving false positive is a user who typed ONLY a name that
/// also appears on screen — in which case "reply to that person" is almost
/// certainly what they meant anyway.
enum ReplyTargetDetector {
    struct ReplyTarget: Sendable, Equatable {
        let name: String
        /// How many leaves matched. More than one means the person wrote
        /// several times (or their name also labels a profile link); the
        /// prompt then tells the model to answer their most recent message.
        let matchCount: Int
    }

    /// The annotation the renderer draws after a matching leaf.
    static let noteText = "LIKELY REPLY TARGET"

    private static let maxNameChars = 48
    /// Lowercase name particles that legitimately break the
    /// uppercase-initial rule mid-name ("Daniel van der Berg").
    private static let lowercaseParticles: Set<String> = [
        "van", "von", "der", "den", "ter", "ten", "de", "da", "di", "del",
        "dos", "das", "du", "la", "le", "el", "al", "bin", "ibn",
    ]

    /// Runs both gates and, when they pass, returns the target plus a copy
    /// of the tree with every matching leaf annotated. Nil = not a mention;
    /// the caller keeps the ordinary draft framing.
    static func detect(
        fieldValue: String, tree: SurroundingNode?
    ) -> (target: ReplyTarget, annotatedTree: SurroundingNode)? {
        guard let tree else { return nil }
        let name = fieldValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isNameShaped(name) else { return nil }
        var matchCount = 0
        let annotated = annotate(tree, name: name, matchCount: &matchCount)
        guard matchCount > 0 else { return nil }
        return (ReplyTarget(name: name, matchCount: matchCount), annotated)
    }

    /// Gate 1: could this string be a person's display name and nothing
    /// else? 2–5 words so bare interjections ("Thanks", "Ok") can never
    /// qualify; every word uppercase-initial (Unicode-aware) except known
    /// lowercase particles, which may not open or close the name; letters,
    /// `.`, `-` and apostrophes only — any digit or sentence punctuation is
    /// a draft, not a name.
    static func isNameShaped(_ candidate: String) -> Bool {
        guard !candidate.isEmpty, candidate.count <= maxNameChars,
              !candidate.contains("\n")
        else { return false }
        let words = candidate.split(separator: " ")
        guard (2...5).contains(words.count) else { return false }
        for (index, word) in words.enumerated() {
            for character in word {
                guard character.isLetter || character == "." || character == "-"
                        || character == "'" || character == "’"
                else { return false }
            }
            guard let first = word.first else { return false }
            if first.isUppercase { continue }
            let isEdge = index == 0 || index == words.count - 1
            guard !isEdge, lowercaseParticles.contains(word.lowercased()) else { return false }
        }
        return true
    }

    /// Gate 2 + annotation: a leaf matches when its text IS the name, or
    /// starts with the name followed by a non-letter ("Michael Long • 2nd").
    /// Exact case — the page pre-filled the mention from the same canonical
    /// name it displays. Prefix matching refuses a longer name that merely
    /// begins the same ("Dave Vernon" never matches "Dave V").
    private static func annotate(
        _ node: SurroundingNode, name: String, matchCount: inout Int
    ) -> SurroundingNode {
        var node = node
        if let text = node.text, leafMatches(text: text, name: name) {
            matchCount += 1
            node.note = noteText
        }
        node.children = node.children.map { annotate($0, name: name, matchCount: &matchCount) }
        return node
    }

    static func leafMatches(text: String, name: String) -> Bool {
        guard text.hasPrefix(name) else { return false }
        guard text.count > name.count else { return true }
        let boundary = text[text.index(text.startIndex, offsetBy: name.count)]
        return !boundary.isLetter
    }
}
