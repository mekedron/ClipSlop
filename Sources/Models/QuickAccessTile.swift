import Foundation

enum QuickAccessMethod: String, Codable, CaseIterable, Sendable, Identifiable {
    case inline
    case openInPopup

    var id: String { rawValue }

    /// SF Symbol used to denote this method anywhere it's shown — keep in sync with
    /// the prompts library shortcut chips in `PromptsSettingsView.shortcutChip`.
    var iconName: String {
        switch self {
        case .inline: return "doc.on.clipboard"
        case .openInPopup: return "play.fill"
        }
    }
}

struct QuickAccessTile: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var promptID: UUID
    var method: QuickAccessMethod

    init(
        id: UUID = UUID(),
        promptID: UUID,
        method: QuickAccessMethod = .openInPopup
    ) {
        self.id = id
        self.promptID = promptID
        self.method = method
    }
}
