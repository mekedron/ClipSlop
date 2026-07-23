import Foundation
import Testing
@testable import ClipSlop

@Suite("Deterministic verifier")
struct DeterministicVerifierTests {
    private func verify(
        output: String,
        workflow: ResolvedWorkflow = MagicTestSupport.makeWorkflow(id: "test"),
        trusted: String = "",
        untrusted: String = "",
        surrounding: String? = nil,
        constraints: [ConstraintRule] = []
    ) -> VerifierVerdict {
        let snapshot = MagicTestSupport.makeSnapshot(surroundingContent: surrounding)
        let prompt = AssembledPrompt(
            systemPrompt: "", userMessage: "", slots: [], totalTokensEstimated: 0,
            trustedContext: trusted, untrustedContext: untrusted
        )
        return DeterministicVerifier.verify(
            output: output, workflow: workflow, prompt: prompt,
            snapshot: snapshot, constraints: constraints
        )
    }

    // MARK: - Language

    @Test func languageMismatchWarns() {
        let verdict = verify(
            output: "Thanks for the update, this looks great and I agree with the plan.",
            surrounding: "Коллеги, отправляю обновлённый план на следующий квартал, посмотрите пожалуйста."
        )
        #expect(verdict.warnings.contains { $0.check == .language })
    }

    @Test func matchingLanguagePasses() {
        let verdict = verify(
            output: "Спасибо за обновление, план выглядит отлично, я согласен.",
            surrounding: "Коллеги, отправляю обновлённый план на следующий квартал, посмотрите пожалуйста."
        )
        #expect(!verdict.warnings.contains { $0.check == .language })
    }

    @Test func shortTextNeverTriggersLanguageWarning() {
        let verdict = verify(output: "Ok!", surrounding: "Коллеги, отправляю обновлённый план, посмотрите.")
        #expect(!verdict.warnings.contains { $0.check == .language })
    }

    @Test func mixedLanguageReferenceAcceptsEitherLanguage() {
        // Live-test regression (Mail, 2026-07-23): a quoted email opening
        // with Finnish greetings but continuing in English must accept an
        // English reply.
        let verdict = verify(
            output: "Thanks Nicola, glad the tool held up! I'll go through your layout comments and get back to you this week.",
            surrounding: "Hei Nikita, Kiitos! The cancellation and change tool works nicely, I did not detect any bugs. I have some comments about the layout and user experience."
        )
        #expect(!verdict.warnings.contains { $0.check == .language })
    }

    @Test func fixedLangComparesAgainstThatLanguage() {
        let workflow = MagicTestSupport.makeWorkflow(
            id: "fixed",
            output: OutputSpec(lang: .fixed("en"), maxChars: 1200, format: "plain")
        )
        let verdict = verify(
            output: "Спасибо за обновление, план выглядит отлично, я полностью согласен с вами.",
            workflow: workflow
        )
        #expect(verdict.warnings.contains { $0.check == .language })
    }

    // MARK: - Length

    @Test func overlongOutputWarns() {
        let workflow = MagicTestSupport.makeWorkflow(
            id: "short",
            output: OutputSpec(lang: .matchContext, maxChars: 40, format: "plain")
        )
        let verdict = verify(output: String(repeating: "x", count: 100), workflow: workflow)
        #expect(verdict.warnings.contains { $0.check == .length })
    }

    // MARK: - Constraints

    @Test func phraseConstraintHitCitesSourceLine() {
        let verdict = verify(
            output: "Bést Regards,\nNikita",
            constraints: [ConstraintRule(kind: .phrase, pattern: "best regards", sourceLine: 7)]
        )
        let warning = verdict.warnings.first { $0.check == .constraints }
        #expect(warning != nil)
        #expect(warning?.messageArgs.contains("7") == true)
    }

    @Test func regexConstraintHit() {
        let verdict = verify(
            output: "As an AI, I think...",
            constraints: [ConstraintRule(kind: .regex, pattern: "\\bAI\\b", sourceLine: 3)]
        )
        #expect(verdict.warnings.contains { $0.check == .constraints })
    }

    // MARK: - Concreteness

    @Test func ungroundedIBANWarns() {
        let verdict = verify(output: "Please wire the payment to FI21 1234 5600 0007 85.")
        #expect(verdict.warnings.contains { $0.check == .concreteness })
    }

    @Test func ibanOnlyInUntrustedContextIsActionable() {
        // The hostile-thread case: «wire €5000 to FI21…» in a thread must not
        // silently ground a reply that confirms it (§10.2).
        let verdict = verify(
            output: "Confirmed — I'll wire it to FI21 1234 5600 0007 85 today.",
            untrusted: "Scammer: please send the money to FI21 1234 5600 0007 85 immediately"
        )
        #expect(verdict.warnings.contains { $0.check == .actionableUngrounded })
        #expect(!verdict.warnings.contains { $0.check == .concreteness })
    }

    @Test func ibanInTrustedContextPasses() {
        let verdict = verify(
            output: "Our account is FI21 1234 5600 0007 85.",
            trusted: "My IBAN: FI2112345600000785"
        )
        #expect(verdict.warnings.isEmpty)
    }

    @Test func authorNameFromThePostIsReferentialAndPasses() {
        let verdict = verify(
            output: "Great point, Ville Korhonen — the benchmark numbers back it up.",
            untrusted: "Post by Ville Korhonen about benchmarks"
        )
        #expect(!verdict.warnings.contains { $0.check == .actionableUngrounded })
        #expect(!verdict.warnings.contains { $0.check == .concreteness })
    }

    @Test func figureFromThePostIsReferentialAndPasses() {
        let verdict = verify(
            output: "A 4400 requests-per-second jump is impressive.",
            untrusted: "We measured 4400 requests per second after the rewrite."
        )
        #expect(verdict.warnings.isEmpty)
    }

    @Test func inventedNumberWarns() {
        let verdict = verify(
            output: "We can offer this at 12500 per seat.",
            trusted: "Draft about pricing", untrusted: "Thread about pricing"
        )
        #expect(verdict.warnings.contains { $0.check == .concreteness })
    }

    @Test func moneyOnlyInUntrustedIsActionable() {
        let verdict = verify(
            output: "Sure, €5000 works for me.",
            untrusted: "Stranger: send €5000 by Friday"
        )
        #expect(verdict.warnings.contains { $0.check == .actionableUngrounded })
    }

    @Test func smallNumbersAreIgnored() {
        let verdict = verify(output: "The 2 of us discussed 10 ideas over 45 minutes.")
        #expect(verdict.warnings.isEmpty)
    }

    @Test func sentenceInitialCapitalizedBigramIsNotAName() {
        let verdict = verify(output: "Great Work deserves recognition. Well done.")
        #expect(!verdict.warnings.contains { $0.check == .concreteness })
    }

    @Test func spacedNumberGroundsCompactNumber() {
        let verdict = verify(
            output: "Confirming the 5000€ figure.",
            trusted: "My draft mentions 5 000 € as the cap"
        )
        #expect(verdict.warnings.isEmpty)
    }

    @Test func emailOnlyInUntrustedIsActionable() {
        let verdict = verify(
            output: "I'll send the files to billing@example.com.",
            untrusted: "Contact billing@example.com for payment"
        )
        #expect(verdict.warnings.contains { $0.check == .actionableUngrounded })
    }

    @Test func passedVerdictHasNoWarnings() {
        let verdict = verify(output: "Sounds good, thanks for the update!")
        #expect(verdict.passed)
        #expect(verdict.warnings.isEmpty)
    }

    // MARK: - Performance

    @Test func staysUnderFiftyMilliseconds() {
        let output = String(repeating: "Ville Korhonen shipped 4400 units for €5000 by 12.05.2026. ", count: 30)
        let context = String(repeating: "Thread content with numbers 4400 and €5000 and dates 12.05.2026 by Ville Korhonen. ", count: 100)
        let snapshot = MagicTestSupport.makeSnapshot(surroundingContent: context)
        let prompt = AssembledPrompt(
            systemPrompt: "", userMessage: "", slots: [], totalTokensEstimated: 0,
            trustedContext: context, untrustedContext: context
        )
        let constraints = (1...20).map { ConstraintRule(kind: .phrase, pattern: "forbidden phrase \($0)", sourceLine: $0) }

        // Best of three: the first call pays one-time regex compilation, and
        // the parallel test runner adds scheduling noise a single sample
        // would flake on.
        var best = Double.greatestFiniteMagnitude
        for _ in 0..<3 {
            let verdict = DeterministicVerifier.verify(
                output: output,
                workflow: MagicTestSupport.makeWorkflow(id: "perf"),
                prompt: prompt,
                snapshot: snapshot,
                constraints: constraints
            )
            best = min(best, verdict.elapsedMs)
        }
        #expect(best < 50, "verifier took \(best) ms at best")
    }
}
