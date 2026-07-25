import Foundation

/// A pure value snapshot of the accessibility structure around the focused
/// field: containers (with the labels the collector could afford to read),
/// cleaned text leaves, and exactly one `isField` marker node. Built by the
/// collector, carried on `MagicSnapshot.Surrounding`, rendered and trimmed
/// by `SurroundingTreeRenderer` — never mutated in between.
struct SurroundingNode: Sendable, Equatable {
    /// Raw AX role ("AXGroup", "AXList", …) — the walk reads it anyway, so
    /// carrying it is free.
    var role: String
    /// Container label: AXTitle → AXDescription → (spine only)
    /// AXRoleDescription. Nil when unlabeled or the label budget ran out.
    var label: String? = nil
    /// Cleaned text for text-role leaves; nil for containers.
    var text: String? = nil
    var children: [SurroundingNode] = []
    /// Exactly one node in a collected tree: the focused field. Its own
    /// content is never in the tree — the draft travels in the field slot.
    var isField: Bool = false

    var containsField: Bool { isField || children.contains(where: \.containsField) }

    /// Any collected text anywhere in the subtree — the emptiness test
    /// `capture()` uses, mirroring the flat walk's "nothing gathered" check
    /// so `contextBlind` semantics stay identical.
    var hasText: Bool {
        if let text, !text.isEmpty { return true }
        return children.contains(where: \.hasText)
    }

    /// Text-only join in document order — no structural tags, no marker.
    /// Used where the renderer's English scaffolding would skew analysis
    /// (the verifier's language identification).
    var plainText: String {
        var pieces: [String] = []
        appendText(to: &pieces)
        return pieces.joined(separator: "\n")
    }

    private func appendText(to pieces: inout [String]) {
        if let text, !text.isEmpty { pieces.append(text) }
        for child in children { child.appendText(to: &pieces) }
    }
}
