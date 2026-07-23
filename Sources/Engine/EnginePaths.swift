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

        /// Role→provider mapping stays beside providers.json: credentials and
        /// provider configuration remain where the app already keeps them.
        /// (The design doc's providers.yaml unification is a later milestone.)
        static let rolesFileURL = Constants.appSupportDirectory.appendingPathComponent("roles.json")

        static func ensureDirectoriesExist() {
            for url in [rootDirectory, coreDirectory, workflowsDirectory,
                        workflowsDirectory.appendingPathComponent("base"), logsDirectory] {
                try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            }
        }
    }
}
