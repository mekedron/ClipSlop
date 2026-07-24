import Foundation

extension Constants {
    /// File layout of the context engine. Unlike the app's JSON stores this
    /// tree is a user-facing, hand-editable wiki (design doc §15: "files
    /// first"), so it lives in the home directory rather than Application
    /// Support. Dev builds get their own tree for the same reason
    /// `appSupportDirectory` is scoped: a dev launch must never overwrite the
    /// real library.
    enum Engine {
        static let rootDirectory: URL = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(Constants.isDevBuild ? ".clipslop-dev" : ".clipslop")

        static let coreDirectory = rootDirectory.appendingPathComponent("core")
        static let workflowsDirectory = rootDirectory.appendingPathComponent("workflows")
        static let logsDirectory = rootDirectory.appendingPathComponent("logs")

        /// Provider list as a hand-editable engine file (§14). API keys stay
        /// in Keychain (referenced by id), OAuth state stays app-internal —
        /// only configuration lives here.
        static let providersFileURL = rootDirectory.appendingPathComponent("providers.yaml")

        /// Role→provider mapping with fallback chains (§14). Successor of
        /// the App Support roles.json (migrated on first launch).
        static let rolesYamlURL = rootDirectory.appendingPathComponent("roles.yaml")

        /// Legacy locations, read once for migration.
        static let legacyRolesFileURL = Constants.appSupportDirectory.appendingPathComponent("roles.json")
        static let legacyProvidersFileURL = Constants.providersFileURL

        static func ensureDirectoriesExist() {
            for url in [rootDirectory, coreDirectory, workflowsDirectory,
                        workflowsDirectory.appendingPathComponent("base"), logsDirectory] {
                try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            }
        }
    }
}
