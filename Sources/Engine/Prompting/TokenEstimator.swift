import Foundation

/// chars/4 heuristic — no tokenizer dependency. It undercounts Cyrillic
/// (closer to 2.5 chars/token) and overcounts CJK; the slot budgets are
/// safety rails against runaway prompts, not billing, and carry deliberate
/// slack for exactly this error.
enum TokenEstimator {
    static func estimate(_ text: String) -> Int {
        text.isEmpty ? 0 : max(1, text.count / 4)
    }

    static func characterBudget(forTokens tokens: Int) -> Int {
        tokens * 4
    }
}
