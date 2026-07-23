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
        ---
        """)
        #expect(warnings.isEmpty)
        #expect(config.webCallBudget == 1500)
        #expect(config.toastDismissSeconds == 20)
        #expect(config.warmObserverEnabled == 0)
        #expect(config.warmContextTtlSeconds == 60)
        // Untouched keys keep defaults.
        #expect(config.axCallBudget == MagicEngineConfig.default.axCallBudget)
        #expect(config.observerDebounceMs == MagicEngineConfig.default.observerDebounceMs)
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

    @Test func unparseableFileFallsBackToDefaults() {
        let (config, warnings) = MagicEngineConfig.parse("not yaml at all")
        #expect(config == .default)
        #expect(warnings.count == 1)
        #expect(warnings[0].contains("defaults"))
    }
}
