import Foundation
import Testing
@testable import ClipSlop

/// The opt-in full-content log is the exact inverse of `PressTrace`: where the
/// always-on trace is contentless by construction, every file here holds the
/// user's draft, their screen, and other people's messages verbatim. Its
/// protection is therefore filesystem permissions and nothing else, which makes
/// the mode bits a real invariant rather than housekeeping.
@Suite("Magic debug logger")
struct MagicDebugLoggerTests {
    private func makeEntry(output: String = "generated") -> MagicDebugEntry {
        let snapshot = MagicTestSupport.makeSnapshot(
            value: "the user's private draft",
            surroundingContent: "someone else's message"
        )
        var trace = PressTrace(snapshot: snapshot, decision: nil, classification: nil)
        trace.outcome = "inserted"
        return MagicDebugEntry(
            trace: trace, snapshot: snapshot, classification: nil, decision: nil,
            workflowID: nil, workflowChain: nil, hint: nil, assembled: nil,
            output: output, verdict: nil, errorDescription: nil
        )
    }

    private func mode(of path: String) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
    }

    /// 0600 on the file, 0700 on the directory. The engine tree lives in a home
    /// directory shared with every process running as this user, so the default
    /// 0644 publishes the press to all of them.
    @Test func writesArePrivateToTheUser() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clipslop-debuglog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let logger = MagicDebugLogger(directory: root, keepDays: 7)
        await logger.write(makeEntry())

        let files = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        )
        #expect(files.count == 1)
        let file = try #require(files.first)
        #expect(try mode(of: file.path) == 0o600)
        #expect(try mode(of: root.path) == 0o700)
    }

    /// A directory that already exists keeps whatever mode it was created with,
    /// so `createDirectory(attributes:)` alone is not enough — a tree seeded by
    /// an earlier build, or by the user's own `mkdir`, would stay world-readable
    /// forever.
    @Test func anExistingWorldReadableDirectoryIsTightened() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clipslop-debuglog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )

        await MagicDebugLogger(directory: root, keepDays: 7).write(makeEntry())
        #expect(try mode(of: root.path) == 0o700)
    }

    /// The header of every file promises a 7-day life. ClipSlop is a menu-bar
    /// accessory that stays up for weeks, so the prune has to be reachable from
    /// the write path — a launch-only prune keeps that promise for nobody who
    /// never quits.
    @Test func prunesFilesPastTheKeepWindow() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clipslop-debuglog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let stale = root.appendingPathComponent("press-old.md")
        try "old".write(to: stale, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -8 * 86400)],
            ofItemAtPath: stale.path
        )

        await MagicDebugLogger(directory: root, keepDays: 7).pruneOldLogs()
        #expect(!FileManager.default.fileExists(atPath: stale.path))
    }

    /// A press on a secure field never reaches the value read, so the snapshot
    /// it logs carries an empty one — the render must not invent a section that
    /// suggests otherwise, and must say the field was secure.
    @Test func aSecureFieldRendersNoValue() {
        let snapshot = MagicTestSupport.makeSnapshot(
            role: "AXSecureTextField", editable: false, secure: true, value: ""
        )
        var trace = PressTrace(snapshot: snapshot, decision: nil, classification: nil)
        trace.outcome = "dead:secure"
        let rendered = MagicDebugLogger.render(MagicDebugEntry(
            trace: trace, snapshot: snapshot, classification: nil, decision: nil,
            workflowID: nil, workflowChain: nil, hint: nil, assembled: nil,
            output: nil, verdict: nil, errorDescription: nil
        ))
        #expect(rendered.contains("secure=true"))
        #expect(rendered.contains("### Field value (0 chars)"))
    }
}
