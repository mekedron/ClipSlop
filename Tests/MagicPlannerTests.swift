import Foundation
import Testing
@testable import ClipSlop

/// The fast-mode chip planner: pure prompt assembly, deterministic response
/// parsing, eligibility, provider resolution, and the async race against
/// its hard cap — all against mocks, no real APIs.
@Suite("Magic planner")
struct MagicPlannerTests {

    private func candidates() -> [MagicPlanner.Candidate] {
        [
            MagicPlanner.Candidate(id: "base.reply", summary: "Reply to what's on screen", intent: "reply"),
            MagicPlanner.Candidate(id: "base.write", summary: "Write from scratch", intent: "write"),
        ]
    }

    // MARK: - Eligibility

    @Test func eligibilityMatrix() {
        // The happy case: fast mode, grounded, ≥2 chips, planner enabled.
        #expect(MagicPlanner.isEligible(
            forceChips: false, contextBlind: false, candidateCount: 2, timeoutMs: 900
        ))
        // Forced chips (the always-ask hotkey) NEVER plans.
        #expect(!MagicPlanner.isEligible(
            forceChips: true, contextBlind: false, candidateCount: 2, timeoutMs: 900
        ))
        // Context-blind: nothing to reason from.
        #expect(!MagicPlanner.isEligible(
            forceChips: false, contextBlind: true, candidateCount: 2, timeoutMs: 900
        ))
        // A lone chip means the router wants a human confirmation.
        #expect(!MagicPlanner.isEligible(
            forceChips: false, contextBlind: false, candidateCount: 1, timeoutMs: 900
        ))
        // timeout 0 is the kill switch.
        #expect(!MagicPlanner.isEligible(
            forceChips: false, contextBlind: false, candidateCount: 2, timeoutMs: 0
        ))
    }

    // MARK: - Prompt assembly

    @Test func promptCarriesSituationAndCandidates() {
        let snapshot = MagicTestSupport.makeSnapshot(
            bundleId: "com.google.Chrome",
            appName: "Chrome",
            url: "https://www.linkedin.com/messaging/thread/42",
            placeholder: "Write a message…",
            surroundingContent: "Anna: Are you coming to the meetup tomorrow?"
        )
        let message = MagicPlanner.buildUserMessage(snapshot: snapshot, candidates: candidates())

        #expect(message.contains("APP: Chrome (com.google.Chrome)"))
        #expect(message.contains("URL HOST: linkedin.com"))
        #expect(message.contains("FIELD: empty"))
        // The placeholder is page-controlled, so it is fenced as untrusted
        // rather than inlined into the trusted FIELD line.
        #expect(message.contains("FIELD PLACEHOLDER (untrusted data"))
        #expect(message.contains("Write a message…"))
        #expect(!message.contains("placeholder: \"Write a message…\""))
        #expect(message.contains("- base.reply — Reply to what's on screen (intent: reply)"))
        #expect(message.contains("- base.write — Write from scratch (intent: write)"))
        #expect(message.contains("Anna: Are you coming"))
        #expect(message.contains("untrusted data"))
        #expect(message.contains("Answer with exactly one candidate id, or UNSURE."))
        // Never the full URL — host only, same rule as the traces.
        #expect(!message.contains("/messaging/thread/42"))
    }

    @Test func promptCapsTheSurroundingsExcerpt() {
        let huge = String(repeating: "word ", count: 5_000)  // ~6250 tokens
        let snapshot = MagicTestSupport.makeSnapshot(surroundingContent: huge)
        let message = MagicPlanner.buildUserMessage(snapshot: snapshot, candidates: candidates())

        #expect(message.contains(PromptAssembler.truncationMarker))
        // The whole message stays tiny: caps are 300 (surroundings) + 120
        // (field) tokens plus fixed scaffolding.
        #expect(TokenEstimator.estimate(message) < 600)
    }

    @Test func promptSurroundingsExcerptKeepsTheTail() {
        // Top-to-bottom AX walk: the pending message is at the tail, the
        // head is sidebar noise. The planner must see the tail or it can
        // only ever answer UNSURE.
        let sidebar = String(repeating: "sidebar preview noise ", count: 500)
        let pending = "Derk: do you know when you can expect news?"
        let snapshot = MagicTestSupport.makeSnapshot(surroundingContent: sidebar + pending)
        let message = MagicPlanner.buildUserMessage(snapshot: snapshot, candidates: candidates())
        #expect(message.contains(pending))
        #expect(message.contains(PromptAssembler.truncationMarker))
    }

    @Test func promptRendersTreeSurroundingsWithChainAndMarker() {
        // A structured capture renders as the budgeted outline: the chain
        // line and the field marker survive the planner's 300-token cap
        // even when the tree itself is far bigger.
        let messages = (1...80).map {
            SurroundingNode(role: "AXStaticText", text: "MESSAGE-\($0) a chat line with some words in it")
        }
        let tree = SurroundingNode(role: "AXWebArea", label: "feed", children: [
            SurroundingNode(role: "AXGroup", label: "post by Priya Patel", children: [
                SurroundingNode(role: "AXList", label: "comments", children: messages + [
                    SurroundingNode(role: "AXTextArea", isField: true),
                ]),
            ]),
        ])
        let snapshot = MagicTestSupport.makeSnapshot(surroundingTree: tree)
        let message = MagicPlanner.buildUserMessage(snapshot: snapshot, candidates: candidates())

        #expect(message.contains("YOU ARE WRITING IN: feed › post by Priya Patel › comments"))
        #expect(message.contains(SurroundingTreeRenderer.fieldMarkerPrefix))
        // Nearest message survives, the oldest do not.
        #expect(message.contains("MESSAGE-80"))
        #expect(!message.contains("MESSAGE-1 "))
        // The whole planner prompt stays tiny (300 + 120 caps + scaffolding).
        #expect(TokenEstimator.estimate(message) < 600)
    }

    @Test func promptIncludesSelectionForTiePresses() {
        let selection = "перепиши это покороче please"
        let snapshot = MagicTestSupport.makeSnapshot(
            value: "some field text \(selection) trailing",
            selection: .init(range: nil, text: selection)
        )
        let message = MagicPlanner.buildUserMessage(snapshot: snapshot, candidates: candidates())
        #expect(message.contains("SELECTED TEXT"))
        #expect(message.contains(selection))
        #expect(message.contains("FIELD: selection"))
    }

    @Test func promptIncludesDraftTail() {
        let snapshot = MagicTestSupport.makeSnapshot(value: "Dear Anna, thanks for")
        let message = MagicPlanner.buildUserMessage(snapshot: snapshot, candidates: candidates())
        #expect(message.contains("THE USER'S DRAFT SO FAR"))
        #expect(message.contains("Dear Anna, thanks for"))
        #expect(message.contains("FIELD: draft"))
    }

    // MARK: - Response parsing

    @Test func parseAcceptsExactIDOnly() {
        let ids = ["base.reply", "base.write"]
        #expect(MagicPlanner.parse(response: "base.reply", candidateIDs: ids) == 0)
        #expect(MagicPlanner.parse(response: "base.write", candidateIDs: ids) == 1)
        // Forgiven wrapping: whitespace, quotes, backticks, trailing period.
        #expect(MagicPlanner.parse(response: "  base.reply\n", candidateIDs: ids) == 0)
        #expect(MagicPlanner.parse(response: "\"base.reply\"", candidateIDs: ids) == 0)
        #expect(MagicPlanner.parse(response: "`base.write`", candidateIDs: ids) == 1)
        #expect(MagicPlanner.parse(response: "base.reply.", candidateIDs: ids) == 0)
        // Everything else is unsure.
        #expect(MagicPlanner.parse(response: "UNSURE", candidateIDs: ids) == nil)
        #expect(MagicPlanner.parse(response: "unsure", candidateIDs: ids) == nil)
        #expect(MagicPlanner.parse(response: "I think base.reply fits best", candidateIDs: ids) == nil)
        #expect(MagicPlanner.parse(response: "base.rewrite", candidateIDs: ids) == nil)
        #expect(MagicPlanner.parse(response: "", candidateIDs: ids) == nil)
    }

    // MARK: - Provider resolution

    @Test func unboundPlannerInheritsGenerationResolution() {
        let generation = AIProviderConfig(name: "Premium", providerType: .anthropic, isDefault: true)
        let other = AIProviderConfig(name: "Other", providerType: .openAI)
        let resolved = MagicPlanner.resolveProvider(
            binding: RoleBinding(),
            generationProvider: generation,
            generationBinding: RoleBinding(),
            providers: [other, generation],
            noCloud: [], bundleId: "com.example.app", urlHost: nil
        )
        #expect(resolved?.id == generation.id)
    }

    @Test func boundPlannerUsesItsOwnProvider() {
        let generation = AIProviderConfig(name: "Premium", providerType: .anthropic, isDefault: true)
        let small = AIProviderConfig(name: "Small", providerType: .ollama)
        let resolved = MagicPlanner.resolveProvider(
            binding: RoleBinding(provider: small.id),
            generationProvider: generation,
            generationBinding: RoleBinding(),
            providers: [generation, small],
            noCloud: [], bundleId: nil, urlHost: nil
        )
        #expect(resolved?.id == small.id)
    }

    @Test func plannerRoleTimeoutIsStamped() {
        let generation = AIProviderConfig(name: "Premium", providerType: .anthropic, isDefault: true)
        let small = AIProviderConfig(name: "Small", providerType: .ollama)
        let resolved = MagicPlanner.resolveProvider(
            binding: RoleBinding(provider: small.id, timeoutSeconds: 5),
            generationProvider: generation,
            generationBinding: RoleBinding(),
            providers: [generation, small],
            noCloud: [], bundleId: nil, urlHost: nil
        )
        #expect(resolved?.requestTimeout == 5)
    }

    @Test func noCloudSurfaceSwapsToLocalOrSkips() {
        let cloud = AIProviderConfig(name: "Cloud", providerType: .anthropic, isDefault: true)
        let local = AIProviderConfig(name: "Local", providerType: .ollama)

        // A local provider anywhere in the list serves the no-cloud press.
        let swapped = MagicPlanner.resolveProvider(
            binding: RoleBinding(),
            generationProvider: cloud,
            generationBinding: RoleBinding(),
            providers: [cloud, local],
            noCloud: ["telegram"], bundleId: "ru.keepcoder.Telegram", urlHost: nil
        )
        #expect(swapped?.id == local.id)

        // No local provider → the planner is skipped (nil), never a refusal
        // of the whole press.
        let skipped = MagicPlanner.resolveProvider(
            binding: RoleBinding(),
            generationProvider: cloud,
            generationBinding: RoleBinding(),
            providers: [cloud],
            noCloud: ["telegram"], bundleId: "ru.keepcoder.Telegram", urlHost: nil
        )
        #expect(skipped == nil)
    }

    @Test func refusedResolutionSkipsPlanner() {
        // min_cost_class the chain cannot meet → nil, not a thrown refusal.
        let local = AIProviderConfig(name: "Local", providerType: .ollama, isDefault: true)
        let resolved = MagicPlanner.resolveProvider(
            binding: RoleBinding(provider: local.id, minCostClass: .premium),
            generationProvider: local,
            generationBinding: RoleBinding(),
            providers: [local],
            noCloud: [], bundleId: nil, urlHost: nil
        )
        #expect(resolved == nil)
    }

    // MARK: - The race

    private struct MockAIService: AIService {
        let delayMs: Int
        let result: @Sendable () throws -> AIGenerationResult

        func process(text: String, systemPrompt: String, config: AIProviderConfig) async throws -> String {
            try await processWithUsage(text: text, systemPrompt: systemPrompt, config: config).text
        }

        func stream(text: String, systemPrompt: String, config: AIProviderConfig) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { $0.finish() }
        }

        func processWithUsage(text: String, systemPrompt: String, config: AIProviderConfig) async throws -> AIGenerationResult {
            if delayMs > 0 {
                try await Task.sleep(for: .milliseconds(delayMs))
            }
            return try result()
        }
    }

    private var provider: AIProviderConfig {
        AIProviderConfig(name: "Mock", providerType: .anthropic, modelID: "mock-model")
    }

    @Test func confidentAnswerInTimeChooses() async {
        let service = MockAIService(delayMs: 0) {
            AIGenerationResult(text: "base.write", inputTokens: 120, outputTokens: 4)
        }
        let run = await MagicPlanner.run(
            snapshot: MagicTestSupport.makeSnapshot(surroundingContent: "thread"),
            candidates: candidates(), provider: provider, timeoutMs: 2_000, service: service
        )
        #expect(run.outcome == .chose(1))
        #expect(run.inputTokens == 120)
        #expect(run.outputTokens == 4)
        #expect(!run.usageEstimated)
    }

    @Test func unsureAnswerDeclines() async {
        let service = MockAIService(delayMs: 0) {
            AIGenerationResult(text: "UNSURE")
        }
        let run = await MagicPlanner.run(
            snapshot: MagicTestSupport.makeSnapshot(),
            candidates: candidates(), provider: provider, timeoutMs: 2_000, service: service
        )
        #expect(run.outcome == .unsure)
        // Usage still accounted (estimated) — the call completed.
        #expect(run.inputTokens != nil)
        #expect(run.usageEstimated)
    }

    @Test func slowAnswerTimesOut() async {
        let service = MockAIService(delayMs: 5_000) {
            AIGenerationResult(text: "base.reply")
        }
        let clock = ContinuousClock()
        let start = clock.now
        let run = await MagicPlanner.run(
            snapshot: MagicTestSupport.makeSnapshot(),
            candidates: candidates(), provider: provider, timeoutMs: 60, service: service
        )
        let elapsed = clock.now - start
        #expect(run.outcome == .timedOut)
        // Abandoned call: no spend to account.
        #expect(run.inputTokens == nil)
        #expect(run.outputTokens == nil)
        // The race honored the cap, not the mock's 5 s sleep.
        #expect(elapsed < .seconds(2))
    }

    /// A provider that ignores cancellation — the CLIToolService shape, where
    /// the wait is a subprocess and not a `Task.sleep`. `withTaskGroup` awaits
    /// its children even after `cancelAll()`, so the old race let such a
    /// provider hold `run` open long past `planner_timeout_ms`.
    private struct UncancellableAIService: AIService {
        let delayMs: Int

        func process(text: String, systemPrompt: String, config: AIProviderConfig) async throws -> String {
            try await processWithUsage(text: text, systemPrompt: systemPrompt, config: config).text
        }

        func stream(text: String, systemPrompt: String, config: AIProviderConfig) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { $0.finish() }
        }

        func processWithUsage(text: String, systemPrompt: String, config: AIProviderConfig) async throws -> AIGenerationResult {
            let delayMs = delayMs
            await withUnsafeContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(delayMs)) {
                    continuation.resume()
                }
            }
            return AIGenerationResult(text: "base.reply")
        }
    }

    @Test func capIsHardEvenWhenTheProviderIgnoresCancellation() async {
        let clock = ContinuousClock()
        let start = clock.now
        let run = await MagicPlanner.run(
            snapshot: MagicTestSupport.makeSnapshot(),
            candidates: candidates(), provider: provider, timeoutMs: 60,
            service: UncancellableAIService(delayMs: 3_000)
        )
        #expect(run.outcome == .timedOut)
        #expect(clock.now - start < .seconds(1))
    }

    /// Reports, from inside the in-flight provider call, whether that call was
    /// cancelled — the cap task's only externally visible act once it wakes.
    private actor CancellationWitness {
        private(set) var sawCancellation = false
        func record() { sawCancellation = true }
    }

    private struct WitnessedAIService: AIService {
        let delayMs: Int
        let witness: CancellationWitness

        func process(text: String, systemPrompt: String, config: AIProviderConfig) async throws -> String {
            try await processWithUsage(text: text, systemPrompt: systemPrompt, config: config).text
        }

        func stream(text: String, systemPrompt: String, config: AIProviderConfig) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { $0.finish() }
        }

        func processWithUsage(text: String, systemPrompt: String, config: AIProviderConfig) async throws -> AIGenerationResult {
            do {
                try await Task.sleep(for: .milliseconds(delayMs))
            } catch {
                await witness.record()
                throw error
            }
            return AIGenerationResult(text: "base.reply")
        }
    }

    @Test func theCapTaskDiesWithTheRaceItWasTiming() async {
        // The cap task used to be the one racer nobody could stop: it slept out
        // the whole `planner_timeout_ms` after the race had already been
        // settled — by the provider, by itself, or by the press cancelling —
        // and `run` returned leaving it behind, one per abandoned press, for up
        // to five seconds. Both of its late acts are no-ops against the
        // one-shot claim, so the leak has no behaviour of its own to assert on;
        // what the fix must not break is the pair of properties below, and the
        // second one is where handing the cap to the race can actually bite.

        // 1. The race is decided by the answer, not by the cap. A five-second
        //    cap over an instant answer must not show up in the wall clock, nor
        //    in the run's own timing.
        let clock = ContinuousClock()
        let start = clock.now
        let answered = await MagicPlanner.run(
            snapshot: MagicTestSupport.makeSnapshot(surroundingContent: "thread"),
            candidates: candidates(), provider: provider, timeoutMs: 5_000,
            service: MockAIService(delayMs: 0) {
                AIGenerationResult(text: "base.reply", inputTokens: 12, outputTokens: 1)
            }
        )
        #expect(answered.outcome == .chose(0))
        #expect(clock.now - start < .seconds(1))
        #expect(answered.ms < 1_000)

        // 2. The cap that DOES fire now cancels itself, from inside its own
        //    body, by settling the race — and must still go on to kill the
        //    provider call. That self-cancel is safe only because the cap is
        //    already past its single suspension point when it happens; get the
        //    ordering wrong and `planner_timeout_ms` silently stops ending the
        //    request, which is the whole point of a hard cap.
        let witness = CancellationWitness()
        let timedOut = await MagicPlanner.run(
            snapshot: MagicTestSupport.makeSnapshot(),
            candidates: candidates(), provider: provider, timeoutMs: 60,
            service: WitnessedAIService(delayMs: 5_000, witness: witness)
        )
        #expect(timedOut.outcome == .timedOut)
        // The cancel reaches the call just after `run` returns, so poll for it
        // — but only for a second, far short of the mock's own 5 s answer, so
        // the flag can only mean a real cancellation.
        var sawCancellation = false
        let pollStart = clock.now
        while clock.now - pollStart < .seconds(1) {
            if await witness.sawCancellation {
                sawCancellation = true
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(sawCancellation)
    }

    @Test func serviceErrorFailsSoftly() async {
        let service = MockAIService(delayMs: 0) {
            throw AIServiceError.emptyResponse
        }
        let run = await MagicPlanner.run(
            snapshot: MagicTestSupport.makeSnapshot(),
            candidates: candidates(), provider: provider, timeoutMs: 2_000, service: service
        )
        #expect(run.outcome == .failed)
        #expect(run.inputTokens == nil)
    }

    // MARK: - Cancellation

    @Test func cancellingThePressEndsTheCallInsteadOfWaitingOutTheCap() async {
        // The human outraced the planner, so `MagicPressCoordinator` cancels
        // `plannerTask`. Unstructured tasks do not inherit cancellation and
        // `withCheckedContinuation` is not a cancellation point, so that cancel
        // used to do nothing at all: the request stayed in flight and `run`
        // only came back when the cap fired, up to `planner_timeout_ms` later.
        let clock = ContinuousClock()
        let start = clock.now
        let task = Task { () -> MagicPlanner.Run in
            await MagicPlanner.run(
                snapshot: MagicTestSupport.makeSnapshot(),
                candidates: candidates(), provider: provider, timeoutMs: 5_000,
                service: MockAIService(delayMs: 5_000) { AIGenerationResult(text: "base.reply") }
            )
        }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let run = await task.value

        #expect(run.outcome == .failed)
        // Nothing completed, so nothing is billable.
        #expect(run.billableUsage == nil)
        // Returned on the cancel, not on the 5 s cap.
        #expect(clock.now - start < .seconds(1))
    }

    @Test func aPressCancelledBeforeTheCallStartsNeverHangs() async {
        // `withTaskCancellationHandler` runs its handler *before* the operation
        // when the task enters already cancelled, so the cancel arrives before
        // there is any continuation to resume. Unless that is latched, the body
        // parks a continuation nobody is left to resume and the press hangs
        // forever in `.planning`.
        let task = Task { () -> MagicPlanner.Run in
            // The only way out of this sleep is the cancel below, so `run` is
            // always entered with cancellation already pending — no timing
            // assumption, and the test never actually waits ten seconds.
            try? await Task.sleep(for: .seconds(10))
            return await MagicPlanner.run(
                snapshot: MagicTestSupport.makeSnapshot(),
                candidates: candidates(), provider: provider, timeoutMs: 5_000,
                service: MockAIService(delayMs: 0) { AIGenerationResult(text: "base.reply") }
            )
        }
        task.cancel()
        let run = await task.value

        #expect(run.outcome == .failed)
        #expect(run.billableUsage == nil)
    }

    // MARK: - Spend accounting

    @Test func onlyCompletedCallsAreBillable() async {
        // Reported usage is billed verbatim.
        let reported = await MagicPlanner.run(
            snapshot: MagicTestSupport.makeSnapshot(),
            candidates: candidates(), provider: provider, timeoutMs: 2_000,
            service: MockAIService(delayMs: 0) {
                AIGenerationResult(text: "base.write", inputTokens: 120, outputTokens: 4)
            }
        )
        #expect(reported.billableUsage
            == MagicPlanner.Usage(inputTokens: 120, outputTokens: 4, estimated: false))

        // A provider that reports no usage still spent tokens — estimated,
        // never dropped. UNSURE is an answer, and answers cost money.
        let estimated = await MagicPlanner.run(
            snapshot: MagicTestSupport.makeSnapshot(),
            candidates: candidates(), provider: provider, timeoutMs: 2_000,
            service: MockAIService(delayMs: 0) { AIGenerationResult(text: "UNSURE") }
        )
        #expect(estimated.outcome == .unsure)
        #expect(estimated.billableUsage?.estimated == true)
        #expect((estimated.billableUsage?.inputTokens ?? 0) > 0)

        // Abandoned at the cap: nothing came back, so there is nothing to
        // account — the ledger must not grow a row for it.
        let timedOut = await MagicPlanner.run(
            snapshot: MagicTestSupport.makeSnapshot(),
            candidates: candidates(), provider: provider, timeoutMs: 60,
            service: MockAIService(delayMs: 5_000) { AIGenerationResult(text: "base.reply") }
        )
        #expect(timedOut.outcome == .timedOut)
        #expect(timedOut.billableUsage == nil)

        // A failed call is abandoned by the same rule.
        let failed = await MagicPlanner.run(
            snapshot: MagicTestSupport.makeSnapshot(),
            candidates: candidates(), provider: provider, timeoutMs: 2_000,
            service: MockAIService(delayMs: 0) { throw AIServiceError.emptyResponse }
        )
        #expect(failed.outcome == .failed)
        #expect(failed.billableUsage == nil)
    }

    @Test func completedRunStillBillsAfterThePressMovedOn() async {
        // The leak this guards: the planner answered, and only *then* did a
        // human chip pick cancel the press. `finishPlanner` — the sole owner of
        // the ledger append — sits behind a `guard !Task.isCancelled`, so those
        // tokens were paid for and never recorded, and `spend_summary`
        // under-reported real spend by however often the user out-clicks the
        // planner. The spend now rides the run itself, ahead of that guard, so
        // the value the coordinator bills from must survive the abandonment.
        let answered = AsyncStream<Void>.makeStream()
        let plannerTask = Task { () -> MagicPlanner.Run in
            let run = await MagicPlanner.run(
                snapshot: MagicTestSupport.makeSnapshot(surroundingContent: "thread"),
                candidates: candidates(), provider: provider, timeoutMs: 2_000,
                service: MockAIService(delayMs: 0) {
                    AIGenerationResult(text: "base.reply", inputTokens: 88, outputTokens: 2)
                }
            )
            answered.continuation.finish()
            // Park until the press cancels us — this is the window between the
            // answer landing and the routing decision being taken.
            try? await Task.sleep(for: .seconds(10))
            return run
        }
        for await _ in answered.stream {}
        plannerTask.cancel()
        let run = await plannerTask.value

        #expect(run.outcome == .chose(0))
        #expect(run.billableUsage
            == MagicPlanner.Usage(inputTokens: 88, outputTokens: 2, estimated: false))
    }

    @Test func outOfRangeIndexIsImpossibleByParsing() {
        // parse() can only return indices into candidateIDs — the coordinator's
        // extra bounds check is belt-and-braces, not load-bearing.
        let ids = candidates().map(\.id)
        for response in ["base.reply", "base.write", "nonsense"] {
            if let index = MagicPlanner.parse(response: response, candidateIDs: ids) {
                #expect(index < ids.count)
            }
        }
    }

    // MARK: - Config knob

    @Test func plannerTimeoutKeyParsesAndClamps() {
        #expect(MagicEngineConfig.default.plannerTimeoutMs == 900, "planner must be ON out of the box")

        let off = MagicEngineConfig.parse("---\nplanner_timeout_ms: 0\n---")
        #expect(off.config.plannerTimeoutMs == 0)
        #expect(off.warnings.isEmpty)

        let clamped = MagicEngineConfig.parse("---\nplanner_timeout_ms: 99999\n---")
        #expect(clamped.config.plannerTimeoutMs == 5_000)
        #expect(!clamped.warnings.isEmpty)

        #expect(EngineSeedContent.engineConfig.contains("planner_timeout_ms: 900"))
    }

    @Test func candidateFromWorkflowUsesCardIdentity() {
        let workflow = MagicTestSupport.makeWorkflow(
            id: "base.reply", summary: "Reply to what's on screen", intents: ["reply", "answer"]
        )
        let candidate = MagicPlanner.Candidate(workflow: workflow)
        #expect(candidate.id == "base.reply")
        #expect(candidate.summary == "Reply to what's on screen")
        #expect(candidate.intent == "reply")
    }
}
