import Foundation

enum CLIToolDetector {
    struct DetectionResult: Sendable {
        let definition: CLIToolDefinition
        let binaryPath: String
    }

    /// Common directories where CLI tools are installed but may not be in the app's inherited PATH.
    private static let extraSearchPaths: [String] = [
        "/usr/local/bin",
        "/opt/homebrew/bin",
        "\(NSHomeDirectory())/.local/bin",
        "\(NSHomeDirectory())/.cargo/bin",
        "/usr/bin",
    ]

    /// Returns all known CLI tools that are currently installed on the system.
    static func detectAll() -> [DetectionResult] {
        CLIToolDefinition.knownTools.compactMap { definition in
            guard let path = resolvePath(for: definition) else { return nil }
            return DetectionResult(definition: definition, binaryPath: path)
        }
    }

    /// Resolves the absolute path for a CLI tool definition, or nil if not found.
    static func resolvePath(for definition: CLIToolDefinition) -> String? {
        let searchDirs = buildSearchDirs()
        for binaryName in definition.binaryNames {
            for dir in searchDirs {
                let candidate = (dir as NSString).appendingPathComponent(binaryName)
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }
        return nil
    }

    /// Checks whether a binary is still available at the given path.
    static func isAvailable(at path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }

    // MARK: - Private

    private static func buildSearchDirs() -> [String] {
        var dirs: [String] = []

        // Directories from the process environment PATH
        if let envPath = ProcessInfo.processInfo.environment["PATH"] {
            dirs.append(contentsOf: envPath.split(separator: ":").map(String.init))
        }

        // Append common extra directories that may not be in the launchd-inherited PATH
        for extra in extraSearchPaths where !dirs.contains(extra) {
            dirs.append(extra)
        }

        return dirs
    }
}
