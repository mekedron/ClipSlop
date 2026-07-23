import Foundation

/// User-tunable engine parameters, read from `~/.clipslop/config.yaml`
/// (files-first, §15). Every value is clamped to a sane range — a typo in a
/// hand-edited file degrades to the nearest safe bound, never to a hung
/// press or an unbounded walk.
struct MagicEngineConfig: Sendable, Equatable {
    /// Overall snapshot deadline — the press never waits longer for capture.
    var captureDeadlineMs = 1600
    /// AX call budget for the native (non-web) surrounding walk.
    var axCallBudget = 350
    /// AX call budget for web-content walks (Chromium wraps everything in
    /// AXGroups, so web needs far more calls).
    var webCallBudget = 900
    /// Depth of the text gather inside one native sibling subtree.
    var maxGatherDepth = 6
    /// Depth cap inside web subtrees.
    var maxWebDepth = 30
    /// Siblings visited per level in the native walk.
    var maxSiblingsPerLevel = 16
    /// Children visited per node in web subtrees.
    var maxWebChildrenPerNode = 60
    /// Cap on the assembled surrounding text.
    var surroundingMaxChars = 6000
    /// Web walk: how much text preceding the field to keep (a chat's newest
    /// messages) and how much after it.
    var webBeforeKeepChars = 4500
    var webAfterKeepChars = 1000
    /// Cap on the focused field's own value read.
    var fieldValueMaxChars = 50_000
    /// Post-insert toast auto-dismiss.
    var toastDismissSeconds = 8

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
        ("surrounding_max_chars", 500...50_000, \.surroundingMaxChars),
        ("web_before_keep_chars", 200...40_000, \.webBeforeKeepChars),
        ("web_after_keep_chars", 0...20_000, \.webAfterKeepChars),
        ("field_value_max_chars", 1_000...500_000, \.fieldValueMaxChars),
        ("toast_dismiss_seconds", 2...120, \.toastDismissSeconds),
        ]
    }

    /// Parses the config file (same constrained YAML subset as workflow
    /// frontmatter). Missing keys keep their defaults; out-of-range values
    /// clamp with a warning; unknown keys warn and are ignored.
    static func parse(_ text: String) -> (config: MagicEngineConfig, warnings: [String]) {
        var config = MagicEngineConfig.default
        var warnings: [String] = []

        let document: FrontmatterDocument
        do {
            document = try FrontmatterParser.parse(text)
        } catch let error as FrontmatterError {
            return (config, ["line \(error.line): \(error.message) — using defaults"])
        } catch {
            return (config, ["could not parse config — using defaults"])
        }

        let known = Dictionary(uniqueKeysWithValues: ranges().map { ($0.key, $0) })
        for (key, value) in document.fields {
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
        return (config, warnings)
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
        (config, warnings) = MagicEngineConfig.parse(text)
    }
}
