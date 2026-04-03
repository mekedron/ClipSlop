import Foundation

struct PromptNode: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var mnemonicKey: String
    var nodeType: NodeType
    var systemPrompt: String?
    var children: [PromptNode]?
    var mnemonicModifiers: MnemonicModifiers?

    enum NodeType: String, Codable, Sendable {
        case folder
        case prompt
    }

    init(
        id: UUID = UUID(),
        name: String,
        mnemonicKey: String,
        nodeType: NodeType,
        systemPrompt: String? = nil,
        children: [PromptNode]? = nil,
        mnemonicModifiers: MnemonicModifiers? = nil
    ) {
        self.id = id
        self.name = name
        self.mnemonicKey = mnemonicKey
        self.nodeType = nodeType
        self.systemPrompt = systemPrompt
        self.children = children
        self.mnemonicModifiers = mnemonicModifiers
    }

    /// Display string for the mnemonic badge, e.g. "⇧F" or "T".
    var mnemonicDisplay: String {
        let prefix = (mnemonicModifiers ?? []).symbolString
        return prefix + mnemonicKey.uppercased()
    }

    var isFolder: Bool { nodeType == .folder }
    var isPrompt: Bool { nodeType == .prompt }

    var sortedChildren: [PromptNode] {
        children?.sorted { $0.mnemonicKey < $1.mnemonicKey } ?? []
    }

    func findChild(byKey key: String) -> PromptNode? {
        children?.first { $0.mnemonicKey.lowercased() == key.lowercased() }
    }

    static func folder(_ name: String, key: String, children: [PromptNode]) -> PromptNode {
        PromptNode(name: name, mnemonicKey: key, nodeType: .folder, children: children)
    }

    static func prompt(_ name: String, key: String, systemPrompt: String) -> PromptNode {
        PromptNode(name: name, mnemonicKey: key, nodeType: .prompt, systemPrompt: systemPrompt)
    }
}
