import Foundation

/// Full-content debug record of one press — everything needed to trace a
/// misbehaving run: the complete snapshot, the routing decision, the exact
/// prompt, the raw model output, and how it ended. The counterpart of the
/// always-on contentless `PressTrace`; written only while the user has
/// enabled debug logging in Settings → Magic.
struct MagicDebugEntry: Sendable {
    let trace: PressTrace
    let snapshot: MagicSnapshot?
    let classification: SelectionClassification?
    let decision: RoutingDecision?
    let workflowID: String?
    let workflowChain: [String]?
    let hint: String?
    let assembled: AssembledPrompt?
    let output: String?
    let verdict: VerifierVerdict?
    let errorDescription: String?
}

/// Writes one human-readable markdown file per press to
/// `~/.clipslop/logs/debug/`, pruned after 7 days. These files contain the
/// user's actual screen content and drafts — the header of every file says
/// so.
///
/// Every press, `no_cloud` surfaces included, and deliberately: `no_cloud`
/// (§14, P7) is a rule about which *provider* may see a surface, and skipping
/// those presses here would blind the one diagnostic on exactly the apps whose
/// routing is hardest to reason about — the ones that refuse, or silently swap
/// to a local model. Local disk is not the boundary that setting draws. What
/// carries the risk instead is the mode being on at all, so it is opt-in, the
/// files are 0600 in a 0700 directory, they expire in a week, and both the file
/// header and `docs/guides/privacy-and-data` say plainly that a protected app's
/// content lands here too.
actor MagicDebugLogger {
    private let directory: URL
    private let keepDays: Int
    /// When `pruneOldLogs` last ran on this actor. The header of every file
    /// here promises a 7-day life, and a prune that only happens at launch
    /// keeps that promise for nobody: ClipSlop is a menu-bar accessory that
    /// routinely stays up for weeks, so the files it swore to delete are
    /// exactly the ones it never gets around to.
    private var lastPrune: ContinuousClock.Instant?
    private static let pruneInterval: Duration = .seconds(3600)

    init(
        directory: URL = Constants.Engine.logsDirectory.appendingPathComponent("debug"),
        keepDays: Int = 7
    ) {
        self.directory = directory
        self.keepDays = keepDays
    }

    func write(_ entry: MagicDebugEntry) {
        // 0700 on the directory, 0600 on every file. These hold the user's
        // draft, their screen, and other people's messages verbatim — the exact
        // content the always-on trace is contentless in order to avoid keeping.
        // The engine tree lives in a home directory shared with every process
        // running as this user, so the default 0755/0644 publishes it to all of
        // them. `atomically:` writes through a temp file and the rename carries
        // that file's mode, so the chmod has to follow the write rather than
        // precede it.
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: directory.path
        )

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let stamp = formatter.string(from: Date())
        let shortID = String(entry.trace.traceID.uuidString.prefix(8))
        let url = directory.appendingPathComponent("press-\(stamp)-\(shortID).md")

        do {
            try Self.render(entry).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return
        }
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path
        )
        pruneIfDue()
    }

    /// Hourly at most, off the press that triggered it: the prune is a
    /// directory listing plus a `resourceValues` per file, and the press path
    /// is already the latency-sensitive one.
    private func pruneIfDue(now: ContinuousClock.Instant = ContinuousClock().now) {
        if let lastPrune, now - lastPrune < Self.pruneInterval { return }
        lastPrune = now
        pruneOldLogs()
    }

    func pruneOldLogs(now: Date = Date()) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let cutoff = now.addingTimeInterval(-Double(keepDays) * 86400)
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? now
            if modified < cutoff {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    // MARK: - Rendering

    nonisolated static func render(_ entry: MagicDebugEntry) -> String {
        var out = """
        # Magic Button debug log
        > Contains full screen content, prompts, and model output — including
        > presses on `no_cloud` surfaces, which that setting keeps off the
        > network rather than off this disk. Delete freely; files older than
        > 7 days are pruned automatically.

        - trace: `\(entry.trace.traceID.uuidString)` (links to traces-*.jsonl)
        - time: \(entry.trace.ts.ISO8601Format())
        - outcome: **\(entry.trace.outcome)**
        - situation: `\(entry.trace.situationClass)` · presentation: \(entry.trace.presentation)
        - latency ms: \(entry.trace.latencyMs)

        """

        if let snapshot = entry.snapshot {
            let field = snapshot.field
            out += """

            ## Snapshot
            - app: \(snapshot.app.name ?? "?") (`\(snapshot.app.bundleId ?? "?")`, pid \(snapshot.app.pid))
            - window: \(snapshot.windowTitle ?? "—")
            - url: \(snapshot.url ?? "—")
            - grammar row: \(snapshot.grammarRow)
            - field: role=\(field?.role ?? "—") subrole=\(field?.subrole ?? "—") editable=\(field.map { String($0.editable) } ?? "—") secure=\(field.map { String($0.secure) } ?? "—")
            - ancestor roles: \(snapshot.ancestorRoles.joined(separator: " > "))
            - warm hit: \(snapshot.warmHit) · ax cannotComplete: \(snapshot.axCannotComplete)

            ### Field value (\(field?.value.count ?? 0) chars)
            ```
            \(field?.value ?? "")
            ```

            ### Selection (\(field?.selection?.text.count ?? 0) chars)
            ```
            \(field?.selection?.text ?? "")
            ```

            ### Surroundings (method: \(snapshot.surrounding?.method ?? "none"), \(snapshot.surrounding?.content.count ?? 0) chars)
            ```
            \(snapshot.surrounding?.content ?? "")
            ```

            """
        }

        if let classification = entry.classification {
            out += """

            ## Selection classification
            - ranked: \(classification.ranked.map(\.rawValue).joined(separator: " > ")) (tie: \(classification.isTie))
            - signals: \(classification.signals)

            """
        }

        if let decision = entry.decision {
            out += """

            ## Routing
            - tier: \(decision.tier) · counted: \(decision.counted.map(\.id).joined(separator: ", "))
            - alternatives: \(decision.alternatives.map(\.id).joined(separator: ", "))
            - chosen: \(entry.workflowID ?? "—") (chain: \(entry.workflowChain?.joined(separator: " → ") ?? "—"))
            - chip index chosen: \(entry.trace.chipIndexChosen.map(String.init) ?? "—") · hint: \(entry.hint ?? "—")

            """
        }

        if let assembled = entry.assembled {
            out += """

            ## Prompt (\(assembled.totalTokensEstimated) tokens estimated)
            - slots: \(assembled.slots.map { "\($0.id.rawValue)=\($0.tokensEstimated)\($0.truncated ? "(trimmed)" : "")" }.joined(separator: " · "))

            ### System prompt
            ```
            \(assembled.systemPrompt)
            ```

            ### User message
            ```
            \(assembled.userMessage)
            ```

            """
        }

        if let output = entry.output {
            out += """

            ## Model output (\(entry.trace.providerType ?? "?") / \(entry.trace.modelID ?? "?"))
            ```
            \(output)
            ```

            """
        }

        if let verdict = entry.verdict {
            out += """

            ## Verifier
            - passed: \(verdict.passed) (\(String(format: "%.1f", verdict.elapsedMs)) ms)
            - warnings: \(verdict.warnings.isEmpty ? "none" : verdict.warnings.map { "\($0.check.rawValue): \($0.messageKey) \($0.messageArgs)" }.joined(separator: "; "))

            """
        }

        if let errorDescription = entry.errorDescription {
            out += """

            ## Error
            ```
            \(errorDescription)
            ```

            """
        }

        return out
    }
}
