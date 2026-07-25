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

/// `CLIToolService.stream` assigned `continuation.onTermination` twice — once
/// inside its task and once outside it — and the second write silently dropped
/// the first, so whether the subprocess was terminated or the task was cancelled
/// came down to which one the scheduler let land last. The single handler that
/// replaced them reaches the child through `StreamRun`, because at the moment it
/// is installed the task has not created that child yet.
///
/// It carries a second decision too: whether the non-zero exit status that
/// comes back is the tool's own failure or the SIGTERM we just sent. Reading
/// the stderr pipe in the latter case is what `runProcess` warns about — a
/// grandchild holding the write end open blocks the Foundation thread doing the
/// read forever — so the flag has to be exact.
///
/// Nothing observable reports a breakage in either: a leaked CLI just keeps
/// burning tokens behind a stream nobody reads, a stranded thread just
/// accumulates, and `MagicPressPipeline`'s hard `budget.ms` cap silently stops
/// meaning anything. Hence tests on the handoff itself, which needs no
/// subprocess — `Process` instances are never launched below, only used as
/// identities to hand back and forth.
@Suite("CLI stream process handoff")
struct StreamRunTests {
    /// The ordinary path: the tool launched, then the consumer walked away.
    /// `onTermination` must be handed the child so it can signal it.
    @Test func cancelAfterAttachHandsBackTheProcess() {
        let run = CLIToolService.StreamRun()
        let process = Process()

        #expect(run.canLaunch())
        #expect(run.attach(process))
        #expect(run.cancel() === process)
    }

    /// Ownership transfers exactly once. A second claimant terminating the same
    /// process would be harmless today only because `terminate` is
    /// `isRunning`-guarded; the handoff must not lean on that.
    @Test func theProcessIsHandedBackOnlyOnce() {
        let run = CLIToolService.StreamRun()
        #expect(run.attach(Process()))

        _ = run.cancel()
        #expect(run.cancel() == nil)
    }

    /// Cancelled before the task got as far as spawning anything: no child is
    /// reported (there is none to kill) and the launch must be refused outright.
    /// Nothing in the task suspends before `process.run()`, so `Task.cancel()`
    /// would not have stopped it — this flag is what does.
    @Test func cancelBeforeLaunchRefusesToSpawn() {
        let run = CLIToolService.StreamRun()

        #expect(run.cancel() == nil)
        #expect(!run.canLaunch())
    }

    /// The race the holder exists for: cancellation lands while the task is
    /// between its `canLaunch` guard and `attach`. The child is live and nobody
    /// has published it, so `attach` must refuse and leave the launching side
    /// holding the obligation to kill it.
    @Test func attachAfterCancelIsRefusedSoTheLauncherKills() {
        let run = CLIToolService.StreamRun()
        #expect(run.cancel() == nil)

        #expect(!run.attach(Process()))
        // And the refusal is not remembered as a live child either — a later
        // termination pass must not be handed a process it did not launch.
        #expect(run.cancel() == nil)
    }

    /// The flag `terminationHandler` reads to tell a tool that failed from a
    /// tool we killed. It has to be readable over and over and consume nothing,
    /// which is why it is not `cancel()`: that hands the child over exactly
    /// once, and a `terminationHandler` calling it would swallow the very
    /// process `onTermination` still has to signal.
    @Test func cancellationIsReadableRepeatedlyAndConsumesNothing() {
        let run = CLIToolService.StreamRun()
        let process = Process()
        #expect(run.attach(process))
        #expect(!run.isCancelled)

        _ = run.cancel()

        #expect(run.isCancelled)
        #expect(run.isCancelled)
        #expect(!run.canLaunch())
    }

    /// A live run reads clean however often it is asked: a tool that exits
    /// non-zero on its own must still get its stderr read and reported as
    /// `cliToolFailed`, which is the whole diagnostic the guard must not eat.
    @Test func anUncancelledRunNeverReportsCancellation() {
        let run = CLIToolService.StreamRun()
        #expect(!run.isCancelled)
        #expect(run.attach(Process()))
        #expect(!run.isCancelled)
        #expect(run.canLaunch())
    }

    /// The launch-refused path kills the child itself, so it too must leave the
    /// run reading as cancelled — otherwise that SIGTERM comes back through
    /// `terminationHandler` as a tool failure and drags the stderr read with it.
    @Test func aRefusedAttachStillReadsAsCancelled() {
        let run = CLIToolService.StreamRun()
        _ = run.cancel()

        #expect(!run.attach(Process()))
        #expect(run.isCancelled)
    }

    /// Hammered from two threads, since that is how the two sides really
    /// arrive. Whatever the interleaving, exactly one of them ends up owning the
    /// child: `attach` succeeding means `cancel` gets it back, `attach` failing
    /// means the launcher kills it itself. Never both, never neither.
    @Test func exactlyOneSideOwnsTheChildUnderContention() async {
        for _ in 0..<200 {
            let run = CLIToolService.StreamRun()
            // The process is created and dropped inside the task that uses it,
            // so no non-Sendable value crosses between them.
            async let attached = Task.detached { run.attach(Process()) }.value
            async let handedBack = Task.detached { run.cancel() != nil }.value

            let (didAttach, didHandBack) = await (attached, handedBack)
            #expect(didAttach == didHandBack)
        }
    }
}
