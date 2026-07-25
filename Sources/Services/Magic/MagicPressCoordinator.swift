import AppKit
@preconcurrency import ApplicationServices
import KeyboardShortcuts
import os

enum MagicToastPanelReason: Sendable, Equatable {
    case nonEditable
    case focusMismatch
    case verifierFailed
}

/// What a press should do about the field it is about to paste into, decided
/// from one `MagicSelectionProbe`. File scope rather than nested in
/// `MagicPressCoordinator` so the `nonisolated` decision function that returns
/// it — and the tests that call it — never have to reason about the
/// coordinator's main-actor isolation.
enum MagicSelectionVerdict: Sendable, Equatable {
    /// The captured selection is still the live one: paste over it.
    case proceed
    /// Someone else's selection is live, or one that cannot be placed in the
    /// field's current value: clipboard + toast, field untouched.
    case refuse
    /// The target dropped the selection: re-assert these UTF-16 offsets first,
    /// then paste.
    case reassert(location: Int, length: Int)
}

enum MagicToastState {
    case generating(label: String)
    case inserted(MagicInserter.PreInsertRecord)
    case panelResult(text: String, reason: MagicToastPanelReason, warnings: [VerifierWarning])
}

/// The press-band state machine: hotkey → snapshot → route → (chips) →
/// generate → verify → insert → toast. Owns the engine stores and every
/// Magic window, keeping AppState down to one property.
@MainActor
@Observable
final class MagicPressCoordinator {
    enum Phase {
        case idle
        case collecting
        /// The fast-mode chip planner is racing its hard cap
        /// (`planner_timeout_ms`) — nothing is on screen yet; Escape
        /// cancels the press.
        case planning
        case chips
        case generating
        case toast
    }

    private(set) var phase: Phase = .idle
    var toastState: MagicToastState? {
        didSet {
            // ⌘↩ is the keyboard twin of hold-to-insert: armed exactly while
            // the verifier-warning affordance is on screen, never otherwise.
            if case .panelResult(_, .verifierFailed, _) = toastState {
                KeyboardShortcuts.enable(.confirmMagicInsert)
            } else {
                KeyboardShortcuts.disable(.confirmMagicInsert)
            }
        }
    }
    var toastHovered = false {
        didSet { if !toastHovered { scheduleToastDismissIfSettled() } }
    }
    /// Transient note shown in the inserted toast ("Previous text copied").
    var restoreNote: String?

    weak var appState: AppState?

    // Engine stores (seeded before first load).
    @ObservationIgnored let workflowStore: WorkflowStore
    @ObservationIgnored let coreStore: CoreFileStore
    @ObservationIgnored let roleStore: EngineRoleStore
    @ObservationIgnored let configStore: EngineConfigStore
    @ObservationIgnored private let traceLogger = EngineTraceLogger()
    @ObservationIgnored private let debugLogger = MagicDebugLogger()
    @ObservationIgnored private let snapshotService = AXSnapshotService()
    @ObservationIgnored private let inserter = MagicInserter()
    @ObservationIgnored private let spendLedger = SpendLedger()
    /// M1 warm collector (§5.1): one AXObserver on the frontmost app keeps
    /// cheap context fresh and pre-builds Chromium AX trees.
    @ObservationIgnored private(set) var frontmostObserver: FrontmostObserver!

    // Windows.
    @ObservationIgnored private var chipPanel: ChipPanelWindow?
    @ObservationIgnored private var toastWindow: MagicToastWindow?
    @ObservationIgnored private var hintHUD: ErrorHUDWindow?

    // The press in flight.
    private struct ActivePress {
        let snapshot: MagicSnapshot
        let plan: MagicPressPlan
        let decision: RoutingDecision
        let classification: SelectionClassification?
        let forceChips: Bool
        var trace: PressTrace
        var result: MagicPressResult?
        var record: MagicInserter.PreInsertRecord?
        var workflow: ResolvedWorkflow?
        var hint: String?
    }

    @ObservationIgnored private var activePress: ActivePress?
    @ObservationIgnored private var generationTask: Task<Void, Never>?
    @ObservationIgnored private var plannerTask: Task<Void, Never>?
    @ObservationIgnored private var toastDismissTask: Task<Void, Never>?
    @ObservationIgnored private var pressStart: ContinuousClock.Instant?
    /// An accepted verifier warning is waiting out its focus delay. Neither
    /// `phase` nor `toastState` changes across that gap, so this is what keeps
    /// a second ⌘↩ from pasting the flagged output twice.
    @ObservationIgnored private var insertAnywayInFlight = false
    /// When the focus restoration started by the last overlay teardown is
    /// expected to have landed — see `returnFocusToTarget` (asynchronous by
    /// construction) and `awaitFocusSettle`. Nil means nothing is in flight and
    /// the next press captures immediately.
    @ObservationIgnored private var focusSettlesAt: ContinuousClock.Instant?
    /// Which app that restoration is aimed at — published with the deadline so
    /// the press waiting it out has an explicit target instead of a re-derived
    /// one. See the check in `startPress`.
    @ObservationIgnored private var focusSettleTargetPid: pid_t?
    /// How long `returnFocusToTarget` needs: one main-loop hop to re-activate
    /// the target plus the 120 ms AX-focus delay, rounded up to the same 600 ms
    /// the menu-driven entry points already wait for a stolen focus to return.
    private static let focusSettleMs = 600
    private static let logger = Logger(subsystem: Constants.bundleIdentifier, category: "engine.magic")

    init() {
        EngineSeedContent.seedIfNeeded()
        workflowStore = WorkflowStore()
        coreStore = CoreFileStore()
        roleStore = EngineRoleStore()
        configStore = EngineConfigStore()
        frontmostObserver = FrontmostObserver(
            snapshotService: snapshotService,
            configProvider: { [configStore] in configStore.config }
        )
        // One-shot migration of the legacy UserDefaults toggle. Debug logging
        // lives in config.yaml (`debug_log_enabled`) so file-editing agents can
        // reach it, and config is the authority once this has run.
        if UserDefaults.standard.bool(forKey: "magicDebugLogging") {
            configStore.setInteger(1, forKey: "debug_log_enabled")
        }
        UserDefaults.standard.removeObject(forKey: "magicDebugLogging")
        Task { [traceLogger, debugLogger] in
            await traceLogger.pruneOldLogs()
            await debugLogger.pruneOldLogs()
        }
    }

    /// Called from `AppState.setup()` once the app is fully wired. Safe to
    /// call before Accessibility is granted — the observer attaches lazily
    /// on the next app activation after the grant.
    func startWarmObserver() {
        frontmostObserver.start()
    }

    /// Startup validation (§14): file-load warnings and per-role resolution
    /// problems go to the log with clear messages. The same facts render as
    /// badges in Settings → Providers; failure is visible, never silent
    /// (§15.3).
    func logProviderLayerHealth() {
        guard let providerStore = appState?.providerStore else { return }
        // Reading the stores is main-actor work and stays here; resolution
        // itself is pure bookkeeping over already-loaded config.
        let warnings = providerStore.loadWarnings + roleStore.loadWarnings
        let resolutions = EngineRole.allCases.map { role in
            (role, roleStore.resolution(for: role, in: providerStore))
        }

        // The `KeychainService.load` below is one synchronous
        // `SecItemCopyMatching` per API-key-bearing role, and this runs from
        // `AppState.setup()` — while the first window is going up. A cold
        // Security daemon, a locked keychain or an item still syncing turns each
        // of those into a launch-time stall of the main thread for a check whose
        // only output is a log line. Nothing here touches UI or mutable state
        // (the verdicts were resolved above and travel as values), so the probe
        // and the logging move off, in exactly the order they were built: load
        // warnings first, then one line per role in `allCases` order.
        Task.detached(priority: .utility) { [logger = Self.logger] in
            for warning in warnings {
                logger.warning("provider layer: \(warning, privacy: .public)")
            }
            for (role, resolution) in resolutions {
                switch resolution {
                case .resolved(let provider):
                    if provider.providerType.requiresAPIKey,
                       KeychainService.load(key: provider.apiKeyRef)?.isEmpty != false {
                        logger.warning("role \(role.rawValue, privacy: .public): provider \(provider.name, privacy: .public) has no API key")
                    }
                case .refusedBelowMinCost(let min):
                    logger.error("role \(role.rawValue, privacy: .public): no provider meets min_cost_class \(min.rawValue, privacy: .public) — will refuse")
                case .noneAvailable:
                    logger.error("role \(role.rawValue, privacy: .public): no provider available")
                }
            }
        }
    }

    /// True when the press targets ClipSlop's own windows (the onboarding
    /// sandbox, a Settings field). Skips the focus dance — there is no
    /// external app to return to.
    private var isSelfTargeted: Bool {
        activePress?.snapshot.app.bundleId == Bundle.main.bundleIdentifier
    }

    /// The window that held key before a self-targeted press's chip panel
    /// took it (the onboarding sandbox). Restored explicitly on overlay
    /// close — AppKit's automatic pick after a key panel orders out is not
    /// guaranteed to land on the sandbox window.
    @ObservationIgnored private weak var selfTargetKeyWindow: NSWindow?

    // MARK: - Transitions

    /// The pure view of the press band that `MagicPressReducer` decides from.
    /// Rebuilt per event on purpose: it is a *reading* of the live state, never
    /// a second copy of it that could drift. Windows and AppKit stop here —
    /// everything below the reducer boundary is `Bool` and `Int`.
    ///
    /// Every field here is a cheap property read except one:
    /// `PermissionService.isAccessibilityGranted` is `AXIsProcessTrusted()`, a
    /// TCC query rather than a cached flag. Only `.press` gates on it, and this
    /// state is built for every event — including `.toastSettleCheck`, which the
    /// toast's `.onHover` fires on each mouse pass across its edge. Reading it
    /// unconditionally would therefore charge a TCC round-trip per hover for a
    /// question only the press asks. So it is read for the events that consult
    /// it and left at the non-gating `true` for the rest; an event that starts
    /// gating on permission has to add itself to `gatesOnPermission`.
    private func reducerState(for event: MagicPressReducer.Event) -> MagicPressReducer.State {
        let gatesOnPermission: Bool
        if case .press = event { gatesOnPermission = true } else { gatesOnPermission = false }

        var verifierWarningPending = false
        if case .panelResult(_, .verifierFailed, _) = toastState { verifierWarningPending = true }
        return MagicPressReducer.State(
            phase: phase,
            verifierWarningPending: verifierWarningPending,
            insertAnywayInFlight: insertAnywayInFlight,
            chipPanelOpen: chipPanel != nil,
            chipCandidateCount: activePress?.decision.chipCandidates.count ?? 0,
            toastOpen: toastWindow != nil,
            toastIsKey: toastWindow?.isKeyWindow == true,
            toastHovered: toastHovered,
            hintOpen: hintHUD != nil,
            hasActivePress: activePress != nil,
            hasWorkflow: activePress?.workflow != nil,
            accessibilityGranted: gatesOnPermission ? PermissionService.isAccessibilityGranted : true
        )
    }

    // MARK: - Press entry

    /// The branching lives in `MagicPressReducer` — the single-flight bounce,
    /// the double-press accept, and the "a plain press means insert it, a
    /// forced press means ask me again" split over a verifier warning. This
    /// method only does what the reducer decided, in order.
    func handlePress(forceChips: Bool) {
        let event = MagicPressReducer.Event.press(forceChips: forceChips)
        switch MagicPressReducer.reduce(state: reducerState(for: event), event: event) {
        case .ignore:
            return
        case .acceptTopChip:
            selectChip(0)
        case .insertAnyway:
            // The reducer only says "a plain press over a verifier warning is
            // an accept"; whether that accept is still available is
            // `insertAnyway`'s own question (it may already be in flight).
            insertAnyway()
        case .showPermissionAlert:
            appState?.showPermissionAlert()
        case .dismissToastThenShowPermissionAlert:
            // The toast belongs to a press that is over either way, so it comes
            // down before the gate refuses this one — same order as when the
            // permission check sat inline after `dismissToast`.
            dismissToast(outcome: nil)
            appState?.showPermissionAlert()
        case .dismissToastThenStartPress(let force):
            dismissToast(outcome: nil)
            startPress(forceChips: force)
        case .startPress(let force):
            startPress(forceChips: force)
        default:
            // Unreachable for `.press` — the remaining actions belong to the
            // overlay and toast events.
            return
        }
    }

    private func startPress(forceChips: Bool) {
        phase = .collecting
        pressStart = ContinuousClock().now
        let locale = Locale.preferredLanguages.first ?? "en"
        configStore.reloadIfChanged()
        let config = configStore.config
        // Config was just reloaded, so this is where a freshly flipped
        // `warm_observer_enabled: 0` takes effect: drop the cache and tear the
        // live observer down rather than leaving it running behind the switch.
        frontmostObserver.applyKillSwitch()

        Task { [weak self] in
            guard let self else { return }
            // A press that had to tear an overlay down races its own focus
            // restoration. `dismissToast` → `closeToast` → `returnFocusToTarget`
            // re-activates the target app on the next main-loop hop and sets
            // kAXFocusedAttribute 120 ms after *that*, so a capture kicked off
            // right here reads the field before focus came back — or finds no
            // field at all and kills the press as `dead:no_target`. Waiting out
            // the published settle is the same trick `pressFromMenu`,
            // `dryRunToClipboard` and `insertTestString` use after the menu
            // steals key; `phase` is already `.collecting`, so a second hotkey
            // still bounces off the single-flight guard while we wait, and an
            // `.idle` press with no restoration pending waits zero.
            //
            // `pressStart` stays where it is, before the wait: the user really
            // is waiting from the hotkey, and a press-to-paste sample that
            // hides the settle would flatter the §3.6 SLO instead of measuring
            // it.
            let pinnedTarget = await self.awaitFocusSettle()
            let clock = ContinuousClock()
            let snapshotStart = clock.now
            // Read the frontmost app and the warm cache *after* the settle:
            // right after an overlay teardown ClipSlop can still be frontmost,
            // and an appInfo taken then names the wrong app for the whole press
            // (wrong `no_cloud` identity, wrong routing, wrong paste target).
            let appInfo = self.frontmostAppInfo()
            // …but the target is the app the restoration was aimed at, not
            // whoever happens to be frontmost when the sleep ends. Without the
            // pin, an app the user ⌘-tabbed to *during* those 600 ms becomes
            // the target, and the pid guard in `AXSnapshotService.capture` then
            // yields a contentless snapshot and the press dies silently. A
            // deliberate switch away is not a target: end the press the way a
            // lost target ends — trace, hint, back to `.idle` — instead of
            // following the user into a field they never pressed the hotkey in.
            if let pinnedTarget, appInfo.pid != pinnedTarget {
                self.continuePress(
                    snapshot: Self.lostTargetSnapshot(pid: pinnedTarget, locale: locale),
                    snapshotMs: Self.ms(clock.now - snapshotStart),
                    forceChips: forceChips
                )
                return
            }
            let warm = self.frontmostObserver.warm
            var snapshot = await self.snapshotService.capture(
                appInfo: appInfo, locale: locale, config: config, warm: warm
            )
            if MagicSelectionCapture.isNeeded(for: snapshot) {
                snapshot = await MagicSelectionCapture.refine(snapshot)
            }
            let snapshotMs = Self.ms(clock.now - snapshotStart)
            self.continuePress(snapshot: snapshot, snapshotMs: snapshotMs, forceChips: forceChips)
        }
    }

    /// A capture that found nothing, built without going near AX: a nil `field`
    /// makes `grammarRow` read `.noTarget`, which is the dead end
    /// `continuePress` already knows how to end. The app is named from the
    /// pinned pid rather than left blank so the trace records which target the
    /// press was addressed to before it was abandoned.
    private static func lostTargetSnapshot(pid: pid_t, locale: String) -> MagicSnapshot {
        let app = NSRunningApplication(processIdentifier: pid)
        return MagicSnapshot(
            app: .init(name: app?.localizedName, bundleId: app?.bundleIdentifier, pid: pid),
            windowTitle: nil, url: nil, field: nil, surrounding: nil,
            locale: locale, ts: Date(), focusedElement: nil
        )
    }

    private func continuePress(snapshot: MagicSnapshot, snapshotMs: Int, forceChips: Bool) {
        switch snapshot.grammarRow {
        case .secure:
            // Dead with no exceptions — and silent (§3.1).
            logBareTrace(snapshot: snapshot, outcome: "dead:secure")
            phase = .idle
            return
        case .noTarget:
            logBareTrace(snapshot: snapshot, outcome: "dead:no_target")
            showHint(Loc.shared.t("magic.hud.no_target"))
            phase = .idle
            return
        default:
            break
        }

        let plan: MagicPressPlan
        do {
            guard let appState else { phase = .idle; return }
            plan = try MagicPressPipeline.plan(
                workflowStore: workflowStore,
                coreStore: coreStore,
                roleStore: roleStore,
                providerStore: appState.providerStore,
                config: configStore.config
            )
        } catch {
            logBareTrace(snapshot: snapshot, outcome: "error:plan")
            showHint(error.localizedDescription, near: snapshot)
            phase = .idle
            return
        }

        let (decision, classification) = MagicPressPipeline.route(plan: plan, snapshot: snapshot)
        var trace = PressTrace(snapshot: snapshot, decision: decision, classification: classification)
        trace.latencyMs.snapshot = snapshotMs

        var press = ActivePress(
            snapshot: snapshot, plan: plan, decision: decision,
            classification: classification, forceChips: forceChips, trace: trace
        )

        if forceChips {
            press.trace.presentation = "chips_forced"
            activePress = press
            showChips(decision.chipCandidates)
            return
        }

        switch decision.presentation {
        case .silent(let chosen):
            press.trace.presentation = "silent"
            activePress = press
            startRun(workflow: chosen, hint: nil)
        case .chips(let ranked):
            press.trace.presentation = "chips"
            activePress = press
            startPlannerOrChips(ranked)
        }
    }

    // MARK: - Planner (fast-mode chip disambiguation)

    /// Planner-first with a hard cap: the panel is shown only after the
    /// planner declined (or was skipped), so it can never flash-then-vanish.
    /// Any ineligibility — forced chips (handled upstream), context-blind
    /// press, a lone chip, `planner_timeout_ms: 0`, no usable provider
    /// (no_cloud with no local, resolution refused) — falls through to the
    /// plain chip panel; the planner never fails a press.
    private func startPlannerOrChips(_ candidates: [ResolvedWorkflow]) {
        guard let press = activePress else {
            showChips(candidates)
            return
        }
        let plan = press.plan
        let snapshot = press.snapshot
        guard MagicPlanner.isEligible(
            forceChips: press.forceChips,
            contextBlind: snapshot.contextBlind,
            candidateCount: candidates.count,
            timeoutMs: plan.plannerTimeoutMs
        ), let provider = MagicPlanner.resolveProvider(
            binding: plan.plannerBinding,
            generationProvider: plan.provider,
            generationBinding: plan.roleBinding,
            providers: plan.providers,
            noCloud: plan.noCloud,
            bundleId: snapshot.app.bundleId,
            urlHost: EngineRouter.urlHost(of: snapshot.url)
        ) else {
            showChips(candidates)
            return
        }

        // The panel shows IMMEDIATELY with a progress affordance — the
        // planner is just another finger racing for a chip. The user can
        // always outrace it (digits, click, hint, Esc all cancel the
        // planner); a confident planner answer presses the chip for them.
        showChips(candidates)
        phase = .planning

        let plannerCandidates = candidates.map(MagicPlanner.Candidate.init(workflow:))
        let timeoutMs = plan.plannerTimeoutMs
        plannerTask = Task { [weak self, spendLedger] in
            let run = await MagicPlanner.run(
                snapshot: snapshot,
                candidates: plannerCandidates,
                provider: provider,
                timeoutMs: timeoutMs,
                service: AIServiceFactory.service(for: provider.providerType)
            )
            // Bill BEFORE the cancellation guard, and off `spendLedger` rather
            // than `self`, because the money is already gone by the time we
            // get here. A planner call that completes but loses the race to a
            // human chip pick has still been paid for, so billing behind
            // `guard !Task.isCancelled` would drop those tokens on the floor
            // and make `spend_summary` under-report by however often the user
            // out-clicks the planner. Routing is what the press moved on from;
            // the invoice is not. An abandoned call (`.timedOut` / `.failed`,
            // no usage came back) still appends nothing.
            if let usage = run.billableUsage {
                await spendLedger.append(Self.plannerSpend(usage, provider: provider))
            }
            guard !Task.isCancelled else { return }
            self?.finishPlanner(run, candidates: candidates)
        }
    }

    /// The planner's ledger entry, filed under the planner role so
    /// `spend_summary` can tell the two Magic calls apart. `nonisolated`: it is
    /// pure arithmetic on values and runs from the planner task, which must be
    /// able to bill without touching coordinator state.
    private nonisolated static func plannerSpend(
        _ usage: MagicPlanner.Usage, provider: AIProviderConfig
    ) -> SpendRecord {
        SpendRecord(
            ts: Date(),
            role: EngineRole.plannerMagic.rawValue,
            provider: provider.providerType.rawValue,
            model: provider.modelID,
            inputTokens: usage.inputTokens,
            outputTokens: usage.outputTokens,
            estimated: usage.estimated
        )
    }

    /// The routing half of a planner answer. Takes no provider: spend is not
    /// its business any more.
    private func finishPlanner(
        _ run: MagicPlanner.Run,
        candidates: [ResolvedWorkflow]
    ) {
        plannerTask = nil
        // Routing only. The spend was accounted by the planner task itself
        // (see `startPlannerOrChips`) precisely because this method is
        // reachable only when the press still wants the answer, and the bill
        // is owed either way.
        guard phase == .planning, var press = activePress else { return }
        press.trace.latencyMs.planner = run.ms

        if case .chose(let index) = run.outcome, index < candidates.count {
            press.trace.presentation = "chips_planner"
            press.trace.plannerIndexChosen = index
            activePress = press
            // Proceed exactly as selectChip(index) would: the panel is on
            // screen, so leave the chip phases, close it and return focus
            // before generating.
            acceptChipSelection(candidates[index], hint: nil)
        } else {
            // Declined/unsure: the panel is already up — just hand it over
            // to the user (the progress affordance hides with the phase).
            activePress = press
            if chipPanel == nil { showChips(candidates) } else { phase = .chips }
        }
    }

    private func cancelPlanner() {
        guard phase == .planning else { return }
        plannerTask?.cancel()
        plannerTask = nil
        KeyboardShortcuts.disable(.dismissMagicOverlay)
        if var press = activePress {
            press.trace.outcome = "cancelled"
            submitTrace(press.trace)
            activePress = nil
        }
        phase = .idle
    }

    // MARK: - Chips

    private func showChips(_ candidates: [ResolvedWorkflow]) {
        guard !candidates.isEmpty else {
            // Never silent (§15.3). An empty candidate list means routing
            // matched nothing on this surface — the bare `phase = .idle` this
            // replaces ended the press with no hint, no toast and no trace,
            // indistinguishable from the hotkey never having fired.
            if var press = activePress {
                press.trace.outcome = "noCandidates"
                submitTrace(press.trace)
                activePress = nil
                showHint(Loc.shared.t("magic.hud.no_routable_workflow"), near: press.snapshot)
            }
            phase = .idle
            return
        }
        phase = .chips
        let chips = candidates.prefix(4).enumerated().map { index, workflow in
            MagicChip(
                index: index,
                workflowID: workflow.id,
                title: workflow.card.summary ?? workflow.id,
                subtitle: workflow.card.intents.first
            )
        }
        let anchor = activePress.map { CaretLocator.anchorRect(for: $0.snapshot) } ?? .zero

        let panel = ChipPanelWindow(
            chips: Array(chips),
            note: activePress?.snapshot.contextBlind == true
                ? Loc.shared.t("magic.chips.context_blind") : nil,
            coordinator: self,
            onSelect: { [weak self] index in Task { @MainActor in self?.selectChip(index) } },
            onHint: { [weak self] hint in Task { @MainActor in self?.submitHint(hint) } },
            onDismiss: { [weak self] in Task { @MainActor in self?.dismissChips() } }
        )
        if isSelfTargeted { selfTargetKeyWindow = NSApp.keyWindow }
        chipPanel = panel
        panel.show(anchoredAt: anchor)
        KeyboardShortcuts.enable(.dismissMagicOverlay)
    }

    /// The global Escape hotkey (armed only while an overlay is visible):
    /// dismiss whichever Magic surface is up. The Carbon hotkey consumes
    /// the event, so the target app never sees this Escape — the fix for
    /// web pages blurring their composer instead of closing our toast.
    ///
    /// The precedence between the five surfaces is the behaviour, so it lives
    /// in `MagicPressReducer` where it is one ordered chain with tests on it,
    /// not an if/else-if ladder nobody can see rot.
    func dismissFloatingOverlay() {
        switch MagicPressReducer.reduce(state: reducerState(for: .dismissOverlay), event: .dismissOverlay) {
        case .dismissChips:
            dismissChips()
        case .cancelPlanner:
            cancelPlanner()
        case .cancelGeneration:
            cancelGeneration()
        case .dismissToast:
            dismissToast(outcome: nil)
        case .closeHint:
            closeHint()
        default:
            return
        }
    }

    func selectChip(_ index: Int) {
        let event = MagicPressReducer.Event.selectChip(index)
        switch MagicPressReducer.reduce(state: reducerState(for: event), event: event) {
        case .cancelPlannerRace:
            // The index named no candidate, but the panel was still touched by
            // a human — the planner loses the race either way.
            cancelPlannerRace()
        case .acceptChip(let index):
            cancelPlannerRace()
            guard var press = activePress else { return }
            press.trace.chipIndexChosen = index
            activePress = press
            acceptChipSelection(press.decision.chipCandidates[index], hint: nil)
        default:
            return
        }
    }

    func submitHint(_ hint: String) {
        switch MagicPressReducer.reduce(state: reducerState(for: .submitHint), event: .submitHint) {
        case .cancelPlannerRace:
            cancelPlannerRace()
        case .acceptChipWithHint:
            cancelPlannerRace()
            guard var press = activePress,
                  let workflow = press.decision.chipCandidates.first else { return }
            press.trace.chipIndexChosen = 0
            activePress = press
            acceptChipSelection(workflow, hint: hint)
        default:
            return
        }
    }

    /// The human outraced the planner: their touch wins and the in-flight
    /// request really does die — `MagicPlanner.run` hangs a cancellation
    /// handler off this cancel, so it settles now instead of idling until the
    /// hard cap fires. A call that had already answered still bills; the ledger
    /// append in `startPlannerOrChips` runs ahead of the cancellation guard.
    private func cancelPlannerRace() {
        plannerTask?.cancel()
        plannerTask = nil
    }

    /// The one way an accepted chip leaves the panel: leave `.chips`/`.planning`
    /// FIRST, then close, then run.
    ///
    /// `ChipPanelWindow` routes `resignKey` to its `onDismiss`, i.e. to
    /// `dismissChips()` — which clears `activePress` and records the press as
    /// dismissed. Ordering the panel out while it is still key is exactly what
    /// makes it resign key, so an accepted selection sits one nested run-loop
    /// spin (inside `orderOut`/`deactivate`/`hide`) away from being cancelled
    /// by its own teardown and no-oping instead of generating. Today the hop
    /// through `Task { @MainActor … }` in the window happens to save us; that
    /// is an accident of scheduling, not an invariant. Moving out of the chip
    /// phases up front makes `dismissChips`'s own guard the invariant: however
    /// the callback arrives, sync or enqueued, it finds a phase it refuses to
    /// act on.
    private func acceptChipSelection(_ workflow: ResolvedWorkflow, hint: String?) {
        phase = .generating
        closeChipPanel(returnFocus: true)
        startRun(workflow: workflow, hint: hint)
    }

    func dismissChips() {
        guard phase == .chips || phase == .planning else { return }
        plannerTask?.cancel()
        plannerTask = nil
        phase = .idle
        closeChipPanel(returnFocus: true)
        if var press = activePress {
            press.trace.outcome = "dismissed"
            submitTrace(press.trace)
            activePress = nil
        }
    }

    private func closeChipPanel(returnFocus: Bool) {
        guard let panel = chipPanel else { return }
        chipPanel = nil
        KeyboardShortcuts.disable(.dismissMagicOverlay)
        let wasKey = panel.isKeyWindow
        panel.orderOut(nil)
        if isSelfTargeted, wasKey {
            selfTargetKeyWindow?.makeKeyAndOrderFront(nil)
        }
        if returnFocus { returnFocusToTarget(excluding: nil, force: wasKey) }
    }

    // MARK: - Generation

    private func startRun(workflow: ResolvedWorkflow, hint: String?) {
        guard var press = activePress else { return }
        press.workflow = workflow
        press.hint = hint
        // Stamp on the coordinator-side draft too, so a run that dies before
        // `execute` returns its trace still records what was chosen.
        press.trace.chosenID = workflow.id
        activePress = press

        phase = .generating
        toastState = .generating(label: workflow.card.summary ?? workflow.id)
        restoreNote = nil
        showToast()

        let plan = press.plan
        let snapshot = press.snapshot
        let decision = press.decision
        let classification = press.classification

        generationTask = Task { [weak self] in
            do {
                let result = try await MagicPressPipeline.execute(
                    plan: plan, snapshot: snapshot, workflow: workflow,
                    decision: decision, classification: classification, hint: hint
                )
                guard !Task.isCancelled else { return }
                await self?.handleResult(result)
            } catch {
                guard !Task.isCancelled, !Self.isCancellation(error) else { return }
                await self?.handleGenerationError(error)
            }
        }
    }

    private func handleResult(_ result: MagicPressResult) async {
        guard var press = activePress else { return }
        press.result = result
        let spend = SpendRecord(
            ts: Date(),
            role: EngineRole.generationMagic.rawValue,
            provider: result.traceDraft.providerType ?? "unknown",
            model: result.traceDraft.modelID ?? "unknown",
            inputTokens: result.inputTokens,
            outputTokens: result.outputTokens,
            estimated: result.usageEstimated
        )
        Task { [spendLedger] in await spendLedger.append(spend) }
        var trace = result.traceDraft
        trace.latencyMs.snapshot = press.trace.latencyMs.snapshot
        trace.latencyMs.planner = press.trace.latencyMs.planner
        trace.presentation = press.trace.presentation
        trace.chipIndexChosen = press.trace.chipIndexChosen
        trace.plannerIndexChosen = press.trace.plannerIndexChosen
        press.trace = trace
        activePress = press

        if result.verdict.passed {
            await performInsert(result.output)
        } else {
            // Stamp the default outcome now: `execute` never sets one, so a
            // warning panel closed with ✕/Escape or left to auto-dismiss used
            // to submit the trace with PressTrace's `unknown`, losing the
            // guard-health signal for warnings the user declined (§10.2).
            // Every other exit — insertAnyway, regenerate, copy — overwrites
            // it, so this only survives when the user really did walk away.
            press.trace.outcome = "verifierDismissed"
            activePress = press
            phase = .toast
            toastState = .panelResult(
                text: result.output, reason: .verifierFailed, warnings: result.verdict.warnings
            )
            showToast()
        }
    }

    private func performInsert(_ text: String) async {
        guard let snapshot = activePress?.snapshot else { return }

        // After a chip round-trip some apps drop the selection on
        // deactivate — re-assert the captured range before pasting over it.
        //
        // The AX work behind this happens off the main actor, which makes this
        // a suspension point in the middle of the press band.
        // The band mutates freely across it — Escape while `.generating` runs
        // `cancelGeneration`, which submits the trace and clears `activePress` —
        // and resuming into a capture taken before the hop would resurrect a
        // press the user had just cancelled (toast shown, outcome overwritten).
        // So the press is re-read afterwards and matched by `ts`: same press or
        // nothing happened.
        let selectionHeld = await reassertSelectionIfLost(snapshot)
        guard var press = activePress, press.snapshot.ts == snapshot.ts else { return }

        guard selectionHeld else {
            // The user selected something else inside the field while chips or
            // generation were up. The plan addressed the OLD selection, so
            // pasting would replace text nobody asked about — the same class
            // of error as focus moving, and handled the same way: clipboard +
            // toast, field untouched.
            PasteboardTransaction.writeGenerated(text)
            press.trace.outcome = "selectionChanged"
            activePress = press
            phase = .toast
            toastState = .panelResult(text: text, reason: .focusMismatch, warnings: [])
            showToast()
            scheduleToastDismissIfSettled()
            return
        }

        let outcome = await inserter.insert(text, against: press.snapshot)
        if let start = pressStart {
            press.trace.latencyMs.paste = Self.ms(ContinuousClock().now - start)
        }
        switch outcome {
        case .inserted(let record):
            press.record = record
            // Don't overwrite an insert-anyway stamp — its rate is the
            // §10.2 guard-health metric — and mark pastes the AX read could
            // not confirm.
            if press.trace.outcome != "insertedAnyway" {
                press.trace.outcome = "inserted"
            }
            if !record.pasteConfirmed {
                press.trace.outcome += ":unconfirmed"
            }
            activePress = press
            phase = .toast
            toastState = .inserted(record)
        case .focusMismatch:
            press.trace.outcome = "focusMismatch"
            activePress = press
            phase = .toast
            toastState = .panelResult(text: text, reason: .focusMismatch, warnings: [])
        case .panelOnly:
            press.trace.outcome = "panelOnly"
            activePress = press
            phase = .toast
            toastState = .panelResult(text: text, reason: .nonEditable, warnings: [])
        }
        showToast()
        scheduleToastDismissIfSettled()
    }

    private func handleGenerationError(_ error: Error) async {
        Self.logger.error("magic generation failed: \(error.localizedDescription, privacy: .public)")
        let pressSnapshot = activePress?.snapshot
        if var press = activePress {
            press.trace.outcome = "error:generation:\(Self.errorKind(error))"
            lastErrorDescription = error.localizedDescription
            activePress = press
            submitTrace(press.trace)
            activePress = nil
        }
        closeToast()
        phase = .idle
        showHint(error.localizedDescription, near: pressSnapshot)
    }

    /// Short, contentless error class for traces ("http429", "url-1009",
    /// "emptyResponse") — enough to see failure patterns without logging
    /// message text.
    private static func errorKind(_ error: Error) -> String {
        if let pipelineError = error as? MagicPressPipelineError {
            switch pipelineError {
            case .noProvider: return "noProvider"
            case .noWorkflows: return "noWorkflows"
            case .downgradeRefused: return "downgradeRefused"
            case .noCloudRefused: return "noCloud"
            case .budgetExceeded: return "budgetExceeded"
            }
        }
        if let aiError = error as? AIServiceError {
            switch aiError {
            case .httpError(let statusCode, _): return "http\(statusCode)"
            case .invalidURL: return "invalidURL"
            case .missingAPIKey: return "missingAPIKey"
            case .decodingError: return "decodingError"
            case .networkError: return "networkError"
            case .emptyResponse: return "emptyResponse"
            case .generationStopped: return "generationStopped"
            case .emptyStream: return "emptyStream"
            case .cancelled: return "cancelled"
            case .cliToolNotFound: return "cliToolNotFound"
            case .cliToolFailed(let exitCode, _): return "cliToolFailed\(exitCode)"
            case .cliToolTimeout: return "cliToolTimeout"
            case .oauthLoginRequired: return "oauthLoginRequired"
            case .oauthTokenExpired: return "oauthTokenExpired"
            }
        }
        if let urlError = error as? URLError { return "url\(urlError.code.rawValue)" }
        return String(describing: type(of: error))
    }

    func cancelGeneration() {
        guard phase == .generating else { return }
        generationTask?.cancel()
        generationTask = nil
        if var press = activePress {
            press.trace.outcome = "cancelled"
            submitTrace(press.trace)
            activePress = nil
        }
        closeToast()
        phase = .idle
    }

    // MARK: - Toast actions

    func undoOrRestore() {
        guard let press = activePress, let record = press.record else { return }
        Task { [weak self] in
            guard let self else { return }
            let undone = await self.inserter.attemptUndo(for: press.snapshot)
            if undone {
                self.dismissToast(outcome: "undone")
            } else {
                // Guaranteed recovery path (§3.5): the pre-paste text is
                // always copyable, even when the field is gone.
                ClipboardService.setText(record.recoverableText)
                self.restoreNote = Loc.shared.t("magic.toast.previous_copied")
                self.scheduleToastDismissIfSettled()
            }
        }
    }

    func regenerate() {
        rerun(hint: activePress?.hint)
    }

    func refine(_ instruction: String) {
        let existing = activePress?.hint
        let combined = [existing, instruction].compactMap { $0 }.joined(separator: "\n")
        rerun(hint: combined.isEmpty ? instruction : combined)
    }

    /// Regenerate/refine replace in place: best-effort ⌘Z first (restores
    /// the pre-paste state, including a replaced selection), then a fresh
    /// run against the original snapshot.
    private func rerun(hint: String?) {
        guard MagicPressReducer.reduce(state: reducerState(for: .regenerateOrRefine), event: .regenerateOrRefine) == .rerun
        else { return }
        guard var press = activePress, let workflow = press.workflow else { return }
        // Leave `.toast` before the async undo, not after it: two fast clicks
        // on Regenerate/Refine both passed this guard while the first was
        // still inside its undo + 150 ms sleep, submitting two traces and
        // racing two provider requests against one `activePress` — the loser
        // could still land through `handleResult`. `.generating` also makes
        // handlePress single-flight and lets Escape cancel the pending run.
        phase = .generating
        press.trace.outcome = "regenerated"
        submitTrace(press.trace)

        // A fresh trace needs a fresh timing origin. `pressStart` still points
        // at the original hotkey, so leaving it there makes `performInsert`
        // bill this generation for the first one *plus* however long the user
        // spent reading the toast before clicking Regenerate — and those
        // inflated press-to-paste samples are exactly what `TraceStats` reads
        // the §3.6 p50/p95 SLO from, so one regeneration could fail a gate that
        // nothing in the product actually missed.
        // The click is the press this run is measured from.
        pressStart = ContinuousClock().now

        var trace = PressTrace(
            snapshot: press.snapshot, decision: press.decision, classification: press.classification
        )
        trace.presentation = press.trace.presentation
        trace.chipIndexChosen = press.trace.chipIndexChosen
        trace.plannerIndexChosen = press.trace.plannerIndexChosen
        trace.latencyMs.planner = press.trace.latencyMs.planner
        press.trace = trace
        activePress = press

        cancelToastDismiss()
        Task { [weak self] in
            guard let self else { return }
            if self.activePress?.record != nil {
                _ = await self.inserter.attemptUndo(for: press.snapshot)
                // Give the target app a beat to apply the undo before the
                // replacement paste arrives.
                try? await Task.sleep(for: .milliseconds(150))
            }
            self.startRun(workflow: workflow, hint: hint)
        }
    }

    func copyResult() {
        guard let press = activePress else { return }
        let text = press.result?.output ?? press.record?.insertedText
        guard let text else { return }
        // A deliberate copy is meant to persist — plain write, no transient
        // marker.
        ClipboardService.setText(text)
        dismissToast(outcome: "copied")
    }

    /// Hold-to-confirm bypass of a verifier failure — logged, always (§10.2:
    /// its rate is a guard-health metric).
    func insertAnyway() {
        // The reducer owns the claim: a warning must be on screen, a press must
        // still exist, and no earlier accept may be inside its 150 ms focus
        // delay — `toastState` and `phase` are both unchanged across that
        // sleep, so a repeated ⌘↩ / Magic press (or a second hold) used to
        // queue another `performInsert` and paste the flagged output twice.
        guard MagicPressReducer.reduce(state: reducerState(for: .insertAnyway), event: .insertAnyway) == .insertAnyway
        else { return }
        // Re-binds the payload the decision does not carry; both halves were
        // proven above.
        guard case .panelResult(let text, .verifierFailed, _) = toastState,
              var press = activePress else { return }
        insertAnywayInFlight = true
        press.trace.outcome = "insertedAnyway"
        activePress = press
        // Yield focus only when we actually hold it (the user clicked into
        // the toast) — returnFocusToTarget skips the dance when the app
        // never became active.
        returnFocusToTarget(excluding: toastWindow)
        Task { [weak self] in
            // Let the mouse-up's event-tracking session fully close before
            // the synthetic ⌘V — a keystroke posted mid-session routes to
            // this panel, not the target app.
            try? await Task.sleep(for: .milliseconds(150))
            await self?.performInsert(text)
            self?.insertAnywayInFlight = false
        }
    }

    func makeToastKey() {
        toastWindow?.makeKey()
        cancelToastDismiss()
    }

    /// The toast's SwiftUI content grows without a state transition when the
    /// refine row expands or its text view gains lines; `show()` is not called
    /// on those, so the view asks the panel to re-measure itself.
    ///
    /// Deferred by one main-actor hop: callers are inside a button action or a
    /// height callback, so the state change that makes the content taller has
    /// not been rendered yet and `fittingSize` would still report the old one.
    func resizeToast() {
        Task { @MainActor [weak self] in
            self?.toastWindow?.resizeToFit()
        }
    }

    func dismissToast(outcome: String?) {
        // Nothing may outlive the surface it would have filled. Escape cannot
        // reach here while generating — `dismissFloatingOverlay` routes that to
        // `cancelGeneration` first — but `rerun` sits in `.generating` across an
        // async undo, and `handleResult` only no-ops on the dropped press
        // *after* the provider call has been paid for. Cancelling here makes the
        // invariant hold by construction instead of by routing order.
        generationTask?.cancel()
        generationTask = nil
        // Close first: the focus return inside needs the press's snapshot
        // (target app pid + focused element), which dies with activePress.
        closeToast()
        if var press = activePress {
            if let outcome { press.trace.outcome = outcome }
            submitTrace(press.trace)
            activePress = nil
        }
        phase = .idle
    }

    // MARK: - Toast window plumbing

    private func showToast() {
        cancelToastDismiss()
        if toastWindow == nil {
            toastWindow = MagicToastWindow(coordinator: self) { [weak self] in
                self?.dismissToast(outcome: nil)
            }
        }
        let anchor = activePress.map { CaretLocator.anchorRect(for: $0.snapshot) } ?? .zero
        toastWindow?.show(anchoredAt: anchor)
        KeyboardShortcuts.enable(.dismissMagicOverlay)
    }

    private func closeToast() {
        cancelToastDismiss()
        KeyboardShortcuts.disable(.dismissMagicOverlay)
        toastState = nil
        let wasKey = toastWindow?.isKeyWindow ?? false
        toastWindow?.orderOut(nil)
        toastWindow = nil
        if isSelfTargeted, wasKey {
            selfTargetKeyWindow?.makeKeyAndOrderFront(nil)
        }
        if wasKey { returnFocusToTarget(excluding: nil, force: true) }
    }

    private func scheduleToastDismissIfSettled() {
        // The pending timer is dropped first whatever the answer is — this is
        // also the "the user just started hovering" path, which must cancel and
        // not re-arm.
        cancelToastDismiss()
        guard MagicPressReducer.reduce(
            state: reducerState(for: .toastSettleCheck), event: .toastSettleCheck
        ) == .scheduleToastDismiss else { return }
        let dismissAfter = configStore.config.toastDismissSeconds
        toastDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(dismissAfter))
            guard !Task.isCancelled else { return }
            self?.dismissToast(outcome: nil)
        }
    }

    private func cancelToastDismiss() {
        toastDismissTask?.cancel()
        toastDismissTask = nil
    }

    // MARK: - Focus

    /// The AppState focus dance (see `dismissPopup` for the full rationale):
    /// hide or deactivate, then explicitly re-activate the app the press
    /// came from. Skipped entirely for self-targeted presses — and whenever
    /// we never actually became active (a non-activating panel can be key
    /// while the target app stays frontmost): the target still has focus,
    /// hiding our windows from the background would make macOS promote some
    /// *other* app, and on Sonoma+ the re-activation of the target can be
    /// refused — killing the paste.
    /// `force` covers the key-but-inactive case: a non-activating panel that
    /// held key focus (chip hint field) stole it from the target's window
    /// without activating us — ordering the panel out does not reliably
    /// re-focus the web page's composer, so the target must be re-activated
    /// explicitly. The hide/deactivate half stays gated on `NSApp.isActive`:
    /// running it while inactive is what promoted random third apps.
    private func returnFocusToTarget(excluding excluded: NSWindow?, force: Bool = false) {
        guard !isSelfTargeted, NSApp.isActive || force else { return }
        // The press's own snapshot knows the target app — `lastExternalApp`
        // is popup-flow state and can be stale or nil for Magic presses
        // (live bug: Escape on the LinkedIn chip panel returned focus
        // nowhere). The remembered AX element gets focus back explicitly:
        // app activation alone does not reliably re-focus a web composer.
        let target: NSRunningApplication? = activePress
            .flatMap { NSRunningApplication(processIdentifier: $0.snapshot.app.pid) }
            ?? appState?.lastExternalApp
        let element = activePress?.snapshot.focusedElement?.element
        if NSApp.isActive {
            let hasOtherWindow = NSApp.windows.contains { window in
                window.isVisible
                    && window !== chipPanel
                    && window !== toastWindow
                    && window !== excluded
                    && !(window is ProcessingHUDWindow)
                    && !(window is ErrorHUDWindow)
                    && window.className != "NSStatusBarWindow"
            }
            if hasOtherWindow {
                NSApp.deactivate()
            } else {
                NSApp.hide(nil)
            }
        }
        // Everything below lands asynchronously, so publish when the field can
        // be trusted to have focus again: a press arriving in the meantime
        // waits it out instead of snapshotting the pre-restoration field
        // (`awaitFocusSettle`). A deadline rather than a flag — it expires on
        // its own, so a press a second later pays nothing.
        focusSettlesAt = ContinuousClock().now.advanced(by: .milliseconds(Self.focusSettleMs))
        // `target` is the one place that knows, for certain, which app focus is
        // going back to. Publishing it with the deadline is what lets the next
        // press be addressed to *that* app rather than to whoever is frontmost
        // when the sleep ends.
        focusSettleTargetPid = target?.processIdentifier
        DispatchQueue.main.async {
            target?.activate(options: [.activateAllWindows])
            if let element {
                // Off the main thread on purpose: an AX write to an
                // unresponsive target blocks for the 0.35 s AX messaging
                // timeout, and on the main queue that is a beachball on top of
                // whatever the user did next. The 0.12 s delay is what
                // sequences this after `activate` (activation is asynchronous
                // in any case), and the timer is armed from inside the main-queue
                // block, so the ordering is unchanged by the hop.
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.12) {
                    AXUIElementSetAttributeValue(
                        element, kAXFocusedAttribute as CFString, kCFBooleanTrue
                    )
                }
            }
        }
    }

    /// Blocks a starting press until the focus restoration from a torn-down
    /// overlay has had time to land, and returns the app that restoration was
    /// aimed at — the press's pinned target.
    ///
    /// Nil means "no target was pinned, read the frontmost app as usual": either
    /// nothing was pending (the common `.idle` press, which pays nothing) or the
    /// deadline had already expired, which is the user closing a toast and
    /// pressing again seconds later. Nothing was waited out in that case, so
    /// there is no window during which they could have been dragged into an app
    /// they did not mean to press in, and whatever is frontmost now *is* the
    /// target — pinning a stale one would kill a perfectly deliberate press.
    private func awaitFocusSettle() async -> pid_t? {
        guard let settlesAt = focusSettlesAt else { return nil }
        focusSettlesAt = nil
        let pinned = focusSettleTargetPid
        focusSettleTargetPid = nil
        let remaining = settlesAt - ContinuousClock().now
        guard remaining > .zero else { return nil }
        try? await Task.sleep(for: remaining)
        return pinned
    }

    /// Restores the captured selection when the target dropped it (some apps
    /// collapse the selection when a panel takes key), and reports whether the
    /// field is still in the state the press was planned against.
    ///
    /// Returns false when a *different* non-empty selection is live: the user
    /// re-selected during chips or generation, and the plan — written for the
    /// old selection — would paste over text nobody addressed. Any non-empty
    /// selection must therefore be checked for identity, not just presence.
    ///
    /// Every AX read and write this needs happens inside `MagicInserter`'s
    /// reader actor, in one hop, and everything below decides on the value it
    /// hands back. Calling `AXUIElementCopyAttributeValue` /
    /// `AXUIElementSetAttributeValue` straight from here would put up to three
    /// synchronous IPC round-trips on the main actor at the 0.35 s process-wide
    /// AX messaging timeout each — up to a second of frozen UI at the one
    /// moment the user is actively waiting for text to appear, which is the
    /// stall `AXFieldReader` exists to keep off this path (R4).
    ///
    /// The suspension point that introduces is safe *here* for a reason worth
    /// stating, because it is not safe everywhere (see `focusMatches` and
    /// `lastWrite` in `MagicInserter`): the whole decision is taken from one
    /// probe read in a single hop, with no second piece of state consulted
    /// after the await, so there is no way for the two halves of the judgement
    /// to come from different versions of the world. The re-assert write that
    /// may follow is best-effort by design and is immediately re-checked by
    /// `MagicInserter.verifyFocusStillMatches`, which re-reads focus and field
    /// state from scratch before anything is pasted.
    private func reassertSelectionIfLost(_ snapshot: MagicSnapshot) async -> Bool {
        guard let element = snapshot.focusedElement,
              let range = snapshot.field?.selection?.range
        else { return true }

        // Coordinate systems: `range` is in *character* offsets — the snapshot
        // converts AX's UTF-16 ranges on the way in so every consumer can slice
        // with `String.index(_:offsetBy:)` — while
        // `kAXSelectedTextRangeAttribute` speaks UTF-16 in both directions.
        // Both halves below therefore have to translate, and the translation
        // is only meaningful against the value the field holds *now* (it may
        // have been edited while chips or the toast were up), so the probe
        // reads it fresh and unclipped rather than trusting the captured one,
        // which is truncated at `maxFieldValueChars`. The captured value is
        // handed over only as the fallback for a field that publishes no
        // readable value at all.
        let probe = await inserter.selectionProbe(
            of: element, fallbackValue: snapshot.field?.value ?? ""
        )

        switch Self.selectionVerdict(captured: range, probe: probe) {
        case .proceed:
            return true
        case .refuse:
            return false
        case .reassert(let location, let length):
            await inserter.reassertSelectedRange(
                location: location, length: length, of: element
            )
            return true
        }
    }

    /// The re-assert decision table, as a pure function of the captured range
    /// and one probe of the live field.
    ///
    /// `nonisolated static` for the same reason `utf16Range` and
    /// `AXSnapshotService.characterRange` are: every AX read it depends on has
    /// already happened, so the whole judgement — including the two ways it can
    /// refuse a paste — can be exercised directly by the tests. Against a real
    /// app it is only observable as "the text went to the toast instead", which
    /// is precisely the outcome nobody notices is wrong.
    nonisolated static func selectionVerdict(
        captured: Range<Int>, probe: MagicSelectionProbe
    ) -> MagicSelectionVerdict {
        if probe.hasLiveSelection {
            // Selection survived — but only ours may be pasted over, and the
            // two ranges must be compared in one space: a single emoji earlier
            // in the field makes the live UTF-16 range differ numerically from
            // our character range over the very same span (a spurious clipboard
            // fallback) and, worse, lets a *different* span compare equal (a
            // paste over text nobody addressed). The probe does that conversion
            // against the value it read in the same breath; a range it could
            // not map is stale by definition — treat it as someone else's.
            guard let live = probe.liveRange, live == captured else { return .refuse }
            return .proceed
        }

        // The target dropped the selection (some apps collapse it when a panel
        // takes key). Re-encode our character offsets as UTF-16 before handing
        // them back; sending the character numbers verbatim reselects a
        // shifted span, and the paste then overwrites text the user never
        // selected. If the offsets no longer fit the current value the field
        // has changed underneath the press — same class of mismatch as a
        // re-selection, and reported the same way.
        guard let cfRange = utf16Range(captured, in: probe.value) else { return .refuse }
        return .reassert(location: cfRange.location, length: cfRange.length)
    }

    /// Character offsets → the UTF-16 `CFRange` AX expects — the inverse of
    /// `AXSnapshotService.characterRange(_:in:)`. Nil when the range does not
    /// lie inside `value`, so a caller never sets a range that points nowhere.
    /// `nonisolated` for the same reason its inverse is: the arithmetic is pure
    /// and gets exercised directly by the tests.
    nonisolated static func utf16Range(_ range: Range<Int>, in value: String) -> CFRange? {
        guard range.lowerBound >= 0,
              let lower = value.index(
                value.startIndex, offsetBy: range.lowerBound, limitedBy: value.endIndex
              ),
              let upper = value.index(lower, offsetBy: range.count, limitedBy: value.endIndex)
        else { return nil }
        let utf16 = value.utf16
        return CFRange(
            location: utf16.distance(from: utf16.startIndex, to: lower),
            length: utf16.distance(from: lower, to: upper)
        )
    }

    // MARK: - Dry-run (debug surface, §17)

    /// Captures the current field, runs plan → route → assemble without
    /// executing anything, and puts the pretty-printed report on the
    /// clipboard. The 600 ms delay lets focus return to the target app after
    /// the menu closes.
    func dryRunToClipboard() {
        guard phase == .idle, let appState else { return }
        let locale = Locale.preferredLanguages.first ?? "en"
        configStore.reloadIfChanged()
        let config = configStore.config

        let warm = frontmostObserver.warm
        Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(600))
            let snapshot = await self.snapshotService.capture(
                appInfo: self.frontmostAppInfo(), locale: locale, config: config, warm: warm
            )

            let report: DryRunReport?
            do {
                let plan = try MagicPressPipeline.plan(
                    workflowStore: self.workflowStore,
                    coreStore: self.coreStore,
                    roleStore: self.roleStore,
                    providerStore: appState.providerStore,
                    config: config
                )
                report = MagicPressPipeline.dryRun(plan: plan, snapshot: snapshot)
            } catch {
                self.showHint(error.localizedDescription)
                return
            }

            guard let report else {
                self.showHint(Loc.shared.t("magic.hud.no_target"))
                return
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(report) {
                ClipboardService.setText(String(decoding: data, as: UTF8.self))
                self.showHint("Dry-run report copied to clipboard")
            }
        }
    }

    /// Aggregates every trace file into the gate report (SLO percentiles,
    /// chip top-1, warm-hit rate, R4 axErrors) and copies it as markdown.
    func traceStatsToClipboard() {
        Task { [weak self] in
            let stats = await Task.detached {
                TraceStats.load(from: Constants.Engine.logsDirectory)
            }.value
            ClipboardService.setText(stats.markdown())
            self?.showHint("Trace stats copied (\(stats.overall.presses) presses)")
        }
    }

    /// Menu-bar entry point. Clicking the status-item menu steals key focus
    /// from the target field; the press must wait for the menu to close and
    /// focus to return before the snapshot — same settle as the dry-run and
    /// insert-test menu items.
    func pressFromMenu(forceChips: Bool) {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            self?.handlePress(forceChips: forceChips)
        }
    }

    /// R1 spike surface: run the real inserter against the focused field
    /// with a canned multi-word string — no LLM call — so undo atomicity
    /// can be probed (insert → ⌘Z → re-read) deterministically and free.
    /// The 600 ms delay lets focus return to the target after the menu
    /// closes, same as the dry-run.
    func insertTestString() {
        guard phase == .idle else { return }
        let locale = Locale.preferredLanguages.first ?? "en"
        configStore.reloadIfChanged()
        let config = configStore.config

        let warm = frontmostObserver.warm
        Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(600))
            let snapshot = await self.snapshotService.capture(
                appInfo: self.frontmostAppInfo(), locale: locale, config: config, warm: warm
            )
            guard snapshot.grammarRow != .noTarget, snapshot.grammarRow != .secure else {
                self.showHint(Loc.shared.t("magic.hud.no_target"))
                return
            }
            let text = "R1SPIKE alpha bravo, charlie — delta echo."
            switch await self.inserter.insert(text, against: snapshot) {
            case .inserted(let record):
                self.showHint("Test insert: landed (confirmed: \(record.pasteConfirmed))")
            case .focusMismatch:
                self.showHint("Test insert: focus mismatch")
            case .panelOnly:
                self.showHint("Test insert: non-editable, clipboard only")
            }
        }
    }

    /// Shows the tallest toast state with canned content and no LLM call, so
    /// the panel's layout can be checked without waiting for a real press to
    /// trip the verifier.
    ///
    /// This exists because the clipping bug it exercises was invisible for a
    /// whole milestone: `MagicToastWindow` is created at a nominal 80 pt, only
    /// the verifier-failure and focus-mismatch states exceed that, and neither
    /// is reachable on demand. The warning list, the output scroll view, and
    /// the action row must all be visible and clickable here.
    func showToastPanelTest(reason: MagicToastPanelReason = .verifierFailed) {
        guard phase == .idle else { return }
        phase = .toast
        toastState = .panelResult(
            text: """
            Hi Dana — thanks for the nudge. I can get the revised deck over by \
            Thursday, and the invoice total comes to €4,820. Let me know if the \
            Friday slot suits you better and I'll move things around.
            """,
            reason: reason,
            warnings: reason == .verifierFailed
                ? [
                    VerifierWarning(
                        check: .actionableUngrounded,
                        messageKey: "magic.verifier.ungrounded",
                        messageArgs: ["€4,820"]
                    ),
                    VerifierWarning(
                        check: .concreteness,
                        messageKey: "magic.verifier.actionable_untrusted",
                        messageArgs: ["Thursday"]
                    ),
                    VerifierWarning(
                        check: .length,
                        messageKey: "magic.verifier.too_long",
                        messageArgs: ["44", "30"]
                    ),
                ]
                : []
        )
        showToast()
    }

    // MARK: - Onboarding

    /// Writes the onboarding interview into the core/ wiki. Only fields the
    /// user actually filled are written; the seeded templates otherwise stay
    /// untouched. The three sample messages land in writing-style.md — in V0
    /// they ride the pinned slot (a structured few-shot store is a later
    /// milestone).
    func saveOnboardingProfile(name: String, role: String, sampleMessages: [String]) {
        if !name.isEmpty || !role.isEmpty {
            let identity = """
            # Who I am

            - Name: \(name)
            - Role: \(role)
            - Company / context:
            - Languages I write in:
            """
            try? identity.write(
                to: Constants.Engine.coreDirectory.appendingPathComponent("identity.md"),
                atomically: true, encoding: .utf8
            )
        }

        if !sampleMessages.isEmpty {
            let styleURL = Constants.Engine.coreDirectory.appendingPathComponent("writing-style.md")
            var style = (try? String(contentsOf: styleURL, encoding: .utf8)) ?? EngineSeedContent.writingStyle
            let heading = "## Examples of how I actually write"
            if let headingRange = style.range(of: heading) {
                style = String(style[..<headingRange.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let examples = sampleMessages
                .map { "> " + $0.replacingOccurrences(of: "\n", with: "\n> ") }
                .joined(separator: "\n\n")
            style = style.trimmingCharacters(in: .whitespacesAndNewlines)
                + "\n\n\(heading)\n\n\(examples)\n"
            try? style.write(to: styleURL, atomically: true, encoding: .utf8)
        }

        coreStore.reloadIfChanged()
    }

    // MARK: - Traces & HUD

    private func submitTrace(_ trace: PressTrace) {
        // This context belongs to the press being submitted and to nothing
        // else, so it is consumed here whether or not a debug file is
        // written. Clearing it only on the logging path let a failure recorded
        // while the checkbox was off survive in `lastErrorDescription`, and the
        // next entry after the user enabled logging — typically a perfectly
        // healthy press — was filed with an unrelated provider error under its
        // Error section, i.e. a diagnostic record that actively misleads.
        defer {
            lastBareSnapshot = nil
            lastErrorDescription = nil
        }

        var stamped = trace
        if let start = pressStart {
            stamped.latencyMs.total = Self.ms(ContinuousClock().now - start)
        }
        Task { [traceLogger] in await traceLogger.append(stamped) }

        // Full-content debug log (opt-in via `debug_log_enabled` in
        // config.yaml — the Settings → Magic checkbox is a view over that
        // key): everything the contentless trace deliberately omits.
        guard configStore.config.debugLogEnabled == 1 else { return }
        let press = activePress
        let entry = MagicDebugEntry(
            trace: stamped,
            snapshot: press?.snapshot ?? lastBareSnapshot,
            classification: press?.classification,
            decision: press?.decision,
            workflowID: press?.workflow?.id ?? stamped.chosenID,
            workflowChain: press?.workflow?.chain,
            hint: press?.hint,
            assembled: press?.result?.assembled,
            output: press?.result?.output,
            verdict: press?.result?.verdict,
            errorDescription: lastErrorDescription
        )
        Task { [debugLogger] in await debugLogger.write(entry) }
    }

    /// Context for debug entries on paths that have no ActivePress (dead
    /// presses) or that carry an error.
    @ObservationIgnored private var lastBareSnapshot: MagicSnapshot?
    @ObservationIgnored private var lastErrorDescription: String?

    private func logBareTrace(snapshot: MagicSnapshot, outcome: String) {
        var trace = PressTrace(snapshot: snapshot, decision: nil, classification: nil)
        trace.outcome = outcome
        lastBareSnapshot = snapshot
        submitTrace(trace)
    }

    /// Transient message HUD. With a snapshot it anchors above the focused
    /// field like every other Magic panel — a press error appearing in the
    /// screen center reads as unrelated to what the user just did.
    private func showHint(_ message: String, near snapshot: MagicSnapshot? = nil) {
        closeHint()
        let hud = ErrorHUDWindow(promptName: Loc.shared.t("magic.name"), message: message) { [weak self] in
            self?.closeHint()
        }
        hintHUD = hud
        if let snapshot {
            hud.show(anchoredAt: CaretLocator.anchorRect(for: snapshot))
        } else {
            hud.showAtCenter()
        }
        KeyboardShortcuts.enable(.dismissMagicOverlay)
        Task { [weak self, weak hud] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, let hud, self.hintHUD === hud else { return }
            self.closeHint()
        }
    }

    private func closeHint() {
        guard let hud = hintHUD else { return }
        hud.close()
        hintHUD = nil
        // Only release Escape when no other overlay still owns it.
        if chipPanel == nil, toastWindow == nil, phase != .generating {
            KeyboardShortcuts.disable(.dismissMagicOverlay)
        }
    }

    private func frontmostAppInfo() -> MagicSnapshot.AppInfo {
        let app = NSWorkspace.shared.frontmostApplication
        return MagicSnapshot.AppInfo(
            name: app?.localizedName,
            bundleId: app?.bundleIdentifier,
            pid: app?.processIdentifier ?? -1
        )
    }

    private static func ms(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1000)
            + Int(duration.components.attoseconds / 1_000_000_000_000_000)
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if case AIServiceError.cancelled = error { return true }
        return (error as? URLError)?.code == .cancelled
    }
}
