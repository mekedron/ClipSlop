import Foundation

/// JSON document persisted to disk and exchanged via iCloud sync /
/// import/export. Wraps the tile array with a version + the grid column
/// preference so the whole Quick Access configuration travels together.
struct QuickAccessDocument: Codable, Sendable {
    var version: Int
    var gridColumns: Int
    var tiles: [QuickAccessTile]

    init(version: Int = 1, gridColumns: Int = 2, tiles: [QuickAccessTile] = []) {
        self.version = version
        self.gridColumns = gridColumns
        self.tiles = tiles
    }
}

/// Owns the Quick Access tile grid: tiles + grid columns. Persisted to
/// `Constants.quickAccessFileURL`, with one-time migration from the old
/// UserDefaults storage so existing users keep their configuration.
@MainActor
@Observable
final class QuickAccessStore {
    private(set) var tiles: [QuickAccessTile] = []
    private(set) var gridColumns: Int = 2

    /// Fires with the encoded document whenever a local change happens.
    /// CloudSyncService hooks into this for upload.
    var onChanged: ((_ data: Data) -> Void)?

    /// While true, applying a remote sync write — suppresses onChanged so
    /// we don't bounce the same change back to the cloud.
    private var isSyncing = false

    init() {
        let settings = AppSettings.shared
        let defaults = UserDefaults.standard

        // Users on the build where the auto-update toggle was introduced may
        // already have a disk file (from the UserDefaults→disk migration in
        // the previous version) or legacy UserDefaults data, but no explicit
        // `useDefaultQuickAccess` setting. If the setting was never set AND
        // we find existing customization, opt them out of auto-update so we
        // don't clobber their tiles. They can re-enable from settings.
        let neverSetExplicitly = defaults.object(forKey: "useDefaultQuickAccess") == nil
        if neverSetExplicitly,
           Self.diskFileHasTiles() || Self.userDefaultsHasTiles() {
            settings.useDefaultQuickAccess = false
        }

        if settings.useDefaultQuickAccess {
            // Always refresh defaults on launch — new tiles shipped with
            // app updates will appear automatically.
            let doc = Self.defaultDocument()
            tiles = doc.tiles
            gridColumns = Self.clampColumns(doc.gridColumns)
            saveLocally()
        } else if let doc = Self.loadFromDisk() {
            tiles = doc.tiles
            gridColumns = Self.clampColumns(doc.gridColumns)
        } else if let migrated = Self.migrateFromUserDefaults() {
            tiles = migrated.tiles
            gridColumns = Self.clampColumns(migrated.gridColumns)
            saveLocally()
        }
    }

    // MARK: - Mutations

    func updateTiles(_ newTiles: [QuickAccessTile]) {
        tiles = newTiles
        saveAndNotify()
        markCustomized()
    }

    func setGridColumns(_ value: Int) {
        let clamped = Self.clampColumns(value)
        guard clamped != gridColumns else { return }
        gridColumns = clamped
        saveAndNotify()
        markCustomized()
    }

    func removeTile(withID id: UUID) {
        tiles.removeAll { $0.id == id }
        saveAndNotify()
        markCustomized()
    }

    /// Reset tiles + grid columns to the bundled defaults and re-enable
    /// `useDefaultQuickAccess` so future app updates can refresh them.
    func restoreDefaults() {
        let doc = Self.defaultDocument()
        tiles = doc.tiles
        gridColumns = Self.clampColumns(doc.gridColumns)
        saveAndNotify()
        AppSettings.shared.useDefaultQuickAccess = true
    }

    // MARK: - Import / Export

    func exportJSON() -> Data? {
        try? JSONEncoder.pretty.encode(currentDocument)
    }

    func importJSON(from data: Data) throws {
        let doc = try JSONDecoder().decode(QuickAccessDocument.self, from: data)
        tiles = doc.tiles
        gridColumns = Self.clampColumns(doc.gridColumns)
        saveAndNotify()
        markCustomized()
    }

    // MARK: - iCloud sync application

    /// Applied by `CloudSyncService` when remote data arrives. Saves to disk
    /// but does NOT fire `onChanged`, preventing an echo back to the cloud.
    /// Also marks the local install as customized — the cloud copy reflects
    /// someone's choices, so we shouldn't overwrite it with defaults next
    /// launch.
    func replaceFromSync(_ data: Data) {
        guard let doc = try? JSONDecoder().decode(QuickAccessDocument.self, from: data) else { return }
        isSyncing = true
        tiles = doc.tiles
        gridColumns = Self.clampColumns(doc.gridColumns)
        saveToDisk(doc)
        isSyncing = false
        AppSettings.shared.useDefaultQuickAccess = false
    }

    // MARK: - Private

    private var currentDocument: QuickAccessDocument {
        QuickAccessDocument(gridColumns: gridColumns, tiles: tiles)
    }

    private func markCustomized() {
        AppSettings.shared.useDefaultQuickAccess = false
    }

    private func saveLocally() {
        saveToDisk(currentDocument)
    }

    private func saveAndNotify() {
        let doc = currentDocument
        saveToDisk(doc)
        guard !isSyncing else { return }
        if let data = try? JSONEncoder.pretty.encode(doc) {
            onChanged?(data)
        }
    }

    private func saveToDisk(_ doc: QuickAccessDocument) {
        guard let data = try? JSONEncoder.pretty.encode(doc) else { return }
        try? data.write(to: Constants.quickAccessFileURL)
    }

    private static func loadFromDisk() -> QuickAccessDocument? {
        guard FileManager.default.fileExists(atPath: Constants.quickAccessFileURL.path),
              let data = try? Data(contentsOf: Constants.quickAccessFileURL),
              let doc = try? JSONDecoder().decode(QuickAccessDocument.self, from: data)
        else { return nil }
        return doc
    }

    private static func diskFileHasTiles() -> Bool {
        loadFromDisk().map { !$0.tiles.isEmpty } ?? false
    }

    private static func userDefaultsHasTiles() -> Bool {
        guard let data = UserDefaults.standard.data(forKey: "quickAccessTiles"),
              let tiles = try? JSONDecoder().decode([QuickAccessTile].self, from: data)
        else { return false }
        return !tiles.isEmpty
    }

    /// One-shot UserDefaults → disk migration. Reads the legacy keys, writes
    /// them to the on-disk document, then removes them so the migration only
    /// runs once.
    private static func migrateFromUserDefaults() -> QuickAccessDocument? {
        let defaults = UserDefaults.standard
        let storedColumns = defaults.object(forKey: "quickAccessGridColumns") as? Int
        let storedTilesData = defaults.data(forKey: "quickAccessTiles")
        let hadAnything = storedColumns != nil || storedTilesData != nil
        guard hadAnything else { return nil }

        let migratedTiles: [QuickAccessTile]
        if let data = storedTilesData,
           let decoded = try? JSONDecoder().decode([QuickAccessTile].self, from: data) {
            migratedTiles = decoded
        } else {
            migratedTiles = []
        }
        let columns = storedColumns ?? 2

        defaults.removeObject(forKey: "quickAccessGridColumns")
        defaults.removeObject(forKey: "quickAccessTiles")

        return QuickAccessDocument(gridColumns: columns, tiles: migratedTiles)
    }

    private static func clampColumns(_ value: Int) -> Int {
        max(1, min(8, value))
    }

    // MARK: - Defaults

    /// UUIDs match the entries in `DefaultPrompts.json` — the bundled prompts
    /// always carry these IDs, so default tiles resolve to real prompts on a
    /// fresh install (and continue to resolve after the user customizes the
    /// prompts library as long as they haven't deleted these specific ones).
    private static func defaultDocument() -> QuickAccessDocument {
        let yourPrompt = UUID(uuidString: "FD5545B3-C0BE-4D4C-927B-4EC4104C9C3D")!
        let fixGrammar = UUID(uuidString: "3B9EDEAA-8E0F-49E9-BFD4-B30EF9947BBD")!
        let reformat = UUID(uuidString: "541F791B-B1F6-4282-A22B-AE9A63B1742B")!
        let cleanUp = UUID(uuidString: "D616C293-3B13-47FD-84FB-315A92D0F7F0")!
        let tldr = UUID(uuidString: "C1DB2D6B-91A3-4F87-8D93-BEF61850CAD9")!
        let summary = UUID(uuidString: "36FC6C25-871F-4446-88E5-AF779D6C3F17")!
        let keyPoints = UUID(uuidString: "A1B2C3D4-E5F6-4A7B-8C9D-0E1F2A3B4C5D")!
        let actionItems = UUID(uuidString: "B2C3D4E5-F6A7-4B8C-9D0E-1F2A3B4C5D6E")!

        let tiles: [QuickAccessTile] = [
            QuickAccessTile(promptID: yourPrompt, method: .openInPopup),
            QuickAccessTile(promptID: fixGrammar, method: .inline),
            QuickAccessTile(promptID: reformat, method: .inline),
            QuickAccessTile(promptID: cleanUp, method: .inline),
            QuickAccessTile(promptID: tldr, method: .openInPopup),
            QuickAccessTile(promptID: summary, method: .openInPopup),
            QuickAccessTile(promptID: keyPoints, method: .openInPopup),
            QuickAccessTile(promptID: actionItems, method: .openInPopup),
        ]
        return QuickAccessDocument(gridColumns: 2, tiles: tiles)
    }
}
