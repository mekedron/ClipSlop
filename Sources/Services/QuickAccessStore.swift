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
        if let doc = Self.loadFromDisk() {
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
    }

    func setGridColumns(_ value: Int) {
        let clamped = Self.clampColumns(value)
        guard clamped != gridColumns else { return }
        gridColumns = clamped
        saveAndNotify()
    }

    func removeTile(withID id: UUID) {
        tiles.removeAll { $0.id == id }
        saveAndNotify()
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
    }

    // MARK: - iCloud sync application

    /// Applied by `CloudSyncService` when remote data arrives. Saves to disk
    /// but does NOT fire `onChanged`, preventing an echo back to the cloud.
    func replaceFromSync(_ data: Data) {
        guard let doc = try? JSONDecoder().decode(QuickAccessDocument.self, from: data) else { return }
        isSyncing = true
        tiles = doc.tiles
        gridColumns = Self.clampColumns(doc.gridColumns)
        saveToDisk(doc)
        isSyncing = false
    }

    // MARK: - Private

    private var currentDocument: QuickAccessDocument {
        QuickAccessDocument(gridColumns: gridColumns, tiles: tiles)
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
}
