import Foundation

/// The press band's transition table, lifted out of `MagicPressCoordinator` so
/// it can be read — and tested — without AppKit, AX, a window server or a
/// provider.
///
/// Six consecutive review rounds found bugs in this band and every one of them
/// was a *transition* bug rather than an algorithmic one: a chip accepted while
/// the panel was still key and cancelled by the panel's own `resignKey`
/// teardown; two fast Regenerate clicks both passing the `.toast` guard and
/// racing two provider calls against one `activePress`; a repeated ⌘↩ pasting
/// flagged output twice across `insertAnyway`'s focus delay; a forced-chips
/// press over a verifier warning swallowed as an "insert it" accept. None of
/// them were reachable from a test, because the decisions lived inside methods
/// that also drove windows, AX and the network.
///
/// So the decision moves here and stays pure: `reduce` reads a value and
/// returns a value. The coordinator keeps the *doing*, in exactly the order it
/// did before — several of those orderings are themselves bug fixes (leaving
/// `.chips` before closing the panel, entering `.generating` before the async
/// undo, closing the toast before clearing `activePress`) and the reducer
/// deliberately has no opinion about them. It answers WHAT, never WHEN.
enum MagicPressReducer {
    /// Everything the transitions actually read — and nothing else. No windows,
    /// no tasks, no snapshot: a decision that needs a new fact has to name it
    /// here, which is the whole point of the split.
    struct State: Equatable {
        var phase: MagicPressCoordinator.Phase = .idle
        /// `toastState` is `.panelResult(_, .verifierFailed, _)`. The only
        /// thing on the toast the press band branches on: it is what arms ⌘↩,
        /// what turns a plain press into an accept, and what `insertAnyway`
        /// refuses to run without.
        var verifierWarningPending = false
        /// An accepted verifier warning is inside its 150 ms focus delay.
        /// Neither `phase` nor `toastState` moves across that gap, so this flag
        /// is the only thing standing between a repeated ⌘↩ and a double paste.
        var insertAnywayInFlight = false
        var chipPanelOpen = false
        /// `activePress.decision.chipCandidates.count` — an index the panel
        /// offers but the decision no longer has a workflow for is not an
        /// accept, yet it is still a human touch that kills the planner.
        var chipCandidateCount = 0
        var toastOpen = false
        var toastIsKey = false
        var toastHovered = false
        var hintOpen = false
        var hasActivePress = false
        /// `activePress.workflow` — nil until a chip (or the silent route) has
        /// chosen one, and regenerate/refine have nothing to re-run without it.
        var hasWorkflow = false
        var accessibilityGranted = true
    }

    /// The decision-bearing inputs. Payload that only the executor needs (the
    /// hint text, the output string behind a verifier warning) stays out: it
    /// changes nothing about which transition is taken.
    enum Event: Equatable {
        /// The Magic hotkey. `forceChips` is ⌘⌃⇧M — "always ask me".
        case press(forceChips: Bool)
        /// The global Escape hotkey, armed only while an overlay is visible.
        case dismissOverlay
        case selectChip(Int)
        case submitHint
        case regenerateOrRefine
        case insertAnyway
        /// The toast's auto-dismiss timer wants to (re)arm itself.
        case toastSettleCheck
    }

    enum Action: Equatable {
        case ignore
        case startPress(forceChips: Bool)
        /// A press over a toast tears the toast down first, and it does so even
        /// when the permission gate is about to refuse the press — the toast
        /// belongs to a press that is over either way.
        case dismissToastThenStartPress(forceChips: Bool)
        case showPermissionAlert
        case dismissToastThenShowPermissionAlert
        /// The double-press override: route through the normal chip pick for
        /// index 0 rather than duplicating its planner-cancel + trace stamp.
        case acceptTopChip
        case acceptChip(index: Int)
        /// The hint field's Return: the top candidate, carrying the typed hint.
        case acceptChipWithHint
        /// A chip event that names no candidate. Nothing is accepted, but the
        /// planner still loses the race — a human touched the panel.
        case cancelPlannerRace
        case insertAnyway
        case rerun
        case cancelPlanner
        case cancelGeneration
        case dismissChips
        case dismissToast
        case closeHint
        case scheduleToastDismiss
    }

    static func reduce(state: State, event: Event) -> Action {
        switch event {
        case .press(let forceChips):
            return press(state, forceChips: forceChips)

        case .dismissOverlay:
            return dismissOverlay(state)

        case .selectChip(let index):
            return chipPick(state, index: index, withHint: false)

        case .submitHint:
            // The hint always addresses the top candidate — the panel's own
            // ordering is the choice the user did not make explicitly.
            return chipPick(state, index: 0, withHint: true)

        case .regenerateOrRefine:
            // Both the phase and the press must still be there. Two fast clicks
            // used to pass this together: the first one now leaves `.toast`
            // *before* its async undo, so the second lands here in `.generating`
            // and is refused instead of racing a second provider call against
            // the one `activePress`.
            guard state.phase == .toast, state.hasActivePress, state.hasWorkflow else {
                return .ignore
            }
            return .rerun

        case .insertAnyway:
            // The double-paste guard. `verifierWarningPending` is the
            // affordance being on screen; `insertAnywayInFlight` is the 150 ms
            // focus delay a second ⌘↩ (or a second hold, or a plain Magic
            // press) used to slip through while nothing else had changed.
            guard state.verifierWarningPending,
                  state.hasActivePress,
                  !state.insertAnywayInFlight
            else { return .ignore }
            return .insertAnyway

        case .toastSettleCheck:
            // Auto-dismiss is for a toast nobody is using: hovering it or
            // clicking into it (key) means the user is reading or about to
            // refine, and a toast that vanishes mid-sentence loses the output.
            guard state.phase == .toast, !state.toastHovered, !state.toastIsKey else {
                return .ignore
            }
            return .scheduleToastDismiss
        }
    }

    private static func press(_ state: State, forceChips: Bool) -> Action {
        switch state.phase {
        case .collecting, .generating:
            // Single-flight; ✕ on the toast is the cancel affordance (R10).
            return .ignore

        case .chips, .planning:
            // Double-press: the open panel *is* the first-press state — accept
            // the top intent (§3.3 override). During `.planning` the panel is
            // visible too; the human pick cancels the planner. A FORCED press
            // asked for the panel that is already up, so it does nothing.
            return forceChips ? .ignore : .acceptTopChip

        case .toast:
            // With verifier warnings pending, a PLAIN press means "yes, insert
            // it" — the keyboard twin of hold-to-insert, like the double-press
            // accept on chips. A forced-chips press means the opposite ("always
            // ask me"), so it must not be swallowed as an accept: it tears the
            // warning panel down and starts a fresh forced press, exactly like
            // it does from every other toast state. Without the `!forceChips`
            // half, ⌘⌃⇧M pasted the flagged output instead of re-asking — the
            // same distinction the `.chips`/`.planning` case above makes.
            if !forceChips, state.verifierWarningPending { return .insertAnyway }
            return state.accessibilityGranted
                ? .dismissToastThenStartPress(forceChips: forceChips)
                : .dismissToastThenShowPermissionAlert

        case .idle:
            return state.accessibilityGranted
                ? .startPress(forceChips: forceChips)
                : .showPermissionAlert
        }
    }

    /// Escape's routing precedence, as an ordered chain rather than five
    /// independent guards: the chip panel is dismissed even mid-`planning`
    /// (that is what cancels the planner *and* records the dismissal), a
    /// planner racing with no panel yet is cancelled, a generation in flight is
    /// cancelled, and only then does the toast — or, last, the hint HUD — get
    /// the key. Order is the behaviour here; the phase and the window are
    /// different facts and both surfaces can be up at once.
    private static func dismissOverlay(_ state: State) -> Action {
        if state.chipPanelOpen { return .dismissChips }
        if state.phase == .planning { return .cancelPlanner }
        if state.phase == .generating { return .cancelGeneration }
        if state.toastOpen { return .dismissToast }
        if state.hintOpen { return .closeHint }
        return .ignore
    }

    private static func chipPick(_ state: State, index: Int, withHint: Bool) -> Action {
        guard state.phase == .chips || state.phase == .planning, state.hasActivePress else {
            return .ignore
        }
        // Bounds first, planner second — but both are reported, because the
        // coordinator kills the planner on either. (The lower bound cannot be
        // hit from the panel, which only ever offers 0…3; it is here so the
        // reducer can never name an index a caller would subscript with.)
        guard index >= 0, index < state.chipCandidateCount else { return .cancelPlannerRace }
        return withHint ? .acceptChipWithHint : .acceptChip(index: index)
    }
}
