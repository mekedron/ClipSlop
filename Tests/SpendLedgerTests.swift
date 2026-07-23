import Foundation
import Testing
@testable import ClipSlop

@Suite("Spend ledger")
struct SpendLedgerTests {
    private func record(
        daysAgo: Int, role: String = "generation.magic",
        input: Int = 100, output: Int = 50, estimated: Bool = false,
        now: Date
    ) -> SpendRecord {
        SpendRecord(
            ts: Calendar.current.date(byAdding: .day, value: -daysAgo, to: now)!,
            role: role, provider: "anthropic", model: "claude-sonnet-5",
            inputTokens: input, outputTokens: output, estimated: estimated
        )
    }

    @Test func totalsSplitTodayAndMonth() {
        // Mid-month noon anchor keeps day/month arithmetic unambiguous.
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 7, day: 15, hour: 12))!
        let totals = SpendLedger.totals(records: [
            record(daysAgo: 0, input: 100, output: 50, now: now),
            record(daysAgo: 0, input: 10, output: 5, estimated: true, now: now),
            record(daysAgo: 3, input: 1_000, output: 500, now: now),
            record(daysAgo: 60, input: 9_999, output: 9_999, now: now),   // out of month
            record(daysAgo: 0, role: "chat.assistant", input: 7, output: 3, now: now),
        ], now: now)

        let magic = totals["generation.magic"]
        #expect(magic?.todayInput == 110)
        #expect(magic?.todayOutput == 55)
        #expect(magic?.monthInput == 1_110)
        #expect(magic?.monthOutput == 555)
        #expect(magic?.anyEstimated == true)
        #expect(totals["chat.assistant"]?.todayInput == 7)
    }

    @Test func appendAndLoadRoundTrip() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("spend-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let ledger = SpendLedger(directory: dir)
        let now = Date()
        await ledger.append(record(daysAgo: 0, now: now))
        await ledger.append(record(daysAgo: 0, role: "chat.assistant", now: now))

        let loaded = SpendLedger.load(from: dir)
        #expect(loaded.count == 2)
        #expect(loaded.map(\.role).sorted() == ["chat.assistant", "generation.magic"])
    }
}
