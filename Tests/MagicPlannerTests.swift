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
        #expect(message.contains("placeholder: \"Write a message…\""))
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
