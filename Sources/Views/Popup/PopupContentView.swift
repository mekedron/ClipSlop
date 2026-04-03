import SwiftUI

struct PopupContentView: View {
    let appState: AppState

    var body: some View {
        HStack(spacing: 0) {
            if let session = appState.currentSession, session.hasSteps {
                HistorySidebarView(appState: appState)
                    .frame(width: 180)
                Divider()
            }

            // Main content (right side)
            VStack(spacing: 0) {
                if let error = appState.errorMessage {
                    errorView(error)
                } else if appState.isProcessing {
                    ProcessingView(appState: appState)
                } else if appState.isEditing {
                    editView
                } else {
                    mainContentArea
                }
            }
        }
        .frame(minWidth: 560, minHeight: 400)
        .background(.ultraThinMaterial.opacity(appState.settings.popupOpacity))
        .background(KeyEventHandler(appState: appState))
    }

    // MARK: - Main Content Area

    private var mainContentArea: some View {
        VStack(spacing: 0) {
            // Text display
            ScrollView(.vertical, showsIndicators: false) {
                Text(appState.currentDisplayText)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .frame(minHeight: 80)

            Divider()

            // Breadcrumb (always visible)
            HStack(spacing: 4) {
                Image(systemName: "folder")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                if appState.navigationPath.isEmpty {
                    Text("Prompts")
                        .font(.caption.bold())
                } else {
                    Button {
                        appState.navigateToRoot()
                    } label: {
                        Text("Prompts")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)

                    ForEach(Array(appState.navigationPath.enumerated()), id: \.element.id) { i, node in
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        if i < appState.navigationPath.count - 1 {
                            Button {
                                appState.navigationPath = Array(appState.navigationPath.prefix(i + 1))
                            } label: {
                                Text(node.name)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        } else {
                            Text(node.name)
                                .font(.caption.bold())
                        }
                    }
                }

                Spacer()

                if !appState.navigationPath.isEmpty {
                    Button {
                        appState.navigateBack()
                    } label: {
                        HStack(spacing: 2) {
                            Image(systemName: "chevron.left")
                            Text("Back")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            // Prompt navigator
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 150), spacing: 6)],
                    spacing: 6
                ) {
                    ForEach(appState.currentPrompts) { node in
                        PromptCard(node: node) {
                            appState.navigateInto(node)
                        }
                    }
                }
                .padding(12)
            }
            .frame(maxHeight: 200)

            Divider()

            actionsBar

            shortcutsHint
        }
    }

    private var editView: some View {
        VStack(spacing: 0) {
            TextEditor(text: Bindable(appState).editingText)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .scrollIndicators(.hidden)
                .padding(12)

            Divider()

            HStack(spacing: 12) {
                Button {
                    appState.saveEdit()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle")
                        Text("Done")
                        Text("⌘↩").foregroundStyle(.white.opacity(0.6))
                    }
                    .font(.caption)
                }
                .buttonStyle(AlwaysProminentButtonStyle())

                Button {
                    appState.cancelEdit()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark.circle")
                        Text("Cancel")
                        Text("Esc").foregroundStyle(.tertiary)
                    }
                    .font(.caption)
                }
                .buttonStyle(.bordered)

                Spacer()

                Label("Editing", systemImage: "pencil")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    // MARK: - Actions Bar

    private var actionsBar: some View {
        HStack(spacing: 10) {
            actionButton("Select All", icon: "selection.pin.in.out", shortcut: "⌘A") {
                appState.selectAllText()
            }

            actionButton("Copy", icon: "doc.on.doc", shortcut: "⌘C") {
                appState.copyCurrentText()
            }

            Divider().frame(height: 16)

            actionButton("Edit", icon: "pencil", shortcut: "⌘E") {
                appState.startEditing()
            }

            actionButton("Open", icon: "square.and.arrow.up", shortcut: "⌘O") {
                appState.openInTextEdit()
            }

            actionButton("Save", icon: "square.and.arrow.down", shortcut: "⌘S") {
                appState.saveToFile()
            }

            Spacer()

            if appState.showCopiedFeedback {
                Label("Copied!", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: appState.showCopiedFeedback)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Shortcuts Hint

    private var shortcutsHint: some View {
        HStack(spacing: 16) {
            shortcutHint("←→", "History")
            shortcutHint("↑↓", "Scroll")
            shortcutHint("Space", "Page ↓")
            shortcutHint("⇧Space", "Page ↑")

            if !appState.navigationPath.isEmpty {
                shortcutHint("⌫", "Back")
            }

            shortcutHint("Esc", "Close")

            Spacer()

            // Mnemonic hint
            Text("Press a letter to pick a prompt")
                .foregroundStyle(.tertiary)
        }
        .font(.caption2)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.3))
    }

    private func shortcutHint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 3) {
            Text(key)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
            Text(label)
                .foregroundStyle(.tertiary)
        }
    }

    private func actionButton(
        _ label: String,
        icon: String,
        shortcut: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                Text(label)
                Text(shortcut)
                    .foregroundStyle(.tertiary)
            }
            .font(.caption)
        }
        .buttonStyle(.bordered)
    }

    // MARK: - Error

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(.orange)

            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            HStack {
                Button("Dismiss") {
                    appState.clearError()
                    appState.dismissPopup()
                }
                Button("Try Again") {
                    appState.clearError()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - NSEvent-based key handler (works in NSPanel)

struct KeyEventHandler: NSViewRepresentable {
    let appState: AppState

    func makeNSView(context: Context) -> KeyEventView {
        let view = KeyEventView()
        view.appState = appState
        return view
    }

    func updateNSView(_ nsView: KeyEventView, context: Context) {
        nsView.appState = appState
    }

    class KeyEventView: NSView {
        var appState: AppState?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil, monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard let self, let appState = self.appState else { return event }
                    guard event.window === self.window else { return event }
                    return self.handleKey(event, appState: appState) ? nil : event
                }
            }
        }

        override func removeFromSuperview() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            super.removeFromSuperview()
        }

        // Key codes for physical keys (layout-independent)
        private enum KeyCode {
            static let a: UInt16 = 0
            static let s: UInt16 = 1
            static let c: UInt16 = 8
            static let v: UInt16 = 9
            static let e: UInt16 = 14
            static let o: UInt16 = 31
            static let n: UInt16 = 45
            static let z: UInt16 = 6
            static let comma: UInt16 = 43
            static let escape: UInt16 = 53
            static let enter: UInt16 = 36
            static let delete: UInt16 = 51
            static let forwardDelete: UInt16 = 117
            static let space: UInt16 = 49
            static let upArrow: UInt16 = 126
            static let downArrow: UInt16 = 125
            static let leftArrow: UInt16 = 123
            static let rightArrow: UInt16 = 124
        }

        @MainActor
        private func handleKey(_ event: NSEvent, appState: AppState) -> Bool {
            let code = event.keyCode
            let hasCmd = event.modifierFlags.contains(.command)

            // --- Edit mode ---
            if appState.isEditing {
                // Cmd+Enter — Done editing
                if hasCmd && code == KeyCode.enter {
                    appState.saveEdit()
                    return true
                }
                // Cmd+, — Open Settings (works in all modes)
                if hasCmd && code == KeyCode.comma {
                    appState.openSettings()
                    return true
                }
                if code == KeyCode.escape {
                    appState.cancelEdit()
                    return true
                }
                return false
            }

            // --- Normal mode ---

            // Escape
            if code == KeyCode.escape {
                if !appState.navigationPath.isEmpty {
                    appState.navigateBack()
                } else {
                    appState.dismissPopup()
                }
                return true
            }

            // Cmd+E — Edit mode
            if hasCmd && code == KeyCode.e {
                appState.startEditing()
                return true
            }

            // Cmd+O — Open in TextEdit
            if hasCmd && code == KeyCode.o {
                appState.openInTextEdit()
                return true
            }

            // Cmd+S — Save to file
            if hasCmd && code == KeyCode.s {
                appState.saveToFile()
                return true
            }

            // Cmd+, — Open Settings
            if hasCmd && code == KeyCode.comma {
                appState.openSettings()
                return true
            }

            // Cmd+A — Select All
            if hasCmd && code == KeyCode.a {
                appState.selectAllText()
                return true
            }

            // Cmd+C — Copy
            if hasCmd && code == KeyCode.c {
                if let textView = self.window?.firstResponder as? NSTextView,
                   textView.selectedRange().length > 0 {
                    return false
                }
                appState.copyCurrentText()
                return true
            }

            // Cmd+V — Paste
            if hasCmd && code == KeyCode.v {
                appState.pasteCurrentText()
                return true
            }

            let isArrowUp = code == KeyCode.upArrow
            let isArrowDown = code == KeyCode.downArrow
            let isArrowLeft = code == KeyCode.leftArrow
            let isArrowRight = code == KeyCode.rightArrow
            let hasShift = event.modifierFlags.contains(.shift)
            let isSpace = code == KeyCode.space

            // ← / → — navigate history (← = newer, → = older)
            if isArrowLeft {
                appState.navigateHistoryNewer()
                return true
            }
            if isArrowRight {
                appState.navigateHistoryOlder()
                return true
            }

            // ↑ / ↓ — scroll text (Shift = page)
            // Space = page down, Shift+Space = page up
            if isArrowUp || isArrowDown || isSpace {
                let isUp = isArrowUp || (isSpace && hasShift)
                let pageScroll = isSpace || hasShift
                let amount: CGFloat = pageScroll ? 300 : 40
                scrollTextArea(up: isUp, by: amount)
                return true
            }

            // Delete/Backspace — go back in navigation
            if code == KeyCode.delete || code == KeyCode.forwardDelete {
                if !appState.navigationPath.isEmpty {
                    appState.navigateBack()
                    return true
                }
                return false
            }

            // Mnemonic key navigation (use typed character, works with any layout)
            let typedChar = event.characters?.lowercased() ?? ""
            guard !appState.isProcessing, !hasCmd, !typedChar.isEmpty else { return false }

            appState.handleMnemonicKey(typedChar)
            return true
        }

        private func scrollTextArea(up: Bool, by amount: CGFloat) {
            // Find the first (topmost) scroll view — that's the text area
            guard let scrollView = findFirstScrollView(in: self.window?.contentView) else { return }
            let clipView = scrollView.contentView
            let maxY = scrollView.documentView?.frame.height ?? 0
            var origin = clipView.bounds.origin
            if up {
                origin.y = max(0, origin.y - amount)
            } else {
                origin.y = min(max(0, maxY - clipView.bounds.height), origin.y + amount)
            }
            clipView.setBoundsOrigin(origin)
        }

        /// Find the first NSScrollView that contains text (skip sidebar scroll views)
        private func findFirstScrollView(in view: NSView?) -> NSScrollView? {
            guard let view else { return nil }
            // BFS to find scroll views in order — first one in the main content area
            var queue: [NSView] = [view]
            var scrollViews: [NSScrollView] = []
            while !queue.isEmpty {
                let current = queue.removeFirst()
                if let sv = current as? NSScrollView {
                    scrollViews.append(sv)
                }
                queue.append(contentsOf: current.subviews)
            }
            // Return the largest scroll view (likely the text area, not sidebar or prompt grid)
            return scrollViews.max(by: { $0.frame.width < $1.frame.width })
        }
    }
}
