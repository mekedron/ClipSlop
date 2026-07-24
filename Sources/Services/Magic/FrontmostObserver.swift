import AppKit
@preconcurrency import ApplicationServices
import os

/// Cheap context kept warm by the frontmost-app observer (§5.1): identity of
/// the focused field plus the two attributes that are expensive to discover
/// at press time (URL needs an ancestor walk, title a window hop). The press
/// uses it only as a fallback keyed on the focused element still matching —
/// AXUIElements have no stable identity, so misses are tolerated by design.
/// Field value, selection, and the secure flag are never cached: they are
/// stale the moment the user types.
struct WarmContext: Sendable {
    let pid: pid_t
    let bundleId: String?
    let windowTitle: String?
    let url: String?
    let focusedElement: AXElementRef?
    let fieldRole: String?
    let capturedAt: Date

    /// The cache-split rule (§5.1): same process, within TTL.
    func isUsable(forPid pid: pid_t, at now: Date = Date(), ttlSeconds: Int) -> Bool {
        self.pid == pid && now.timeIntervalSince(capturedAt) <= Double(ttlSeconds)
    }
}

/// AXObserver callbacks are C function pointers; the refcon carries the
/// observer instance. The run-loop source lives on the main run loop, so
/// assuming main-actor isolation here is sound.
private let frontmostAXCallback: AXObserverCallback = { _, _, _, refcon in
    guard let refcon else { return }
    let service = Unmanaged<FrontmostObserver>.fromOpaque(refcon).takeUnretainedValue()
    MainActor.assumeIsolated {
        service.noteFocusEvent()
    }
}

/// The M1 observer subsystem (§5.1): exactly one `AXObserver`, scoped to the
/// frontmost app, created and torn down by `NSWorkspace` activation events —
/// no background fleet. On every (debounced) focus or title change it takes a
/// cheap single-attribute snapshot; the deep surrounding walk never runs
/// here. Activating a Chromium/Electron app also triggers the accessibility
/// enablement immediately, so the lazy AX tree is built long before the
/// first press instead of during it.
@MainActor
final class FrontmostObserver {
    private(set) var warm: WarmContext?

    private var axObserver: AXObserver?
    private var observedPid: pid_t = -1
    private var refreshTask: Task<Void, Never>?
    private var started = false

    private let snapshotService: AXSnapshotService
    private let configProvider: @MainActor () -> MagicEngineConfig
    private static let logger = Logger(subsystem: Constants.bundleIdentifier, category: "engine.warm")

    private static let notifications: [String] = [
        kAXFocusedUIElementChangedNotification,
        kAXFocusedWindowChangedNotification,
        kAXTitleChangedNotification,
    ]

    init(snapshotService: AXSnapshotService, configProvider: @escaping @MainActor () -> MagicEngineConfig) {
        self.snapshotService = snapshotService
        self.configProvider = configProvider
    }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            MainActor.assumeIsolated { self?.appActivated(app) }
        }
        center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            MainActor.assumeIsolated { self?.appTerminated(app) }
        }

        if let app = NSWorkspace.shared.frontmostApplication {
            appActivated(app)
        }
    }

    /// Pure attach decision, extracted for tests. Our own app activating (a
    /// chip panel taking key) must NOT tear down the observer on the target —
    /// the press returns there in a moment.
    nonisolated static func shouldAttach(
        bundleId: String?,
        pid: pid_t,
        observedPid: pid_t,
        ownBundleId: String?,
        observerEnabled: Bool
    ) -> Bool {
        guard observerEnabled, pid > 0, pid != observedPid else { return false }
        guard bundleId == nil || bundleId != ownBundleId else { return false }
        return true
    }

    private func appActivated(_ app: NSRunningApplication) {
        guard PermissionService.isAccessibilityGranted else { return }
        guard Self.shouldAttach(
            bundleId: app.bundleIdentifier,
            pid: app.processIdentifier,
            observedPid: observedPid,
            ownBundleId: Bundle.main.bundleIdentifier,
            observerEnabled: configProvider().warmObserverEnabled != 0
        ) else { return }

        detach()
        attach(to: app)
    }

    private func appTerminated(_ app: NSRunningApplication) {
        guard app.processIdentifier == observedPid else { return }
        detach()
        warm = nil
    }

    private func attach(to app: NSRunningApplication) {
        let pid = app.processIdentifier
        var created: AXObserver?
        guard AXObserverCreate(pid, frontmostAXCallback, &created) == .success, let created else {
            Self.logger.debug("AXObserverCreate failed for pid \(pid)")
            return
        }

        observedPid = pid
        axObserver = created
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let appElement = AXUIElementCreateApplication(pid)
        for name in Self.notifications {
            // Some apps reject individual notifications — best-effort each.
            AXObserverAddNotification(created, appElement, name as CFString, refcon)
        }
        CFRunLoopAddSource(
            CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode
        )

        // Chromium/Electron enablement now, not at press time: the renderer
        // builds its AX tree while the user is still reading the page.
        Task { [snapshotService] in await snapshotService.warmUp(pid: pid) }
        scheduleRefresh(immediate: true)
    }

    private func detach() {
        refreshTask?.cancel()
        refreshTask = nil
        if let axObserver {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObserver), .defaultMode
            )
        }
        axObserver = nil
        observedPid = -1
    }

    // MARK: - Cheap refresh

    func noteFocusEvent() {
        scheduleRefresh(immediate: false)
    }

    /// Debounced (~200 ms, configurable): click-around must not turn into an
    /// AX-read storm. The read itself runs on the snapshot actor's executor —
    /// no AX I/O on the main thread.
    private func scheduleRefresh(immediate: Bool) {
        refreshTask?.cancel()
        let config = configProvider()
        guard config.warmObserverEnabled != 0 else { return }
        let debounceMs = immediate ? 0 : config.observerDebounceMs
        let pid = observedPid

        refreshTask = Task { [weak self] in
            if debounceMs > 0 {
                try? await Task.sleep(for: .milliseconds(debounceMs))
            }
            guard !Task.isCancelled, let self else { return }
            guard let app = NSWorkspace.shared.frontmostApplication,
                  app.processIdentifier == pid
            else { return }
            let appInfo = MagicSnapshot.AppInfo(
                name: app.localizedName, bundleId: app.bundleIdentifier, pid: pid
            )
            let context = await self.snapshotService.cheapCapture(appInfo: appInfo, config: config)
            guard !Task.isCancelled, self.observedPid == pid else { return }
            self.warm = context
        }
    }
}
