import Foundation
import Testing
@testable import ClipSlop

@Suite("Press trace")
struct PressTraceTests {
    @Test func roundTripsThroughCodable() throws {
        let snapshot = MagicTestSupport.makeSnapshot(url: "https://www.linkedin.com/feed/")
        let decision = try MagicTestSupport.seedRoute(snapshot)
        var trace = PressTrace(snapshot: snapshot, decision: decision, classification: nil)
        trace.outcome = "inserted"
        trace.chipIndexChosen = 1

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(trace)
        let decoded = try decoder.decode(PressTrace.self, from: data)
        #expect(decoded.situationClass == trace.situationClass)
        #expect(decoded.outcome == "inserted")
        #expect(decoded.chipIndexChosen == 1)
        #expect(decoded.urlHost == "linkedin.com")
    }

    /// The contentless invariant (§17): a trace built from a snapshot full of
    /// sentinel content must not leak any of it — no field text, no
    /// selection, no surrounding content, no window title, no URL path.
    @Test func tracesAreContentless() throws {
        let sentinels = [
            "SENTINEL-FIELD-VALUE", "SENTINEL-SELECTION", "SENTINEL-SURROUNDING",
            "SENTINEL-TITLE", "SENTINEL-AUTHOR", "SENTINEL-PLACEHOLDER", "SENTINEL-URL-PATH",
        ]
        let snapshot = MagicTestSupport.makeSnapshot(
            windowTitle: "SENTINEL-TITLE",
            url: "https://www.linkedin.com/feed/SENTINEL-URL-PATH",
            value: "SENTINEL-FIELD-VALUE with SENTINEL-SELECTION inside",
            selection: .init(range: nil, text: "SENTINEL-SELECTION"),
            placeholder: "SENTINEL-PLACEHOLDER",
            surroundingContent: "SENTINEL-SURROUNDING",
            surroundingAuthor: "SENTINEL-AUTHOR"
        )
        let classification = SelectionClassifier.classify("SENTINEL-SELECTION")
        let decision = try MagicTestSupport.seedRoute(snapshot, classification: classification)
        var trace = PressTrace(snapshot: snapshot, decision: decision, classification: classification)
        trace.outcome = "inserted"

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = String(decoding: try encoder.encode(trace), as: UTF8.self)

        for sentinel in sentinels {
            #expect(!json.contains(sentinel), "trace leaked \(sentinel)")
        }
        // The host survives; the bundle id is intentionally kept.
        #expect(json.contains("linkedin.com"))
    }
}

@Suite("Trace logger")
struct EngineTraceLoggerTests {
    @Test func appendsJSONLinesAndPrunes() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipslop-trace-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let logger = EngineTraceLogger(directory: directory, keepDays: 30)
        let snapshot = MagicTestSupport.makeSnapshot()
        var trace = PressTrace(snapshot: snapshot, decision: nil, classification: nil)
        trace.outcome = "inserted"
        // The factory snapshot carries a fixed 2025 timestamp; date the trace
        // today so the prune pass below doesn't collect the file under test.
        trace.ts = Date()

        await logger.append(trace)
        await logger.append(trace)

        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(files.count == 1)
        let lines = try String(contentsOf: files[0], encoding: .utf8)
            .split(separator: "\n").filter { !$0.isEmpty }
        #expect(lines.count == 2)

        // A file dated far in the past gets pruned.
        let oldFile = directory.appendingPathComponent("traces-2020-01-01.jsonl")
        try Data("{}\n".utf8).write(to: oldFile)
        await logger.pruneOldLogs()
        #expect(!FileManager.default.fileExists(atPath: oldFile.path))
        #expect(FileManager.default.fileExists(atPath: files[0].path))
    }
}
