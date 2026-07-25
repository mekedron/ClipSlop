import AppKit
@preconcurrency import ApplicationServices

/// The field's value and caret/selection as read back through AX, the two
/// readings every "is this still the state we planned for" question is
/// answered from. Both are optional because both are routinely unreadable:
/// plenty of web composers publish no `AXValue`, and many apps publish no
/// selected range.
///
/// File scope (rather than nested in `MagicInserter`) so `AXFieldReader` can
/// build one off the main actor and hand it back; `Sendable` for the same
/// crossing.
fileprivate struct FieldProbe: Sendable {
    let value: String?
    let range: Range<Int>?
}

/// Everything `MagicPressCoordinator.reassertSelectionIfLost` needs to know
/// about the target field before it lets a press paste — read in a single hop
/// into `AXFieldReader`.
///
/// One value rather than two calls on purpose: the guard compares the live
/// selection against the captured one *as measured in the field's current
/// value*, and then re-encodes its own range against that same string. Two
/// round-trips could straddle a keystroke and have the two halves of that
/// decision belong to different versions of the field — which is how a
/// re-selection ends up landing on a shifted span.
///
/// Internal (not `fileprivate` like `FieldProbe`) because this one crosses into
/// the coordinator; the `AXUIElement` itself never does.
struct MagicSelectionProbe: Sendable {
    /// The field's value as the target holds it right now, or the caller's
    /// fallback when AX published nothing readable. Deliberately unclipped —
    /// see `reassertSelectionIfLost`.
    let value: String
    /// The field published a selection with a non-zero length. Distinct from
    /// `liveRange != nil`: a selection can exist and still be unmappable into
    /// `value`, and those two cases must not be confused — the first refuses
    /// the paste, the second re-asserts our own range.
    let hasLiveSelection: Bool
    /// That live selection in CHARACTER offsets (the space snapshots record
    /// ranges in), or nil when it does not lie inside `value`.
    let liveRange: Range<Int>?
}

/// Every Accessibility read the insert path makes, on its own executor.
///
/// `AXUIElementCopyAttributeValue` is synchronous IPC into the target app and
/// the process-wide messaging timeout is 0.35 s per call
/// (`AXSnapshotService.configureTimeoutOnce`), so an unresponsive target
/// charges that much for every attribute. The insert path polls hard — focus
/// verification spends 3–5 reads every 50 ms for up to 600 ms, paste
/// confirmation 2–3 more every 60 ms for up to 700 ms — which on the main
/// thread adds up to seconds of beachball. Capture was made an actor for
/// exactly this reason (R4); insertion gets the same treatment. `MagicInserter`
/// stays `@MainActor` as the orchestrator and awaits into here for the AX I/O,
/// hopping back to the main actor for every AppKit and pasteboard step.
fileprivate actor AXFieldReader {
    /// Identity check only: is the element that holds focus right now the one
    /// the snapshot was taken against?
    fileprivate func isSnapshotFieldFocused(_ snapshot: MagicSnapshot) -> Bool {
        Self.focusedSnapshotField(snapshot) != nil
    }

    /// Identity check plus the field's own value and caret, read in the same
    /// hop — the state guard needs both, and splitting them would double the
    /// round-trips of a poll that runs every 50 ms. Nil means focus is not on
    /// the snapshot's field at all, which is decided before any value is read.
    fileprivate func snapshotFieldProbe(_ snapshot: MagicSnapshot) -> FieldProbe? {
        guard let focused = Self.focusedSnapshotField(snapshot) else { return nil }
        return Self.fieldProbe(of: focused)
    }

    /// The one AX *write* on this path (re-focusing the remembered element
    /// during a focus repair). It blocks on the same 0.35 s messaging timeout
    /// a read does, so it belongs off the main actor with them. `AXElementRef`
    /// is the codebase's Sendable carrier for a bare `AXUIElement`.
    fileprivate func forceFocus(_ element: AXElementRef) {
        AXUIElementSetAttributeValue(
            element.element, kAXFocusedAttribute as CFString, kCFBooleanTrue
        )
    }

    /// Fresh value + selection read for the Restore record.
    fileprivate func currentFieldState(_ snapshot: MagicSnapshot) -> (String, MagicSnapshot.SelectionInfo?)? {
        guard let focused = snapshot.focusedElement?.element ?? Self.currentFocusedElement()
        else { return nil }

        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused, kAXValueAttribute as CFString, &valueRef) == .success,
              let value = valueRef as? String
        else { return nil }

        var selection: MagicSnapshot.SelectionInfo?
        var selectedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(focused, kAXSelectedTextAttribute as CFString, &selectedRef) == .success,
           let text = selectedRef as? String, !text.isEmpty {
            selection = .init(range: nil, text: text)
        } else if let snapshotSelection = snapshot.field?.selection, snapshot.field?.value == value {
            selection = snapshotSelection
        }
        return (value, selection)
    }

    /// Value + caret/selection as the target holds them right now.
    ///
    /// The live focused element is preferred over the snapshot's remembered
    /// one — the opposite order to `currentFieldState`, and deliberately so:
    /// the apps this guard exists for are the ones that rebuild the
    /// AXUIElement on re-render, where the remembered reference answers with
    /// nothing (or with what the field held before the rebuild) and a stale
    /// reading is worse than no reading. Callers reach here only just after
    /// focus was verified, so the live element is the target's.
    fileprivate func currentFieldProbe(_ snapshot: MagicSnapshot) -> FieldProbe {
        guard let focused = Self.currentFocusedElement() ?? snapshot.focusedElement?.element else {
            return FieldProbe(value: nil, range: nil)
        }
        return Self.fieldProbe(of: focused)
    }

    /// The pre-paste selection reading the press band takes immediately before
    /// handing text to `insert`: the field's value and its live selection, in
    /// one hop.
    ///
    /// This used to run inline on the main actor in
    /// `MagicPressCoordinator.reassertSelectionIfLost`, which is exactly the
    /// shape this actor exists to stop: up to three synchronous AX round-trips
    /// (value, selected range, and the set that follows) at the process-wide
    /// 0.35 s messaging timeout each, charged to the main thread at the precise
    /// moment the user is watching for their paste — close to a second of frozen
    /// UI against an unresponsive target.
    ///
    /// `fallbackValue` (the caller's captured field value) is passed IN rather
    /// than substituted by the caller afterwards because the character-offset
    /// conversion below has to be measured against the very string the caller
    /// will later re-encode its own range against.
    fileprivate func selectionProbe(
        of element: AXElementRef, fallbackValue: String
    ) -> MagicSelectionProbe {
        let value = Self.copyString(element.element, kAXValueAttribute) ?? fallbackValue

        var selectedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element.element, kAXSelectedTextRangeAttribute as CFString, &selectedRef
        ) == .success, let selectedRef, CFGetTypeID(selectedRef) == AXValueGetTypeID()
        else { return MagicSelectionProbe(value: value, hasLiveSelection: false, liveRange: nil) }

        var current = CFRange()
        guard AXValueGetValue((selectedRef as! AXValue), .cfRange, &current), current.length > 0
        else { return MagicSelectionProbe(value: value, hasLiveSelection: false, liveRange: nil) }

        // Converted inside the same hop that read the value: AX speaks UTF-16
        // in both directions while snapshots record character offsets, and a
        // single emoji earlier in the field makes the two numbers disagree over
        // the very same span. Nil here means the live selection does not map
        // into the current value at all — stale by definition, and the caller
        // treats it as someone else's.
        return MagicSelectionProbe(
            value: value,
            hasLiveSelection: true,
            liveRange: AXSnapshotService.characterRange(current, in: value)
        )
    }

    /// The selection re-assert write. `AXValueCreate` is cheap; the
    /// `AXUIElementSetAttributeValue` that follows blocks on the same 0.35 s
    /// messaging timeout a read does, so it belongs here beside `forceFocus`
    /// rather than on the main actor. Offsets arrive already converted to UTF-16
    /// (`MagicPressCoordinator.utf16Range`) and travel as plain `Int`s because
    /// `CFRange` is not `Sendable`.
    fileprivate func setSelectedRange(location: Int, length: Int, of element: AXElementRef) {
        var range = CFRange(location: location, length: length)
        guard let axValue = AXValueCreate(.cfRange, &range) else { return }
        AXUIElementSetAttributeValue(
            element.element, kAXSelectedTextRangeAttribute as CFString, axValue
        )
    }

    // MARK: - Private
    //
    // Static, so they are nonisolated: they take an `AXUIElement` that never
    // leaves this actor, and the isolated entry points above are the only
    // boundary.

    private static func focusedSnapshotField(_ snapshot: MagicSnapshot) -> AXUIElement? {
        guard let focused = currentFocusedElement(),
              elementIsTheSnapshotField(snapshot, focused)
        else { return nil }
        return focused
    }

    /// Element identity, with the corroboration apps without stable identity
    /// need. Says nothing about the field's *contents* — see `focusMatches`.
    private static func elementIsTheSnapshotField(
        _ snapshot: MagicSnapshot, _ focused: AXUIElement
    ) -> Bool {
        if let expected = snapshot.focusedElement, CFEqual(expected.element, focused) {
            return true
        }
        // AXUIElements have no stable identity across some apps' re-renders
        // (Chromium rebuilds the element as the user types), so an identity
        // mismatch is not by itself proof that focus moved — but the
        // corroboration has to be strong enough that a DIFFERENT field cannot
        // supply it. Role and window title must agree, and then either the
        // on-screen frame or a distinctive value. The old test was role +
        // value alone, which every other empty composer in the same window
        // satisfies: a field focused during generation accepted the paste.
        guard let field = snapshot.field,
              copyString(focused, kAXRoleAttribute) == field.role,
              windowTitle(of: focused) == snapshot.windowTitle
        else { return false }

        if let expectedFrame = field.frame, let currentFrame = frame(of: focused) {
            return framesAgree(expectedFrame, currentFrame)
        }
        // No geometry published: value agreement is the only evidence left,
        // and it is evidence only when the value is distinctive. An empty
        // value matches every empty field, so it decides nothing and the
        // press goes to the toast rather than into an unidentified field.
        guard let current = copyString(focused, kAXValueAttribute) else { return false }
        return !field.value.isEmpty && current == field.value
    }

    /// Sub-point differences are AX rounding, not movement; anything larger
    /// means the field scrolled or a different one took focus, and either way
    /// the press should not paste blind.
    private static func framesAgree(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) < 1 && abs(lhs.minY - rhs.minY) < 1
            && abs(lhs.width - rhs.width) < 1 && abs(lhs.height - rhs.height) < 1
    }

    private static func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success
        else { return nil }
        return raw as? String
    }

    private static func windowTitle(of element: AXUIElement) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXUIElementGetTypeID()
        else { return nil }
        return copyString((raw as! AXUIElement), kAXTitleAttribute)
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        func axValue(_ attribute: String) -> AXValue? {
            var raw: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
                  let raw, CFGetTypeID(raw) == AXValueGetTypeID()
            else { return nil }
            return (raw as! AXValue)
        }
        guard let originValue = axValue(kAXPositionAttribute),
              let sizeValue = axValue(kAXSizeAttribute)
        else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(originValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private static func currentFocusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var appValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedApplicationAttribute as CFString, &appValue
        ) == .success, let appValue, CFGetTypeID(appValue) == AXUIElementGetTypeID() else { return nil }

        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            (appValue as! AXUIElement), kAXFocusedUIElementAttribute as CFString, &focusedValue
        ) == .success, let focusedValue, CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else { return nil }

        return (focusedValue as! AXUIElement)
    }

    /// The range is converted to CHARACTER offsets against the value read in
    /// the same breath — the space `AXSnapshotService` records
    /// `field.selectedRange` in. AX hands out UTF-16, and comparing the two
    /// spaces would report a moved caret for any field holding an emoji.
    private static func fieldProbe(of element: AXUIElement) -> FieldProbe {
        var valueRef: CFTypeRef?
        let value: String? = AXUIElementCopyAttributeValue(
            element, kAXValueAttribute as CFString, &valueRef
        ) == .success ? valueRef as? String : nil

        var range: Range<Int>?
        var rangeRef: CFTypeRef?
        if let value,
           AXUIElementCopyAttributeValue(
               element, kAXSelectedTextRangeAttribute as CFString, &rangeRef
           ) == .success,
           let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID() {
            let axValue = rangeRef as! AXValue
            var cfRange = CFRange()
            if AXValueGetType(axValue) == .cfRange,
               AXValueGetValue(axValue, .cfRange, &cfRange) {
                range = AXSnapshotService.characterRange(cfRange, in: value)
            }
        }
        return FieldProbe(value: value, range: range)
    }
}

/// Atomic insertion with focus safety and guaranteed text recovery (§3.5,
/// P8): re-verify the target, paste over the selection/caret via the
/// clipboard, restore the clipboard only if untouched — and never, under any
/// failure, lose the user's pre-paste field text.
@MainActor
final class MagicInserter {
    /// The Restore contract: everything needed to recover the field as it
    /// was the instant before we pasted. `fieldValue` is re-read fresh at
    /// insert time — the snapshot may be seconds old if chips were up.
    struct PreInsertRecord: Sendable {
        let fieldValue: String
        let selection: MagicSnapshot.SelectionInfo?
        let insertedText: String
        let clipboardRestored: Bool
        /// The inserted text was observed in the field's AXValue after the
        /// paste. False means the ⌘V may not have landed (some web fields
        /// also just don't expose a readable value).
        let pasteConfirmed: Bool

        /// The text Restore guarantees to make copyable: the replaced
        /// selection when there was one, else the whole prior field.
        var recoverableText: String {
            if let selection, !selection.text.isEmpty { return selection.text }
            return fieldValue
        }
    }

    enum Outcome: Sendable {
        case inserted(PreInsertRecord)
        /// Focus moved between press and paste — result delivered to the
        /// toast + clipboard instead. Never a blind paste.
        case focusMismatch
        /// Grammar row 5 (non-editable selection): panel/clipboard only.
        case panelOnly
    }

    /// Electron apps have been observed reading the pasteboard noticeably
    /// after the ⌘V lands (R3) — restoring too early hands them the old
    /// content. The grace period is the documented mitigation; the residual
    /// race is accepted.
    private static let clipboardRestoreGrace: Duration = .milliseconds(400)

    /// Every AX read this class makes goes through here, off the main actor —
    /// see `AXFieldReader` for why. The orchestration, the `lastWrite`
    /// bookkeeping and every AppKit/pasteboard touch stay on the main actor.
    private let reader = AXFieldReader()

    /// The field state as one of OUR OWN writes left it — read back right
    /// after a paste, and again after a ⌘Z that took one away. Two guards need
    /// it, for opposite reasons:
    ///
    /// - Undo has to know the app's newest undo group is still ours. Focus
    ///   agreement does not say that: type one character into the target after
    ///   the paste and the ⌘Z removes that character, leaves the generated text
    ///   sitting there, and the toast still reports "undone".
    /// - Insert has to tell drift the user caused from drift we caused.
    ///   Regenerate ⌘Z's its own paste away before re-running, so by the time
    ///   the replacement lands the field no longer matches the snapshot it was
    ///   planned against — but nothing the user did is at stake there, so that
    ///   difference must not block the paste.
    ///
    /// Keyed by `MagicSnapshot.ts`, which is the press identity: a probe left
    /// by an earlier press must never vouch for the current one.
    ///
    /// Written ONLY through `noteOurOwnWrite`, and read by the guards as a
    /// value captured before they suspend — see `focusMatches`. Both halves
    /// matter now that the AX reads live in `AXFieldReader`: the checks await
    /// into that actor mid-decision, so main-actor isolation alone no longer
    /// makes "read the field, then consult `lastWrite`" atomic.
    private var lastWrite: (press: Date, probe: FieldProbe)?

    /// Bumped by every `lastWrite` mutation, so a guard that captured the value
    /// before an `await` can prove it is still deciding on the state of the
    /// world it captured — and bail conservatively if it is not.
    private var lastWriteGeneration = 0

    /// The only writer of `lastWrite`, so the generation can never drift out of
    /// step with it.
    private func noteOurOwnWrite(press: Date, probe: FieldProbe) {
        lastWrite = (press: press, probe: probe)
        lastWriteGeneration += 1
    }

    func insert(_ text: String, against snapshot: MagicSnapshot) async -> Outcome {
        if snapshot.grammarRow == .nonEditableSelection {
            PasteboardTransaction.writeGenerated(text)
            return .panelOnly
        }

        guard await verifyFocusStillMatches(snapshot) else {
            PasteboardTransaction.writeGenerated(text)
            return .focusMismatch
        }

        // Fresh pre-paste state for Restore.
        let liveState = await reader.currentFieldState(snapshot)
        let (freshValue, freshSelection) = liveState ?? (
            snapshot.field?.value ?? "", snapshot.field?.selection
        )

        // Off the main thread (see `PasteboardTransaction.readQueue`), so a
        // large clipboard does not stall the UI here. Still ordered before our
        // own write — the `await` is what guarantees it.
        let saved = await PasteboardTransaction.save()
        let ourCount = PasteboardTransaction.writeGenerated(text)
        PasteboardTransaction.postPaste()

        // Best-effort paste confirmation: watch the field's value for the
        // inserted text. Confirmation also gates the clipboard restore — we
        // never take the pasteboard back before the target has visibly
        // consumed it (with the fixed grace as the floor for late readers,
        // R3).
        // Confirmation requires the field to have actually CHANGED, not just
        // to contain the probe: when the draft already opened with the same
        // words the model generated, a substring test alone marks a swallowed
        // or ignored ⌘V as landed — and then reports a paste that never
        // happened while quietly taking the clipboard back.
        let clock = ContinuousClock()
        let start = clock.now
        var confirmed = false
        let probe = String(text.prefix(64))
        while clock.now - start < .milliseconds(700) {
            // Cancellation (Escape during the press, or a regenerate taking
            // over) shortens this wait instead of ending the method: the ⌘V is
            // already posted, so the only thing given up here is the
            // best-effort `confirmed` flag, while the clipboard restore, the
            // settled probe and `noteOurOwnWrite` below all still run — those
            // are what keep the user's pasteboard and their ⌘Z intact, and
            // skipping either would leave the generated text sitting in their
            // clipboard and undo aimed at nothing.
            //
            // Without this the loop did not merely run long, it SPUN: a
            // cancelled task makes `Task.sleep` return immediately, so the 60 ms
            // pacing vanished and the remainder of the 700 ms went into
            // back-to-back AX reads of an app the user had already walked away
            // from.
            if Task.isCancelled { break }
            try? await Task.sleep(for: .milliseconds(60))
            guard let (value, _) = await reader.currentFieldState(snapshot) else { continue }
            if value != freshValue, value.contains(probe) {
                confirmed = true
                break
            }
        }
        // Deliberately NOT cancellation-aware — see `sleepThroughCancellation`.
        // A cancelled press reaches the restore sooner than a confirmed one
        // (it skipped the loop above), which makes the R3 grace more load
        // bearing here, not less.
        if clock.now - start < Self.clipboardRestoreGrace {
            await Self.sleepThroughCancellation(
                for: Self.clipboardRestoreGrace - (clock.now - start)
            )
        }
        let restored = PasteboardTransaction.restore(saved, ifChangeCountStill: ourCount)

        // Ground truth for Undo (and for a regenerate's second insert): what
        // the field holds now that our paste has settled. Anything else in it
        // later is the user's doing, and a ⌘Z would then be aimed at their
        // edit rather than at ours.
        let settledProbe = await reader.currentFieldProbe(snapshot)
        noteOurOwnWrite(press: snapshot.ts, probe: settledProbe)

        return .inserted(PreInsertRecord(
            fieldValue: freshValue,
            selection: freshSelection,
            insertedText: text,
            clipboardRestored: restored,
            pasteConfirmed: confirmed
        ))
    }

    /// Best-effort undo: a synthetic ⌘Z aimed at the still-focused field.
    /// Returns false when focus has moved, or when the field no longer holds
    /// what our paste left in it — the caller falls back to the guaranteed
    /// path (copy the recoverable text).
    func attemptUndo(for snapshot: MagicSnapshot) async -> Bool {
        // Field drift is expected on this path — we are the ones who changed
        // the field — so the insert-time state guard is switched off here and
        // the undo-specific comparison below takes its place.
        guard await verifyFocusStillMatches(snapshot, requireUnchangedField: false),
              await undoStillTargetsOurPaste(snapshot)
        else { return false }
        SyntheticKeystroke.post(SyntheticKeystroke.keyZ)

        // Re-baseline against whatever the undo actually produced: a
        // regenerate inserts again right after this, and the state its guard
        // will meet is this one, not the snapshot's — an app that re-selects
        // the text it restored (AppKit does) leaves a caret matching neither.
        // The app applies the ⌘Z on its own run loop, so wait for the value to
        // move rather than guessing a delay; a value we could not read in the
        // first place has nothing to wait for.
        let pasted = lastWrite?.probe.value
        var settled = await reader.currentFieldProbe(snapshot)
        if pasted != nil {
            let clock = ContinuousClock()
            let start = clock.now
            while settled.value == pasted, clock.now - start < .milliseconds(250) {
                try? await Task.sleep(for: .milliseconds(40))
                settled = await reader.currentFieldProbe(snapshot)
            }
        }
        noteOurOwnWrite(press: snapshot.ts, probe: settled)
        return true
    }

    /// Whether the app's newest undo group is still the one our paste opened.
    ///
    /// Only the value decides. Typing, deleting and autocorrect each open a
    /// fresh undo group — and undoing *that* would take the user's own edit
    /// away while leaving the generated text in place, which is precisely the
    /// damage Restore exists to prevent. Moving the caret opens no undo group,
    /// so a moved caret must not cost the user their undo.
    ///
    /// When either side of the comparison is unreadable there is no evidence
    /// at all, and refusing on no evidence would remove ⌘Z from every app with
    /// an opaque `AXValue` (most web composers). Those keep the best-effort
    /// keystroke; the guaranteed copy-previous-text path remains one click
    /// away either way.
    private func undoStillTargetsOurPaste(_ snapshot: MagicSnapshot) async -> Bool {
        // Same discipline as `focusMatches`: `written` is bound from
        // `lastWrite` *before* the await into the reader, so the value being
        // compared cannot change while the comparison's other half is being
        // read. Guard conditions are evaluated left to right, which is what
        // makes that free here — do not reorder them.
        guard let lastWrite, lastWrite.press == snapshot.ts,
              let written = lastWrite.probe.value,
              let current = await reader.currentFieldProbe(snapshot).value
        else { return true }
        return current == written
    }

    /// The safety invariant that makes every timing bug non-destructive:
    /// paste only when the frontmost app and the focused element still match
    /// the snapshot — and, for the paste itself, only when the field is still
    /// in the state the result was written for (`requireUnchangedField`). Undo
    /// passes false: it runs against a field we deliberately changed.
    ///
    /// Polls briefly to let a chip-panel focus return land.
    func verifyFocusStillMatches(
        _ snapshot: MagicSnapshot,
        within timeout: Duration = .milliseconds(600),
        requireUnchangedField: Bool = true
    ) async -> Bool {
        let clock = ContinuousClock()
        let start = clock.now
        let deadline = start + timeout
        var didAttemptRefocus = false

        while true {
            // The caret is evidence only until we have forced focus back
            // ourselves: making a text field first responder selects its whole
            // contents in AppKit, so after the repair below a "moved" caret is
            // our own artifact, not something the user did.
            if await focusMatches(
                snapshot,
                requireUnchangedField: requireUnchangedField,
                trustCaret: !didAttemptRefocus
            ) { return true }
            // One active repair before giving up: when our chip panel held
            // key focus (hint field), macOS does not reliably hand key back
            // to the target's composer on dismissal — regardless of which
            // gesture accepted the chip. Re-activating the target app and
            // re-focusing the remembered AX element is deterministic where
            // app-level activation dances are not.
            if !didAttemptRefocus, clock.now - start > .milliseconds(200) {
                didAttemptRefocus = true
                if Self.isSelfTargeted(snapshot) {
                    // In-process repair: hand key back to a regular window —
                    // an overlay panel may have been auto-promoted to key
                    // when the chip panel closed.
                    if let window = NSApp.windows.first(where: {
                        $0.isVisible && $0.canBecomeKey && !($0 is NSPanel)
                    }) {
                        window.makeKeyAndOrderFront(nil)
                    }
                } else if Self.mayReclaimFocus(snapshot) {
                    if NSWorkspace.shared.frontmostApplication?.processIdentifier != snapshot.app.pid {
                        NSRunningApplication(processIdentifier: snapshot.app.pid)?
                            .activate(options: [])
                    }
                    if let expected = snapshot.focusedElement {
                        await reader.forceFocus(expected)
                    }
                }
            }
            guard clock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    // MARK: - Selection re-assert (for the press band)

    /// The press band's pre-paste selection reading, taken on the inserter's AX
    /// executor instead of the main actor.
    ///
    /// `MagicPressCoordinator.reassertSelectionIfLost` keeps the decision and
    /// the range arithmetic — both pure, both directly under test — and only the
    /// AX I/O it needs comes here. Routing it through the inserter rather than
    /// exposing `AXFieldReader` keeps that actor file-private, so every AX call
    /// on the insert path still goes through exactly one door.
    func selectionProbe(
        of element: AXElementRef, fallbackValue: String
    ) async -> MagicSelectionProbe {
        await reader.selectionProbe(of: element, fallbackValue: fallbackValue)
    }

    /// Companion write for the reading above: re-select the span the target
    /// dropped when a panel took key. UTF-16 offsets, already converted by the
    /// caller.
    func reassertSelectedRange(location: Int, length: Int, of element: AXElementRef) async {
        await reader.setSelectedRange(location: location, length: length, of: element)
    }

    // MARK: - Private

    /// A delay a cancelled press still waits out.
    ///
    /// `Task.sleep` returns the instant its task is cancelled, and on this path
    /// there is exactly one wait that must NOT collapse: the clipboard-restore
    /// grace. The ⌘V has already been posted by then, and taking the pasteboard
    /// back early hands a late reader (Electron, R3) the user's own restored
    /// clipboard content to paste into their field — data loss caused by a
    /// cancel, which is the one thing a cancel may never do. An unstructured
    /// task does not inherit cancellation, so the grace holds while the rest of
    /// the path exits early.
    private static func sleepThroughCancellation(for duration: Duration) async {
        let sleeper = Task.detached { () -> Void in
            try? await Task.sleep(for: duration)
        }
        await sleeper.value
    }

    /// True when the press targeted one of ClipSlop's own windows (the
    /// onboarding sandbox, a Settings field).
    private static func isSelfTargeted(_ snapshot: MagicSnapshot) -> Bool {
        snapshot.app.pid == ProcessInfo.processInfo.processIdentifier
    }

    /// Whether the focus we are about to reclaim is focus *we* took.
    ///
    /// The repair below re-activates the target app, which yanks the user out
    /// of whatever they are doing. That is right when our own chip panel is
    /// what holds key, and right when focus merely drifted inside the target
    /// app — but wrong when a third app is frontmost: the user switched away
    /// deliberately, and stealing activation back pastes into a window they
    /// left. The press ends in `focusMismatch` instead, which puts the result
    /// on the clipboard and in the toast (§3.5, P8).
    private static func mayReclaimFocus(_ snapshot: MagicSnapshot) -> Bool {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return false }
        return frontmost.processIdentifier == snapshot.app.pid
            || frontmost.processIdentifier == ProcessInfo.processInfo.processIdentifier
    }

    private func focusMatches(
        _ snapshot: MagicSnapshot,
        requireUnchangedField: Bool,
        trustCaret: Bool
    ) async -> Bool {
        // Self-targeted presses verify in-process: ClipSlop is an accessory
        // (menu bar) app, so NSWorkspace.frontmostApplication and the
        // system-wide AX focus routinely still report the previous regular
        // app even while our own window is key — the external checks below
        // would fail every time. The field-state guard is skipped here too:
        // the target is our own onboarding sandbox or a Settings field, and
        // reading our own process through AX is a deadlock hazard, not a
        // safety gain.
        if Self.isSelfTargeted(snapshot) {
            guard let key = NSApp.keyWindow,
                  !(key is ChipPanelWindow), !(key is MagicToastWindow)
            else { return false }
            return key.firstResponder is NSTextView
        }
        guard let expectedBundleId = snapshot.app.bundleId,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == expectedBundleId
        else { return false }

        // Being the right ELEMENT is not the same as being in the right
        // STATE. Apps that keep one AXUIElement across re-renders hand back
        // the very same element after the user has typed half a sentence into
        // it, so identity alone let a result assembled from the old value and
        // the old caret be pasted into the new one. When the state has moved
        // on, the press goes to the clipboard and the toast like any other
        // mismatch — §3.5's "never a blind paste".
        //
        // Identity and state are asked for in one hop when both are wanted:
        // the reader reads the value and caret only after the element checks
        // out, so the AX traffic is the same as when both lived here.
        guard requireUnchangedField else {
            return await reader.isSnapshotFieldFocused(snapshot)
        }
        // `lastWrite` is captured HERE, before the hop into the reader actor,
        // and the captured value is what decides below — the comparison is a
        // `nonisolated static` that cannot reach back for a fresher one. Moving
        // the AX reads into `AXFieldReader` (right fix for the main-thread
        // stalls) put a suspension point between reading the field and
        // consulting our own last write, where none existed while the whole
        // check was synchronous on the main actor; deciding half from before
        // that gap and half from after it is how a guard starts answering
        // questions nobody asked.
        //
        // The generation re-check closes the other half: if a write did land
        // during the await, this reading is judged against nothing and the
        // answer is the conservative one. False here is not a refusal — the
        // caller's poll loop simply looks again, now with both halves fresh.
        let ourLastWrite = lastWrite
        let generation = lastWriteGeneration
        guard let current = await reader.snapshotFieldProbe(snapshot) else { return false }
        guard generation == lastWriteGeneration else { return false }
        return Self.fieldStateUnchanged(
            snapshot, current: current, ourLastWrite: ourLastWrite, trustCaret: trustCaret
        )
    }

    /// Whether the field is still in the state the result was assembled from
    /// — the snapshot's state, or else the state one of our own writes left
    /// behind (a regenerate undoes its previous paste before re-running, and
    /// that difference is ours, not the user's).
    ///
    /// Takes both readings as values: the probe was read in the reader actor,
    /// and `ourLastWrite` is the caller's capture of `lastWrite` from before
    /// that hop. `nonisolated static` on purpose — the decision then *cannot*
    /// consult the live `lastWrite`, so no future edit can quietly reintroduce
    /// a mid-decision re-read across the suspension point in `focusMatches`.
    private nonisolated static func fieldStateUnchanged(
        _ snapshot: MagicSnapshot,
        current: FieldProbe,
        ourLastWrite: (press: Date, probe: FieldProbe)?,
        trustCaret: Bool
    ) -> Bool {
        let currentRange = trustCaret ? current.range : nil
        if fieldStateAgrees(
            expectedValue: snapshot.field?.value, expectedRange: snapshot.field?.selectedRange,
            currentValue: current.value, currentRange: currentRange
        ) { return true }

        guard let ourLastWrite, ourLastWrite.press == snapshot.ts,
              ourLastWrite.probe.value != nil
        else { return false }
        return fieldStateAgrees(
            expectedValue: ourLastWrite.probe.value, expectedRange: ourLastWrite.probe.range,
            currentValue: current.value, currentRange: currentRange
        )
    }

    /// Does a field state read now still count as the state a result was
    /// planned against?
    ///
    /// Deliberately asymmetric, because AX readings are: only positive
    /// evidence of a CHANGE rejects. A value that was unreadable proves
    /// nothing — and capture writes "" for unreadable just as it does for
    /// genuinely empty, so an empty expectation cannot be told from a missing
    /// one and must decide nothing either. Rejecting on that would send every
    /// app with an opaque field to the toast, forever. The caret is the same
    /// kind of evidence: it decides only when both readings published one.
    ///
    /// The one genuinely ambiguous case is a current value that merely extends
    /// the expected one. That is what capture's `maxFieldValueChars` clip looks
    /// like on a long document — and also exactly what the user typing at the
    /// end of a short one looks like. The caret breaks the tie: typing moves
    /// it, a clipped tail does not. With no caret to consult, the ambiguity
    /// resolves against pasting.
    ///
    /// `nonisolated` so the tests can exercise the decision table directly;
    /// everything it decides on has already been read by the caller.
    nonisolated static func fieldStateAgrees(
        expectedValue: String?, expectedRange: Range<Int>?,
        currentValue: String?, currentRange: Range<Int>?
    ) -> Bool {
        let caretAgrees: Bool? = (expectedRange == nil || currentRange == nil)
            ? nil
            : expectedRange == currentRange

        guard let expectedValue, !expectedValue.isEmpty, let currentValue else {
            return caretAgrees ?? true
        }
        if currentValue == expectedValue { return caretAgrees ?? true }
        if currentValue.count > expectedValue.count {
            // Capture keeps at most `field_value_max_chars` of a long field, as
            // either its head or — once the caret sits past that cap — the
            // window of that length ending AT the caret. Both are what an
            // untouched long document looks like from here, and neither may
            // send the press to the clipboard. The caret still has to agree:
            // it is the only thing that tells a clip from the user typing.
            if currentValue.hasPrefix(expectedValue) { return caretAgrees == true }
            if let expectedRange,
               Self.slice(of: currentValue, ofLength: expectedValue.count,
                          endingAt: expectedRange.upperBound) == expectedValue {
                return caretAgrees == true
            }
        }
        return false
    }

    /// The `length` characters of `value` ending at `end`, or nil when that
    /// span does not lie inside it. Offsets are character offsets, the space
    /// `AXSnapshotService` records ranges in.
    private nonisolated static func slice(of value: String, ofLength length: Int, endingAt end: Int) -> String? {
        let start = end - length
        guard start >= 0, end <= value.count else { return nil }
        let lower = value.index(value.startIndex, offsetBy: start)
        let upper = value.index(lower, offsetBy: length)
        return String(value[lower..<upper])
    }
}
