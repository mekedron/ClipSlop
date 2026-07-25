import Foundation
import Testing
@testable import ClipSlop

/// Every test runs against a throwaway engine root — the executor's `root:`
/// parameter exists precisely so nothing here can touch the real
/// `~/.clipslop` (or `-dev`) tree.
@MainActor
@Suite("Engine tool executor")
struct EngineToolExecutorTests {

    // MARK: - Fixture

    private static let anthropicID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private static let cliID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    /// Builds a minimal but complete engine tree in a temp directory.
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("engine-tools-\(UUID().uuidString)")
        for sub in ["core", "workflows/base", "logs"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(sub), withIntermediateDirectories: true
            )
        }

        try write(root, "workflows/base/base.generation.md", """
        ---
        id: base.generation
        kind: workflow
        mode: direct
        version: 1
        abstract: true
        intents: [write]
        ---
        ## Rules
        - Be brief.
        """)
        try write(root, "workflows/base/base.reply.md", """
        ---
        id: base.reply
        kind: workflow
        mode: direct
        version: 1
        extends: base.generation
        summary: "Reply"
        intents: [reply]
        ---
        Body.
        """)
        try write(root, "workflows/comment.social.md", """
        ---
        id: comment.social
        kind: workflow
        mode: direct
        version: 1
        extends: base.generation
        priority: 70
        summary: "Comment"
        intents: [comment]
        when:
          app: [com.google.Chrome]
        ---
        Body.
        """)
        try write(root, "config.yaml", """
        ---
        # Engine tuning — comment must survive edits.
        web_call_budget: 900
        toast_dismiss_seconds: 8
        no_cloud: []
        ---
        """)
        try write(root, "providers.yaml", ProvidersFile.serialize([
            AIProviderConfig(
                id: Self.anthropicID, name: "Claude", providerType: .anthropic,
                modelID: "claude-test", isDefault: true
            ),
            AIProviderConfig(
                id: Self.cliID, name: "Local CLI", providerType: .cliTool,
                modelID: "llama"
            ),
        ]))
        try write(root, "core/constraints.md", "# Hard rules\n")
        return root
    }

    private func write(_ root: URL, _ relative: String, _ content: String) throws {
        try content.write(
            to: root.appendingPathComponent(relative), atomically: true, encoding: .utf8
        )
    }

    private func call(_ name: String, _ args: [String: Any] = [:]) -> ToolCallRequest {
        let data = try! JSONSerialization.data(withJSONObject: args)
        return ToolCallRequest(id: "t1", name: name, argumentsJSON: String(data: data, encoding: .utf8)!)
    }

    private func executor(_ root: URL) -> EngineToolExecutor {
        EngineToolExecutor(root: root)
    }

    // MARK: - Path confinement

    @Test func rejectsPathsOutsideTheEngineTree() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = executor(root)

        for path in ["../outside.md", "/etc/passwd", "~/x.md", "workflows/../../x.md"] {
            #expect(throws: ToolError.self) {
                try executor.perform(call("read_engine_file", ["path": path]))
            }
        }
        // Whitelist: logs and arbitrary top-level files are not readable
        // even though they are inside the tree.
        for path in ["logs/traces-2026-07-01.jsonl", "logs/debug/press.md", "random.txt"] {
            #expect(throws: ToolError.self) {
                try executor.perform(call("read_engine_file", ["path": path]))
            }
        }
    }

    @Test func writesAreConfinedToWorkflowPaths() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = executor(root)

        for path in ["core/identity.md", "config.yaml", "workflows/x.txt", "../w.md"] {
            #expect(throws: ToolError.self) {
                try executor.perform(call("write_workflow", ["path": path, "content": "x"]))
            }
        }
    }

    /// `standardizedFileURL` does not resolve symlinks, so a link planted
    /// inside the tree used to satisfy the prefix check and be followed.
    @Test func rejectsSymlinkedEntriesInsideTheTree() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("secret-\(UUID().uuidString).md")
        try "---\nid: secret\n---\nSecrets.".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }

        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("workflows/leak.md"), withDestinationURL: outside
        )
        // A link to a directory outside the tree hides the escape one level up.
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("workflows/elsewhere"),
            withDestinationURL: root.deletingLastPathComponent()
        )

        let executor = executor(root)
        #expect(throws: ToolError.self) {
            try executor.perform(call("read_engine_file", ["path": "workflows/leak.md"]))
        }
        #expect(throws: ToolError.self) {
            try executor.perform(call("read_engine_file", ["path": "workflows/elsewhere/x.md"]))
        }
        #expect(throws: ToolError.self) {
            try executor.perform(call("write_workflow", ["path": "workflows/leak.md", "content": "x"]))
        }
        // The file outside is untouched.
        #expect(try String(contentsOf: outside, encoding: .utf8).contains("Secrets."))
    }

    /// workflows/library/** is PromptStore's tree: writing it here bypasses the
    /// prompts.json mirror, the hotkey refresh, and the UUID bookkeeping.
    @Test func workflowWritesRejectThePromptLibrarySubtree() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = executor(root)

        for path in [
            "workflows/library/fix-grammar.md", "workflows/library/format/tldr.md",
            // Case variants name the same directory on the default
            // case-insensitive macOS volume, so the refusal has to be
            // case-insensitive too — an exact comparison would let a one-letter
            // spelling write into the library with none of its bookkeeping.
            "workflows/Library/fix-grammar.md", "workflows/LIBRARY/format/tldr.md",
        ] {
            #expect(throws: ToolError.self) {
                try executor.perform(call("write_workflow", ["path": path, "content": "x"]))
            }
            #expect(throws: ToolError.self) {
                try executor.perform(call("delete_workflow", ["path": path]))
            }
        }
        // Reading them is still fine — the library is part of the engine tree.
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("workflows/library"), withIntermediateDirectories: true
        )
        try write(root, "workflows/library/card.md", "---\nid: library.card\n---\nBody.")
        let output = try executor.perform(call("read_engine_file", ["path": "workflows/library/card.md"]))
        #expect(output.contains("library.card"))
    }

    // MARK: - Reading

    @Test func listsEngineFilesWithWorkflowIDs() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // A broken workflow must be listed as disabled, with its error.
        try write(root, "workflows/broken.md", "---\nid: broken\n---\nBody.")

        let output = try executor(root).perform(call("list_engine_files"))
        #expect(output.contains("comment.social"))
        #expect(output.contains("base.generation"))
        #expect(output.contains("constraints.md"))  // JSONEncoder escapes "/".
        #expect(output.contains("\"disabled\":true"))
        #expect(output.contains("'kind' is required"))
    }

    @Test func readsEngineFiles() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = try executor(root).perform(call("read_engine_file", ["path": "config.yaml"]))
        #expect(output.contains("web_call_budget: 900"))
    }

    @Test func engineStatusReportsRolesAndProviders() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = try executor(root).perform(call("engine_status"))
        #expect(output.contains("\"workflows_loaded\":2"))  // two routable, one abstract
        #expect(output.contains("Claude"))
        #expect(output.contains("generation.magic"))
        // chat.assistant skips the CLI provider (no tool calling) → Claude.
        #expect(output.contains("\"tool_calling\":false"))
    }

    // MARK: - write_workflow validation

    @Test func writesAValidWorkflowTheEngineCanLoad() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let content = """
        ---
        id: thanks.short
        kind: workflow
        mode: direct
        version: 1
        extends: base.generation
        summary: "Short thanks"
        intents: [thanks]
        ---
        ## Rules
        - One sentence.
        """
        let output = try executor(root).perform(
            call("write_workflow", ["path": "workflows/thanks.short.md", "content": content])
        )
        #expect(output.contains("thanks.short"))

        let (catalog, errors) = WorkflowStore.load(from: root.appendingPathComponent("workflows"))
        #expect(catalog.workflow(id: "thanks.short") != nil)
        #expect(errors.filter { !$0.isWarning }.isEmpty)
    }

    @Test func rejectsUnparseableFrontmatterWithLineNumber() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bad = """
        ---
        id: bad.card
        kind: workflow
        mode: direct
        version: 1
        nonsense_key: 1
        summary: "Bad"
        intents: [x]
        ---
        Body.
        """
        let error = #expect(throws: ToolError.self) {
            try executor(root).perform(call("write_workflow", ["path": "workflows/bad.md", "content": bad]))
        }
        #expect(error?.message.contains("line 6") == true)
        #expect(error?.message.contains("nonsense_key") == true)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("workflows/bad.md").path))
    }

    @Test func rejectsDuplicateWorkflowIDs() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let duplicate = """
        ---
        id: comment.social
        kind: workflow
        mode: direct
        version: 1
        summary: "Duplicate"
        intents: [comment]
        ---
        Body.
        """
        let error = #expect(throws: ToolError.self) {
            try executor(root).perform(call("write_workflow", ["path": "workflows/dup.md", "content": duplicate]))
        }
        #expect(error?.message.contains("duplicate") == true)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("workflows/dup.md").path))
    }

    @Test func rejectsMissingExtendsTarget() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let orphan = """
        ---
        id: orphan.card
        kind: workflow
        mode: direct
        version: 1
        extends: base.does-not-exist
        summary: "Orphan"
        intents: [x]
        ---
        Body.
        """
        let error = #expect(throws: ToolError.self) {
            try executor(root).perform(call("write_workflow", ["path": "workflows/orphan.md", "content": orphan]))
        }
        #expect(error?.message.contains("does not exist") == true)
    }

    @Test func overwritingAFileWithItsOwnIDIsNotADuplicate() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let updated = """
        ---
        id: comment.social
        kind: workflow
        mode: direct
        version: 2
        extends: base.generation
        summary: "Comment v2"
        intents: [comment]
        ---
        New body.
        """
        let output = try executor(root).perform(
            call("write_workflow", ["path": "workflows/comment.social.md", "content": updated])
        )
        #expect(output.contains("written"))
    }

    /// Renaming a parent's `id:` orphans every child that `extends` the old
    /// one. The baseline used to exclude the file being written, so those
    /// children were already broken in the baseline and the diff wrote the
    /// breakage off as pre-existing — the warning never fired.
    @Test func changingAnIDWarnsAboutTheDependentsItBreaks() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let renamed = """
        ---
        id: base.generation.v2
        kind: workflow
        mode: direct
        version: 1
        abstract: true
        intents: [write]
        ---
        ## Rules
        - Be brief.
        """
        let output = try executor(root).perform(
            call("write_workflow", ["path": "workflows/base/base.generation.md", "content": renamed])
        )
        // base.reply and comment.social both extend the old id.
        #expect(output.contains("side effect"))
        #expect(output.contains("base.reply") || output.contains("base.reply.md"))
        #expect(output.contains("comment.social"))
    }

    // MARK: - delete_workflow

    @Test func deleteProposalWarnsAboutDependents() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let proposal = try executor(root).makeProposal(
            for: call("delete_workflow", ["path": "workflows/base/base.generation.md"])
        )
        #expect(proposal.isDestructive)
        #expect(proposal.warning?.contains("base.reply") == true)
        #expect(proposal.warning?.contains("comment.social") == true)
    }

    @Test func deleteRemovesTheFile() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try executor(root).perform(call("delete_workflow", ["path": "workflows/comment.social.md"]))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("workflows/comment.social.md").path))
    }

    // MARK: - write_core_file

    @Test func rejectsUnknownCoreFileNames() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: ToolError.self) {
            try executor(root).perform(call("write_core_file", ["name": "evil.md", "content": "x"]))
        }
    }

    @Test func constraintsWriteReportsMachineCheckableRules() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let content = """
        # Rules
        - never say: "best regards"
        - never match: /free of charge/
        - just prose, not a rule
        """
        let output = try executor(root).perform(
            call("write_core_file", ["name": "constraints.md", "content": content])
        )
        #expect(output.contains("\"machine_checkable_rules\":2"))
        let written = try String(
            contentsOf: root.appendingPathComponent("core/constraints.md"), encoding: .utf8
        )
        #expect(written == content)
    }

    @Test func systemPromptWritesToTheRootNotCore() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try executor(root).perform(
            call("write_core_file", ["name": "system-prompt.md", "content": "Override."])
        )
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("system-prompt.md").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("core/system-prompt.md").path))
    }

    // MARK: - set_config

    @Test func configEditPreservesCommentsAndValidates() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try executor(root).perform(call("set_config", ["values": ["web_call_budget": 1500]]))

        let text = try String(contentsOf: root.appendingPathComponent("config.yaml"), encoding: .utf8)
        #expect(text.contains("# Engine tuning — comment must survive edits."))
        #expect(text.contains("web_call_budget: 1500"))
        let (config, warnings) = MagicEngineConfig.parse(text)
        #expect(config.webCallBudget == 1500)
        #expect(warnings.isEmpty)
    }

    @Test func rejectsOutOfRangeConfigValuesWithTheRange() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = try String(contentsOf: root.appendingPathComponent("config.yaml"), encoding: .utf8)
        let error = #expect(throws: ToolError.self) {
            try executor(root).perform(call("set_config", ["values": ["web_call_budget": 99999]]))
        }
        #expect(error?.message.contains("outside 50–10000") == true)
        let after = try String(contentsOf: root.appendingPathComponent("config.yaml"), encoding: .utf8)
        #expect(before == after)  // Nothing written.
    }

    @Test func rejectsUnknownConfigKeys() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let error = #expect(throws: ToolError.self) {
            try executor(root).perform(call("set_config", ["values": ["warp_speed": 9]]))
        }
        #expect(error?.message.contains("unknown key") == true)
    }

    @Test func setsNoCloudListAndInsertsMissingKeys() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try executor(root).perform(call("set_config", [
            "values": [
                "no_cloud": ["telegram", "gmail.com"],
                "capture_deadline_ms": 2000,  // Not in the fixture file → inserted.
            ] as [String: Any],
        ]))
        let text = try String(contentsOf: root.appendingPathComponent("config.yaml"), encoding: .utf8)
        let (config, warnings) = MagicEngineConfig.parse(text)
        #expect(warnings.isEmpty)
        #expect(config.noCloud == ["telegram", "gmail.com"])
        #expect(config.captureDeadlineMs == 2000)
    }

    /// The entries come from a model-supplied tool argument, so the writer has
    /// to quote them: unquoted, an entry with a ',' became TWO privacy rules
    /// and one with a ']' or a '#' truncated the list — and because a
    /// comma-split flow list is still valid YAML, `MagicEngineConfig.parse`
    /// accepted the result without a warning and the user's rule was quietly
    /// the wrong rule (P7).
    @Test func noCloudEntriesWithFlowSyntaxSurviveAsSingleEntries() throws {
        let awkward = [
            "weird,name.example.com",   // ',' used to split this into two rules.
            "bracket]host.example.com", // ']' used to truncate the list here.
            "hash # host.example.com",  // ' #' used to comment out the rest.
            "brace}open{host.com",
            "quote\"host.example.com",
        ]
        let edit = try EngineToolExecutor.applyConfigEdits(
            to: "---\nno_cloud: []\n---\n",
            sets: [("no_cloud", .array(awkward.map { JSONValue.string($0) }))]
        )
        let (config, warnings) = MagicEngineConfig.parse(edit.text)
        #expect(warnings.isEmpty)
        // One entry per input, each with its original text (entries are folded
        // to lower case by `MagicEngineConfig`; these are already lower case).
        #expect(config.noCloud == awkward)
    }

    @Test func noCloudRejectsBlankEntriesInsteadOfDroppingThem() throws {
        let error = #expect(throws: ToolError.self) {
            try EngineToolExecutor.applyConfigEdits(
                to: "---\nno_cloud: []\n---\n",
                sets: [("no_cloud", .array([.string("gmail.com"), .string("  ")]))]
            )
        }
        #expect(error?.message.contains("blank") == true)
    }

    /// These two entries used to corrupt each other: each was written
    /// faithfully on its own, but `stripFlowComment` did not track
    /// backslash-escaped quotes, so on the finished list it read the ']' as
    /// closing the list and the ' #' as starting a comment — the list-level
    /// round-trip caught it and the whole edit was refused. The parser now
    /// tracks escapes the same way `splitFlowItems` does, so the pair must
    /// survive intact; this test ties the writer to that fix, since a
    /// regression there would silently start refusing legitimate privacy
    /// rules again.
    @Test func noCloudEntriesThatOnceCorruptedEachOtherNowSurvive() throws {
        let entries = ["quote\"a]", "hash # b"]
        let edit = try EngineToolExecutor.applyConfigEdits(
            to: "---\nno_cloud: []\n---\n",
            sets: [("no_cloud", .array(entries.map { JSONValue.string($0) }))]
        )
        let (config, warnings) = MagicEngineConfig.parse(edit.text)
        #expect(warnings.isEmpty)
        #expect(config.noCloud == entries)
    }

    /// The round-trip guard still has teeth. "\r\n" is a single Swift
    /// `Character`, so `quotedScalar`'s `case "\n"` never matches it and the
    /// raw newline would land in config.yaml, splitting the `no_cloud:` line in
    /// two — the per-entry round-trip catches that and refuses the edit rather
    /// than writing a mangled privacy list.
    @Test func noCloudRefusesEntriesTheWriterCannotEscape() throws {
        let error = #expect(throws: ToolError.self) {
            try EngineToolExecutor.applyConfigEdits(
                to: "---\nno_cloud: []\n---\n",
                sets: [("no_cloud", .array([.string("gmail.com"), .string("bad\r\nhost.example.com")]))]
            )
        }
        #expect(error?.message.contains("no_cloud") == true)
    }

    @Test func noCloudRoundTripsPlainEntriesUnchanged() throws {
        let edit = try EngineToolExecutor.applyConfigEdits(
            to: "---\nno_cloud: []\n---\n",
            sets: [("no_cloud", .array([.string("telegram"), .string("gmail.com")]))]
        )
        let (config, warnings) = MagicEngineConfig.parse(edit.text)
        #expect(warnings.isEmpty)
        #expect(config.noCloud == ["telegram", "gmail.com"])
        // Clearing the list stays possible.
        let cleared = try EngineToolExecutor.applyConfigEdits(
            to: edit.text, sets: [("no_cloud", .array([]))]
        )
        #expect(MagicEngineConfig.parse(cleared.text).config.noCloud.isEmpty)
    }

    /// The seeded file writes `no_cloud: []` on one line, so rewriting just the
    /// `key:` line worked — right up until a user wrote the block form by hand,
    /// which is what a files-first config invites. The old writer replaced the
    /// header and left `  - gmail.com` dangling under `no_cloud: [...]`, the
    /// parser rejected the file with "unexpected indented line", and the edit
    /// was refused as a whole-file syntax error: nothing corrupted, but
    /// `set_config` unusable on legal YAML with an unintelligible message.
    @Test func blockFormListIsReplacedWholeAndSurroundingCommentsSurvive() throws {
        let text = """
            ---
            # Privacy rules — surfaces that must never reach a cloud model.
            no_cloud:
              - gmail.com
              # Work Slack.
              - com.tinyspeck.slackmacgap
            # Capture budget.
            capture_deadline_ms: 900
            ---

            """
        let edit = try EngineToolExecutor.applyConfigEdits(
            to: text, sets: [("no_cloud", .array([.string("telegram")]))]
        )
        let (config, warnings) = MagicEngineConfig.parse(edit.text)
        #expect(warnings.isEmpty)
        #expect(config.noCloud == ["telegram"])
        // The block's items are gone — all of them, comment included — and the
        // rest of the file is untouched, in order.
        #expect(!edit.text.contains("gmail.com"))
        #expect(!edit.text.contains("slackmacgap"))
        #expect(!edit.text.contains("Work Slack"))
        #expect(edit.text.contains("# Privacy rules"))
        #expect(edit.text.contains("# Capture budget."))
        #expect(config.captureDeadlineMs == 900)
        #expect(edit.text.contains("no_cloud: [\"telegram\"]"))
        // The card must show what is being replaced, not an empty "before".
        #expect(edit.display.first?.old == "[gmail.com, com.tinyspeck.slackmacgap]")
    }

    @Test func removingABlockFormKeyRemovesItsContinuation() throws {
        let text = """
            ---
            no_cloud:
              - gmail.com

            capture_deadline_ms: 900
            ---

            """
        let edit = try EngineToolExecutor.applyConfigEdits(
            to: text, sets: [("no_cloud", .null)]
        )
        let (config, warnings) = MagicEngineConfig.parse(edit.text)
        #expect(warnings.isEmpty)
        #expect(!edit.text.contains("no_cloud"))
        #expect(!edit.text.contains("gmail.com"))
        #expect(config.noCloud.isEmpty)
        #expect(config.captureDeadlineMs == 900)
    }

    /// Block form is not a `no_cloud` peculiarity — any key can be written that
    /// way, and an integer key with a stray indented line under it must be
    /// re-written as a single scalar line rather than left with an orphan.
    @Test func blockFormIsHandledForNonPrivacyKeysToo() throws {
        let text = "---\ncapture_deadline_ms:\n  900\ntoast_dismiss_seconds: 10\n---\n"
        let edit = try EngineToolExecutor.applyConfigEdits(
            to: text, sets: [("capture_deadline_ms", .int(2000))]
        )
        let (config, warnings) = MagicEngineConfig.parse(edit.text)
        #expect(warnings.isEmpty)
        #expect(config.captureDeadlineMs == 2000)
        #expect(config.toastDismissSeconds == 10)
    }

    @Test func nullResetsAConfigKeyToDefault() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try executor(root).perform(call("set_config", ["values": ["toast_dismiss_seconds": NSNull()]]))
        let text = try String(contentsOf: root.appendingPathComponent("config.yaml"), encoding: .utf8)
        #expect(!text.contains("toast_dismiss_seconds"))
        let (config, _) = MagicEngineConfig.parse(text)
        #expect(config.toastDismissSeconds == MagicEngineConfig.default.toastDismissSeconds)
    }

    // MARK: - set_role

    @Test func bindsARoleByProviderName() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try executor(root).perform(call("set_role", [
            "role": "generation.magic",
            "provider": "Claude",
            "timeout_seconds": 30,
            "min_cost_class": "mid",
        ] as [String: Any]))

        let text = try String(contentsOf: root.appendingPathComponent("roles.yaml"), encoding: .utf8)
        let parsed = RolesFile.parse(text)
        #expect(parsed.warnings.isEmpty)
        let binding = parsed.bindings[.generationMagic]
        #expect(binding?.provider == Self.anthropicID)
        #expect(binding?.timeoutSeconds == 30)
        #expect(binding?.minCostClass == .mid)
    }

    @Test func rejectsUnknownRoleAndBadTimeout() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: ToolError.self) {
            try executor(root).perform(call("set_role", ["role": "planner.fallback", "provider": "Claude"]))
        }
        #expect(throws: ToolError.self) {
            try executor(root).perform(call("set_role", [
                "role": "generation.magic", "timeout_seconds": 9999,
            ] as [String: Any]))
        }
    }

    @Test func warnsWhenBindingANonToolCallingProviderToTheChat() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let proposal = try executor(root).makeProposal(for: call("set_role", [
            "role": "chat.assistant", "provider": "Local CLI",
        ]))
        #expect(proposal.warning?.contains("tool calling") == true)
    }

    @Test func refusesToRewriteRolesFileWithSkippedRecords() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // A record the parser skips (unknown role) would be dropped by a
        // rewrite — the tool must refuse instead.
        try write(root, "roles.yaml", """
        ---
        roles:
          - role: mystery.role
            provider: \(Self.anthropicID.uuidString)
        ---
        """)
        let error = #expect(throws: ToolError.self) {
            try executor(root).perform(call("set_role", ["role": "generation.magic", "provider": "Claude"]))
        }
        #expect(error?.message.contains("skipped") == true)
    }

    // MARK: - set_provider_metadata

    @Test func editsOnlyLocalityAndCostClass() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try executor(root).perform(call("set_provider_metadata", [
            "provider": "Local CLI", "locality": "local", "cost_class": "local",
        ]))

        let text = try String(contentsOf: root.appendingPathComponent("providers.yaml"), encoding: .utf8)
        let parsed = ProvidersFile.parse(text)
        #expect(parsed.warnings.isEmpty)
        let cli = parsed.providers.first { $0.id == Self.cliID }
        #expect(cli?.locality == .local)
        #expect(cli?.costClass == .local)
        // The untouched provider survives the round trip intact.
        let claude = parsed.providers.first { $0.id == Self.anthropicID }
        #expect(claude?.name == "Claude")
        #expect(claude?.isDefault == true)
    }

    @Test func derivedClearsExplicitMetadata() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try executor(root).perform(call("set_provider_metadata", [
            "provider": "Claude", "locality": "local",
        ]))
        _ = try executor(root).perform(call("set_provider_metadata", [
            "provider": "Claude", "locality": "derived",
        ]))
        let parsed = ProvidersFile.parse(
            try String(contentsOf: root.appendingPathComponent("providers.yaml"), encoding: .utf8)
        )
        #expect(parsed.providers.first { $0.id == Self.anthropicID }?.locality == nil)
    }

    @Test func rejectsUnknownProviderNames() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let error = #expect(throws: ToolError.self) {
            try executor(root).perform(call("set_provider_metadata", [
                "provider": "Nonexistent", "locality": "local",
            ]))
        }
        #expect(error?.message.contains("Claude") == true)  // Lists what exists.
    }

    // MARK: - Trace tools (end to end against files)

    @Test func readTracesFiltersAndExplainsFromLogFiles() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let logs = root.appendingPathComponent("logs")
        let lines = [
            TraceInspectorTests.traceJSON(
                id: "AAAAAAAA-0000-0000-0000-000000000001",
                ts: "2026-07-20T10:00:00Z", app: "com.apple.mail", outcome: "inserted"
            ),
            TraceInspectorTests.traceJSON(
                id: "BBBBBBBB-0000-0000-0000-000000000002",
                ts: "2026-07-21T10:00:00Z", app: "com.google.Chrome",
                outcome: "error:generation:noCloud"
            ),
        ]
        try lines.joined(separator: "\n")
            .write(to: logs.appendingPathComponent("traces-2026-07-21.jsonl"), atomically: true, encoding: .utf8)

        let executor = executor(root)
        let filtered = try executor.perform(call("read_traces", ["outcome_prefix": "error"]))
        #expect(filtered.contains("\"matched\":1"))
        #expect(filtered.contains("noCloud"))
        #expect(!filtered.contains("com.apple.mail"))

        // Latest press is the Chrome error; the explanation decodes it.
        let latest = try executor.perform(call("explain_press"))
        #expect(latest.contains("com.google.Chrome"))
        #expect(latest.contains("no_cloud"))

        // And by id prefix, case-insensitively.
        let byID = try executor.perform(call("explain_press", ["trace_id": "aaaaaaaa"]))
        #expect(byID.contains("com.apple.mail"))
    }
}
