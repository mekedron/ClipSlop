import Foundation

/// User-tunable engine parameters, read from `~/.clipslop/config.yaml`
/// (files-first, §15). Every value is clamped to a sane range — a typo in a
/// hand-edited file degrades to the nearest safe bound, never to a hung
/// press or an unbounded walk.
struct MagicEngineConfig: Sendable, Equatable {
    /// Overall snapshot deadline — the press never waits longer for capture.
    var captureDeadlineMs = 2500
    /// Accessibility *requests* allowed per press in native apps. One
    /// request = reading one attribute of one on-screen element (its role,
    /// its text, or its list of children) — an IPC round-trip into the
    /// target app. Native trees are dense (much text per element), so few
    /// requests suffice.
    var axCallBudget = 600
    /// The same request budget for web pages. Chromium wraps every div in
    /// an empty AXGroup, so reaching the text costs many more requests —
    /// a long LinkedIn/Gmail thread wants thousands.
    var webCallBudget = 3000
    /// Depth of the text gather inside one native sibling subtree.
    var maxGatherDepth = 6
    /// Depth cap inside web subtrees.
    var maxWebDepth = 30
    /// Siblings visited per level in the native walk.
    var maxSiblingsPerLevel = 16
    /// Children visited per node in web subtrees.
    var maxWebChildrenPerNode = 60
    /// Cap on the assembled surrounding text.
    var surroundingMaxChars = 32_000
    /// Web walk: how much text preceding the field to keep (a chat's newest
    /// messages) and how much after it.
    var webBeforeKeepChars = 20_000
    var webAfterKeepChars = 6_000
    /// Token ceiling for the prompt's SURROUNDING CONTEXT block — the one
    /// knob that decides how much captured screen text the model sees.
    /// 0 = unlimited: everything the collector gathered is passed
    /// untrimmed, and workflow-card budgets never cut it either.
    var surroundingMaxTokens = 8_000
    /// Hierarchical screen context (0/1): capture the surroundings as a
    /// structured tree and render them as an indented outline with an
    /// explicit ⟨YOUR FIELD⟩ marker; overflow keeps the content nearest
    /// the field. 0 = the old flat text blob (tail kept on overflow).
    var surroundingTreeEnabled = 1
    /// Cap on the focused field's own value read.
    var fieldValueMaxChars = 50_000
    /// Post-insert toast auto-dismiss.
    var toastDismissSeconds = 8
    /// Character ceiling for generated output when the routed workflow card
    /// sets no `output.max_chars` of its own. Told to the model at assembly
    /// and checked by the verifier — a card's explicit value always wins.
    var outputMaxCharsDefault = 1200
    /// Warm frontmost-app observer (§5.1). 0 disables the whole subsystem —
    /// presses then behave exactly like V0 collect-on-press.
    var warmObserverEnabled = 1
    /// How long the observer's cheap context stays usable as press-time
    /// backfill.
    var warmContextTtlSeconds = 30
    /// Debounce between a focus-change notification and the cheap read.
    var observerDebounceMs = 200
    /// Fast-mode chip planner (`MagicPlanner`): hard time cap for the one
    /// tiny model call that may auto-pick the obvious chip when routing was
    /// ambiguous. On timeout / unsure / error the chip panel shows
    /// unchanged. 0 disables the planner entirely (the kill switch);
    /// forced-chips presses never use it regardless.
    var plannerTimeoutMs = 900
    /// Full-content per-press debug log (`logs/debug/`, 7-day prune).
    /// Lives in config.yaml — not UserDefaults — so file-editing agents can
    /// flip it; the Settings → Magic checkbox is a view over this key
    /// (config.yaml is authoritative, see `EngineConfigStore.setInteger`).
    /// Off by default: these files contain real screen content.
    var debugLogEnabled = 0
    /// Apps/domains whose field content must never reach a cloud provider
    /// (P7). Entries are matched case-insensitively: substring of the app
    /// bundle id, or exact/suffix match of the URL host. A matching press
    /// switches to a local provider from the role's chain, or refuses
    /// honestly (P9) when none exists.
    var noCloud: [String] = []

    static let `default` = MagicEngineConfig()

    /// key → (range, keypath) table so parsing, clamping, and the seeded
    /// file stay in one place. Built per call — WritableKeyPath tuples are
    /// not Sendable, so this cannot be a static stored table under strict
    /// concurrency.
    private static func ranges() -> [(key: String, range: ClosedRange<Int>, path: WritableKeyPath<MagicEngineConfig, Int>)] {
        [
        ("capture_deadline_ms", 300...10_000, \.captureDeadlineMs),
        ("ax_call_budget", 50...5_000, \.axCallBudget),
        ("web_call_budget", 50...10_000, \.webCallBudget),
        ("max_gather_depth", 1...50, \.maxGatherDepth),
        ("max_web_depth", 5...100, \.maxWebDepth),
        ("max_siblings_per_level", 2...200, \.maxSiblingsPerLevel),
        ("max_web_children_per_node", 5...500, \.maxWebChildrenPerNode),
        ("surrounding_max_chars", 500...200_000, \.surroundingMaxChars),
        ("web_before_keep_chars", 200...150_000, \.webBeforeKeepChars),
        ("web_after_keep_chars", 0...50_000, \.webAfterKeepChars),
        ("surrounding_max_tokens", 0...200_000, \.surroundingMaxTokens),
        ("surrounding_tree_enabled", 0...1, \.surroundingTreeEnabled),
        ("field_value_max_chars", 1_000...500_000, \.fieldValueMaxChars),
        ("toast_dismiss_seconds", 2...120, \.toastDismissSeconds),
        ("output_max_chars_default", 100...100_000, \.outputMaxCharsDefault),
        ("warm_observer_enabled", 0...1, \.warmObserverEnabled),
        ("warm_context_ttl_seconds", 5...300, \.warmContextTtlSeconds),
        ("observer_debounce_ms", 50...2_000, \.observerDebounceMs),
        ("planner_timeout_ms", 0...5_000, \.plannerTimeoutMs),
        ("debug_log_enabled", 0...1, \.debugLogEnabled),
        ]
    }

    /// Every integer key with its range and default — the source the
    /// Agent Skill's drift tests (`AgentSkillTests`) regenerate the
    /// config-key table from. (`no_cloud` is the one non-integer key and is
    /// asserted separately.) Key paths stay private; this exposes only data.
    static func keyTable() -> [(key: String, range: ClosedRange<Int>, defaultValue: Int)] {
        let defaults = MagicEngineConfig.default
        return ranges().map { ($0.key, $0.range, defaults[keyPath: $0.path]) }
    }

    /// Outcome of reading config.yaml. `applied == false` means the document
    /// did not parse as a whole: `config` is then the settings the caller
    /// asked to retain (plus any privacy rules rescued from the raw text),
    /// never the all-default config.
    struct LoadResult: Sendable {
        var config: MagicEngineConfig
        var warnings: [String]
        var applied: Bool
    }

    /// Parses the config file (same constrained YAML subset as workflow
    /// frontmatter). Missing keys keep their defaults; out-of-range values
    /// clamp with a warning; unknown keys warn and are ignored.
    ///
    /// Convenience over `load(_:retaining:)` for callers that only validate a
    /// candidate file (the Settings Assistant's `set_config`, the status
    /// report) and therefore have nothing to retain.
    static func parse(_ text: String) -> (config: MagicEngineConfig, warnings: [String]) {
        let result = load(text, retaining: .default)
        return (result.config, result.warnings)
    }

    /// Reads the file, keeping `previous` whole when the document is not
    /// parseable at all.
    ///
    /// Answering a fatal syntax error with the all-default config would let one
    /// malformed *unrelated* line empty `no_cloud` and send protected screen
    /// content to a cloud provider (P7). A file we could not read must not be
    /// able to change any setting, least of all a privacy rule: nothing is
    /// applied, the warning says so in those words, and the last settings that
    /// did parse stay in effect.
    static func load(_ text: String, retaining previous: MagicEngineConfig) -> LoadResult {
        var config = MagicEngineConfig.default
        var warnings: [String] = []

        let document: FrontmatterDocument
        do {
            document = try FrontmatterParser.parse(text)
        } catch let error as FrontmatterError {
            return unapplied(text, retaining: previous, reason: "line \(error.line): \(error.message)")
        } catch {
            // Unreachable today (the parser only throws `FrontmatterError`),
            // but the "line …" prefix is load-bearing: `EngineToolExecutor`
            // treats it as a whole-file failure and refuses to write.
            return unapplied(text, retaining: previous, reason: "line 1: could not parse config.yaml")
        }

        let known = Dictionary(uniqueKeysWithValues: ranges().map { ($0.key, $0) })
        for (key, value) in document.fields {
            if key == "no_cloud" {
                switch value {
                case .list(let items):
                    config.noCloud = normalized(items)
                case .scalar(let scalar) where !scalar.isEmpty:
                    config.noCloud = normalized([scalar])
                default:
                    warnings.append("'no_cloud' must be a list like [com.tinyspeck.slackmacgap, gmail.com]")
                }
                continue
            }
            guard let entry = known[key] else {
                warnings.append("unknown key '\(key)' (line \(document.fieldLines[key] ?? 0)) — ignored")
                continue
            }
            guard case .scalar(let scalar) = value, let number = Int(scalar) else {
                warnings.append("'\(key)' must be an integer — keeping \(config[keyPath: entry.path])")
                continue
            }
            let clamped = min(max(number, entry.range.lowerBound), entry.range.upperBound)
            if clamped != number {
                warnings.append("'\(key)' \(number) is outside \(entry.range.lowerBound)–\(entry.range.upperBound), clamped to \(clamped)")
            }
            config[keyPath: entry.path] = clamped
        }
        return LoadResult(config: config, warnings: warnings, applied: true)
    }

    /// The retain path: nothing from the file is applied, except that a
    /// `no_cloud:` block we can still read on its own may *add* rules.
    private static func unapplied(
        _ text: String, retaining previous: MagicEngineConfig, reason: String
    ) -> LoadResult {
        var config = previous
        // Privacy is the one setting that must survive a typo somewhere else
        // in the file (P7), including on a first launch where there is no
        // previous config to retain. Rescue the `no_cloud:` block and union it
        // in — union, not replace, because a file we could not read is allowed
        // to tighten a rule, never to drop one.
        if let salvaged = salvagedNoCloud(from: text) {
            config.noCloud = previous.noCloud + salvaged.filter { !previous.noCloud.contains($0) }
        }
        return LoadResult(
            config: config,
            warnings: ["\(reason) — config.yaml was NOT applied; the previous settings (no_cloud rules included) stay in effect until the file is fixed"],
            applied: false
        )
    }

    /// Best-effort recovery of just the `no_cloud:` entry from a file the
    /// parser rejected as a whole: the top-level line plus any indented
    /// continuation, re-parsed as a document of its own. Deliberately routed
    /// back through `FrontmatterParser` rather than split by hand, so quoting,
    /// comments, and list forms behave exactly as they do in a healthy file.
    /// Returns nil when the key is absent or is itself the broken part.
    static func salvagedNoCloud(from text: String) -> [String]? {
        let lines = text.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: {
            $0.first != " " && $0.first != "\t"
                && $0.trimmingCharacters(in: .whitespaces).hasPrefix("no_cloud:")
        }) else { return nil }

        var end = start + 1
        while end < lines.count, let first = lines[end].first, first == " " || first == "\t" {
            end += 1
        }
        let snippet = (["---"] + Array(lines[start..<end]) + ["---"]).joined(separator: "\n")

        guard let document = try? FrontmatterParser.parse(snippet),
              let value = document.fields["no_cloud"]
        else { return nil }
        switch value {
        case .list(let items):
            return normalized(items)
        case .scalar(let scalar) where !scalar.isEmpty:
            return normalized([scalar])
        default:
            return nil
        }
    }

    /// Entries are matched case-insensitively, so they are stored folded;
    /// empties would match everything and are dropped.
    private static func normalized(_ items: [String]) -> [String] {
        items.map { $0.lowercased() }.filter { !$0.isEmpty }
    }
}

/// Disk-backed store for `config.yaml`, same reload-on-press mtime pattern
/// as the other engine stores.
@MainActor
@Observable
final class EngineConfigStore {
    private(set) var config: MagicEngineConfig = .default
    private(set) var warnings: [String] = []

    @ObservationIgnored private var lastModified: Date = .distantPast
    @ObservationIgnored private var hasLoaded = false

    nonisolated static let fileURL = Constants.Engine.rootDirectory.appendingPathComponent("config.yaml")

    init() {
        reloadIfChanged()
    }

    func reloadIfChanged() {
        let modified = (try? Self.fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
        guard modified != lastModified || !hasLoaded else { return }
        lastModified = modified
        hasLoaded = true

        guard let text = try? String(contentsOf: Self.fileURL, encoding: .utf8) else {
            config = .default
            warnings = []
            return
        }
        // `retaining: config` is what keeps a broken hand edit from resetting
        // live settings — above all `no_cloud` — to their defaults mid-session.
        let result = MagicEngineConfig.load(text, retaining: config)
        config = result.config
        warnings = result.warnings
    }

    /// Sets one integer key in config.yaml, preserving comments and every
    /// other line (the same line-wise edit discipline the Settings
    /// Assistant's `set_config` tool uses). This is how UI toggles write
    /// config-backed switches — config.yaml is the single authority; the
    /// UI is a view over it.
    func setInteger(_ value: Int, forKey key: String) {
        let text = (try? String(contentsOf: Self.fileURL, encoding: .utf8))
            ?? EngineSeedContent.engineConfig
        try? Self.settingInteger(value, forKey: key, in: text)
            .write(to: Self.fileURL, atomically: true, encoding: .utf8)
        reloadIfChanged()
    }

    /// Pure edit: replace the key's line, or insert before the closing
    /// `---` fence (end of file when there is none).
    nonisolated static func settingInteger(_ value: Int, forKey key: String, in text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        if let index = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("\(key):")
        }) {
            lines[index] = "\(key): \(value)"
        } else if let closing = lines.lastIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "---"
        }), closing > 0 {
            lines.insert("\(key): \(value)", at: closing)
        } else {
            lines.append("\(key): \(value)")
        }
        return lines.joined(separator: "\n")
    }
}
