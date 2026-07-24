import Foundation
import Testing
@testable import ClipSlop

/// The bundled Agent Skill (`Sources/AgentSkill/clipslop/`) is the single
/// source of truth for engine knowledge — the Settings Assistant embeds its
/// `engine-reference` region, and external agents install the whole
/// directory. These tests regenerate every key table from the engine's own
/// parsers and assert the markdown still names them, so the skill cannot
/// rot silently when a parser gains or changes a key.
@Suite("Agent skill")
struct AgentSkillTests {

    private func skillURL() throws -> URL {
        let url = try #require(AgentSkill.bundledSkillURL, "bundled skill directory missing")
        return url
    }

    private func reference(_ name: String) throws -> String {
        let url = try skillURL()
            .appendingPathComponent("references")
            .appendingPathComponent(name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Package shape

    @Test func bundleContainsSkillAndAllReferences() throws {
        let root = try skillURL()
        #expect(root.lastPathComponent == AgentSkill.directoryName)
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: root.appendingPathComponent("SKILL.md").path))
        for name in [
            "workflow-schema.md", "config-keys.md", "providers-roles.md",
            "traces.md", "prompt-library.md",
        ] {
            let path = root.appendingPathComponent("references").appendingPathComponent(name).path
            #expect(fm.fileExists(atPath: path), "missing references/\(name)")
        }
    }

    @Test func frontmatterMatchesAgentSkillsSpec() throws {
        let markdown = try #require(AgentSkill.skillMarkdown())
        // The skill's own frontmatter must survive the engine's constrained
        // YAML parser — external agents get at least this much structure.
        let document = try FrontmatterParser.parse(markdown)

        guard case .scalar(let name)? = document.fields["name"] else {
            Issue.record("frontmatter 'name' missing")
            return
        }
        // Spec: lowercase + hyphens, must equal the directory name.
        #expect(name == AgentSkill.directoryName)
        #expect(name.wholeMatch(of: /[a-z0-9][a-z0-9-]*/) != nil)
        #expect(name.count <= 64)

        guard case .scalar(let description)? = document.fields["description"] else {
            Issue.record("frontmatter 'description' missing")
            return
        }
        #expect(!description.isEmpty)
        #expect(description.count <= 1024, "description is \(description.count) chars (max 1024)")
        // Keyword-rich: the description must say what AND when.
        #expect(description.contains("~/.clipslop"))
        #expect(description.contains("Use when"))

        #expect(AgentSkill.bundledVersion != nil, "metadata.version missing")
    }

    @Test func bodyStaysWithinProgressiveDisclosureBudget() throws {
        let markdown = try #require(AgentSkill.skillMarkdown())
        let document = try FrontmatterParser.parse(markdown)
        let body = document.body
        let lines = body.components(separatedBy: "\n").count
        #expect(lines < 500, "SKILL.md body is \(lines) lines (must stay < 500)")
        let estimatedTokens = body.count / 4
        #expect(estimatedTokens < 5000, "SKILL.md body ≈ \(estimatedTokens) tokens (must stay < 5000)")
    }

    // MARK: - Single-sourcing into the Settings Assistant

    @Test func engineReferenceRegionFeedsTheAssistantPrompt() throws {
        let region = try #require(AgentSkill.engineReference())
        #expect(region.contains("ENGINE FILE TREE"))
        #expect(region.contains("SAFETY RULES"))
        #expect(!region.contains("engine-reference:"), "markers must not leak into the prompt")
        // Agent-agnostic by contract: no in-app tool names inside the region.
        for toolName in ["read_traces", "explain_press", "list_engine_files", "write_workflow"] {
            #expect(!region.contains(toolName), "region mentions tool '\(toolName)'")
        }

        let prompt = AssistantSystemPrompt.build(providerNames: ["TestProvider"])
        #expect(prompt.contains(region), "assistant prompt must embed the skill's engine reference verbatim")
        #expect(prompt.contains("TestProvider"))
        #expect(!prompt.contains(AssistantSystemPrompt.missingReferenceFallback))
    }

    @Test func referenceExtractionHandlesMarkerShapes() {
        let markdown = """
        intro
        <!-- engine-reference:begin
             explanatory note -->
        THE KNOWLEDGE
        <!-- engine-reference:end -->
        outro
        """
        #expect(AgentSkill.extractEngineReference(from: markdown) == "THE KNOWLEDGE")
        #expect(AgentSkill.extractEngineReference(from: "no markers here") == nil)
    }

    @Test func versionParsingReadsFrontmatterOnly() {
        let markdown = """
        ---
        name: clipslop
        metadata:
          version: "2.5.0"
        ---
        body text
        version: 9.9.9
        """
        #expect(AgentSkill.parseVersion(from: markdown) == "2.5.0")
        #expect(AgentSkill.parseVersion(from: "no frontmatter") == nil)
    }

    // MARK: - Drift protection: config keys

    @Test func configKeyTableMatchesMagicEngineConfig() throws {
        let configReference = try reference("config-keys.md")
        // SKILL.md is hard-wrapped prose — collapse line breaks so a key
        // and its range may sit on adjacent lines.
        let skill = try #require(AgentSkill.skillMarkdown())
            .replacingOccurrences(of: "\n", with: " ")

        for entry in MagicEngineConfig.keyTable() {
            let rangeText = "\(entry.range.lowerBound)–\(entry.range.upperBound)"
            let row = "| `\(entry.key)` | \(entry.defaultValue) | \(rangeText) |"
            #expect(
                configReference.contains(row),
                "config-keys.md is missing or stale for '\(entry.key)' — expected row start '\(row)'"
            )
            #expect(skill.contains(entry.key), "SKILL.md never mentions config key '\(entry.key)'")
            // SKILL.md renders 0–1 switches as "0|1"; every other range verbatim.
            let skillRange = entry.range == 0...1 ? "\(entry.key) 0|1" : "\(entry.key) \(rangeText)"
            #expect(skill.contains(skillRange), "SKILL.md range for '\(entry.key)' is stale")
        }
        // The one non-integer key.
        #expect(configReference.contains("`no_cloud`"))
        #expect(skill.contains("no_cloud"))
    }

    @Test func debugLogKeyIsFileReachable() {
        // The audit story depends on this key existing with these semantics.
        let parsed = MagicEngineConfig.parse("---\ndebug_log_enabled: 1\n---")
        #expect(parsed.config.debugLogEnabled == 1)
        #expect(parsed.warnings.isEmpty)
        #expect(MagicEngineConfig.default.debugLogEnabled == 0, "must be off by default (privacy)")
        #expect(EngineSeedContent.engineConfig.contains("debug_log_enabled: 0"))
    }

    @Test func configStoreLineEditPreservesCommentsAndFences() {
        let original = """
        ---
        # a comment that must survive
        capture_deadline_ms: 1600
        debug_log_enabled: 0
        ---
        """
        let toggled = EngineConfigStore.settingInteger(1, forKey: "debug_log_enabled", in: original)
        #expect(toggled.contains("# a comment that must survive"))
        #expect(toggled.contains("debug_log_enabled: 1"))
        #expect(!toggled.contains("debug_log_enabled: 0"))
        #expect(toggled.contains("capture_deadline_ms: 1600"))

        let inserted = EngineConfigStore.settingInteger(
            1, forKey: "debug_log_enabled", in: "---\ncapture_deadline_ms: 1600\n---"
        )
        let parsed = MagicEngineConfig.parse(inserted)
        #expect(parsed.config.debugLogEnabled == 1)
        #expect(parsed.warnings.isEmpty)
    }

    // MARK: - Drift protection: workflow card schema

    @Test func workflowSchemaNamesEveryParserKey() throws {
        let schema = try reference("workflow-schema.md")
        let allKeys = WorkflowCardParser.knownKeys
            .union(WorkflowCardParser.knownWhenKeys)
            .union(WorkflowCardParser.ignoredForwardKeys)
        for key in allKeys.sorted() {
            #expect(schema.contains("`\(key)`"), "workflow-schema.md is missing key '\(key)'")
        }
    }

    @Test func promptLibraryReferenceNamesEveryLibraryKey() throws {
        let library = try reference("prompt-library.md")
        for key in WorkflowCardParser.libraryKeys.sorted() {
            #expect(library.contains("`\(key)`"), "prompt-library.md is missing library key '\(key)'")
        }
        #expect(library.contains("_folder.md"))
        #expect(library.contains("prompts.json"))
    }

    // MARK: - Drift protection: providers / roles

    @Test func providersRolesReferenceNamesEverySchemaKey() throws {
        let text = try reference("providers-roles.md")
        for key in ProvidersFile.knownKeys.sorted() {
            #expect(text.contains("`\(key)`"), "providers-roles.md is missing providers key '\(key)'")
        }
        for key in RolesFile.knownKeys.sorted() {
            #expect(text.contains("`\(key)`"), "providers-roles.md is missing roles key '\(key)'")
        }
        for role in EngineRole.allCases {
            #expect(text.contains("`\(role.rawValue)`"), "providers-roles.md is missing role '\(role.rawValue)'")
        }
        for type in AIProviderType.allCases {
            #expect(text.contains("`\(type.rawValue)`"), "providers-roles.md is missing provider type '\(type.rawValue)'")
        }
        for cost in ProviderCostClass.allCases {
            #expect(text.contains(cost.rawValue), "providers-roles.md is missing cost class '\(cost.rawValue)'")
        }
        for locality in ProviderLocality.allCases {
            #expect(text.contains(locality.rawValue), "providers-roles.md is missing locality '\(locality.rawValue)'")
        }
    }

    // MARK: - Drift protection: trace vocabulary

    @Test func traceReferenceNamesEveryTraceField() throws {
        let text = try reference("traces.md")

        // A fully-populated trace so optional fields reach the JSON output.
        var trace = PressTrace(
            snapshot: MagicTestSupport.makeSnapshot(url: "https://example.com/x"),
            decision: nil,
            classification: nil
        )
        trace.appBundleID = "com.example.app"
        trace.urlHost = "example.com"
        trace.selectionClass = "instruction"
        trace.selectionWasTie = false
        trace.chosenID = "base.reply"
        trace.chipIndexChosen = 0
        trace.plannerIndexChosen = 0
        trace.providerType = "anthropic"
        trace.modelID = "test"
        trace.verifierPassed = true
        trace.latencyMs.paste = 5
        trace.latencyMs.planner = 3

        let data = try JSONEncoder().encode(trace)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        for field in object.keys.sorted() {
            #expect(text.contains("`\(field)`"), "traces.md is missing trace field '\(field)'")
        }
        let latency = try #require(object["latencyMs"] as? [String: Any])
        for field in latency.keys.sorted() {
            #expect(text.contains("`\(field)`"), "traces.md is missing latency field '\(field)'")
        }
        for check in VerifierWarning.Check.allCases {
            #expect(text.contains("`\(check.rawValue)`"), "traces.md is missing verifier check '\(check.rawValue)'")
        }

        let spend = SpendRecord(
            ts: Date(), role: "generation.magic", provider: "anthropic",
            model: "test", inputTokens: 1, outputTokens: 2, estimated: true
        )
        let spendData = try JSONEncoder().encode(spend)
        let spendObject = try #require(try JSONSerialization.jsonObject(with: spendData) as? [String: Any])
        for field in spendObject.keys.sorted() {
            #expect(text.contains("`\(field)`"), "traces.md is missing spend field '\(field)'")
        }
    }

    // MARK: - Install

    @Test func installCopiesAndReplacesVersioned() throws {
        let fm = FileManager.default
        let parent = fm.temporaryDirectory
            .appendingPathComponent("clipslop-skill-test-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: parent) }

        let installed = try AgentSkill.install(intoParent: parent)
        #expect(installed.lastPathComponent == AgentSkill.directoryName)
        #expect(fm.fileExists(atPath: installed.appendingPathComponent("SKILL.md").path))
        #expect(fm.fileExists(atPath: installed
            .appendingPathComponent("references")
            .appendingPathComponent("config-keys.md").path))
        #expect(AgentSkill.installedVersion(at: installed) == AgentSkill.bundledVersion)

        // Overwrite an existing (stale) installation cleanly.
        try "stale".write(
            to: installed.appendingPathComponent("SKILL.md"),
            atomically: true, encoding: .utf8
        )
        try AgentSkill.install(intoParent: parent)
        let refreshed = try String(
            contentsOf: installed.appendingPathComponent("SKILL.md"), encoding: .utf8
        )
        #expect(refreshed != "stale")
        #expect(AgentSkill.installedVersion(at: installed) == AgentSkill.bundledVersion)
        // No staging litter left behind.
        let leftovers = try fm.contentsOfDirectory(atPath: parent.path)
            .filter { $0.contains("staging") }
        #expect(leftovers.isEmpty)
    }
}
