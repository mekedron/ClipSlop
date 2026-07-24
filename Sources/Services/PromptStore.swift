import Foundation
import os

/// The prompt library, §7.3-unified: canonical storage is the markdown card
/// tree under `~/.clipslop/workflows/library/` (folders = subdirectories,
/// prompts = workflow cards, parsed by the same `FrontmatterParser` /
/// `WorkflowCardParser` the engine uses). This store is the facade that maps
/// that subtree onto the `PromptNode` tree API every consumer already speaks:
/// the popup UI, Quick Access tiles, App Intents/Spotlight, per-prompt
/// hotkeys (`prompt_quickPaste_<uuid>`), and the assistant's library tools.
///
/// `prompts.json` lives on as a **derived mirror**, regenerated after every
/// mutation: the existing `CloudSyncService` uploads it unchanged, and the
/// App Intents cold-launch path keeps reading it. It is never edited
/// independently — inbound remote data is decoded and written back into the
/// markdown tree (`replaceFromSync`).
@MainActor
@Observable
final class PromptStore {
    private(set) var prompts: [PromptNode] = []

    /// Called after every local save with the encoded mirror JSON.
    /// CloudSyncService hooks into this to upload changes.
    var onPromptsChanged: ((_ data: Data) -> Void)?

    /// True while applying a remote sync — suppresses onPromptsChanged to prevent echo loops.
    private var isSyncing = false

    @ObservationIgnored private let libraryDirectory: URL
    @ObservationIgnored private let mirrorFileURL: URL
    @ObservationIgnored private let bundledDefaults: () -> [PromptNode]
    @ObservationIgnored private let setDefaultsActive: ((Bool) -> Void)?
    @ObservationIgnored private var defaultsActive: Bool
    /// Mtime signature of the library tree — reload-on-demand, same pattern
    /// as `WorkflowStore`.
    @ObservationIgnored private var directorySignature: [String: Date] = [:]
    /// Relative paths of the files the current model owns. The diff sync
    /// only ever deletes paths from this set, so files it failed to parse
    /// (a hand-edit typo) are skipped, never destroyed.
    @ObservationIgnored private var knownPaths: Set<String> = []

    private static let logger = Logger(subsystem: Constants.bundleIdentifier, category: "prompts.library")

    convenience init() {
        self.init(
            libraryDirectory: Constants.Engine.workflowsDirectory.appendingPathComponent("library"),
            mirrorFileURL: Constants.promptsFileURL,
            useDefaultPrompts: AppSettings.shared.useDefaultPrompts,
            setDefaultsActive: { AppSettings.shared.useDefaultPrompts = $0 }
        )
    }

    /// Designated initializer with injectable locations so tests run against
    /// temp directories and never touch `~/.clipslop` or UserDefaults.
    init(
        libraryDirectory: URL,
        mirrorFileURL: URL,
        useDefaultPrompts: Bool,
        defaults: @escaping () -> [PromptNode] = PromptStore.loadBundledDefaults,
        setDefaultsActive: ((Bool) -> Void)? = nil
    ) {
        self.libraryDirectory = libraryDirectory
        self.mirrorFileURL = mirrorFileURL
        self.defaultsActive = useDefaultPrompts
        self.bundledDefaults = defaults
        self.setDefaultsActive = setDefaultsActive
        bootstrap()
    }

    // MARK: - Bootstrap & migration

    private func bootstrap() {
        let fm = FileManager.default

        guard fm.fileExists(atPath: libraryDirectory.path) else {
            // §7.3 migration, first launch without `workflows/library/`:
            // materialize the tree from prompts.json (or the bundled defaults
            // when defaults are active), keeping the original JSON as a
            // one-time backup.
            if fm.fileExists(atPath: mirrorFileURL.path) {
                let backupURL = URL(fileURLWithPath: mirrorFileURL.path + ".pre-unification.bak")
                if !fm.fileExists(atPath: backupURL.path) {
                    try? fm.copyItem(at: mirrorFileURL, to: backupURL)
                }
            }
            let source: [PromptNode]
            if defaultsActive {
                source = bundledDefaults()
            } else {
                source = Self.decodeMirror(at: mirrorFileURL) ?? bundledDefaults()
            }
            prompts = Self.canonicalize(source)
            persist()
            return
        }

        reload()

        if defaultsActive {
            // Same semantic as the old JSON store: while the user hasn't
            // customized, the latest bundled defaults are authoritative on
            // every launch (app updates refresh the default library).
            let defaults = Self.canonicalize(bundledDefaults())
            if defaults != prompts {
                prompts = defaults
                persist()
                return
            }
        }
        refreshMirrorIfStale()
    }

    /// Reloads the tree when any library file's mtime (or the file set)
    /// changed — external edits are live on next access, like workflows are
    /// live on the next press. Regenerates the mirror so iCloud and the
    /// hotkey registrations follow.
    func reloadIfChanged() {
        let signature = PromptLibraryFiles.signature(of: libraryDirectory)
        guard signature != directorySignature else { return }
        reload()
        writeMirrorAndNotify()
    }

    private func reload() {
        let result = PromptLibraryFiles.load(from: libraryDirectory)
        for issue in result.issues {
            Self.logger.error("library \(issue, privacy: .public)")
        }
        for write in result.pendingWrites {
            try? write.content.write(to: write.url, atomically: true, encoding: .utf8)
        }
        prompts = result.nodes
        knownPaths = result.parsedRelativePaths
        directorySignature = PromptLibraryFiles.signature(of: libraryDirectory)
    }

    // MARK: - Sync (iCloud mirror)

    /// Replace prompts from a remote iCloud sync. Writes the markdown tree
    /// (diffed by UUID-carrying file content) but does NOT fire
    /// onPromptsChanged, preventing an echo loop.
    func replaceFromSync(_ nodes: [PromptNode]) {
        isSyncing = true
        prompts = Self.canonicalize(nodes)
        persist()
        isSyncing = false
    }

    func save() {
        persist()
    }

    // MARK: - CRUD (unchanged API; every mutation rewrites the tree)

    func updatePrompts(_ newPrompts: [PromptNode]) {
        prompts = Self.canonicalize(newPrompts)
        persist()
        markCustomized()
    }

    func addNode(_ node: PromptNode, toFolderWithID folderID: UUID? = nil) {
        var updated = prompts
        if let folderID {
            insertNode(node, into: &updated, parentID: folderID)
        } else {
            updated.append(node)
        }
        prompts = Self.canonicalize(updated)
        persist()
        markCustomized()
    }

    func removeNode(withID id: UUID) {
        var updated = prompts
        removeNodeRecursive(id: id, from: &updated)
        prompts = Self.canonicalize(updated)
        persist()
        markCustomized()
    }

    func updateNode(_ node: PromptNode) {
        var updated = prompts
        updateNodeRecursive(node, in: &updated)
        prompts = Self.canonicalize(updated)
        persist()
        markCustomized()
    }

    enum MoveDirection { case up, down }

    func moveNode(id: UUID, direction: MoveDirection) {
        var updated = prompts
        moveNodeRecursive(id: id, direction: direction, in: &updated)
        prompts = Self.canonicalize(updated)
        persist()
        markCustomized()
    }

    func moveNode(id: UUID, toFolderID folderID: UUID?) {
        var updated = prompts
        // Extract the node from its current location
        guard let node = findAndRemoveNode(id: id, from: &updated) else { return }
        // Insert into the target folder (nil = root)
        if let folderID {
            insertNode(node, into: &updated, parentID: folderID)
        } else {
            updated.append(node)
        }
        prompts = Self.canonicalize(updated)
        persist()
        markCustomized()
    }

    func findNode(byID id: UUID) -> PromptNode? {
        findNodeRecursive(id: id, in: prompts)
    }

    func allPromptIDs() -> Set<UUID> {
        var result = Set<UUID>()
        collectIDs(from: prompts, into: &result)
        return result
    }

    func allPromptNodes() -> [PromptNode] {
        var result: [PromptNode] = []
        collectPrompts(from: prompts, into: &result)
        return result
    }

    /// Flattened list of every prompt node paired with its folder-name path.
    /// Folders themselves are excluded; the path is the chain of ancestor folder
    /// names (empty for root-level prompts). Used by the prompt-search feature
    /// to display "Folder / Subfolder" subtitles in flat result lists.
    func allPromptNodesWithPaths() -> [(node: PromptNode, path: [String])] {
        Self.promptNodesWithPaths(in: prompts)
    }

    /// Actor-free form of `allPromptNodesWithPaths()`, so callers that hold a tree
    /// but not the store — e.g. an App Intents query reading `prompts.json`
    /// directly on a cold launch — get identical flattening.
    nonisolated static func promptNodesWithPaths(
        in nodes: [PromptNode]
    ) -> [(node: PromptNode, path: [String])] {
        var result: [(node: PromptNode, path: [String])] = []
        collectPromptsWithPaths(from: nodes, path: [], into: &result)
        return result
    }

    func allFolders() -> [(id: UUID, name: String, depth: Int)] {
        var result: [(id: UUID, name: String, depth: Int)] = []
        collectFolders(from: prompts, depth: 0, into: &result)
        return result
    }

    // MARK: - Validation queries

    /// Returns IDs of sibling nodes (in the same parent folder, or root level)
    /// that share the same mnemonic key as `nodeID`. Case-insensitive.
    /// The placeholder "?" is never reported as a conflict so that freshly
    /// added prompts (which all default to "?") can coexist until renamed.
    func mnemonicConflictSiblings(of nodeID: UUID) -> [UUID] {
        guard let target = findNodeRecursive(id: nodeID, in: prompts) else { return [] }
        let key = target.mnemonicKey.lowercased()
        guard key != "?" else { return [] }

        let siblings = siblingsOfNode(id: nodeID, in: prompts) ?? []
        return siblings
            .filter { $0.mnemonicKey.lowercased() == key }
            .map(\.id)
    }

    /// Returns every prompt node (other than `excludingID`) whose
    /// `quickPasteShortcut` or `openRunShortcut` matches `config` exactly,
    /// paired with which field matched.
    func prompts(
        matchingShortcut config: ShortcutConfig,
        excluding excludingID: UUID
    ) -> [(prompt: PromptNode, field: ShortcutField)] {
        var result: [(prompt: PromptNode, field: ShortcutField)] = []
        for prompt in allPromptNodes() where prompt.id != excludingID {
            if prompt.quickPasteShortcut == config {
                result.append((prompt, .quickPaste))
            }
            if prompt.openRunShortcut == config {
                result.append((prompt, .openRun))
            }
        }
        return result
    }

    private func siblingsOfNode(id: UUID, in nodes: [PromptNode]) -> [PromptNode]? {
        if nodes.contains(where: { $0.id == id }) {
            return nodes.filter { $0.id != id }
        }
        for node in nodes {
            if let children = node.children,
               let result = siblingsOfNode(id: id, in: children) {
                return result
            }
        }
        return nil
    }

    private func collectFolders(from nodes: [PromptNode], depth: Int, into result: inout [(id: UUID, name: String, depth: Int)]) {
        for node in nodes where node.isFolder {
            result.append((id: node.id, name: node.name, depth: depth))
            if let children = node.children {
                collectFolders(from: children, depth: depth + 1, into: &result)
            }
        }
    }

    private func findNodeRecursive(id: UUID, in nodes: [PromptNode]) -> PromptNode? {
        for node in nodes {
            if node.id == id { return node }
            if let found = findNodeRecursive(id: id, in: node.children ?? []) {
                return found
            }
        }
        return nil
    }

    private func collectIDs(from nodes: [PromptNode], into result: inout Set<UUID>) {
        for node in nodes {
            result.insert(node.id)
            if let children = node.children {
                collectIDs(from: children, into: &result)
            }
        }
    }

    private func collectPrompts(from nodes: [PromptNode], into result: inout [PromptNode]) {
        for node in nodes {
            if node.isPrompt {
                result.append(node)
            }
            if let children = node.children {
                collectPrompts(from: children, into: &result)
            }
        }
    }

    nonisolated private static func collectPromptsWithPaths(
        from nodes: [PromptNode],
        path: [String],
        into result: inout [(node: PromptNode, path: [String])]
    ) {
        for node in nodes {
            if node.isPrompt {
                result.append((node: node, path: path))
            }
            if let children = node.children {
                collectPromptsWithPaths(from: children, path: path + [node.name], into: &result)
            }
        }
    }

    private func findAndRemoveNode(id: UUID, from nodes: inout [PromptNode]) -> PromptNode? {
        if let index = nodes.firstIndex(where: { $0.id == id }) {
            return nodes.remove(at: index)
        }
        for i in nodes.indices {
            if var children = nodes[i].children {
                if let found = findAndRemoveNode(id: id, from: &children) {
                    nodes[i].children = children
                    return found
                }
            }
        }
        return nil
    }

    func restoreDefaults() {
        prompts = Self.canonicalize(bundledDefaults())
        persist()
        defaultsActive = true
        setDefaultsActive?(true)
    }

    func exportJSON() -> Data? {
        try? JSONEncoder.pretty.encode(prompts)
    }

    func importJSON(from data: Data) throws {
        let decoded = try JSONDecoder().decode([PromptNode].self, from: data)
        prompts = Self.canonicalize(decoded)
        persist()
        markCustomized()
    }

    // MARK: - Persistence

    /// Writes the markdown tree (diffed — untouched files keep their mtimes),
    /// regenerates the derived `prompts.json` mirror, and notifies consumers.
    private func persist() {
        knownPaths = PromptLibraryFiles.sync(
            nodes: prompts, previousPaths: knownPaths, in: libraryDirectory
        )
        directorySignature = PromptLibraryFiles.signature(of: libraryDirectory)
        writeMirrorAndNotify()
    }

    private func writeMirrorAndNotify() {
        guard let data = try? JSONEncoder.pretty.encode(prompts) else { return }
        if (try? Data(contentsOf: mirrorFileURL)) != data {
            try? data.write(to: mirrorFileURL)
        }

        // Posted unconditionally — deliberately ABOVE the isSyncing guard.
        //
        // `onPromptsChanged` is a single-assignment closure already claimed by
        // AppState (iCloud upload + shortcut refresh), and it is suppressed during
        // remote sync to avoid an echo loop. Consumers that only need to *observe*
        // the library — like Spotlight indexing — must also see changes arriving
        // from another Mac, so they hang off this instead.
        NotificationCenter.default.post(name: .clipSlopPromptLibraryDidChange, object: nil)

        if !isSyncing {
            onPromptsChanged?(data)
        }
    }

    private func refreshMirrorIfStale() {
        guard let data = try? JSONEncoder.pretty.encode(prompts) else { return }
        if (try? Data(contentsOf: mirrorFileURL)) != data {
            try? data.write(to: mirrorFileURL)
            NotificationCenter.default.post(name: .clipSlopPromptLibraryDidChange, object: nil)
        }
    }

    private func markCustomized() {
        defaultsActive = false
        setDefaultsActive?(false)
    }

    // MARK: - Canonical form

    /// The file tree's canonical shape: prompt bodies are
    /// whitespace-trimmed (frontmatter parsing trims the markdown body, so
    /// padding could never round-trip), prompts carry no children, folders
    /// always carry a (possibly empty) children array and no body.
    nonisolated static func canonicalize(_ nodes: [PromptNode]) -> [PromptNode] {
        nodes.map { node in
            var updated = node
            if node.isFolder {
                updated.systemPrompt = nil
                updated.children = canonicalize(node.children ?? [])
            } else {
                updated.systemPrompt = (node.systemPrompt ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                updated.children = nil
            }
            return updated
        }
    }

    // MARK: - Sources

    nonisolated static func loadBundledDefaults() -> [PromptNode] {
        guard let url = Bundle.module.url(forResource: "DefaultPrompts", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let nodes = try? JSONDecoder().decode([PromptNode].self, from: data)
        else { return [] }
        return nodes
    }

    nonisolated private static func decodeMirror(at url: URL) -> [PromptNode]? {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let nodes = try? JSONDecoder().decode([PromptNode].self, from: data)
        else { return nil }
        return nodes
    }

    private func insertNode(_ node: PromptNode, into nodes: inout [PromptNode], parentID: UUID) {
        for i in nodes.indices {
            if nodes[i].id == parentID {
                var updated = nodes[i]
                var children = updated.children ?? []
                children.append(node)
                updated.children = children
                nodes[i] = updated
                return
            }
            if var children = nodes[i].children {
                insertNode(node, into: &children, parentID: parentID)
                nodes[i].children = children
            }
        }
    }

    private func removeNodeRecursive(id: UUID, from nodes: inout [PromptNode]) {
        nodes.removeAll { $0.id == id }
        for i in nodes.indices {
            if var children = nodes[i].children {
                removeNodeRecursive(id: id, from: &children)
                nodes[i].children = children
            }
        }
    }

    private func updateNodeRecursive(_ node: PromptNode, in nodes: inout [PromptNode]) {
        for i in nodes.indices {
            if nodes[i].id == node.id {
                nodes[i] = node
                return
            }
            if var children = nodes[i].children {
                updateNodeRecursive(node, in: &children)
                nodes[i].children = children
            }
        }
    }

    private func moveNodeRecursive(id: UUID, direction: MoveDirection, in nodes: inout [PromptNode]) {
        if let index = nodes.firstIndex(where: { $0.id == id }) {
            let targetIndex = direction == .up ? index - 1 : index + 1
            guard targetIndex >= 0, targetIndex < nodes.count else { return }
            nodes.swapAt(index, targetIndex)
            return
        }
        for i in nodes.indices {
            if var children = nodes[i].children {
                moveNodeRecursive(id: id, direction: direction, in: &children)
                nodes[i].children = children
            }
        }
    }
}

extension JSONEncoder {
    static let pretty: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}
