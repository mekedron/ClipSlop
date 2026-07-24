import Foundation
import NaturalLanguage

struct VerifierWarning: Sendable, Codable, Equatable {
    /// `CaseIterable` so the Agent Skill drift tests can assert the bundled
    /// trace reference names every check id.
    enum Check: String, Sendable, Codable, CaseIterable {
        case language
        case length
        case constraints
        case concreteness
        case actionableUngrounded
    }

    let check: Check
    /// Localizable.strings key; args are interpolated by the UI layer.
    let messageKey: String
    let messageArgs: [String]
}

struct VerifierVerdict: Sendable {
    let passed: Bool
    let warnings: [VerifierWarning]
    let elapsedMs: Double

    static let passedVerdict = VerifierVerdict(passed: true, warnings: [], elapsedMs: 0)
}

/// Pre-insert verification (§10.2): deterministic code only, no model call —
/// this is what preserves the one-LLM-call press path (P1) and the latency
/// SLO. Anything determinism can't catch (tone, subtly unsupported claims)
/// is a later milestone's async post-insert check.
enum DeterministicVerifier {
    static func verify(
        output: String,
        workflow: ResolvedWorkflow,
        prompt: AssembledPrompt,
        snapshot: MagicSnapshot,
        constraints: [ConstraintRule],
        outputMaxChars: Int
    ) -> VerifierVerdict {
        let clock = ContinuousClock()
        let start = clock.now
        var warnings: [VerifierWarning] = []

        warnings.append(contentsOf: languageWarnings(output: output, workflow: workflow, snapshot: snapshot))
        warnings.append(contentsOf: lengthWarnings(output: output, maxChars: outputMaxChars))
        warnings.append(contentsOf: constraintWarnings(output: output, constraints: constraints))
        warnings.append(contentsOf: concretenessWarnings(output: output, prompt: prompt))

        let elapsed = clock.now - start
        return VerifierVerdict(
            passed: warnings.isEmpty,
            warnings: warnings,
            elapsedMs: Double(elapsed.components.attoseconds) / 1e15
                + Double(elapsed.components.seconds) * 1000
        )
    }

    // MARK: - Language

    /// Warns only on a confident mismatch: both sides ≥ 20 characters and
    /// the recognizer ≥ 60% sure of each. For `match_context` the output is
    /// acceptable in the language of the surroundings **or** of the user's
    /// own field draft — continuing a Russian draft on an English page is a
    /// legitimate outcome (base.continue does exactly that), so only an
    /// output matching *neither* is a defect. A fixed lang compares against
    /// that language alone.
    static func languageWarnings(
        output: String, workflow: ResolvedWorkflow, snapshot: MagicSnapshot
    ) -> [VerifierWarning] {
        guard let outputLang = confidentLanguage(of: output) else { return [] }

        let accepted: [String]
        switch workflow.card.output.lang {
        case .fixed(let code):
            accepted = [code]
        case .matchContext:
            // Every plausible hypothesis of every reference counts: a mail
            // quote like "Hei Nikita, the tool works nicely…" reads as
            // Finnish-and-English at once, and an English reply to it is
            // not a defect. Only an output matching no hypothesis warns.
            accepted = [snapshot.surrounding?.content, snapshot.field?.value]
                .compactMap { $0 }
                .filter { $0.trimmingCharacters(in: .whitespacesAndNewlines).count >= 20 }
                .flatMap(plausibleLanguages(of:))
        }

        guard !accepted.isEmpty, !accepted.contains(outputLang) else { return [] }
        return [VerifierWarning(
            check: .language,
            messageKey: "magic.verifier.language_mismatch",
            messageArgs: [outputLang, accepted[0]]
        )]
    }

    /// All language hypotheses with ≥ 25% probability — tolerant on the
    /// reference side, where mixed-language context is normal.
    private static func plausibleLanguages(of text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 20 else { return [] }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        return recognizer.languageHypotheses(withMaximum: 4)
            .filter { $0.value >= 0.25 }
            .map { $0.key.rawValue }
    }

    private static func confidentLanguage(of text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 20 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        guard let language = recognizer.dominantLanguage,
              let confidence = recognizer.languageHypotheses(withMaximum: 3)[language],
              confidence >= 0.6
        else { return nil }
        return language.rawValue
    }

    // MARK: - Length

    /// `maxChars` is the resolved ceiling: the card's own `output.max_chars`
    /// or, absent that, config.yaml's `output_max_chars_default`.
    static func lengthWarnings(output: String, maxChars: Int) -> [VerifierWarning] {
        guard output.count > maxChars else { return [] }
        return [VerifierWarning(
            check: .length,
            messageKey: "magic.verifier.too_long",
            messageArgs: [String(output.count), String(maxChars)]
        )]
    }

    // MARK: - Constraints

    static func constraintWarnings(output: String, constraints: [ConstraintRule]) -> [VerifierWarning] {
        var warnings: [VerifierWarning] = []
        for rule in constraints {
            let hit: Bool
            switch rule.kind {
            case .phrase:
                hit = output.range(
                    of: rule.pattern, options: [.caseInsensitive, .diacriticInsensitive]
                ) != nil
            case .regex:
                guard let regex = try? NSRegularExpression(pattern: rule.pattern, options: [.caseInsensitive]) else { continue }
                hit = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)) != nil
            }
            if hit {
                warnings.append(VerifierWarning(
                    check: .constraints,
                    messageKey: "magic.verifier.constraint_hit",
                    messageArgs: [rule.pattern, String(rule.sourceLine)]
                ))
            }
        }
        return warnings
    }

    // MARK: - Concreteness by matching (§10.2)

    enum TokenClass: String, Sendable {
        case number, money, iban, date, properName, email, phone

        /// Actionable data — amounts, payment coordinates, commitments —
        /// must be grounded in *trusted* context; a hostile thread must not
        /// silently ground a reply that confirms a transfer.
        var isActionable: Bool {
            switch self {
            case .money, .iban, .email, .phone: true
            case .number, .date, .properName: false
            }
        }
    }

    struct ConcreteToken: Sendable, Equatable {
        let text: String
        let tokenClass: TokenClass
        /// True when the token's neighborhood in the output reads as a
        /// commitment (pay/send/meet…), which upgrades dates to actionable.
        let nearCommitment: Bool
    }

    static func concretenessWarnings(output: String, prompt: AssembledPrompt) -> [VerifierWarning] {
        let trustedNormalized = Normalized(prompt.trustedContext)
        let untrustedNormalized = Normalized(prompt.untrustedContext)

        var warnings: [VerifierWarning] = []
        var reported = Set<String>()

        for token in extractTokens(from: output) {
            guard reported.insert(token.text).inserted else { continue }

            let inTrusted = grounded(token, in: trustedNormalized)
            let inUntrusted = grounded(token, in: untrustedNormalized)
            let actionable = token.tokenClass.isActionable
                || (token.tokenClass == .date && token.nearCommitment)

            if !inTrusted && !inUntrusted {
                warnings.append(VerifierWarning(
                    check: .concreteness,
                    messageKey: "magic.verifier.ungrounded",
                    messageArgs: [token.text]
                ))
            } else if !inTrusted && inUntrusted && actionable {
                // Referential mentions (a name, a figure from the post) pass —
                // replying to what's on screen is the product. Actionable data
                // grounded only by screen content warns.
                warnings.append(VerifierWarning(
                    check: .actionableUngrounded,
                    messageKey: "magic.verifier.actionable_untrusted",
                    messageArgs: [token.text]
                ))
            }
        }
        return warnings
    }

    // MARK: Token extraction

    // Precompiled once; NSRegularExpression is Sendable.
    private static let ibanRegex =
        try! NSRegularExpression(pattern: #"\b[A-Z]{2}\d{2}(?: ?[A-Z0-9]{2,4}){3,8}\b"#)
    private static let emailRegex =
        try! NSRegularExpression(pattern: #"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b"#)
    private static let moneyRegex =
        try! NSRegularExpression(pattern: #"(?:[€$£]\s?\d[\d\s.,]*\d|[€$£]\s?\d|\d[\d\s.,]*\s?(?:€|\$|£|EUR|USD|GBP|руб|₽|kr|snt)\b)"#)
    private static let phoneRegex =
        try! NSRegularExpression(pattern: #"\+\d[\d\s()\-]{6,}\d"#)
    private static let numericDateRegex =
        try! NSRegularExpression(pattern: #"\b\d{1,2}[./]\d{1,2}[./]\d{2,4}\b"#)
    private static let bigNumberRegex =
        try! NSRegularExpression(pattern: #"\b\d{3,}(?:[.,]\d+)?\b"#)
    private static let properNameRegex =
        try! NSRegularExpression(pattern: #"\p{Lu}\p{Ll}+ \p{Lu}\p{Ll}+"#)

    private static let monthNames: Set<String> = [
        "january", "february", "march", "april", "may", "june", "july",
        "august", "september", "october", "november", "december",
        "января", "февраля", "марта", "апреля", "мая", "июня", "июля",
        "августа", "сентября", "октября", "ноября", "декабря",
        "tammikuuta", "helmikuuta", "maaliskuuta", "huhtikuuta", "toukokuuta",
        "kesäkuuta", "heinäkuuta", "elokuuta", "syyskuuta", "lokakuuta",
        "marraskuuta", "joulukuuta",
    ]

    private static let commitmentMarkers: [String] = [
        "pay", "send", "wire", "transfer", "meet", "deliver", "deadline", "by ",
        "заплач", "оплач", "отправ", "перевед", "переведу", "встрет", "до ",
        "maksa", "lähet", "siirr", "tavata", "mennessä",
    ]

    static func extractTokens(from output: String) -> [ConcreteToken] {
        var tokens: [ConcreteToken] = []
        var claimedRanges: [NSRange] = []
        let fullRange = NSRange(output.startIndex..., in: output)

        func collect(_ regex: NSRegularExpression, as tokenClass: TokenClass, exclusive: Bool = true) {
            for match in regex.matches(in: output, range: fullRange) {
                if exclusive && claimedRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) {
                    continue
                }
                guard let range = Range(match.range, in: output) else { continue }
                let text = String(output[range])
                if exclusive { claimedRanges.append(match.range) }
                tokens.append(ConcreteToken(
                    text: text,
                    tokenClass: tokenClass,
                    nearCommitment: nearCommitment(in: output, around: range)
                ))
            }
        }

        // Order matters: specific classes claim their character ranges first
        // so a plain-number pass doesn't double-report an IBAN's digits.
        collect(ibanRegex, as: .iban)
        collect(emailRegex, as: .email)
        collect(phoneRegex, as: .phone)
        collect(moneyRegex, as: .money)
        collect(numericDateRegex, as: .date)
        collect(bigNumberRegex, as: .number)

        // Month-name dates ("May 15", "15 мая").
        let words = output.components(separatedBy: CharacterSet.whitespacesAndNewlines)
        for (index, word) in words.enumerated() {
            let cleaned = word.trimmingCharacters(in: .punctuationCharacters).lowercased()
            guard monthNames.contains(cleaned) else { continue }
            let neighbors = [words.indices.contains(index - 1) ? words[index - 1] : "",
                             words.indices.contains(index + 1) ? words[index + 1] : ""]
            if let day = neighbors.first(where: { Int($0.trimmingCharacters(in: .punctuationCharacters)) != nil }) {
                let text = "\(day.trimmingCharacters(in: .punctuationCharacters)) \(cleaned)"
                tokens.append(ConcreteToken(
                    text: text, tokenClass: .date,
                    nearCommitment: containsCommitmentMarker(output.lowercased())
                ))
            }
        }

        // Proper-name bigrams, skipping sentence-initial positions.
        for match in properNameRegex.matches(in: output, range: fullRange) {
            guard let range = Range(match.range, in: output) else { continue }
            if isSentenceInitial(range: range, in: output) { continue }
            tokens.append(ConcreteToken(
                text: String(output[range]), tokenClass: .properName, nearCommitment: false
            ))
        }

        return tokens
    }

    private static func isSentenceInitial(range: Range<String.Index>, in text: String) -> Bool {
        var index = range.lowerBound
        while index > text.startIndex {
            index = text.index(before: index)
            let character = text[index]
            if character.isWhitespace { continue }
            return character == "." || character == "!" || character == "?" || character == "\n" || character == "…"
        }
        return true  // start of output
    }

    private static func nearCommitment(in text: String, around range: Range<String.Index>) -> Bool {
        let start = text.index(range.lowerBound, offsetBy: -60, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: 60, limitedBy: text.endIndex) ?? text.endIndex
        return containsCommitmentMarker(String(text[start..<end]).lowercased())
    }

    private static func containsCommitmentMarker(_ lowercased: String) -> Bool {
        commitmentMarkers.contains { lowercased.contains($0) }
    }

    // MARK: Grounding

    /// Pre-normalized context: lowercase/diacritic-folded text for name and
    /// email matching, digits-only stream for numeric matching (so "5 000 €"
    /// grounds "5000€" and a spaced IBAN grounds a compact one).
    struct Normalized {
        let folded: String
        let digits: String

        init(_ text: String) {
            folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            digits = String(text.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) })
        }
    }

    private static func grounded(_ token: ConcreteToken, in context: Normalized) -> Bool {
        switch token.tokenClass {
        case .number, .money, .iban, .phone, .date:
            let tokenDigits = String(token.text.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) })
            guard !tokenDigits.isEmpty else { return true }
            return context.digits.contains(tokenDigits)
        case .properName, .email:
            let folded = token.text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            return context.folded.contains(folded)
        }
    }
}
