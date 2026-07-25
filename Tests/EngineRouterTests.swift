import Testing
@testable import ClipSlop

@Suite("Engine router")
struct EngineRouterTests {
    // MARK: - Tier suppression and the silent rule, against the real seeds

    @Test func linkedInEmptyFieldIsSilentOnCommentSocial() throws {
        let decision = try MagicTestSupport.seedRoute(MagicTestSupport.makeSnapshot(
            bundleId: "com.google.Chrome",
            url: "https://www.linkedin.com/feed/update/urn:li:activity:123/",
            surroundingContent: "Ville Korhonen: We just shipped our new benchmark suite."
        ))
        #expect(decision.tier == .exact)
        #expect(decision.counted.map(\.id) == ["comment.social"])
        guard case .silent(let chosen) = decision.presentation else {
            Issue.record("expected silent, got chips")
            return
        }
        #expect(chosen.id == "comment.social")
        // base.* still available as chip alternatives, never counted.
        #expect(decision.alternatives.contains { $0.id.hasPrefix("base.") })
        #expect(decision.situationClass == "exact/linkedin.com/empty")
    }

    @Test func contextBlindPressAlwaysAsks() throws {
        // Same press as the silent LinkedIn case above, but with NOTHING
        // readable (a blind app or an unreadable page): even a confident
        // single candidate must ask — the model has no grounding (§15.3).
        let decision = try MagicTestSupport.seedRoute(MagicTestSupport.makeSnapshot(
            bundleId: "com.google.Chrome",
            url: "https://www.linkedin.com/feed/update/urn:li:activity:123/"
        ))
        #expect(decision.counted.map(\.id) == ["comment.social"])
        guard case .chips = decision.presentation else {
            Issue.record("blind press must show chips, not insert silently")
            return
        }
    }

    @Test func gmailEmptyFieldRoutesToReplyThreadWeb() throws {
        let decision = try MagicTestSupport.seedRoute(MagicTestSupport.makeSnapshot(
            bundleId: "com.apple.Safari",
            url: "https://mail.google.com/mail/u/0/#inbox/abc",
            surroundingContent: "Hi, could you send over the updated offer?"
        ))
        #expect(decision.counted.map(\.id) == ["reply.thread.web"])
        guard case .silent = decision.presentation else {
            Issue.record("expected silent")
            return
        }
    }

    @Test func nativeMailMatchesAtDomainTier() throws {
        let decision = try MagicTestSupport.seedRoute(MagicTestSupport.makeSnapshot(
            bundleId: "com.apple.mail",
            surroundingContent: "Thread content"
        ))
        #expect(decision.tier == .domain)
        #expect(decision.counted.map(\.id) == ["reply.thread"])
    }

    @Test func unknownAppEmptyFieldWithThreadShowsChipsReplyFirst() throws {
        let decision = try MagicTestSupport.seedRoute(MagicTestSupport.makeSnapshot(
            bundleId: "com.unknown.app",
            surroundingContent: "Someone: what do you think about this?"
        ))
        #expect(decision.tier == .base)
        // reply and write are genuinely different meanings → chips.
        guard case .chips(let ranked) = decision.presentation else {
            Issue.record("expected chips")
            return
        }
        #expect(ranked.first?.id == "base.reply")
        #expect(ranked.contains { $0.id == "base.write" })
    }

    @Test func unknownAppEmptyFieldWithoutContextRanksWriteFirst() throws {
        let decision = try MagicTestSupport.seedRoute(MagicTestSupport.makeSnapshot(
            bundleId: "com.unknown.app"
        ))
        guard case .chips(let ranked) = decision.presentation else {
            Issue.record("expected chips")
            return
        }
        #expect(ranked.first?.id == "base.write")
    }

    @Test func draftStateIsSilentViaIntentDedup() throws {
        // continue.draft and base.continue share the intent "continue":
        // ranking, not ambiguity — exactly one counted candidate → silent.
        let decision = try MagicTestSupport.seedRoute(MagicTestSupport.makeSnapshot(
            bundleId: "com.unknown.app",
            value: "Hei Ville, kiitos viestistä. Ajattelin että"
        ))
        #expect(decision.counted.map(\.id) == ["continue.draft"])
        guard case .silent(let chosen) = decision.presentation else {
            Issue.record("expected silent")
            return
        }
        #expect(chosen.id == "continue.draft")
        #expect(decision.alternatives.contains { $0.id == "base.continue" })
    }

    @Test func decisiveInstructionSelectionIsSilent() throws {
        let classification = SelectionClassifier.classify("напиши сюда вежливый отказ")
        let decision = try MagicTestSupport.seedRoute(
            MagicTestSupport.makeSnapshot(
                bundleId: "com.unknown.app",
                value: "Черновик письма. напиши сюда вежливый отказ",
                selection: .init(range: nil, text: "напиши сюда вежливый отказ")
            ),
            classification: classification
        )
        #expect(decision.counted.map(\.id) == ["instruct.selection"])
        guard case .silent = decision.presentation else {
            Issue.record("expected silent")
            return
        }
    }

    @Test func tieClassificationForcesChips() throws {
        let tieText = String(repeating: "word ", count: 50)
        let classification = SelectionClassifier.classify(tieText)
        #expect(classification.isTie)
        let decision = try MagicTestSupport.seedRoute(
            MagicTestSupport.makeSnapshot(
                bundleId: "com.unknown.app",
                value: tieText,
                selection: .init(range: nil, text: tieText)
            ),
            classification: classification
        )
        guard case .chips = decision.presentation else {
            Issue.record("expected chips on a classification tie")
            return
        }
    }

    @Test func materialSelectionAsksAdaptVersusRewrite() throws {
        let paragraph = """
        The quarterly numbers came in above plan again. Renewals held at 96 \
        percent and the enterprise pipeline doubled. The board asked for churn \
        analysis before pricing changes. The team wants to keep the course.
        """
        let classification = SelectionClassifier.classify(paragraph)
        #expect(classification.top == .material)
        let decision = try MagicTestSupport.seedRoute(
            MagicTestSupport.makeSnapshot(
                bundleId: "com.unknown.app",
                value: paragraph,
                selection: .init(range: nil, text: paragraph)
            ),
            classification: classification
        )
        // Since adapt.selection (§ user request 2026-07-24): a material
        // selection is a genuine two-way choice — fit the message to the
        // page's language/register, or restructure it — so both count and
        // chips ask, adapt first (priority 65 vs 60).
        #expect(decision.counted.map(\.id) == ["adapt.selection", "rewrite.selection"])
        guard case .chips = decision.presentation else {
            Issue.record("material selection should ask adapt-vs-rewrite")
            return
        }
    }

    // MARK: - Chip candidates and determinism

    @Test func chipsNeverShowTwoWorkflowsWithTheSameIntent() throws {
        // Live-test regression (2026-07-23): a tie on a short selection
        // showed "Do what my selection says" twice — instruct.selection and
        // its base.instruct parent share intent and summary.
        let tieText = "Я вернулся из отпуска и уже два дня в работе. Со следующей недели можно возобновить встречи."
        let classification = SelectionClassifier.classify(tieText)
        #expect(classification.isTie)
        let decision = try MagicTestSupport.seedRoute(
            MagicTestSupport.makeSnapshot(
                bundleId: "com.google.Chrome",
                value: tieText,
                selection: .init(range: nil, text: tieText)
            ),
            classification: classification
        )
        let chips = decision.chipCandidates
        let intents = chips.map { $0.card.intents.first ?? $0.id }
        #expect(Set(intents).count == chips.count, "duplicate intents in chips: \(chips.map(\.id))")
        let summaries = chips.compactMap(\.card.summary)
        #expect(Set(summaries).count == summaries.count, "identical chip labels: \(summaries)")
    }

    @Test func chipCandidatesAreCappedAtFourAndDistinct() throws {
        let decision = try MagicTestSupport.seedRoute(MagicTestSupport.makeSnapshot(
            bundleId: "com.unknown.app",
            surroundingContent: "context"
        ))
        let chips = decision.chipCandidates
        #expect(chips.count <= 4)
        #expect(Set(chips.map(\.id)).count == chips.count)
    }

    @Test func rankingIsDeterministic() throws {
        let snapshot = MagicTestSupport.makeSnapshot(
            bundleId: "com.unknown.app",
            surroundingContent: "context"
        )
        let first = try MagicTestSupport.seedRoute(snapshot)
        let second = try MagicTestSupport.seedRoute(snapshot)
        #expect(first.counted.map(\.id) == second.counted.map(\.id))
        #expect(first.alternatives.map(\.id) == second.alternatives.map(\.id))
    }

    // MARK: - Predicate details

    @Test func urlPredicateRequiresAURL() {
        let workflow = MagicTestSupport.makeWorkflow(
            id: "url.only",
            when: WhenPredicate(apps: nil, urlPattern: "example\\.com", fieldRoles: nil, fieldStates: nil, selectionClasses: nil)
        )
        // No URL in the snapshot → the predicate fails, never crashes.
        #expect(!EngineRouter.matchesWhen(
            workflow.card.when,
            snapshot: MagicTestSupport.makeSnapshot(url: nil),
            classification: nil
        ))
    }

    @Test func roleMatchingIsCaseInsensitive() {
        let when = WhenPredicate(
            apps: nil, urlPattern: nil,
            fieldRoles: ["axtextarea"], fieldStates: nil, selectionClasses: nil
        )
        #expect(EngineRouter.matchesWhen(
            when,
            snapshot: MagicTestSupport.makeSnapshot(role: "AXTextArea"),
            classification: nil
        ))
    }

    @Test func urlHostStripsWWW() {
        #expect(EngineRouter.urlHost(of: "https://www.linkedin.com/feed/") == "linkedin.com")
        #expect(EngineRouter.urlHost(of: "https://mail.google.com/mail") == "mail.google.com")
        #expect(EngineRouter.urlHost(of: nil) == nil)
    }
}
