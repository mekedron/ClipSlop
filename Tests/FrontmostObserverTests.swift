import Foundation
import Testing
@testable import ClipSlop

@Suite("Warm frontmost observer")
struct FrontmostObserverTests {
    private func makeWarm(pid: pid_t = 42, capturedAt: Date) -> WarmContext {
        WarmContext(
            pid: pid, bundleId: "com.example.app",
            windowTitle: "Inbox", url: "https://mail.example.com/thread/1",
            focusedElement: nil, fieldRole: "AXTextArea", capturedAt: capturedAt
        )
    }

    // MARK: - Cache-split rule (§5.1): same pid, within TTL

    @Test func warmContextFreshWithinTTL() {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let warm = makeWarm(capturedAt: now.addingTimeInterval(-10))
        #expect(warm.isUsable(forPid: 42, at: now, ttlSeconds: 30))
    }

    @Test func warmContextExpiresAfterTTL() {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let warm = makeWarm(capturedAt: now.addingTimeInterval(-31))
        #expect(!warm.isUsable(forPid: 42, at: now, ttlSeconds: 30))
    }

    @Test func warmContextExactTTLBoundaryIsStillUsable() {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let warm = makeWarm(capturedAt: now.addingTimeInterval(-30))
        #expect(warm.isUsable(forPid: 42, at: now, ttlSeconds: 30))
    }

    @Test func warmContextForOtherProcessIsNeverUsable() {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let warm = makeWarm(pid: 42, capturedAt: now)
        #expect(!warm.isUsable(forPid: 43, at: now, ttlSeconds: 30))
    }

    // MARK: - Attach decision

    @Test func attachesToANewFrontmostApp() {
        #expect(FrontmostObserver.shouldAttach(
            bundleId: "com.google.Chrome", pid: 100, observedPid: -1,
            ownBundleId: "com.clipslop.app", observerEnabled: true
        ))
    }

    @Test func ownAppActivationKeepsTheCurrentObserver() {
        // A chip panel taking key activates ClipSlop; tearing down the
        // observer on the target app would lose the warm context the press
        // is about to return to.
        #expect(!FrontmostObserver.shouldAttach(
            bundleId: "com.clipslop.app", pid: 7, observedPid: 100,
            ownBundleId: "com.clipslop.app", observerEnabled: true
        ))
    }

    @Test func reactivatingTheObservedAppDoesNotRebuild() {
        #expect(!FrontmostObserver.shouldAttach(
            bundleId: "com.google.Chrome", pid: 100, observedPid: 100,
            ownBundleId: "com.clipslop.app", observerEnabled: true
        ))
    }

    @Test func killSwitchBlocksAttachment() {
        #expect(!FrontmostObserver.shouldAttach(
            bundleId: "com.google.Chrome", pid: 100, observedPid: -1,
            ownBundleId: "com.clipslop.app", observerEnabled: false
        ))
    }

    @Test func invalidPidNeverAttaches() {
        #expect(!FrontmostObserver.shouldAttach(
            bundleId: nil, pid: -1, observedPid: -1,
            ownBundleId: "com.clipslop.app", observerEnabled: true
        ))
    }

    // MARK: - Trace plumbing

    @Test func warmHitAndAxErrorsReachTheTrace() {
        var snapshot = MagicTestSupport.makeSnapshot()
        snapshot.warmHit = true
        snapshot.axCannotComplete = 3
        let trace = PressTrace(snapshot: snapshot, decision: nil, classification: nil)
        #expect(trace.warmHit)
        #expect(trace.axErrors == 3)
    }
}
