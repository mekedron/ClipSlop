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

    /// The load-bearing property — an idle timer, not a total-duration cap —
    /// asserted against explicit idle values rather than by sleeping. The
    /// sleeping version of this test asserted that its own `Task.sleep` was
    /// punctual and failed on CI, where a late pet looks exactly like a stalled
    /// tool.
    @Test(arguments: [
        // (idle, expected remaining sleep) — a fresh chunk buys a full window,
        // and a partial wait resumes for only what is left of it.
        (Duration.zero, Duration.milliseconds(100)),
        (.milliseconds(1), .milliseconds(99)),
        (.milliseconds(60), .milliseconds(40)),
        (.milliseconds(99), .milliseconds(1)),
    ])
    func idleBelowTheTimeoutWaitsOutTheRemainder(_ idle: Duration, _ remaining: Duration) {
        #expect(
            StreamWatchdog.step(idle: idle, timeout: Self.timeout, finished: false)
                == .wait(remaining)
        )
    }

    @Test(arguments: [Duration.milliseconds(100), .milliseconds(101), .seconds(30)])
    func idleAtOrBeyondTheTimeoutFires(_ idle: Duration) {
        #expect(StreamWatchdog.step(idle: idle, timeout: Self.timeout, finished: false) == .fire)
    }

    /// `finished` outranks a blown deadline: the process exiting normally must
    /// not be reported as a timeout just because the loop woke up late.
    @Test(arguments: [Duration.zero, .milliseconds(100), .seconds(30)])
    func finishedAlwaysStopsRegardlessOfIdle(_ idle: Duration) {
        #expect(StreamWatchdog.step(idle: idle, timeout: Self.timeout, finished: true) == .stop)
    }

    /// End-to-end counterpart to the cases above: activity really does reset the
    /// live timer. Deliberately generous — a 1 s window petted every 100 ms —
    /// so it tolerates a ~900 ms scheduling hiccup per chunk while total
    /// elapsed (~1.5 s) still exceeds the window a duration cap would enforce.
    @Test func steadyOutputNeverTimesOut() async throws {
        let fired = Counter()
        let watchdog = StreamWatchdog()
        watchdog.start(timeout: .seconds(1)) { fired.increment() }

        for _ in 0..<15 {
            try await Task.sleep(for: .milliseconds(100))
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
        for _ in 0..<10 {
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
