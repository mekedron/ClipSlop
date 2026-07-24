import Foundation

/// Serialization between the in-memory `PromptNode` tree and the markdown
/// card tree under `~/.clipslop/workflows/library/` (§7.3: "the library IS
/// the workflow store").
///
/// Layout: folders are subdirectories carrying a `_folder.md` metadata card
/// (uuid/title/mnemonic/order); prompts are workflow cards
/// (`kind: workflow, mode: direct`) whose body is the prompt's system-prompt
/// text and whose §7.3 library keys carry the popup/hotkey attributes. Cards
/// have no `when:`, so they never enter routing — the engine can still load
/// and invoke them by id, and `PromptStore` maps them onto the existing
/// `PromptNode` API by their frontmatter `uuid:`.
///
/// Everything here is pure and `nonisolated`; `PromptStore` is the only
/// writer.
enum PromptLibraryFiles {

    static let folderFileName = "_folder.md"

    /// Filename stem the library uses when a name slugs down to nothing
    /// (e.g. a fully non-ASCII name).
    static let fallbackSlug = "item"

    // MARK: - Load

    struct LoadResult {
        var nodes: [PromptNode] = []
        /// Relative paths of every file the model was built from (including
        /// `_folder.md`s and files scheduled for a uuid write-back). The
        /// store's diff-sync may delete these when their node disappears —
        /// and never touches anything else, so an unparseable hand-edited
        /// file is skipped with an issue, not destroyed.
        var parsedRelativePaths: Set<String> = []
        /// Files that must be rewritten to persist a generated identity
        /// (missing or duplicate `uuid:`, missing `_folder.md`).
        var pendingWrites: [(url: URL, content: String)] = []
        var issues: [String] = []
    }

    static func load(from directory: URL) -> LoadResult {
        var result = LoadResult()
        var seenUUIDs = Set<UUID>()
        result.nodes = loadChildren(of: directory, root: directory, seenUUIDs: &seenUUIDs, result: &result)
        return result
    }

    private static func loadChildren(
        of directory: URL,
        root: URL,
        seenUUIDs: inout Set<UUID>,
        result: inout LoadResult
    ) -> [PromptNode] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var items: [(order: Int, sortKey: String, node: PromptNode)] = []

        for url in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory {
                let (node, order) = loadFolder(at: url, root: root, seenUUIDs: &seenUUIDs, result: &result)
                items.append((order, url.lastPathComponent, node))
            } else if url.pathExtension == "md", url.lastPathComponent != folderFileName {
                guard let (node, order) = loadPrompt(at: url, root: root, seenUUIDs: &seenUUIDs, result: &result)
                else { continue }
                items.append((order, url.lastPathComponent, node))
            }
        }

        return items
            .sorted { ($0.order, $0.sortKey) < ($1.order, $1.sortKey) }
            .map(\.node)
    }

    private static func loadPrompt(
        at url: URL,
        root: URL,
        seenUUIDs: inout Set<UUID>,
        result: inout LoadResult
    ) -> (node: PromptNode, order: Int)? {
        let relative = relativePath(of: url, in: root)
        let text: String
        let card: WorkflowCard
        let body: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
            let document = try FrontmatterParser.parse(text)
            (card, _, _) = try WorkflowCardParser.make(from: document)
            body = document.body
        } catch let error as FrontmatterError {
            result.issues.append("\(relative):\(error.line): \(error.message) — file skipped")
            return nil
        } catch {
            result.issues.append("\(relative): \(error.localizedDescription) — file skipped")
            return nil
        }

        let meta = card.library
        var uuid = meta?.uuid
        var needsRewrite = false
        if let existing = uuid, seenUUIDs.contains(existing) {
            result.issues.append("\(relative): duplicate uuid \(existing.uuidString) — assigned a fresh one")
            uuid = nil
        }
        if uuid == nil {
            uuid = UUID()
            needsRewrite = true
        }
        seenUUIDs.insert(uuid!)

        let stem = url.deletingPathExtension().lastPathComponent
        let node = PromptNode(
            id: uuid!,
            name: meta?.title ?? fallbackName(forStem: stem),
            mnemonicKey: meta?.mnemonic ?? "?",
            nodeType: .prompt,
            systemPrompt: body,
            children: nil,
            mnemonicModifiers: meta?.mnemonicModifiers,
            providerID: meta?.providerID,
            displayMode: meta?.displayMode,
            quickPasteShortcut: meta?.shortcutInline,
            openRunShortcut: meta?.shortcutPopup,
            selectAllBeforeCapture: meta?.selectAll
        )
        result.parsedRelativePaths.insert(relative)

        let order = meta?.order ?? Int.max
        if needsRewrite {
            let id = workflowID(forRelativePath: relative)
            let content = promptCard(node, id: id, order: meta?.order)
            result.pendingWrites.append((url: url, content: content))
        }
        return (node, order)
    }

    private static func loadFolder(
        at url: URL,
        root: URL,
        seenUUIDs: inout Set<UUID>,
        result: inout LoadResult
    ) -> (node: PromptNode, order: Int) {
        let metaURL = url.appendingPathComponent(folderFileName)
        let relativeMeta = relativePath(of: metaURL, in: root)

        var uuid: UUID?
        var title: String?
        var mnemonic: String?
        var modifiers: MnemonicModifiers?
        var order: Int?
        var metaParseable = !FileManager.default.fileExists(atPath: metaURL.path)
        var needsRewrite = !FileManager.default.fileExists(atPath: metaURL.path)

        if FileManager.default.fileExists(atPath: metaURL.path) {
            do {
                let text = try String(contentsOf: metaURL, encoding: .utf8)
                let document = try FrontmatterParser.parse(text)
                metaParseable = true
                if case .scalar(let raw)? = document.fields["uuid"] {
                    if let parsed = UUID(uuidString: raw) {
                        uuid = parsed
                    } else {
                        result.issues.append("\(relativeMeta): invalid uuid '\(raw)' — assigned a fresh one")
                    }
                }
                if case .scalar(let raw)? = document.fields["title"] { title = raw }
                if case .scalar(let raw)? = document.fields["mnemonic"] { mnemonic = raw }
                if case .scalar(let raw)? = document.fields["order"], let parsed = Int(raw) { order = parsed }
                if case .list(let raw)? = document.fields["mnemonic_modifiers"] {
                    var set: MnemonicModifiers = []
                    for item in raw {
                        switch item {
                        case "shift": set.insert(.shift)
                        case "control": set.insert(.control)
                        case "option": set.insert(.option)
                        case "command": set.insert(.command)
                        default:
                            result.issues.append("\(relativeMeta): unknown mnemonic modifier '\(item)' — ignored")
                        }
                    }
                    modifiers = set
                }
                result.parsedRelativePaths.insert(relativeMeta)
            } catch {
                // The user's hand edit stays on disk untouched; the folder
                // gets a session-local identity until the file is fixed or
                // the next mutation rewrites the canonical form.
                result.issues.append("\(relativeMeta): \(error.localizedDescription) — using defaults")
            }
        }

        if let existing = uuid, seenUUIDs.contains(existing) {
            result.issues.append("\(relativeMeta): duplicate uuid \(existing.uuidString) — assigned a fresh one")
            uuid = nil
        }
        if uuid == nil {
            uuid = UUID()
            if metaParseable { needsRewrite = true }
        }
        seenUUIDs.insert(uuid!)

        let children = loadChildren(of: url, root: root, seenUUIDs: &seenUUIDs, result: &result)
        let node = PromptNode(
            id: uuid!,
            name: title ?? fallbackName(forStem: url.lastPathComponent),
            mnemonicKey: mnemonic ?? "?",
            nodeType: .folder,
            systemPrompt: nil,
            children: children,
            mnemonicModifiers: modifiers
        )
        if needsRewrite {
            result.pendingWrites.append((url: metaURL, content: folderCard(node, order: order)))
            result.parsedRelativePaths.insert(relativeMeta)
        }
        return (node, order ?? Int.max)
    }

    // MARK: - Serialize

    /// The complete desired file set for a tree: relative path → file content.
    /// Deterministic — same tree, same bytes — which is what makes the diff
    /// sync and the migration idempotent.
    static func fileSet(for nodes: [PromptNode]) -> [String: String] {
        var result: [String: String] = [:]
        addEntries(for: nodes, pathComponents: [], into: &result)
        return result
    }

    private static func addEntries(
        for nodes: [PromptNode],
        pathComponents: [String],
        into result: inout [String: String]
    ) {
        var taken = Set<String>()
        for (index, node) in nodes.enumerated() {
            let slug = unique(slug(node.name), in: &taken)
            if node.isFolder {
                let dir = pathComponents + [slug]
                result[(dir + [folderFileName]).joined(separator: "/")] = folderCard(node, order: index)
                addEntries(for: node.children ?? [], pathComponents: dir, into: &result)
            } else {
                let id = (["library"] + pathComponents + [slug]).joined(separator: ".")
                let path = (pathComponents + [slug + ".md"]).joined(separator: "/")
                result[path] = promptCard(node, id: id, order: index)
            }
        }
    }

    static func promptCard(_ node: PromptNode, id: String, order: Int?) -> String {
        var lines = ["---"]
        lines.append("id: \(id)")
        lines.append("kind: workflow")
        lines.append("mode: direct")
        lines.append("version: 1")
        lines.append("uuid: \(node.id.uuidString)")
        lines.append("title: \(quote(node.name))")
        if let order { lines.append("order: \(order)") }
        if node.mnemonicKey != "?" {
            lines.append("mnemonic: \(quote(node.mnemonicKey))")
        }
        if let modifiers = node.mnemonicModifiers {
            lines.append("mnemonic_modifiers: [\(modifierNames(modifiers).joined(separator: ", "))]")
        }
        if let provider = node.providerID {
            lines.append("provider: \(provider.uuidString)")
        }
        if let mode = node.displayMode {
            lines.append("display_mode: \(mode.rawValue)")
        }
        if let selectAll = node.selectAllBeforeCapture {
            lines.append("select_all: \(selectAll)")
        }
        if let shortcut = node.quickPasteShortcut {
            lines.append("shortcut_inline: {key: \(shortcut.carbonKeyCode), modifiers: \(shortcut.carbonModifiers)}")
        }
        if let shortcut = node.openRunShortcut {
            lines.append("shortcut_popup: {key: \(shortcut.carbonKeyCode), modifiers: \(shortcut.carbonModifiers)}")
        }
        lines.append("---")
        let body = (node.systemPrompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return lines.joined(separator: "\n") + "\n" + (body.isEmpty ? "" : body + "\n")
    }

    static func folderCard(_ node: PromptNode, order: Int?) -> String {
        var lines = ["---"]
        lines.append("uuid: \(node.id.uuidString)")
        lines.append("title: \(quote(node.name))")
        if let order { lines.append("order: \(order)") }
        if node.mnemonicKey != "?" {
            lines.append("mnemonic: \(quote(node.mnemonicKey))")
        }
        if let modifiers = node.mnemonicModifiers {
            lines.append("mnemonic_modifiers: [\(modifierNames(modifiers).joined(separator: ", "))]")
        }
        lines.append("---")
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Diff sync

    /// Brings the directory in line with `nodes`: writes files whose content
    /// changed (leaving identical files untouched, so mtimes stay stable),
    /// deletes files that belonged to the previous model and no longer exist,
    /// and prunes directories that became empty. Returns the new owned set.
    static func sync(
        nodes: [PromptNode],
        previousPaths: Set<String>,
        in directory: URL
    ) -> Set<String> {
        let fm = FileManager.default
        let desired = fileSet(for: nodes)
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)

        for (relative, content) in desired {
            let url = directory.appendingPathComponent(relative)
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? String(contentsOf: url, encoding: .utf8)) != content {
                try? content.write(to: url, atomically: true, encoding: .utf8)
            }
        }

        for relative in previousPaths.subtracting(desired.keys) {
            try? fm.removeItem(at: directory.appendingPathComponent(relative))
        }
        pruneEmptyDirectories(in: directory)
        return Set(desired.keys)
    }

    private static func pruneEmptyDirectories(in directory: URL) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for url in entries {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDirectory else { continue }
            pruneEmptyDirectories(in: url)
            if let contents = try? fm.contentsOfDirectory(atPath: url.path), contents.isEmpty {
                try? fm.removeItem(at: url)
            }
        }
    }

    // MARK: - Signature (mtime-based hot reload, same pattern as WorkflowStore)

    static func signature(of directory: URL) -> [String: Date] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [:] }
        var signature: [String: Date] = [:]
        for case let url as URL in enumerator where url.pathExtension == "md" {
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            signature[url.path] = mtime
        }
        return signature
    }

    // MARK: - Naming

    /// Filename slug for a node name: lowercase ASCII letters/digits with
    /// dashes, e.g. "TL;DR" → "tl-dr". Deliberately not transliterated —
    /// fully non-ASCII names fall back to "item" and get uniquified.
    static func slug(_ name: String) -> String {
        var out = ""
        var pendingDash = false
        for scalar in name.lowercased().unicodeScalars {
            let isAlnum = (scalar.value >= 97 && scalar.value <= 122)
                || (scalar.value >= 48 && scalar.value <= 57)
            if isAlnum {
                if pendingDash && !out.isEmpty { out.append("-") }
                pendingDash = false
                out.unicodeScalars.append(scalar)
            } else {
                pendingDash = true
            }
        }
        return out.isEmpty ? fallbackSlug : out
    }

    private static func unique(_ base: String, in taken: inout Set<String>) -> String {
        if taken.insert(base).inserted { return base }
        var counter = 2
        while !taken.insert("\(base)-\(counter)").inserted { counter += 1 }
        return "\(base)-\(counter)"
    }

    /// Display-name fallback when a card has no `title:` — "tl-dr" → "Tl Dr".
    static func fallbackName(forStem stem: String) -> String {
        let words = stem.split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
        return words.isEmpty ? stem : words.joined(separator: " ")
    }

    /// Workflow id for a card at `relative` (used for uuid write-backs, where
    /// the file keeps its hand-given location): path components slugged and
    /// joined under the `library.` namespace.
    static func workflowID(forRelativePath relative: String) -> String {
        var components = relative.split(separator: "/").map(String.init)
        if let last = components.last, last.hasSuffix(".md") {
            components[components.count - 1] = String(last.dropLast(3))
        }
        return (["library"] + components.map { slug($0) }).joined(separator: ".")
    }

    private static func relativePath(of url: URL, in root: URL) -> String {
        let rootPath = root.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(rootPath) ? String(path.dropFirst(rootPath.count)) : path
    }

    private static func quote(_ text: String) -> String {
        var out = ""
        for character in text {
            switch character {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            default: out.append(character)
            }
        }
        return "\"\(out)\""
    }

    private static func modifierNames(_ modifiers: MnemonicModifiers) -> [String] {
        var names: [String] = []
        if modifiers.contains(.shift) { names.append("shift") }
        if modifiers.contains(.control) { names.append("control") }
        if modifiers.contains(.option) { names.append("option") }
        if modifiers.contains(.command) { names.append("command") }
        return names
    }
}
