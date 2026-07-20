import AppIntents
import Foundation

/// Resolves `PromptEntity` values at runtime from the live prompt library.
///
/// Conforms to both query protocols on purpose:
/// - `EnumerableEntityQuery` gives Shortcuts the full picker list and supplies
///   `suggestedEntities()`, which parameterised App Shortcut phrases require —
///   without it those phrases silently never appear.
/// - `EntityStringQuery` lets us substitute the in-app scorer so ranking matches
///   what the "/" search overlay does.
struct PromptEntityQuery: EntityStringQuery, EnumerableEntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [PromptEntity] {
        let wanted = Set(identifiers)
        return await PromptLibrarySnapshot.current().filter { wanted.contains($0.id) }
    }

    func allEntities() async throws -> [PromptEntity] {
        await PromptLibrarySnapshot.current()
    }

    func suggestedEntities() async throws -> [PromptEntity] {
        await PromptLibrarySnapshot.current()
    }

    func entities(matching string: String) async throws -> [PromptEntity] {
        PromptEntityRanking.rank(await PromptLibrarySnapshot.current(), query: string)
    }
}

/// The single `@MainActor` hop shared by every query path.
enum PromptLibrarySnapshot {
    static func current() async -> [PromptEntity] {
        let fromRunningApp = await MainActor.run { () -> [PromptEntity]? in
            guard let promptStore = AppState.shared?.promptStore else { return nil }
            // `allPromptNodesWithPaths()` returns leaves only — folders are not
            // runnable, so they must not become entities.
            return promptStore.allPromptNodesWithPaths().map(PromptEntity.init(node:path:))
        }
        if let fromRunningApp { return fromRunningApp }

        // Fall back to reading the library straight off disk.
        //
        // The system can ask for entity values without the app being up — to fill
        // a Spotlight parameter picker, for instance. Returning [] there would
        // render as "No Results" and look like a broken feature, when in fact the
        // library is just a JSON file we can read without any of the app's state.
        return diskSnapshot()
    }

    /// Reads and flattens `prompts.json` with no dependency on `AppState`.
    nonisolated static func diskSnapshot() -> [PromptEntity] {
        guard let data = try? Data(contentsOf: Constants.promptsFileURL),
              let nodes = try? JSONDecoder().decode([PromptNode].self, from: data)
        else { return [] }
        return PromptStore.promptNodesWithPaths(in: nodes).map(PromptEntity.init(node:path:))
    }
}

/// Ranking, kept pure and off the main actor so it is directly testable.
enum PromptEntityRanking {
    nonisolated static func rank(_ entities: [PromptEntity], query: String) -> [PromptEntity] {
        let tokens = PromptSearchState.tokenize(query)
        guard !tokens.isEmpty else {
            return entities.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }

        return entities
            .compactMap { entity -> (entity: PromptEntity, score: Int)? in
                PromptSearchState
                    .score(name: entity.name, path: entity.folderComponents, tokens: tokens)
                    .map { (entity, $0) }
            }
            // Same tie-break as the in-app overlay: score descending, then name.
            .sorted {
                $0.score != $1.score
                    ? $0.score > $1.score
                    : $0.entity.name.localizedCaseInsensitiveCompare($1.entity.name) == .orderedAscending
            }
            .map(\.entity)
    }
}
