import Foundation

/// Pure trace debugging for the Settings Assistant: load, filter, and
/// explain contentless press traces so the model can answer "why did my
/// press do X" from evidence instead of speculation. Everything here is
/// `nonisolated` and side-effect free (loading reads files it is given) —
/// tests drive it with synthetic traces and temp directories.
enum TraceInspector {

    // MARK: - Loading

    /// Decodes every `traces-*.jsonl` in `directory`, newest first.
    /// Undecodable lines (pre-M1 schema) are counted, never silently dropped
    /// — the same contract as `TraceStats.load`.
    nonisolated static func loadTraces(from directory: URL) -> (traces: [PressTrace], skipped: Int) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var traces: [PressTrace] = []
        var skipped = 0

        let files = ((try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("traces-") && $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        for file in files {
            guard let content = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in content.split(separator: "\n") where !line.isEmpty {
                if let trace = try? decoder.decode(PressTrace.self, from: Data(line.utf8)) {
                    traces.append(trace)
                } else {
                    skipped += 1
                }
            }
        }
        traces.sort { $0.ts > $1.ts }
        return (traces, skipped)
    }

    // MARK: - Filtering (read_traces)

    struct Filter: Sendable {
        var app: String?
        var outcomePrefix: String?
        var presentation: String?
        var situationContains: String?
        var verifierFailed: Bool?
        var limit: Int = 20

        static let none = Filter()
    }

    nonisolated static func filter(_ traces: [PressTrace], _ filter: Filter) -> [PressTrace] {
        var result = traces
        if let app = filter.app?.lowercased(), !app.isEmpty {
            result = result.filter { $0.appBundleID?.lowercased().contains(app) == true }
        }
        if let prefix = filter.outcomePrefix, !prefix.isEmpty {
            result = result.filter { $0.outcome.hasPrefix(prefix) }
        }
        if let presentation = filter.presentation, !presentation.isEmpty {
            result = result.filter { $0.presentation == presentation }
        }
        if let situation = filter.situationContains?.lowercased(), !situation.isEmpty {
            result = result.filter { $0.situationClass.lowercased().contains(situation) }
        }
        if let failed = filter.verifierFailed {
            result = result.filter { $0.verifierPassed == !failed }
        }
        return Array(result.prefix(max(1, min(filter.limit, 200))))
    }

    // MARK: - Explanation (explain_press)

    /// Finds a trace by traceID prefix (case-insensitive); nil id → newest.
    nonisolated static func find(_ idPrefix: String?, in traces: [PressTrace]) -> PressTrace? {
        guard let idPrefix, !idPrefix.isEmpty else { return traces.first }
        let needle = idPrefix.lowercased()
        return traces.first { $0.traceID.uuidString.lowercased().hasPrefix(needle) }
    }

    /// Renders one trace as a human-readable story. Everything stated here
    /// is derived from trace fields — the explanation can never contain
    /// content, because the trace can't.
    nonisolated static func explain(_ trace: PressTrace) -> String {
        var out = "# Press \(trace.traceID.uuidString.prefix(8)) — \(iso(trace.ts))\n\n"

        // Situation.
        out += "## Situation\n"
        out += "- App: \(trace.appBundleID ?? "unknown")"
        if let host = trace.urlHost { out += " · \(host)" }
        out += "\n- Grammar row: \(trace.grammarRow) (field state: \(trace.fieldState))\n"
        if let cls = trace.selectionClass {
            out += "- Selection classified as **\(cls)**"
            if trace.selectionWasTie == true {
                out += " — but the classification was a tie, which forces chips"
            }
            out += "\n"
        }
        out += "- Situation class: \(trace.situationClass)\n"
        if trace.warmHit {
            out += "- Warm observer had fresh context (URL/title backfill available)\n"
        }
        if trace.axErrors > 0 {
            out += "- ⚠︎ \(trace.axErrors) accessibility errors (kAXErrorCannotComplete) during capture — the snapshot may be partial\n"
        }

        // Routing.
        out += "\n## Routing\n"
        out += "- Tier: **\(trace.tier)** (exact ≻ domain ≻ base — candidates counted at the highest matching tier)\n"
        out += "- Counted candidates: \(trace.candidateIDs.isEmpty ? "none" : trace.candidateIDs.joined(separator: ", "))\n"
        switch trace.presentation {
        case "silent":
            out += "- Ran **silently**: exactly one counted candidate and no classifier tie\n"
        case "chips":
            out += "- Showed **chips**: "
            if trace.selectionWasTie == true {
                out += "the selection classification tied"
            } else if trace.candidateIDs.count > 1 {
                out += "\(trace.candidateIDs.count) candidates matched at the same tier"
            } else {
                out += "the decision was ambiguous"
            }
            out += "\n"
        case "chips_forced":
            out += "- Showed **chips** because the user pressed the always-show-chips shortcut\n"
        default:
            out += "- Presentation: \(trace.presentation)\n"
        }
        if let chosen = trace.chosenID {
            out += "- Chosen workflow: **\(chosen)**"
            if let index = trace.chipIndexChosen {
                out += " (chip #\(index + 1)\(index == 0 ? ", the top-ranked one" : ""))"
            }
            out += "\n"
        }
        if trace.hintUsed {
            out += "- The user typed a free-text hint\n"
        }

        // Generation.
        if let providerType = trace.providerType {
            out += "\n## Generation\n"
            out += "- Provider: \(providerType)"
            if let model = trace.modelID, !model.isEmpty { out += " · \(model)" }
            out += "\n"
            if !trace.slotTokens.isEmpty {
                let slots = trace.slotTokens.sorted { $0.key < $1.key }
                    .map { "\($0.key) \($0.value)" }.joined(separator: ", ")
                out += "- Prompt slots (estimated tokens): \(slots) — total \(trace.totalTokens)\n"
            }
        }

        // Verifier.
        if let passed = trace.verifierPassed {
            out += "\n## Verifier\n"
            if passed {
                out += "- Passed all deterministic checks\n"
            } else {
                out += "- **Flagged** — the output was shown in the toast instead of auto-inserting:\n"
                for check in trace.verifierChecks {
                    out += "  - `\(check)`: \(checkMeaning(check))\n"
                }
            }
        }

        // Latency.
        let l = trace.latencyMs
        out += "\n## Latency\n"
        out += "- snapshot \(l.snapshot) ms · route \(l.route) ms · assemble \(l.assemble) ms · generate \(l.generate) ms · verify \(l.verify) ms\n"
        if let paste = l.paste {
            let verdict = paste <= TraceStats.sloP50Ms
                ? "within the p50 SLO (\(TraceStats.sloP50Ms) ms)"
                : (paste <= TraceStats.sloP95Ms
                    ? "over the p50 SLO (\(TraceStats.sloP50Ms) ms) but within p95 (\(TraceStats.sloP95Ms) ms)"
                    : "over the p95 SLO (\(TraceStats.sloP95Ms) ms)")
            out += "- Press → paste: **\(paste) ms** — \(verdict)\n"
        }

        // Outcome.
        out += "\n## Outcome\n"
        out += "- `\(trace.outcome)` — \(outcomeMeaning(trace.outcome))\n"
        return out
    }

    /// Verifier check ids → what they mean (mirrors `DeterministicVerifier`).
    nonisolated static func checkMeaning(_ check: String) -> String {
        switch check {
        case "language":
            "the output's language matched neither the surroundings nor the user's own draft"
        case "length":
            "longer than the workflow's output.max_chars (or the config default when the card sets none)"
        case "constraints":
            "matched a 'never say' / 'never match' rule in core/constraints.md"
        case "concreteness":
            "contains concrete data (numbers, names, dates…) that does not occur in the gathered context"
        case "actionableUngrounded":
            "contains actionable data (money, IBAN, email, phone, commitment dates) grounded only by untrusted screen content"
        default:
            "unrecognized check id"
        }
    }

    /// Outcome strings → what they mean (mirrors the press band's vocabulary).
    nonisolated static func outcomeMeaning(_ outcome: String) -> String {
        let unconfirmed = outcome.hasSuffix(":unconfirmed")
        let base = unconfirmed
            ? String(outcome.dropLast(":unconfirmed".count))
            : outcome
        var meaning: String
        switch base {
        case "inserted":
            meaning = "the text was pasted into the field"
        case "insertedAnyway":
            meaning = "the verifier flagged the output but the user held Insert Anyway"
        case "panelOnly":
            meaning = "the result went to the toast/clipboard only, never into the field"
        case "focusMismatch":
            meaning = "focus changed between press and paste — the engine never blind-pastes, so the result went to the toast + clipboard instead"
        case "regenerated":
            meaning = "the user asked for a regeneration (the previous insert was undone first)"
        case "cancelled":
            meaning = "the user cancelled the press (✕ on the toast)"
        case "copied":
            meaning = "the user copied the result instead of inserting"
        case "dismissed":
            meaning = "the chip panel or toast was dismissed without acting"
        case "undone":
            meaning = "the user undid the insertion"
        case "unknown":
            meaning = "the press ended without a stamped outcome"
        default:
            if base.hasPrefix("dead:") {
                let reason = String(base.dropFirst("dead:".count))
                meaning = "the press was dead on arrival (\(reason)) — e.g. a secure field, no focused field, or a non-editable target"
            } else if base.hasPrefix("error:generation:") {
                let kind = String(base.dropFirst("error:generation:".count))
                switch kind {
                case "noCloud":
                    meaning = "the surface is on the no_cloud list and no local provider was available — the engine refused rather than sending content to the cloud (P7)"
                case "downgradeRefused":
                    meaning = "no provider in the chain met the role's min_cost_class — the engine refused rather than silently downgrading (P9)"
                default:
                    meaning = "generation failed (\(kind)) — nothing was inserted"
                }
            } else if base.hasPrefix("error:") {
                meaning = "the press failed (\(String(base.dropFirst("error:".count))))"
            } else {
                meaning = "unrecognized outcome"
            }
        }
        if unconfirmed {
            meaning += "; the paste could not be confirmed by re-reading the field's value (some fields, like Mail's web area, are unreadable)"
        }
        return meaning
    }

    private nonisolated static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
