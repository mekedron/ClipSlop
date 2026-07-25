import AppKit
import os

/// Synthetic keystrokes, factored out of the three call sites that used to
/// inline the CGEvent dance. Same primitives as the legacy paths: session
/// event source, HID tap.
@MainActor
enum SyntheticKeystroke {
    static let keyC: CGKeyCode = 0x08
    static let keyV: CGKeyCode = 0x09
    static let keyZ: CGKeyCode = 0x06
    static let keyA: CGKeyCode = 0x00

    static func post(_ key: CGKeyCode, flags: CGEventFlags = .maskCommand) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

/// Pasteboard mechanics for the Magic Button (§3.5): transient/concealed
/// marker types so clipboard managers skip our writes, `changeCount`
/// verification instead of fixed sleeps, and restore-only-if-untouched.
/// `ClipboardService` stays as-is for the legacy popup paths.
@MainActor
enum PasteboardTransaction {
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    /// `nonisolated` so `readSaved` can log from `readQueue`. `Logger` is
    /// `Sendable`, and os_log is itself thread-safe.
    nonisolated private static let logger = Logger(
        subsystem: Constants.bundleIdentifier, category: "engine.pasteboard"
    )

    /// The thread `save()`'s bulk read runs on.
    ///
    /// That read walks every representation of every pasteboard item and copies
    /// the bytes — synchronous IPC to the pasteboard server, bounded only by
    /// `saveBudgetBytes`, i.e. up to a quarter of a gigabyte for a screenshot
    /// carried as TIFF + PNG + PDF. On the main actor that is a stall on the
    /// insert path at the exact moment the user is watching for their paste,
    /// which is the same reason capture and the insert path's AX I/O are off the
    /// main actor (R4, `AXFieldReader`).
    ///
    /// A dedicated serial queue rather than an `actor`: an actor guarantees the
    /// reads never overlap, but not that they share a thread, and `NSPasteboard`
    /// is only safe under single-thread use. One queue gives both.
    ///
    /// Only the *read* moves. `writeGenerated`, `restore` and
    /// `markCurrentItemGenerated` are O(1) type declarations rather than bulk
    /// copies, and they sit inside the save → write → paste → confirm → grace →
    /// restore transaction whose ordering is load bearing — putting suspension
    /// points between those steps would buy nothing and reopen every window the
    /// press band's guards were written to close.
    nonisolated private static let readQueue = DispatchQueue(
        label: "\(Constants.bundleIdentifier).pasteboard-read", qos: .userInitiated
    )

    /// A fuse against a pasteboard that should not exist — NOT a memory policy
    /// for everyday content. Read the trade-off before touching the number.
    ///
    /// The eager whole-pasteboard read below (see `Saved.items`) runs on every
    /// Magic hotkey whether or not the press ends up touching the clipboard,
    /// and it copies bytes: a screenshot lives on the clipboard as TIFF *and*
    /// PNG *and* PDF at once, so a retina capture is tens of megabytes in our
    /// address space, held for the length of the insert — the paste
    /// confirmation loop runs up to 700 ms, plus the 400 ms restore grace, so
    /// roughly 1.1 s. That is a transient spike, and it ends.
    ///
    /// Crossing this budget does NOT end: `save()` abandons the capture, the
    /// press still calls `writeGenerated`, and `restore()` then refuses — so
    /// the user's clipboard is overwritten with our generated text and there is
    /// nowhere left to get it back from. **Exceeding the budget destroys user
    /// data.** That is strictly worse than a spike that frees itself a second
    /// later, which is why the threshold sits deliberately far above anything
    /// real content produces rather than anywhere near the memory we would
    /// prefer to use.
    ///
    /// 256 MB accordingly: a full-screen 5K bitmap is ~59 MB per representation
    /// (5120 × 2880 × 4), so a screenshot carried as TIFF + PNG + PDF, an image
    /// copied out of a browser, a multi-page PDF, a large rich-text document —
    /// all of it must fit, be captured, and be restored intact. What the fuse
    /// is for is the clipboard nobody meant to make: some tool's several-hundred-
    /// megabyte output, a runaway export, a generated bitmap with no sane size.
    ///
    /// Lowering this number trades the user's data for our memory, one clipboard
    /// at a time, and does it silently — the loss surfaces only as "my image
    /// vanished when I pressed the hotkey", long after the press. If a future
    /// press path can restore an over-budget clipboard some other way (never
    /// writing over it, or refusing the pasteboard route entirely when
    /// `Saved.isRestorable` is false), shrink the budget then — not before.
    ///
    /// It bounds retention, not peak: a representation is read before its size
    /// is known — the pasteboard exposes no length ahead of the read — so the
    /// true high-water mark is the budget plus the single largest
    /// representation, after which the whole capture is dropped at once.
    ///
    /// `nonisolated` so `fitsInBudget` can default to it: a default argument of
    /// a non-isolated function is evaluated in the caller's (non-isolated)
    /// context, which cannot reach a main-actor-isolated constant.
    nonisolated static let saveBudgetBytes = 256 * 1024 * 1024

    /// The budget arithmetic, extracted so the all-or-nothing decision is
    /// testable without a live `NSPasteboard`. Deliberately inclusive at the
    /// boundary: a capture that lands exactly on the budget is still a capture
    /// we are willing to hold.
    nonisolated static func fitsInBudget(
        runningTotal: Int, nextRepresentation: Int,
        budget: Int = PasteboardTransaction.saveBudgetBytes
    ) -> Bool {
        runningTotal + nextRepresentation <= budget
    }

    struct Saved: Sendable {
        /// Every representation of every item, keyed by raw type name. The
        /// whole pasteboard is captured — not just the text types — because
        /// `restore()` re-declares what it holds: recording only string/RTF/
        /// HTML would silently destroy an image, file URL, PDF, or color
        /// clipboard on every Magic paste.
        ///
        /// `nil` means the capture crossed `saveBudgetBytes` and was abandoned.
        /// Abandoning is all-or-nothing on purpose: a partial capture would
        /// restore as a *lossy* clipboard — the representations that fit,
        /// written back over the ones that did not — which is the very failure
        /// mode the whole-pasteboard rule above exists to prevent, except
        /// harder to notice, because the clipboard would still look populated.
        /// Nothing is the honest answer, and `restore()` enforces it.
        let items: [[String: Data]]?
        let changeCount: Int

        /// Plain-text view of what was saved, when it had one. The legacy
        /// inline path compares it against the text it last pasted to decide
        /// whether a hotkey without a fresh selection is a follow-up prompt.
        ///
        /// Read up front and stored, rather than derived from `items`, so that
        /// a capture abandoned by the `saveBudgetBytes` fuse still answers this
        /// question: the follow-up check needs the text and nothing else, so
        /// whatever else shared the clipboard has no business switching the
        /// feature off on top of everything else that press already lost.
        let string: String?

        /// Whether `restore()` has anything faithful to put back. False only
        /// for an over-budget capture — an *empty* clipboard is still fully
        /// captured, and restores as empty.
        var isRestorable: Bool { items != nil }
    }

    /// Captures the whole pasteboard, off the main thread (see `readQueue`).
    ///
    /// Callers always `await` this before their own write, so our own writes
    /// still cannot interleave with the walk below. A *foreign* write can — it
    /// always could, the pasteboard being a shared multi-process resource — and
    /// the outcome is unchanged: `Saved.changeCount` may then predate the items
    /// it was read with, and `restore` declines rather than fighting the other
    /// writer (§3.5, R3).
    nonisolated static func save() async -> Saved {
        await withCheckedContinuation { continuation in
            readQueue.async { continuation.resume(returning: readSaved()) }
        }
    }

    nonisolated private static func readSaved() -> Saved {
        let pasteboard = NSPasteboard.general
        let changeCount = pasteboard.changeCount

        // Read ahead of the walk below, so that the follow-up-prompt check
        // still has its text when the fuse blows (see `Saved.string`) — and
        // held to the same budget itself, or a clipboard carrying a
        // quarter-gigabyte of plain text would sail past the ceiling through
        // the one field that escapes the walk.
        let plainText = pasteboard.string(forType: .string).flatMap {
            fitsInBudget(runningTotal: 0, nextRepresentation: $0.utf8.count) ? $0 : nil
        }

        var items: [[String: Data]] = []
        var totalBytes = 0
        for item in pasteboard.pasteboardItems ?? [] {
            var representations: [String: Data] = [:]
            for type in item.types {
                // Reads promised/lazy data eagerly — the item is gone by the
                // time we restore, so there is nothing left to promise.
                // File-promise types are not an exception worth carving out:
                // `data(forType:)` hands back the promise's own metadata (a
                // content UTI, a destination URL), never the file's bytes —
                // those only ever flow through `NSFilePromiseReceiver` — so
                // they are small, and skipping them would strip an item of the
                // only representation it has, which is precisely the silent
                // destruction the whole-pasteboard rule forbids.
                guard let data = item.data(forType: type) else { continue }
                guard fitsInBudget(runningTotal: totalBytes, nextRepresentation: data.count) else {
                    // Bail on the whole capture the moment the budget breaks,
                    // instead of finishing the walk and discarding afterwards:
                    // the remaining representations are then never read at all,
                    // which caps both the memory we touch and the number of
                    // synchronous cross-process reads this press performs.
                    //
                    // `error`, not `notice`: the press that follows overwrites
                    // the clipboard and `restore()` will refuse to give it back,
                    // so this line is the only record that the user's clipboard
                    // was destroyed. Given how far above real content
                    // `saveBudgetBytes` sits, it should also never be reached —
                    // if it shows up in a log, that is the finding, not noise.
                    // Sizes and type names only — never a byte of what the user
                    // was carrying.
                    let offendingType = type.rawValue
                    let offendingBytes = data.count
                    let capturedBytes = totalBytes
                    let budget = saveBudgetBytes
                    Self.logger.error(
                        "pasteboard capture abandoned, clipboard contents lost for this press: \(capturedBytes, privacy: .public) B captured plus \(offendingBytes, privacy: .public) B for type \(offendingType, privacy: .public) exceeds the \(budget, privacy: .public) B budget"
                    )
                    return Saved(items: nil, changeCount: changeCount, string: plainText)
                }
                totalBytes += data.count
                representations[type.rawValue] = data
            }
            items.append(representations)
        }
        return Saved(items: items, changeCount: changeCount, string: plainText)
    }

    /// Writes generated text marked transient + concealed. Returns the
    /// pasteboard's changeCount after our write — the token every later
    /// restore decision verifies against.
    @discardableResult
    static func writeGenerated(_ text: String) -> Int {
        let pasteboard = NSPasteboard.general
        pasteboard.declareTypes([.string, transientType, concealedType], owner: nil)
        pasteboard.setString(text, forType: .string)
        pasteboard.setString("", forType: transientType)
        pasteboard.setString("", forType: concealedType)
        return pasteboard.changeCount
    }

    /// Restores the saved contents only when nobody wrote to the pasteboard
    /// since our own write. Never fights other writers (§3.5, R3). The
    /// restore write is itself transient-marked so clipboard managers skip
    /// the churn.
    @discardableResult
    static func restore(_ saved: Saved, ifChangeCountStill expected: Int) -> Bool {
        // Checked before anything is read or cleared: an over-budget capture
        // (`saveBudgetBytes`) holds no faithful copy, so the only correct move
        // is to leave the pasteboard exactly as the press left it. Reported as
        // "not restored" rather than "restored", which is what it is — callers
        // already treat a false return as "the clipboard is not ours to hand
        // back" and must not be told otherwise.
        guard let savedItems = saved.items else { return false }

        let pasteboard = NSPasteboard.general
        guard shouldRestore(currentCount: pasteboard.changeCount, ourWriteCount: expected) else {
            return false
        }
        pasteboard.clearContents()
        // An empty clipboard restores as an empty clipboard: writeObjects
        // rejects a typeless item, so there is nothing to write.
        let items: [NSPasteboardItem] = savedItems.compactMap { representations in
            guard !representations.isEmpty else { return nil }
            let item = NSPasteboardItem()
            for (rawType, data) in representations {
                item.setData(data, forType: NSPasteboard.PasteboardType(rawType))
            }
            return item
        }
        guard !items.isEmpty else { return true }
        // Transient marker so clipboard managers skip the restore churn —
        // one item carries it, same as our own writes. Guarded because the
        // clipboard we saved may already have carried the marker itself (any
        // other tool that follows the org.nspasteboard convention, including
        // our own `writeGenerated`), in which case the loop above has already
        // written the type and `setString` would quietly return false: the
        // marker is present either way, but only one of the two paths says so.
        let first = items[0]
        if !first.types.contains(transientType) {
            first.setString("", forType: transientType)
        }
        pasteboard.writeObjects(items)
        return true
    }

    nonisolated static func shouldRestore(currentCount: Int, ourWriteCount: Int) -> Bool {
        currentCount == ourWriteCount
    }

    /// Adds the transient+concealed marker types to whatever is currently on
    /// the pasteboard, without disturbing the content. Used by paths that
    /// write via `ClipboardService`'s rich-text setters (the legacy inline
    /// path) but still want clipboard managers to skip the generated draft.
    static func markCurrentItemGenerated() {
        let pasteboard = NSPasteboard.general
        pasteboard.addTypes([transientType, concealedType], owner: nil)
        pasteboard.setString("", forType: transientType)
        pasteboard.setString("", forType: concealedType)
    }

    /// Posts ⌘C and polls `changeCount` until the frontmost app has written
    /// (20 ms steps), which resolves in 40–80 ms on cooperative apps.
    ///
    /// The count, not the text, is the signal. An unchanged count *is* "nothing
    /// was selected"; comparing the pasteboard string against what was there
    /// before cannot tell that apart from a selection identical to the last
    /// copy, and reports the successful copy as a failure. The captured text is
    /// left on the pasteboard; callers own restore.
    static func captureViaCommandC(timeout: Duration = .milliseconds(400)) async -> String? {
        let pasteboard = NSPasteboard.general
        let countBefore = pasteboard.changeCount

        SyntheticKeystroke.post(SyntheticKeystroke.keyC)

        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            // Not cancellable, and the reason is stronger here than the wasted
            // `changeCount` round-trips a collapsed sleep would spin through
            // (see `UninterruptibleSleep`): the ⌘C is already posted and cannot
            // be recalled. Giving up on the poll early does not stop the target
            // from writing — it only stops us from being there when it does, and
            // `MagicSelectionCapture.refine` then reads a `changeCount` that has
            // not moved yet, declines the restore, and leaves the probe's spoils
            // sitting on the user's clipboard for good. The full deadline is what
            // makes the write and the restore decision meet.
            await UninterruptibleSleep.sleep(for: .milliseconds(20))
            if pasteboard.changeCount != countBefore {
                return pasteboard.string(forType: .string)
            }
        }
        return nil
    }

    /// Posts ⌘V immediately. Unlike `ClipboardService.simulatePaste()` there
    /// is no built-in delay — Magic Button callers sequence focus explicitly
    /// and re-verify the target before pasting.
    static func postPaste() {
        SyntheticKeystroke.post(SyntheticKeystroke.keyV)
    }
}
