import Foundation

enum SyncStatus: Equatable, Sendable {
    case disabled
    case unavailable
    case current
    case syncing
    case pendingConflict
    case error(String)
}

@MainActor
@Observable
final class CloudSyncService {
    private(set) var status: SyncStatus = .disabled
    private(set) var pendingCloudPrompts: [PromptNode]?

    private weak var promptStore: PromptStore?
    private var metadataQuery: NSMetadataQuery?
    private var containerURL: URL?
    private var debounceTask: Task<Void, Never>?
    private var lastUploadHash: Int?
    private var identityObserver: Any?

    private let syncFileName = "prompts.json"

    private var hasCompletedInitialSync: Bool {
        get { UserDefaults.standard.bool(forKey: "cloudSync.hasCompletedInitialSync") }
        set { UserDefaults.standard.set(newValue, forKey: "cloudSync.hasCompletedInitialSync") }
    }

    private var documentsURL: URL? { containerURL?.appendingPathComponent("Documents") }
    private var cloudFileURL: URL? { documentsURL?.appendingPathComponent(syncFileName) }

    // MARK: - Public API

    func start(promptStore: PromptStore) {
        self.promptStore = promptStore

        guard FileManager.default.ubiquityIdentityToken != nil else {
            status = .unavailable
            return
        }

        status = .syncing

        // Container discovery — completely off main thread
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
                self.startMetadataQuery()
                self.observeIdentityChanges()
                // Initial sync also off main thread
                self.performInitialSyncAsync()
            }
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
        guard let nodes = pendingCloudPrompts else { return }
        pendingCloudPrompts = nil
        promptStore?.replaceFromSync(nodes)
        if let data = try? JSONEncoder.pretty.encode(nodes) {
            uploadToCloudAsync(data)
        }
        hasCompletedInitialSync = true
        status = .current
    }

    func resolveUseLocal() {
        pendingCloudPrompts = nil
        if let data = try? Data(contentsOf: Constants.promptsFileURL) {
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
            if let data = try? Data(contentsOf: Constants.promptsFileURL) {
                uploadToCloudAsync(data)
            }
            hasCompletedInitialSync = true
            status = .current
            return
        }

        triggerDownloadIfNeeded(cloudFileURL)

        if hasCompletedInitialSync {
            resolveByDateAsync()
        } else {
            presentConflictChoiceAsync()
        }
    }

    private func presentConflictChoiceAsync() {
        guard let cloudFileURL else { return }

        Task.detached { [weak self] in
            let result = Self.coordinatedRead(at: cloudFileURL)
            await MainActor.run {
                guard let self else { return }
                switch result {
                case .success(let data):
                    if let nodes = try? JSONDecoder().decode([PromptNode].self, from: data), !nodes.isEmpty {
                        self.pendingCloudPrompts = nodes
                        self.status = .pendingConflict
                    } else {
                        self.uploadLocalAndFinish()
                    }
                case .failure(let error):
                    self.status = .error(error.localizedDescription)
                }
            }
        }
    }

    private func resolveByDateAsync() {
        guard let cloudFileURL else { return }

        Task.detached { [weak self] in
            let result = Self.coordinatedRead(at: cloudFileURL)
            await MainActor.run {
                guard let self else { return }
                switch result {
                case .success(let cloudData):
                    guard let localData = try? Data(contentsOf: Constants.promptsFileURL) else {
                        self.status = .current
                        return
                    }

                    let fm = FileManager.default
                    let cloudDate = (try? fm.attributesOfItem(atPath: cloudFileURL.path))?[.modificationDate] as? Date ?? .distantPast
                    let localDate = (try? fm.attributesOfItem(atPath: Constants.promptsFileURL.path))?[.modificationDate] as? Date ?? .distantPast

                    if cloudDate > localDate {
                        self.applyRemoteData(cloudData)
                    } else if localDate > cloudDate {
                        self.uploadToCloudAsync(localData)
                    }
                    self.status = .current

                case .failure:
                    self.status = .current
                }
            }
        }
    }

    // MARK: - Upload (async)

    private func uploadToCloudAsync(_ data: Data) {
        guard let cloudFileURL else { return }

        status = .syncing
        lastUploadHash = data.hashValue
        let url = cloudFileURL

        Task.detached { [weak self] in
            let result = Self.coordinatedWrite(data: data, to: url)
            await MainActor.run {
                guard let self else { return }
                switch result {
                case .success:
                    self.status = .current
                case .failure(let error):
                    self.status = .error(error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Download / Remote Changes

    private func handleRemoteChangeAsync() {
        guard let cloudFileURL, status != .pendingConflict else { return }

        status = .syncing
        triggerDownloadIfNeeded(cloudFileURL)

        Task.detached { [weak self] in
            let result = Self.coordinatedRead(at: cloudFileURL)
            await MainActor.run {
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
    }

    private func applyRemoteData(_ data: Data) {
        guard let nodes = try? JSONDecoder().decode([PromptNode].self, from: data) else { return }
        lastUploadHash = data.hashValue
        promptStore?.replaceFromSync(nodes)
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
        if let data = try? Data(contentsOf: Constants.promptsFileURL) {
            uploadToCloudAsync(data)
        }
        hasCompletedInitialSync = true
        status = .current
    }
}
