import Foundation
import Testing
@testable import ClipSlop

@Suite("Trace inspector")
struct TraceInspectorTests {

    // MARK: - Fixtures

    /// One trace as a JSONL line — the same decode path `loadTraces` uses.
    /// Shared with `EngineToolExecutorTests` for its on-disk trace tests.
    static func traceJSON(
        id: String = UUID().uuidString,
        ts: String = "2026-07-21T10:00:00Z",
        app: String = "com.apple.TextEdit",
        situation: String = "base/com.apple.TextEdit/draft",
        tier: String = "base",
        candidates: [String] = ["continue.draft"],
        chosen: String? = "continue.draft",
        presentation: String = "silent",
        chipIndex: Int? = nil,
        selectionClass: String? = nil,
        selectionWasTie: Bool? = nil,
        verifierPassed: Bool? = true,
        verifierChecks: [String] = [],
        outcome: String = "inserted",
        pasteMs: Int? = 2_000
    ) -> String {
        var json: [String: Any] = [
            "ts": ts,
            "traceID": id,
            "situationClass": situation,
            "appBundleID": app,
            "grammarRow": "draft",
            "fieldState": "draft",
            "tier": tier,
            "candidateIDs": candidates,
            "presentation": presentation,
            "hintUsed": false,
            "slotTokens": ["pinned": 300, "field": 80],
            "totalTokens": 380,
            "providerType": "anthropic",
            "modelID": "claude-test",
            "verifierChecks": verifierChecks,
            "warmHit": false,
            "axErrors": 0,
            "latencyMs": [
                "snapshot": 120, "route": 1, "assemble": 4,
                "generate": 1_500, "verify": 3, "total": 9_000,
            ] as [String: Any],
            "outcome": outcome,
        ]
        if let chosen { json["chosenID"] = chosen }
        if let chipIndex { json["chipIndexChosen"] = chipIndex }
        if let selectionClass { json["selectionClass"] = selectionClass }
        if let selectionWasTie { json["selectionWasTie"] = selectionWasTie }
        if let verifierPassed { json["verifierPassed"] = verifierPassed }
        if let pasteMs {
            var latency = json["latencyMs"] as! [String: Any]
            latency["paste"] = pasteMs
            json["latencyMs"] = latency
        }
        let data = try! JSONSerialization.data(withJSONObject: json)
        return String(data: data, encoding: .utf8)!
    }

    private func trace(_ line: String) -> PressTrace {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try! decoder.decode(PressTrace.self, from: Data(line.utf8))
    }

    // MARK: - Loading

    @Test func loadsNewestFirstAndCountsBadLines() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("trace-inspector-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let old = Self.traceJSON(ts: "2026-07-19T08:00:00Z", app: "com.old")
        let new = Self.traceJSON(ts: "2026-07-21T08:00:00Z", app: "com.new")
        try (old + "\n" + "{not json}\n")
            .write(to: directory.appendingPathComponent("traces-2026-07-19.jsonl"), atomically: true, encoding: .utf8)
        try (new + "\n")
            .write(to: directory.appendingPathComponent("traces-2026-07-21.jsonl"), atomically: true, encoding: .utf8)

        let (traces, skipped) = TraceInspector.loadTraces(from: directory)
        #expect(traces.count == 2)
        #expect(skipped == 1)
        #expect(traces[0].appBundleID == "com.new")
        #expect(traces[1].appBundleID == "com.old")
    }

    // MARK: - Filtering

    @Test func filtersByAppOutcomePresentationAndVerifier() {
        let traces = [
            trace(Self.traceJSON(app: "com.apple.mail", outcome: "inserted")),
            trace(Self.traceJSON(app: "com.google.Chrome", outcome: "dead:secure")),
            trace(Self.traceJSON(
                app: "com.google.Chrome", presentation: "chips",
                verifierPassed: false, verifierChecks: ["length"], outcome: "insertedAnyway"
            )),
        ]

        var filter = TraceInspector.Filter()
        filter.app = "chrome"
        #expect(TraceInspector.filter(traces, filter).count == 2)

        filter = TraceInspector.Filter()
        filter.outcomePrefix = "dead"
        #expect(TraceInspector.filter(traces, filter).count == 1)

        filter = TraceInspector.Filter()
        filter.presentation = "chips"
        #expect(TraceInspector.filter(traces, filter).count == 1)

        filter = TraceInspector.Filter()
        filter.verifierFailed = true
        let failed = TraceInspector.filter(traces, filter)
        #expect(failed.count == 1)
        #expect(failed[0].verifierChecks == ["length"])

        filter = TraceInspector.Filter()
        filter.limit = 2
        #expect(TraceInspector.filter(traces, filter).count == 2)
    }

    @Test func findsByCaseInsensitiveIDPrefixAndDefaultsToNewest() {
        let a = trace(Self.traceJSON(id: "AAAAAAAA-1111-1111-1111-111111111111"))
        let b = trace(Self.traceJSON(id: "BBBBBBBB-2222-2222-2222-222222222222"))
        #expect(TraceInspector.find(nil, in: [a, b])?.traceID == a.traceID)
        #expect(TraceInspector.find("bbbb", in: [a, b])?.traceID == b.traceID)
        #expect(TraceInspector.find("cccc", in: [a, b]) == nil)
    }

    // MARK: - Explanation

    @Test func explainsASilentInsert() {
        let explanation = TraceInspector.explain(trace(Self.traceJSON()))
        #expect(explanation.contains("Ran **silently**"))
        #expect(explanation.contains("continue.draft"))
        #expect(explanation.contains("claude-test"))
        #expect(explanation.contains("within the p50 SLO"))
        #expect(explanation.contains("pasted into the field"))
    }

    @Test func explainsChipsFromAClassifierTie() {
        let explanation = TraceInspector.explain(trace(Self.traceJSON(
            candidates: ["instruct.selection", "rewrite.selection"],
            presentation: "chips", chipIndex: 1,
            selectionClass: "mixed", selectionWasTie: true,
            outcome: "inserted"
        )))
        #expect(explanation.contains("the selection classification tied"))
        #expect(explanation.contains("chip #2"))
    }

    @Test func explainsAVerifierFailureWithCheckMeanings() {
        let explanation = TraceInspector.explain(trace(Self.traceJSON(
            verifierPassed: false,
            verifierChecks: ["length", "actionableUngrounded"],
            outcome: "insertedAnyway:unconfirmed",
            pasteMs: 7_000
        )))
        #expect(explanation.contains("output.max_chars"))
        #expect(explanation.contains("untrusted screen content"))
        #expect(explanation.contains("held Insert Anyway"))
        #expect(explanation.contains("could not be confirmed"))
        #expect(explanation.contains("over the p95 SLO"))
    }

    // MARK: - Vocabulary

    @Test func outcomeMeaningsCoverTheEngineVocabulary() {
        #expect(TraceInspector.outcomeMeaning("dead:secure").contains("dead on arrival"))
        #expect(TraceInspector.outcomeMeaning("error:generation:noCloud").contains("no_cloud"))
        #expect(TraceInspector.outcomeMeaning("error:generation:downgradeRefused").contains("min_cost_class"))
        #expect(TraceInspector.outcomeMeaning("error:generation:timeout").contains("timeout"))
        #expect(TraceInspector.outcomeMeaning("focusMismatch").contains("never blind-pastes"))
        #expect(TraceInspector.outcomeMeaning("inserted:unconfirmed").contains("could not be confirmed"))
    }

    @Test func checkMeaningsCoverTheVerifierChecks() {
        for check in ["language", "length", "constraints", "concreteness", "actionableUngrounded"] {
            #expect(TraceInspector.checkMeaning(check) != "unrecognized check id")
        }
    }
}
