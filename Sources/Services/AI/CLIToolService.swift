import Foundation

struct CLIToolService: AIService {
    private static let timeoutSeconds: UInt64 = 120

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
            group.addTask {
                try await Task.sleep(nanoseconds: Self.timeoutSeconds * 1_000_000_000)
                throw AIServiceError.cliToolTimeout
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    func stream(text: String, systemPrompt: String, config: AIProviderConfig) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
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
                        if let chunk = String(data: data, encoding: .utf8) {
                            continuation.yield(chunk)
                        }
                    }

                    process.terminationHandler = { proc in
                        stdoutHandle.readabilityHandler = nil

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
                        if process.isRunning { process.terminate() }
                    }
                } catch {
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
