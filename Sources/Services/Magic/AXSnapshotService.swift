import AppKit
@preconcurrency import ApplicationServices

/// Collect-on-press context capture (V0 — no observer subsystem, §19). An
/// actor so every AX call runs off the main actor on one serialized executor;
/// the process-wide AX messaging timeout plus a hard call budget and an
/// overall deadline guarantee a press can never hang the app (R4).
actor AXSnapshotService {
    struct Budget {
        var remainingCalls: Int = 350
        let maxAncestorDepth = 10
        let maxSiblingsPerLevel = 16
        let maxGatherDepth = 6
        let maxContentChars = 6000
        let maxFieldValueChars = 50_000

        /// The web-area document-order sweep visits far more nodes than the
        /// native sibling walk (every div is an AXGroup); in-process AX IPC
        /// is cheap once the tree is built, and the overall capture deadline
        /// still bounds the worst case.
        static let webSweepCalls = 900
        let maxWebDepth = 30
        let maxWebChildrenPerNode = 60
        /// The sweep over-collects, then keeps what's nearest the field.
        let maxWebCollectChars = 24_000
        let webBeforeKeepChars = 4500
        let webAfterKeepChars = 1000
    }

    private var didConfigureTimeout = false
    /// PIDs we already asked to build an accessibility tree (Chromium /
    /// Electron enablement) — the request is per-process, once.
    private var enabledPIDs: Set<pid_t> = []

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
        deadline: Duration = .milliseconds(1600)
    ) async -> MagicSnapshot {
        configureTimeoutOnce()

        let clock = ContinuousClock()
        let deadlineInstant = clock.now + deadline
        var budget = Budget()

        func expired() -> Bool { clock.now >= deadlineInstant }

        let systemWide = AXUIElementCreateSystemWide()
        guard let app: AXUIElement = copyElement(systemWide, kAXFocusedApplicationAttribute, &budget)
        else {
            return MagicSnapshot(
                app: appInfo, windowTitle: nil, url: nil, field: nil,
                surrounding: nil, locale: locale, ts: Date(), focusedElement: nil
            )
        }

        // Chromium and Electron build their AX tree lazily and only for
        // clients that announce themselves (§5.1). Ask once per process,
        // give the renderer a beat to materialize the tree the first time.
        let freshlyEnabled = enableAccessibilityIfNeeded(app: app, pid: appInfo.pid)
        if freshlyEnabled {
            try? await Task.sleep(for: .milliseconds(250))
        }

        guard let focused: AXUIElement = copyElement(app, kAXFocusedUIElementAttribute, &budget)
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

        // Window title + URL, walking ancestors once. Web content gets a
        // deeper ancestor allowance — Chromium wraps every div in an
        // AXGroup, so the focused field can sit 15+ levels below the web
        // area.
        var windowTitle: String?
        var url: String?
        var webArea: AXUIElement?
        var ancestors: [AXUIElement] = []
        var cursor: AXUIElement? = focused
        while let current = cursor, ancestors.count < 25, !expired() {
            ancestors.append(current)
            cursor = copyElement(current, kAXParentAttribute, &budget)
        }
        var ancestorRoles: [String] = []
        for ancestor in ancestors where !expired() {
            let ancestorRole = copyString(ancestor, kAXRoleAttribute, &budget)
            ancestorRoles.append(ancestorRole ?? "?")
            if webArea == nil, ancestorRole == "AXWebArea" {
                webArea = ancestor
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

        // Budgeted surrounding walk (§5.2 rung 1: the AX tree). Web content
        // uses a document-order sweep of the whole web area — the
        // ancestor-sibling walk is structurally too shallow for Chromium's
        // deeply nested trees (a chat's message list lives many AXGroup
        // levels away from the composer).
        func walk(_ budget: inout Budget) -> String {
            if let webArea {
                // Locality ladder (§5.2 "walk up from focus"): sweep a near
                // ancestor's subtree first and widen only while context is
                // thin. Sweeping the page root directly drags in sidebars —
                // on chat surfaces that means *other conversations'*
                // previews polluting the thread.
                budget.remainingCalls = max(budget.remainingCalls, Budget.webSweepCalls)
                let webAreaIndex = ancestors.firstIndex { CFEqual($0, webArea) } ?? 0
                var rootIndices: [Int] = []
                for candidate in [min(5, webAreaIndex), min(10, webAreaIndex), webAreaIndex]
                where !rootIndices.contains(candidate) {
                    rootIndices.append(candidate)
                }
                var result = ""
                for index in rootIndices {
                    result = collectWebAreaSurroundings(
                        root: ancestors[index], focused: focused, budget: &budget, expired: expired
                    )
                    if result.count >= 300 || budget.remainingCalls <= 0 || expired() { break }
                }
                return result
            }
            return collectSurroundings(
                focused: focused, ancestors: ancestors, budget: &budget, expired: expired
            )
        }

        var surroundingText = walk(&budget)
        // First press in a freshly-enabled Chromium/Electron process often
        // races the tree build — one retry with a fresh budget.
        if surroundingText.isEmpty, freshlyEnabled, !expired() {
            try? await Task.sleep(for: .milliseconds(300))
            var retryBudget = Budget()
            retryBudget.remainingCalls = Budget.webSweepCalls
            surroundingText = walk(&retryBudget)
        }

        return MagicSnapshot(
            app: appInfo,
            windowTitle: windowTitle,
            url: url,
            field: field,
            surrounding: surroundingText.isEmpty ? nil : .axTree(content: surroundingText),
            locale: locale,
            ts: Date(),
            focusedElement: AXElementRef(element: focused),
            // ancestors[0] is the focused element itself, so this reads
            // focused-upward.
            ancestorRoles: ancestorRoles
        )
    }

    // MARK: - Surrounding walk (web content)

    /// Document-order text sweep of a web subtree, split around the focused
    /// element. For a chat this keeps the messages immediately above the
    /// composer — the conversation being replied to — and a little of what
    /// follows. The focused element's own subtree (the draft) is skipped —
    /// **unless the focused element IS the root**: Mail's compose reports
    /// focus on the AXWebArea itself, and its content (draft + quoted
    /// thread) is exactly what we're here to read.
    private func collectWebAreaSurroundings(
        root: AXUIElement,
        focused: AXUIElement,
        budget: inout Budget,
        expired: () -> Bool
    ) -> String {
        let skipFocusedSubtree = !CFEqual(root, focused)

        var before: [String] = []
        var after: [String] = []
        var seenFocused = false
        var collectedChars = 0

        func sweep(_ element: AXUIElement, depth: Int) {
            guard depth < budget.maxWebDepth, budget.remainingCalls > 0, !expired(),
                  collectedChars < budget.maxWebCollectChars
            else { return }
            if skipFocusedSubtree, CFEqual(element, focused) {
                seenFocused = true
                return
            }

            guard let role = copyString(element, kAXRoleAttribute, &budget) else { return }
            if Self.textRoles.contains(role) {
                let text = copyString(element, kAXValueAttribute, &budget)
                    ?? copyString(element, kAXTitleAttribute, &budget)
                if let text {
                    let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if cleaned.count > 1 {
                        if seenFocused { after.append(cleaned) } else { before.append(cleaned) }
                        collectedChars += cleaned.count
                    }
                }
                return
            }

            guard let children: [AXUIElement] = copyElementArray(element, kAXChildrenAttribute, &budget) else { return }
            for child in children.prefix(budget.maxWebChildrenPerNode) {
                sweep(child, depth: depth + 1)
            }
        }
        sweep(root, depth: 0)

        return Self.assembleWebContent(
            before: before, after: after,
            beforeKeepChars: budget.webBeforeKeepChars,
            afterKeepChars: budget.webAfterKeepChars,
            maxChars: budget.maxContentChars
        )
    }

    /// Keeps the tail of the text preceding the field (nearest context —
    /// for a chat, the latest messages) plus the head of what follows.
    /// Pure, extracted for tests.
    nonisolated static func assembleWebContent(
        before: [String],
        after: [String],
        beforeKeepChars: Int,
        afterKeepChars: Int,
        maxChars: Int
    ) -> String {
        var keptBefore: [String] = []
        var count = 0
        for piece in before.reversed() {
            keptBefore.append(piece)
            count += piece.count
            if count >= beforeKeepChars { break }
        }

        var keptAfter: [String] = []
        count = 0
        for piece in after {
            keptAfter.append(piece)
            count += piece.count
            if count >= afterKeepChars { break }
        }

        return assembleContent(pieces: keptBefore.reversed() + keptAfter, maxChars: maxChars)
    }

    // MARK: - Surrounding walk (native)

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

    /// Asks a Chromium/Electron process to build its accessibility tree.
    /// `AXManualAccessibility` is the Electron switch; **stock Chromium/
    /// Chrome ignores it** and instead honors `AXEnhancedUserInterface`
    /// (the flag VoiceOver sets). We set both, once per process — other
    /// apps report the attributes unsupported and nothing happens. The
    /// flag stays on for the process lifetime: toggling it is what caused
    /// the notorious Chrome window-relayout bugs, and the browser-CPU cost
    /// of leaving it on is the R11 tradeoff the design accepts for V0.
    /// Returns true on the first request to a process (the caller then
    /// waits for the tree to build).
    private func enableAccessibilityIfNeeded(app: AXUIElement, pid: pid_t) -> Bool {
        guard pid > 0, !enabledPIDs.contains(pid) else { return false }
        enabledPIDs.insert(pid)
        let manual = AXUIElementSetAttributeValue(
            app, "AXManualAccessibility" as CFString, kCFBooleanTrue
        )
        let enhanced = AXUIElementSetAttributeValue(
            app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue
        )
        return manual == .success || enhanced == .success
    }

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
