import Foundation

/// Pure aggregation over decoded press traces (§17) — the gate instrument
/// for M1/M2: latency SLO percentiles (direct: p50 ≤ 3 s, p95 ≤ 6 s), chip
/// top-1 rate (≥ 70% target), warm-observer hit rate, and the R4
/// `axErrors` count all come from here. File loading lives in
/// `load(from:)`; `compute(from:)` is pure so tests drive it with synthetic
/// traces.
struct TraceStats: Sendable {
    static let sloP50Ms = 3_000
    static let sloP95Ms = 6_000
    static let top1Target = 0.7

    struct Bucket: Sendable {
        var presses = 0
        var silent = 0
        /// Chip presentations (forced, planner-resolved, or plain).
        var chips = 0
        /// Chip presentations the fast-mode planner resolved without
        /// showing the panel (presentation "chips_planner").
        var plannerPicked = 0
        /// Chip presentations where the user picked a chip at all.
        var chipChosen = 0
        /// …where the picked chip was the top-ranked one (index 0).
        var chipTop1 = 0
        var hintUsed = 0
        /// Outcome family (first two `:`-separated components) → count.
        var outcomes: [String: Int] = [:]
        /// Presses whose text landed in the field at some point: final
        /// outcome inserted*, insertedAnyway*, undone, or regenerated.
        var insertions = 0
        var insertedAnyway = 0
        var undone = 0
        var warmHits = 0
        var axErrors = 0
        /// Presses that saw at least one `kAXErrorCannotComplete`.
        var pressesWithAXErrors = 0
        /// Press→paste latencies (the §3.6 SLO number), only for presses
        /// that reached generation. Older lines without `paste` fall back
        /// to the sum of pipeline stages (excludes paste mechanics —
        /// slightly optimistic, flagged in the report).
        var totalLatenciesMs: [Int] = []
        var generateLatenciesMs: [Int] = []

        mutating func add(_ trace: PressTrace) {
            presses += 1
            if trace.presentation == "silent" {
                silent += 1
            } else {
                chips += 1
                if trace.presentation == "chips_planner" { plannerPicked += 1 }
                if let index = trace.chipIndexChosen {
                    chipChosen += 1
                    if index == 0 { chipTop1 += 1 }
                }
            }
            if trace.hintUsed { hintUsed += 1 }

            let family = trace.outcome.split(separator: ":").prefix(2).joined(separator: ":")
            outcomes[family, default: 0] += 1
            if trace.outcome.hasPrefix("insertedAnyway") { insertedAnyway += 1 }
            if trace.outcome.hasPrefix("inserted") || trace.outcome == "undone"
                || trace.outcome == "regenerated" {
                insertions += 1
            }
            if trace.outcome == "undone" { undone += 1 }

            if trace.warmHit { warmHits += 1 }
            axErrors += trace.axErrors
            if trace.axErrors > 0 { pressesWithAXErrors += 1 }

            if trace.latencyMs.generate > 0 {
                let l = trace.latencyMs
                totalLatenciesMs.append(
                    l.paste ?? (l.snapshot + l.route + l.assemble + l.generate + l.verify)
                )
                generateLatenciesMs.append(l.generate)
            }
        }

        // MARK: Derived rates (nil when the denominator is empty)

        var top1Rate: Double? { rate(chipTop1, over: chipChosen) }
        var silentRate: Double? { rate(silent, over: presses) }
        /// Of the presses that would have shown chips, how many the planner
        /// resolved silently.
        var plannerPickRate: Double? { rate(plannerPicked, over: chips) }
        var undoRate: Double? { rate(undone, over: insertions) }
        var insertAnywayRate: Double? { rate(insertedAnyway, over: insertions) }
        var warmHitRate: Double? { rate(warmHits, over: presses) }

        var p50TotalMs: Int? { Self.percentile(totalLatenciesMs, 0.5) }
        var p95TotalMs: Int? { Self.percentile(totalLatenciesMs, 0.95) }
        var p50GenerateMs: Int? { Self.percentile(generateLatenciesMs, 0.5) }
        var p95GenerateMs: Int? { Self.percentile(generateLatenciesMs, 0.95) }

        private func rate(_ numerator: Int, over denominator: Int) -> Double? {
            denominator > 0 ? Double(numerator) / Double(denominator) : nil
        }

        /// Nearest-rank percentile; nil for an empty sample.
        static func percentile(_ values: [Int], _ q: Double) -> Int? {
            guard !values.isEmpty else { return nil }
            let sorted = values.sorted()
            let rank = Int((q * Double(sorted.count)).rounded(.up))
            return sorted[max(0, min(rank - 1, sorted.count - 1))]
        }
    }

    var overall = Bucket()
    /// Sorted by press count, descending.
    var bySituation: [(situationClass: String, bucket: Bucket)] = []
    /// Lines that failed to decode (typically pre-M1 traces missing the
    /// warmHit/axErrors keys) — reported, never silently dropped.
    var skippedLines = 0

    static func compute(from traces: [PressTrace], skippedLines: Int = 0) -> TraceStats {
        var stats = TraceStats()
        stats.skippedLines = skippedLines
        var byClass: [String: Bucket] = [:]
        for trace in traces {
            stats.overall.add(trace)
            byClass[trace.situationClass, default: Bucket()].add(trace)
        }
        stats.bySituation = byClass
            .map { (situationClass: $0.key, bucket: $0.value) }
            .sorted {
                ($0.bucket.presses, $1.situationClass) > ($1.bucket.presses, $0.situationClass)
            }
        return stats
    }

    /// Reads every `traces-*.jsonl` in `directory`, decoding line by line.
    static func load(from directory: URL) -> TraceStats {
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
        return compute(from: traces, skippedLines: skipped)
    }

    // MARK: - Markdown report

    func markdown() -> String {
        var out = "# Magic trace stats — \(overall.presses) presses"
        if skippedLines > 0 {
            out += " (\(skippedLines) lines skipped: old schema)"
        }
        out += "\n\n## Overall\n\n"
        out += "| metric | value |\n|---|---|\n"
        out += "| presses | \(overall.presses) |\n"
        out += "| silent | \(fraction(overall.silent, overall.presses, overall.silentRate)) |\n"
        out += "| chip top-1 | \(fraction(overall.chipTop1, overall.chipChosen, overall.top1Rate))"
        if let rate = overall.top1Rate {
            out += rate >= Self.top1Target ? " ✓" : " ✗ (target ≥ 70%)"
        }
        out += " |\n"
        out += "| planner auto-pick | \(fraction(overall.plannerPicked, overall.chips, overall.plannerPickRate)) |\n"
        out += "| hint used | \(overall.hintUsed) |\n"
        out += "| undo | \(fraction(overall.undone, overall.insertions, overall.undoRate)) |\n"
        out += "| insert-anyway | \(fraction(overall.insertedAnyway, overall.insertions, overall.insertAnywayRate)) |\n"
        out += "| warm hits | \(fraction(overall.warmHits, overall.presses, overall.warmHitRate)) |\n"
        out += "| ax errors (R4) | \(overall.axErrors) across \(overall.pressesWithAXErrors) presses |\n"
        out += "| latency p50/p95 press→paste | \(slo(overall.p50TotalMs, Self.sloP50Ms)) / \(slo(overall.p95TotalMs, Self.sloP95Ms)) |\n"
        out += "| latency p50/p95 generate | \(ms(overall.p50GenerateMs)) / \(ms(overall.p95GenerateMs)) |\n"

        if !overall.outcomes.isEmpty {
            out += "\n## Outcomes\n\n| outcome | count |\n|---|---|\n"
            for (outcome, count) in overall.outcomes.sorted(by: { ($0.value, $1.key) > ($1.value, $0.key) }) {
                out += "| \(outcome) | \(count) |\n"
            }
        }

        if !bySituation.isEmpty {
            out += "\n## Per situation class\n\n"
            out += "| class | presses | silent | top-1 | undo | p50/p95 ms | warm | axErr |\n"
            out += "|---|---|---|---|---|---|---|---|\n"
            for (name, b) in bySituation {
                out += "| \(name) | \(b.presses) | \(percent(b.silentRate)) | "
                out += "\(percent(b.top1Rate)) | \(percent(b.undoRate)) | "
                out += "\(ms(b.p50TotalMs))/\(ms(b.p95TotalMs)) | "
                out += "\(percent(b.warmHitRate)) | \(b.axErrors) |\n"
            }
        }
        return out
    }

    private func fraction(_ numerator: Int, _ denominator: Int, _ rate: Double?) -> String {
        "\(numerator)/\(denominator) (\(percent(rate)))"
    }

    private func percent(_ rate: Double?) -> String {
        guard let rate else { return "—" }
        return "\(Int((rate * 100).rounded()))%"
    }

    private func ms(_ value: Int?) -> String {
        value.map { "\($0)" } ?? "—"
    }

    private func slo(_ value: Int?, _ limit: Int) -> String {
        guard let value else { return "—" }
        return "\(value) ms \(value <= limit ? "✓" : "✗ (SLO \(limit))")"
    }
}
