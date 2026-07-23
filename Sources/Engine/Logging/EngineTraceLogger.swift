import Foundation

/// Appends one JSON line per completed press to
/// `~/.clipslop/logs/traces-YYYY-MM-DD.jsonl`. An actor so file I/O stays off
/// the main actor; one write per press, no update-in-place — the press band
/// stamps the outcome before submitting.
actor EngineTraceLogger {
    private let directory: URL
    private let keepDays: Int

    init(directory: URL = Constants.Engine.logsDirectory, keepDays: Int = 30) {
        self.directory = directory
        self.keepDays = keepDays
    }

    func append(_ trace: PressTrace) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(trace) else { return }

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("traces-\(Self.dayStamp(for: trace.ts)).jsonl")

        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data + Data("\n".utf8))
        } else {
            try? (data + Data("\n".utf8)).write(to: url)
        }
    }

    /// Deletes trace files older than `keepDays`. Called once on launch.
    func pruneOldLogs(now: Date = Date()) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return }

        let cutoff = now.addingTimeInterval(-Double(keepDays) * 86400)
        let cutoffStamp = Self.dayStamp(for: cutoff)
        for file in files where file.lastPathComponent.hasPrefix("traces-") && file.pathExtension == "jsonl" {
            let stamp = file.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "traces-", with: "")
            if stamp < cutoffStamp {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    private static func dayStamp(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }
}
