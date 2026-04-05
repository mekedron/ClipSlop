import SwiftUI
import Textual
import UniformTypeIdentifiers

// MARK: - Constrained RichHTMLEditor (overrides intrinsicContentSize to prevent expansion)

/// NSView container that suppresses the editor's intrinsicContentSize,
/// forcing it to fit within the parent instead of expanding to content height.
final class ClippingEditorContainer: NSView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
}

@MainActor
final class HTMLToolbarState: ObservableObject {
    @Published var hasBold = false
    @Published var hasItalic = false
    @Published var hasUnderline = false
    @Published var hasStrikethrough = false
    @Published var hasOrderedList = false
    @Published var hasUnorderedList = false
    @Published var hasLink = false
    @Published var foregroundColor: Color?
    @Published var backgroundColor: Color?
    weak var editor: RichHTMLEditorView?

    func bold() { editor?.bold() }
    func italic() { editor?.italic() }
    func underline() { editor?.underline() }
    func strikethrough() { editor?.strikethrough() }
    func orderedList() { editor?.orderedList() }
    func unorderedList() { editor?.unorderedList() }
    func addLink(url: URL, text: String? = nil) { editor?.addLink(url: url, text: text) }
    func unlink() { editor?.unlink() }
    func setForegroundColor(_ color: NSColor) { editor?.setForegroundColor(color) }
    func setBackgroundColor(_ color: NSColor) { editor?.setBackgroundColor(color) }
    func undo() { editor?.undo() }
    func redo() { editor?.redo() }
}

struct ConstrainedRichHTMLEditor: NSViewRepresentable {
    @Binding var html: String
    @ObservedObject var toolbarState: HTMLToolbarState
    var isEditable: Bool
    var findBarState: FindBarState?

    func makeNSView(context: Context) -> ClippingEditorContainer {
        let container = ClippingEditorContainer()
        container.wantsLayer = true
        container.layer?.masksToBounds = true

        let editor = RichHTMLEditorView()
        editor.delegate = context.coordinator
        editor.html = html
        context.coordinator.editor = editor

        // Prevent the editor from expanding beyond container
        editor.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .vertical)
        editor.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)

        editor.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(editor)
        NSLayoutConstraint.activate([
            editor.topAnchor.constraint(equalTo: container.topAnchor),
            editor.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            editor.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            editor.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        return container
    }

    // Tell SwiftUI to use the proposed size, not the content size
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ClippingEditorContainer, context: Context) -> CGSize? {
        CGSize(
            width: proposal.width ?? 500,
            height: proposal.height ?? 300
        )
    }

    func updateNSView(_ container: ClippingEditorContainer, context: Context) {
        guard let editor = context.coordinator.editor else { return }
        if !context.coordinator.isUpdating && editor.html != html {
            editor.html = html
        }
        // Register as search backend when findBarState is provided
        if let findBarState {
            context.coordinator.findBarState = findBarState
            findBarState.activeBackend = context.coordinator
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency RichHTMLEditorViewDelegate, SearchableContent {
        let parent: ConstrainedRichHTMLEditor
        weak var editor: RichHTMLEditorView?
        weak var findBarState: FindBarState?
        var isUpdating = false
        private var cssInjected = false
        private var searchJSInjected = false

        init(parent: ConstrainedRichHTMLEditor) {
            self.parent = parent
            super.init()
        }

        func richHTMLEditorViewDidLoad(_ richHTMLEditorView: RichHTMLEditorView) {
            // Make WKWebView background transparent so it blends with the app theme
            richHTMLEditorView.webView.setValue(false, forKey: "drawsBackground")

            if !cssInjected {
                richHTMLEditorView.injectAdditionalCSS(HTMLStyles.shared)
                richHTMLEditorView.injectAdditionalCSS(HTMLStyles.searchCSS)
                if !parent.isEditable {
                    richHTMLEditorView.injectAdditionalCSS("body { user-select: text; }")
                }
                cssInjected = true
            }
            if !parent.isEditable {
                richHTMLEditorView.webView.evaluateJavaScript(
                    "document.getElementById('swift-rich-html-editor').contentEditable = false"
                )
            }
            // Inject search JS
            if !searchJSInjected {
                richHTMLEditorView.webView.evaluateJavaScript(HTMLStyles.searchJS)
                searchJSInjected = true
            }
            parent.toolbarState.editor = richHTMLEditorView

            // Register as search backend and re-execute if needed
            if let findBarState {
                findBarState.activeBackend = self
                if findBarState.isVisible, !findBarState.searchQuery.isEmpty {
                    findBarState.executeSearchImmediately()
                }
            }
        }

        func richHTMLEditorViewDidChange(_ richHTMLEditorView: RichHTMLEditorView) {
            guard !isUpdating else { return }
            isUpdating = true
            parent.html = richHTMLEditorView.html
            isUpdating = false
        }

        func richHTMLEditorView(
            _ richHTMLEditorView: RichHTMLEditorView,
            selectedTextAttributesDidChange uiAttrs: UITextAttributes
        ) {
            let state = parent.toolbarState
            state.editor = richHTMLEditorView
            state.hasBold = uiAttrs.hasBold
            state.hasItalic = uiAttrs.hasItalic
            state.hasUnderline = uiAttrs.hasUnderline
            state.hasStrikethrough = uiAttrs.hasStrikeThrough
            state.hasOrderedList = uiAttrs.hasOrderedList
            state.hasUnorderedList = uiAttrs.hasUnorderedList
            state.hasLink = uiAttrs.hasLink
            state.foregroundColor = uiAttrs.foregroundColor.map { Color($0) }
            state.backgroundColor = uiAttrs.backgroundColor.map { Color($0) }
        }

        func richHTMLEditorView(_ richHTMLEditorView: RichHTMLEditorView, caretPositionDidChange caretPosition: CGRect) {}
        func richHTMLEditorView(_ richHTMLEditorView: RichHTMLEditorView, javascriptFunctionDidFail error: any Error, whileExecutingFunction function: String) {}
        func richHTMLEditorView(_ richHTMLEditorView: RichHTMLEditorView, shouldHandleLink link: URL) -> Bool { false }

        // MARK: - SearchableContent

        func performSearch(query: String) async -> Int {
            guard let editor, !query.isEmpty else {
                clearSearch()
                return 0
            }
            let escaped = query
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
                .replacingOccurrences(of: "\n", with: "\\n")
            do {
                let value = try await editor.webView.evaluateJavaScript("csSearch('\(escaped)')")
                return (value as? Int) ?? 0
            } catch {
                return 0
            }
        }

        func highlightMatch(at index: Int) {
            guard let editor else { return }
            editor.webView.evaluateJavaScript("csHighlight(\(index))")
        }

        func clearSearch() {
            guard let editor else { return }
            editor.webView.evaluateJavaScript("csClearSearch()")
        }
    }
}

// MARK: - Shared HTML styles for editor and preview

enum HTMLStyles {
    static let shared = """
    body {
        font-family: -apple-system, Helvetica Neue, sans-serif;
        font-size: 13px; line-height: 1.5;
        color-scheme: light dark;
        background: transparent;
        padding: 12px; margin: 0;
    }
    img { max-width: 100%; }
    table { border-collapse: collapse; }
    td, th { padding: 4px 8px; border: 1px solid #ddd; }
    pre { background: #f0f0f0; padding: 10px; border-radius: 6px; overflow-x: auto; }
    code { font-family: Menlo, monospace; font-size: 12px; }
    blockquote { border-left: 3px solid #ccc; margin-left: 0; padding-left: 12px; color: #555; }
    @media (prefers-color-scheme: dark) {
        pre { background: #1e1e1e; }
        td, th { border-color: #444; }
        blockquote { border-left-color: #555; color: #aaa; }
    }
    """

    static let searchCSS = """
    .cs-find-highlight {
        background-color: rgba(255, 214, 0, 0.4);
        border-radius: 2px;
    }
    .cs-find-current {
        background-color: rgba(255, 140, 0, 0.6);
        border-radius: 2px;
    }
    """

    static let searchJS = """
    var _csMarks = [];
    function csSearch(query) {
        csClearSearch();
        if (!query) return 0;
        var root = document.getElementById('swift-rich-html-editor') || document.body;
        var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null, false);
        var textNodes = [];
        while (walker.nextNode()) textNodes.push(walker.currentNode);
        var lowerQ = query.toLowerCase();
        for (var i = 0; i < textNodes.length; i++) {
            var node = textNodes[i];
            var text = node.textContent;
            var lowerText = text.toLowerCase();
            var idx = 0;
            while ((idx = lowerText.indexOf(lowerQ, idx)) !== -1) {
                var range = document.createRange();
                range.setStart(node, idx);
                range.setEnd(node, idx + query.length);
                var mark = document.createElement('mark');
                mark.className = 'cs-find-highlight';
                range.surroundContents(mark);
                _csMarks.push(mark);
                // After wrapping, the walker's text node is split; advance past the mark
                node = mark.nextSibling;
                if (!node) break;
                text = node.textContent;
                lowerText = text.toLowerCase();
                idx = 0;
            }
        }
        return _csMarks.length;
    }
    function csHighlight(index) {
        for (var i = 0; i < _csMarks.length; i++) {
            _csMarks[i].className = (i === index) ? 'cs-find-current' : 'cs-find-highlight';
        }
        if (_csMarks[index]) _csMarks[index].scrollIntoView({block:'center',behavior:'smooth'});
    }
    function csClearSearch() {
        for (var i = 0; i < _csMarks.length; i++) {
            var mark = _csMarks[i];
            var parent = mark.parentNode;
            if (parent) {
                while (mark.firstChild) parent.insertBefore(mark.firstChild, mark);
                parent.removeChild(mark);
                parent.normalize();
            }
        }
        _csMarks = [];
    }
    """
}

// MARK: - Editor Context (bridge between SwiftUI toolbar and NSTextView)

@MainActor
final class MarkdownEditorContext {
    weak var textView: NSTextView?

    func wrapSelection(prefix: String, suffix: String) {
        guard let textView else { return }
        let range = textView.selectedRange()
        let selected = (textView.string as NSString).substring(with: range)
        let replacement = prefix + selected + suffix
        textView.insertText(replacement, replacementRange: range)

        // Place cursor between prefix/suffix if nothing was selected
        if selected.isEmpty {
            let cursorPos = range.location + prefix.utf16.count
            textView.setSelectedRange(NSRange(location: cursorPos, length: 0))
        }
    }

    func insertText(_ text: String) {
        guard let textView else { return }
        textView.insertText(text, replacementRange: textView.selectedRange())
    }

    func insertLinePrefix(_ prefix: String) {
        guard let textView else { return }
        let string = textView.string as NSString
        let cursorPos = textView.selectedRange().location
        // Find the start of the current line
        let lineRange = string.lineRange(for: NSRange(location: cursorPos, length: 0))
        let lineStart = lineRange.location
        textView.insertText(prefix, replacementRange: NSRange(location: lineStart, length: 0))
    }

    func insertLink() {
        guard let textView else { return }
        let range = textView.selectedRange()
        let selected = (textView.string as NSString).substring(with: range)
        if selected.isEmpty {
            let replacement = "[text](url)"
            textView.insertText(replacement, replacementRange: range)
            // Select "text" for easy replacement
            let textStart = range.location + 1
            textView.setSelectedRange(NSRange(location: textStart, length: 4))
        } else {
            let replacement = "[\(selected)](url)"
            textView.insertText(replacement, replacementRange: range)
            // Select "url" for easy replacement
            let urlStart = range.location + selected.utf16.count + 3
            textView.setSelectedRange(NSRange(location: urlStart, length: 3))
        }
    }

    func insertCodeBlock() {
        guard let textView else { return }
        let range = textView.selectedRange()
        let selected = (textView.string as NSString).substring(with: range)
        let replacement = "```\n\(selected)\n```"
        textView.insertText(replacement, replacementRange: range)
        if selected.isEmpty {
            let cursorPos = range.location + 4 // after ```\n
            textView.setSelectedRange(NSRange(location: cursorPos, length: 0))
        }
    }

    func insertHorizontalRule() {
        guard let textView else { return }
        let range = textView.selectedRange()
        textView.insertText("\n---\n", replacementRange: range)
    }
}

// MARK: - Main Editor View

struct MarkdownEditorView: View {
    @Binding var text: String
    var findBarState: FindBarState?
    @State private var showPreview = false
    @State private var showImagePicker = false
    @State private var editorContext = MarkdownEditorContext()

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            if showPreview {
                if findBarState?.isVisible == true {
                    // Preview uses native StructuredText — swap to HTML for JS search
                    ConstrainedRichHTMLEditor(
                        html: .constant(MarkdownConverter.html(from: text)),
                        toolbarState: HTMLToolbarState(),
                        isEditable: false,
                        findBarState: findBarState
                    )
                    .id("md-editor-preview-search")
                } else {
                    MarkdownPreviewView(markdown: text)
                }
            } else {
                MarkdownTextView(text: $text, editorContext: editorContext, findBarState: findBarState)
            }
        }
        .onChange(of: showPreview) {
            findBarState?.clearAndReSearch()
        }
        .background(MarkdownShortcutHandler(editorContext: editorContext, showPreview: $showPreview, showImagePicker: $showImagePicker))
        .fileImporter(
            isPresented: $showImagePicker,
            allowedContentTypes: [.image]
        ) { result in
            if case .success(let url) = result {
                let granted = url.startAccessingSecurityScopedResource()
                defer { if granted { url.stopAccessingSecurityScopedResource() } }

                // Copy to temp to ensure the file remains accessible
                let dest = FileManager.default.temporaryDirectory
                    .appendingPathComponent(url.lastPathComponent)
                try? FileManager.default.copyItem(at: url, to: dest)

                editorContext.insertText("![](\(dest.absoluteString))")
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 2) {
            // Text style
            toolbarButton("B", icon: "bold", help: "Bold ⌘B") {
                editorContext.wrapSelection(prefix: "**", suffix: "**")
            }
            .fontWeight(.bold)

            toolbarButton("I", icon: "italic", help: "Italic ⌘I") {
                editorContext.wrapSelection(prefix: "*", suffix: "*")
            }
            .italic()

            toolbarButton("S", icon: "strikethrough", help: "Strikethrough ⇧⌘S") {
                editorContext.wrapSelection(prefix: "~~", suffix: "~~")
            }
            .strikethrough()

            toolbarButton(nil, icon: "chevron.left.forwardslash.chevron.right", help: "Inline code ⌘`") {
                editorContext.wrapSelection(prefix: "`", suffix: "`")
            }

            toolbarSeparator

            // Headings
            Menu {
                Button("Heading 1") { editorContext.insertLinePrefix("# ") }
                Button("Heading 2") { editorContext.insertLinePrefix("## ") }
                Button("Heading 3") { editorContext.insertLinePrefix("### ") }
            } label: {
                Text("H")
                    .font(.system(.body, design: .default))
                    .fontWeight(.semibold)
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .frame(height: 28)
            .disabled(showPreview)

            toolbarSeparator

            // Structure
            toolbarButton(nil, icon: "list.bullet", help: "Bullet list ⇧⌘L") {
                editorContext.insertLinePrefix("- ")
            }

            toolbarButton(nil, icon: "list.number", help: "Numbered list ⇧⌘O") {
                editorContext.insertLinePrefix("1. ")
            }

            toolbarButton(nil, icon: "text.quote", help: "Blockquote ⌘'") {
                editorContext.insertLinePrefix("> ")
            }

            toolbarButton(nil, icon: "curlybraces", help: "Code block ⇧⌘K") {
                editorContext.insertCodeBlock()
            }

            toolbarSeparator

            // Insert
            toolbarButton(nil, icon: "link", help: "Insert link ⌘K") {
                editorContext.insertLink()
            }

            toolbarButton(nil, icon: "photo", help: "Insert image ⇧⌘I") {
                showImagePicker = true
            }

            toolbarButton(nil, icon: "minus", help: "Horizontal rule ⇧⌘H") {
                editorContext.insertHorizontalRule()
            }

            toolbarSeparator

            // Undo/Redo
            toolbarButton(nil, icon: "arrow.uturn.backward", help: "Undo ⌘Z") {
                editorContext.textView?.undoManager?.undo()
            }
            toolbarButton(nil, icon: "arrow.uturn.forward", help: "Redo ⇧⌘Z") {
                editorContext.textView?.undoManager?.redo()
            }

            toolbarSeparator

            // Preview toggle
            toolbarButton(
                nil,
                icon: showPreview ? "pencil" : "eye",
                help: showPreview ? "Edit" : "Preview"
            ) {
                showPreview.toggle()
            }

            Spacer()

            if showPreview {
                Text("Preview")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Markdown")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var toolbarSeparator: some View {
        Divider().frame(height: 16).padding(.horizontal, 4)
    }

    private func toolbarButton(
        _ label: String?,
        icon: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            if let label {
                Text(label)
                    .font(.system(.body, design: .default))
                    .frame(width: 28, height: 24)
            } else {
                Image(systemName: icon)
                    .frame(width: 28, height: 24)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(help)
        .disabled(showPreview && icon != "pencil" && icon != "eye")
    }
}

// MARK: - NSTextView Wrapper (plain text Markdown editing)

struct MarkdownTextView: NSViewRepresentable {
    @Binding var text: String
    let editorContext: MarkdownEditorContext
    var findBarState: FindBarState?

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        let textView = NSTextView()
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 12)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.delegate = context.coordinator
        textView.string = text

        // Text wrapping
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]

        scrollView.documentView = textView
        editorContext.textView = textView
        context.coordinator.textView = textView

        // Register as search backend
        if let findBarState {
            findBarState.activeBackend = context.coordinator
            if findBarState.isVisible, !findBarState.searchQuery.isEmpty {
                findBarState.executeSearchImmediately()
            }
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.isUpdating = true
        if textView.string != text {
            textView.string = text
        }
        context.coordinator.isUpdating = false
        editorContext.textView = textView
        context.coordinator.textView = textView

        if let findBarState {
            findBarState.activeBackend = context.coordinator
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, SearchableContent {
        var parent: MarkdownTextView
        var isUpdating = false
        weak var textView: NSTextView?
        private var matchRanges: [NSRange] = []

        init(parent: MarkdownTextView) {
            self.parent = parent
            super.init()
        }

        func textDidChange(_ notification: Notification) {
            guard !isUpdating else { return }
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        // MARK: - SearchableContent

        func performSearch(query: String) async -> Int {
            guard let textView, !query.isEmpty else {
                clearSearch()
                return 0
            }

            clearHighlights()
            matchRanges = []

            let content = textView.string as NSString
            var searchRange = NSRange(location: 0, length: content.length)

            while searchRange.location < content.length {
                let range = content.range(
                    of: query,
                    options: [.caseInsensitive, .diacriticInsensitive],
                    range: searchRange
                )
                guard range.location != NSNotFound else { break }
                matchRanges.append(range)
                searchRange.location = range.location + range.length
                searchRange.length = content.length - searchRange.location
            }

            let layoutManager = textView.layoutManager
            for range in matchRanges {
                layoutManager?.addTemporaryAttribute(
                    .backgroundColor,
                    value: NSColor.systemYellow.withAlphaComponent(0.4),
                    forCharacterRange: range
                )
            }

            return matchRanges.count
        }

        func highlightMatch(at index: Int) {
            guard let textView, index >= 0, index < matchRanges.count else { return }
            let layoutManager = textView.layoutManager

            for range in matchRanges {
                layoutManager?.addTemporaryAttribute(
                    .backgroundColor,
                    value: NSColor.systemYellow.withAlphaComponent(0.4),
                    forCharacterRange: range
                )
            }

            let currentRange = matchRanges[index]
            layoutManager?.addTemporaryAttribute(
                .backgroundColor,
                value: NSColor.systemOrange.withAlphaComponent(0.6),
                forCharacterRange: currentRange
            )

            textView.scrollRangeToVisible(currentRange)
        }

        func clearSearch() {
            clearHighlights()
            matchRanges = []
        }

        private func clearHighlights() {
            guard let textView, let layoutManager = textView.layoutManager else { return }
            let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: fullRange)
        }
    }
}

// MARK: - Markdown Preview (Textual StructuredText)

// MARK: - Markdown Keyboard Shortcuts

struct MarkdownShortcutHandler: NSViewRepresentable {
    let editorContext: MarkdownEditorContext
    @Binding var showPreview: Bool
    @Binding var showImagePicker: Bool

    func makeNSView(context: Context) -> NSView {
        let view = ShortcutView()
        view.handler = context.coordinator
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class ShortcutView: NSView {
        var handler: Coordinator?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil, monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event -> NSEvent? in
                    guard let self, let handler = self.handler else { return event }
                    guard event.window === self.window else { return event }
                    let code = event.keyCode
                    let flags = event.modifierFlags
                    let handled = MainActor.assumeIsolated {
                        handler.handleKey(code: code, flags: flags)
                    }
                    return handled ? nil : event
                }
            }
        }

        override func removeFromSuperview() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            super.removeFromSuperview()
        }
    }

    @MainActor
    final class Coordinator {
        let parent: MarkdownShortcutHandler
        init(_ parent: MarkdownShortcutHandler) { self.parent = parent }

        func handleKey(code: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
            let hasCmd = flags.contains(.command)
            let hasShift = flags.contains(.shift)
            guard hasCmd else { return false }

            let ctx = parent.editorContext

            switch (hasShift, code) {
            // Cmd+B — Bold
            case (false, 11): ctx.wrapSelection(prefix: "**", suffix: "**"); return true
            // Cmd+I — Italic
            case (false, 34): ctx.wrapSelection(prefix: "*", suffix: "*"); return true
            // Cmd+` — Inline code
            case (false, 50): ctx.wrapSelection(prefix: "`", suffix: "`"); return true
            // Cmd+K — Link
            case (false, 40): ctx.insertLink(); return true
            // Cmd+' — Blockquote
            case (false, 39): ctx.insertLinePrefix("> "); return true
            // Cmd+Shift+S — Strikethrough
            case (true, 1): ctx.wrapSelection(prefix: "~~", suffix: "~~"); return true
            // Cmd+Shift+L — Bullet list
            case (true, 37): ctx.insertLinePrefix("- "); return true
            // Cmd+Shift+O — Numbered list
            case (true, 31): ctx.insertLinePrefix("1. "); return true
            // Cmd+Shift+K — Code block
            case (true, 40): ctx.insertCodeBlock(); return true
            // Cmd+Shift+I — Image
            case (true, 34): parent.showImagePicker = true; return true
            // Cmd+Shift+H — Horizontal rule
            case (true, 4): ctx.insertHorizontalRule(); return true
            // Cmd+P — Preview toggle
            case (false, 35): parent.showPreview.toggle(); return true
            default: return false
            }
        }
    }
}

struct MarkdownPreviewView: View {
    let markdown: String
    private var settings: AppSettings { .shared }

    var body: some View {
        switch settings.markdownRenderer {
        case .textual:
            ScrollView {
                if settings.showImagesInMarkdown {
                    StructuredText(markdown: markdown)
                        .textual.imageAttachmentLoader(.image())
                        .textSelection(.enabled)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    StructuredText(markdown: markdown)
                        .textSelection(.enabled)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        case .htmlEditor:
            ConstrainedRichHTMLEditor(
                html: .constant(MarkdownConverter.html(
                    from: markdown,
                    preserveImageWidths: settings.preserveImageWidths
                )),
                toolbarState: HTMLToolbarState(),
                isEditable: false
            )
        }
    }
}

// MARK: - HTML WYSIWYG Editor (Infomaniak)

import InfomaniakRichHTMLEditor

struct HTMLEditorView: View {
    @Binding var text: String
    var isEditable: Bool = true
    var findBarState: FindBarState?
    @State private var showSource = false
    @StateObject private var toolbarState = HTMLToolbarState()

    @State private var showLinkSheet = false
    @State private var linkURL = ""
    @State private var linkText = ""

    var body: some View {
        VStack(spacing: 0) {
            if isEditable {
                htmlToolbar
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
            }

            if showSource && isEditable {
                MarkdownTextView(text: $text, editorContext: MarkdownEditorContext(), findBarState: findBarState)
            } else {
                ConstrainedRichHTMLEditor(
                    html: $text,
                    toolbarState: toolbarState,
                    isEditable: isEditable,
                    findBarState: findBarState
                )
            }
        }
        .clipped()
        .sheet(isPresented: $showLinkSheet) {
            linkSheet
        }
        .onDisappear {
            // Close the system color panel when leaving the editor
            if NSColorPanel.shared.isVisible {
                NSColorPanel.shared.close()
            }
        }
    }

    private var linkSheet: some View {
        let isEditing = toolbarState.hasLink
        return VStack(spacing: 12) {
            Text(isEditing ? "Edit Link" : "Insert Link")
                .font(.headline)
            TextField("URL", text: $linkURL)
                .textFieldStyle(.roundedBorder)
            TextField("Text (optional)", text: $linkText)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Cancel") { showLinkSheet = false }
                    .keyboardShortcut(.cancelAction)

                if isEditing {
                    Button("Remove Link") {
                        toolbarState.unlink()
                        showLinkSheet = false
                    }
                    .foregroundStyle(.red)
                }

                Spacer()

                Button(isEditing ? "Update" : "Insert") {
                    if let url = URL(string: linkURL), !linkURL.isEmpty {
                        let label = linkText.isEmpty ? nil : linkText
                        toolbarState.addLink(url: url, text: label)
                    }
                    linkURL = ""
                    linkText = ""
                    showLinkSheet = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(linkURL.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 350)
    }

    @State private var showImagePicker = false


    private var htmlToolbar: some View {
        HStack(spacing: 2) {
            // Text formatting
            htmlToolbarButton("bold", active: toolbarState.hasBold, help: "Bold ⌘B") {
                toolbarState.bold()
            }
            htmlToolbarButton("italic", active: toolbarState.hasItalic, help: "Italic ⌘I") {
                toolbarState.italic()
            }
            htmlToolbarButton("underline", active: toolbarState.hasUnderline, help: "Underline ⌘U") {
                toolbarState.underline()
            }
            htmlToolbarButton("strikethrough", active: toolbarState.hasStrikethrough, help: "Strikethrough ⇧⌘S") {
                toolbarState.strikethrough()
            }

            Divider().frame(height: 16).padding(.horizontal, 4)

            // Text & background color — styled as toolbar buttons with color dot
            colorButton(icon: "textformat", color: toolbarState.foregroundColor ?? .primary, help: "Text color") { color in
                toolbarState.setForegroundColor(NSColor(color))
            }
            colorButton(icon: "highlighter", color: toolbarState.backgroundColor ?? .yellow, help: "Highlight") { color in
                toolbarState.setBackgroundColor(NSColor(color))
            }

            Divider().frame(height: 16).padding(.horizontal, 4)

            // Lists
            htmlToolbarButton("list.bullet", active: toolbarState.hasUnorderedList, help: "Bullet list ⇧⌘L") {
                toolbarState.unorderedList()
            }

            Divider().frame(height: 16).padding(.horizontal, 4)

            // Link
            htmlToolbarButton("link", active: toolbarState.hasLink, help: "Link ⌘K") {
                linkURL = "https://"
                linkText = ""
                showLinkSheet = true
            }

            // Image
            htmlToolbarButton("photo", active: false, help: "Insert image ⇧⌘I") {
                showImagePicker = true
            }

            Divider().frame(height: 16).padding(.horizontal, 4)

            // Undo/Redo
            htmlToolbarButton("arrow.uturn.backward", active: false, help: "Undo ⌘Z") {
                toolbarState.undo()
            }
            htmlToolbarButton("arrow.uturn.forward", active: false, help: "Redo ⇧⌘Z") {
                toolbarState.redo()
            }

            Divider().frame(height: 16).padding(.horizontal, 4)

            // Source toggle
            Button {
                showSource.toggle()
            } label: {
                Image(systemName: showSource ? "eye" : "chevron.left.forwardslash.chevron.right")
                    .frame(width: 28, height: 24)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(showSource ? "WYSIWYG" : "HTML Source")

            Spacer()

            Text(showSource ? "HTML Source" : "WYSIWYG")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .fileImporter(isPresented: $showImagePicker, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result {
                let granted = url.startAccessingSecurityScopedResource()
                defer { if granted { url.stopAccessingSecurityScopedResource() } }
                // Read image data and embed as base64 in HTML
                if let data = try? Data(contentsOf: url) {
                    let ext = url.pathExtension.lowercased()
                    let mime = switch ext {
                        case "png": "image/png"
                        case "jpg", "jpeg": "image/jpeg"
                        case "gif": "image/gif"
                        case "webp": "image/webp"
                        default: "image/png"
                    }
                    let base64 = data.base64EncodedString()
                    let imgTag = "<img src=\"data:\(mime);base64,\(base64)\" style=\"max-width:100%\">"
                    text += imgTag
                }
            }
        }
    }

    private func htmlToolbarButton(_ icon: String, active: Bool, help: String = "", action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .frame(width: 28, height: 24)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(active ? .accentColor : nil)
        .disabled(showSource)
        .help(help)
    }

    private func colorButton(icon: String, color: Color, help: String, apply: @escaping (Color) -> Void) -> some View {
        ColorPicker(selection: Binding(
            get: { color },
            set: { apply($0) }
        ), supportsOpacity: false) {
            Image(systemName: icon)
                .frame(width: 28, height: 24)
                .overlay(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(color)
                        .frame(width: 16, height: 3)
                        .offset(y: -3)
                }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .labelsHidden()
        .help(help)
        .disabled(showSource)
    }
}

// MARK: - HTML Read-Only View (WKWebView, scrollable, non-editable)

