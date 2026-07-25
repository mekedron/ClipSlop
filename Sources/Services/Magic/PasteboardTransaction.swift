import AppKit

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

    struct Saved: Sendable {
        /// Every representation of every item, keyed by raw type name. The
        /// whole pasteboard is captured — not just the text types — because
        /// `restore()` re-declares what it holds: recording only string/RTF/
        /// HTML would silently destroy an image, file URL, PDF, or color
        /// clipboard on every Magic paste.
        let items: [[String: Data]]
        let changeCount: Int

        /// Plain-text view of what was saved, when it had one. The legacy
        /// inline path compares it against the text it last pasted to decide
        /// whether a hotkey without a fresh selection is a follow-up prompt.
        var string: String? {
            for representations in items {
                if let data = representations[NSPasteboard.PasteboardType.string.rawValue] {
                    return String(data: data, encoding: .utf8)
                }
            }
            return nil
        }
    }

    static func save() -> Saved {
        let pasteboard = NSPasteboard.general
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            var representations: [String: Data] = [:]
            for type in item.types {
                // Reads promised/lazy data eagerly — the item is gone by the
                // time we restore, so there is nothing left to promise.
                if let data = item.data(forType: type) {
                    representations[type.rawValue] = data
                }
            }
            return representations
        }
        return Saved(items: items, changeCount: pasteboard.changeCount)
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
        let pasteboard = NSPasteboard.general
        guard shouldRestore(currentCount: pasteboard.changeCount, ourWriteCount: expected) else {
            return false
        }
        pasteboard.clearContents()
        // An empty clipboard restores as an empty clipboard: writeObjects
        // rejects a typeless item, so there is nothing to write.
        let items: [NSPasteboardItem] = saved.items.compactMap { representations in
            guard !representations.isEmpty else { return nil }
            let item = NSPasteboardItem()
            for (rawType, data) in representations {
                item.setData(data, forType: NSPasteboard.PasteboardType(rawType))
            }
            return item
        }
        guard !items.isEmpty else { return true }
        // Transient marker so clipboard managers skip the restore churn —
        // one item carries it, same as our own writes.
        items[0].setString("", forType: transientType)
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
    /// (20 ms steps). Replaces the legacy fixed 200 ms sleep + string
    /// comparison — resolves in 40–80 ms on cooperative apps, and an
    /// unchanged count *is* the "nothing was selected" signal, so identical
    /// re-selections no longer read as failures. The captured text is left
    /// on the pasteboard; callers own restore.
    static func captureViaCommandC(timeout: Duration = .milliseconds(400)) async -> String? {
        let pasteboard = NSPasteboard.general
        let countBefore = pasteboard.changeCount

        SyntheticKeystroke.post(SyntheticKeystroke.keyC)

        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
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
