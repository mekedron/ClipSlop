import Foundation
import Testing
@testable import ClipSlop

// The press band's transition table, under test at last. Every bug six review
// rounds found in `MagicPressCoordinator` was a transition bug — a chip
// cancelled by its own panel teardown, two Regenerate clicks racing one press,
// a repeated ⌘↩ pasting twice, a forced press swallowed as an accept — and none
// of them were reachable while the decisions lived inside methods that also
// drove windows and AX. `MagicPressReducer` is a value in, a value out; these
// are the cases those bugs would have failed.

/// A chip panel on screen with `candidates` chips and a live press behind it.
private func chipsUp(
    phase: MagicPressCoordinator.Phase, candidates: Int = 3
) -> MagicPressReducer.State {
    MagicPressReducer.State(
        phase: phase, chipPanelOpen: true, chipCandidateCount: candidates, hasActivePress: true
    )
}

/// A finished press showing its toast. `verifierWarning` is the flagged-output
/// panel — the state ⌘↩, hold-to-insert and the plain-press accept are armed in.
private func toastUp(
    verifierWarning: Bool = false,
    insertAnywayInFlight: Bool = false,
    hasWorkflow: Bool = true
) -> MagicPressReducer.State {
    MagicPressReducer.State(
        phase: .toast,
        verifierWarningPending: verifierWarning,
        insertAnywayInFlight: insertAnywayInFlight,
        toastOpen: true,
        hasActivePress: true,
        hasWorkflow: hasWorkflow
    )
}

@Suite("Press band: the Magic hotkey")
struct MagicPressReducerPressTests {
    private func press(
        _ state: MagicPressReducer.State, forceChips: Bool
    ) -> MagicPressReducer.Action {
        MagicPressReducer.reduce(state: state, event: .press(forceChips: forceChips))
    }

    /// The whole matrix, phase by phase, in both flavours. Written out rather
    /// than looped: this table IS the feature, and a diff that changes one cell
    /// should read as one changed line.
    @Test func coversEveryPhaseInBothFlavours() {
        let idle = MagicPressReducer.State(phase: .idle)
        #expect(press(idle, forceChips: false) == .startPress(forceChips: false))
        #expect(press(idle, forceChips: true) == .startPress(forceChips: true))

        // Single-flight: the press already in flight owns the band, and ✕ on
        // the toast is the cancel affordance (R10).
        let collecting = MagicPressReducer.State(phase: .collecting)
        #expect(press(collecting, forceChips: false) == .ignore)
        #expect(press(collecting, forceChips: true) == .ignore)

        let generating = MagicPressReducer.State(
            phase: .generating, toastOpen: true, hasActivePress: true, hasWorkflow: true
        )
        #expect(press(generating, forceChips: false) == .ignore)
        #expect(press(generating, forceChips: true) == .ignore)

        // Double-press over an open panel accepts the top intent (§3.3). A
        // FORCED press asked for the panel that is already up: nothing to do.
        let planning = chipsUp(phase: .planning)
        #expect(press(planning, forceChips: false) == .acceptTopChip)
        #expect(press(planning, forceChips: true) == .ignore)

        let chips = chipsUp(phase: .chips)
        #expect(press(chips, forceChips: false) == .acceptTopChip)
        #expect(press(chips, forceChips: true) == .ignore)

        // A toast with no verifier warning is just the last press's residue:
        // tear it down and start a new one, forced flag carried through.
        let toast = toastUp()
        #expect(press(toast, forceChips: false) == .dismissToastThenStartPress(forceChips: false))
        #expect(press(toast, forceChips: true) == .dismissToastThenStartPress(forceChips: true))
    }

    /// The round-6 fix, which never got its regression test. A PLAIN press over
    /// a verifier warning is the keyboard twin of hold-to-insert ("yes, insert
    /// it"). A forced-chips press means the opposite — "always ask me" — so it
    /// must not be swallowed as an accept. Before the `!forceChips` half,
    /// ⌘⌃⇧M over a flagged result pasted that result instead of re-asking.
    @Test func aVerifierWarningTakesAPlainPressAsAnAcceptAndAForcedOneAsAReAsk() {
        let warned = toastUp(verifierWarning: true)
        #expect(press(warned, forceChips: false) == .insertAnyway)
        #expect(press(warned, forceChips: true) == .dismissToastThenStartPress(forceChips: true))
    }

    /// The accept only exists while the warning is on screen: the same toast
    /// without one takes both presses as a restart.
    @Test func aToastWithoutAWarningNeverAccepts() {
        #expect(press(toastUp(), forceChips: false) == .dismissToastThenStartPress(forceChips: false))
    }

    /// `insertAnywayInFlight` is not the press's business — it never was. The
    /// press still routes to the accept, and the accept declines itself (see
    /// `theSecondConfirmationIsRefused`). Collapsing the two steps here would
    /// look equivalent and quietly move the double-paste guard somewhere it is
    /// only checked on one of the three ways in (⌘↩, hold, hotkey).
    @Test func aPressStillDelegatesTheInFlightCheckToTheAcceptItself() {
        let claimed = toastUp(verifierWarning: true, insertAnywayInFlight: true)
        #expect(press(claimed, forceChips: false) == .insertAnyway)
        #expect(MagicPressReducer.reduce(state: claimed, event: .insertAnyway) == .ignore)
    }

    /// Accessibility can be revoked between presses. The gate refuses the new
    /// press — but the old toast still comes down, because it belongs to a
    /// press that is over either way.
    @Test func thePermissionGateRefusesThePressAndTheToastStillComesDown() {
        var idle = MagicPressReducer.State(phase: .idle)
        idle.accessibilityGranted = false
        #expect(press(idle, forceChips: false) == .showPermissionAlert)

        var toast = toastUp()
        toast.accessibilityGranted = false
        #expect(press(toast, forceChips: false) == .dismissToastThenShowPermissionAlert)
        #expect(press(toast, forceChips: true) == .dismissToastThenShowPermissionAlert)

        // The accept path is not permission-gated: the paste is a continuation
        // of a press that already had Accessibility when it captured.
        var warned = toastUp(verifierWarning: true)
        warned.accessibilityGranted = false
        #expect(press(warned, forceChips: false) == .insertAnyway)
    }
}

@Suite("Press band: Escape routing")
struct MagicPressReducerDismissTests {
    private func escape(_ state: MagicPressReducer.State) -> MagicPressReducer.Action {
        MagicPressReducer.reduce(state: state, event: .dismissOverlay)
    }

    /// The precedence chain, asserted from the top down by removing one surface
    /// at a time from a state where all five are somehow up. This used to be an
    /// if/else-if ladder in `dismissFloatingOverlay` — exactly the kind of
    /// ordering that rots silently, because every individual branch keeps
    /// working while the wrong one wins.
    @Test func chipPanelBeatsPlannerBeatsGeneratingBeatsToastBeatsHint() {
        var everything = MagicPressReducer.State(
            phase: .planning,
            chipPanelOpen: true,
            chipCandidateCount: 3,
            toastOpen: true,
            hintOpen: true,
            hasActivePress: true
        )
        #expect(escape(everything) == .dismissChips)

        // No panel, but the planner is still racing its hard cap.
        everything.chipPanelOpen = false
        #expect(escape(everything) == .cancelPlanner)

        // Generating shows a toast of its own, and Escape must kill the
        // provider call rather than merely close the surface reporting it.
        everything.phase = .generating
        #expect(escape(everything) == .cancelGeneration)

        everything.phase = .toast
        #expect(escape(everything) == .dismissToast)

        everything.toastOpen = false
        #expect(escape(everything) == .closeHint)

        everything.hintOpen = false
        #expect(escape(everything) == .ignore)
    }

    /// The hotkey is only armed while a surface is up, but arming and disarming
    /// are asynchronous — an Escape that arrives with nothing on screen must do
    /// nothing at all rather than fall through to some phase-based default.
    @Test func escapeWithNothingOnScreenIsIgnored() {
        #expect(escape(MagicPressReducer.State(phase: .idle)) == .ignore)
        #expect(escape(MagicPressReducer.State(phase: .toast)) == .ignore)
        #expect(escape(MagicPressReducer.State(phase: .collecting)) == .ignore)
    }

    /// Phase and window are different facts: the panel is dismissed even in
    /// `.planning` (which is what cancels the planner *and* records the press
    /// as dismissed), and the planner is cancelled even with no panel yet.
    @Test func theChipPanelIsDismissedInEitherChipPhase() {
        #expect(escape(chipsUp(phase: .chips)) == .dismissChips)
        #expect(escape(chipsUp(phase: .planning)) == .dismissChips)
        #expect(
            escape(MagicPressReducer.State(phase: .planning, hasActivePress: true)) == .cancelPlanner
        )
    }
}

@Suite("Press band: chip picks")
struct MagicPressReducerChipTests {
    private func pick(_ state: MagicPressReducer.State, _ index: Int) -> MagicPressReducer.Action {
        MagicPressReducer.reduce(state: state, event: .selectChip(index))
    }

    private func hint(_ state: MagicPressReducer.State) -> MagicPressReducer.Action {
        MagicPressReducer.reduce(state: state, event: .submitHint)
    }

    @Test func aPickIsAcceptedOnlyInAPanelPhaseWithALivePress() {
        #expect(pick(chipsUp(phase: .chips), 2) == .acceptChip(index: 2))
        #expect(pick(chipsUp(phase: .planning), 0) == .acceptChip(index: 0))

        // The panel's callbacks can outlive the phase they belong to (a chip
        // clicked as the panel is being torn down); those must no-op, not
        // re-enter a press that has already moved on.
        #expect(pick(MagicPressReducer.State(phase: .idle, hasActivePress: true), 0) == .ignore)
        #expect(pick(MagicPressReducer.State(phase: .generating, hasActivePress: true), 0) == .ignore)
        #expect(pick(MagicPressReducer.State(phase: .toast, hasActivePress: true), 0) == .ignore)
        // Phase without a press: nothing to stamp a choice onto.
        var pressless = chipsUp(phase: .chips)
        pressless.hasActivePress = false
        #expect(pick(pressless, 0) == .ignore)
    }

    /// A digit the panel does not have a workflow for accepts nothing — but the
    /// planner still dies, because a human just touched the panel and their
    /// intent outranks the in-flight guess either way.
    @Test func anOutOfRangePickStillKillsThePlanner() {
        let two = chipsUp(phase: .planning, candidates: 2)
        #expect(pick(two, 2) == .cancelPlannerRace)
        #expect(pick(two, 99) == .cancelPlannerRace)
        #expect(pick(two, -1) == .cancelPlannerRace)
        #expect(pick(chipsUp(phase: .chips, candidates: 0), 0) == .cancelPlannerRace)
    }

    /// Typing a hint is an accept of the top candidate carrying an instruction;
    /// the hint text itself decides nothing, so it never reaches the reducer.
    @Test func aHintAcceptsTheTopCandidate() {
        #expect(hint(chipsUp(phase: .chips)) == .acceptChipWithHint)
        #expect(hint(chipsUp(phase: .planning)) == .acceptChipWithHint)
        #expect(hint(MagicPressReducer.State(phase: .toast, hasActivePress: true)) == .ignore)
    }

    @Test func aHintWithNothingToRunOnlyKillsThePlanner() {
        #expect(hint(chipsUp(phase: .planning, candidates: 0)) == .cancelPlannerRace)
    }
}

@Suite("Press band: toast actions")
struct MagicPressReducerToastTests {
    private func confirm(_ state: MagicPressReducer.State) -> MagicPressReducer.Action {
        MagicPressReducer.reduce(state: state, event: .insertAnyway)
    }

    private func rerun(_ state: MagicPressReducer.State) -> MagicPressReducer.Action {
        MagicPressReducer.reduce(state: state, event: .regenerateOrRefine)
    }

    /// The double-paste guard. Neither `phase` nor `toastState` changes across
    /// `insertAnyway`'s 150 ms focus delay, so `insertAnywayInFlight` is the
    /// only thing that tells the second ⌘↩ apart from the first — without it
    /// the flagged output was pasted twice.
    @Test func theSecondConfirmationIsRefused() {
        #expect(confirm(toastUp(verifierWarning: true)) == .insertAnyway)
        #expect(confirm(toastUp(verifierWarning: true, insertAnywayInFlight: true)) == .ignore)
    }

    /// ⌘↩ is armed by `toastState`, not by the phase, so the warning and the
    /// press it belongs to are what must be checked — an accept with no
    /// `activePress` would have nothing to stamp `insertedAnyway` on.
    @Test func aConfirmationNeedsBothAWarningAndItsPress() {
        #expect(confirm(toastUp()) == .ignore)
        var orphaned = toastUp(verifierWarning: true)
        orphaned.hasActivePress = false
        #expect(confirm(orphaned) == .ignore)
        #expect(confirm(MagicPressReducer.State(phase: .idle)) == .ignore)
    }

    /// The Regenerate double-click race. Both clicks passed the old `.toast`
    /// guard while the first was still inside its undo + 150 ms sleep, so two
    /// provider calls ran against one `activePress`. The fix is that the first
    /// one leaves `.toast` up front — which only helps if the second is
    /// actually refused in `.generating`.
    @Test func aSecondRegenerateFindsThePressAlreadyGone() {
        #expect(rerun(toastUp()) == .rerun)

        var regenerating = toastUp()
        regenerating.phase = .generating
        #expect(rerun(regenerating) == .ignore)

        // Nothing to re-run without a press or a chosen workflow: a toast can
        // outlive the press (dismissal clears it) and a press can reach the
        // toast without a workflow (focus-mismatch clipboard fallback).
        var pressless = toastUp()
        pressless.hasActivePress = false
        #expect(rerun(pressless) == .ignore)
        #expect(rerun(toastUp(hasWorkflow: false)) == .ignore)
    }

    /// Auto-dismiss is for a toast nobody is using. Hovering it or clicking
    /// into it (key) means the user is reading or about to refine, and a toast
    /// that vanishes mid-sentence takes the only copy of the output with it.
    @Test func autoDismissWaitsForTheUserToLetGo() {
        let settled = toastUp()
        #expect(MagicPressReducer.reduce(state: settled, event: .toastSettleCheck)
            == .scheduleToastDismiss)

        var hovered = settled
        hovered.toastHovered = true
        #expect(MagicPressReducer.reduce(state: hovered, event: .toastSettleCheck) == .ignore)

        var key = settled
        key.toastIsKey = true
        #expect(MagicPressReducer.reduce(state: key, event: .toastSettleCheck) == .ignore)

        // A press that has moved on from `.toast` must never re-arm the timer;
        // nothing may outlive the surface it would have filled.
        var generating = settled
        generating.phase = .generating
        #expect(MagicPressReducer.reduce(state: generating, event: .toastSettleCheck) == .ignore)
    }

    /// A verifier warning is never auto-dismissed, however still the pointer is.
    ///
    /// Every other toast state can be taken away by the timer because its text
    /// is already on the pasteboard — the insert path writes it before any of
    /// them is reachable. The warning panel is the one state that never goes
    /// through the inserter, so the draft it shows exists nowhere else and a
    /// timer would destroy a paid generation with no undo and no copy. The user
    /// has to say so: ✕, Escape, or one of the panel's own actions.
    @Test func verifierWarningIsNeverAutoDismissed() {
        let flagged = toastUp(verifierWarning: true)
        #expect(MagicPressReducer.reduce(state: flagged, event: .toastSettleCheck) == .ignore)

        // Not merely because the pointer happens to be somewhere: the un-hover
        // that arms the timer for every other state is exactly the path this
        // has to survive.
        var unhovered = flagged
        unhovered.toastHovered = false
        unhovered.toastIsKey = false
        #expect(MagicPressReducer.reduce(state: unhovered, event: .toastSettleCheck) == .ignore)

        // The same toast without the warning still auto-dismisses — the guard
        // is scoped to the state whose output is unrecoverable, not bolted onto
        // the whole `.toast` phase.
        #expect(MagicPressReducer.reduce(state: toastUp(), event: .toastSettleCheck)
            == .scheduleToastDismiss)
    }

    /// `.inserting` is the one phase nothing may tear down.
    ///
    /// `MagicInserter.insert` posts the ⌘V and then holds the pasteboard for
    /// the confirmation poll and the R3 restore grace — of the order of a
    /// second, with a "generating" toast still on screen carrying a cancel. A
    /// teardown accepted in that window submits the press's trace and clears it
    /// while `performInsert` is still suspended, and the resumption submits a
    /// second trace for the same press and reopens the toast that was just
    /// closed. The text is in the field either way by then: Undo is the
    /// affordance for a paste the user did not want, and it lives on the toast
    /// this phase is on its way to.
    @Test func insertingRefusesEveryTeardown() {
        var inserting = MagicPressReducer.State(
            phase: .inserting, toastOpen: true, hasActivePress: true, hasWorkflow: true
        )
        func reduce(_ state: MagicPressReducer.State, _ event: MagicPressReducer.Event)
            -> MagicPressReducer.Action {
            MagicPressReducer.reduce(state: state, event: event)
        }

        // Escape outranks the toast that is still on screen.
        #expect(reduce(inserting, .dismissOverlay) == .ignore)
        // …and the chip panel, if a teardown left one up.
        inserting.chipPanelOpen = true
        #expect(reduce(inserting, .dismissOverlay) == .ignore)
        inserting.chipPanelOpen = false

        // Single-flight: a second hotkey during the paste is not a new press.
        #expect(reduce(inserting, .press(forceChips: false)) == .ignore)
        #expect(reduce(inserting, .press(forceChips: true)) == .ignore)

        // Nothing else can claim the press either.
        #expect(reduce(inserting, .regenerateOrRefine) == .ignore)
        #expect(reduce(inserting, .toastSettleCheck) == .ignore)
        #expect(reduce(inserting, .selectChip(0)) == .ignore)

        // Including a verifier accept: `insertAnyway` routes back into
        // `performInsert`, so honouring it here would run two pastes at once.
        var flagged = inserting
        flagged.verifierWarningPending = true
        #expect(reduce(flagged, .press(forceChips: false)) == .ignore)
        #expect(reduce(flagged, .insertAnyway) == .ignore)
    }
}
