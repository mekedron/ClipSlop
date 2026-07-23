import AppKit
@preconcurrency import ApplicationServices
import os

enum MagicToastPanelReason: Sendable, Equatable {
    case nonEditable
    case focusMismatch
    case verifierFailed
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
        case chips
        case generating
        case toast
    }

    private(set) var phase: Phase = .idle
    var toastState: MagicToastState?
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
    @ObservationIgnored private var toastDismissTask: Task<Void, Never>?
    @ObservationIgnored private var pressStart: ContinuousClock.Instant?
    private static let logger = Logger(subsystem: Constants.bundleIdentifier, category: "engine.magic")

    init() {
        EngineSeedContent.seedIfNeeded()
        workflowStore = WorkflowStore()
        coreStore = CoreFileStore()
        roleStore = EngineRoleStore()
        configStore = EngineConfigStore()
        Task { [traceLogger, debugLogger] in
            await traceLogger.pruneOldLogs()
            await debugLogger.pruneOldLogs()
        }
    }

    /// True when the press targets ClipSlop's own windows (the onboarding
    /// sandbox, a Settings field). Skips the focus dance — there is no
    /// external app to return to.
    private var isSelfTargeted: Bool {
        activePress?.snapshot.app.bundleId == Bundle.main.bundleIdentifier
    }

    // MARK: - Press entry

    func handlePress(forceChips: Bool) {
        switch phase {
        case .collecting, .generating:
            // Single-flight; ✕ on the toast is the cancel affordance (R10).
            return
        case .chips:
            // Double-press: the open panel *is* the first-press state —
            // accept the top intent (§3.3 override).
            if !forceChips { selectChip(0) }
            return
        case .toast:
            dismissToast(outcome: nil)
        case .idle:
            break
        }

        guard PermissionService.isAccessibilityGranted else {
            appState?.showPermissionAlert()
            return
        }

        phase = .collecting
        pressStart = ContinuousClock().now
        let appInfo = frontmostAppInfo()
        let locale = Locale.preferredLanguages.first ?? "en"
        configStore.reloadIfChanged()
        let config = configStore.config

        Task { [weak self] in
            guard let self else { return }
            let clock = ContinuousClock()
            let snapshotStart = clock.now
            var snapshot = await self.snapshotService.capture(appInfo: appInfo, locale: locale, config: config)
            if MagicSelectionCapture.isNeeded(for: snapshot) {
                snapshot = await MagicSelectionCapture.refine(snapshot)
            }
            let snapshotMs = Self.ms(clock.now - snapshotStart)
            self.continuePress(snapshot: snapshot, snapshotMs: snapshotMs, forceChips: forceChips)
        }
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
                providerStore: appState.providerStore
            )
        } catch {
            logBareTrace(snapshot: snapshot, outcome: "error:plan")
            showHint(error.localizedDescription)
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
            showChips(ranked)
        }
    }

    // MARK: - Chips

    private func showChips(_ candidates: [ResolvedWorkflow]) {
        guard !candidates.isEmpty else {
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
            onSelect: { [weak self] index in Task { @MainActor in self?.selectChip(index) } },
            onHint: { [weak self] hint in Task { @MainActor in self?.submitHint(hint) } },
            onDismiss: { [weak self] in Task { @MainActor in self?.dismissChips() } }
        )
        chipPanel = panel
        panel.show(anchoredAt: anchor)
    }

    func selectChip(_ index: Int) {
        guard phase == .chips, var press = activePress else { return }
        let candidates = press.decision.chipCandidates
        guard index < candidates.count else { return }

        press.trace.chipIndexChosen = index
        activePress = press
        closeChipPanel(returnFocus: true)
        startRun(workflow: candidates[index], hint: nil)
    }

    func submitHint(_ hint: String) {
        guard phase == .chips, var press = activePress else { return }
        guard let workflow = press.decision.chipCandidates.first else { return }
        press.trace.chipIndexChosen = 0
        activePress = press
        closeChipPanel(returnFocus: true)
        startRun(workflow: workflow, hint: hint)
    }

    func dismissChips() {
        guard phase == .chips else { return }
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
        panel.orderOut(nil)
        if returnFocus { returnFocusToTarget(excluding: nil) }
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
        var trace = result.traceDraft
        trace.latencyMs.snapshot = press.trace.latencyMs.snapshot
        trace.presentation = press.trace.presentation
        trace.chipIndexChosen = press.trace.chipIndexChosen
        press.trace = trace
        activePress = press

        if result.verdict.passed {
            await performInsert(result.output)
        } else {
            phase = .toast
            toastState = .panelResult(
                text: result.output, reason: .verifierFailed, warnings: result.verdict.warnings
            )
            showToast()
        }
    }

    private func performInsert(_ text: String) async {
        guard var press = activePress else { return }

        // After a chip round-trip some apps drop the selection on
        // deactivate — re-assert the captured range before pasting over it.
        reassertSelectionIfLost(press.snapshot)

        let outcome = await inserter.insert(text, against: press.snapshot)
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
        if var press = activePress {
            press.trace.outcome = "error:generation:\(Self.errorKind(error))"
            lastErrorDescription = error.localizedDescription
            activePress = press
            submitTrace(press.trace)
            activePress = nil
        }
        closeToast()
        phase = .idle
        showHint(error.localizedDescription)
    }

    /// Short, contentless error class for traces ("http429", "url-1009",
    /// "emptyResponse") — enough to see failure patterns without logging
    /// message text.
    private static func errorKind(_ error: Error) -> String {
        if let aiError = error as? AIServiceError {
            switch aiError {
            case .httpError(let statusCode, _): return "http\(statusCode)"
            case .invalidURL: return "invalidURL"
            case .missingAPIKey: return "missingAPIKey"
            case .decodingError: return "decodingError"
            case .networkError: return "networkError"
            case .emptyResponse: return "emptyResponse"
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
        guard phase == .toast, var press = activePress, let workflow = press.workflow else { return }
        press.trace.outcome = "regenerated"
        submitTrace(press.trace)

        var trace = PressTrace(
            snapshot: press.snapshot, decision: press.decision, classification: press.classification
        )
        trace.presentation = press.trace.presentation
        trace.chipIndexChosen = press.trace.chipIndexChosen
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
        guard case .panelResult(let text, .verifierFailed, _) = toastState else { return }
        guard var press = activePress else { return }
        press.trace.outcome = "insertedAnyway"
        activePress = press
        // Yield focus only when we actually hold it (the user clicked into
        // the toast). Holding the button on a non-activating panel leaves
        // the target app frontmost — hiding our windows then would make
        // macOS promote some *other* app, and on Sonoma+ the re-activation
        // of the target can be refused, killing the paste.
        if NSApp.isActive {
            returnFocusToTarget(excluding: toastWindow)
        }
        Task { [weak self] in
            // Let the mouse-up's event-tracking session fully close before
            // the synthetic ⌘V — a keystroke posted mid-session routes to
            // this panel, not the target app.
            try? await Task.sleep(for: .milliseconds(150))
            await self?.performInsert(text)
        }
    }

    func makeToastKey() {
        toastWindow?.makeKey()
        cancelToastDismiss()
    }

    func dismissToast(outcome: String?) {
        if var press = activePress {
            if let outcome { press.trace.outcome = outcome }
            submitTrace(press.trace)
            activePress = nil
        }
        closeToast()
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
    }

    private func closeToast() {
        cancelToastDismiss()
        toastState = nil
        let wasKey = toastWindow?.isKeyWindow ?? false
        toastWindow?.orderOut(nil)
        toastWindow = nil
        if wasKey { returnFocusToTarget(excluding: nil) }
    }

    private func scheduleToastDismissIfSettled() {
        cancelToastDismiss()
        guard phase == .toast, !toastHovered else { return }
        guard toastWindow?.isKeyWindow != true else { return }
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
    /// came from. Skipped entirely for self-targeted presses.
    private func returnFocusToTarget(excluding excluded: NSWindow?) {
        guard !isSelfTargeted else { return }
        let target = appState?.lastExternalApp
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
        DispatchQueue.main.async {
            target?.activate(options: [.activateAllWindows])
        }
    }

    private func reassertSelectionIfLost(_ snapshot: MagicSnapshot) {
        guard let element = snapshot.focusedElement?.element,
              let range = snapshot.field?.selection?.range
        else { return }

        var currentRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &currentRef
        ) == .success, let currentRef, CFGetTypeID(currentRef) == AXValueGetTypeID() {
            var current = CFRange()
            if AXValueGetValue((currentRef as! AXValue), .cfRange, &current), current.length > 0 {
                return  // selection survived; leave it alone
            }
        }

        var cfRange = CFRange(location: range.lowerBound, length: range.count)
        if let value = AXValueCreate(.cfRange, &cfRange) {
            AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value)
        }
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

        Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(600))
            let snapshot = await self.snapshotService.capture(
                appInfo: self.frontmostAppInfo(), locale: locale, config: config
            )

            let report: DryRunReport?
            do {
                let plan = try MagicPressPipeline.plan(
                    workflowStore: self.workflowStore,
                    coreStore: self.coreStore,
                    roleStore: self.roleStore,
                    providerStore: appState.providerStore
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
        var stamped = trace
        if let start = pressStart {
            stamped.latencyMs.total = Self.ms(ContinuousClock().now - start)
        }
        Task { [traceLogger] in await traceLogger.append(stamped) }

        // Full-content debug log (opt-in, Settings → Magic): everything the
        // contentless trace deliberately omits.
        guard appState?.settings.magicDebugLogging == true else { return }
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
        lastBareSnapshot = nil
        lastErrorDescription = nil
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

    private func showHint(_ message: String) {
        hintHUD?.close()
        let hud = ErrorHUDWindow(promptName: Loc.shared.t("magic.name"), message: message) { [weak self] in
            self?.hintHUD?.close()
            self?.hintHUD = nil
        }
        hintHUD = hud
        hud.showAtCenter()
        Task { [weak self, weak hud] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, let hud, self.hintHUD === hud else { return }
            hud.close()
            self.hintHUD = nil
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
