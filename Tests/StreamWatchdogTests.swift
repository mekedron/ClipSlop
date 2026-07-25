import Foundation
import Testing
import os
@testable import ClipSlop

/// `CLIToolService.stream` had no timeout at all: a CLI that printed nothing and
/// never exited hung the caller forever, and the role's `timeout_seconds` — which
/// the non-streaming path and all three HTTP services honour — did not apply.
/// The watchdog is an *idle* timer rather than a total-duration cap, so these
/// tests pin both halves of that: silence trips it, throughput does not.
@Suite("CLI stream watchdog")
struct StreamWatchdogTests {
    /// Timings are deliberately coarse (a 4× margin over the timeout) so the
    /// suite stays honest on a loaded machine without sleeping for long.
    private static let timeout = Duration.milliseconds(100)

    private final class Counter: Sendable {
        private let value = OSAllocatedUnfairLock(initialState: 0)
        func increment() { value.withLock { $0 += 1 } }
        var count: Int { value.withLock { $0 } }
    }

    @Test func firesOnceAfterSilence() async throws {
        let fired = Counter()
        let watchdog = StreamWatchdog()
        watchdog.start(timeout: Self.timeout) { fired.increment() }

        try await Task.sleep(for: .milliseconds(400))
        // Exactly once: the loop returns after claiming the timeout, so a
        // long-dead stream must not spew repeat errors at the continuation.
        #expect(fired.count == 1)
    }

    @Test func steadyOutputNeverTimesOut() async throws {
        let fired = Counter()
        let watchdog = StreamWatchdog()
        watchdog.start(timeout: Self.timeout) { fired.increment() }

        // 10 chunks at 40 ms — total elapsed (400 ms) is 4× the timeout, but no
        // single gap reaches it. A total-duration cap would have killed this.
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(40))
            watchdog.noteActivity()
        }
        #expect(fired.count == 0)

        watchdog.stop()
    }

    @Test func silenceAfterOutputStillFires() async throws {
        let fired = Counter()
        let watchdog = StreamWatchdog()
        watchdog.start(timeout: Self.timeout) { fired.increment() }

        // A tool that emits a preamble and then wedges is the real hang.
        try await Task.sleep(for: .milliseconds(40))
        watchdog.noteActivity()
        try await Task.sleep(for: .milliseconds(400))
        #expect(fired.count == 1)
    }

    @Test func stopBeforeTheDeadlineDisarmsIt() async throws {
        let fired = Counter()
        let watchdog = StreamWatchdog()
        watchdog.start(timeout: Self.timeout) { fired.increment() }
        watchdog.stop()

        try await Task.sleep(for: .milliseconds(400))
        #expect(fired.count == 0)
    }

    /// The process exiting normally races the deadline. `stop()` and the timeout
    /// claim share one lock precisely so a stream that already finished can
    /// never be handed a `cliToolTimeout` afterwards.
    @Test func stopRightAtTheDeadlineIsExclusive() async throws {
        for _ in 0..<20 {
            let fired = Counter()
            let watchdog = StreamWatchdog()
            watchdog.start(timeout: .milliseconds(20)) { fired.increment() }
            try await Task.sleep(for: .milliseconds(20))
            watchdog.stop()
            try await Task.sleep(for: .milliseconds(60))
            // Whoever won, the callback ran at most once and never after stop
            // reported the run finished.
            #expect(fired.count <= 1)
        }
    }
}
