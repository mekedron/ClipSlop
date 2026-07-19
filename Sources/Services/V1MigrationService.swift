import AppKit
import Foundation
import Security

/// One-shot migration from v1 (`com.clipslop.app`) to v2 (`com.mekedron.clipslop`).
///
/// v2 is a different bundle identifier from macOS's perspective, so UserDefaults,
/// Keychain, and iCloud are all separate from v1. This service copies the user's
/// data over on first launch. v1 data is left intact so the user can roll back.
///
/// Keychain access is only possible because the v2 entitlements file lists both
/// `$(AppIdentifierPrefix)com.clipslop.app` and `$(AppIdentifierPrefix)com.mekedron.clipslop`
/// in `keychain-access-groups`. CI substitutes the team ID at build time.
enum V1MigrationService {
    static let oldBundleID = "com.clipslop.app"
    static let oldICloudContainerID = "iCloud.com.clipslop.app"

    static let completedKey = "v1MigrationCompleted"
    static let userDefaultsStepKey = "v1MigrationCompleted.userDefaults"
    static let keychainStepKey = "v1MigrationCompleted.keychain"
    static let iCloudStepKey = "v1MigrationCompleted.iCloud"

    /// Posted on the main queue when the async iCloud step finishes (success
    /// or skip). `AppState` waits on this before starting CloudSyncService.
    static let iCloudMigrationDidFinish = Notification.Name("V1MigrationService.iCloudDidFinish")

    /// Allowlist of known UserDefaults keys that should carry over. Keys not
    /// in this list (Apple-internal preferences, transient state) stay behind.
    private static let userDefaultsKeyAllowlist: Set<String> = [
        // AppSettings
        "streamingEnabled", "showInDock", "hasCompletedOnboarding",
        "selectedProviderID", "popupOpacity", "popupWidth", "popupHeight",
        "hideMenuBarIcon", "hideDockIcon", "iCloudSyncEnabled", "useKeyCodes",
        "showImagesInMarkdown", "markdownRenderer", "preserveImageWidths",
        "markdownViewer", "markdownEditor",
        "closeOnEscape", "closeOnCopy", "appColorScheme", "editorMode",
        "richTextMode", "markdownAIOnlyRichText", "useCustomConversionPrompt",
        "customConversionPrompt", "suppressPermissionAlert",
        "useDefaultPrompts", "useDefaultQuickAccess",
        // Misc
        "promptGridHeight", "onboardingStep", "appLanguage",
        // v1.3.5 farewell dialog state — migrate so the dialog stays dismissed
        "v2FarewellNoticeSeenAt", "v2FarewellNoticeDismissed",
    ]

    /// Open-ended key prefixes that should also carry over.
    private static let userDefaultsKeyPrefixes: [String] = [
        "cloudSync.hasCompletedInitialSync.",
        "KeyboardShortcuts_",
        "SU", // Sparkle preferences (SUEnableAutomaticChecks, SULastCheckTime, SUSkippedVersion, etc.)
    ]

    // MARK: - Public entry points

    /// Synchronous migration: UserDefaults + Keychain. Must run BEFORE any
    /// code reads `UserDefaults.standard` or queries Keychain in the v2 app.
    /// Fast (typically <50ms).
    static func runSynchronousMigration() {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: completedKey) { return }

        log("Synchronous migration starting")

        let v1Running = isV1AppRunning()
        if v1Running {
            log("v1 app (\(oldBundleID)) appears to be running; skipping Keychain step to avoid races. Will retry next launch.")
        }

        if !defaults.bool(forKey: userDefaultsStepKey) {
            do {
                let count = try migrateUserDefaults()
                defaults.set(true, forKey: userDefaultsStepKey)
                log("UserDefaults: migrated \(count) keys")
            } catch {
                log("UserDefaults migration failed: \(error.localizedDescription)")
            }
        }

        if !v1Running, !defaults.bool(forKey: keychainStepKey) {
            do {
                let count = try migrateKeychain()
                defaults.set(true, forKey: keychainStepKey)
                log("Keychain: migrated \(count) items")
            } catch {
                log("Keychain migration failed: \(error.localizedDescription)")
            }
        }

        maybeMarkCompleted()
        log("Synchronous migration finished")
    }

    /// iCloud Documents migration. Slow (file I/O over NSFileCoordinator) so
    /// it runs in a detached Task. AppState gates CloudSyncService start on
    /// `iCloudMigrationDidFinish` to avoid a race where v2 uploads empty
    /// files to the NEW container before v1 data is copied over.
    static func runICloudMigration() async {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: iCloudStepKey) {
            await MainActor.run {
                NotificationCenter.default.post(name: iCloudMigrationDidFinish, object: nil)
            }
            return
        }

        if isV1AppRunning() {
            log("iCloud: v1 app still running; skipping iCloud step. Will retry next launch.")
            await MainActor.run {
                NotificationCenter.default.post(name: iCloudMigrationDidFinish, object: nil)
            }
            return
        }

        guard FileManager.default.ubiquityIdentityToken != nil else {
            log("iCloud: user has iCloud Drive disabled; nothing to migrate")
            defaults.set(true, forKey: iCloudStepKey)
            maybeMarkCompleted()
            await MainActor.run {
                NotificationCenter.default.post(name: iCloudMigrationDidFinish, object: nil)
            }
            return
        }

        let oldContainerDocs = oldICloudDocumentsURL()
        guard let newContainerDocs = newICloudDocumentsURL() else {
            log("iCloud: new container not available; will retry next launch")
            await MainActor.run {
                NotificationCenter.default.post(name: iCloudMigrationDidFinish, object: nil)
            }
            return
        }

        try? FileManager.default.createDirectory(at: newContainerDocs, withIntermediateDirectories: true)

        let filesToCopy = ["prompts.json", "quick-access.json"]
        var copied = 0
        for name in filesToCopy {
            let src = oldContainerDocs.appendingPathComponent(name)
            let dst = newContainerDocs.appendingPathComponent(name)
            if copyICloudFile(from: src, to: dst, name: name) {
                copied += 1
            }
        }
        log("iCloud: copied \(copied) of \(filesToCopy.count) files")

        defaults.set(true, forKey: iCloudStepKey)
        maybeMarkCompleted()

        await MainActor.run {
            NotificationCenter.default.post(name: iCloudMigrationDidFinish, object: nil)
        }
    }

    // MARK: - UserDefaults

    private static func migrateUserDefaults() throws -> Int {
        guard let oldDomain = UserDefaults(suiteName: oldBundleID) else { return 0 }
        let newDomain = UserDefaults.standard
        let all = oldDomain.dictionaryRepresentation()

        var copied = 0
        for (key, value) in all {
            if !shouldMigrateUserDefaultsKey(key) { continue }
            // Don't overwrite values already set in v2 (e.g. user already changed something).
            if newDomain.object(forKey: key) != nil { continue }
            newDomain.set(value, forKey: key)
            copied += 1
        }
        return copied
    }

    private static func shouldMigrateUserDefaultsKey(_ key: String) -> Bool {
        if userDefaultsKeyAllowlist.contains(key) { return true }
        for prefix in userDefaultsKeyPrefixes where key.hasPrefix(prefix) {
            return true
        }
        return false
    }

    // MARK: - Keychain

    private static func migrateKeychain() throws -> Int {
        // macOS keychain queries default to the FIRST access group listed in
        // `keychain-access-groups`. To find v1 items we must explicitly target
        // their access group: `TEAMID.com.clipslop.app`. We discover the team
        // ID prefix at runtime by adding a probe item and inspecting its
        // assigned access group.
        guard let legacyGroup = detectLegacyAccessGroup() else {
            log("Keychain: could not detect team-id prefix (binary may be unsigned); skipping")
            return 0
        }
        log("Keychain: querying legacy access group '\(legacyGroup)'")

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: oldBundleID,
            kSecAttrAccessGroup as String: legacyGroup,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return 0 }
        guard status == errSecSuccess else {
            throw KeychainMigrationError.queryFailed(status)
        }
        guard let items = result as? [[String: Any]] else { return 0 }

        var migrated = 0
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                  let data = item[kSecValueData as String] as? Data else { continue }

            // Skip if v2 already has this item (e.g. user re-entered a key).
            if v2HasKeychainItem(account: account) { continue }

            var addQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: Constants.bundleIdentifier,
                kSecAttrAccount as String: account,
                kSecValueData as String: data,
            ]
            // Preserve label/description if present.
            if let label = item[kSecAttrLabel as String] {
                addQuery[kSecAttrLabel as String] = label
            }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus == errSecSuccess || addStatus == errSecDuplicateItem {
                migrated += 1
            } else {
                log("Keychain: failed to add '\(account)' (OSStatus \(addStatus))")
            }
        }
        return migrated
    }

    /// Returns the v1 access group (e.g. `XXXXXXXXXX.com.clipslop.app`) by
    /// briefly writing a probe item to Keychain, reading back the access
    /// group macOS assigned to it (which is `TEAMID.com.mekedron.clipslop`),
    /// and substituting the legacy bundle ID. Returns nil if Keychain access
    /// is unavailable (e.g. unsigned debug builds with no entitlement).
    private static func detectLegacyAccessGroup() -> String? {
        let probeAccount = "_v1MigrationProbe_\(UUID().uuidString)"
        let probeQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.bundleIdentifier,
            kSecAttrAccount as String: probeAccount,
            kSecValueData as String: Data([0]),
        ]
        let addStatus = SecItemAdd(probeQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else { return nil }
        defer { SecItemDelete(probeQuery as CFDictionary) }

        let readQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.bundleIdentifier,
            kSecAttrAccount as String: probeAccount,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let readStatus = SecItemCopyMatching(readQuery as CFDictionary, &result)
        guard readStatus == errSecSuccess,
              let attrs = result as? [String: Any],
              let group = attrs[kSecAttrAccessGroup as String] as? String,
              let dotIdx = group.firstIndex(of: ".") else { return nil }
        let teamID = String(group[..<dotIdx])
        return "\(teamID).\(oldBundleID)"
    }

    private static func v2HasKeychainItem(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.bundleIdentifier,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    enum KeychainMigrationError: LocalizedError {
        case queryFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .queryFailed(let status):
                "Keychain query failed with OSStatus \(status)"
            }
        }
    }

    // MARK: - iCloud

    private static func oldICloudDocumentsURL() -> URL {
        let mobile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents")
        // Apple converts `iCloud.com.clipslop.app` to `iCloud~com~clipslop~app`
        // for the on-disk directory name.
        let folder = oldICloudContainerID.replacingOccurrences(of: ".", with: "~")
        return mobile.appendingPathComponent(folder).appendingPathComponent("Documents")
    }

    private static func newICloudDocumentsURL() -> URL? {
        guard let container = FileManager.default.url(forUbiquityContainerIdentifier: nil) else {
            return nil
        }
        return container.appendingPathComponent("Documents")
    }

    /// Returns true on successful copy. Idempotent: skips when the destination
    /// already has equal-or-newer content.
    private static func copyICloudFile(from src: URL, to dst: URL, name: String) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: src.path) else {
            log("iCloud: '\(name)' not present in old container (nothing to copy)")
            return false
        }

        if fm.fileExists(atPath: dst.path) {
            let srcDate = (try? fm.attributesOfItem(atPath: src.path))?[.modificationDate] as? Date ?? .distantPast
            let dstDate = (try? fm.attributesOfItem(atPath: dst.path))?[.modificationDate] as? Date ?? .distantPast
            if dstDate >= srcDate {
                log("iCloud: '\(name)' in new container is already up-to-date")
                return false
            }
        }

        let coordinator = NSFileCoordinator()
        var coordErr: NSError?
        var data: Data?

        coordinator.coordinate(readingItemAt: src, options: [], error: &coordErr) { readURL in
            data = try? Data(contentsOf: readURL)
        }
        if let coordErr {
            log("iCloud: read coordination failed for '\(name)': \(coordErr.localizedDescription)")
            return false
        }
        guard let data else {
            log("iCloud: could not read '\(name)' from old container")
            return false
        }

        var writeErr: NSError?
        var success = false
        coordinator.coordinate(writingItemAt: dst, options: .forReplacing, error: &writeErr) { writeURL in
            do {
                try data.write(to: writeURL)
                success = true
            } catch {
                log("iCloud: write failed for '\(name)': \(error.localizedDescription)")
            }
        }
        if let writeErr {
            log("iCloud: write coordination failed for '\(name)': \(writeErr.localizedDescription)")
            return false
        }
        if success {
            log("iCloud: copied '\(name)' (\(data.count) bytes)")
        }
        return success
    }

    // MARK: - Bookkeeping

    private static func isV1AppRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == oldBundleID }
    }

    private static func maybeMarkCompleted() {
        let d = UserDefaults.standard
        if d.bool(forKey: userDefaultsStepKey),
           d.bool(forKey: keychainStepKey),
           d.bool(forKey: iCloudStepKey) {
            d.set(true, forKey: completedKey)
            log("All migration steps complete — master flag set")
        }
    }

    // MARK: - Logging

    private static let logURL: URL = Constants.appSupportDirectory
        .appendingPathComponent("migration-v1-to-v2.log")

    private static func makeLogFormatter() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }

    private static func log(_ message: String) {
        let line = "[\(makeLogFormatter().string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        let fm = FileManager.default
        if !fm.fileExists(atPath: logURL.path) {
            try? data.write(to: logURL)
            return
        }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }
}
