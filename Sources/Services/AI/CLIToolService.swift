import Foundation
import os

/// Idle-timeout watchdog for a streamed CLI run.
///
/// `process(text:…)` races the whole subprocess against `timeout(for:)`, but a
/// stream cannot be capped the same way: a healthy long generation legitimately
/// outlives any total-duration limit. What has to be caught is a tool that
/// produces nothing and never exits — before this, `stream` had no timeout at
/// all and a hung CLI hung the caller forever.
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

    func start(timeout: Duration, onTimeout: @escaping @Sendable () -> Void) {
        let state = self.state
        Task.detached {
            while true {
                let (last, finished) = state.withLock { ($0.lastActivity, $0.finished) }
                if finished { return }
                let idle = last.duration(to: .now)
                guard idle < timeout else {
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
                }
                do { try await Task.sleep(for: timeout - idle) } catch { return }
            }
        }
    }
}

struct CLIToolService: AIService {
    /// Used only when the resolved provider carries no timeout of its own.
    private static let defaultTimeoutSeconds: TimeInterval = 120

    /// The role's `timeout_seconds` when one is bound, the 120 s default
    /// otherwise. `EngineRoleStore.resolve` and `PrivacyBinding` both stamp
    /// `requestTimeout` on the provider they hand back; the three HTTP services
    /// apply it as `URLRequest.timeoutInterval`, and this raced a hard-coded
    /// constant instead — so a 15 s role timeout had no effect whatsoever on
    /// CLI-backed generation.
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
            group.addTask { [timeout = Self.timeout(for: config)] in
                try await Task.sleep(for: timeout)
                throw AIServiceError.cliToolTimeout
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    func stream(text: String, systemPrompt: String, config: AIProviderConfig) -> AsyncThrowingStream<String, Error> {
        let timeout = Self.timeout(for: config)
        return AsyncThrowingStream { continuation in
            let watchdog = StreamWatchdog()
            let task = Task {
                do {
                    let (binaryPath, definition) = try resolveToolInfo(config: config)

                    // Streaming always reads stdout directly (no output file).
                    let arguments = definition.buildArguments(text, systemPrompt, nil)

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

                    continuation.onTermination = { @Sendable _ in
                        watchdog.stop()
                        if process.isRunning { process.terminate() }
                    }

                    // Finish before terminating: killing the process fires
                    // `terminationHandler` with a non-zero status, and the
                    // first `finish` wins — the caller must see the timeout,
                    // not a spurious `cliToolFailed(SIGTERM)`.
                    watchdog.start(timeout: timeout) { @Sendable in
                        continuation.finish(throwing: AIServiceError.cliToolTimeout)
                        if process.isRunning { process.terminate() }
                    }
                } catch {
                    watchdog.stop()
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
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

    private func runProcess(binaryPath: String, arguments: [String], outputFile: URL?) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
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
                continuation.resume(throwing: AIServiceError.cliToolNotFound(binaryPath))
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
