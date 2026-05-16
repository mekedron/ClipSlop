import Foundation

enum SyncStatus: Equatable, Sendable {
    case disabled
    case unavailable
    case current
    case syncing
    case pendingConflict
    case error(String)
}

/// Syncs a single JSON file in the iCloud Documents container. Parametric on
/// file name + local URL + how to apply remote data, so we can have one
/// instance per syncable artifact (prompts library, Quick Access config, …).
@MainActor
@Observable
final class CloudSyncService {
    /// How to handle the initial-sync case where both sides have data.
    enum ConflictResolution: Sendable {
        /// Surface a UI for the user to pick which side to keep. Used for the
        /// prompts library — the cost of dropping the wrong side is high.
        case promptUser
        /// Pick the side with the newer mtime automatically. Used for UI
        /// state like the Quick Access grid where the cost is low and a
        /// modal dialog would be intrusive.
        case newestWins
    }

    private(set) var status: SyncStatus = .disabled
    /// Raw cloud data waiting for a `resolveUseCloud()` decision. Only ever
    /// non-nil when `status == .pendingConflict` and `conflictResolution ==
    /// .promptUser`.
    private(set) var pendingConflictData: Data?

    let syncFileName: String
    let localFileURL: URL
    private let conflictResolution: ConflictResolution

    /// Called on the main actor when remote data should replace local state.
    /// The store wired to this closure is responsible for decoding the bytes.
    var applyRemote: ((Data) -> Void)?

    private var metadataQuery: NSMetadataQuery?
    private var containerURL: URL?
    private var debounceTask: Task<Void, Never>?
    private var lastUploadHash: Int?
    private var identityObserver: Any?

    private var initialSyncFlagKey: String {
        "cloudSync.hasCompletedInitialSync.\(syncFileName)"
    }

    private var hasCompletedInitialSync: Bool {
        get { UserDefaults.standard.bool(forKey: initialSyncFlagKey) }
        set { UserDefaults.standard.set(newValue, forKey: initialSyncFlagKey) }
    }

    private var documentsURL: URL? { containerURL?.appendingPathComponent("Documents") }
    private var cloudFileURL: URL? { documentsURL?.appendingPathComponent(syncFileName) }

    init(
        syncFileName: String,
        localFileURL: URL,
        conflictResolution: ConflictResolution
    ) {
        self.syncFileName = syncFileName
        self.localFileURL = localFileURL
        self.conflictResolution = conflictResolution
    }

    // MARK: - Public API

    func start() {
        guard FileManager.default.ubiquityIdentityToken != nil else {
            status = .unavailable
            return
        }

        status = .syncing

        // Container discovery — off main thread, then back to main actor
        Task { [weak self] in
            let url = await Task.detached {
                FileManager.default.url(forUbiquityContainerIdentifier: nil)
            }.value
            guard let self else { return }
            guard let url else {
                self.status = .unavailable
                return
            }
            self.containerURL = url
            self.ensureDocumentsDirectory()
            self.startMetadataQuery()
            self.observeIdentityChanges()
            self.performInitialSyncAsync()
        }
    }

    func stop() {
        stopMetadataQuery()
        debounceTask?.cancel()
        debounceTask = nil
        containerURL = nil
        lastUploadHash = nil
        pendingConflictData = nil
        if let identityObserver {
            NotificationCenter.default.removeObserver(identityObserver)
        }
        identityObserver = nil
        status = .disabled
    }

    func handleLocalChange(data: Data) {
        guard status != .pendingConflict else { return }
        let hash = data.hashValue
        if hash == lastUploadHash { return }

        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await self?.uploadToCloudAsync(data)
        }
    }

    // MARK: - Conflict Resolution

    func resolveUseCloud() {
        guard let data = pendingConflictData else { return }
        pendingConflictData = nil
        applyRemote?(data)
        uploadToCloudAsync(data)
        hasCompletedInitialSync = true
        status = .current
    }

    func resolveUseLocal() {
        pendingConflictData = nil
        if let data = try? Data(contentsOf: localFileURL) {
            uploadToCloudAsync(data)
        }
        hasCompletedInitialSync = true
        status = .current
    }

    // MARK: - Initial Sync (async — never blocks main thread)

    private func performInitialSyncAsync() {
        guard let cloudFileURL else {
            status = .current
            return
        }

        let fm = FileManager.default
        guard fm.fileExists(atPath: cloudFileURL.path) else {
            // No cloud file — upload local
            if let data = try? Data(contentsOf: localFileURL) {
                uploadToCloudAsync(data)
            }
            hasCompletedInitialSync = true
            status = .current
            return
        }

        triggerDownloadIfNeeded(cloudFileURL)

        if hasCompletedInitialSync {
            resolveByDateAsync()
            return
        }

        switch conflictResolution {
        case .promptUser:
            presentConflictChoiceAsync()
        case .newestWins:
            resolveByDateAsync()
        }
    }

    private func presentConflictChoiceAsync() {
        guard let cloudFileURL else { return }

        Task { [weak self] in
            let result = await Task.detached {
                Self.coordinatedRead(at: cloudFileURL)
            }.value
            guard let self else { return }
            switch result {
            case .success(let data):
                if data.isEmpty {
                    self.uploadLocalAndFinish()
                } else {
                    self.pendingConflictData = data
                    self.status = .pendingConflict
                }
            case .failure(let error):
                self.status = .error(error.localizedDescription)
            }
        }
    }

    private func resolveByDateAsync() {
        guard let cloudFileURL else { return }
        let localURL = localFileURL

        Task { [weak self] in
            let result = await Task.detached {
                Self.coordinatedRead(at: cloudFileURL)
            }.value
            guard let self else { return }
            switch result {
            case .success(let cloudData):
                let fm = FileManager.default
                let cloudDate = (try? fm.attributesOfItem(atPath: cloudFileURL.path))?[.modificationDate] as? Date ?? .distantPast

                // If we have no local file at all, just accept the cloud copy.
                guard fm.fileExists(atPath: localURL.path),
                      let localData = try? Data(contentsOf: localURL) else {
                    if !cloudData.isEmpty {
                        self.applyRemoteData(cloudData)
                    }
                    self.hasCompletedInitialSync = true
                    self.status = .current
                    return
                }

                let localDate = (try? fm.attributesOfItem(atPath: localURL.path))?[.modificationDate] as? Date ?? .distantPast

                if cloudDate > localDate, !cloudData.isEmpty {
                    self.applyRemoteData(cloudData)
                } else if localDate > cloudDate {
                    self.uploadToCloudAsync(localData)
                }
                self.hasCompletedInitialSync = true
                self.status = .current

            case .failure:
                self.status = .current
            }
        }
    }

    // MARK: - Upload (async)

    private func uploadToCloudAsync(_ data: Data) {
        guard let cloudFileURL else { return }

        status = .syncing
        lastUploadHash = data.hashValue
        let url = cloudFileURL

        Task { [weak self] in
            let result = await Task.detached {
                Self.coordinatedWrite(data: data, to: url)
            }.value
            guard let self else { return }
            switch result {
            case .success:
                self.status = .current
            case .failure(let error):
                self.status = .error(error.localizedDescription)
            }
        }
    }

    // MARK: - Download / Remote Changes

    private func handleRemoteChangeAsync() {
        guard let cloudFileURL, status != .pendingConflict else { return }

        status = .syncing
        triggerDownloadIfNeeded(cloudFileURL)

        Task { [weak self] in
            let result = await Task.detached {
                Self.coordinatedRead(at: cloudFileURL)
            }.value
            guard let self else { return }
            switch result {
            case .success(let data):
                let hash = data.hashValue
                if hash != self.lastUploadHash {
                    self.applyRemoteData(data)
                }
                self.status = .current
            case .failure:
                self.status = .current
            }
        }
    }

    private func applyRemoteData(_ data: Data) {
        lastUploadHash = data.hashValue
        applyRemote?(data)
    }

    private func triggerDownloadIfNeeded(_ url: URL) {
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
    }

    // MARK: - NSFileCoordinator helpers (run on background thread ONLY)

    private nonisolated static func coordinatedRead(at url: URL) -> Result<Data, Error> {
        let coordinator = NSFileCoordinator()
        var coordError: NSError?
        var result: Result<Data, Error> = .failure(NSError(domain: "CloudSync", code: -1))

        coordinator.coordinate(readingItemAt: url, options: [], error: &coordError) { readURL in
            if let data = try? Data(contentsOf: readURL) {
                result = .success(data)
            }
        }

        if let coordError {
            return .failure(coordError)
        }
        return result
    }

    private nonisolated static func coordinatedWrite(data: Data, to url: URL) -> Result<Void, Error> {
        let coordinator = NSFileCoordinator()
        var coordError: NSError?
        var result: Result<Void, Error> = .failure(NSError(domain: "CloudSync", code: -1))

        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordError) { writeURL in
            do {
                try data.write(to: writeURL)
                result = .success(())
            } catch {
                result = .failure(error)
            }
        }

        if let coordError {
            return .failure(coordError)
        }
        return result
    }

    // MARK: - NSMetadataQuery

    private func startMetadataQuery() {
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(format: "%K == %@", NSMetadataItemFSNameKey, syncFileName)

        NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main
        ) { [weak self] _ in self?.processQueryResults() }

        NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidUpdate, object: query, queue: .main
        ) { [weak self] _ in self?.processQueryResults() }

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
            handleRemoteChangeAsync()
        } else if let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL {
            triggerDownloadIfNeeded(url)
        }
    }

    // MARK: - Identity Changes

    private func observeIdentityChanges() {
        identityObserver = NotificationCenter.default.addObserver(
            forName: .NSUbiquityIdentityDidChange, object: nil, queue: .main
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

    private func uploadLocalAndFinish() {
        if let data = try? Data(contentsOf: localFileURL) {
            uploadToCloudAsync(data)
        }
        hasCompletedInitialSync = true
        status = .current
    }
}
