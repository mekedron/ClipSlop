import Foundation
import os

/// Idle-timeout watchdog for a streamed CLI run.
///
/// `process(text:…)` races the whole subprocess against `timeout(for:)`, but a
/// stream cannot be capped the same way: a healthy long generation legitimately
/// outlives any total-duration limit. What has to be caught is a tool that
/// produces nothing and never exits, which with no timeout at all hangs the
/// caller forever.
///
/// So this measures *silence*, and every chunk resets it. That is also exactly
/// what `URLRequest.timeoutInterval` means for the three HTTP streaming
/// services, which consume the same `requestTimeout` value — so one role
/// timeout now means the same thing on both transports.
///
/// One task for the whole run rather than one per chunk: it sleeps the
/// remaining slice, wakes, and re-reads the stamp, so a fast stream costs a
/// lock acquisition per chunk and nothing else. `ContinuousClock` so that a
/// wall-clock adjustment cannot make a live stream look stalled.
final class StreamWatchdog: Sendable {
    private struct State {
        var lastActivity: ContinuousClock.Instant
        var finished = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State(lastActivity: .now))

    /// Called from the readability handler's queue on every chunk.
    func noteActivity() {
        state.withLock { $0.lastActivity = .now }
    }

    /// Idempotent, and safe to call from the termination handler, from
    /// `onTermination`, and from the timeout path itself.
    func stop() {
        state.withLock { $0.finished = true }
    }

    /// One turn of the loop below.
    enum Step: Equatable {
        case stop
        case fire
        /// Sleep the rest of the window, then look again — a chunk that lands
        /// meanwhile moves the stamp forward and buys another full window.
        case wait(Duration)
    }

    /// The decision, pulled out of the loop so reset-on-activity can be tested
    /// against explicit idle values instead of against the scheduler. Sleeping
    /// for real made the test assert that its own `Task.sleep` was punctual,
    /// which on a loaded CI runner it is not — a late pet is indistinguishable
    /// from a stalled tool, and the watchdog was right to fire.
    static func step(idle: Duration, timeout: Duration, finished: Bool) -> Step {
        if finished { return .stop }
        return idle < timeout ? .wait(timeout - idle) : .fire
    }

    func start(timeout: Duration, onTimeout: @escaping @Sendable () -> Void) {
        let state = self.state
        Task.detached {
            while true {
                let (last, finished) = state.withLock { ($0.lastActivity, $0.finished) }
                switch Self.step(idle: last.duration(to: .now), timeout: timeout, finished: finished) {
                case .stop:
                    return
                case .fire:
                    // Claim the timeout under the lock: the process can exit
                    // between the read above and here, and a stream that
                    // already finished must not be handed a timeout error.
                    let won = state.withLock { s -> Bool in
                        guard !s.finished else { return false }
                        s.finished = true
                        return true
                    }
                    if won { onTimeout() }
                    return
                case .wait(let remaining):
                    do { try await Task.sleep(for: remaining) } catch { return }
                }
            }
        }
    }
}

struct CLIToolService: AIService {
    /// Used only when the resolved provider carries no timeout of its own.
    private static let defaultTimeoutSeconds: TimeInterval = 120

    /// The role's `timeout_seconds` when one is bound, the 120 s default
    /// otherwise. `EngineRoleStore.resolve` and `PrivacyBinding` both stamp
    /// `requestTimeout` on the provider they hand back and the three HTTP
    /// services apply it as `URLRequest.timeoutInterval`, so honouring it here
    /// too is what makes one role timeout mean the same thing on both
    /// transports rather than silently doing nothing on CLI-backed generation.
    private static func timeout(for config: AIProviderConfig) -> Duration {
        .seconds(config.requestTimeout ?? defaultTimeoutSeconds)
    }

    func process(text: String, systemPrompt: String, config: AIProviderConfig) async throws -> String {
        let (binaryPath, definition) = try resolveToolInfo(config: config)

        // For tools that dump logs to stdout, capture the final answer via a temp file.
        let outputFile: URL? = definition.usesOutputFile
            ? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
            : nil

        let arguments = definition.buildArguments(text, systemPrompt, outputFile?.path)

        defer { if let outputFile { try? FileManager.default.removeItem(at: outputFile) } }

        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await runProcess(binaryPath: binaryPath, arguments: arguments, outputFile: outputFile)
            }
            // Throwing out of the group cancels the subprocess child and waits
            // for it, so the timeout is only worth as much as that child's
            // cancellation handling — see `runProcess`, which terminates the
            // tool and resumes rather than sitting on a continuation forever.
            group.addTask { [timeout = Self.timeout(for: config)] in
                try await Task.sleep(for: timeout)
                throw AIServiceError.cliToolTimeout
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    /// One consumer, one subprocess — and exactly ONE `onTermination` handler,
    /// doing all three teardown steps.
    ///
    /// `continuation.onTermination` is a single property, so a second
    /// assignment silently discards the first and *which* one lands last is up
    /// to the scheduler. Split the teardown across two writes — stop the
    /// watchdog and kill the child from inside the `Task`, cancel the task from
    /// the synchronous builder body — and one half is always lost: either the
    /// tool is never terminated and a CLI nobody is reading keeps running while
    /// its readability handler yields into a dead continuation, or the task is
    /// never cancelled.
    ///
    /// Neither half is optional. `MagicPressPipeline`'s hard `budget.ms` cap
    /// abandons the stream and relies on exactly this handler to take the CLI
    /// down with it — an invariant nothing else enforces. So the handler is
    /// installed once, after the task exists and therefore deterministically
    /// last. The process it has to signal does not exist at that point (the task
    /// creates it), so it arrives through `StreamRun` — the same "who owns the
    /// child" handoff `runProcess` uses.
    func stream(text: String, systemPrompt: String, config: AIProviderConfig) -> AsyncThrowingStream<String, Error> {
        let timeout = Self.timeout(for: config)
        return AsyncThrowingStream { continuation in
            let watchdog = StreamWatchdog()
            let run = StreamRun()
            let task = Task {
                do {
                    let (binaryPath, definition) = try resolveToolInfo(config: config)

                    // Streaming always reads stdout directly (no output file).
                    let arguments = definition.buildArguments(text, systemPrompt, nil)

                    // Nothing in this task suspends before `process.run()`, so
                    // `task.cancel()` alone cannot stop the launch: a consumer
                    // that walks away while the task is still queued would get
                    // its CLI spawned anyway. The holder is where that early
                    // cancellation is recorded. Ask before building a single
                    // pipe, so this path has nothing to unwind.
                    guard run.canLaunch() else {
                        watchdog.stop()
                        continuation.finish(throwing: CancellationError())
                        return
                    }

                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: binaryPath)
                    process.arguments = arguments
                    process.environment = buildEnvironment()
                    process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())

                    let stdoutPipe = Pipe()
                    let stderrPipe = Pipe()
                    process.standardOutput = stdoutPipe
                    process.standardError = stderrPipe

                    let stdoutHandle = stdoutPipe.fileHandleForReading
                    stdoutHandle.readabilityHandler = { handle in
                        let data = handle.availableData
                        guard !data.isEmpty else {
                            stdoutHandle.readabilityHandler = nil
                            return
                        }
                        watchdog.noteActivity()
                        if let chunk = String(data: data, encoding: .utf8) {
                            continuation.yield(chunk)
                        }
                    }

                    process.terminationHandler = { proc in
                        stdoutHandle.readabilityHandler = nil
                        watchdog.stop()

                        // Never read a pipe belonging to a process we killed
                        // ourselves. A non-zero status after cancellation is
                        // our own SIGTERM rather than a tool diagnostic, and
                        // the stream is already terminal, so the `stderr` below
                        // would be assembled for nobody — while the read itself
                        // is the trap `runProcess` documents: a grandchild that
                        // inherited the write end (claude and codex both spawn
                        // helpers) holds it open after we killed its parent,
                        // and this Foundation thread then blocks on it
                        // indefinitely. That was hard to hit while the
                        // duplicate `onTermination` assignment meant nothing
                        // ever terminated the child on cancellation; now that
                        // one handler reliably does, every cancelled generation
                        // would strand a thread here.
                        guard !run.isCancelled else {
                            continuation.finish()
                            return
                        }

                        if proc.terminationStatus != 0 {
                            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                            let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                            continuation.finish(
                                throwing: AIServiceError.cliToolFailed(
                                    exitCode: proc.terminationStatus,
                                    stderr: String(stderr.prefix(500))
                                )
                            )
                        } else {
                            continuation.finish()
                        }
                    }

                    try process.run()

                    // Publish the live child so the termination handler below
                    // has something to signal — and pick up a cancellation that
                    // landed while we were launching, which went looking for a
                    // process and found none. Whichever side loses this race is
                    // the side that owns the killing, so it happens exactly
                    // once and never not at all.
                    guard run.attach(process) else {
                        Self.terminate(process)
                        watchdog.stop()
                        continuation.finish(throwing: CancellationError())
                        return
                    }

                    // Finish before terminating: killing the process fires
                    // `terminationHandler` with a non-zero status, and the
                    // first `finish` wins — the caller must see the timeout,
                    // not a spurious `cliToolFailed(SIGTERM)`. That ordering
                    // survives the handler below running re-entrantly from
                    // inside this `finish`: the stream is already terminal by
                    // then, so the kill it performs cannot beat the timeout
                    // error to the caller either. The `terminate` here is kept
                    // (idempotent, `isRunning`-guarded) so the deadline holds
                    // even if the stream was somehow terminated beforehand and
                    // this callback is the only thing still running.
                    //
                    // The timeout kill is ours exactly as much as the
                    // cancellation kill is, so claim the run before signalling:
                    // that is what tells `terminationHandler` not to block on a
                    // stderr pipe for a `cliToolTimeout` the caller has already
                    // been handed. Claiming explicitly rather than relying on
                    // `finish` to re-enter `onTermination` first — the flag
                    // must be set before the SIGTERM whatever the stream
                    // implementation does with handler re-entrancy. `cancel`
                    // hands the child over once and may well return nil here
                    // because `onTermination` got it; `process` is captured, so
                    // the kill does not depend on that.
                    watchdog.start(timeout: timeout) { @Sendable in
                        continuation.finish(throwing: AIServiceError.cliToolTimeout)
                        _ = run.cancel()
                        Self.terminate(process)
                    }
                } catch {
                    watchdog.stop()
                    continuation.finish(throwing: error)
                }
            }

            // The one and only assignment, and the reason the task above is
            // bound to a `let` first: this closure needs `task`, so it cannot
            // be installed any earlier, and nothing may install one later.
            //
            // Runs on every exit — consumer cancellation *and* our own
            // `finish` — so all three steps are idempotent by construction:
            // `stop` latches a flag, `terminate` no-ops on a process that has
            // already exited, and cancelling a finished task does nothing.
            // Order is not load-bearing for correctness, only for latency:
            // `cancel()` flips the holder's flag first, which is what a task
            // still mid-launch reads in its `canLaunch` guard.
            continuation.onTermination = { @Sendable _ in
                watchdog.stop()
                if let process = run.cancel() { Self.terminate(process) }
                task.cancel()
            }
        }
    }

    // MARK: - Private

    private func resolveToolInfo(config: AIProviderConfig) throws -> (String, CLIToolDefinition) {
        guard let definition = CLIToolDefinition.find(byID: config.modelID) else {
            throw AIServiceError.cliToolNotFound(config.modelID)
        }

        // Check stored path first
        if CLIToolDetector.isAvailable(at: config.baseURL) {
            return (config.baseURL, definition)
        }

        // Re-detect in case the binary moved (e.g. Homebrew upgrade)
        if let newPath = CLIToolDetector.resolvePath(for: definition) {
            return (newPath, definition)
        }

        throw AIServiceError.cliToolNotFound(definition.displayName)
    }

    /// Runs the tool to completion — and, crucially, observes cancellation.
    ///
    /// `process(text:…)` races this against `Self.timeout(for:)` in a task
    /// group, and leaving a group does not abandon the losing child: it cancels
    /// it and then *awaits* it. A bare `withCheckedThrowingContinuation`
    /// notices nothing, so the group sat there while a hung CLI kept the
    /// continuation suspended — forever, for a tool that never exits. The
    /// `cliToolTimeout` the timeout task had already thrown never reached the
    /// caller, and cancelling a Magic run left the subprocess running behind
    /// it. Cancellation now terminates the process and resumes the continuation
    /// itself, so the group can return the moment the timeout fires.
    private func runProcess(binaryPath: String, arguments: [String], outputFile: URL?) async throws -> String {
        let run = ProcessRun()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                // Cancelled before the body even ran — the group cancels the
                // loser the instant the timeout task throws. Spawn nothing.
                guard run.begin(continuation) else {
                    run.fail(CancellationError())
                    return
                }

                let process = Process()
                process.executableURL = URL(fileURLWithPath: binaryPath)
                process.arguments = arguments
                process.environment = buildEnvironment()
                process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                process.terminationHandler = { proc in
                    // Claim the resume BEFORE touching a pipe. On the
                    // cancellation path the continuation is already gone, and
                    // `readDataToEndOfFile` there is a liability rather than a
                    // courtesy: a grandchild that inherited the write end holds
                    // it open after we killed its parent, and this handler runs
                    // on a Foundation thread that would then block on it
                    // indefinitely for output nobody is waiting for.
                    guard let continuation = run.claim() else { return }

                    guard proc.terminationStatus == 0 else {
                        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                        continuation.resume(
                            throwing: AIServiceError.cliToolFailed(
                                exitCode: proc.terminationStatus,
                                stderr: String(stderr.prefix(500))
                            )
                        )
                        return
                    }

                    // If an output file was used, read the final answer from it.
                    let output: String
                    if let outputFile,
                       let fileContent = try? String(contentsOf: outputFile, encoding: .utf8),
                       !fileContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        output = fileContent.trimmingCharacters(in: .whitespacesAndNewlines)
                    } else {
                        // Otherwise read stdout directly.
                        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                        output = (String(data: stdoutData, encoding: .utf8) ?? "")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                    }

                    guard !output.isEmpty else {
                        continuation.resume(throwing: AIServiceError.emptyResponse)
                        return
                    }

                    continuation.resume(returning: output)
                }

                do {
                    try process.run()
                } catch {
                    run.fail(AIServiceError.cliToolNotFound(binaryPath))
                    return
                }

                // Publish the live process so `onCancel` has something to
                // signal — and pick up the cancellation that landed while we
                // were launching, which looked and found nothing.
                if !run.attach(process) {
                    Self.terminate(process)
                    run.fail(CancellationError())
                }
            }
        } onCancel: {
            if let process = run.cancel() { Self.terminate(process) }
            run.fail(CancellationError())
        }
    }

    /// SIGTERM now, SIGKILL if the tool is still around a moment later. The
    /// whole point of the timeout is that nothing outlives it, and a CLI that
    /// traps SIGTERM (or sits wedged in a syscall) would otherwise keep burning
    /// tokens and CPU for a request that has already failed.
    private static let terminationGrace: TimeInterval = 2

    private static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + terminationGrace) {
            // Foundation reaps the child before it flips `isRunning`, so the
            // pid here is still ours — this cannot land on a recycled one.
            guard process.isRunning else { return }
            kill(process.processIdentifier, SIGKILL)
        }
    }

    /// One `runProcess` call's shared state: the continuation, resumable
    /// exactly once, and the process cancellation has to signal.
    /// `Process.terminationHandler` and `withTaskCancellationHandler`'s
    /// `onCancel` both arrive on threads of their own choosing and either may
    /// win, so "who resumes" and "is there anything to kill yet" are single
    /// decisions taken under one lock — the same shape `ChatGPTAuthService`
    /// uses for its listener callbacks.
    private final class ProcessRun: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<String, Error>?
        private var process: Process?
        private var isCancelled = false

        /// Adopts the continuation. `false` means cancellation got here first.
        func begin(_ continuation: CheckedContinuation<String, Error>) -> Bool {
            lock.withLock { () -> Bool in
                self.continuation = continuation
                return !isCancelled
            }
        }

        /// Takes the continuation, or nil when somebody else already has it.
        /// Losing this race means doing nothing whatsoever.
        func claim() -> CheckedContinuation<String, Error>? {
            lock.withLock { () -> CheckedContinuation<String, Error>? in
                defer { continuation = nil }
                return continuation
            }
        }

        func fail(_ error: Error) {
            claim()?.resume(throwing: error)
        }

        /// Publishes the launched process. `false` means cancellation already
        /// ran and found nothing, so the launching side owns terminating it.
        func attach(_ process: Process) -> Bool {
            lock.withLock { () -> Bool in
                guard !isCancelled else { return false }
                self.process = process
                return true
            }
        }

        /// Marks the run cancelled and hands back a process to signal, if one
        /// was launched.
        func cancel() -> Process? {
            lock.withLock { () -> Process? in
                isCancelled = true
                defer { process = nil }
                return process
            }
        }
    }

    /// `stream`'s half of the same problem `ProcessRun` solves, and solved the
    /// same way: the subprocess is created inside a `Task`, while
    /// `continuation.onTermination` is installed synchronously and may fire the
    /// instant the consumer walks away — quite possibly before that task has
    /// reached `process.run()`. Both sides arrive on threads of their own
    /// choosing and either may win, so "may this still launch" and "is there a
    /// live child to signal, and who owns it" are single decisions taken under
    /// one lock.
    ///
    /// Deliberately a sibling of `ProcessRun` rather than a reuse of it: a
    /// stream continuation may be finished any number of times (later `finish`
    /// calls are no-ops), so there is no resume-exactly-once arbitration to
    /// share — only the process handoff. Folding the two together would mean
    /// splitting `ProcessRun`'s single lock across a continuation half and a
    /// process half, and its `begin`/`cancel` pair depends on those being one
    /// atomic decision or a cancellation slipping between them strands the
    /// caller on an unresumed continuation.
    ///
    /// Internal rather than private only so `StreamRunTests` can pin the
    /// handoff without spawning a real subprocess: the invariant it protects —
    /// exactly one side terminates the child — is the kind that fails silently
    /// in production and is trivially checkable here.
    final class StreamRun: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false

        /// Was this run torn down from our side? A plain non-blocking read,
        /// separate from `cancel()` because the two do different jobs: `cancel`
        /// hands the child over exactly once, while this is asked repeatedly
        /// and from places that must not consume anything — chiefly
        /// `terminationHandler`, which uses it to tell "the tool failed" from
        /// "we sent the SIGTERM ourselves" and so decide whether reading stderr
        /// is diagnostics or a trap.
        var isCancelled: Bool {
            lock.withLock { () -> Bool in cancelled }
        }

        /// `false` when cancellation already landed: spawn nothing at all.
        func canLaunch() -> Bool { !isCancelled }

        /// Publishes the launched process. `false` means cancellation already
        /// ran and found nothing, so the launching side owns terminating it.
        func attach(_ process: Process) -> Bool {
            lock.withLock { () -> Bool in
                guard !cancelled else { return false }
                self.process = process
                return true
            }
        }

        /// Marks the run cancelled and hands back a process to signal, if one
        /// was launched. Hands it back once — the caller becomes its owner.
        func cancel() -> Process? {
            lock.withLock { () -> Process? in
                cancelled = true
                defer { process = nil }
                return process
            }
        }
    }

    private func buildEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extraPaths = ["/usr/local/bin", "/opt/homebrew/bin", "\(NSHomeDirectory())/.local/bin"]
        let currentPath = env["PATH"] ?? "/usr/bin:/bin"
        let missing = extraPaths.filter { !currentPath.contains($0) }
        if !missing.isEmpty {
            env["PATH"] = (missing + [currentPath]).joined(separator: ":")
        }
        return env
    }
}
