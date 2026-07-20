import Foundation

/// Bridges the gap between an App Intent's `nonisolated perform()` and the
/// `@MainActor` app.
enum AppStateBridge {
    /// Waits for `AppState.shared` to be published.
    ///
    /// Spotlight can dispatch an intent that *causes* the launch, so `perform()`
    /// may start running while `setup()` is still wiring things up. Without this
    /// the first invocation after a cold start would fail with "no prompts found"
    /// — a flake that looks like a broken feature and is near-impossible to
    /// reproduce on a warm app.
    ///
    /// Returns `Bool` rather than `AppState?` deliberately: `AppState` is
    /// `@MainActor` and not `Sendable`, so handing it back to nonisolated code
    /// would not compile. Callers re-read `AppState.shared` inside their own hop.
    static func waitUntilReady(timeout: Duration = .seconds(5)) async -> Bool {
        if await MainActor.run(body: { AppState.shared != nil }) { return true }

        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if Task.isCancelled { return false }
            try? await Task.sleep(for: .milliseconds(50))
            if await MainActor.run(body: { AppState.shared != nil }) { return true }
        }
        return false
    }
}
