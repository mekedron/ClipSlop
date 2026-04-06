import Foundation

@MainActor
@Observable
final class PromptStore {
    private(set) var prompts: [PromptNode] = []

    /// Called after every local save with the encoded JSON data.
    /// CloudSyncService hooks into this to upload changes.
    var onPromptsChanged: ((_ data: Data) -> Void)?

    /// True while applying a remote sync — suppresses onPromptsChanged to prevent echo loops.
    private var isSyncing = false

    init() {
        let settings = AppSettings.shared
        if settings.useDefaultPrompts {
            // Always load latest defaults when user hasn't customized
            prompts = loadDefaults()
            saveToDisk(prompts)
        } else {
            prompts = loadFromDisk() ?? loadDefaults()
        }
    }

    /// Replace prompts from a remote iCloud sync. Saves locally but does NOT fire onPromptsChanged.
    func replaceFromSync(_ nodes: [PromptNode]) {
        isSyncing = true
        prompts = nodes
        saveToDisk(nodes)
        isSyncing = false
    }

    func save() {
        saveToDisk(prompts)
    }

    func updatePrompts(_ newPrompts: [PromptNode]) {
        prompts = newPrompts
        saveToDisk(newPrompts)
        markCustomized()
    }

    func addNode(_ node: PromptNode, toFolderWithID folderID: UUID? = nil) {
        var updated = prompts
        if let folderID {
            insertNode(node, into: &updated, parentID: folderID)
        } else {
            updated.append(node)
        }
        prompts = updated
        saveToDisk(updated)
        markCustomized()
    }

    func removeNode(withID id: UUID) {
        var updated = prompts
        removeNodeRecursive(id: id, from: &updated)
        prompts = updated
        saveToDisk(updated)
        markCustomized()
    }

    func updateNode(_ node: PromptNode) {
        var updated = prompts
        updateNodeRecursive(node, in: &updated)
        prompts = updated
        saveToDisk(updated)
        markCustomized()
    }

    enum MoveDirection { case up, down }

    func moveNode(id: UUID, direction: MoveDirection) {
        var updated = prompts
        moveNodeRecursive(id: id, direction: direction, in: &updated)
        prompts = updated
        saveToDisk(updated)
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
        prompts = updated
        saveToDisk(updated)
        markCustomized()
    }

    func allFolders() -> [(id: UUID, name: String, depth: Int)] {
        var result: [(id: UUID, name: String, depth: Int)] = []
        collectFolders(from: prompts, depth: 0, into: &result)
        return result
    }

    private func collectFolders(from nodes: [PromptNode], depth: Int, into result: inout [(id: UUID, name: String, depth: Int)]) {
        for node in nodes where node.isFolder {
            result.append((id: node.id, name: node.name, depth: depth))
            if let children = node.children {
                collectFolders(from: children, depth: depth + 1, into: &result)
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
        prompts = loadDefaults()
        saveToDisk(prompts)
        AppSettings.shared.useDefaultPrompts = true
    }

    func exportJSON() -> Data? {
        try? JSONEncoder.pretty.encode(prompts)
    }

    func importJSON(from data: Data) throws {
        let decoded = try JSONDecoder().decode([PromptNode].self, from: data)
        prompts = decoded
        saveToDisk(decoded)
        markCustomized()
    }

    // MARK: - Private

    private func markCustomized() {
        AppSettings.shared.useDefaultPrompts = false
    }

    private func loadDefaults() -> [PromptNode] {
        guard let url = Bundle.module.url(forResource: "DefaultPrompts", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let nodes = try? JSONDecoder().decode([PromptNode].self, from: data)
        else { return [] }
        return nodes
    }

    private func loadFromDisk() -> [PromptNode]? {
        guard FileManager.default.fileExists(atPath: Constants.promptsFileURL.path),
              let data = try? Data(contentsOf: Constants.promptsFileURL),
              let nodes = try? JSONDecoder().decode([PromptNode].self, from: data)
        else { return nil }
        return nodes
    }

    private func saveToDisk(_ nodes: [PromptNode]) {
        guard let data = try? JSONEncoder.pretty.encode(nodes) else { return }
        try? data.write(to: Constants.promptsFileURL)
        if !isSyncing {
            onPromptsChanged?(data)
        }
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
