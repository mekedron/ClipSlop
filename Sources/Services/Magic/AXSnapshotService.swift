import AppKit
@preconcurrency import ApplicationServices

/// Collect-on-press context capture (V0 — no observer subsystem, §19). An
/// actor so every AX call runs off the main actor on one serialized executor;
/// the process-wide AX messaging timeout plus a hard call budget and an
/// overall deadline guarantee a press can never hang the app (R4).
actor AXSnapshotService {
    struct Budget {
        var remainingCalls: Int = 200
        let maxAncestorDepth = 8
        let maxSiblingsPerLevel = 12
        let maxGatherDepth = 3
        let maxContentChars = 6000
        let maxFieldValueChars = 50_000
    }

    private var didConfigureTimeout = false

    /// Roles whose text content the surrounding walk collects.
    private static let textRoles: Set<String> = [
        "AXStaticText", "AXHeading", "AXLink", "AXTextArea", "AXTextField", "AXCell",
    ]
    private static let editableRoles: Set<String> = [
        "AXTextArea", "AXTextField", "AXComboBox", "AXSearchField",
    ]

    /// Captures the focused field and its surroundings. Always returns a
    /// snapshot — on budget/deadline exhaustion it is partial, never absent.
    /// `appInfo` is read by the caller on the main actor before the hop
    /// (NSWorkspace state should not be sampled from a background executor).
    func capture(
        appInfo: MagicSnapshot.AppInfo,
        locale: String,
        deadline: Duration = .milliseconds(1200)
    ) -> MagicSnapshot {
        configureTimeoutOnce()

        let clock = ContinuousClock()
        let deadlineInstant = clock.now + deadline
        var budget = Budget()

        func expired() -> Bool { clock.now >= deadlineInstant }

        let systemWide = AXUIElementCreateSystemWide()
        guard let app: AXUIElement = copyElement(systemWide, kAXFocusedApplicationAttribute, &budget),
              let focused: AXUIElement = copyElement(app, kAXFocusedUIElementAttribute, &budget)
        else {
            return MagicSnapshot(
                app: appInfo, windowTitle: nil, url: nil, field: nil,
                surrounding: nil, locale: locale, ts: Date(), focusedElement: nil
            )
        }

        let role = copyString(focused, kAXRoleAttribute, &budget) ?? "AXUnknown"
        let subrole = copyString(focused, kAXSubroleAttribute, &budget)

        // Secure fields: bail before reading anything else — the value of a
        // password field must never be touched (§3.1, no exceptions).
        let secure = role == "AXSecureTextField" || subrole == "AXSecureTextField"
        if secure {
            let field = MagicSnapshot.FieldInfo(
                role: role, subrole: subrole, editable: false, secure: true,
                value: "", selection: nil, placeholder: nil
            )
            return MagicSnapshot(
                app: appInfo, windowTitle: nil, url: nil, field: field,
                surrounding: nil, locale: locale, ts: Date(),
                focusedElement: AXElementRef(element: focused)
            )
        }

        // Editability: the role list is the fast path; "is the value
        // settable" is the authority (web contenteditable reports odd roles
        // but a settable value).
        var editable = Self.editableRoles.contains(role)
        if !editable {
            var settable = DarwinBoolean(false)
            budget.remainingCalls -= 1
            if AXUIElementIsAttributeSettable(focused, kAXValueAttribute as CFString, &settable) == .success {
                editable = settable.boolValue
            }
        }

        var value = copyString(focused, kAXValueAttribute, &budget) ?? ""
        if value.count > budget.maxFieldValueChars {
            value = String(value.prefix(budget.maxFieldValueChars))
        }

        let selectionText = copyString(focused, kAXSelectedTextAttribute, &budget)
        let selectionRange = copyRange(focused, kAXSelectedTextRangeAttribute, &budget)
        var selection: MagicSnapshot.SelectionInfo?
        if let selectionText, !selectionText.isEmpty {
            let range = selectionRange.flatMap { $0.length > 0 ? $0.location..<($0.location + $0.length) : nil }
            selection = MagicSnapshot.SelectionInfo(range: range, text: selectionText)
        } else if let selectionRange, selectionRange.length > 0,
                  !value.isEmpty, selectionRange.location + selectionRange.length <= value.count {
            // Some web fields report a range but empty AXSelectedText —
            // recover the text from the value; if that fails too, the caller
            // runs the synthetic-⌘C fallback.
            let start = value.index(value.startIndex, offsetBy: selectionRange.location)
            let end = value.index(start, offsetBy: selectionRange.length)
            selection = MagicSnapshot.SelectionInfo(
                range: selectionRange.location..<(selectionRange.location + selectionRange.length),
                text: String(value[start..<end])
            )
        }

        let placeholder = copyString(focused, kAXPlaceholderValueAttribute, &budget)

        let field = MagicSnapshot.FieldInfo(
            role: role, subrole: subrole, editable: editable, secure: false,
            value: value, selection: selection, placeholder: placeholder
        )

        // Window title + URL, walking ancestors once.
        var windowTitle: String?
        var url: String?
        var ancestors: [AXUIElement] = []
        var cursor: AXUIElement? = focused
        while let current = cursor, ancestors.count < budget.maxAncestorDepth, !expired() {
            ancestors.append(current)
            cursor = copyElement(current, kAXParentAttribute, &budget)
        }
        for ancestor in ancestors where url == nil && !expired() {
            let ancestorRole = copyString(ancestor, kAXRoleAttribute, &budget)
            if ancestorRole == "AXWebArea" {
                url = copyURLString(ancestor, "AXURL", &budget)
                    ?? copyString(ancestor, "AXDocument", &budget)
            }
        }
        if let window: AXUIElement = copyElement(focused, kAXWindowAttribute, &budget) {
            windowTitle = copyString(window, kAXTitleAttribute, &budget)
            if url == nil {
                url = copyURLString(window, "AXURL", &budget) ?? copyString(window, "AXDocument", &budget)
            }
        }

        // Budgeted surrounding walk (§5.2 rung 1: the AX tree).
        let surroundingText = collectSurroundings(
            focused: focused, ancestors: ancestors,
            budget: &budget, expired: expired
        )

        return MagicSnapshot(
            app: appInfo,
            windowTitle: windowTitle,
            url: url,
            field: field,
            surrounding: surroundingText.isEmpty ? nil : .axTree(content: surroundingText),
            locale: locale,
            ts: Date(),
            focusedElement: AXElementRef(element: focused)
        )
    }

    // MARK: - Surrounding walk

    /// Walks up from the focused element; at each ancestor level, gathers
    /// text from the focused-path element's siblings in document order.
    /// Every attribute read decrements the budget; the deadline aborts the
    /// walk wherever it happens to be.
    private func collectSurroundings(
        focused: AXUIElement,
        ancestors: [AXUIElement],
        budget: inout Budget,
        expired: () -> Bool
    ) -> String {
        var pieces: [String] = []
        var totalChars = 0

        for (index, ancestor) in ancestors.enumerated().dropFirst() {
            guard budget.remainingCalls > 0, !expired(), totalChars < budget.maxContentChars else { break }
            let pathChild = ancestors[index - 1]

            guard let children: [AXUIElement] = copyElementArray(ancestor, kAXChildrenAttribute, &budget) else {
                continue
            }
            for sibling in children.prefix(budget.maxSiblingsPerLevel) {
                guard budget.remainingCalls > 0, !expired(), totalChars < budget.maxContentChars else { break }
                if CFEqual(sibling, pathChild) || CFEqual(sibling, focused) { continue }
                gatherText(
                    from: sibling, depth: 0, into: &pieces,
                    totalChars: &totalChars, budget: &budget, expired: expired
                )
            }
        }

        return Self.assembleContent(pieces: pieces, maxChars: budget.maxContentChars)
    }

    private func gatherText(
        from element: AXUIElement,
        depth: Int,
        into pieces: inout [String],
        totalChars: inout Int,
        budget: inout Budget,
        expired: () -> Bool
    ) {
        guard depth < budget.maxGatherDepth, budget.remainingCalls > 0, !expired(),
              totalChars < budget.maxContentChars
        else { return }

        guard let role = copyString(element, kAXRoleAttribute, &budget) else { return }

        if Self.textRoles.contains(role) {
            let text = copyString(element, kAXValueAttribute, &budget)
                ?? copyString(element, kAXTitleAttribute, &budget)
                ?? copyString(element, kAXDescriptionAttribute, &budget)
            if let text {
                let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if cleaned.count > 1 {
                    pieces.append(cleaned)
                    totalChars += cleaned.count
                }
            }
            return
        }

        guard let children: [AXUIElement] = copyElementArray(element, kAXChildrenAttribute, &budget) else { return }
        for child in children.prefix(budget.maxSiblingsPerLevel) {
            gatherText(
                from: child, depth: depth + 1, into: &pieces,
                totalChars: &totalChars, budget: &budget, expired: expired
            )
        }
    }

    /// Pure assembly: dedup consecutive duplicates, collapse whitespace runs,
    /// cap total length. Extracted static for tests.
    nonisolated static func assembleContent(pieces: [String], maxChars: Int) -> String {
        var deduped: [String] = []
        for piece in pieces {
            let collapsed = piece
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            guard !collapsed.isEmpty, collapsed != deduped.last else { continue }
            deduped.append(collapsed)
        }
        var result = deduped.joined(separator: "\n")
        if result.count > maxChars {
            result = String(result.prefix(maxChars))
        }
        return result
    }

    // MARK: - AX plumbing

    /// One process-global messaging timeout (R4): a hung AX server answers
    /// with `kAXErrorCannotComplete` after 0.35 s instead of blocking us.
    private func configureTimeoutOnce() {
        guard !didConfigureTimeout else { return }
        didConfigureTimeout = true
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.35)
    }

    /// Copies an attribute with budget accounting and one retry on
    /// `.cannotComplete` (§5.1).
    private func copyRaw(_ element: AXUIElement, _ attribute: String, _ budget: inout Budget) -> CFTypeRef? {
        guard budget.remainingCalls > 0 else { return nil }
        var value: CFTypeRef?
        budget.remainingCalls -= 1
        var result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        if result == .cannotComplete, budget.remainingCalls > 0 {
            budget.remainingCalls -= 1
            result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        }
        return result == .success ? value : nil
    }

    private func copyString(_ element: AXUIElement, _ attribute: String, _ budget: inout Budget) -> String? {
        copyRaw(element, attribute, &budget) as? String
    }

    private func copyURLString(_ element: AXUIElement, _ attribute: String, _ budget: inout Budget) -> String? {
        guard let raw = copyRaw(element, attribute, &budget) else { return nil }
        if let url = raw as? URL { return url.absoluteString }
        if CFGetTypeID(raw) == CFURLGetTypeID() {
            return (raw as! CFURL as URL).absoluteString
        }
        return raw as? String
    }

    private func copyElement(_ element: AXUIElement, _ attribute: String, _ budget: inout Budget) -> AXUIElement? {
        guard let raw = copyRaw(element, attribute, &budget),
              CFGetTypeID(raw) == AXUIElementGetTypeID()
        else { return nil }
        return (raw as! AXUIElement)
    }

    private func copyElementArray(_ element: AXUIElement, _ attribute: String, _ budget: inout Budget) -> [AXUIElement]? {
        guard let raw = copyRaw(element, attribute, &budget) as? [AnyObject] else { return nil }
        return raw.compactMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
    }

    private func copyRange(_ element: AXUIElement, _ attribute: String, _ budget: inout Budget) -> CFRange? {
        guard let raw = copyRaw(element, attribute, &budget),
              CFGetTypeID(raw) == AXValueGetTypeID()
        else { return nil }
        let axValue = raw as! AXValue
        var range = CFRange()
        guard AXValueGetType(axValue) == .cfRange,
              AXValueGetValue(axValue, .cfRange, &range)
        else { return nil }
        return range
    }
}
