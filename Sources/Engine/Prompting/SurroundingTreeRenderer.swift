import Foundation

/// Renders a collected `SurroundingNode` tree as an indented outline the
/// model can navigate — container tags like `[list: comments]`, bare text
/// lines, one `⟨YOUR FIELD⟩` marker at the exact box being written in, and
/// an ancestor-chain header — and trims it structure-aware: on overflow the
/// content nearest the field survives, farthest units drop first, and the
/// field's ancestor chain plus the marker are never evicted. Pure; runs in
/// the assembler (and the planner), never in the collector.
enum SurroundingTreeRenderer {
    static let fieldMarkerPrefix = "⟨YOUR FIELD — you are writing here"
    static let trimMarker = "[… more content trimmed …]"
    static let chainHeaderPrefix = "YOU ARE WRITING IN: "
    /// Suffix on every container line on the field path. A screen routinely
    /// holds several conversation-shaped regions at once (a conversation
    /// list, a docked chat overlay, the thread the field is actually in),
    /// and indentation alone across a long outline is not legible enough for
    /// a model to tell which of them encloses the field — the containment
    /// must be readable from the line itself, so the field's enclosing
    /// sections carry it in words and every other region visibly lacks it.
    static let containsFieldNote = "contains your field"
    static let outlineHeader =
        "SCREEN OUTLINE (⟨YOUR FIELD⟩ marks the exact box you are writing in; "
        + "the nested containers marked \"contains your field\" are the sections that enclose it):"

    private static let indentStep = "  "
    private static let maxLabelChars = 80

    /// Pure-structure roles: unlabeled they emit no line of their own
    /// (their children keep the indent level); labeled they emit `[label]`
    /// without the noise of a "group" tag.
    private static let genericContainerRoles: Set<String> = [
        "AXGroup", "AXGenericElement", "AXUnknown",
    ]

    // MARK: - Normalization

    /// Applies, in order: (1) unlabeled wrapper containers with exactly one
    /// child are deleted and the child hoists — this kills Chromium's
    /// AXGroup chains; (2) containers with no text descendants and no field
    /// are deleted entirely. The field node itself is never touched.
    static func normalize(_ root: SurroundingNode) -> SurroundingNode {
        normalized(root) ?? SurroundingNode(role: root.role, label: root.label, isField: root.isField)
    }

    private static func normalized(_ node: SurroundingNode) -> SurroundingNode? {
        var node = node
        node.children = node.children.compactMap(normalized)
        if node.isField { return node }
        let hasOwnText = node.text?.isEmpty == false
        // Empty container: no own text, no surviving children (a child with
        // text or the field always survives) → gone.
        if !hasOwnText, node.children.isEmpty { return nil }
        // Wrapper: no label, no text, exactly one child → the child hoists.
        if !hasOwnText, (node.label ?? "").isEmpty, node.children.count == 1 {
            return node.children[0]
        }
        return node
    }

    // MARK: - Field path and ancestor chain

    /// Labels (or informative role tags) of the containers on the path from
    /// the root to the field, outermost first — "feed › post by Priya Patel
    /// › comments". Empty when the tree carries no field.
    static func ancestorChain(of root: SurroundingNode) -> [String] {
        let tree = normalize(root)
        return chainElements(tree: tree, path: fieldPath(in: tree))
    }

    /// Child-index path from the root to the field node, nil when absent.
    private static func fieldPath(in node: SurroundingNode) -> [Int]? {
        if node.isField { return [] }
        for (index, child) in node.children.enumerated() {
            if let sub = fieldPath(in: child) { return [index] + sub }
        }
        return nil
    }

    private static func chainElements(tree: SurroundingNode, path: [Int]?) -> [String] {
        guard let path else { return [] }
        var elements: [String] = []
        var node = tree
        for index in path {
            if let element = chainElement(for: node) { elements.append(element) }
            guard node.children.indices.contains(index) else { break }
            node = node.children[index]
        }
        return elements
    }

    private static func chainElement(for node: SurroundingNode) -> String? {
        if let label = node.label, !label.isEmpty { return truncatedLabel(label) }
        guard !genericContainerRoles.contains(node.role), node.text == nil else { return nil }
        return roleTag(node.role)
    }

    // MARK: - Line rendering

    private static func roleTag(_ role: String) -> String {
        let stripped = role.hasPrefix("AX") ? String(role.dropFirst(2)) : role
        return stripped.lowercased()
    }

    private static func truncatedLabel(_ label: String) -> String {
        label.count <= maxLabelChars ? label : String(label.prefix(maxLabelChars)) + "…"
    }

    /// The bracketed tag line a container emits — or nil for an unlabeled
    /// generic container off the field path (its children keep the indent
    /// level; the container itself is silent). On-path containers carry the
    /// `containsFieldNote` suffix (see its comment for why containment has
    /// to be spelled out).
    private static func containerLine(for node: SurroundingNode, onFieldPath: Bool) -> String? {
        let generic = genericContainerRoles.contains(node.role)
        let note = onFieldPath ? " — \(containsFieldNote)" : ""
        if let label = node.label, !label.isEmpty {
            let clipped = truncatedLabel(label)
            return generic ? "[\(clipped)\(note)]" : "[\(roleTag(node.role)): \(clipped)\(note)]"
        }
        guard !generic || onFieldPath else { return nil }
        return "[\(roleTag(node.role))\(note)]"
    }

    private static func fieldMarkerLine(note: String?) -> String {
        if let note, !note.isEmpty { return fieldMarkerPrefix + " — " + note + "⟩" }
        return fieldMarkerPrefix + "⟩"
    }

    // MARK: - Outline construction

    private struct OutlineLine {
        let text: String
        let indent: Int
        let unit: Int
        let cost: Int
    }

    /// Trim priority of a unit: nearest the field first. Level 1 is the
    /// field's own siblings, level 2 the parent's siblings, … up to the
    /// root; within a level, before-siblings (nearest first) precede
    /// after-siblings (nearest first).
    private struct UnitPriority: Comparable {
        let level: Int
        let after: Int
        let distance: Int
        static func < (lhs: Self, rhs: Self) -> Bool {
            (lhs.level, lhs.after, lhs.distance) < (rhs.level, rhs.after, rhs.distance)
        }
    }

    private static func outline(
        tree: SurroundingNode, path: [Int]?, fieldNote: String?
    ) -> (lines: [OutlineLine], priorities: [Int: UnitPriority]) {
        var lines: [OutlineLine] = []
        var priorities: [Int: UnitPriority] = [:]
        var nextUnit = 1

        func append(_ text: String, indent: Int, unit: Int) {
            let rendered = String(repeating: indentStep, count: indent) + text
            lines.append(OutlineLine(
                text: rendered, indent: indent, unit: unit,
                cost: TokenEstimator.estimate(rendered)
            ))
        }

        func emit(_ node: SurroundingNode, indent: Int, pathRemainder: ArraySlice<Int>?, unit: Int) {
            if node.isField {
                append(fieldMarkerLine(note: fieldNote), indent: indent, unit: 0)
                return
            }
            let onPath = pathRemainder != nil
            let lineUnit = onPath ? 0 : unit
            var childIndent = indent
            if let text = node.text, !text.isEmpty {
                append(text, indent: indent, unit: lineUnit)
                childIndent = indent + 1
            } else if !node.children.isEmpty {
                if let line = containerLine(for: node, onFieldPath: onPath) {
                    append(line, indent: indent, unit: lineUnit)
                }
                childIndent = indent + 1
            }
            let pathIndex = pathRemainder?.first
            for (index, child) in node.children.enumerated() {
                if let pathIndex, index == pathIndex {
                    emit(child, indent: childIndent, pathRemainder: pathRemainder?.dropFirst(), unit: unit)
                } else if let pathIndex, let remainder = pathRemainder {
                    // A maximal subtree hanging off a field-path ancestor —
                    // one trim unit. The remaining path length IS the level.
                    let id = nextUnit
                    nextUnit += 1
                    priorities[id] = UnitPriority(
                        level: remainder.count,
                        after: index > pathIndex ? 1 : 0,
                        distance: abs(index - pathIndex)
                    )
                    emit(child, indent: childIndent, pathRemainder: nil, unit: id)
                } else {
                    emit(child, indent: childIndent, pathRemainder: nil, unit: unit)
                }
            }
        }

        // No field (defensive — collected trees always carry one): anchor
        // the priorities at the tail via a virtual path index past the last
        // child, matching the flat walk's keep-the-tail rule.
        let effectivePath = path ?? [tree.children.count]
        emit(tree, indent: 0, pathRemainder: effectivePath[...], unit: 0)
        return (lines, priorities)
    }

    // MARK: - Render + structure-aware trim

    /// Renders the tree within `maxTokens` (0 = everything, untrimmed).
    /// Unit 0 — the headers, every container line on the field path, and
    /// the marker — is always kept, so the marker can never be orphaned.
    /// Remaining units are included nearest-first; the first that does not
    /// fully fit is included partially (farthest-from-field lines dropped),
    /// and a single trim-marker line stands wherever content was cut.
    static func render(
        _ root: SurroundingNode, maxTokens: Int, fieldNote: String? = nil
    ) -> (text: String, truncated: Bool) {
        let tree = normalize(root)
        let path = fieldPath(in: tree)

        var headerLines: [String] = []
        let chain = chainElements(tree: tree, path: path)
        if !chain.isEmpty {
            headerLines.append(chainHeaderPrefix + chain.joined(separator: " › "))
        }
        headerLines.append(path == nil ? "SCREEN OUTLINE:" : outlineHeader)

        let (lines, priorities) = outline(tree: tree, path: path, fieldNote: fieldNote)

        var keptUnits: Set<Int> = [0]
        var partialUnit: Int?
        var partialKept: Set<Int> = []

        if maxTokens <= 0 {
            // 0 = unlimited: everything renders, nothing trims.
            keptUnits.formUnion(priorities.keys)
        } else if !priorities.isEmpty {
            let headerCost = headerLines.reduce(0) { $0 + TokenEstimator.estimate($1) }
            let unitZeroCost = lines.filter { $0.unit == 0 }.reduce(0) { $0 + $1.cost }
            var remaining = maxTokens - headerCost - unitZeroCost
            let ordered = priorities
                .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value < $1.value }
                .map(\.key)
            for unit in ordered {
                let unitIndices = lines.indices.filter { lines[$0].unit == unit }
                let cost = unitIndices.reduce(0) { $0 + lines[$1].cost }
                if cost <= remaining {
                    keptUnits.insert(unit)
                    remaining -= cost
                    continue
                }
                // First unit that does not fully fit: partial include,
                // nearest-to-field lines first — the tail of a before-unit,
                // the head of an after-unit — then stop; every farther unit
                // is dropped.
                let after = priorities[unit]?.after == 1
                var budgetLeft = remaining - TokenEstimator.estimate(trimMarker)
                var kept: Set<Int> = []
                for index in (after ? unitIndices : unitIndices.reversed()) {
                    guard lines[index].cost <= budgetLeft else { break }
                    kept.insert(index)
                    budgetLeft -= lines[index].cost
                }
                if !kept.isEmpty {
                    partialUnit = unit
                    partialKept = kept
                }
                break
            }
        }

        var out = headerLines
        var truncated = false
        var pendingGapIndent: Int?
        for (index, line) in lines.enumerated() {
            let kept = keptUnits.contains(line.unit)
                || (line.unit == partialUnit && partialKept.contains(index))
            if kept {
                if let gap = pendingGapIndent {
                    out.append(String(repeating: indentStep, count: gap) + trimMarker)
                    pendingGapIndent = nil
                }
                out.append(line.text)
            } else {
                truncated = true
                pendingGapIndent = min(pendingGapIndent ?? line.indent, line.indent)
            }
        }
        if let gap = pendingGapIndent {
            out.append(String(repeating: indentStep, count: gap) + trimMarker)
        }
        return (out.joined(separator: "\n"), truncated)
    }
}
