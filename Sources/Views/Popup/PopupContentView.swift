import SwiftUI

struct PopupContentView: View {
    let appState: AppState
    @State private var promptGridHeight: Double = UserDefaults.standard.object(forKey: "promptGridHeight") as? Double ?? 200
    @State private var dragStartHeight: Double = 0
    private let loc = Loc.shared

    private var isViewingOriginal: Bool {
        guard let session = appState.currentSession else { return false }
        if appState.selectedHistoryStepIndex == -1 { return true }
        if appState.selectedHistoryStepIndex == nil && !session.hasSteps { return true }
        return false
    }

    var body: some View {
        HStack(spacing: 0) {
            if let session = appState.currentSession, session.hasSteps, !appState.isEditing {
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
        .padding(.top, 1) // minimal gap below titlebar
        .overlay(alignment: .top) {
            Divider()
        }
        .frame(minWidth: 560, minHeight: 400)
        .background(.ultraThinMaterial.opacity(appState.settings.popupOpacity))
        .background(KeyEventHandler(appState: appState))
    }

    // MARK: - Main Content Area

    private var mainContentArea: some View {
        GeometryReader { geo in
            let maxPromptHeight = max(80, geo.size.height - 200)
            let clampedHeight = min(promptGridHeight, maxPromptHeight)

            VStack(spacing: 0) {
                // Text display — takes all remaining vertical space
                Group {
                    switch appState.activeEditorMode {
                    case .markdown:
                        MarkdownPreviewView(markdown: appState.currentDisplayText)
                            .id(appState.currentDisplayText)
                    case .html:
                        HTMLEditorView(text: .constant(appState.currentDisplayText), isEditable: false)
                            .id(appState.currentDisplayText)
                    case .plainText:
                        ScrollView(.vertical, showsIndicators: false) {
                            Text(appState.currentDisplayText)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(16)
                        }
                    }
                }
                .frame(maxHeight: .infinity)

                // Resize handle centered on divider
                ZStack {
                    Divider()
                    ResizeHandle(height: $promptGridHeight, dragStartHeight: $dragStartHeight)
                        .frame(height: 8)
                }

                // Breadcrumb (always visible)
                HStack(spacing: 4) {
                Image(systemName: "folder")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                if appState.navigationPath.isEmpty {
                    Text(loc.t("popup.prompts"))
                        .font(.caption.bold())
                } else {
                    Button {
                        appState.navigateToRoot()
                    } label: {
                        Text(loc.t("popup.prompts"))
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
                            Text(loc.t("popup.back"))
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
            ScrollView(.vertical, showsIndicators: true) {
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
            .frame(height: clampedHeight)

            Divider()

            actionsBar

            shortcutsHint
            }
        }
    }

    private var editView: some View {
        VStack(spacing: 0) {
            Group {
                switch appState.activeEditorMode {
                case .markdown:
                    MarkdownEditorView(text: Bindable(appState).editingText)
                case .html:
                    HTMLEditorView(text: Bindable(appState).editingText)
                case .plainText:
                    TextEditor(text: Bindable(appState).editingText)
                        .font(.system(.body, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .scrollIndicators(.hidden)
                        .padding(12)
                }
            }
            .onAppear {
                if appState.activeEditorMode != .html {
                    focusEditor()
                }
            }

            Divider()

            HStack(spacing: 12) {
                Button {
                    appState.saveEdit()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle")
                        Text(loc.t("popup.done"))
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
                        Text(loc.t("popup.cancel"))
                        Text("Esc").foregroundStyle(.tertiary)
                    }
                    .font(.caption)
                }
                .buttonStyle(.bordered)

                Spacer()

                Picker(loc.t("popup.display"), selection: Bindable(appState).activeEditorMode) {
                    Text("Plain text").tag(EditorMode.plainText)
                    Text("HTML").tag(EditorMode.html)
                    Text("Markdown").tag(EditorMode.markdown)
                }
                .frame(width: 145)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private func focusEditor() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if let window = NSApp.windows.first(where: { $0 is PopupWindow }) {
                if let textView = findTextView(in: window.contentView) {
                    window.makeFirstResponder(textView)
                }
            }
        }
    }

    // MARK: - Actions Bar

    private var actionsBar: some View {
        HStack(spacing: 10) {
            copyButton

            Divider().frame(height: 16)

            actionButton(loc.t("popup.edit"), icon: "pencil", shortcut: "⌘E") {
                appState.startEditing()
            }

            actionButton(loc.t("popup.open"), icon: "square.and.arrow.up", shortcut: "⌘O") {
                appState.openInTextEdit()
            }

            actionButton(loc.t("popup.save"), icon: "square.and.arrow.down", shortcut: "⌘S") {
                appState.saveToFile()
            }

            Spacer()

            if isViewingOriginal {
                Picker(loc.t("popup.source"), selection: Bindable(appState).originalViewMode) {
                    Text("Plain text").tag(RichTextMode.plainText)
                    Text("HTML").tag(RichTextMode.html)
                    Text("Markdown").tag(RichTextMode.markdown)
                    Text("Markdown (AI)").tag(RichTextMode.markdownAI)
                }
                .frame(width: 160)
                .onChange(of: appState.originalViewMode) { _, newMode in
                    if newMode == .markdownAI {
                        appState.convertOriginalWithAI()
                    }
                    // Sync display format to match source
                    switch newMode {
                    case .plainText: appState.activeEditorMode = .plainText
                    case .html: appState.activeEditorMode = .html
                    case .markdown, .markdownAI: appState.activeEditorMode = .markdown
                    }
                }
            }

            Picker(loc.t("popup.display"), selection: Bindable(appState).activeEditorMode) {
                Text("Plain text").tag(EditorMode.plainText)
                Text("HTML").tag(EditorMode.html)
                Text("Markdown").tag(EditorMode.markdown)
            }
            .frame(width: 145)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Shortcuts Hint

    private var shortcutsHint: some View {
        HStack(spacing: 16) {
            shortcutHint("←→", loc.t("popup.hint.history"))
            shortcutHint("↑↓", loc.t("popup.hint.scroll"))
            shortcutHint("Space", loc.t("popup.hint.page_down"))
            shortcutHint("⇧Space", loc.t("popup.hint.page_up"))

            if !appState.navigationPath.isEmpty {
                shortcutHint("⌫", loc.t("popup.hint.back"))
            }

            shortcutHint("Esc", loc.t("popup.hint.close"))
            shortcutHint("⌘D", loc.t("popup.hint.display"))

            Spacer()

            // Mnemonic hint
            Text(loc.t("popup.mnemonic_hint"))
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

    private var copyButton: some View {
        let copied = appState.showCopiedFeedback
        return Button {
            appState.copyCurrentText()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                Text(copied ? loc.t("popup.copied") : loc.t("popup.copy"))
                if !copied {
                    Text("⌘C").foregroundStyle(.tertiary)
                }
            }
            .font(.caption)
        }
        .buttonStyle(.bordered)
        .tint(copied ? .green : nil)
        .animation(.easeInOut(duration: 0.2), value: copied)
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
                Button(loc.t("popup.dismiss")) {
                    appState.clearError()
                    appState.dismissPopup()
                }
                Button(loc.t("popup.try_again")) {
                    appState.clearError()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func findTextView(in view: NSView?) -> NSTextView? {
        guard let view else { return nil }
        if let textView = view as? NSTextView { return textView }
        for subview in view.subviews {
            if let found = findTextView(in: subview) { return found }
        }
        return nil
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
            static let d: UInt16 = 2
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
                if hasCmd && code == KeyCode.enter {
                    appState.saveEdit()
                    return true
                }
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

            if code == KeyCode.escape {
                if !appState.navigationPath.isEmpty {
                    appState.navigateBack()
                } else if !appState.settings.keepOpenOnEscape {
                    appState.dismissPopup()
                }
                return true
            }

            if hasCmd && code == KeyCode.e {
                appState.startEditing()
                return true
            }

            if hasCmd && code == KeyCode.d {
                let hasShift = event.modifierFlags.contains(.shift)
                if hasShift {
                    // Cycle backward: Plain → Markdown → HTML → Plain
                    switch appState.activeEditorMode {
                    case .plainText: appState.activeEditorMode = .markdown
                    case .html: appState.activeEditorMode = .plainText
                    case .markdown: appState.activeEditorMode = .html
                    }
                } else {
                    // Cycle forward: Plain → HTML → Markdown → Plain
                    switch appState.activeEditorMode {
                    case .plainText: appState.activeEditorMode = .html
                    case .html: appState.activeEditorMode = .markdown
                    case .markdown: appState.activeEditorMode = .plainText
                    }
                }
                return true
            }

            if hasCmd && code == KeyCode.o {
                appState.openInTextEdit()
                return true
            }

            if hasCmd && code == KeyCode.s {
                appState.saveToFile()
                return true
            }

            if hasCmd && code == KeyCode.comma {
                appState.openSettings()
                return true
            }

            if hasCmd && code == KeyCode.a {
                appState.selectAllText()
                return true
            }

            if hasCmd && code == KeyCode.c {
                if let textView = self.window?.firstResponder as? NSTextView,
                   textView.selectedRange().length > 0 {
                    return false
                }
                appState.copyCurrentText()
                return true
            }

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

            if isArrowLeft {
                appState.navigateHistoryNewer()
                return true
            }
            if isArrowRight {
                appState.navigateHistoryOlder()
                return true
            }

            if isArrowUp || isArrowDown || isSpace {
                let isUp = isArrowUp || (isSpace && hasShift)
                let pageScroll = isSpace || hasShift
                let amount: CGFloat = pageScroll ? 300 : 40
                scrollTextArea(up: isUp, by: amount)
                return true
            }

            if code == KeyCode.delete || code == KeyCode.forwardDelete {
                if !appState.navigationPath.isEmpty {
                    appState.navigateBack()
                    return true
                }
                return false
            }

            // Mnemonic key navigation
            let matchChar: String
            if appState.settings.useKeyCodes {
                matchChar = keyCodeToCharacter(code) ?? ""
            } else {
                matchChar = event.characters?.lowercased() ?? ""
            }

            let mods = MnemonicModifiers(eventFlags: event.modifierFlags)

            guard !appState.isProcessing, !matchChar.isEmpty else { return false }

            return appState.handleMnemonicKey(matchChar, modifiers: mods)
        }

        private func scrollTextArea(up: Bool, by amount: CGFloat) {
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

        private func findFirstScrollView(in view: NSView?) -> NSScrollView? {
            guard let view else { return nil }
            var queue: [NSView] = [view]
            var scrollViews: [NSScrollView] = []
            while !queue.isEmpty {
                let current = queue.removeFirst()
                if let sv = current as? NSScrollView {
                    scrollViews.append(sv)
                }
                queue.append(contentsOf: current.subviews)
            }
            return scrollViews.max(by: { $0.frame.width < $1.frame.width })
        }
    }
}

// MARK: - Resize Handle (AppKit-based to block window dragging)

struct ResizeHandle: NSViewRepresentable {
    @Binding var height: Double
    @Binding var dragStartHeight: Double

    func makeNSView(context: Context) -> ResizeHandleNSView {
        let view = ResizeHandleNSView()
        view.onDrag = { delta in
            if dragStartHeight == 0 { dragStartHeight = height }
            // NSView y-axis is bottom-up: positive delta = mouse moved up = grow prompts
            height = max(80, min(400, dragStartHeight + delta))
        }
        view.onDragEnd = {
            UserDefaults.standard.set(height, forKey: "promptGridHeight")
            dragStartHeight = 0
        }
        return view
    }

    func updateNSView(_ nsView: ResizeHandleNSView, context: Context) {
        nsView.onDrag = { delta in
            if dragStartHeight == 0 { dragStartHeight = height }
            height = max(80, min(400, dragStartHeight + delta))
        }
        nsView.onDragEnd = {
            UserDefaults.standard.set(height, forKey: "promptGridHeight")
            dragStartHeight = 0
        }
    }
}

final class ResizeHandleNSView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }

    var onDrag: ((Double) -> Void)?
    var onDragEnd: (() -> Void)?

    private var dragOriginY: CGFloat = 0

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 8)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupTrackingArea()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupTrackingArea()
    }

    private func setupTrackingArea() {
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // No visual indicator — cursor change on hover is enough
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.resizeUpDown.push()
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.pop()
    }

    override func mouseDown(with event: NSEvent) {
        dragOriginY = event.locationInWindow.y
    }

    override func mouseDragged(with event: NSEvent) {
        let delta = Double(event.locationInWindow.y - dragOriginY)
        onDrag?(delta)
    }

    override func mouseUp(with event: NSEvent) {
        onDragEnd?()
    }
}
