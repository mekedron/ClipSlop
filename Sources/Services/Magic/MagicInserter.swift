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

        try? await Task.sleep(for: Self.clipboardRestoreGrace)
        let restored = PasteboardTransaction.restore(saved, ifChangeCountStill: ourCount)

        return .inserted(PreInsertRecord(
            fieldValue: freshValue,
            selection: freshSelection,
            insertedText: text,
            clipboardRestored: restored
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
        let deadline = clock.now + timeout

        while true {
            if focusMatches(snapshot) { return true }
            guard clock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    // MARK: - Private

    private func focusMatches(_ snapshot: MagicSnapshot) -> Bool {
        guard let expectedBundleId = snapshot.app.bundleId,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == expectedBundleId
        else { return false }

        guard let focused = currentFocusedElement() else { return false }

        if let expected = snapshot.focusedElement, CFEqual(expected.element, focused) {
            return true
        }
        // AXUIElements have no stable identity across some apps' re-renders;
        // fall back to role + window-title + value agreement.
        guard let field = snapshot.field else { return false }
        var roleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused, kAXRoleAttribute as CFString, &roleValue) == .success,
              roleValue as? String == field.role
        else { return false }

        var currentValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(focused, kAXValueAttribute as CFString, &currentValue) == .success,
           let current = currentValue as? String {
            return current == field.value
        }
        // Value unreadable (some web fields): bundle + role agreement is the
        // best evidence available.
        return true
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
