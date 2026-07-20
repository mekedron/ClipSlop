import AppIntents
import CoreSpotlight
import Foundation

/// A prompt from the user's library, exposed to Spotlight, Shortcuts and Siri.
///
/// The App Intents *schema* is compiled into `Metadata.appintents` at build time,
/// but entity **values** are resolved at runtime by `PromptEntityQuery` — which is
/// what lets a prompt the user created a minute ago show up without a rebuild.
struct PromptEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Prompt",
        numericFormat: "\(placeholder: .int) prompts"
    )

    static let defaultQuery = PromptEntityQuery()

    let id: UUID

    @Property(title: "Name")
    var name: String

    @Property(title: "Folder")
    var folderPath: String

    /// Ancestor folder names, kept unjoined so `PromptSearchState.score` receives
    /// them in exactly the shape the in-app "/" search overlay uses.
    let folderComponents: [String]

    /// The in-app keyboard badge (e.g. "S", "⇧F"), used to derive an icon.
    let mnemonic: String

    init(node: PromptNode, path: [String]) {
        self.id = node.id
        self.folderComponents = path
        self.mnemonic = node.mnemonicDisplay
        self.name = node.name
        self.folderPath = path.joined(separator: " / ")
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: folderPath.isEmpty ? "ClipSlop" : "\(folderPath)",
            image: .init(systemName: Self.symbolName(forMnemonic: mnemonic))
        )
    }

    /// `PromptNode` carries no icon, so mirror the mnemonic badge that identifies
    /// the prompt in-app. Anything that isn't a single alphanumeric character
    /// (modifier combos like "⇧F", function keys, the "?" placeholder) has no
    /// matching SF Symbol and falls back to a generic glyph.
    nonisolated static func symbolName(forMnemonic mnemonic: String) -> String {
        guard mnemonic.count == 1,
              let character = mnemonic.lowercased().first,
              character.isASCII,
              character.isLetter || character.isNumber
        else { return "text.bubble" }
        return "\(character).square"
    }
}

extension PromptEntity: IndexedEntity {
    /// What Spotlight itself matches against when the prompt is indexed.
    ///
    /// Deliberately excludes `systemPrompt`. Prompt bodies are private user content
    /// and `CSSearchableIndex` writes into the *system-wide* index, which also lands
    /// in Time Machine backups and outlives the app. Names and folder paths are the
    /// minimum needed to find a prompt; the bodies stay in the app.
    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = name
        attributes.displayName = name
        attributes.contentDescription = folderPath.isEmpty
            ? "ClipSlop prompt"
            : "ClipSlop prompt · \(folderPath)"
        attributes.keywords = Self.keywords(
            name: name,
            folders: folderComponents,
            mnemonic: mnemonic
        )
        attributes.domainIdentifier = PromptEntity.spotlightDomainIdentifier
        return attributes
    }

    static let spotlightDomainIdentifier = "com.mekedron.clipslop.prompt"

    /// Note that Spotlight ranks indexed items with its own matching against these
    /// keywords — `PromptSearchState.score` is *not* consulted there. Our scoring
    /// only governs the Shortcuts picker and Siri disambiguation, so don't go
    /// hunting for a ranking-parity bug that doesn't exist.
    nonisolated static func keywords(
        name: String,
        folders: [String],
        mnemonic: String
    ) -> [String] {
        var result: Set<String> = ["ClipSlop", "prompt", "AI"]
        result.formUnion(folders)
        result.formUnion(
            name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        )
        if mnemonic.count == 1 {
            result.insert(mnemonic)
        }
        return Array(result)
    }
}
