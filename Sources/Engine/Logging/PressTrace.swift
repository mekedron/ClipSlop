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
    /// True when the press had no readable context at all (blind app —
    /// §15.3 forced chips). Written only when true, absent otherwise.
    var contextBlind: Bool?
    /// True when the surroundings were captured as a structured tree
    /// (method "ax_tree_structured") and the prompt's context block was
    /// rendered structure-aware. Contentless; written only when true.
    var surroundingTree: Bool?
    var tier: String
    var candidateIDs: [String]
    var chosenID: String?
    /// "silent" | "chips" | "chips_forced" | "chips_planner"
    /// (`chips_planner` = routing was ambiguous and the fast-mode planner
    /// auto-picked a chip — distinguishable from both silent routing and a
    /// human chip choice, §15.3).
    var presentation: String
    /// Index of the chip the user picked (0-based) — ground truth for top-1
    /// intent accuracy before any Feedback Watcher exists. HUMAN picks
    /// only, by design; planner picks go to `plannerIndexChosen`.
    var chipIndexChosen: Int?
    /// Index of the chip the planner auto-picked (0-based, presentation
    /// "chips_planner"). Never mixed into `chipIndexChosen` — the top-1
    /// metric stays human ground truth.
    var plannerIndexChosen: Int?
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
    /// The surrounding walk stopped on budget/deadline rather than at the
    /// page's edge — the capture is incomplete. Contentless; written only
    /// when true.
    var axBudgetExhausted: Bool?
    var latencyMs: Latency
    /// "inserted" | "insertedAnyway" | "panelOnly" | "focusMismatch" |
    /// "selectionChanged" | "verifierDismissed" | "noCandidates" |
    /// "regenerated" | "undone" | "cancelled" | "copied" | "dismissed" |
    /// "dead:<reason>" | "error:<kind>", any of the insert outcomes optionally
    /// carrying a ":unconfirmed" suffix. `TraceInspector.explain` renders the
    /// same set; keep the two in step.
    var outcome: String

    struct Latency: Codable, Sendable {
        var snapshot: Int = 0
        var route: Int = 0
        var assemble: Int = 0
        var generate: Int = 0
        var verify: Int = 0
        /// Fast-mode planner call duration. Present whenever the planner
        /// ran — with presentation "chips" it means the planner declined
        /// (unsure / timeout / error) and the panel showed anyway.
        var planner: Int?
        /// Press → paste landed (the §3.6 SLO number). Optional: absent on
        /// presses that never inserted and on pre-M1 trace lines.
        var paste: Int?
        /// Press → outcome stamped (includes toast lifetime / user think
        /// time — NOT the SLO number).
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
        contextBlind = snapshot.contextBlind ? true : nil
        surroundingTree = snapshot.surrounding?.tree != nil ? true : nil
        tier = decision.map { String(describing: $0.tier) } ?? "none"
        candidateIDs = decision?.counted.map(\.id) ?? []
        chosenID = nil
        presentation = "silent"
        chipIndexChosen = nil
        plannerIndexChosen = nil
        hintUsed = false
        slotTokens = [:]
        totalTokens = 0
        providerType = nil
        modelID = nil
        verifierPassed = nil
        verifierChecks = []
        warmHit = snapshot.warmHit
        axErrors = snapshot.axCannotComplete
        axBudgetExhausted = snapshot.surrounding?.captureExhausted == true ? true : nil
        latencyMs = Latency()
        outcome = "unknown"
    }
}
