import Foundation
import KeyboardShortcuts

// MARK: - Proposal model (shown as an Approve/Reject card)

/// One before→after row inside a proposal card. `oldValue == nil` means a pure
/// addition; `newValue == nil` means a removal.
struct ProposalField: Identifiable, Hashable, Sendable {
    let id = UUID()
    let label: String
    let oldValue: String?
    let newValue: String?
}

enum ProposalResolution: Sendable, Equatable {
    case pending
    case approved
    case rejected
}

/// A pending library mutation the assistant wants to make. Rendered as a card
/// in the chat; applied only if the user approves.
struct ToolProposal: Identifiable, Sendable {
    let id = UUID()
    let call: ToolCallRequest
    let title: String
    let fields: [ProposalField]
    let isDestructive: Bool
    let warning: String?
    var resolution: ProposalResolution = .pending
}

// MARK: - Tool error

/// A recoverable tool failure. The message is fed back to the model so it can
/// correct itself (e.g. re-list the library and retry with a valid id).
struct ToolError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - Tool definitions

enum PromptLibraryTools {
    static func isMutating(_ toolName: String) -> Bool {
        all.first { $0.name == toolName }?.isMutating ?? false
    }

    static let all: [ToolDefinition] = [
        ToolDefinition(
            name: "list_library",
            description: "List the whole prompt library as a tree of folders and prompts. Returns each node's id, name, type, mnemonic, and (for prompts) display mode, shortcuts, and provider. Does NOT include prompt bodies — use get_prompt for those. Always call this before referencing any node by id.",
            parametersSchemaJSON: #"{"type":"object","properties":{},"additionalProperties":false}"#,
            isMutating: false
        ),
        ToolDefinition(
            name: "get_prompt",
            description: "Get the full details of one prompt, including its system_prompt body.",
            parametersSchemaJSON: #"{"type":"object","properties":{"id":{"type":"string","description":"The prompt's id from list_library."}},"required":["id"],"additionalProperties":false}"#,
            isMutating: false
        ),
        ToolDefinition(
            name: "create_prompt",
            description: "Create a new prompt. system_prompt is the instruction text sent to the AI when the prompt runs.",
            parametersSchemaJSON: #"{"type":"object","properties":{"name":{"type":"string"},"system_prompt":{"type":"string"},"folder_id":{"type":"string","description":"Optional id of the folder to place it in; omit for the library root."},"mnemonic_key":{"type":"string","description":"Optional single character for in-popup navigation."},"display_mode":{"type":"string","enum":["default","plainText","html","markdown","markdownStyled"]},"select_all_before_capture":{"type":"boolean"}},"required":["name","system_prompt"],"additionalProperties":false}"#,
            isMutating: true
        ),
        ToolDefinition(
            name: "update_prompt",
            description: "Update an existing prompt. Only the fields you provide change. Use display_mode \"default\" to clear a per-prompt mode override.",
            parametersSchemaJSON: #"{"type":"object","properties":{"id":{"type":"string"},"name":{"type":"string"},"system_prompt":{"type":"string"},"mnemonic_key":{"type":"string"},"display_mode":{"type":"string","enum":["default","plainText","html","markdown","markdownStyled"]},"select_all_before_capture":{"type":"boolean"},"provider_name":{"type":"string","description":"Name of an AI provider to use for this prompt, or \"default\" to clear the override."}},"required":["id"],"additionalProperties":false}"#,
            isMutating: true
        ),
        ToolDefinition(
            name: "create_folder",
            description: "Create a new folder.",
            parametersSchemaJSON: #"{"type":"object","properties":{"name":{"type":"string"},"parent_folder_id":{"type":"string","description":"Optional id of the parent folder; omit for the library root."},"mnemonic_key":{"type":"string"}},"required":["name"],"additionalProperties":false}"#,
            isMutating: true
        ),
        ToolDefinition(
            name: "rename_folder",
            description: "Rename a folder or change its mnemonic.",
            parametersSchemaJSON: #"{"type":"object","properties":{"id":{"type":"string"},"name":{"type":"string"},"mnemonic_key":{"type":"string"}},"required":["id"],"additionalProperties":false}"#,
            isMutating: true
        ),
        ToolDefinition(
            name: "delete_node",
            description: "Delete a prompt or a folder. Deleting a folder deletes everything inside it.",
            parametersSchemaJSON: #"{"type":"object","properties":{"id":{"type":"string"}},"required":["id"],"additionalProperties":false}"#,
            isMutating: true
        ),
        ToolDefinition(
            name: "move_node",
            description: "Move a prompt or folder into another folder, or to the library root.",
            parametersSchemaJSON: #"{"type":"object","properties":{"id":{"type":"string"},"target_folder_id":{"type":"string","description":"Destination folder id; omit or null for the library root."}},"required":["id"],"additionalProperties":false}"#,
            isMutating: true
        ),
        ToolDefinition(
            name: "set_shortcut",
            description: "Assign a global keyboard shortcut to a prompt. slot \"quick_paste\" transforms the selected text in place; slot \"open_run\" opens the popup and runs the prompt. Shortcut format: \"cmd+shift+g\" (needs Command, Control, or Option).",
            parametersSchemaJSON: #"{"type":"object","properties":{"id":{"type":"string"},"slot":{"type":"string","enum":["quick_paste","open_run"]},"shortcut":{"type":"string","description":"e.g. \"cmd+shift+g\", \"ctrl+opt+f5\"."}},"required":["id","slot","shortcut"],"additionalProperties":false}"#,
            isMutating: true
        ),
        ToolDefinition(
            name: "clear_shortcut",
            description: "Remove a prompt's global keyboard shortcut for the given slot.",
            parametersSchemaJSON: #"{"type":"object","properties":{"id":{"type":"string"},"slot":{"type":"string","enum":["quick_paste","open_run"]}},"required":["id","slot"],"additionalProperties":false}"#,
            isMutating: true
        ),
    ]
}

// MARK: - Executor

/// Runs the assistant's tool calls against the prompt library. Read-only tools
/// are executed directly by the agent loop; mutating tools go through
/// `makeProposal` (for the confirmation card) and then `perform` on approval.
@MainActor
final class PromptLibraryToolExecutor {
    private let store: PromptStore
    private let providerStore: ProviderStore
    private let shortcutService: PromptShortcutService

    init(store: PromptStore, providerStore: ProviderStore, shortcutService: PromptShortcutService) {
        self.store = store
        self.providerStore = providerStore
        self.shortcutService = shortcutService
    }

    // MARK: Proposal building (mutating tools)

    func makeProposal(for call: ToolCallRequest) throws -> ToolProposal {
        let args = arguments(call)
        switch call.name {
        case "create_prompt":
            let name = try requireString(args, "name")
            var fields: [ProposalField] = [ProposalField(label: "Name", oldValue: nil, newValue: name)]
            fields.append(ProposalField(label: "Prompt", oldValue: nil, newValue: try requireString(args, "system_prompt")))
            if let folderID = args["folder_id"]?.stringValue {
                fields.append(ProposalField(label: "Folder", oldValue: nil, newValue: folderName(forID: folderID)))
            }
            return ToolProposal(call: call, title: "Create prompt “\(name)”", fields: fields, isDestructive: false, warning: nil)

        case "update_prompt":
            let node = try requireNode(args["id"]?.stringValue)
            var fields: [ProposalField] = []
            if let value = args["name"]?.stringValue {
                fields.append(ProposalField(label: "Name", oldValue: node.name, newValue: value))
            }
            if let value = args["system_prompt"]?.stringValue {
                fields.append(ProposalField(label: "Prompt", oldValue: node.systemPrompt, newValue: value))
            }
            if let value = args["mnemonic_key"]?.stringValue {
                fields.append(ProposalField(label: "Mnemonic", oldValue: node.mnemonicKey, newValue: value))
            }
            if let value = args["display_mode"]?.stringValue {
                fields.append(ProposalField(label: "Mode", oldValue: node.displayMode?.rawValue ?? "default", newValue: value))
            }
            if let value = args["select_all_before_capture"]?.boolValue {
                fields.append(ProposalField(label: "Select all first", oldValue: String(node.selectAllBeforeCapture ?? false), newValue: String(value)))
            }
            if let value = args["provider_name"]?.stringValue {
                fields.append(ProposalField(label: "Provider", oldValue: providerName(for: node.providerID) ?? "Default", newValue: value))
            }
            return ToolProposal(call: call, title: "Edit prompt “\(node.name)”", fields: fields, isDestructive: false, warning: nil)

        case "create_folder":
            let name = try requireString(args, "name")
            var fields: [ProposalField] = [ProposalField(label: "Name", oldValue: nil, newValue: name)]
            if let parent = args["parent_folder_id"]?.stringValue {
                fields.append(ProposalField(label: "Inside", oldValue: nil, newValue: folderName(forID: parent)))
            }
            return ToolProposal(call: call, title: "Create folder “\(name)”", fields: fields, isDestructive: false, warning: nil)

        case "rename_folder":
            let node = try requireNode(args["id"]?.stringValue)
            var fields: [ProposalField] = []
            if let value = args["name"]?.stringValue {
                fields.append(ProposalField(label: "Name", oldValue: node.name, newValue: value))
            }
            if let value = args["mnemonic_key"]?.stringValue {
                fields.append(ProposalField(label: "Mnemonic", oldValue: node.mnemonicKey, newValue: value))
            }
            return ToolProposal(call: call, title: "Rename folder “\(node.name)”", fields: fields, isDestructive: false, warning: nil)

        case "delete_node":
            let node = try requireNode(args["id"]?.stringValue)
            let kind = node.isFolder ? "folder" : "prompt"
            var warning: String?
            if node.isFolder {
                let count = descendantCount(node)
                if count > 0 {
                    warning = "This folder contains \(count) item\(count == 1 ? "" : "s"). Deleting it removes them all."
                }
            }
            return ToolProposal(
                call: call,
                title: "Delete \(kind) “\(node.name)”",
                fields: [ProposalField(label: kind.capitalized, oldValue: node.name, newValue: nil)],
                isDestructive: true,
                warning: warning
            )

        case "move_node":
            let node = try requireNode(args["id"]?.stringValue)
            let target = folderName(forID: args["target_folder_id"]?.stringValue)
            return ToolProposal(
                call: call,
                title: "Move “\(node.name)”",
                fields: [ProposalField(label: "Move to", oldValue: nil, newValue: target)],
                isDestructive: false,
                warning: nil
            )

        case "set_shortcut":
            let node = try requireNode(args["id"]?.stringValue)
            guard node.isPrompt else { throw ToolError(message: "Shortcuts can only be set on prompts, not folders.") }
            let slot = try requireSlot(args)
            let config = try parseShortcut(args)
            try ensureNoShortcutConflict(config, excluding: node.id)
            return ToolProposal(
                call: call,
                title: "Set \(slotLabel(slot)) shortcut for “\(node.name)”",
                fields: [ProposalField(label: slotLabel(slot), oldValue: nil, newValue: ShortcutParser.display(config))],
                isDestructive: false,
                warning: nil
            )

        case "clear_shortcut":
            let node = try requireNode(args["id"]?.stringValue)
            let slot = try requireSlot(args)
            let existing = (slot == .quickPaste ? node.quickPasteShortcut : node.openRunShortcut)
                .map { ShortcutParser.display($0) } ?? "None"
            return ToolProposal(
                call: call,
                title: "Clear \(slotLabel(slot)) shortcut for “\(node.name)”",
                fields: [ProposalField(label: slotLabel(slot), oldValue: existing, newValue: "None")],
                isDestructive: false,
                warning: nil
            )

        default:
            throw ToolError(message: "Unknown tool '\(call.name)'.")
        }
    }

    // MARK: Execution (read-only tools + approved mutations)

    func perform(_ call: ToolCallRequest) throws -> String {
        let args = arguments(call)
        switch call.name {
        case "list_library":
            return libraryJSON(store.prompts).jsonString()

        case "get_prompt":
            let node = try requireNode(args["id"]?.stringValue)
            guard node.isPrompt else { throw ToolError(message: "Node '\(node.name)' is a folder, not a prompt.") }
            return promptDetailJSON(node).jsonString()

        case "create_prompt":
            let node = PromptNode(
                name: try requireString(args, "name"),
                mnemonicKey: args["mnemonic_key"]?.stringValue ?? "?",
                nodeType: .prompt,
                systemPrompt: try requireString(args, "system_prompt"),
                displayMode: try displayMode(args["display_mode"]?.stringValue) ?? nil,
                selectAllBeforeCapture: args["select_all_before_capture"]?.boolValue
            )
            let folderID = args["folder_id"]?.stringValue.flatMap { UUID(uuidString: $0) }
            store.addNode(node, toFolderWithID: folderID)
            return success(["status": .string("created"), "id": .string(node.id.uuidString)], warnings: mnemonicWarnings(for: node.id))

        case "update_prompt":
            var node = try requireNode(args["id"]?.stringValue)
            guard node.isPrompt else { throw ToolError(message: "Node '\(node.name)' is a folder; use rename_folder.") }
            if let value = args["name"]?.stringValue { node.name = value }
            if let value = args["system_prompt"]?.stringValue { node.systemPrompt = value }
            if let value = args["mnemonic_key"]?.stringValue { node.mnemonicKey = value }
            if let raw = args["display_mode"]?.stringValue { node.displayMode = try displayMode(raw) ?? nil }
            if let value = args["select_all_before_capture"]?.boolValue { node.selectAllBeforeCapture = value }
            if let providerNameValue = args["provider_name"]?.stringValue {
                node.providerID = try resolveProviderID(providerNameValue)
            }
            store.updateNode(node)
            return success(["status": .string("updated"), "id": .string(node.id.uuidString)], warnings: mnemonicWarnings(for: node.id))

        case "create_folder":
            let node = PromptNode(
                name: try requireString(args, "name"),
                mnemonicKey: args["mnemonic_key"]?.stringValue ?? "?",
                nodeType: .folder,
                children: []
            )
            let parentID = args["parent_folder_id"]?.stringValue.flatMap { UUID(uuidString: $0) }
            store.addNode(node, toFolderWithID: parentID)
            return success(["status": .string("created"), "id": .string(node.id.uuidString)])

        case "rename_folder":
            var node = try requireNode(args["id"]?.stringValue)
            guard node.isFolder else { throw ToolError(message: "Node '\(node.name)' is a prompt; use update_prompt.") }
            if let value = args["name"]?.stringValue { node.name = value }
            if let value = args["mnemonic_key"]?.stringValue { node.mnemonicKey = value }
            store.updateNode(node)
            return success(["status": .string("updated"), "id": .string(node.id.uuidString)], warnings: mnemonicWarnings(for: node.id))

        case "delete_node":
            let node = try requireNode(args["id"]?.stringValue)
            store.removeNode(withID: node.id)
            shortcutService.refreshShortcuts()
            return success(["status": .string("deleted"), "id": .string(node.id.uuidString)])

        case "move_node":
            let node = try requireNode(args["id"]?.stringValue)
            let targetID = args["target_folder_id"]?.stringValue.flatMap { UUID(uuidString: $0) }
            if let targetID, store.findNode(byID: targetID)?.isFolder != true {
                throw ToolError(message: "Target '\(args["target_folder_id"]?.stringValue ?? "")' is not a folder.")
            }
            store.moveNode(id: node.id, toFolderID: targetID)
            return success(["status": .string("moved"), "id": .string(node.id.uuidString)])

        case "set_shortcut":
            let node = try requireNode(args["id"]?.stringValue)
            guard node.isPrompt else { throw ToolError(message: "Shortcuts can only be set on prompts.") }
            let slot = try requireSlot(args)
            let config = try parseShortcut(args)
            try ensureNoShortcutConflict(config, excluding: node.id)
            var updated = node
            let name: KeyboardShortcuts.Name
            switch slot {
            case .quickPaste:
                updated.quickPasteShortcut = config
                name = PromptShortcutService.quickPasteName(for: node.id)
            case .openRun:
                updated.openRunShortcut = config
                name = PromptShortcutService.openRunName(for: node.id)
            }
            store.updateNode(updated)
            KeyboardShortcuts.setShortcut(
                .init(carbonKeyCode: config.carbonKeyCode, carbonModifiers: config.carbonModifiers),
                for: name
            )
            shortcutService.refreshShortcuts()
            return success(["status": .string("shortcut_set"), "id": .string(node.id.uuidString), "shortcut": .string(ShortcutParser.display(config))])

        case "clear_shortcut":
            let node = try requireNode(args["id"]?.stringValue)
            let slot = try requireSlot(args)
            var updated = node
            let name: KeyboardShortcuts.Name
            switch slot {
            case .quickPaste:
                updated.quickPasteShortcut = nil
                name = PromptShortcutService.quickPasteName(for: node.id)
            case .openRun:
                updated.openRunShortcut = nil
                name = PromptShortcutService.openRunName(for: node.id)
            }
            store.updateNode(updated)
            KeyboardShortcuts.reset(name)
            shortcutService.refreshShortcuts()
            return success(["status": .string("shortcut_cleared"), "id": .string(node.id.uuidString)])

        default:
            throw ToolError(message: "Unknown tool '\(call.name)'.")
        }
    }

    /// A short human-readable label for the read-only activity row.
    func activityLabel(for call: ToolCallRequest) -> String {
        switch call.name {
        case "list_library":
            return "Read library"
        case "get_prompt":
            let id = arguments(call)["id"]?.stringValue
            if let id, let uuid = UUID(uuidString: id), let node = store.findNode(byID: uuid) {
                return "Read prompt “\(node.name)”"
            }
            return "Read prompt"
        default:
            return call.name
        }
    }

    // MARK: - Argument helpers

    private func arguments(_ call: ToolCallRequest) -> [String: JSONValue] {
        JSONValue.parse(call.argumentsJSON).objectValue ?? [:]
    }

    private func requireString(_ args: [String: JSONValue], _ key: String) throws -> String {
        guard let value = args[key]?.stringValue, !value.isEmpty else {
            throw ToolError(message: "Missing required argument '\(key)'.")
        }
        return value
    }

    private func requireNode(_ idString: String?) throws -> PromptNode {
        guard let idString else { throw ToolError(message: "Missing required argument 'id'.") }
        guard let uuid = UUID(uuidString: idString) else {
            throw ToolError(message: "'\(idString)' is not a valid id. Call list_library for current ids.")
        }
        guard let node = store.findNode(byID: uuid) else {
            throw ToolError(message: "No node with id '\(idString)'. Call list_library for current ids.")
        }
        return node
    }

    private func requireSlot(_ args: [String: JSONValue]) throws -> ShortcutField {
        switch args["slot"]?.stringValue {
        case "quick_paste": return .quickPaste
        case "open_run": return .openRun
        default: throw ToolError(message: "slot must be \"quick_paste\" or \"open_run\".")
        }
    }

    private func slotLabel(_ slot: ShortcutField) -> String {
        slot == .quickPaste ? "Quick Paste" : "Open & Run"
    }

    private func parseShortcut(_ args: [String: JSONValue]) throws -> ShortcutConfig {
        let raw = try requireString(args, "shortcut")
        guard let config = ShortcutParser.parse(raw) else {
            throw ToolError(message: "Couldn't parse shortcut '\(raw)'. Use a form like \"cmd+shift+g\" with at least Command, Control, or Option.")
        }
        return config
    }

    private func ensureNoShortcutConflict(_ config: ShortcutConfig, excluding id: UUID) throws {
        if let conflict = store.prompts(matchingShortcut: config, excluding: id).first {
            throw ToolError(message: "Shortcut \(ShortcutParser.display(config)) is already used by “\(conflict.prompt.name)”. Ask the user, or clear it there first.")
        }
    }

    /// Returns `.some(mode)` for a valid mode, `.some(nil)` for "default"
    /// (clear the override), and throws for anything else. `nil` return from
    /// the optional means "no value provided" is handled by the caller.
    private func displayMode(_ raw: String?) throws -> EditorMode?? {
        guard let raw else { return nil }
        if raw == "default" { return .some(nil) }
        guard let mode = EditorMode(rawValue: raw) else {
            throw ToolError(message: "Unknown display_mode '\(raw)'. Use default, plainText, html, markdown, or markdownStyled.")
        }
        return .some(mode)
    }

    private func resolveProviderID(_ name: String) throws -> UUID? {
        if name.lowercased() == "default" { return nil }
        guard let match = providerStore.providers.first(where: { $0.name.lowercased() == name.lowercased() }) else {
            let available = providerStore.providers.map(\.name).joined(separator: ", ")
            throw ToolError(message: "No provider named '\(name)'. Available: \(available.isEmpty ? "none" : available).")
        }
        return match.id
    }

    private func providerName(for id: UUID?) -> String? {
        guard let id else { return nil }
        return providerStore.providers.first(where: { $0.id == id })?.name
    }

    private func folderName(forID idString: String?) -> String {
        guard let idString,
              let uuid = UUID(uuidString: idString),
              let node = store.findNode(byID: uuid)
        else { return "Library root" }
        return node.name
    }

    private func descendantCount(_ node: PromptNode) -> Int {
        guard let children = node.children else { return 0 }
        return children.reduce(children.count) { $0 + descendantCount($1) }
    }

    private func mnemonicWarnings(for id: UUID) -> [String] {
        let conflicts = store.mnemonicConflictSiblings(of: id)
        guard !conflicts.isEmpty else { return [] }
        return ["The mnemonic key now conflicts with \(conflicts.count) sibling node(s). Consider a different key."]
    }

    private func success(_ dict: [String: JSONValue], warnings: [String] = []) -> String {
        var payload = dict
        if !warnings.isEmpty {
            payload["warnings"] = .array(warnings.map { .string($0) })
        }
        return JSONValue.object(payload).jsonString()
    }

    // MARK: - JSON rendering

    private func libraryJSON(_ nodes: [PromptNode]) -> JSONValue {
        .array(nodes.map { nodeSummary($0) })
    }

    private func nodeSummary(_ node: PromptNode) -> JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(node.id.uuidString),
            "name": .string(node.name),
            "type": .string(node.nodeType.rawValue),
        ]
        if node.mnemonicKey != "?" && !node.mnemonicKey.isEmpty {
            object["mnemonic"] = .string(node.mnemonicDisplay)
        }
        if node.isPrompt {
            object["display_mode"] = .string(node.displayMode?.rawValue ?? "default")
            if node.selectAllBeforeCapture == true {
                object["select_all_before_capture"] = .bool(true)
            }
            if let name = providerName(for: node.providerID) {
                object["provider"] = .string(name)
            }
            var shortcuts: [String: JSONValue] = [:]
            if let config = node.quickPasteShortcut {
                shortcuts["quick_paste"] = .string(ShortcutParser.display(config))
            }
            if let config = node.openRunShortcut {
                shortcuts["open_run"] = .string(ShortcutParser.display(config))
            }
            if !shortcuts.isEmpty { object["shortcuts"] = .object(shortcuts) }
        }
        if node.isFolder {
            object["children"] = libraryJSON(node.sortedChildren)
        }
        return .object(object)
    }

    private func promptDetailJSON(_ node: PromptNode) -> JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(node.id.uuidString),
            "name": .string(node.name),
            "type": .string(node.nodeType.rawValue),
            "system_prompt": .string(node.systemPrompt ?? ""),
            "mnemonic": .string(node.mnemonicKey),
            "display_mode": .string(node.displayMode?.rawValue ?? "default"),
            "select_all_before_capture": .bool(node.selectAllBeforeCapture ?? false),
        ]
        if let name = providerName(for: node.providerID) {
            object["provider"] = .string(name)
        }
        if let config = node.quickPasteShortcut {
            object["quick_paste_shortcut"] = .string(ShortcutParser.display(config))
        }
        if let config = node.openRunShortcut {
            object["open_run_shortcut"] = .string(ShortcutParser.display(config))
        }
        return .object(object)
    }
}
