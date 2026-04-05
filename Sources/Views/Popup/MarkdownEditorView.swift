import SwiftUI
import Textual
import UniformTypeIdentifiers

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
    @State private var showPreview = false
    @State private var showImagePicker = false
    @State private var editorContext = MarkdownEditorContext()

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            if showPreview {
                MarkdownPreviewView(markdown: text)
            } else {
                MarkdownTextView(text: $text, editorContext: editorContext)
            }
        }
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
            toolbarButton("B", icon: "bold", help: "Bold (**text**)") {
                editorContext.wrapSelection(prefix: "**", suffix: "**")
            }
            .fontWeight(.bold)

            toolbarButton("I", icon: "italic", help: "Italic (*text*)") {
                editorContext.wrapSelection(prefix: "*", suffix: "*")
            }
            .italic()

            toolbarButton("S", icon: "strikethrough", help: "Strikethrough (~~text~~)") {
                editorContext.wrapSelection(prefix: "~~", suffix: "~~")
            }
            .strikethrough()

            toolbarButton(nil, icon: "chevron.left.forwardslash.chevron.right", help: "Inline code (`code`)") {
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
                    .frame(width: 28, height: 24)
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize()
            .disabled(showPreview)

            toolbarSeparator

            // Structure
            toolbarButton(nil, icon: "list.bullet", help: "Bullet list (- item)") {
                editorContext.insertLinePrefix("- ")
            }

            toolbarButton(nil, icon: "list.number", help: "Numbered list (1. item)") {
                editorContext.insertLinePrefix("1. ")
            }

            toolbarButton(nil, icon: "text.quote", help: "Blockquote (> text)") {
                editorContext.insertLinePrefix("> ")
            }

            toolbarButton(nil, icon: "curlybraces", help: "Code block (```)") {
                editorContext.insertCodeBlock()
            }

            toolbarSeparator

            // Insert
            toolbarButton(nil, icon: "link", help: "Insert link [text](url)") {
                editorContext.insertLink()
            }

            toolbarButton(nil, icon: "photo", help: "Insert image") {
                showImagePicker = true
            }

            toolbarButton(nil, icon: "minus", help: "Horizontal rule (---)") {
                editorContext.insertHorizontalRule()
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
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownTextView
        var isUpdating = false

        init(parent: MarkdownTextView) {
            self.parent = parent
            super.init()
        }

        func textDidChange(_ notification: Notification) {
            guard !isUpdating else { return }
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}

// MARK: - Markdown Preview (Textual StructuredText)

struct MarkdownPreviewView: View {
    let markdown: String

    var body: some View {
        ScrollView {
            StructuredText(markdown: markdown)
                .textual.imageAttachmentLoader(.image())
                .textSelection(.enabled)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - HTML WYSIWYG Editor (Infomaniak)

import InfomaniakRichHTMLEditor

struct HTMLEditorView: View {
    @Binding var text: String
    @State private var showSource = false
    @StateObject private var textAttributes = TextAttributes()

    @State private var showLinkSheet = false
    @State private var linkURL = ""
    @State private var linkText = ""

    var body: some View {
        VStack(spacing: 0) {
            htmlToolbar
                .fixedSize(horizontal: false, vertical: true)
            Divider()

            if showSource {
                MarkdownTextView(text: $text, editorContext: MarkdownEditorContext())
            } else {
                RichHTMLEditor(html: $text, textAttributes: textAttributes)
                    .introspectEditor { editor in
                        editor.enclosingScrollView?.hasVerticalScroller = true
                    }
            }
        }
        .clipped()
        .sheet(isPresented: $showLinkSheet) {
            linkSheet
        }
    }

    private var linkSheet: some View {
        VStack(spacing: 12) {
            Text("Insert Link")
                .font(.headline)
            TextField("URL", text: $linkURL)
                .textFieldStyle(.roundedBorder)
            TextField("Text (optional)", text: $linkText)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Cancel") { showLinkSheet = false }
                    .keyboardShortcut(.cancelAction)
                Button("Insert") {
                    if let url = URL(string: linkURL), !linkURL.isEmpty {
                        let label = linkText.isEmpty ? nil : linkText
                        textAttributes.addLink(url: url, text: label)
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

    private var htmlToolbar: some View {
        HStack(spacing: 2) {
            // Text formatting
            htmlToolbarButton("bold", active: textAttributes.hasBold) {
                textAttributes.bold()
            }
            htmlToolbarButton("italic", active: textAttributes.hasItalic) {
                textAttributes.italic()
            }
            htmlToolbarButton("underline", active: textAttributes.hasUnderline) {
                textAttributes.underline()
            }
            htmlToolbarButton("strikethrough", active: textAttributes.hasStrikethrough) {
                textAttributes.strikethrough()
            }

            Divider().frame(height: 16).padding(.horizontal, 4)

            // Lists
            htmlToolbarButton("list.bullet", active: textAttributes.hasUnorderedList) {
                textAttributes.unorderedList()
            }

            Divider().frame(height: 16).padding(.horizontal, 4)

            // Insert
            htmlToolbarButton("link", active: false) {
                linkURL = "https://"
                linkText = ""
                showLinkSheet = true
            }

            Divider().frame(height: 16).padding(.horizontal, 4)

            // Source toggle
            Button {
                showSource.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: showSource ? "eye" : "chevron.left.forwardslash.chevron.right")
                }
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
    }

    private func htmlToolbarButton(_ icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .frame(width: 28, height: 24)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(active ? .accentColor : nil)
        .disabled(showSource)
    }
}

// MARK: - HTML Read-Only View (WKWebView, scrollable, non-editable)

import WebKit

struct HTMLReadOnlyView: NSViewRepresentable {
    let html: String

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        loadContent(in: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        loadContent(in: webView)
    }

    private func loadContent(in webView: WKWebView) {
        let wrapped = """
        <!DOCTYPE html>
        <html><head>
        <meta charset="utf-8">
        <style>
        body {
            font-family: -apple-system, Helvetica Neue, sans-serif;
            font-size: 13px; line-height: 1.5;
            padding: 12px; margin: 0;
            color-scheme: light dark;
        }
        img { max-width: 100%; }
        table { border-collapse: collapse; }
        td, th { padding: 4px 8px; border: 1px solid #ddd; }
        pre { background: #f0f0f0; padding: 10px; border-radius: 6px; overflow-x: auto; }
        code { font-family: Menlo, monospace; font-size: 12px; }
        blockquote { border-left: 3px solid #ccc; margin-left: 0; padding-left: 12px; color: #555; }
        </style>
        </head><body>\(html)</body></html>
        """
        webView.loadHTMLString(wrapped, baseURL: nil)
    }
}
