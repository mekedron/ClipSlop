import AppKit

/// Synthetic-⌘C fallback for web fields that report a selection range but
/// return empty `AXSelectedText` (§5.2). Runs after the AX snapshot, only
/// when the snapshot itself says a selection should exist.
@MainActor
enum MagicSelectionCapture {
    /// True when the snapshot's field claims a selection the AX read failed
    /// to deliver.
    static func isNeeded(for snapshot: MagicSnapshot) -> Bool {
        guard let field = snapshot.field, !field.secure else { return false }
        guard field.selection == nil else { return false }
        // A non-empty selected range with no recoverable text: the app says a
        // selection exists and AX would not hand it over. That is the only
        // honest trigger.
        if let range = field.selectedRange, !range.isEmpty { return true }
        // Non-editable areas publish no range at all in many apps, so a ⌘C
        // probe stays the fallback there — it is also harmless, since nothing
        // is ever pasted back into a non-editable area.
        //
        // Editable fields are deliberately excluded now: "editable and
        // non-empty" was true of every draft, and in a copy-current-line
        // target (many editors, some IDE consoles) the probe returns text with
        // NOTHING selected — `refine` then promoted that to a real selection
        // while the paste still landed at the caret, so the press rewrote a
        // line the user had not addressed.
        return !field.editable
    }

    /// Captures the selection via ⌘C with changeCount polling, restores the
    /// previous pasteboard, and returns an updated snapshot. One retry.
    static func refine(_ snapshot: MagicSnapshot) async -> MagicSnapshot {
        let saved = await PasteboardTransaction.save()

        var captured = await PasteboardTransaction.captureViaCommandC()
        if captured == nil {
            captured = await PasteboardTransaction.captureViaCommandC(timeout: .milliseconds(200))
        }

        // Restore whenever the pasteboard MOVED, not only when we got a string
        // back: `captureViaCommandC` returns nil when the target published
        // only non-string representations after bumping `changeCount` (an
        // image, a file URL, a rich-text-only copy), and the user's clipboard
        // was then left holding our probe's spoils forever.
        //
        // Read the count ONCE and hand that same value to `restore` as the
        // expected token. Reading it a second time inside the call made
        // `shouldRestore` compare the pasteboard's count to itself — always
        // true — which threw away the "never fight other writers" contract
        // (§3.5, R3): a clipboard manager or another app that wrote between our
        // ⌘C probe and this line got clobbered by our restore.
        let countAfterProbe = NSPasteboard.general.changeCount
        if countAfterProbe != saved.changeCount {
            PasteboardTransaction.restore(saved, ifChangeCountStill: countAfterProbe)
        }

        guard let text = captured, !text.isEmpty, let field = snapshot.field else { return snapshot }

        var updatedField = field
        updatedField.selection = .init(range: nil, text: text)
        // Copy, don't rebuild. The memberwise init dropped `ancestorRoles`,
        // `warmHit` and `axCannotComplete` back to their defaults, and
        // `PressTrace` reads all three from the REFINED snapshot — so every
        // web-selection press logged "no warm hit" and zero AX errors, quietly
        // corrupting the two health metrics §5.1 and R4 are measured by.
        var refined = snapshot
        refined.field = updatedField
        return refined
    }
}
