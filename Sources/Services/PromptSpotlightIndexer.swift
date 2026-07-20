import AppIntents
import CoreSpotlight
import Foundation
import os

/// Keeps the system's view of the prompt library up to date.
///
/// Two jobs, both driven by the same signal:
///  1. `updateAppShortcutParameters()` — tells App Intents to re-fetch entity
///     values. Parameterised App Shortcut phrases show "No Results" until the
///     system has successfully fetched entities at least once, so this must run
///     on first launch, not only on change.
///  2. CoreSpotlight indexing — makes prompts findable by name in ⌘Space rather
///     than only selectable as a parameter. User-controllable via
///     `AppSettings.spotlightIndexingEnabled`.
@MainActor
final class PromptSpotlightIndexer {
    static let shared = PromptSpotlightIndexer()

    private static let indexedIDsKey = "spotlight.indexedPromptIDs"
    private static let schemaVersionKey = "spotlight.indexSchemaVersion"
    /// Bump whenever `PromptEntity.attributeSet` changes, otherwise stale
    /// attributes linger in the system index with nothing to invalidate them.
    private static let schemaVersion = 1

    /// Failures here are non-fatal by design, so they must at least be visible:
    ///   log stream --predicate 'subsystem == "com.mekedron.clipslop"'
    private static let log = Logger(subsystem: "com.mekedron.clipslop", category: "spotlight")

    private var observer: NSObjectProtocol?
    private var debounceTask: Task<Void, Never>?
    private weak var promptStore: PromptStore?

    private init() {}

    func start(promptStore: PromptStore) {
        self.promptStore = promptStore

        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .clipSlopPromptLibraryDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleRefresh()
            }
        }

        // Initial pass, deferred so the menu bar renders first — same reasoning as
        // the iCloud sync delay in AppState.setup().
        scheduleRefresh(delay: .seconds(2))
    }

    func settingChanged(enabled: Bool) {
        if enabled {
            scheduleRefresh(delay: .milliseconds(100))
        } else {
            Task { await Self.deleteAllIndexedPrompts() }
        }
    }

    /// Debounced because editing a prompt autosaves on **every keystroke**
    /// (`PromptsSettingsView` wires `autoSave()` to `.onChange` of the name and
    /// body fields), so an undebounced handler would hammer CoreSpotlight
    /// throughout typing.
    private func scheduleRefresh(delay: Duration = .milliseconds(750)) {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    private func refresh() async {
        guard let promptStore else {
            Self.log.error("refresh skipped: promptStore reference was released")
            return
        }
        let entities = promptStore.allPromptNodesWithPaths().map(PromptEntity.init(node:path:))
        Self.log.notice("refresh: \(entities.count) prompt(s)")

        if AppSettings.shared.spotlightIndexingEnabled {
            await Self.reindex(entities)
        } else {
            Self.log.notice("indexing disabled by setting; skipping CoreSpotlight")
        }

        // Runs regardless of the indexing setting: this drives the parameter
        // picker for Spotlight/Siri phrases, which is not the same feature as
        // publishing searchable items.
        do {
            try await ClipSlopShortcuts.updateAppShortcutParameters()
            Self.log.notice("updateAppShortcutParameters succeeded")
        } catch {
            Self.log.error("updateAppShortcutParameters failed: \(error.localizedDescription)")
        }
    }

    private static func reindex(_ entities: [PromptEntity]) async {
        let defaults = UserDefaults.standard
        let needsFullRebuild = defaults.integer(forKey: schemaVersionKey) != schemaVersion
        let previous: Set<UUID> = needsFullRebuild
            ? []
            : Set((defaults.stringArray(forKey: indexedIDsKey) ?? []).compactMap(UUID.init(uuidString:)))

        let staleIDs = Array(previous.subtracting(entities.map(\.id)))

        do {
            if needsFullRebuild {
                try await CSSearchableIndex.default().deleteSearchableItems(
                    withDomainIdentifiers: [PromptEntity.spotlightDomainIdentifier]
                )
            } else if !staleIDs.isEmpty {
                // Incremental rather than delete-all: wiping the whole domain first
                // would leave a window where nothing is findable.
                try await CSSearchableIndex.default().deleteAppEntities(
                    identifiedBy: staleIDs,
                    ofType: PromptEntity.self
                )
            }

            try await CSSearchableIndex.default().indexAppEntities(entities)

            defaults.set(entities.map(\.id.uuidString), forKey: indexedIDsKey)
            defaults.set(schemaVersion, forKey: schemaVersionKey)
            log.notice("indexed \(entities.count) prompt(s), deleted \(staleIDs.count) stale")
        } catch {
            // Spotlight is an enhancement — never block or fail the app over it,
            // but do say so rather than failing silently.
            log.error("CoreSpotlight indexing failed: \(error.localizedDescription)")
        }
    }

    private static func deleteAllIndexedPrompts() async {
        try? await CSSearchableIndex.default().deleteSearchableItems(
            withDomainIdentifiers: [PromptEntity.spotlightDomainIdentifier]
        )
        UserDefaults.standard.removeObject(forKey: indexedIDsKey)
        UserDefaults.standard.removeObject(forKey: schemaVersionKey)
    }

    /// Pure — the stale-deletion logic, extracted so it is testable without
    /// touching CoreSpotlight.
    nonisolated static func diff(
        previous: Set<UUID>,
        current: [PromptEntity]
    ) -> (toDelete: [UUID], toIndex: [PromptEntity]) {
        (Array(previous.subtracting(current.map(\.id))), current)
    }
}
