import Foundation
import os

/// Immutable snapshot of the loaded workflow set, safe to hand to the
/// off-main pipeline.
struct WorkflowCatalog: Sendable {
    let workflows: [ResolvedWorkflow]
    let loadedAt: Date

    static let empty = WorkflowCatalog(workflows: [], loadedAt: .distantPast)

    func workflow(id: String) -> ResolvedWorkflow? {
        workflows.first { $0.id == id }
    }
}

/// Loads `~/.clipslop/workflows/**.md` into a validated catalog.
///
/// Hot-reload is reload-on-press: every `reloadIfChanged()` stats the
/// directory (sub-millisecond for a dozen small files) and re-parses only
/// when a file's mtime or the file set changed. This satisfies "external
/// edits are live on the next press" without a file-watcher subsystem.
@MainActor
@Observable
final class WorkflowStore {
    private(set) var catalog: WorkflowCatalog = .empty
    private(set) var loadErrors: [WorkflowLoadError] = []

    @ObservationIgnored private var directorySignature: [String: Date] = [:]
    private static let logger = Logger(subsystem: Constants.bundleIdentifier, category: "engine.workflows")

    init() {
        reloadIfChanged()
    }

    func reloadIfChanged() {
        let signature = Self.signature(of: Constants.Engine.workflowsDirectory)
        guard signature != directorySignature || catalog.loadedAt == .distantPast else { return }
        directorySignature = signature

        let (loaded, errors) = Self.load(from: Constants.Engine.workflowsDirectory)
        catalog = loaded
        loadErrors = errors
        for error in errors {
            let location = [error.fileURL?.lastPathComponent, error.line.map { "line \($0)" }]
                .compactMap { $0 }.joined(separator: ":")
            if error.isWarning {
                Self.logger.warning("workflow \(location, privacy: .public): \(error.message, privacy: .public)")
            } else {
                Self.logger.error("workflow disabled \(location, privacy: .public): \(error.message, privacy: .public)")
            }
        }
    }

    // MARK: - Pure loading

    nonisolated static func load(from directory: URL) -> (WorkflowCatalog, [WorkflowLoadError]) {
        var raws: [RawWorkflow] = []
        var errors: [WorkflowLoadError] = []

        for fileURL in markdownFiles(in: directory) {
            guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
                errors.append(WorkflowLoadError(fileURL: fileURL, workflowID: nil, message: "could not read file"))
                continue
            }
            do {
                let document = try FrontmatterParser.parse(text)
                let (card, explicitKeys, warnings) = try WorkflowCardParser.make(from: document)
                for warning in warnings {
                    errors.append(WorkflowLoadError(
                        fileURL: fileURL, workflowID: card.id, message: warning, isWarning: true
                    ))
                }
                raws.append(RawWorkflow(card: card, explicitKeys: explicitKeys, body: document.body, fileURL: fileURL))
            } catch let error as FrontmatterError {
                errors.append(WorkflowLoadError(
                    fileURL: fileURL, workflowID: nil, line: error.line, message: error.message
                ))
            } catch {
                errors.append(WorkflowLoadError(
                    fileURL: fileURL, workflowID: nil, message: error.localizedDescription
                ))
            }
        }

        let (resolved, resolveErrors) = WorkflowResolver.resolve(raws)
        errors.append(contentsOf: resolveErrors)
        return (WorkflowCatalog(workflows: resolved, loadedAt: Date()), errors)
    }

    nonisolated static func markdownFiles(in directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [URL] = []
        // `_folder.md` files are the library tree's per-directory metadata
        // (§7.3 — folder name/mnemonic/order), not workflow cards.
        for case let url as URL in enumerator
        where url.pathExtension == "md" && url.lastPathComponent != PromptLibraryFiles.folderFileName {
            files.append(url)
        }
        return files.sorted { $0.path < $1.path }
    }

    private nonisolated static func signature(of directory: URL) -> [String: Date] {
        var signature: [String: Date] = [:]
        for url in markdownFiles(in: directory) {
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            signature[url.path] = mtime
        }
        return signature
    }
}
