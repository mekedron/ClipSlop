import Foundation

/// One generation's spend, in tokens (§14). No dollar pricing — model price
/// tables churn; tokens per role/day is the accounting unit. Contentless.
struct SpendRecord: Codable, Sendable {
    var ts: Date
    /// EngineRole raw value ("generation.magic").
    var role: String
    var provider: String
    var model: String
    var inputTokens: Int
    var outputTokens: Int
    /// True when the API reported no usage and the counts are chars/4
    /// estimates.
    var estimated: Bool
}

/// Appends one JSON line per generation to
/// `~/.clipslop/logs/spend-YYYY-MM.jsonl` — same shape and lifecycle as
/// `EngineTraceLogger`, monthly files instead of daily.
actor SpendLedger {
    private let directory: URL

    init(directory: URL = Constants.Engine.logsDirectory) {
        self.directory = directory
    }

    func append(_ record: SpendRecord) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(record) else { return }

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("spend-\(Self.monthStamp(for: record.ts)).jsonl")
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data + Data("\n".utf8))
        } else {
            try? (data + Data("\n".utf8)).write(to: url)
        }
    }

    nonisolated static func load(from directory: URL) -> [SpendRecord] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var records: [SpendRecord] = []
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("spend-") && $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for file in files {
            guard let content = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in content.split(separator: "\n") where !line.isEmpty {
                if let record = try? decoder.decode(SpendRecord.self, from: Data(line.utf8)) {
                    records.append(record)
                }
            }
        }
        return records
    }

    // MARK: - Aggregation (for the routing UI's inline spend)

    struct RoleTotals: Sendable, Equatable {
        var todayInput = 0
        var todayOutput = 0
        var monthInput = 0
        var monthOutput = 0
        var anyEstimated = false
    }

    nonisolated static func totals(
        records: [SpendRecord],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [String: RoleTotals] {
        var result: [String: RoleTotals] = [:]
        for record in records {
            var totals = result[record.role] ?? RoleTotals()
            if calendar.isDate(record.ts, equalTo: now, toGranularity: .month) {
                totals.monthInput += record.inputTokens
                totals.monthOutput += record.outputTokens
                if calendar.isDate(record.ts, inSameDayAs: now) {
                    totals.todayInput += record.inputTokens
                    totals.todayOutput += record.outputTokens
                }
                totals.anyEstimated = totals.anyEstimated || record.estimated
            }
            result[record.role] = totals
        }
        return result
    }

    private static func monthStamp(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }
}
