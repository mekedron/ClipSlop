import SwiftUI

struct PopupContentView: View {
    let appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            // Shared header across full width
            headerBar
            Divider()

            // Content area: sidebar + main
            HStack(spacing: 0) {
                if let session = appState.currentSession, session.hasSteps {
                    HistorySidebarView(appState: appState)
                        .frame(width: 180)
                    Divider()
                }

                // Main content
                if let error = appState.errorMessage {
                    errorView(error)
                } else if appState.isProcessing {
                    ProcessingView(appState: appState)
                } else {
                    unifiedView
                }
            }
        }
        .frame(minWidth: 560, minHeight: 400)
        .background(.ultraThinMaterial.opacity(appState.settings.popupOpacity))
        .background(KeyEventHandler(appState: appState))
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            HStack(spacing: 4) {
                Button("ClipSlop") {
                    appState.navigateToRoot()
                }
                .buttonStyle(.plain)
                .font(.headline)

                ForEach(appState.breadcrumb, id: \.self) { name in
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(name)
                        .font(.headline)
                }
            }

            Spacer()

            if let session = appState.currentSession {
                sourceBadge(session.inputSource)
            }

            Button {
                appState.dismissPopup()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func sourceBadge(_ source: TransformationSession.InputSource) -> some View {
        let (icon, label) = switch source {
        case .clipboard: ("doc.on.clipboard", "Clipboard")
        case .selectedText: ("text.cursor", "Selected")
        case .screenCapture: ("camera.viewfinder", "OCR")
        }
        return Label(label, systemImage: icon)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary)
            .clipShape(Capsule())
    }

    // MARK: - Unified View

    private var unifiedView: some View {
        VStack(spacing: 0) {
            if appState.isEditing {
                editView
            } else {
                normalView
            }
        }
    }

    private var normalView: some View {
        VStack(spacing: 0) {
            // Text display
            ScrollView {
                Text(appState.currentDisplayText)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .frame(minHeight: 80)

            Divider()

            // Prompt navigator
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 180), spacing: 8)],
                    spacing: 8
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

            // Actions + shortcuts
            actionsBar

            shortcutsHint
        }
    }

    private var editView: some View {
        VStack(spacing: 0) {
            TextEditor(text: Bindable(appState).editingText)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(12)

            Divider()

            HStack(spacing: 12) {
                Button {
                    appState.saveEdit()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle")
                        Text("Save")
                        Text("⌘S").foregroundStyle(.tertiary)
                    }
                    .font(.caption)
                }
                .buttonStyle(.borderedProminent)

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

                Label("Editing mode", systemImage: "pencil")
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

        @MainActor
        private func handleKey(_ event: NSEvent, appState: AppState) -> Bool {
            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
            let hasCmd = event.modifierFlags.contains(.command)

            // --- Edit mode ---
            if appState.isEditing {
                if hasCmd && key == "s" {
                    appState.saveEdit()
                    return true
                }
                if event.keyCode == 53 {
                    appState.cancelEdit()
                    return true
                }
                return false
            }

            // --- Normal mode ---

            // Escape
            if event.keyCode == 53 {
                if !appState.navigationPath.isEmpty {
                    appState.navigateBack()
                } else {
                    appState.dismissPopup()
                }
                return true
            }

            // Cmd+E — Edit mode
            if hasCmd && key == "e" {
                appState.startEditing()
                return true
            }

            // Cmd+S — no-op in normal mode
            if hasCmd && key == "s" { return true }

            // Cmd+A — Select All
            if hasCmd && key == "a" {
                appState.selectAllText()
                return true
            }

            // Cmd+C — Copy
            if hasCmd && key == "c" {
                if let textView = self.window?.firstResponder as? NSTextView,
                   textView.selectedRange().length > 0 {
                    return false
                }
                appState.copyCurrentText()
                return true
            }

            // Cmd+V — Paste
            if hasCmd && key == "v" {
                appState.pasteCurrentText()
                return true
            }

            let isArrowUp = event.keyCode == 126
            let isArrowDown = event.keyCode == 125
            let isArrowLeft = event.keyCode == 123
            let isArrowRight = event.keyCode == 124
            let hasShift = event.modifierFlags.contains(.shift)
            let isSpace = event.keyCode == 49

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
            if event.keyCode == 51 || event.keyCode == 117 {
                if !appState.navigationPath.isEmpty {
                    appState.navigateBack()
                    return true
                }
                return false
            }

            // Mnemonic key navigation
            guard !appState.isProcessing, !hasCmd, !key.isEmpty else { return false }

            appState.handleMnemonicKey(key)
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
