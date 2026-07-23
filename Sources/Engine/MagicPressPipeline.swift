import Foundation

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

    var errorDescription: String? {
        switch self {
        case .noProvider:
            String(localized: "No AI provider is configured for the Magic Button.")
        case .noWorkflows:
            String(localized: "No workflows could be loaded from the workflows folder.")
        case .downgradeRefused(let min):
            String(localized: "No provider meets this role's minimum cost class (\(min.rawValue)) — generation refused instead of silently downgrading.")
        case .noCloudRefused:
            String(localized: "This app or site is marked no-cloud and no local model is configured — nothing was sent.")
        }
    }
}

/// The engine seam the press band calls: `plan` on the main actor, then
/// `route` (pure) and `execute` (async, one model call — P1) off it.
enum MagicPressPipeline {
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
        guard !workflowStore.catalog.workflows.isEmpty else {
            throw MagicPressPipelineError.noWorkflows
        }

        return MagicPressPlan(
            catalog: workflowStore.catalog,
            core: coreStore.files,
            provider: provider,
            workflowLoadErrors: workflowStore.loadErrors,
            roleBinding: roleStore.binding(for: .generationMagic),
            providers: providerStore.providers,
            noCloud: config.noCloud
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
            urlHost: EngineRouter.urlHost(of: snapshot.url)
        ) {
        case .allowed(let allowed):
            provider = allowed
        case .refused:
            throw MagicPressPipelineError.noCloudRefused
        }
        trace.providerType = provider.providerType.rawValue
        trace.modelID = provider.modelID

        let assembleStart = clock.now
        let assembled = PromptAssembler.assemble(
            workflow: workflow,
            snapshot: snapshot,
            core: plan.core,
            classification: classification,
            hint: hint
        )
        trace.latencyMs.assemble = Self.ms(clock.now - assembleStart)
        trace.slotTokens = Dictionary(uniqueKeysWithValues: assembled.slots.map { ($0.id.rawValue, $0.tokensEstimated) })
        trace.totalTokens = assembled.totalTokensEstimated

        let generateStart = clock.now
        let service = AIServiceFactory.service(for: provider.providerType)
        let generation = try await service.processWithUsage(
            text: assembled.userMessage,
            systemPrompt: assembled.systemPrompt,
            config: provider
        )
        let raw = generation.text
        trace.latencyMs.generate = Self.ms(clock.now - generateStart)

        var output = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { throw AIServiceError.emptyResponse }
        output = ContinuationSeam.adjust(output: output, for: snapshot)

        let verifyStart = clock.now
        let verdict = DeterministicVerifier.verify(
            output: output,
            workflow: workflow,
            prompt: assembled,
            snapshot: snapshot,
            constraints: plan.core.constraints
        )
        trace.latencyMs.verify = Self.ms(clock.now - verifyStart)
        trace.verifierPassed = verdict.passed
        trace.verifierChecks = verdict.warnings.map(\.check.rawValue)

        return MagicPressResult(
            output: output, verdict: verdict, assembled: assembled, traceDraft: trace,
            inputTokens: generation.inputTokens ?? assembled.totalTokensEstimated,
            outputTokens: generation.outputTokens ?? TokenEstimator.estimate(output),
            usageEstimated: generation.inputTokens == nil || generation.outputTokens == nil
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
            hint: nil
        )

        let presentation: String
        switch decision.presentation {
        case .silent: presentation = "silent"
        case .chips: presentation = "chips"
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
            providerName: plan.provider.name,
            modelID: plan.provider.modelID,
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
