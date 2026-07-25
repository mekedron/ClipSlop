import Foundation
import Testing
@testable import ClipSlop

// MARK: - Card schema (§7.3 library keys)

@Suite("Library card schema")
struct LibraryCardSchemaTests {
    private func card(_ text: String) throws -> WorkflowCard {
        try WorkflowCardParser.make(from: FrontmatterParser.parse(text)).card
    }

    @Test func parsesFullLibraryCard() throws {
        let parsed = try card("""
        ---
        id: library.format.fix-grammar
        kind: workflow
        mode: direct
        version: 1
        uuid: 11111111-2222-3333-4444-555555555555
        title: "Fix Grammar"
        order: 2
        mnemonic: "g"
        mnemonic_modifiers: [shift, command]
        provider: AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE
        display_mode: markdown
        select_all: true
        shortcut_inline: {key: 5, modifiers: 4352}
        shortcut_popup: {key: 5, modifiers: 6400}
        ---
        Fix all grammar mistakes.
        """)
        let meta = try #require(parsed.library)
        #expect(meta.uuid == UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        #expect(meta.title == "Fix Grammar")
        #expect(meta.order == 2)
        #expect(meta.mnemonic == "g")
        #expect(meta.mnemonicModifiers == [.shift, .command])
        #expect(meta.providerID == UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
        #expect(meta.displayMode == .markdown)
        #expect(meta.selectAll == true)
        #expect(meta.shortcutInline == ShortcutConfig(carbonKeyCode: 5, carbonModifiers: 4352))
        #expect(meta.shortcutPopup == ShortcutConfig(carbonKeyCode: 5, carbonModifiers: 6400))
        // No `when:` — never routed.
        #expect(parsed.when == nil)
    }

    @Test func cardWithoutLibraryKeysHasNilMeta() throws {
        let parsed = try card("""
        ---
        id: base.reply
        kind: workflow
        mode: direct
        version: 1
        summary: "Reply"
        intents: [reply]
        when:
          field.state: [empty]
        ---
        """)
        #expect(parsed.library == nil)
    }

    private func invalid(_ frontmatterLine: String) -> String {
        """
        ---
        id: library.x
        kind: workflow
        mode: direct
        version: 1
        \(frontmatterLine)
        ---
        """
    }

    @Test(arguments: [
        "uuid: not-a-uuid",
        "provider: 1234",
        "order: soon",
        "display_mode: fancy",
        "mnemonic_modifiers: [hyper]",
        "select_all: yes",
        "shortcut_inline: cmd+shift+g",
        "shortcut_inline: {key: 5}",
        "shortcut_popup: {key: five, modifiers: 4352}",
    ])
    func invalidLibraryValuesFail(_ line: String) {
        #expect(throws: FrontmatterError.self) {
            _ = try card(invalid(line))
        }
    }
}

// MARK: - Routing exclusion

@Suite("When-less cards never route")
struct WhenLessRoutingTests {
    @Test func routerExcludesWhenLessCards() {
        let library = MagicTestSupport.makeWorkflow(id: "library.fix-grammar", when: nil)
        let base = MagicTestSupport.makeWorkflow(
            id: "base.reply",
            intents: ["reply"],
            when: WhenPredicate(apps: nil, urlPattern: nil, fieldRoles: nil, fieldStates: [.empty], selectionClasses: nil)
        )
        let catalog = WorkflowCatalog(workflows: [library, base], loadedAt: Date())
        let decision = EngineRouter.route(
            catalog: catalog,
            snapshot: MagicTestSupport.makeSnapshot(),
            classification: nil
        )
        #expect(decision.counted.map(\.id) == ["base.reply"])
        #expect(!decision.alternatives.contains { $0.id == "library.fix-grammar" })
        // Still invocable by id — present in the catalog.
        #expect(catalog.workflow(id: "library.fix-grammar") != nil)
    }

    @Test func catalogOfOnlyWhenLessCardsRoutesNothing() {
        let catalog = WorkflowCatalog(
            workflows: [MagicTestSupport.makeWorkflow(id: "library.a", when: nil)],
            loadedAt: Date()
        )
        let decision = EngineRouter.route(
            catalog: catalog,
            snapshot: MagicTestSupport.makeSnapshot(),
            classification: nil
        )
        #expect(decision.counted.isEmpty)
        #expect(decision.alternatives.isEmpty)
        #expect(decision.chipCandidates.isEmpty)
    }
}

// MARK: - Store fixtures

@MainActor
private enum StoreFixture {
    static func tempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipslop-library-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func makeStore(
        root: URL,
        useDefaults: Bool,
        defaults: @escaping () -> [PromptNode] = PromptStore.loadBundledDefaults,
        setDefaultsActive: ((Bool) -> Void)? = nil,
        stamp: StampBox? = nil
    ) -> PromptStore {
        PromptStore(
            libraryDirectory: root.appendingPathComponent("workflows/library"),
            mirrorFileURL: root.appendingPathComponent("prompts.json"),
            useDefaultPrompts: useDefaults,
            defaults: defaults,
            setDefaultsActive: setDefaultsActive,
            readDefaultsStamp: { stamp?.value },
            writeDefaultsStamp: { stamp?.value = $0 }
        )
    }

    /// Stands in for the `promptLibraryDefaultsStamp` setting across two store
    /// instances without touching UserDefaults.
    final class StampBox {
        var value: String?
    }

    static let providerID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

    /// A pre-canonical tree exercising every persisted attribute.
    static func customTree() -> [PromptNode] {
        [
            PromptNode(
                id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                name: "Fix Grammar",
                mnemonicKey: "g",
                nodeType: .prompt,
                systemPrompt: "Fix all grammar mistakes.",
                mnemonicModifiers: [.shift],
                providerID: providerID,
                displayMode: .markdown,
                quickPasteShortcut: ShortcutConfig(carbonKeyCode: 5, carbonModifiers: 4352),
                openRunShortcut: ShortcutConfig(carbonKeyCode: 5, carbonModifiers: 6400),
                selectAllBeforeCapture: true
            ),
            PromptNode(
                id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
                name: "Deep Folder",
                mnemonicKey: "d",
                nodeType: .folder,
                children: [
                    PromptNode(
                        id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                        name: "TL;DR",
                        mnemonicKey: "t",
                        nodeType: .prompt,
                        systemPrompt: "Summarize in one line."
                    ),
                    PromptNode(
                        id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
                        name: "Ответ по-русски",
                        mnemonicKey: "r",
                        nodeType: .prompt,
                        systemPrompt: "Ответь по-русски."
                    ),
                ]
            ),
        ]
    }

    static func fileSnapshot(of directory: URL) -> [String: String] {
        var snapshot: [String: String] = [:]
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return snapshot }
        for case let url as URL in enumerator where url.pathExtension == "md" {
            snapshot[url.path] = try? String(contentsOf: url, encoding: .utf8)
        }
        return snapshot
    }
}

// MARK: - Round-trip

@MainActor
@Suite("Library store round-trip")
struct PromptLibraryRoundTripTests {

    @Test func defaultLibraryRoundTripsThroughMarkdown() throws {
        let defaults = PromptStore.loadBundledDefaults()
        #expect(!defaults.isEmpty)

        let root = try StoreFixture.tempRoot()
        let store = StoreFixture.makeStore(root: root, useDefaults: true)
        #expect(store.prompts == PromptStore.canonicalize(defaults))

        // A fresh instance reads only what is on disk — order, mnemonics,
        // modifiers, shortcuts, provider overrides, display modes, and UUIDs
        // must all survive markdown serialization.
        let reloaded = StoreFixture.makeStore(root: root, useDefaults: false)
        #expect(reloaded.prompts == store.prompts)

        // Spot-check the layout: folders are directories with _folder.md,
        // prompts are slug-named cards.
        let library = root.appendingPathComponent("workflows/library")
        #expect(FileManager.default.fileExists(
            atPath: library.appendingPathComponent("format/_folder.md").path
        ))
        let fixGrammar = library.appendingPathComponent("format/fix-grammar.md")
        let content = try String(contentsOf: fixGrammar, encoding: .utf8)
        #expect(content.contains("id: library.format.fix-grammar"))
        #expect(content.contains("shortcut_inline: {key: 5, modifiers: 4352}"))
    }

    @Test func libraryLoadsThroughWorkflowStoreWithoutErrors() throws {
        // One tree, one parser: the engine's own WorkflowStore must swallow
        // the whole library — cards resolvable by id, _folder.md skipped.
        let root = try StoreFixture.tempRoot()
        _ = StoreFixture.makeStore(root: root, useDefaults: true)

        let (catalog, errors) = WorkflowStore.load(from: root.appendingPathComponent("workflows"))
        #expect(errors.filter { !$0.isWarning }.isEmpty, "library load errors: \(errors.map(\.message))")

        let fixGrammar = try #require(catalog.workflow(id: "library.format.fix-grammar"))
        #expect(fixGrammar.card.when == nil)
        #expect(fixGrammar.card.library?.uuid != nil)
        #expect(!fixGrammar.body.isEmpty)

        // And none of them routes anywhere.
        let decision = EngineRouter.route(
            catalog: catalog,
            snapshot: MagicTestSupport.makeSnapshot(),
            classification: nil
        )
        #expect(!decision.counted.contains { $0.id.hasPrefix("library.") })
        #expect(!decision.alternatives.contains { $0.id.hasPrefix("library.") })
    }

    @Test func folderMetadataRoundTripsViaFolderCard() throws {
        let root = try StoreFixture.tempRoot()
        let mirror = root.appendingPathComponent("prompts.json")
        try JSONEncoder.pretty.encode(StoreFixture.customTree()).write(to: mirror)

        let store = StoreFixture.makeStore(root: root, useDefaults: false)
        let folderMeta = root.appendingPathComponent("workflows/library/deep-folder/_folder.md")
        let content = try String(contentsOf: folderMeta, encoding: .utf8)
        #expect(content.contains("title: \"Deep Folder\""))
        #expect(content.contains("mnemonic: \"d\""))
        #expect(content.contains("uuid: 33333333-3333-3333-3333-333333333333"))
        #expect(content.contains("order: 1"))

        let reloaded = StoreFixture.makeStore(root: root, useDefaults: false)
        #expect(reloaded.prompts == store.prompts)
        let folder = try #require(reloaded.findNode(byID: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!))
        #expect(folder.name == "Deep Folder")
        #expect(folder.children?.map(\.name) == ["TL;DR", "Ответ по-русски"])
    }
}

// MARK: - Migration

@MainActor
@Suite("§7.3 migration")
struct PromptLibraryMigrationTests {

    @Test func firstLaunchMaterializesFromPromptsJSONWithBackup() throws {
        let root = try StoreFixture.tempRoot()
        let mirror = root.appendingPathComponent("prompts.json")
        let original = try JSONEncoder.pretty.encode(StoreFixture.customTree())
        try original.write(to: mirror)

        let store = StoreFixture.makeStore(root: root, useDefaults: false)
        #expect(store.prompts == StoreFixture.customTree())

        // Backup written once, byte-identical to the pre-unification file.
        let backup = URL(fileURLWithPath: mirror.path + ".pre-unification.bak")
        #expect(try Data(contentsOf: backup) == original)

        // Mirror regenerated from the tree — canonical trees are byte-stable
        // through the shared pretty encoder.
        #expect(try Data(contentsOf: mirror) == original)
    }

    @Test func secondLaunchIsANoOp() throws {
        let root = try StoreFixture.tempRoot()
        let mirror = root.appendingPathComponent("prompts.json")
        try JSONEncoder.pretty.encode(StoreFixture.customTree()).write(to: mirror)

        let first = StoreFixture.makeStore(root: root, useDefaults: false)
        let library = root.appendingPathComponent("workflows/library")
        let filesBefore = StoreFixture.fileSnapshot(of: library)
        let signatureBefore = PromptLibraryFiles.signature(of: library)
        let mirrorBefore = try Data(contentsOf: mirror)

        let second = StoreFixture.makeStore(root: root, useDefaults: false)
        #expect(second.prompts == first.prompts)
        #expect(StoreFixture.fileSnapshot(of: library) == filesBefore)
        // Mtimes untouched — the diff sync skipped every identical file.
        #expect(PromptLibraryFiles.signature(of: library) == signatureBefore)
        #expect(try Data(contentsOf: mirror) == mirrorBefore)
    }

    /// While `useDefaultPrompts` is true the bundled set is authoritative on
    /// every launch — but a hand edit of the markdown never goes through the UI
    /// and so never clears the flag. Bootstrap used to restore the defaults
    /// over those edits on every single launch.
    @Test func handEditedLibrarySurvivesWhileDefaultsAreActive() throws {
        let root = try StoreFixture.tempRoot()
        let stamp = StoreFixture.StampBox()
        _ = StoreFixture.makeStore(root: root, useDefaults: true, stamp: stamp)
        #expect(stamp.value != nil)

        let card = root.appendingPathComponent("workflows/library/format/fix-grammar.md")
        var text = try String(contentsOf: card, encoding: .utf8)
        text += "\n- HAND-EDIT-MARKER: keep this line.\n"
        try text.write(to: card, atomically: true, encoding: .utf8)

        var defaultsStillActive = true
        let reopened = StoreFixture.makeStore(
            root: root, useDefaults: true,
            setDefaultsActive: { defaultsStillActive = $0 }, stamp: stamp
        )
        #expect(try String(contentsOf: card, encoding: .utf8).contains("HAND-EDIT-MARKER"))
        #expect(reopened.allPromptNodes().contains { $0.systemPrompt?.contains("HAND-EDIT-MARKER") == true })
        // And the edit is recognized as the customization it is, so the next
        // launch does not have to re-derive it.
        #expect(!defaultsStillActive)
    }

    /// The same edit, seen by the hot-reload path instead of by bootstrap.
    /// Republishing the new tree while leaving `useDefaultPrompts` set made the
    /// library look pristine to the *next* launch — and if that launch shipped a
    /// different bundled-default stamp, bootstrap's update branch overwrote the
    /// hand edit this reload had already observed.
    @Test func hotReloadedEditMarksTheLibraryCustomized() throws {
        let root = try StoreFixture.tempRoot()
        let stamp = StoreFixture.StampBox()
        var defaultsActive = true
        let store = StoreFixture.makeStore(
            root: root, useDefaults: true,
            setDefaultsActive: { defaultsActive = $0 }, stamp: stamp
        )
        #expect(defaultsActive)

        try """
        ---
        id: library.hand-made
        kind: workflow
        mode: direct
        version: 1
        uuid: 77777777-7777-7777-7777-777777777777
        title: "Hand Made"
        mnemonic: "h"
        ---
        Written in a text editor.
        """.write(
            to: root.appendingPathComponent("workflows/library/hand-made.md"),
            atomically: true, encoding: .utf8
        )

        store.reloadIfChanged()
        #expect(store.findNode(byID: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!) != nil)
        #expect(!defaultsActive)

        // The payoff: an app update shipping a different bundled set no longer
        // discards the card on the launch after the reload that saw it.
        let shipped = [PromptNode(
            id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
            name: "Shipped In An Update", mnemonicKey: "u", nodeType: .prompt,
            systemPrompt: "Brand new default."
        )]
        let relaunched = StoreFixture.makeStore(
            root: root, useDefaults: defaultsActive, defaults: { shipped }, stamp: stamp
        )
        #expect(relaunched.findNode(byID: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!) != nil)
    }

    /// The other half of the same branch: a genuinely new bundled set (an app
    /// update) still refreshes the tree.
    @Test func newBundledDefaultsStillRefreshTheLibrary() throws {
        let root = try StoreFixture.tempRoot()
        let stamp = StoreFixture.StampBox()
        _ = StoreFixture.makeStore(root: root, useDefaults: true, stamp: stamp)
        let firstStamp = stamp.value

        let shipped = [PromptNode(
            id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
            name: "Shipped In An Update", mnemonicKey: "u", nodeType: .prompt,
            systemPrompt: "Brand new default."
        )]
        let refreshed = StoreFixture.makeStore(
            root: root, useDefaults: true, defaults: { shipped }, stamp: stamp
        )
        #expect(refreshed.prompts == PromptStore.canonicalize(shipped))
        #expect(stamp.value != firstStamp)
    }

    @Test func uuidsAreStableAcrossReloadAndMutation() throws {
        let root = try StoreFixture.tempRoot()
        let mirror = root.appendingPathComponent("prompts.json")
        try JSONEncoder.pretty.encode(StoreFixture.customTree()).write(to: mirror)

        let store = StoreFixture.makeStore(root: root, useDefaults: false)
        let added = PromptNode(
            name: "New Prompt", mnemonicKey: "n", nodeType: .prompt, systemPrompt: "Do the thing."
        )
        store.addNode(added, toFolderWithID: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!)
        let idsBefore = store.allPromptIDs()

        let reloaded = StoreFixture.makeStore(root: root, useDefaults: false)
        #expect(reloaded.allPromptIDs() == idsBefore)
        #expect(reloaded.findNode(byID: added.id)?.name == "New Prompt")
    }
}

// MARK: - Mutations & the mirror

@MainActor
@Suite("Library mutations")
struct PromptLibraryMutationTests {

    private func makeStore() throws -> (store: PromptStore, root: URL) {
        let root = try StoreFixture.tempRoot()
        try JSONEncoder.pretty.encode(StoreFixture.customTree())
            .write(to: root.appendingPathComponent("prompts.json"))
        return (StoreFixture.makeStore(root: root, useDefaults: false), root)
    }

    @Test func mutationRegeneratesTheMirrorAndFiresUpload() throws {
        let (store, root) = try makeStore()
        var uploaded: Data?
        store.onPromptsChanged = { uploaded = $0 }

        var node = try #require(store.findNode(byID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!))
        node.systemPrompt = "Fix all grammar and spelling mistakes."
        store.updateNode(node)

        let mirrorData = try Data(contentsOf: root.appendingPathComponent("prompts.json"))
        #expect(uploaded == mirrorData)
        let decoded = try JSONDecoder().decode([PromptNode].self, from: mirrorData)
        #expect(decoded == store.prompts)

        // The card body followed.
        let file = root.appendingPathComponent("workflows/library/fix-grammar.md")
        #expect(try String(contentsOf: file, encoding: .utf8)
            .contains("Fix all grammar and spelling mistakes."))
    }

    /// A card that fails to parse is skipped, so the tree in memory is a
    /// PARTIAL view. Publishing it as the mirror uploads that gap to iCloud,
    /// and the receiving Mac's `replaceFromSync` → `persist()` deletes the
    /// markdown for every card the mirror is missing.
    @Test func unparseableCardBlocksMirrorPublication() throws {
        let (store, root) = try makeStore()
        let mirrorURL = root.appendingPathComponent("prompts.json")
        let mirrorBefore = try Data(contentsOf: mirrorURL)
        var uploaded: Data?
        store.onPromptsChanged = { uploaded = $0 }

        let card = root.appendingPathComponent("workflows/library/fix-grammar.md")
        try "---\nid: broken\nsummary: \"unterminated\n---\nBody.\n"
            .write(to: card, atomically: true, encoding: .utf8)
        store.reloadIfChanged()

        // The card is gone from the model — that part is the documented
        // skip-don't-destroy behaviour.
        #expect(!store.allPromptNodes().contains { $0.name == "Fix Grammar" })
        // But nothing was published: no upload, and the mirror still holds it.
        #expect(uploaded == nil)
        #expect(try Data(contentsOf: mirrorURL) == mirrorBefore)
        #expect(store.unparsedFiles == ["fix-grammar.md"])
    }

    /// …but the tree's own consumers still follow the change.
    ///
    /// Per-prompt hotkey registration reads `prompts`, not the mirror, so the
    /// reason the mirror is withheld does not reach it. Holding it back anyway
    /// left a just-assigned shortcut unregistered — and a just-removed one
    /// still firing — until the next launch, from one typo in an unrelated
    /// card, with nothing on screen connecting the two.
    @Test func unparseableCardStillLetsTheTreeConsumersFollow() throws {
        let (store, root) = try makeStore()
        let card = root.appendingPathComponent("workflows/library/fix-grammar.md")
        try "---\nid: broken\nsummary: \"unterminated\n---\nBody.\n"
            .write(to: card, atomically: true, encoding: .utf8)
        store.reloadIfChanged()
        #expect(store.unparsedFiles == ["fix-grammar.md"])

        var uploaded: Data?
        var treeChanges = 0
        store.onPromptsChanged = { uploaded = $0 }
        store.onLibraryChanged = { treeChanges += 1 }

        store.addNode(PromptNode(
            id: UUID(), name: "New Prompt", mnemonicKey: "n",
            nodeType: .prompt, systemPrompt: "Do the thing."
        ))

        #expect(treeChanges == 1)
        #expect(uploaded == nil, "the partial mirror must still not be uploaded")
    }

    @Test func renameMovesTheFileAndKeepsTheUUID() throws {
        let (store, root) = try makeStore()
        let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        var node = try #require(store.findNode(byID: id))
        node.name = "Grammar Police"
        store.updateNode(node)

        let library = root.appendingPathComponent("workflows/library")
        #expect(!FileManager.default.fileExists(atPath: library.appendingPathComponent("fix-grammar.md").path))
        #expect(FileManager.default.fileExists(atPath: library.appendingPathComponent("grammar-police.md").path))

        let reloaded = StoreFixture.makeStore(root: root, useDefaults: false)
        #expect(reloaded.findNode(byID: id)?.name == "Grammar Police")
    }

    @Test func removingAFolderDeletesItsDirectory() throws {
        let (store, root) = try makeStore()
        store.removeNode(withID: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!)
        let dir = root.appendingPathComponent("workflows/library/deep-folder")
        #expect(!FileManager.default.fileExists(atPath: dir.path))
        #expect(store.prompts.count == 1)
    }

    @Test func replaceFromSyncWritesTreeWithoutEcho() throws {
        let (store, root) = try makeStore()
        var uploads = 0
        store.onPromptsChanged = { _ in uploads += 1 }

        var remote = StoreFixture.customTree()
        remote[0].systemPrompt = "Remote-edited grammar prompt."
        remote.append(PromptNode(
            id: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!,
            name: "Remote Prompt", mnemonicKey: "x", nodeType: .prompt, systemPrompt: "From the other Mac."
        ))
        store.replaceFromSync(remote)

        #expect(uploads == 0, "applyRemote must not echo back to the cloud")
        #expect(store.prompts == remote)
        let file = root.appendingPathComponent("workflows/library/remote-prompt.md")
        #expect(try String(contentsOf: file, encoding: .utf8).contains("From the other Mac."))
    }

    @Test func externalEditIsPickedUpByReloadIfChanged() throws {
        let (store, root) = try makeStore()
        var uploaded: Data?
        store.onPromptsChanged = { uploaded = $0 }

        // Hand-write a card, uuid included — the file is authoritative.
        let handWritten = """
        ---
        id: library.hand-made
        kind: workflow
        mode: direct
        version: 1
        uuid: 77777777-7777-7777-7777-777777777777
        title: "Hand Made"
        mnemonic: "h"
        ---
        Written in a text editor.
        """
        try handWritten.write(
            to: root.appendingPathComponent("workflows/library/hand-made.md"),
            atomically: true, encoding: .utf8
        )

        store.reloadIfChanged()
        let node = try #require(store.findNode(byID: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!))
        #expect(node.name == "Hand Made")
        #expect(node.systemPrompt == "Written in a text editor.")
        // The mirror (and therefore iCloud) followed the external edit.
        let decoded = try JSONDecoder().decode([PromptNode].self, from: try #require(uploaded))
        #expect(decoded.contains { $0.id == node.id })
    }

    @Test func handWrittenCardWithoutUUIDGetsOnePersisted() throws {
        let (store, root) = try makeStore()
        let url = root.appendingPathComponent("workflows/library/no-uuid.md")
        try """
        ---
        id: library.no-uuid
        kind: workflow
        mode: direct
        version: 1
        title: "No UUID Yet"
        ---
        Body.
        """.write(to: url, atomically: true, encoding: .utf8)

        store.reloadIfChanged()
        let node = try #require(store.allPromptNodes().first { $0.name == "No UUID Yet" })
        // The uuid was written back into the file, so it survives reloads.
        #expect(try String(contentsOf: url, encoding: .utf8).contains("uuid: \(node.id.uuidString)"))
        let reloaded = StoreFixture.makeStore(root: root, useDefaults: false)
        #expect(reloaded.findNode(byID: node.id)?.name == "No UUID Yet")
    }
}
