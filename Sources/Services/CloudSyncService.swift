import Foundation

enum SyncStatus: Equatable, Sendable {
    case disabled
    case unavailable
    case current
    case syncing
    case pendingConflict   // First sync on device, iCloud has existing data — needs user choice
    case error(String)
}

@MainActor
@Observable
final class CloudSyncService {
    private(set) var status: SyncStatus = .disabled

    /// Holds cloud prompt data while waiting for user to resolve first-sync conflict.
    private(set) var pendingCloudPrompts: [PromptNode]?

    private weak var promptStore: PromptStore?
    private var metadataQuery: NSMetadataQuery?
    private var containerURL: URL?
    private var debounceTask: Task<Void, Never>?
    private var lastUploadHash: Int?
    private var identityObserver: Any?

    private let containerID: String? = nil // nil = default container from entitlements
    private let syncFileName = "prompts.json"

    /// True after the very first sync completes on this device.
    private var hasCompletedInitialSync: Bool {
        get { UserDefaults.standard.bool(forKey: "cloudSync.hasCompletedInitialSync") }
        set { UserDefaults.standard.set(newValue, forKey: "cloudSync.hasCompletedInitialSync") }
    }

    private var documentsURL: URL? {
        containerURL?.appendingPathComponent("Documents")
    }

    private var cloudFileURL: URL? {
        documentsURL?.appendingPathComponent(syncFileName)
    }

    // MARK: - Public API

    func start(promptStore: PromptStore) {
        self.promptStore = promptStore

        // Quick pre-check: if no iCloud account at all, bail immediately
        guard FileManager.default.ubiquityIdentityToken != nil else {
            status = .unavailable
            return
        }

        status = .syncing

        // Discover ubiquity container on background thread with timeout
        Task { @MainActor [weak self] in
            let url: URL? = await withTaskGroup(of: URL?.self) { group in
                group.addTask {
                    FileManager.default.url(forUbiquityContainerIdentifier: nil)
                }
                group.addTask {
                    try? await Task.sleep(for: .seconds(5))
                    return nil
                }
                // Return whichever finishes first
                for await result in group {
                    group.cancelAll()
                    return result
                }
                return nil
            }

            guard let self else { return }
            guard let url else {
                self.status = .unavailable
                return
            }
            self.containerURL = url
            self.ensureDocumentsDirectory()
            self.performInitialSync()
            self.startMetadataQuery()
            self.observeIdentityChanges()
        }
    }

    func stop() {
        stopMetadataQuery()
        debounceTask?.cancel()
        debounceTask = nil
        containerURL = nil
        lastUploadHash = nil
        pendingCloudPrompts = nil
        if let identityObserver {
            NotificationCenter.default.removeObserver(identityObserver)
        }
        identityObserver = nil
        status = .disabled
    }

    /// Called by PromptStore.onPromptsChanged when local prompts are saved.
    func handleLocalChange(data: Data) {
        guard status != .pendingConflict else { return }
        let hash = data.hashValue
        if hash == lastUploadHash { return }

        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await self?.uploadToCloud(data)
        }
    }

    // MARK: - Conflict Resolution (user actions)

    /// User chose "Use iCloud" — replace local prompts with cloud data.
    func resolveUseCloud() {
        guard let nodes = pendingCloudPrompts else { return }
        pendingCloudPrompts = nil
        promptStore?.replaceFromSync(nodes)
        // Upload the resolved data back so hashes stay in sync
        if let data = try? JSONEncoder.pretty.encode(nodes) {
            uploadToCloud(data)
        }
        hasCompletedInitialSync = true
        status = .current
    }

    /// User chose "Keep local" — upload local prompts to iCloud.
    func resolveUseLocal() {
        pendingCloudPrompts = nil
        if let data = try? Data(contentsOf: Constants.promptsFileURL) {
            uploadToCloud(data)
        }
        hasCompletedInitialSync = true
        status = .current
    }

    // MARK: - Initial Sync

    private func performInitialSync() {
        guard let cloudFileURL else { return }

        let fm = FileManager.default
        if fm.fileExists(atPath: cloudFileURL.path) {
            triggerDownloadIfNeeded(cloudFileURL)

            if hasCompletedInitialSync {
                // Normal ongoing sync — auto-resolve by date
                resolveByDate()
            } else {
                // First sync on this device — check if cloud has meaningful data
                presentConflictChoice()
            }
        } else {
            // No cloud file — upload local prompts
            if let data = try? Data(contentsOf: Constants.promptsFileURL) {
                uploadToCloud(data)
            }
            hasCompletedInitialSync = true
            status = .current
        }
    }

    /// First-time sync: read cloud data and let the user decide.
    private func presentConflictChoice() {
        guard let cloudFileURL else { return }

        let coordinator = NSFileCoordinator()
        var error: NSError?

        coordinator.coordinate(readingItemAt: cloudFileURL, options: [], error: &error) { url in
            guard let data = try? Data(contentsOf: url),
                  let nodes = try? JSONDecoder().decode([PromptNode].self, from: data),
                  !nodes.isEmpty
            else {
                // Cloud file is empty or unreadable — just upload local
                if let localData = try? Data(contentsOf: Constants.promptsFileURL) {
                    uploadToCloud(localData)
                }
                hasCompletedInitialSync = true
                status = .current
                return
            }

            pendingCloudPrompts = nodes
            status = .pendingConflict
        }

        if let error {
            status = .error(error.localizedDescription)
        }
    }

    /// Ongoing sync conflict resolution — newer file wins.
    private func resolveByDate() {
        guard let cloudFileURL else { return }

        let coordinator = NSFileCoordinator()
        var error: NSError?

        coordinator.coordinate(readingItemAt: cloudFileURL, options: [], error: &error) { url in
            guard let cloudData = try? Data(contentsOf: url),
                  let localData = try? Data(contentsOf: Constants.promptsFileURL)
            else {
                status = .current
                return
            }

            let fm = FileManager.default
            let cloudDate = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date ?? .distantPast
            let localDate = (try? fm.attributesOfItem(atPath: Constants.promptsFileURL.path))?[.modificationDate] as? Date ?? .distantPast

            if cloudDate > localDate {
                applyRemoteData(cloudData)
            } else if localDate > cloudDate {
                uploadToCloud(localData)
            }
            status = .current
        }

        if let error {
            status = .error(error.localizedDescription)
        }
    }

    // MARK: - Upload

    private func uploadToCloud(_ data: Data) {
        guard let cloudFileURL else { return }

        status = .syncing
        lastUploadHash = data.hashValue

        let coordinator = NSFileCoordinator()
        var error: NSError?

        coordinator.coordinate(writingItemAt: cloudFileURL, options: .forReplacing, error: &error) { url in
            do {
                try data.write(to: url)
                status = .current
            } catch {
                status = .error(error.localizedDescription)
            }
        }

        if let error {
            status = .error(error.localizedDescription)
        }
    }

    // MARK: - Download / Remote Changes

    private func handleRemoteChange() {
        guard let cloudFileURL, status != .pendingConflict else { return }

        status = .syncing
        triggerDownloadIfNeeded(cloudFileURL)

        let coordinator = NSFileCoordinator()
        var error: NSError?

        coordinator.coordinate(readingItemAt: cloudFileURL, options: [], error: &error) { url in
            guard let data = try? Data(contentsOf: url) else {
                status = .current
                return
            }

            let hash = data.hashValue
            if hash == lastUploadHash {
                status = .current
                return
            }

            applyRemoteData(data)
            status = .current
        }

        if let error {
            status = .error(error.localizedDescription)
        }
    }

    private func applyRemoteData(_ data: Data) {
        guard let nodes = try? JSONDecoder().decode([PromptNode].self, from: data) else { return }
        lastUploadHash = data.hashValue
        promptStore?.replaceFromSync(nodes)
    }

    private func triggerDownloadIfNeeded(_ url: URL) {
        do {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
        } catch {
            // File might already be downloaded — not an error
        }
    }

    // MARK: - NSMetadataQuery

    private func startMetadataQuery() {
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(
            format: "%K == %@",
            NSMetadataItemFSNameKey,
            syncFileName
        )

        NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering,
            object: query,
            queue: .main
        ) { [weak self] _ in
            self?.processQueryResults()
        }

        NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidUpdate,
            object: query,
            queue: .main
        ) { [weak self] _ in
            self?.processQueryResults()
        }

        query.start()
        metadataQuery = query
    }

    private func stopMetadataQuery() {
        metadataQuery?.stop()
        if let query = metadataQuery {
            NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidFinishGathering, object: query)
            NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidUpdate, object: query)
        }
        metadataQuery = nil
    }

    private func processQueryResults() {
        guard let query = metadataQuery else { return }
        query.disableUpdates()
        defer { query.enableUpdates() }

        guard query.resultCount > 0,
              let item = query.result(at: 0) as? NSMetadataItem
        else { return }

        let downloadStatus = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String

        if downloadStatus == NSMetadataUbiquitousItemDownloadingStatusCurrent {
            handleRemoteChange()
        } else {
            if let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL {
                triggerDownloadIfNeeded(url)
            }
        }
    }

    // MARK: - Identity Changes

    private func observeIdentityChanges() {
        identityObserver = NotificationCenter.default.addObserver(
            forName: .NSUbiquityIdentityDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if FileManager.default.ubiquityIdentityToken == nil {
                    self.stop()
                    self.status = .unavailable
                }
            }
        }
    }

    // MARK: - Helpers

    private func ensureDocumentsDirectory() {
        guard let documentsURL else { return }
        try? FileManager.default.createDirectory(at: documentsURL, withIntermediateDirectories: true)
    }
}
