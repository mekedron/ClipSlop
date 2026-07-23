import Foundation

/// What a selected fragment *is* to the engine (§3.4): a directive about the
/// message, raw material to expand, or — the most common real seed — both.
enum SelectionClass: String, Sendable, Codable, CaseIterable {
    case instruction
    case material
    case mixed
}

struct SelectionClassification: Sendable, Equatable {
    /// Best first; always contains all three classes.
    let ranked: [SelectionClass]
    /// True when the margin was not decisive — the router denies the silent
    /// path and shows chips instead.
    let isTie: Bool
    let signals: Signals

    struct Signals: Sendable, Equatable {
        let leadingImperative: Bool
        let containsDeixis: Bool
        let charCount: Int
        let lineCount: Int
        let sentenceCount: Int
    }

    var top: SelectionClass { ranked[0] }
}

/// Deterministic, dictionary-based classification — 0 ms, no model (§3.4).
/// The classification only *ranks*; generation handles all three roles
/// uniformly. Dictionary coverage across RU/EN/FI is a tracked risk (R9);
/// logged chip corrections are the improvement dataset, not V0 code.
enum SelectionClassifier {
    /// First-token imperatives that mark a fragment as addressed to the
    /// engine. Lowercased; matched against the first word stripped of
    /// punctuation.
    static let imperatives: Set<String> = [
        // EN
        "write", "insert", "translate", "reply", "answer", "fix", "add",
        "make", "draft", "rewrite", "summarize", "summarise", "shorten",
        "expand", "explain", "list", "compose", "improve", "polish", "turn",
        // RU
        "напиши", "напишите", "вставь", "вставьте", "переведи", "переведите",
        "сделай", "сделайте", "ответь", "ответьте", "исправь", "исправьте",
        "добавь", "добавьте", "сократи", "сократите", "перепиши", "перепишите",
        "составь", "составьте", "объясни", "объясните", "расширь", "улучши",
        // FI
        "kirjoita", "lisää", "käännä", "vastaa", "korjaa", "tee", "laadi",
        "tiivistä", "selitä", "muotoile", "paranna", "lyhennä",
    ]

    /// Deictic markers ("here", "this letter") that point at the field or the
    /// surroundings — a strong instruction signal. Deliberately excludes
    /// spatial words that are common in ordinary prose ("above plan", "выше
    /// плана") — they produced false instruction/mixed signals.
    static let deixis: Set<String> = [
        // EN
        "here", "this", "these",
        // RU
        "сюда", "здесь", "это", "этот", "эту", "эти",
        // FI
        "tähän", "tässä", "tämä", "tämän", "nämä",
    ]

    static func classify(_ text: String) -> SelectionClassification {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }

        let firstWord = words.first ?? ""
        let leadingImperative = imperatives.contains(firstWord)
        let containsDeixis = !Set(words).isDisjoint(with: deixis)
        let charCount = trimmed.count
        let lineCount = max(1, trimmed.components(separatedBy: .newlines).filter {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }.count)
        let sentenceCount = countSentences(trimmed)

        var instructionScore = 0
        var materialScore = 0

        if leadingImperative { instructionScore += 3 }
        if containsDeixis { instructionScore += 2 }
        if charCount < 200 && lineCount == 1 { instructionScore += 1 }
        if charCount > 300 { materialScore += 2 }
        if sentenceCount >= 3 { materialScore += 1 }
        if !leadingImperative && charCount > 300 { materialScore += 1 }

        // The mixed seed («согласен + упомяни бенчмарки»): directive markers
        // coexisting with material bulk, or an explicit '+'-joined shape.
        let plusJoined = trimmed.contains(" + ") || trimmed.contains(" +")
        let hasMaterialBulk = charCount > 200 || sentenceCount >= 2 || lineCount > 1
        let mixedSignal = (leadingImperative || containsDeixis || plusJoined) && hasMaterialBulk

        let ranked: [SelectionClass]
        let isTie: Bool
        if mixedSignal {
            ranked = [.mixed, .instruction, .material]
            isTie = false
        } else if instructionScore > materialScore {
            ranked = [.instruction, .mixed, .material]
            isTie = false
        } else if materialScore > instructionScore {
            ranked = [.material, .mixed, .instruction]
            isTie = false
        } else {
            // Tie → instruction first: the wrong guess with undo is cheaper
            // than expanding a directive as if it were content (§3.4).
            ranked = [.instruction, .mixed, .material]
            isTie = true
        }

        return SelectionClassification(
            ranked: ranked,
            isTie: isTie,
            signals: .init(
                leadingImperative: leadingImperative,
                containsDeixis: containsDeixis,
                charCount: charCount,
                lineCount: lineCount,
                sentenceCount: sentenceCount
            )
        )
    }

    private static func countSentences(_ text: String) -> Int {
        var count = 0
        var previousWasTerminator = false
        for character in text {
            let isTerminator = character == "." || character == "!" || character == "?" || character == "…"
            if isTerminator && !previousWasTerminator { count += 1 }
            previousWasTerminator = isTerminator
        }
        // Trailing text without a terminator still counts as a sentence.
        if let last = text.unicodeScalars.last,
           !CharacterSet(charactersIn: ".!?…").contains(last) {
            count += 1
        }
        return max(1, count)
    }
}
