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
        // Non-editable areas can hold a selection AX won't expose either;
        // trying ⌘C there is cheap and harmless (no change = no selection).
        return !field.editable || !field.value.isEmpty
    }

    /// Captures the selection via ⌘C with changeCount polling, restores the
    /// previous pasteboard, and returns an updated snapshot. One retry.
    static func refine(_ snapshot: MagicSnapshot) async -> MagicSnapshot {
        let saved = PasteboardTransaction.save()

        var captured = await PasteboardTransaction.captureViaCommandC()
        if captured == nil {
            captured = await PasteboardTransaction.captureViaCommandC(timeout: .milliseconds(200))
        }

        if captured != nil {
            // Our probe overwrote the pasteboard; put the user's content back
            // (unconditional modulo a same-instant writer).
            PasteboardTransaction.restore(saved, ifChangeCountStill: NSPasteboard.general.changeCount)
        }

        guard let text = captured, !text.isEmpty, let field = snapshot.field else { return snapshot }

        let updatedField = MagicSnapshot.FieldInfo(
            role: field.role, subrole: field.subrole,
            editable: field.editable, secure: field.secure,
            value: field.value,
            selection: .init(range: nil, text: text),
            placeholder: field.placeholder
        )
        return MagicSnapshot(
            app: snapshot.app, windowTitle: snapshot.windowTitle, url: snapshot.url,
            field: updatedField, surrounding: snapshot.surrounding,
            locale: snapshot.locale, ts: snapshot.ts,
            focusedElement: snapshot.focusedElement
        )
    }
}
