import Foundation
import os

/// Everything a press needs, extracted on the main actor so the rest of the
/// pipeline can run off it (the `PromptRunner` plan/run pattern).
struct MagicPressPlan: Sendable {
    let catalog: WorkflowCatalog
    let core: CoreFileSet
    let provider: AIProviderConfig
    let workflowLoadErrors: [WorkflowLoadError]
    // Privacy binding inputs (§14, P7) — enforcement runs in `execute()`
    // where the snapshot (app/domain) is known.
    var roleBinding: RoleBinding = RoleBinding()
    var providers: [AIProviderConfig] = []
    var noCloud: [String] = []
    /// Output ceiling for cards without an explicit `output.max_chars`
    /// (config.yaml `output_max_chars_default`).
    var outputMaxCharsDefault: Int = MagicEngineConfig.default.outputMaxCharsDefault
    /// Token ceiling for the prompt's screen-context block
    /// (config.yaml `surrounding_max_tokens`, 0 = unlimited).
    var surroundingMaxTokens: Int = MagicEngineConfig.default.surroundingMaxTokens
    /// Fast-mode chip planner inputs (`MagicPlanner`): the `planner.magic`
    /// binding (empty = inherit the generation resolution) and the hard cap
    /// (0 = planner disabled).
    var plannerBinding: RoleBinding = RoleBinding()
    var plannerTimeoutMs: Int = MagicEngineConfig.default.plannerTimeoutMs
}

struct MagicPressResult: Sendable {
    /// Trimmed output, ready for the Inserter.
    let output: String
    let verdict: VerifierVerdict
    let assembled: AssembledPrompt
    /// Outcome unstamped — the press band records what actually happened
    /// (inserted / cancelled / insert-anyway…) and submits the trace once.
    let traceDraft: PressTrace
    /// Spend accounting (§14): reported usage, or chars/4 estimates
    /// flagged as such.
    let inputTokens: Int
    let outputTokens: Int
    let usageEstimated: Bool
}

/// Dry-run (§17): the full decision and assembly without executing anything.
struct DryRunReport: Codable, Sendable {
    let situationClass: String
    let tier: String
    let grammarRow: String
    let candidateIDs: [String]
    let alternativeIDs: [String]
    let presentation: String
    let chosenID: String?
    let workflowChain: [String]
    let slots: [AssembledSlot]
    let totalTokens: Int
    let providerName: String
    let modelID: String
    /// What the privacy binding (P7) would do with this surface: "allowed",
    /// "no_cloud:local_substitute", or "no_cloud:refused". A dry run sends
    /// nothing, so it does not need the binding to be safe — it needs it to be
    /// honest. Naming the role's configured provider on a surface where a real
    /// press would have refused, or swapped to a local one, is a diagnostic
    /// that misleads on the one surface where the answer matters.
    let privacy: String
    // Snapshot diagnostics — what the collector actually saw.
    let fieldRole: String?
    let fieldSubrole: String?
    let fieldEditable: Bool?
    let fieldValueChars: Int?
    let fieldSelectionChars: Int?
    let url: String?
    let windowTitle: String?
    let ancestorRoles: [String]
    let warmHit: Bool
    let axErrors: Int
}

enum MagicPressPipelineError: LocalizedError {
    case noProvider
    case noWorkflows
    /// P9: nothing in the chain meets the role's `min_cost_class` — refuse
    /// honestly rather than silently generating on a cheaper model.
    case downgradeRefused(min: ProviderCostClass)
    /// P7: the surface is marked `no_cloud` and no local provider exists.
    case noCloudRefused
    /// The card's `budget.ms` deadline passed before the model answered.
    case budgetExceeded(ms: Int)

    var errorDescription: String? {
        switch self {
        case .noProvider:
            String(localized: "No AI provider is configured for the Magic Button.")
        case .noWorkflows:
            String(localized: "No routable workflow could be loaded — every card needs a `when:` block to take part in routing.")
        case .downgradeRefused(let min):
            String(localized: "No provider meets this role's minimum cost class (\(min.rawValue)) — generation refused instead of silently downgrading.")
        case .noCloudRefused:
            String(localized: "This app or site is marked no-cloud and no local model is configured — nothing was sent.")
        case .budgetExceeded(let ms):
            String(localized: "The model did not answer within this workflow's \(ms) ms budget (budget.ms).")
        }
    }
}

/// The engine seam the press band calls: `plan` on the main actor, then
/// `route` (pure) and `execute` (async, one model call — P1) off it.
enum MagicPressPipeline {
    private static let logger = Logger(subsystem: Constants.bundleIdentifier, category: "engine.pipeline")

    /// Token counts owed for calls whose text a press discarded — the retried
    /// attempts. `estimated` is sticky: a total that mixes one reported count
    /// with one chars/4 guess is a guess, and `spend_summary` must not show it
    /// as measured.
    struct Usage: Sendable {
        var input = 0
        var output = 0
        var estimated = false
    }

    /// "The model gave us nothing, for no stated reason" — the only shape a
    /// blind retry can fix. `generationStopped` is deliberately excluded: the
    /// provider reported a failure, an incomplete response, or a refusal, and
    /// repeating the identical request just repeats that decision (and pays for
    /// it twice).
    private static func isEmptyGeneration(_ error: Error) -> Bool {
        switch error as? AIServiceError {
        case .emptyResponse, .emptyStream: true
        default: false
        }
    }

    @MainActor
    static func plan(
        workflowStore: WorkflowStore,
        coreStore: CoreFileStore,
        roleStore: EngineRoleStore,
        providerStore: ProviderStore,
        config: MagicEngineConfig = .default
    ) throws -> MagicPressPlan {
        workflowStore.reloadIfChanged()
        coreStore.reloadIfChanged()
        providerStore.reloadIfChanged()
        roleStore.reloadIfChanged()

        let provider: AIProviderConfig
        switch roleStore.resolution(for: .generationMagic, in: providerStore) {
        case .resolved(let resolved):
            provider = resolved
        case .refusedBelowMinCost(let min):
            throw MagicPressPipelineError.downgradeRefused(min: min)
        case .noneAvailable:
            throw MagicPressPipelineError.noProvider
        }
        // "Routable", not merely "loaded": `EngineRouter.route` only considers
        // cards that declare `when:`, so a catalog holding nothing but library
        // prompts (or one where every routed card is disabled) produced zero
        // candidates, `showChips([])` reset the phase to `.idle`, and the press
        // died with no trace and no HUD — the silent death `noWorkflows` exists
        // to replace.
        guard workflowStore.catalog.workflows.contains(where: { $0.card.when != nil }) else {
            throw MagicPressPipelineError.noWorkflows
        }

        return MagicPressPlan(
            catalog: workflowStore.catalog,
            core: coreStore.files,
            provider: provider,
            workflowLoadErrors: workflowStore.loadErrors,
            roleBinding: roleStore.binding(for: .generationMagic),
            providers: providerStore.providers,
            noCloud: config.noCloud,
            outputMaxCharsDefault: config.outputMaxCharsDefault,
            surroundingMaxTokens: config.surroundingMaxTokens,
            plannerBinding: roleStore.binding(for: .plannerMagic),
            plannerTimeoutMs: config.plannerTimeoutMs
        )
    }

    /// Classification runs only when there is a selection to classify.
    static func classify(_ snapshot: MagicSnapshot) -> SelectionClassification? {
        guard let selection = snapshot.field?.selection, !selection.text.isEmpty else { return nil }
        return SelectionClassifier.classify(selection.text)
    }

    static func route(
        plan: MagicPressPlan,
        snapshot: MagicSnapshot
    ) -> (decision: RoutingDecision, classification: SelectionClassification?) {
        let classification = classify(snapshot)
        let decision = EngineRouter.route(
            catalog: plan.catalog, snapshot: snapshot, classification: classification
        )
        return (decision, classification)
    }

    /// The only model call on the press path (P1). Off-main; non-streaming
    /// in V0 (R7). Never touches the field — insertion is the press band's
    /// job, after it sees the verdict (P8).
    static func execute(
        plan: MagicPressPlan,
        snapshot: MagicSnapshot,
        workflow: ResolvedWorkflow,
        decision: RoutingDecision,
        classification: SelectionClassification?,
        hint: String?
    ) async throws -> MagicPressResult {
        let clock = ContinuousClock()
        var trace = PressTrace(snapshot: snapshot, decision: decision, classification: classification)
        trace.chosenID = workflow.id
        trace.hintUsed = (hint?.isEmpty == false)

        // Privacy binding (P7): a no-cloud surface swaps to a local provider
        // from the chain, or the press refuses before anything is assembled.
        let provider: AIProviderConfig
        switch PrivacyBinding.enforce(
            resolved: plan.provider, binding: plan.roleBinding, providers: plan.providers,
            noCloud: plan.noCloud, bundleId: snapshot.app.bundleId,
            urlHost: EngineRouter.urlHost(of: snapshot.url),
            webSurfaceWithUnknownHost: PrivacyBinding.hasUnreadableWebHost(snapshot)
        ) {
        case .allowed(let allowed):
            provider = allowed
        case .refused:
            throw MagicPressPipelineError.noCloudRefused
        }
        trace.providerType = provider.providerType.rawValue
        trace.modelID = provider.modelID

        let outputMaxChars = workflow.card.output.maxChars ?? plan.outputMaxCharsDefault

        let assembleStart = clock.now
        let assembled = PromptAssembler.assemble(
            workflow: workflow,
            snapshot: snapshot,
            core: plan.core,
            classification: classification,
            hint: hint,
            outputMaxChars: outputMaxChars,
            surroundingMaxTokens: plan.surroundingMaxTokens
        )
        trace.latencyMs.assemble = Self.ms(clock.now - assembleStart)
        trace.slotTokens = Dictionary(uniqueKeysWithValues: assembled.slots.map { ($0.id.rawValue, $0.tokensEstimated) })
        trace.totalTokens = assembled.totalTokensEstimated

        let generateStart = clock.now
        let service = AIServiceFactory.service(for: provider.providerType)

        // One attempt's outcome. `.empty` rather than a thrown error because
        // the call ANSWERED — the usage it reports is owed whatever its text was
        // worth, and an error carries no payload back to the caller.
        enum Attempt {
            case produced(AIGenerationResult, String)
            case empty(AIGenerationResult)
        }

        func attemptGeneration() async throws -> Attempt {
            let generation = try await service.processWithUsage(
                text: assembled.userMessage,
                systemPrompt: assembled.systemPrompt,
                config: provider
            )
            let output = generation.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return output.isEmpty ? .empty(generation) : .produced(generation, output)
        }

        // Reasoning backends intermittently complete a stream with no
        // output text at all. One silent retry absorbs that; a second
        // empty stream surfaces the (now descriptive) error.
        //
        // The retry travels with the bill for what it replaced. A retried press
        // pays the provider twice, so the ledger has to say so or
        // `spend_summary` under-reports by exactly the retry rate — on the
        // reasoning backends the retry exists for, which are the expensive ones.
        // Same rule the press band applies to a planner call that lost its race
        // (`MagicPressCoordinator.startPlannerOrChips`): routing is what the
        // press moved on from, the invoice is not.
        //
        // Only attempts that COMPLETED can be counted. A service that throws
        // `.emptyStream` from inside itself reports no usage at all, so those
        // tokens are unrecoverable here and stay unbilled — a gap in what the
        // provider tells us, not one this function can close. Carried back as a
        // return value rather than accumulated in a captured `var`: this runs as
        // a task-group child below, and shared mutable state across that
        // boundary is a data race the compiler is right to refuse.
        func generateWithOneRetry() async throws -> (AIGenerationResult, String, Usage) {
            var abandoned = Usage()
            func recordAbandoned(_ generation: AIGenerationResult) {
                abandoned.input += generation.inputTokens ?? assembled.totalTokensEstimated
                abandoned.output += generation.outputTokens ?? 0
                abandoned.estimated = abandoned.estimated
                    || generation.inputTokens == nil || generation.outputTokens == nil
            }

            do {
                switch try await attemptGeneration() {
                case .produced(let generation, let output):
                    return (generation, output, abandoned)
                case .empty(let generation):
                    recordAbandoned(generation)
                    Self.logger.warning("first generation attempt returned no text — retrying once")
                }
            } catch let error where Self.isEmptyGeneration(error) {
                Self.logger.warning("first generation attempt returned nothing (\(error.localizedDescription, privacy: .public)) — retrying once")
            }

            switch try await attemptGeneration() {
            case .produced(let generation, let output):
                return (generation, output, abandoned)
            case .empty(let generation):
                recordAbandoned(generation)
                throw AIServiceError.emptyResponse
            }
        }

        // The card's `budget.ms`. It covers the whole generation phase
        // including the retry — a budget the retry could double is not a
        // budget — and 0 (the default) means no cap.
        let generation: AIGenerationResult
        var output: String
        let abandoned: Usage
        let budgetMs = workflow.card.budget.ms
        if budgetMs > 0 {
            // A task group here is only a HARD cap because every `AIService`
            // observes cancellation. The group awaits its losing child before
            // it returns, so `cancelAll()` merely *asks* the generation task to
            // stop: a service that ignored cancellation would keep this line
            // blocked long past `budget.ms` and turn the cap into advice.
            // `MagicPlanner.run` hit exactly that and had to drop its own task
            // group for two detached tasks plus a first-wins continuation —
            // back when `CLIToolService` sat blocked on a subprocess. It no
            // longer does (`runProcess` wraps the wait in
            // `withTaskCancellationHandler` and terminates the process, see
            // `ProcessRun`), which is the whole reason the simpler construct is
            // safe here. Adding an `AIService` that does not cooperatively
            // cancel breaks this cap and nothing else will say so — such a
            // service must either be made cancellable or this code must move to
            // the planner's pattern.
            //
            // Spend when the cap wins is knowingly unbilled: `execute` throws,
            // the press band's `catch` has no result to append, and the
            // cancelled generation never reports usage — there is nothing to
            // record rather than something being dropped. It is not the planner
            // hole in a new place: that call had ANSWERED and was thrown away
            // behind a cancellation guard, while this one is stopped mid-flight.
            // The residual — a provider that billed for tokens produced before
            // the SIGTERM/cancel landed — is accepted, and is the reason
            // `budget.ms` defaults to 0.
            (generation, output, abandoned) = try await withThrowingTaskGroup(
                of: (AIGenerationResult, String, Usage).self
            ) { group in
                group.addTask { try await generateWithOneRetry() }
                group.addTask {
                    try await Task.sleep(for: .milliseconds(budgetMs))
                    throw MagicPressPipelineError.budgetExceeded(ms: budgetMs)
                }
                let first = try await group.next()!
                group.cancelAll()
                return first
            }
        } else {
            (generation, output, abandoned) = try await generateWithOneRetry()
        }
        trace.latencyMs.generate = Self.ms(clock.now - generateStart)
        output = ContinuationSeam.adjust(output: output, for: snapshot)

        let verifyStart = clock.now
        let verdict = DeterministicVerifier.verify(
            output: output,
            workflow: workflow,
            prompt: assembled,
            snapshot: snapshot,
            constraints: plan.core.constraints,
            outputMaxChars: outputMaxChars
        )
        trace.latencyMs.verify = Self.ms(clock.now - verifyStart)
        trace.verifierPassed = verdict.passed
        trace.verifierChecks = verdict.warnings.map(\.check.rawValue)

        // What this press cost in total, abandoned attempts included — the press
        // band appends exactly this once, so anything missing here is missing
        // from `spend_summary` for good.
        return MagicPressResult(
            output: output, verdict: verdict, assembled: assembled, traceDraft: trace,
            inputTokens: (generation.inputTokens ?? assembled.totalTokensEstimated) + abandoned.input,
            outputTokens: (generation.outputTokens ?? TokenEstimator.estimate(output)) + abandoned.output,
            usageEstimated: generation.inputTokens == nil || generation.outputTokens == nil
                || abandoned.estimated
        )
    }

    /// Plan → route → assemble, and stop. Nothing executes, nothing is sent.
    static func dryRun(plan: MagicPressPlan, snapshot: MagicSnapshot) -> DryRunReport? {
        let (decision, classification) = route(plan: plan, snapshot: snapshot)
        guard let workflow = decision.top else { return nil }

        let assembled = PromptAssembler.assemble(
            workflow: workflow,
            snapshot: snapshot,
            core: plan.core,
            classification: classification,
            hint: nil,
            outputMaxChars: workflow.card.output.maxChars ?? plan.outputMaxCharsDefault,
            surroundingMaxTokens: plan.surroundingMaxTokens
        )

        let presentation: String
        switch decision.presentation {
        case .silent: presentation = "silent"
        case .chips: presentation = "chips"
        }

        // Same binding call `execute` makes, on the same inputs, so the report
        // names the provider a real press would actually have used — see
        // `DryRunReport.privacy`.
        let privacy: String
        let provider: AIProviderConfig
        switch PrivacyBinding.enforce(
            resolved: plan.provider, binding: plan.roleBinding, providers: plan.providers,
            noCloud: plan.noCloud, bundleId: snapshot.app.bundleId,
            urlHost: EngineRouter.urlHost(of: snapshot.url),
            webSurfaceWithUnknownHost: PrivacyBinding.hasUnreadableWebHost(snapshot)
        ) {
        case .allowed(let allowed):
            provider = allowed
            privacy = allowed.id == plan.provider.id ? "allowed" : "no_cloud:local_substitute"
        case .refused:
            // The refusal is the finding. The role's own provider is still
            // reported so the report says WHICH binding could not serve the
            // surface, not merely that something could not.
            provider = plan.provider
            privacy = "no_cloud:refused"
        }

        return DryRunReport(
            situationClass: decision.situationClass,
            tier: String(describing: decision.tier),
            grammarRow: String(describing: snapshot.grammarRow),
            candidateIDs: decision.counted.map(\.id),
            alternativeIDs: decision.alternatives.map(\.id),
            presentation: presentation,
            chosenID: workflow.id,
            workflowChain: workflow.chain,
            slots: assembled.slots,
            totalTokens: assembled.totalTokensEstimated,
            providerName: provider.name,
            modelID: provider.modelID,
            privacy: privacy,
            fieldRole: snapshot.field?.role,
            fieldSubrole: snapshot.field?.subrole,
            fieldEditable: snapshot.field?.editable,
            fieldValueChars: snapshot.field?.value.count,
            fieldSelectionChars: snapshot.field?.selection?.text.count,
            url: snapshot.url,
            windowTitle: snapshot.windowTitle,
            ancestorRoles: snapshot.ancestorRoles,
            warmHit: snapshot.warmHit,
            axErrors: snapshot.axCannotComplete
        )
    }

    private static func ms(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1000)
            + Int(duration.components.attoseconds / 1_000_000_000_000_000)
    }
}
