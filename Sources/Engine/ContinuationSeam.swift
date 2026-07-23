import Foundation

/// Deterministic continuation seam. The continue workflows *ask* the model
/// to start with the space/punctuation the join needs, but models forget —
/// and `execute()` trims the response anyway, which would strip an obeyed
/// leading space. Code owns the seam: when pasting at a caret inside
/// existing text, decide in ~ten lines whether a joining space is needed
/// ("…is red." + "We need…" → "…is red. We need…").
enum ContinuationSeam {
    /// Applies only to the draft row (caret paste into a non-empty field).
    static func adjust(output: String, for snapshot: MagicSnapshot) -> String {
        guard snapshot.grammarRow == .draft, let field = snapshot.field else { return output }
        let value = field.value
        let prev: Character?
        if let range = field.selection?.range {
            let caret = min(max(0, range.lowerBound), value.count)
            prev = caret > 0 ? value[value.index(value.startIndex, offsetBy: caret - 1)] : nil
        } else {
            // No usable range (common on web fields): assume the caret sits
            // at the end — where people continue drafts from.
            prev = value.last
        }
        return join(output: output, afterPrecedingCharacter: prev)
    }

    /// Pure seam rule. A space is inserted only when both sides are "word
    /// material": the preceding character ends a word or a sentence, and
    /// the output starts a new word — never before glue punctuation
    /// ("…red" + ", so" stays fused), never after whitespace or an opening
    /// bracket/quote, and never between CJK characters (no spaces there).
    static func join(output: String, afterPrecedingCharacter prev: Character?) -> String {
        guard let prev, let first = output.first else { return output }
        guard !prev.isWhitespace, !prev.isNewline else { return output }
        if isOpening(prev) { return output }
        if isGlue(first) { return output }
        if isCJK(prev) && isCJK(first) { return output }

        let prevEndsWord = prev.isLetter || prev.isNumber || isClosing(prev)
        let firstStartsWord = first.isLetter || first.isNumber || isOpening(first) || first == "—" || first == "–"
        return prevEndsWord && firstStartsWord ? " " + output : output
    }

    private static func isOpening(_ c: Character) -> Bool {
        "([{«„“‘¿¡".contains(c)
    }

    /// Characters that end a clause/word and may be followed by a space.
    private static func isClosing(_ c: Character) -> Bool {
        ".,!?:;…)]}»”\"'’".contains(c)
    }

    /// Output-leading punctuation that must stay fused to the prior word.
    private static func isGlue(_ c: Character) -> Bool {
        ".,!?:;…)]}»”".contains(c)
    }

    private static func isCJK(_ c: Character) -> Bool {
        guard let scalar = c.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x2E80...0x9FFF,     // CJK radicals, ideographs
             0x3040...0x30FF,     // kana (inside the above range, kept for clarity)
             0xF900...0xFAFF,     // CJK compatibility ideographs
             0xFF00...0xFF60:     // fullwidth forms
            return true
        default:
            return false
        }
    }
}
