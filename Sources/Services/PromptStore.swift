import Foundation

@MainActor
@Observable
final class PromptStore {
    private(set) var prompts: [PromptNode] = []

    init() {
        prompts = loadFromDisk() ?? loadDefaults()
    }

    func save() {
        saveToDisk(prompts)
    }

    func updatePrompts(_ newPrompts: [PromptNode]) {
        prompts = newPrompts
        saveToDisk(newPrompts)
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
    }

    func removeNode(withID id: UUID) {
        var updated = prompts
        removeNodeRecursive(id: id, from: &updated)
        prompts = updated
        saveToDisk(updated)
    }

    func updateNode(_ node: PromptNode) {
        var updated = prompts
        updateNodeRecursive(node, in: &updated)
        prompts = updated
        saveToDisk(updated)
    }

    func restoreDefaults() {
        prompts = loadDefaults()
        saveToDisk(prompts)
    }

    func exportJSON() -> Data? {
        try? JSONEncoder.pretty.encode(prompts)
    }

    func importJSON(from data: Data) throws {
        let decoded = try JSONDecoder().decode([PromptNode].self, from: data)
        prompts = decoded
        saveToDisk(decoded)
    }

    // MARK: - Private

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
        try? JSONEncoder.pretty.encode(nodes).write(to: Constants.promptsFileURL)
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
}

extension JSONEncoder {
    static let pretty: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}
