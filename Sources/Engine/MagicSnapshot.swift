import Foundation
@preconcurrency import ApplicationServices

/// A reference to the AX element that had focus when the snapshot was taken.
/// `AXUIElement` is an immutable CFType and documented thread-safe, but is not
/// annotated `Sendable`; the wrapper carries it across the collector actor
/// boundary. Equality is `CFEqual`, which is how the Inserter re-verifies that
/// focus has not moved before pasting.
struct AXElementRef: @unchecked Sendable, Equatable {
    let element: AXUIElement

    static func == (lhs: Self, rhs: Self) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }
}

/// The field state the interaction grammar routes on (§0 of the design doc).
enum FieldState: String, Sendable, Codable, CaseIterable {
    case empty
    case draft
    case selection
}

/// The grammar row for a press — what the press *means* and where the result
/// goes. Derived deterministically from the focused field; never from content.
enum GrammarRow: Sendable, Equatable {
    /// Empty editable field, no selection → cold draft, paste at caret.
    case emptyField
    /// Editable field holding text, no selection → continue, paste at caret.
    case draft
    /// Selection inside an editable field → the selection is addressed to the
    /// engine (inline brief / rewrite); paste replaces exactly the selection.
    case editableSelection
    /// Selection in a non-editable area → classic transform; result goes to
    /// the panel/clipboard, the field is never written.
    case nonEditableSelection
    /// Secure/password field → the feature is dead, no exceptions.
    case secure
    /// No editable focus and no selection → nothing to act on.
    case noTarget
}

/// Point-in-time capture of the focused field and its surroundings, taken on
/// press (V0 has no warm collector). This is the single contract between the
/// press band (which produces it) and the engine pipeline (which consumes it).
struct MagicSnapshot: Sendable {
    struct AppInfo: Sendable {
        let name: String?
        let bundleId: String?
        let pid: pid_t
    }

    struct SelectionInfo: Sendable, Equatable {
        /// Character range within `field.value` when the app reports one.
        /// Web fields often report text without a usable range.
        let range: Range<Int>?
        let text: String
    }

    struct FieldInfo: Sendable {
        let role: String
        let subrole: String?
        let editable: Bool
        let secure: Bool
        let value: String
        let selection: SelectionInfo?
        let placeholder: String?

        /// True when the selection spans the entire field content — the
        /// "rewrite everything" grammar variant.
        var isFullSelection: Bool {
            guard let selection else { return false }
            if let range = selection.range {
                return range.lowerBound == 0 && range.upperBound >= value.count && !value.isEmpty
            }
            return !value.isEmpty && selection.text == value
        }
    }

    struct Surrounding: Sendable {
        /// How the content was gathered. V0 only implements the AX tree rung
        /// of the ladder (§5.2).
        let method: String
        let author: String?
        let content: String
        /// Always "untrusted" — screen content is data, never instructions (P6).
        let trust: String

        static func axTree(content: String, author: String? = nil) -> Surrounding {
            Surrounding(method: "ax_tree", author: author, content: content, trust: "untrusted")
        }
    }

    let app: AppInfo
    let windowTitle: String?
    let url: String?
    let field: FieldInfo?
    let surrounding: Surrounding?
    let locale: String
    let ts: Date
    let focusedElement: AXElementRef?

    /// Field state for router `when` predicates. Selection wins; otherwise
    /// whitespace-only content counts as empty.
    var fieldState: FieldState {
        guard let field else { return .empty }
        if let selection = field.selection, !selection.text.isEmpty { return .selection }
        let trimmed = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? .empty : .draft
    }

    var grammarRow: GrammarRow { MagicGrammar.classify(field: field) }
}

/// The §0 interaction table as code. Pure and deliberately tiny so the whole
/// matrix is unit-testable.
enum MagicGrammar {
    static func classify(field: MagicSnapshot.FieldInfo?) -> GrammarRow {
        guard let field else { return .noTarget }
        if field.secure { return .secure }

        let hasSelection = (field.selection?.text.isEmpty == false)
        if field.editable {
            if hasSelection { return .editableSelection }
            let trimmed = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? .emptyField : .draft
        }
        return hasSelection ? .nonEditableSelection : .noTarget
    }
}
