import Foundation
import Testing
@testable import ClipSlop

/// Pure-logic tests for the App Intents layer. Everything covered here was
/// deliberately extracted as `nonisolated static` so it can be exercised without
/// a running app, CoreSpotlight, or the main actor — the surrounding intent
/// plumbing needs a live system and is verified manually instead.

@Suite("Provider resolution")
struct ProviderResolutionTests {

    private func provider(name: String, isDefault: Bool = false) -> AIProviderConfig {
        AIProviderConfig(name: name, providerType: .anthropic, isDefault: isDefault)
    }

    @Test("Prompt-specific override wins over the default")
    func overrideWins() {
        let preferred = provider(name: "Preferred")
        let fallback = provider(name: "Fallback", isDefault: true)
        let resolved = ProviderStore.resolve(preferring: preferred.id, in: [fallback, preferred])
        #expect(resolved?.id == preferred.id)
    }

    @Test("An override pointing at a deleted provider falls back to the default")
    func staleOverrideFallsBack() {
        // A prompt keeps its providerID after the user deletes that provider in
        // Settings, so this is a real state — not a hypothetical.
        let fallback = provider(name: "Fallback", isDefault: true)
        let resolved = ProviderStore.resolve(preferring: UUID(), in: [fallback])
        #expect(resolved?.id == fallback.id)
    }

    @Test("With no explicit default, the first provider is used")
    func firstWhenNoDefault() {
        let first = provider(name: "First")
        let second = provider(name: "Second")
        #expect(ProviderStore.resolve(preferring: nil, in: [first, second])?.id == first.id)
    }

    @Test("No providers resolves to nil")
    func emptyResolvesToNil() {
        #expect(ProviderStore.resolve(preferring: nil, in: []) == nil)
        #expect(ProviderStore.resolve(preferring: UUID(), in: []) == nil)
    }
}

@Suite("PromptEntity derivation")
struct PromptEntityTests {

    private func promptNode(_ name: String, mnemonic: String = "?") -> PromptNode {
        PromptNode(name: name, mnemonicKey: mnemonic, nodeType: .prompt, systemPrompt: "body")
    }

    @Test("A root-level prompt has an empty folder path")
    func rootPromptHasNoPath() {
        let entity = PromptEntity(node: promptNode("Summary"), path: [])
        #expect(entity.name == "Summary")
        #expect(entity.folderPath.isEmpty)
        #expect(entity.folderComponents.isEmpty)
    }

    @Test("A nested prompt joins its ancestor folders")
    func nestedPromptJoinsPath() {
        let entity = PromptEntity(node: promptNode("TL;DR"), path: ["Analyze", "Long"])
        #expect(entity.folderPath == "Analyze / Long")
        // Kept unjoined too, because the scorer weighs path components separately.
        #expect(entity.folderComponents == ["Analyze", "Long"])
    }

    @Test("Single alphanumeric mnemonics map to an SF Symbol")
    func mnemonicSymbols() {
        #expect(PromptEntity.symbolName(forMnemonic: "S") == "s.square")
        #expect(PromptEntity.symbolName(forMnemonic: "7") == "7.square")
    }

    @Test("Mnemonics with no matching symbol fall back to a generic glyph",
          arguments: ["⇧F", "F5", "?", "", "⌫"])
    func mnemonicFallback(_ mnemonic: String) {
        #expect(PromptEntity.symbolName(forMnemonic: mnemonic) == "text.bubble")
    }

    @Test("Keywords include folders and word-split name parts")
    func keywords() {
        let keywords = Set(
            PromptEntity.keywords(name: "Fix Grammar", folders: ["Writing"], mnemonic: "G")
        )
        #expect(keywords.contains("Fix"))
        #expect(keywords.contains("Grammar"))
        #expect(keywords.contains("Writing"))
        #expect(keywords.contains("G"))
        #expect(keywords.contains("ClipSlop"))
    }

    @Test("Multi-character mnemonics are not added as keywords")
    func multiCharMnemonicExcluded() {
        let keywords = Set(PromptEntity.keywords(name: "Fix", folders: [], mnemonic: "⇧F"))
        #expect(!keywords.contains("⇧F"))
    }
}

@Suite("PromptEntity ranking")
struct PromptEntityRankingTests {

    private func entity(_ name: String, path: [String] = []) -> PromptEntity {
        PromptEntity(
            node: PromptNode(name: name, mnemonicKey: "?", nodeType: .prompt, systemPrompt: "body"),
            path: path
        )
    }

    @Test("An empty query returns everything, alphabetically")
    func emptyQuerySortsAlphabetically() {
        let ranked = PromptEntityRanking.rank([entity("Zebra"), entity("Alpha")], query: "  ")
        #expect(ranked.map(\.name) == ["Alpha", "Zebra"])
    }

    @Test("A token matching neither name nor path excludes the entity")
    func nonMatchingTokenExcludes() {
        let ranked = PromptEntityRanking.rank([entity("Summary")], query: "translate")
        #expect(ranked.isEmpty)
    }

    @Test("A name hit outranks a path hit")
    func nameOutranksPath() {
        let byName = entity("Writing")
        let byPath = entity("Summary", path: ["Writing"])
        let ranked = PromptEntityRanking.rank([byPath, byName], query: "writing")
        #expect(ranked.first?.name == "Writing")
        #expect(ranked.count == 2)
    }

    @Test("All tokens must match — this is AND, not OR")
    func tokensAreAnded() {
        let entities = [entity("Fix Grammar", path: ["Writing"])]
        #expect(PromptEntityRanking.rank(entities, query: "fix writing").count == 1)
        #expect(PromptEntityRanking.rank(entities, query: "fix nonsense").isEmpty)
    }

    @Test("Matching is case- and diacritic-insensitive")
    func caseAndDiacriticInsensitive() {
        #expect(PromptEntityRanking.rank([entity("Résumé")], query: "resume").count == 1)
        #expect(PromptEntityRanking.rank([entity("Résumé")], query: "RÉSUMÉ").count == 1)
    }
}

@Suite("Intent error mapping")
struct IntentErrorMappingTests {

    @Test("Credential failures map to a sign-in message")
    func credentialFailures() {
        for error in [AIServiceError.missingAPIKey, .oauthLoginRequired, .oauthTokenExpired] {
            #expect(ClipSlopIntentError.wrap(error).isProviderNeedsSignIn)
        }
        #expect(ClipSlopIntentError.wrap(AIServiceError.httpError(statusCode: 401, body: ""))
            .isProviderNeedsSignIn)
    }

    @Test("A large error body is truncated")
    func largeBodyTruncated() {
        // httpError interpolates the raw response body for un-special-cased
        // statuses, so without a cap a provider could dump kilobytes of JSON into
        // a Spotlight error banner.
        let error = AIServiceError.httpError(statusCode: 418, body: String(repeating: "x", count: 10_000))
        guard case .failed(let message) = ClipSlopIntentError.wrap(error) else {
            Issue.record("expected .failed")
            return
        }
        #expect(message.count <= 200)
    }

    @Test("Non-AIServiceError errors still produce a bounded message")
    func genericErrorWrapped() {
        struct Boom: LocalizedError {
            var errorDescription: String? { String(repeating: "y", count: 5_000) }
        }
        guard case .failed(let message) = ClipSlopIntentError.wrap(Boom()) else {
            Issue.record("expected .failed")
            return
        }
        #expect(message.count <= 200)
    }
}

@Suite("Spotlight index diffing")
struct SpotlightIndexDiffTests {

    private func entity(_ id: UUID) -> PromptEntity {
        PromptEntity(
            node: PromptNode(id: id, name: "P", mnemonicKey: "?", nodeType: .prompt, systemPrompt: "b"),
            path: []
        )
    }

    @Test("An unchanged library deletes nothing")
    func unchangedDeletesNothing() {
        let id = UUID()
        let result = PromptSpotlightIndexer.diff(previous: [id], current: [entity(id)])
        #expect(result.toDelete.isEmpty)
        #expect(result.toIndex.count == 1)
    }

    @Test("A removed prompt is scheduled for deletion")
    func removedPromptDeleted() {
        let kept = UUID()
        let removed = UUID()
        let result = PromptSpotlightIndexer.diff(previous: [kept, removed], current: [entity(kept)])
        #expect(result.toDelete == [removed])
    }

    @Test("A newly added prompt is indexed but deletes nothing")
    func addedPromptIndexed() {
        let existing = UUID()
        let added = UUID()
        let result = PromptSpotlightIndexer.diff(
            previous: [existing],
            current: [entity(existing), entity(added)]
        )
        #expect(result.toDelete.isEmpty)
        #expect(Set(result.toIndex.map(\.id)) == [existing, added])
    }
}

@Suite("Intent dialog formatting")
struct IntentDialogFormatterTests {

    @Test("Short text is returned trimmed and unchanged")
    func shortTextUnchanged() {
        #expect(IntentDialogFormatter.summarize("  hello  ") == "hello")
    }

    @Test("Long text is truncated with an ellipsis")
    func longTextTruncated() {
        let summary = IntentDialogFormatter.summarize(String(repeating: "a", count: 500), limit: 100)
        #expect(summary.count == 101)
        #expect(summary.hasSuffix("…"))
    }
}

private extension ClipSlopIntentError {
    var isProviderNeedsSignIn: Bool {
        if case .providerNeedsSignIn = self { return true }
        return false
    }
}
