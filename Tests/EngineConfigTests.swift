import Testing
@testable import ClipSlop

@Suite("Engine config")
struct EngineConfigTests {
    @Test func seedParsesCleanAndMatchesDefaults() {
        let (config, warnings) = MagicEngineConfig.parse(EngineSeedContent.engineConfig)
        #expect(warnings.isEmpty, "seed warnings: \(warnings)")
        #expect(config == .default)
    }

    @Test func overridesApply() {
        let (config, warnings) = MagicEngineConfig.parse("""
        ---
        web_call_budget: 1500
        toast_dismiss_seconds: 20
        warm_observer_enabled: 0
        warm_context_ttl_seconds: 60
        output_max_chars_default: 3000
        ---
        """)
        #expect(warnings.isEmpty)
        #expect(config.webCallBudget == 1500)
        #expect(config.toastDismissSeconds == 20)
        #expect(config.outputMaxCharsDefault == 3000)
        #expect(config.warmObserverEnabled == 0)
        #expect(config.warmContextTtlSeconds == 60)
        // Untouched keys keep defaults.
        #expect(config.axCallBudget == MagicEngineConfig.default.axCallBudget)
        #expect(config.observerDebounceMs == MagicEngineConfig.default.observerDebounceMs)
    }

    @Test func zeroSurroundingTokensMeansUnlimitedAndParsesClean() {
        let (config, warnings) = MagicEngineConfig.parse("""
        ---
        surrounding_max_tokens: 0
        ---
        """)
        #expect(warnings.isEmpty)
        #expect(config.surroundingMaxTokens == 0)
        let (negative, negativeWarnings) = MagicEngineConfig.parse("---\nsurrounding_max_tokens: -5\n---")
        #expect(negative.surroundingMaxTokens == 0)
        #expect(negativeWarnings.count == 1)
    }

    @Test func surroundingTreeKeyParsesClampsAndDefaultsOn() {
        #expect(MagicEngineConfig.default.surroundingTreeEnabled == 1, "tree mode must be ON out of the box")

        let off = MagicEngineConfig.parse("---\nsurrounding_tree_enabled: 0\n---")
        #expect(off.config.surroundingTreeEnabled == 0)
        #expect(off.warnings.isEmpty)

        let clamped = MagicEngineConfig.parse("---\nsurrounding_tree_enabled: 7\n---")
        #expect(clamped.config.surroundingTreeEnabled == 1)
        #expect(clamped.warnings.count == 1)

        #expect(EngineSeedContent.engineConfig.contains("surrounding_tree_enabled: 1"))
    }

    @Test func noCloudListParses() {
        let (config, warnings) = MagicEngineConfig.parse("""
        ---
        no_cloud: [Telegram, com.tinyspeck.slackmacgap, Gmail.com]
        ---
        """)
        #expect(warnings.isEmpty)
        #expect(config.noCloud == ["telegram", "com.tinyspeck.slackmacgap", "gmail.com"])

        let (single, _) = MagicEngineConfig.parse("---\nno_cloud: telegram\n---")
        #expect(single.noCloud == ["telegram"])

        let (empty, emptyWarnings) = MagicEngineConfig.parse("---\nno_cloud: []\n---")
        #expect(empty.noCloud.isEmpty)
        #expect(emptyWarnings.isEmpty)
    }

    @Test func outOfRangeValuesClampWithWarning() {
        let (config, warnings) = MagicEngineConfig.parse("""
        ---
        capture_deadline_ms: 999999
        ax_call_budget: 1
        ---
        """)
        #expect(config.captureDeadlineMs == 10_000)
        #expect(config.axCallBudget == 50)
        #expect(warnings.count == 2)
        #expect(warnings.allSatisfy { $0.contains("clamped") })
    }

    @Test func unknownKeyWarnsAndIsIgnored() {
        let (config, warnings) = MagicEngineConfig.parse("""
        ---
        tree_depht: 12
        ---
        """)
        #expect(config == .default)
        #expect(warnings.count == 1)
        #expect(warnings[0].contains("tree_depht"))
    }

    @Test func nonIntegerValueWarnsAndKeepsDefault() {
        let (config, warnings) = MagicEngineConfig.parse("""
        ---
        max_web_depth: deep
        ---
        """)
        #expect(config.maxWebDepth == MagicEngineConfig.default.maxWebDepth)
        #expect(warnings.count == 1)
    }

    @Test func unparseableFileIsNotAppliedAtAll() {
        let (config, warnings) = MagicEngineConfig.parse("not yaml at all")
        #expect(config == .default)  // Nothing to retain in the pure form.
        #expect(warnings.count == 1)
        #expect(warnings[0].contains("NOT applied"))
        // `EngineToolExecutor.applyConfigEdits` treats a "line …" warning as a
        // whole-file failure and refuses to write; keep that prefix.
        #expect(warnings[0].hasPrefix("line "))
    }

    /// A fatal syntax error used to hand back the all-default config — so a
    /// typo on an unrelated line emptied `no_cloud` and the press pipeline
    /// carried protected screen content to a cloud provider (P7). A file that
    /// does not parse now changes nothing.
    @Test func brokenFileRetainsTheLastSettingsThatParsed() {
        let good = MagicEngineConfig.load("""
        ---
        no_cloud: [com.tinyspeck.slackmacgap]
        web_call_budget: 1500
        ---
        """, retaining: .default)
        #expect(good.applied)
        #expect(good.config.noCloud == ["com.tinyspeck.slackmacgap"])

        let broken = MagicEngineConfig.load("""
        ---
        no_cloud: [com.tinyspeck.slackmacgap]
        web_call_budget: 1500
        intents: [reply
        ---
        """, retaining: good.config)
        #expect(!broken.applied)
        #expect(broken.config == good.config)
        #expect(broken.config.noCloud == ["com.tinyspeck.slackmacgap"])
        #expect(broken.config.webCallBudget == 1500)
        #expect(broken.warnings.count == 1)
        #expect(broken.warnings[0].contains("NOT applied"))
    }

    /// First launch with a broken file has nothing to retain, so the privacy
    /// rules are rescued from the raw text instead of defaulting to "none".
    @Test func brokenFileOnFirstLoadStillHonoursNoCloud() {
        let result = MagicEngineConfig.load("""
        ---
        no_cloud: [Telegram, gmail.com]
        web_call_budget: [1500
        ---
        """, retaining: .default)
        #expect(!result.applied)
        #expect(result.config.noCloud == ["telegram", "gmail.com"])
        // Everything else really is untouched — only privacy is rescued.
        #expect(result.config.webCallBudget == MagicEngineConfig.default.webCallBudget)
    }

    @Test func unreadableFileCanAddNoCloudRulesButNeverDropThem() {
        var previous = MagicEngineConfig.default
        previous.noCloud = ["com.tinyspeck.slackmacgap"]
        // The broken file no longer names Slack. A file we could not read is
        // not allowed to lift a live privacy rule, only to tighten it.
        let result = MagicEngineConfig.load("""
        ---
        no_cloud: [telegram]
        budget: {ms: 10
        ---
        """, retaining: previous)
        #expect(!result.applied)
        #expect(result.config.noCloud == ["com.tinyspeck.slackmacgap", "telegram"])

        // A `no_cloud` block that is itself unreadable rescues nothing.
        let unrescuable = MagicEngineConfig.load("---\nno_cloud: [telegram\n---", retaining: previous)
        #expect(!unrescuable.applied)
        #expect(unrescuable.config.noCloud == ["com.tinyspeck.slackmacgap"])
    }

    /// Warnings come out in iteration order and are shown as a list in
    /// Settings → Magic. Iterating the parsed fields dictionary directly
    /// reshuffles that list on every reload of an unchanged file, and the user
    /// has no way to tell a reorder from a new problem. File order, always.
    @Test func warningsComeOutInFileOrder() {
        let text = """
        ---
        toast_dismiss_seconds: 999
        not_a_key: 1
        ax_call_budget: 1
        ---
        """
        let expected = ["toast_dismiss_seconds", "not_a_key", "ax_call_budget"]
        // Repeated because a dictionary's order is stable within one process
        // for one set of keys — a single pass can agree with file order by
        // luck. What is being pinned is that every parse of the same text
        // answers the same way.
        for _ in 0..<8 {
            let warnings = MagicEngineConfig.parse(text).warnings
            #expect(warnings.count == 3)
            #expect(zip(warnings, expected).allSatisfy { $0.contains($1) })
        }
    }
}
