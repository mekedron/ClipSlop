import Foundation

enum SyncStatus: Equatable, Sendable {
    case disabled
    case unavailable
    case current
    case syncing
    case error(String)
}

@MainActor
@Observable
final class CloudSyncService {
    private(set) var status: SyncStatus = .disabled

    private weak var promptStore: PromptStore?
    private var metadataQuery: NSMetadataQuery?
    private var containerURL: URL?
    private var debounceTask: Task<Void, Never>?
    private var lastUploadHash: Int?
    private var identityObserver: Any?

    private let containerID: String? = nil // nil = default container from entitlements
    private let syncFileName = "prompts.json"

    private var documentsURL: URL? {
        containerURL?.appendingPathComponent("Documents")
    }

    private var cloudFileURL: URL? {
        documentsURL?.appendingPathComponent(syncFileName)
    }

    // MARK: - Public API

    func start(promptStore: PromptStore) {
        self.promptStore = promptStore
        status = .syncing

        // Discover ubiquity container on background thread (can block)
        Task.detached { [weak self] in
            let url = FileManager.default.url(forUbiquityContainerIdentifier: nil)
            await MainActor.run {
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
    }

    func stop() {
        stopMetadataQuery()
        debounceTask?.cancel()
        debounceTask = nil
        containerURL = nil
        lastUploadHash = nil
        if let identityObserver {
            NotificationCenter.default.removeObserver(identityObserver)
        }
        identityObserver = nil
        status = .disabled
    }

    /// Called by PromptStore.onPromptsChanged when local prompts are saved.
    func handleLocalChange(data: Data) {
        let hash = data.hashValue
        // Skip if this is data we just uploaded (prevent echo)
        if hash == lastUploadHash { return }

        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await self?.uploadToCloud(data)
        }
    }

    // MARK: - Initial Sync

    private func performInitialSync() {
        guard let cloudFileURL else { return }

        let fm = FileManager.default
        if fm.fileExists(atPath: cloudFileURL.path) {
            // Cloud file exists — download if needed, then compare dates
            triggerDownloadIfNeeded(cloudFileURL)
            resolveConflict()
        } else {
            // No cloud file — upload local prompts
            if let data = try? Data(contentsOf: Constants.promptsFileURL) {
                uploadToCloud(data)
            }
        }
    }

    private func resolveConflict() {
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

            // Compare modification dates — newer wins
            let fm = FileManager.default
            let cloudDate = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date ?? .distantPast
            let localDate = (try? fm.attributesOfItem(atPath: Constants.promptsFileURL.path))?[.modificationDate] as? Date ?? .distantPast

            if cloudDate > localDate {
                // Cloud is newer — apply to local
                applyRemoteData(cloudData)
            } else if localDate > cloudDate {
                // Local is newer — upload to cloud
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
        guard let cloudFileURL else { return }

        status = .syncing

        // Ensure the file is downloaded
        triggerDownloadIfNeeded(cloudFileURL)

        let coordinator = NSFileCoordinator()
        var error: NSError?

        coordinator.coordinate(readingItemAt: cloudFileURL, options: [], error: &error) { url in
            guard let data = try? Data(contentsOf: url) else {
                status = .current
                return
            }

            let hash = data.hashValue
            // Skip if this matches what we last uploaded
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
        let fm = FileManager.default
        do {
            try fm.startDownloadingUbiquitousItem(at: url)
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
            // File is downloaded and ready
            handleRemoteChange()
        } else {
            // Not yet downloaded — trigger download
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
            guard let self else { return }
            // User signed in/out of iCloud — re-check availability
            if FileManager.default.ubiquityIdentityToken == nil {
                self.stop()
                self.status = .unavailable
            }
        }
    }

    // MARK: - Helpers

    private func ensureDocumentsDirectory() {
        guard let documentsURL else { return }
        try? FileManager.default.createDirectory(at: documentsURL, withIntermediateDirectories: true)
    }
}
