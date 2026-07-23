import Foundation

/// Contentless per-press trace (§17). Contentless is enforced by
/// construction: the struct has no fields that could carry field text,
/// output text, surrounding content, window titles, or full URLs — only the
/// URL host survives. A test feeds a snapshot full of sentinel strings
/// through the pipeline and asserts none appear in the encoded trace.
struct PressTrace: Codable, Sendable {
    var ts: Date
    var traceID: UUID
    var situationClass: String
    var appBundleID: String?
    var urlHost: String?
    var grammarRow: String
    var fieldState: String
    var selectionClass: String?
    var selectionWasTie: Bool?
    var tier: String
    var candidateIDs: [String]
    var chosenID: String?
    /// "silent" | "chips" | "chips_forced"
    var presentation: String
    /// Index of the chip the user picked (0-based) — ground truth for top-1
    /// intent accuracy before any Feedback Watcher exists.
    var chipIndexChosen: Int?
    var hintUsed: Bool
    var slotTokens: [String: Int]
    var totalTokens: Int
    var providerType: String?
    var modelID: String?
    var verifierPassed: Bool?
    /// Failed check identifiers only, never the warning text.
    var verifierChecks: [String]
    /// The warm observer had fresh cheap context for this press (§5.1).
    var warmHit: Bool
    /// `kAXErrorCannotComplete` count during capture — the R4 metric.
    var axErrors: Int
    var latencyMs: Latency
    /// "inserted" | "insertedAnyway" | "panelOnly" | "focusMismatch" |
    /// "regenerated" | "cancelled" | "copied" | "dismissed" | "dead:<reason>"
    /// | "error:<kind>"
    var outcome: String

    struct Latency: Codable, Sendable {
        var snapshot: Int = 0
        var route: Int = 0
        var assemble: Int = 0
        var generate: Int = 0
        var verify: Int = 0
        var total: Int = 0
    }

    init(snapshot: MagicSnapshot, decision: RoutingDecision?, classification: SelectionClassification?) {
        ts = snapshot.ts
        traceID = UUID()
        situationClass = decision?.situationClass ?? "unrouted"
        appBundleID = snapshot.app.bundleId
        urlHost = EngineRouter.urlHost(of: snapshot.url)
        grammarRow = String(describing: snapshot.grammarRow)
        fieldState = snapshot.fieldState.rawValue
        selectionClass = classification?.top.rawValue
        selectionWasTie = classification?.isTie
        tier = decision.map { String(describing: $0.tier) } ?? "none"
        candidateIDs = decision?.counted.map(\.id) ?? []
        chosenID = nil
        presentation = "silent"
        chipIndexChosen = nil
        hintUsed = false
        slotTokens = [:]
        totalTokens = 0
        providerType = nil
        modelID = nil
        verifierPassed = nil
        verifierChecks = []
        warmHit = snapshot.warmHit
        axErrors = snapshot.axCannotComplete
        latencyMs = Latency()
        outcome = "unknown"
    }
}
