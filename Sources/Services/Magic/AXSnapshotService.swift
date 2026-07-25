import AppKit
@preconcurrency import ApplicationServices

/// Collect-on-press context capture (V0 — no observer subsystem, §19). An
/// actor so every AX call runs off the main actor on one serialized executor;
/// the process-wide AX messaging timeout plus a hard call budget and an
/// overall deadline guarantee a press can never hang the app (R4).
actor AXSnapshotService {
    /// Per-capture spending limits, seeded from the user-tunable engine
    /// config (`~/.clipslop/config.yaml`).
    struct Budget {
        var remainingCalls: Int
        /// R4 health metric: how often the AX server timed out
        /// (`kAXErrorCannotComplete`) during this capture. Surfaces in the
        /// contentless trace so real-world frequency is measurable.
        var cannotCompleteCount = 0
        let maxSiblingsPerLevel: Int
        let maxGatherDepth: Int
        let maxContentChars: Int
        let maxFieldValueChars: Int
        /// The web walk visits far more nodes than the native sibling walk
        /// (every div is an AXGroup); in-process AX IPC is cheap once the
        /// tree is built, and the capture deadline bounds the worst case.
        let webSweepCalls: Int
        let maxWebDepth: Int
        let maxWebChildrenPerNode: Int
        /// The Mail-style inside-webarea sweep over-collects, then keeps
        /// what's nearest the field. Derived from the keep windows so
        /// raising them in config.yaml never silently hits a lower
        /// collection ceiling.
        let maxWebCollectChars: Int
        let webBeforeKeepChars: Int
        let webAfterKeepChars: Int
        /// Tree mode's only new AX cost: container label reads (AXTitle /
        /// AXDescription / AXRoleDescription). Derived from the call budget
        /// — no config key of its own — and spent from `remainingCalls`
        /// too, so the overall press ceiling never moves.
        var remainingLabelReads: Int
        /// The capture's hard deadline (R4), carried with the budget so every
        /// individual attribute read can honor it. The walks check the
        /// deadline between steps, but the field's own reads — role,
        /// settability, value, selection, placeholder, geometry — happen
        /// before the first such check, and against an AX server that answers
        /// every one with `kAXErrorCannotComplete` each costs the 0.35 s
        /// messaging timeout *twice* (the retry in `copyRaw`). That alone
        /// stretched a nominal 300 ms capture into several seconds. `nil`
        /// means "no deadline" — the observer's cheap read, which is bounded
        /// by its call cap instead.
        var deadline: ContinuousClock.Instant? = nil

        var isPastDeadline: Bool {
            guard let deadline else { return false }
            return ContinuousClock().now >= deadline
        }

        static func labelReadCap(forCalls calls: Int) -> Int {
            max(60, calls / 10)
        }

        init(config: MagicEngineConfig) {
            remainingCalls = config.axCallBudget
            remainingLabelReads = Self.labelReadCap(forCalls: config.axCallBudget)
            maxSiblingsPerLevel = config.maxSiblingsPerLevel
            maxGatherDepth = config.maxGatherDepth
            maxContentChars = config.surroundingMaxChars
            maxFieldValueChars = config.fieldValueMaxChars
            webSweepCalls = config.webCallBudget
            maxWebDepth = config.maxWebDepth
            maxWebChildrenPerNode = config.maxWebChildrenPerNode
            webBeforeKeepChars = config.webBeforeKeepChars
            webAfterKeepChars = config.webAfterKeepChars
            maxWebCollectChars = max(24_000, webBeforeKeepChars + webAfterKeepChars + 8_000)
        }
    }

    private var didConfigureTimeout = false
    /// Processes we already asked to build an accessibility tree (Chromium /
    /// Electron enablement) — the request is per-process, once. Keyed by PID
    /// but *valued* by process identity (the launch date of the application
    /// holding that PID), because the kernel recycles PIDs: a bare
    /// `Set<pid_t>` made a replacement Chromium/Electron process that
    /// inherited a dead one's PID look already-enabled, and it then served an
    /// empty AX tree for the rest of the menu-bar session.
    private var enabledApps: [pid_t: Date] = [:]

    /// Roles whose text content the surrounding walk collects.
    private static let textRoles: Set<String> = [
        "AXStaticText", "AXHeading", "AXLink", "AXTextArea", "AXTextField", "AXCell",
    ]
    private static let editableRoles: Set<String> = [
        "AXTextArea", "AXTextField", "AXComboBox", "AXSearchField",
    ]

    /// The `textRoles` members that can carry `AXSecureTextField` as a SUBROLE
    /// rather than as their role. Static text, headings, links and cells never
    /// do, so only these two ever pay for the extra read below.
    private static let subroleMayBeSecure: Set<String> = ["AXTextArea", "AXTextField"]

    /// Whether a node the walk is about to read the value of is a password
    /// field.
    ///
    /// The focused field is guarded by role OR subrole before any value is
    /// touched, because a password field routinely publishes a plain
    /// `AXTextField` role and carries the secure marker in its subrole alone.
    /// Every node the surrounding walk reaches deserves the same test: a login
    /// form, a "confirm password" row or an unlock sheet sitting beside the
    /// composer is a sibling like any other, and role membership alone would
    /// read its value into the prompt. macOS usually hands back a mask rather
    /// than the characters — that is a mitigation, not the invariant. The
    /// invariant is that a secure value is never touched, and it has to hold on
    /// every path that reads one, not only on the one the press is aimed at.
    ///
    /// One extra attribute read, spent from the same budget as everything else
    /// and only for the two roles that can answer yes. An unreadable subrole is
    /// not evidence of safety, but it is not evidence of danger either: the
    /// element already failed the role test for `AXSecureTextField`, and
    /// refusing every field whose subrole merely timed out would silently empty
    /// the context on exactly the flaky AX servers R4 exists for.
    private func isSecureField(_ element: AXUIElement, role: String, budget: inout Budget) -> Bool {
        guard Self.subroleMayBeSecure.contains(role) else { return false }
        return copyString(element, kAXSubroleAttribute, &budget) == "AXSecureTextField"
    }

    /// The text one leaf node contributes to the surrounding context, or nil
    /// when it contributes none.
    ///
    /// Every walk in this file — flat and structured, native and web — reads its
    /// leaves through here, so the rule about which values may be read at all
    /// has exactly one home. That is the whole point: `isSecureField` is a
    /// privacy invariant, and an invariant with five call sites is one forgotten
    /// edit away from being false on the path nobody was looking at.
    ///
    /// The two parameters are the only things the walks legitimately disagree
    /// about, and both are load bearing:
    ///
    /// - `descriptionFallback` — `AXDescription` is a useful last resort in a
    ///   native tree and noise in a web one, where decorative containers carry
    ///   one each.
    /// - `collapseInternalWhitespace` — the outline renders one line per node,
    ///   so the tree walks fold newlines here. The flat walks must NOT: they
    ///   leave folding to `assembleContent` and count the untouched length
    ///   against their char caps, and collapsing early would make those budgets
    ///   measure something other than what they spend.
    private func nodeText(
        of element: AXUIElement,
        role: String,
        descriptionFallback: Bool,
        collapseInternalWhitespace: Bool,
        budget: inout Budget
    ) -> String? {
        guard !isSecureField(element, role: role, budget: &budget) else { return nil }
        var raw = copyString(element, kAXValueAttribute, &budget)
            ?? copyString(element, kAXTitleAttribute, &budget)
        if raw == nil, descriptionFallback {
            raw = copyString(element, kAXDescriptionAttribute, &budget)
        }
        guard let raw else { return nil }
        let cleaned = collapseInternalWhitespace
            ? Self.collapseWhitespace(raw)
            : raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // One character is a bullet, a separator glyph, a stray digit — never
        // context worth a slot in the prompt.
        return cleaned.count > 1 ? cleaned : nil
    }

    /// Captures the focused field and its surroundings. Always returns a
    /// snapshot — on budget/deadline exhaustion it is partial, never absent.
    /// `appInfo` is read by the caller on the main actor before the hop
    /// (NSWorkspace state should not be sampled from a background executor).
    /// `warm` is the observer's cheap context (§5.1); it backfills URL and
    /// window title when the press-time walk comes up empty, gated on the
    /// focused element still being the one the observer saw.
    func capture(
        appInfo: MagicSnapshot.AppInfo,
        locale: String,
        config: MagicEngineConfig = .default,
        warm: WarmContext? = nil
    ) async -> MagicSnapshot {
        configureTimeoutOnce()

        let clock = ContinuousClock()
        let deadlineInstant = clock.now + .milliseconds(config.captureDeadlineMs)
        var budget = Budget(config: config)
        budget.deadline = deadlineInstant

        let warmUsable = warm.map {
            $0.isUsable(forPid: appInfo.pid, ttlSeconds: config.warmContextTtlSeconds)
        } ?? false

        func expired() -> Bool { clock.now >= deadlineInstant }
        func finish(_ snapshot: MagicSnapshot, _ budget: Budget) -> MagicSnapshot {
            var stamped = snapshot
            stamped.warmHit = warmUsable
            stamped.axCannotComplete = budget.cannotCompleteCount
            return stamped
        }
        /// A press that captured nothing: no field, no target, no content.
        /// `grammarRow` reads `.noTarget`, so nothing can be read from or
        /// written into an element we could not identify.
        func contentless(_ budget: Budget) -> MagicSnapshot {
            finish(MagicSnapshot(
                app: appInfo, windowTitle: nil, url: nil, field: nil,
                surrounding: nil, locale: locale, ts: Date(), focusedElement: nil
            ), budget)
        }

        let systemWide = AXUIElementCreateSystemWide()
        guard let app: AXUIElement = copyElement(systemWide, kAXFocusedApplicationAttribute, &budget)
        else { return contentless(budget) }

        // Bind the capture to the app the caller sampled (§3.1). `appInfo` is
        // read on the main actor *before* the hop onto this actor, and it is
        // the identity routing and `no_cloud` evaluate; the system-wide
        // focused application is read here, one hop later. If the user
        // switched apps in between, everything below — field, value,
        // surroundings — belongs to the new process while the snapshot still
        // claims the old one's bundle ID, so text from a protected native app
        // could be sent to a cloud provider under an unprotected identity (and
        // the Inserter's focus check would only fail afterwards). An
        // AXUIElement's PID is local bookkeeping, not an AX message, so this
        // costs neither budget nor latency.
        guard Self.pid(of: app) == appInfo.pid else { return contentless(budget) }

        // Chromium and Electron build their AX tree lazily and only for
        // clients that announce themselves (§5.1). Ask once per process,
        // give the renderer a beat to materialize the tree the first time.
        let freshlyEnabled = enableAccessibilityIfNeeded(
            app: app, pid: appInfo.pid, budget: &budget
        )
        if freshlyEnabled {
            try? await Task.sleep(for: .milliseconds(250))
        }

        // The same race, one read later: focus can move to another process
        // between the two calls, and `focused` is what every read below — and
        // the Inserter's identity check afterwards — is measured against.
        guard let focused: AXUIElement = copyElement(app, kAXFocusedUIElementAttribute, &budget),
              Self.pid(of: focused) == appInfo.pid
        else { return contentless(budget) }

        // Fail closed when the role is unreadable (§3.1). Any default role —
        // "AXUnknown" included — carries a secure text field whose role read
        // merely timed out (`kAXErrorCannotComplete`, a transient this actor
        // sees often enough to count) straight past the secure guard below and
        // on to `kAXValueAttribute`, one attribute that may well answer, so
        // password text enters the snapshot and the generation prompt. The
        // invariant is that a secure value is never touched; with the role
        // unknown, the only way to keep it is to capture nothing.
        guard let role = copyString(focused, kAXRoleAttribute, &budget) else {
            return contentless(budget)
        }
        let subrole = copyString(focused, kAXSubroleAttribute, &budget)

        // Secure fields: bail before reading anything else — the value of a
        // password field must never be touched (§3.1, no exceptions).
        let secure = role == "AXSecureTextField" || subrole == "AXSecureTextField"
        if secure {
            let field = MagicSnapshot.FieldInfo(
                role: role, subrole: subrole, editable: false, secure: true,
                value: "", selection: nil, placeholder: nil
            )
            return finish(MagicSnapshot(
                app: appInfo, windowTitle: nil, url: nil, field: field,
                surrounding: nil, locale: locale, ts: Date(),
                focusedElement: AXElementRef(element: focused)
            ), budget)
        }

        // Editability: the role list is the fast path; "is the value
        // settable" is the authority (web contenteditable reports odd roles
        // but a settable value).
        var editable = Self.editableRoles.contains(role)
        if !editable, budget.remainingCalls > 0, !budget.isPastDeadline {
            // Not a `copyRaw` read, so it carries its own budget and deadline
            // accounting; it can block for the messaging timeout like any other.
            var settable = DarwinBoolean(false)
            budget.remainingCalls -= 1
            if AXUIElementIsAttributeSettable(focused, kAXValueAttribute as CFString, &settable) == .success {
                editable = settable.boolValue
            }
        }

        // Read the value WHOLE first: the AX selection range is expressed
        // against what the field actually holds, so it can only be converted —
        // and the retained window only chosen — against the untruncated string.
        let fullValue = copyString(focused, kAXValueAttribute, &budget) ?? ""

        let selectionText = copyString(focused, kAXSelectedTextAttribute, &budget)
        // AX ranges are UTF-16 offsets. Converting them to character offsets
        // up front is what makes every consumer below correct: bounds-checking
        // against `value.count` and slicing with grapheme-based
        // `String.index(_:offsetBy:)` treated them as characters, so a single
        // emoji or composed character anywhere before the selection shifted
        // the recovered text — silently, and by exactly the wrong amount.
        let selectionRange = copyRange(focused, kAXSelectedTextRangeAttribute, &budget)
        let characterRange = selectionRange.flatMap { Self.characterRange($0, in: fullValue) }

        // `field_value_max_chars` truncation, caret-aware: the retained window
        // ends exactly at the reported caret / selection end.
        //
        // A bare prefix throws away the one part of a long field the press is
        // actually about — the caret sits at the *end* of a draft far more
        // often than inside its first 50k characters — and it breaks the range
        // conversion with it, since the offsets then point past what was kept.
        // The assembler would build its continuation from the end of the prefix
        // while the paste lands at the real caret, and a selection would lose
        // its before/after positioning entirely.
        //
        // The caret is also the position every consumer already assumes when no
        // range survives (`ContinuationSeam` clamps to `value.count`,
        // `PromptAssembler` keeps the draft's tail), so ending there is what
        // makes the windowed and the un-windowed cases agree.
        //
        // The offsets stay ABSOLUTE, i.e. character offsets into the field's
        // whole value: that is what `MagicPressCoordinator.reassertSelectionIfLost`
        // and `CaretLocator` need, since both measure against the live value
        // they re-read rather than against `field.value`. Consumers that index
        // into `value` instead stay safe by construction — a window is only
        // ever shifted when `upperBound` exceeds `maxFieldValueChars`, and
        // `value.count` is then that same cap, so their bounds checks reject
        // the range and they fall back to text search / caret-at-end instead
        // of slicing at a wrong offset.
        let window = Self.retainedWindow(
            valueCount: fullValue.count, around: characterRange,
            maxChars: budget.maxFieldValueChars
        )
        let value = Self.retainedValue(fullValue, window: window)

        var selection: MagicSnapshot.SelectionInfo?
        if let selectionText, !selectionText.isEmpty {
            selection = MagicSnapshot.SelectionInfo(
                range: characterRange.flatMap { $0.isEmpty ? nil : $0 }, text: selectionText
            )
        } else if let characterRange, !characterRange.isEmpty, !value.isEmpty,
                  window.lowerBound == 0, characterRange.upperBound <= value.count {
            // Some web fields report a range but empty AXSelectedText —
            // recover the text from the value, which is only possible while
            // the range still indexes it (an unshifted window). If it does
            // not, the caller runs the synthetic-⌘C fallback.
            let start = value.index(value.startIndex, offsetBy: characterRange.lowerBound)
            let end = value.index(value.startIndex, offsetBy: characterRange.upperBound)
            selection = MagicSnapshot.SelectionInfo(
                range: characterRange, text: String(value[start..<end])
            )
        }

        let placeholder = copyString(focused, kAXPlaceholderValueAttribute, &budget)

        let field = MagicSnapshot.FieldInfo(
            role: role, subrole: subrole, editable: editable, secure: false,
            value: value, selection: selection, placeholder: placeholder,
            selectedRange: characterRange,
            frame: copyFrame(focused, &budget)
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

        // Warm backfill (§5.1 cache split): only when the observer's cheap
        // read saw this exact focused element — a tab switch or focus move
        // since then makes the cached URL/title wrong, and a miss is fine.
        if let warm, warmUsable, let warmElement = warm.focusedElement,
           CFEqual(warmElement.element, focused) {
            if url == nil { url = warm.url }
            if windowTitle == nil { windowTitle = warm.windowTitle }
        }

        // Budgeted surrounding walk (§5.2 rung 1: the AX tree). Web content
        // uses a document-order sweep of the whole web area — the
        // ancestor-sibling walk is structurally too shallow for Chromium's
        // deeply nested trees (a chat's message list lives many AXGroup
        // levels away from the composer).
        func walk(_ budget: inout Budget) -> String {
            if let webArea {
                budget.remainingCalls = max(budget.remainingCalls, budget.webSweepCalls)
                let webAreaIndex = ancestors.firstIndex { CFEqual($0, webArea) } ?? 0
                if webAreaIndex == 0 {
                    // Mail-style: focus IS the web area — its own content
                    // (draft + quoted thread) is the context.
                    return collectWebAreaSurroundings(
                        root: webArea, focused: focused, budget: &budget, expired: expired
                    )
                }
                // Chat-style: walk outward from the composer, collecting the
                // *nearest* content first. A top-down page sweep on a long
                // thread burns its budget on months-old messages and never
                // reaches the ones being replied to; sidebars only get
                // pulled in when the thread itself is thin.
                return collectWebNearestFirst(
                    ancestors: ancestors, webAreaIndex: webAreaIndex,
                    budget: &budget, expired: expired
                )
            }
            return collectSurroundings(
                focused: focused, ancestors: ancestors, budget: &budget, expired: expired
            )
        }

        /// Tree counterpart of `walk`: same routing, same budgets, same
        /// deadline — only the accumulator differs (nodes, not strings).
        func treeWalk(_ budget: inout Budget) -> SurroundingNode {
            if let webArea {
                budget.remainingCalls = max(budget.remainingCalls, budget.webSweepCalls)
                budget.remainingLabelReads = Budget.labelReadCap(forCalls: budget.remainingCalls)
                let webAreaIndex = ancestors.firstIndex { CFEqual($0, webArea) } ?? 0
                if webAreaIndex == 0 {
                    return collectWebAreaTree(
                        root: webArea, focused: focused, fieldRole: role,
                        budget: &budget, expired: expired
                    )
                }
                return collectWebNearestFirstTree(
                    ancestors: ancestors, ancestorRoles: ancestorRoles,
                    webAreaIndex: webAreaIndex, fieldRole: role,
                    budget: &budget, expired: expired
                )
            }
            return collectNativeTree(
                focused: focused, ancestors: ancestors, ancestorRoles: ancestorRoles,
                fieldRole: role, budget: &budget, expired: expired
            )
        }

        // First press in a freshly-enabled Chromium/Electron process often
        // races the tree build — one retry with a fresh budget. With the
        // warm observer running, enablement happens at app activation, so
        // this path is the fallback for presses that beat the observer.
        var surrounding: MagicSnapshot.Surrounding?
        if config.surroundingTreeEnabled != 0 {
            var tree = treeWalk(&budget)
            if !tree.hasText, freshlyEnabled, !expired() {
                try? await Task.sleep(for: .milliseconds(300))
                var retryBudget = Budget(config: config)
                retryBudget.deadline = deadlineInstant
                retryBudget.remainingCalls = retryBudget.webSweepCalls
                retryBudget.remainingLabelReads = Budget.labelReadCap(forCalls: retryBudget.remainingCalls)
                tree = treeWalk(&retryBudget)
                budget.cannotCompleteCount += retryBudget.cannotCompleteCount
            }
            if tree.hasText {
                // `content` carries a full (untrimmed) render so every
                // string-only consumer keeps working; the real budgeting
                // happens in the assembler on `tree`.
                var content = SurroundingTreeRenderer.render(tree, maxTokens: 0).text
                if content.count > budget.maxContentChars {
                    content = String(content.prefix(budget.maxContentChars))
                }
                surrounding = .axTreeStructured(content: content, tree: tree)
            }
        } else {
            var surroundingText = walk(&budget)
            if surroundingText.isEmpty, freshlyEnabled, !expired() {
                try? await Task.sleep(for: .milliseconds(300))
                var retryBudget = Budget(config: config)
                retryBudget.deadline = deadlineInstant
                retryBudget.remainingCalls = retryBudget.webSweepCalls
                surroundingText = walk(&retryBudget)
                budget.cannotCompleteCount += retryBudget.cannotCompleteCount
            }
            surrounding = surroundingText.isEmpty ? nil : .axTree(content: surroundingText)
        }

        return finish(MagicSnapshot(
            app: appInfo,
            windowTitle: windowTitle,
            url: url,
            field: field,
            surrounding: surrounding,
            locale: locale,
            ts: Date(),
            focusedElement: AXElementRef(element: focused),
            // ancestors[0] is the focused element itself, so this reads
            // focused-upward.
            ancestorRoles: ancestorRoles
        ), budget)
    }

    // MARK: - Warm collector support (§5.1)

    /// Called by the frontmost observer at app activation: request the AX
    /// tree from Chromium/Electron processes *before* any press, so the
    /// lazy build races the user's reading time instead of the capture
    /// deadline.
    func warmUp(pid: pid_t) {
        guard pid > 0 else { return }
        configureTimeoutOnce()
        let app = AXUIElementCreateApplication(pid)
        // No deadline: this runs at app activation with nobody waiting, so the
        // call cap is the whole bound. The budget exists only because the
        // enablement writes are charged like every other AX call.
        var budget = Budget(config: .default)
        _ = enableAccessibilityIfNeeded(app: app, pid: pid, budget: &budget)
    }

    /// The observer's cheap read (§5.1): focused element identity, role,
    /// window title, URL — single-attribute reads plus one ancestor climb
    /// for the web area. Never reads the field value, selection, or
    /// surroundings; those are always fresh at press time. Touching the
    /// focused element here is also what keeps Chromium's lazily-built tree
    /// materialized.
    func cheapCapture(appInfo: MagicSnapshot.AppInfo, config: MagicEngineConfig) -> WarmContext {
        configureTimeoutOnce()
        var budget = Budget(config: config)
        budget.remainingCalls = min(budget.remainingCalls, 120)

        func context(
            windowTitle: String? = nil, url: String? = nil,
            focused: AXUIElement? = nil, role: String? = nil
        ) -> WarmContext {
            WarmContext(
                pid: appInfo.pid, bundleId: appInfo.bundleId,
                windowTitle: windowTitle, url: url,
                focusedElement: focused.map { AXElementRef(element: $0) },
                fieldRole: role, capturedAt: Date()
            )
        }

        let systemWide = AXUIElementCreateSystemWide()
        guard let app: AXUIElement = copyElement(systemWide, kAXFocusedApplicationAttribute, &budget),
              let focused: AXUIElement = copyElement(app, kAXFocusedUIElementAttribute, &budget)
        else { return context() }

        let role = copyString(focused, kAXRoleAttribute, &budget)

        var url: String?
        var cursor: AXUIElement? = focused
        var hops = 0
        while let current = cursor, hops < 25, budget.remainingCalls > 0 {
            if copyString(current, kAXRoleAttribute, &budget) == "AXWebArea" {
                url = copyURLString(current, "AXURL", &budget)
                    ?? copyString(current, "AXDocument", &budget)
                break
            }
            cursor = copyElement(current, kAXParentAttribute, &budget)
            hops += 1
        }

        var windowTitle: String?
        if let window: AXUIElement = copyElement(focused, kAXWindowAttribute, &budget) {
            windowTitle = copyString(window, kAXTitleAttribute, &budget)
            if url == nil {
                url = copyURLString(window, "AXURL", &budget) ?? copyString(window, "AXDocument", &budget)
            }
        }

        return context(windowTitle: windowTitle, url: url, focused: focused, role: role)
    }

    // MARK: - Surrounding walk (web content)

    /// Nearest-first outward walk for web content: at each ancestor level of
    /// the focused element, gather the siblings *before* the focused path in
    /// reverse document order (nearest first — in a chat, the newest
    /// messages) until the keep budget is full, plus a little of what
    /// follows. Collected pieces are then flipped back to document order.
    private func collectWebNearestFirst(
        ancestors: [AXUIElement],
        webAreaIndex: Int,
        budget: inout Budget,
        expired: () -> Bool
    ) -> String {
        var beforeReversed: [String] = []
        var after: [String] = []
        var beforeChars = 0
        var afterChars = 0

        /// Deep text gather. `reverse` visits children bottom-up so pieces
        /// arrive nearest-first.
        func gather(_ element: AXUIElement, depth: Int, reverse: Bool, into pieces: inout [String], chars: inout Int, cap: Int) {
            guard depth < budget.maxWebDepth, budget.remainingCalls > 0, !expired(), chars < cap else { return }
            guard let role = copyString(element, kAXRoleAttribute, &budget) else { return }
            if Self.textRoles.contains(role) {
                if let cleaned = nodeText(
                    of: element, role: role, descriptionFallback: false,
                    collapseInternalWhitespace: false, budget: &budget
                ) {
                    pieces.append(cleaned)
                    chars += cleaned.count
                }
                return
            }
            guard let children: [AXUIElement] = copyElementArray(element, kAXChildrenAttribute, &budget) else { return }
            let ordered = reverse
                ? Array(children.suffix(budget.maxWebChildrenPerNode).reversed())
                : Array(children.prefix(budget.maxWebChildrenPerNode))
            for child in ordered {
                gather(child, depth: depth + 1, reverse: reverse, into: &pieces, chars: &chars, cap: cap)
            }
        }

        for level in 1...webAreaIndex {
            guard beforeChars < budget.webBeforeKeepChars, budget.remainingCalls > 0, !expired() else { break }
            let parent = ancestors[level]
            let pathChild = ancestors[level - 1]
            guard let children: [AXUIElement] = copyElementArray(parent, kAXChildrenAttribute, &budget),
                  let pathIndex = children.firstIndex(where: { CFEqual($0, pathChild) })
            else { continue }

            for sibling in children[..<pathIndex].reversed() {
                guard beforeChars < budget.webBeforeKeepChars else { break }
                gather(sibling, depth: 0, reverse: true, into: &beforeReversed, chars: &beforeChars,
                       cap: budget.webBeforeKeepChars)
            }
            for sibling in children[(pathIndex + 1)...] {
                guard afterChars < budget.webAfterKeepChars else { break }
                gather(sibling, depth: 0, reverse: false, into: &after, chars: &afterChars,
                       cap: budget.webAfterKeepChars)
            }
        }

        return Self.assembleContent(
            pieces: beforeReversed.reversed() + after,
            maxChars: budget.maxContentChars
        )
    }

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
                if let cleaned = nodeText(
                    of: element, role: role, descriptionFallback: false,
                    collapseInternalWhitespace: false, budget: &budget
                ) {
                    if seenFocused { after.append(cleaned) } else { before.append(cleaned) }
                    collectedChars += cleaned.count
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
            if let cleaned = nodeText(
                of: element, role: role, descriptionFallback: true,
                collapseInternalWhitespace: false, budget: &budget
            ) {
                pieces.append(cleaned)
                totalChars += cleaned.count
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

    // MARK: - Surrounding walk (tree mode)

    /// Whitespace collapse for tree node text and labels — the outline
    /// renders one line per node, so internal newlines fold at gather time
    /// (the flat path does the same in `assembleContent`).
    nonisolated static func collapseWhitespace(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Container label: AXTitle → AXDescription → (spine only)
    /// AXRoleDescription. Every read spends from BOTH the label cap and the
    /// call budget. Callers skip elements with fewer than two children —
    /// single-child wrappers get hoisted by normalization anyway, and
    /// Chromium has 15-deep chains of them.
    private func containerLabel(_ element: AXUIElement, isSpine: Bool, budget: inout Budget) -> String? {
        func read(_ attribute: String) -> String? {
            guard budget.remainingLabelReads > 0 else { return nil }
            budget.remainingLabelReads -= 1
            guard let raw = copyString(element, attribute, &budget) else { return nil }
            let cleaned = Self.collapseWhitespace(raw)
            return cleaned.isEmpty ? nil : cleaned
        }
        if let title = read(kAXTitleAttribute) { return title }
        if let description = read(kAXDescriptionAttribute) { return description }
        if isSpine, let roleDescription = read(kAXRoleDescriptionAttribute) { return roleDescription }
        return nil
    }

    /// Deep gather mirroring `gather`/`gatherText` — same visit order, same
    /// depth/width/char caps, same expiry checks — accumulating nodes
    /// instead of strings. `reverse` spends the budget nearest-first (the
    /// web before-walk); the resulting children are flipped back to
    /// document order.
    private func gatherNode(
        _ element: AXUIElement,
        depth: Int,
        maxDepth: Int,
        maxChildren: Int,
        reverse: Bool,
        descriptionFallback: Bool,
        chars: inout Int,
        cap: Int,
        budget: inout Budget,
        expired: () -> Bool
    ) -> SurroundingNode? {
        guard depth < maxDepth, budget.remainingCalls > 0, !expired(), chars < cap else { return nil }
        guard let role = copyString(element, kAXRoleAttribute, &budget) else { return nil }
        if Self.textRoles.contains(role) {
            guard let cleaned = nodeText(
                of: element, role: role, descriptionFallback: descriptionFallback,
                collapseInternalWhitespace: true, budget: &budget
            ) else { return nil }
            chars += cleaned.count
            return SurroundingNode(role: role, text: cleaned)
        }
        guard let children: [AXUIElement] = copyElementArray(element, kAXChildrenAttribute, &budget) else {
            return nil
        }
        let ordered = reverse
            ? Array(children.suffix(maxChildren).reversed())
            : Array(children.prefix(maxChildren))
        var collected: [SurroundingNode] = []
        for child in ordered {
            if let node = gatherNode(
                child, depth: depth + 1, maxDepth: maxDepth, maxChildren: maxChildren,
                reverse: reverse, descriptionFallback: descriptionFallback,
                chars: &chars, cap: cap, budget: &budget, expired: expired
            ) {
                collected.append(node)
            }
        }
        guard !collected.isEmpty else { return nil }
        if reverse { collected.reverse() }
        let label = children.count >= 2
            ? containerLabel(element, isSpine: false, budget: &budget)
            : nil
        return SurroundingNode(role: role, label: label, children: collected)
    }

    /// Tree counterpart of `collectWebNearestFirst`: the ancestor spine
    /// becomes nested container nodes, per-level sibling subtrees hang off
    /// it in document order, and the field node sits at the spine's bottom.
    private func collectWebNearestFirstTree(
        ancestors: [AXUIElement],
        ancestorRoles: [String],
        webAreaIndex: Int,
        fieldRole: String,
        budget: inout Budget,
        expired: () -> Bool
    ) -> SurroundingNode {
        var current = SurroundingNode(role: fieldRole, isField: true)
        var beforeChars = 0
        var afterChars = 0

        for level in 1...webAreaIndex {
            guard beforeChars < budget.webBeforeKeepChars, budget.remainingCalls > 0, !expired() else { break }
            let parent = ancestors[level]
            let pathChild = ancestors[level - 1]
            guard let children: [AXUIElement] = copyElementArray(parent, kAXChildrenAttribute, &budget),
                  let pathIndex = children.firstIndex(where: { CFEqual($0, pathChild) })
            else { continue }

            var beforeReversed: [SurroundingNode] = []
            for sibling in children[..<pathIndex].reversed() {
                guard beforeChars < budget.webBeforeKeepChars else { break }
                if let node = gatherNode(
                    sibling, depth: 0, maxDepth: budget.maxWebDepth,
                    maxChildren: budget.maxWebChildrenPerNode, reverse: true,
                    descriptionFallback: false,
                    chars: &beforeChars, cap: budget.webBeforeKeepChars,
                    budget: &budget, expired: expired
                ) {
                    beforeReversed.append(node)
                }
            }
            var after: [SurroundingNode] = []
            for sibling in children[(pathIndex + 1)...] {
                guard afterChars < budget.webAfterKeepChars else { break }
                if let node = gatherNode(
                    sibling, depth: 0, maxDepth: budget.maxWebDepth,
                    maxChildren: budget.maxWebChildrenPerNode, reverse: false,
                    descriptionFallback: false,
                    chars: &afterChars, cap: budget.webAfterKeepChars,
                    budget: &budget, expired: expired
                ) {
                    after.append(node)
                }
            }

            var parentRole = level < ancestorRoles.count ? ancestorRoles[level] : "?"
            if parentRole == "?" { parentRole = "AXGroup" }
            let label = children.count >= 2
                ? containerLabel(parent, isSpine: true, budget: &budget)
                : nil
            current = SurroundingNode(
                role: parentRole, label: label,
                children: beforeReversed.reversed() + [current] + after
            )
        }
        return current
    }

    /// Tree counterpart of `collectWebAreaSurroundings`: document-order
    /// sweep of the web area, the focused element becoming the field node.
    /// Mail exception preserved: when focus IS the web area root, its own
    /// content is the context and a synthetic field node is appended at the
    /// end of the root's children (the caret effectively sits at the end).
    private func collectWebAreaTree(
        root: AXUIElement,
        focused: AXUIElement,
        fieldRole: String,
        budget: inout Budget,
        expired: () -> Bool
    ) -> SurroundingNode {
        let skipFocusedSubtree = !CFEqual(root, focused)
        var collectedChars = 0

        func sweepNode(_ element: AXUIElement, depth: Int) -> SurroundingNode? {
            guard depth < budget.maxWebDepth, budget.remainingCalls > 0, !expired(),
                  collectedChars < budget.maxWebCollectChars
            else { return nil }
            if skipFocusedSubtree, CFEqual(element, focused) {
                return SurroundingNode(role: fieldRole, isField: true)
            }

            guard let role = copyString(element, kAXRoleAttribute, &budget) else { return nil }
            if Self.textRoles.contains(role) {
                guard let cleaned = nodeText(
                    of: element, role: role, descriptionFallback: false,
                    collapseInternalWhitespace: true, budget: &budget
                ) else { return nil }
                collectedChars += cleaned.count
                return SurroundingNode(role: role, text: cleaned)
            }

            guard let children: [AXUIElement] = copyElementArray(element, kAXChildrenAttribute, &budget) else {
                return nil
            }
            var collected: [SurroundingNode] = []
            for child in children.prefix(budget.maxWebChildrenPerNode) {
                if let node = sweepNode(child, depth: depth + 1) { collected.append(node) }
            }
            guard !collected.isEmpty else { return nil }
            let label = children.count >= 2
                ? containerLabel(element, isSpine: false, budget: &budget)
                : nil
            return SurroundingNode(role: role, label: label, children: collected)
        }

        var rootNode = sweepNode(root, depth: 0) ?? SurroundingNode(role: "AXWebArea")
        if !skipFocusedSubtree {
            rootNode.children.append(SurroundingNode(role: fieldRole, isField: true))
        }
        return rootNode
    }

    /// Tree counterpart of `collectSurroundings`: the ancestor spine as
    /// nested nodes, each level's siblings gathered in document order
    /// around the field's path, the field node at the bottom.
    private func collectNativeTree(
        focused: AXUIElement,
        ancestors: [AXUIElement],
        ancestorRoles: [String],
        fieldRole: String,
        budget: inout Budget,
        expired: () -> Bool
    ) -> SurroundingNode {
        var current = SurroundingNode(role: fieldRole, isField: true)
        var totalChars = 0

        for (index, ancestor) in ancestors.enumerated().dropFirst() {
            guard budget.remainingCalls > 0, !expired(), totalChars < budget.maxContentChars else { break }
            let pathChild = ancestors[index - 1]
            guard let children: [AXUIElement] = copyElementArray(ancestor, kAXChildrenAttribute, &budget) else {
                continue
            }
            // Sample AROUND the path child, not from the head of the list. A
            // blind `prefix(maxSiblingsPerLevel)` dropped the siblings nearest
            // the field whenever the path child sat beyond the cap — and the
            // old `seenPath` flag then never flipped, so everything collected
            // was emitted as "before" and ⟨YOUR FIELD⟩ came out after a run of
            // unrelated leading siblings. The web walk already samples around
            // its `pathIndex`; this is the same rule for the native walk.
            let pathIndex = children.firstIndex {
                CFEqual($0, pathChild) || CFEqual($0, focused)
            }
            let cap = budget.maxSiblingsPerLevel
            let beforeAll = pathIndex.map { children[..<$0] } ?? children[...]
            let afterAll = pathIndex.map { children[($0 + 1)...] } ?? children[children.endIndex...]
            // Each side gets half, and whichever side is short gives its
            // remainder to the other — nearest the field always wins.
            let afterCount = min(afterAll.count, max(0, cap - min(beforeAll.count, cap / 2)))
            let beforeCount = min(beforeAll.count, cap - afterCount)

            var before: [SurroundingNode] = []
            var after: [SurroundingNode] = []
            func gather(_ siblings: ArraySlice<AXUIElement>, into nodes: inout [SurroundingNode]) {
                for sibling in siblings {
                    guard budget.remainingCalls > 0, !expired(), totalChars < budget.maxContentChars else { break }
                    if let node = gatherNode(
                        sibling, depth: 0, maxDepth: budget.maxGatherDepth,
                        maxChildren: budget.maxSiblingsPerLevel, reverse: false,
                        descriptionFallback: true,
                        chars: &totalChars, cap: budget.maxContentChars,
                        budget: &budget, expired: expired
                    ) {
                        nodes.append(node)
                    }
                }
            }
            gather(beforeAll.suffix(beforeCount), into: &before)
            gather(afterAll.prefix(afterCount), into: &after)
            var ancestorRole = index < ancestorRoles.count ? ancestorRoles[index] : "?"
            if ancestorRole == "?" { ancestorRole = "AXGroup" }
            let label = children.count >= 2
                ? containerLabel(ancestor, isSpine: true, budget: &budget)
                : nil
            current = SurroundingNode(
                role: ancestorRole, label: label,
                children: before + [current] + after
            )
        }
        return current
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
    /// Asks a Chromium/Electron process to build its accessibility tree, once
    /// per process. Returns true only when this call is what enabled it — the
    /// caller reads that as "the tree may still be materializing" and pays for
    /// a settle plus one retry walk.
    ///
    /// The cache is keyed by PID but *valued* by process identity, because a
    /// PID is not one: the kernel hands it out again once the process exits and
    /// this actor lives for the whole menu-bar session. Keyed on the PID alone,
    /// a replacement Chromium/Electron process that inherits a dead one's PID
    /// reads as already-enabled and is never asked to build its tree, so it
    /// serves an empty one until ClipSlop restarts. The launch date of whatever
    /// holds the PID *now* is the part a recycled PID cannot inherit.
    private func enableAccessibilityIfNeeded(
        app: AXUIElement, pid: pid_t, budget: inout Budget
    ) -> Bool {
        guard pid > 0 else { return false }
        let identity = Self.processIdentity(pid)
        guard enabledApps[pid] != identity else { return false }
        // Two synchronous AX writes, each able to block for the process-wide
        // 0.35 s messaging timeout. They are charged and deadline-gated like
        // every other AX call this actor makes, or the capture's hard bound
        // (R4) is short by exactly the time this pair can take — and it is the
        // one pair that runs *before* the first walk gets to check anything.
        // Charged before the cache is stamped, so a press that could not afford
        // the attempt leaves the process still marked un-enabled and the next
        // one tries again.
        guard budget.remainingCalls > 0, !budget.isPastDeadline else { return false }
        pruneTerminatedApps()
        enabledApps[pid] = identity

        // `AXManualAccessibility` is Chromium's own private attribute — nothing
        // else implements it — so accepting it is what identifies a browser
        // engine, and rejecting it is what identifies everything else.
        budget.remainingCalls -= 1
        let manual = AXUIElementSetAttributeValue(
            app, "AXManualAccessibility" as CFString, kCFBooleanTrue
        )
        guard manual == .success else { return false }

        // `AXEnhancedUserInterface` is AppKit's "an assistive client is
        // watching" flag. It is process-wide, permanent for the life of the
        // target (nothing here ever unsets it), and on an ordinary AppKit app it
        // changes window move/resize behaviour — a documented source of conflict
        // with window managers, and a side effect bought for a tree that was
        // never lazily built in the first place. Ordinary AppKit apps also
        // *accept* it, so setting it unconditionally marks every app the user
        // activates as freshly-enabled and charges every first press the settle
        // and retry walk above.
        //
        // Only a Chromium host reaches here, which is the only place the flag
        // buys anything: some Chromium/Electron versions answer to it and not to
        // the attribute above.
        guard budget.remainingCalls > 0, !budget.isPastDeadline else { return true }
        budget.remainingCalls -= 1
        AXUIElementSetAttributeValue(
            app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue
        )
        return true
    }

    /// Identity of the application currently holding a PID. `.distantPast`
    /// stands for "no launch date published" — it still distinguishes that
    /// process from any successor whose launch date IS readable, and the
    /// pruning below removes the entry as soon as the process is gone.
    private static func processIdentity(_ pid: pid_t) -> Date {
        NSRunningApplication(processIdentifier: pid)?.launchDate ?? .distantPast
    }

    /// Drops entries whose process has exited, so the enablement cache cannot
    /// grow for the life of the session and cannot shadow a PID's next owner.
    /// Runs only on the (rare) enablement path.
    private func pruneTerminatedApps() {
        enabledApps = enabledApps.filter { pid, _ in
            NSRunningApplication(processIdentifier: pid)?.isTerminated == false
        }
    }

    /// The process an `AXUIElement` belongs to. Local bookkeeping inside the
    /// element — no AX message, so it costs nothing from the call budget.
    private static func pid(of element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        return pid
    }

    /// One process-global messaging timeout (R4): a hung AX server answers
    /// with `kAXErrorCannotComplete` after 0.35 s instead of blocking us.
    private func configureTimeoutOnce() {
        guard !didConfigureTimeout else { return }
        didConfigureTimeout = true
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.35)
    }

    /// Copies an attribute with budget accounting and one retry on
    /// `.cannotComplete` (§5.1). Refuses to start — or to retry — once the
    /// capture deadline has passed: a single read can block for the 0.35 s
    /// messaging timeout, so the deadline has to be enforced per call and not
    /// only between walk steps, or the promised hard bound (R4) is nominal.
    private func copyRaw(_ element: AXUIElement, _ attribute: String, _ budget: inout Budget) -> CFTypeRef? {
        guard budget.remainingCalls > 0, !budget.isPastDeadline else { return nil }
        var value: CFTypeRef?
        budget.remainingCalls -= 1
        var result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        if result == .cannotComplete, budget.remainingCalls > 0, !budget.isPastDeadline {
            budget.cannotCompleteCount += 1
            budget.remainingCalls -= 1
            result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        }
        if result == .cannotComplete {
            budget.cannotCompleteCount += 1
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

    /// The slice of an over-long field value the snapshot keeps, as character
    /// offsets into the whole value. Pure, extracted for tests.
    ///
    /// Below the cap nothing is dropped. Above it, a caret or selection that
    /// still fits inside the leading `maxChars` keeps the historical prefix —
    /// offsets there index `value` directly, so the cheap consumers stay
    /// exact. Only when the reported range lies *beyond* the prefix does the
    /// window slide, and it then ends exactly at the range's upper bound: the
    /// retained text is the context immediately preceding the caret, which is
    /// what a draft continuation and a selection's "before" both need.
    nonisolated static func retainedWindow(
        valueCount: Int, around range: Range<Int>?, maxChars: Int
    ) -> Range<Int> {
        guard maxChars > 0 else { return 0..<0 }
        guard valueCount > maxChars else { return 0..<valueCount }
        guard let range, range.upperBound > maxChars, range.upperBound <= valueCount else {
            return 0..<maxChars
        }
        return (range.upperBound - maxChars)..<range.upperBound
    }

    /// Applies a `retainedWindow` to the value it was computed for. Split from
    /// the window arithmetic so the offsets are testable without a live field.
    nonisolated static func retainedValue(_ value: String, window: Range<Int>) -> String {
        guard window.lowerBound > 0 || window.upperBound < value.count else { return value }
        guard let start = value.index(
                value.startIndex, offsetBy: window.lowerBound, limitedBy: value.endIndex
              ),
              let end = value.index(start, offsetBy: window.count, limitedBy: value.endIndex)
        else { return value }
        return String(value[start..<end])
    }

    /// A UTF-16 `CFRange` from AX mapped onto character offsets into `value`.
    /// Always called with the field's WHOLE value, so the offsets it returns
    /// are absolute — `retainedWindow` may keep less than that, and the
    /// coordinator re-reads the live value to re-assert a selection. Returns
    /// nil when the range does not lie inside the value at all (a stale
    /// range) — a caller must not silently act on offsets that point nowhere.
    nonisolated static func characterRange(_ range: CFRange, in value: String) -> Range<Int>? {
        guard range.location >= 0, range.length >= 0 else { return nil }
        let utf16 = value.utf16
        guard let start = utf16.index(
                utf16.startIndex, offsetBy: range.location, limitedBy: utf16.endIndex
              ),
              let end = utf16.index(start, offsetBy: range.length, limitedBy: utf16.endIndex),
              // A UTF-16 offset landing mid-surrogate has no character index.
              let startIndex = String.Index(start, within: value),
              let endIndex = String.Index(end, within: value)
        else { return nil }
        let lower = value.distance(from: value.startIndex, to: startIndex)
        let upper = value.distance(from: value.startIndex, to: endIndex)
        return lower..<upper
    }

    /// AXPosition + AXSize as one rect. Two calls, spent from the same budget
    /// as everything else; a field that publishes neither simply has no frame
    /// and the Inserter falls back to value agreement.
    private func copyFrame(_ element: AXUIElement, _ budget: inout Budget) -> CGRect? {
        guard let originRaw = copyRaw(element, kAXPositionAttribute, &budget),
              CFGetTypeID(originRaw) == AXValueGetTypeID(),
              let sizeRaw = copyRaw(element, kAXSizeAttribute, &budget),
              CFGetTypeID(sizeRaw) == AXValueGetTypeID()
        else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue((originRaw as! AXValue), .cgPoint, &origin),
              AXValueGetValue((sizeRaw as! AXValue), .cgSize, &size)
        else { return nil }
        return CGRect(origin: origin, size: size)
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
