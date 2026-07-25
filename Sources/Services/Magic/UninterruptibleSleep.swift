import Foundation

/// A delay a cancelled task still waits out.
///
/// `Task.sleep` returns the instant its task is cancelled, so a poll loop paced
/// by it stops being paced the moment anyone cancels: the sleep becomes a
/// no-op and the loop spends the rest of its deadline in back-to-back
/// cross-process reads — `changeCount` polling against the pasteboard server,
/// AX attribute reads at the 0.35 s messaging timeout — against a target the
/// user has already walked away from. The loop was never long; it was paced,
/// and cancellation removes the pacing rather than the loop.
///
/// Every wait on the press band is bounded by a deadline and not by
/// cancellation, because each one has already posted a keystroke or is holding
/// a pasteboard the target may still read. Collapsing such a wait is not
/// "finish early", it is "stop waiting for something that is still in flight" —
/// and what lands after the loop gave up is then attributed to nobody: a ⌘C
/// whose write arrives once the probe has stopped watching leaves its spoils on
/// the user's clipboard, and a ⌘V's grace period cut short hands a late reader
/// the restored contents instead of ours (R3).
///
/// An unstructured task does not inherit cancellation, so the delay holds while
/// the surrounding work stays free to exit.
enum UninterruptibleSleep {
    static func sleep(for duration: Duration) async {
        let sleeper = Task.detached { try? await Task.sleep(for: duration) }
        _ = await sleeper.value
    }
}
