import AppKit
@preconcurrency import ApplicationServices

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
        let (freshValue, freshSelection) = currentFieldState(snapshot) ?? (
            snapshot.field?.value ?? "", snapshot.field?.selection
        )

        let saved = PasteboardTransaction.save()
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
            try? await Task.sleep(for: .milliseconds(60))
            guard let (value, _) = currentFieldState(snapshot) else { continue }
            if value != freshValue, value.contains(probe) {
                confirmed = true
                break
            }
        }
        if clock.now - start < Self.clipboardRestoreGrace {
            try? await Task.sleep(for: Self.clipboardRestoreGrace - (clock.now - start))
        }
        let restored = PasteboardTransaction.restore(saved, ifChangeCountStill: ourCount)

        return .inserted(PreInsertRecord(
            fieldValue: freshValue,
            selection: freshSelection,
            insertedText: text,
            clipboardRestored: restored,
            pasteConfirmed: confirmed
        ))
    }

    /// Best-effort undo: a synthetic ⌘Z aimed at the still-focused field.
    /// Returns false when focus has moved — the caller falls back to the
    /// guaranteed path (copy the recoverable text).
    func attemptUndo(for snapshot: MagicSnapshot) async -> Bool {
        guard await verifyFocusStillMatches(snapshot) else { return false }
        SyntheticKeystroke.post(SyntheticKeystroke.keyZ)
        return true
    }

    /// The safety invariant that makes every timing bug non-destructive:
    /// paste only when the frontmost app and the focused element still match
    /// the snapshot. Polls briefly to let a chip-panel focus return land.
    func verifyFocusStillMatches(
        _ snapshot: MagicSnapshot,
        within timeout: Duration = .milliseconds(600)
    ) async -> Bool {
        let clock = ContinuousClock()
        let start = clock.now
        let deadline = start + timeout
        var didAttemptRefocus = false

        while true {
            if focusMatches(snapshot) { return true }
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
                    if let expected = snapshot.focusedElement?.element {
                        AXUIElementSetAttributeValue(
                            expected, kAXFocusedAttribute as CFString, kCFBooleanTrue
                        )
                    }
                }
            }
            guard clock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    // MARK: - Private

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

    private func focusMatches(_ snapshot: MagicSnapshot) -> Bool {
        // Self-targeted presses verify in-process: ClipSlop is an accessory
        // (menu bar) app, so NSWorkspace.frontmostApplication and the
        // system-wide AX focus routinely still report the previous regular
        // app even while our own window is key — the external checks below
        // would fail every time.
        if Self.isSelfTargeted(snapshot) {
            guard let key = NSApp.keyWindow,
                  !(key is ChipPanelWindow), !(key is MagicToastWindow)
            else { return false }
            return key.firstResponder is NSTextView
        }
        guard let expectedBundleId = snapshot.app.bundleId,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == expectedBundleId
        else { return false }

        guard let focused = currentFocusedElement() else { return false }

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
              Self.copyString(focused, kAXRoleAttribute) == field.role,
              Self.windowTitle(of: focused) == snapshot.windowTitle
        else { return false }

        if let expectedFrame = field.frame, let currentFrame = Self.frame(of: focused) {
            return Self.framesAgree(expectedFrame, currentFrame)
        }
        // No geometry published: value agreement is the only evidence left,
        // and it is evidence only when the value is distinctive. An empty
        // value matches every empty field, so it decides nothing and the
        // press goes to the toast rather than into an unidentified field.
        guard let current = Self.copyString(focused, kAXValueAttribute) else { return false }
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

    private func currentFocusedElement() -> AXUIElement? {
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

    /// Fresh value + selection read for the Restore record.
    private func currentFieldState(_ snapshot: MagicSnapshot) -> (String, MagicSnapshot.SelectionInfo?)? {
        guard let focused = snapshot.focusedElement?.element ?? currentFocusedElement() else { return nil }

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
}
