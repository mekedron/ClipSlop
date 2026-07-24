import Foundation
import Testing
@testable import ClipSlop

@Suite("Trace stats aggregation")
struct TraceStatsTests {
    /// Builds a minimal trace by decoding a JSON literal — the same path
    /// `TraceStats.load` uses, so field-name drift breaks these tests too.
    private func trace(
        situation: String = "base/com.apple.TextEdit/draft",
        presentation: String = "silent",
        chipIndex: Int? = nil,
        outcome: String = "inserted",
        warmHit: Bool = false,
        axErrors: Int = 0,
        totalMs: Int = 2_000,
        generateMs: Int = 1_500
    ) -> PressTrace {
        var json: [String: Any] = [
            "ts": "2026-07-23T10:00:00Z",
            "traceID": UUID().uuidString,
            "situationClass": situation,
            "grammarRow": "draft",
            "fieldState": "draft",
            "tier": "base",
            "candidateIDs": ["continue.draft"],
            "presentation": presentation,
            "hintUsed": false,
            "slotTokens": [:],
            "totalTokens": 0,
            "verifierChecks": [],
            "warmHit": warmHit,
            "axErrors": axErrors,
            "latencyMs": ["snapshot": 100, "route": 1, "assemble": 5,
                          "generate": generateMs, "verify": 2,
                          "paste": totalMs, "total": totalMs + 9_999],
            "outcome": outcome,
        ]
        if let chipIndex { json["chipIndexChosen"] = chipIndex }
        let data = try! JSONSerialization.data(withJSONObject: json)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try! decoder.decode(PressTrace.self, from: data)
    }

    @Test func countsAndRates() {
        let stats = TraceStats.compute(from: [
            trace(outcome: "inserted"),
            trace(outcome: "inserted:unconfirmed"),
            trace(outcome: "undone"),
            trace(outcome: "insertedAnyway"),
            trace(outcome: "dead:secure"),
            trace(presentation: "chips", chipIndex: 0, outcome: "inserted"),
            trace(presentation: "chips", chipIndex: 2, outcome: "inserted"),
            trace(presentation: "chips_forced", chipIndex: nil, outcome: "dismissed"),
        ])
        let b = stats.overall
        #expect(b.presses == 8)
        #expect(b.silent == 5)
        #expect(b.chips == 3)
        #expect(b.chipChosen == 2)
        #expect(b.chipTop1 == 1)
        #expect(b.top1Rate == 0.5)
        // inserted ×2 + undone + insertedAnyway + 2 chip inserts = 6 insertions.
        #expect(b.insertions == 6)
        #expect(b.undone == 1)
        #expect(b.insertedAnyway == 1)
    }

    @Test func outcomeFamiliesCollapseAfterTwoComponents() {
        let stats = TraceStats.compute(from: [
            trace(outcome: "error:generation:networkError"),
            trace(outcome: "error:generation:timeout"),
            trace(outcome: "dead:no_target"),
        ])
        #expect(stats.overall.outcomes["error:generation"] == 2)
        #expect(stats.overall.outcomes["dead:no_target"] == 1)
    }

    @Test func latencyPercentilesExcludeNonGeneratingPresses() {
        var traces = (1...20).map { trace(totalMs: $0 * 100, generateMs: $0 * 50) }
        // A dead press never generated — must not drag percentiles down.
        traces.append(trace(outcome: "dead:secure", totalMs: 5, generateMs: 0))
        let b = TraceStats.compute(from: traces).overall
        #expect(b.totalLatenciesMs.count == 20)
        #expect(b.p50TotalMs == 1_000)   // nearest-rank: 10th of 20
        #expect(b.p95TotalMs == 1_900)   // 19th of 20
    }

    @Test func missingPasteLatencyFallsBackToStageSum() throws {
        // Pre-paste-field trace line: no "paste" key → SLO latency is the
        // sum of pipeline stages (100+1+5+generate+2).
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var json = try JSONSerialization.jsonObject(
            with: encoder.encode(trace(generateMs: 1_000))
        ) as! [String: Any]
        var latency = json["latencyMs"] as! [String: Any]
        latency.removeValue(forKey: "paste")
        json["latencyMs"] = latency
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let old = try decoder.decode(
            PressTrace.self, from: JSONSerialization.data(withJSONObject: json)
        )
        let b = TraceStats.compute(from: [old]).overall
        #expect(b.totalLatenciesMs == [1_108])
    }

    @Test func percentileEdgeCases() {
        #expect(TraceStats.Bucket.percentile([], 0.5) == nil)
        #expect(TraceStats.Bucket.percentile([7], 0.5) == 7)
        #expect(TraceStats.Bucket.percentile([7], 0.95) == 7)
        #expect(TraceStats.Bucket.percentile([1, 2], 0.5) == 1)
    }

    @Test func situationBucketsSortByPressCount() {
        let stats = TraceStats.compute(from: [
            trace(situation: "rare"),
            trace(situation: "common"), trace(situation: "common"),
        ])
        #expect(stats.bySituation.map(\.situationClass) == ["common", "rare"])
        #expect(stats.bySituation[0].bucket.presses == 2)
    }

    @Test func warmAndAXErrorMetrics() {
        let b = TraceStats.compute(from: [
            trace(warmHit: true, axErrors: 3),
            trace(warmHit: false, axErrors: 0),
        ]).overall
        #expect(b.warmHits == 1)
        #expect(b.warmHitRate == 0.5)
        #expect(b.axErrors == 3)
        #expect(b.pressesWithAXErrors == 1)
    }

    @Test func markdownRendersWithoutCrashOnEmptyAndFull() {
        let empty = TraceStats.compute(from: [], skippedLines: 4)
        #expect(empty.markdown().contains("0 presses"))
        #expect(empty.markdown().contains("4 lines skipped"))

        let full = TraceStats.compute(from: [
            trace(presentation: "chips", chipIndex: 0, outcome: "inserted", totalMs: 2_500),
        ])
        let md = full.markdown()
        #expect(md.contains("## Per situation class"))
        #expect(md.contains("✓"))   // 2500 ≤ 3000 SLO
    }

    @Test func loadDecodesJSONLAndCountsSkipped() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("trace-stats-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let good = String(decoding: try encoder.encode(trace()), as: UTF8.self)
        let content = good + "\n" + #"{"not": "a trace"}"# + "\n" + good + "\n"
        try content.write(
            to: dir.appendingPathComponent("traces-2026-07-23.jsonl"),
            atomically: true, encoding: .utf8
        )

        let stats = TraceStats.load(from: dir)
        #expect(stats.overall.presses == 2)
        #expect(stats.skippedLines == 1)
    }
}
