import AppKit
import MarkdownEngine
import SwiftUI

// MARK: - Markdown Engine View

/// ClipSlop's embedding of nodes-app/swift-markdown-engine: a TextKit 2
/// AppKit editor that live-styles Markdown source in place — headings,
/// lists, GFM tables, task checkboxes, blockquotes, code blocks, and
/// clickable links. Backs the "Markdown (Styled)" display mode for both
/// editing and read-only viewing.
///
/// The engine is driven through its notification bus: the formatting
/// toolbar posts apply-requests and the find bar is bridged to the
/// engine's own find highlighting via `MarkdownEngineBridge`.
struct MarkdownEngineView: View {
    @Binding var text: String
    var isEditable: Bool = true
    var findBarState: FindBarState?

    @State private var bridge = MarkdownEngineBridge()

    var body: some View {
        VStack(spacing: 0) {
            if isEditable {
                toolbar
                Divider()
            }

            // .fitsContent + outer SwiftUI ScrollView is the engine's documented
            // SwiftUI embedding. The internal `.scrolls` mode measures document
            // height via TextKit 2, which under-measures on macOS 26 — the view
            // wouldn't scroll and the caret could leave the visible area. In
            // .fitsContent mode the engine reports its height to SwiftUI and
            // propagates caret reveals to this enclosing scroller explicitly.
            ScrollView {
                NativeTextViewWrapper(
                    text: $text,
                    configuration: bridge.configuration,
                    fontSize: 13,
                    documentId: isEditable ? "clipslop-styled-edit" : "clipslop-styled-view",
                    isEditable: isEditable,
                    // In read-only mode the engine forces an arrow cursor over
                    // text (pointing hand over links). Excluding the whole view
                    // makes the engine "stay silent" — its documented escape
                    // hatch for embedders that own the cursor — and the overlay
                    // below restores the standard I-beam behavior.
                    isCursorExcluded: isEditable ? nil : { _ in true }
                )
            }
            .overlay {
                if !isEditable {
                    EngineCursorFixView()
                        .allowsHitTesting(false)
                }
            }
        }
        .onAppear {
            findBarState?.activeBackend = bridge
        }
    }

    // MARK: Toolbar (mirrors MarkdownEditorView's, posts engine bus requests)

    private var toolbar: some View {
        HStack(spacing: 2) {
            toolbarButton("B", icon: "bold", help: "Bold ⌘B") { bridge.post(\.applyBoldRequest) }
                .fontWeight(.bold)
            toolbarButton("I", icon: "italic", help: "Italic ⌘I") { bridge.post(\.applyItalicRequest) }
                .italic()
            toolbarButton("S", icon: "strikethrough", help: "Strikethrough") { bridge.post(\.applyStrikethroughRequest) }
                .strikethrough()
            toolbarButton(nil, icon: "chevron.left.forwardslash.chevron.right", help: "Inline code") {
                bridge.post(\.applyInlineCodeRequest)
            }

            toolbarSeparator

            Menu {
                Button("Heading 1") { bridge.post(\.applyHeadingRequest, userInfo: ["level": 1]) }
                Button("Heading 2") { bridge.post(\.applyHeadingRequest, userInfo: ["level": 2]) }
                Button("Heading 3") { bridge.post(\.applyHeadingRequest, userInfo: ["level": 3]) }
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

            toolbarSeparator

            toolbarButton(nil, icon: "list.bullet", help: "Bullet list") { bridge.post(\.applyUnorderedListRequest) }
            toolbarButton(nil, icon: "list.number", help: "Numbered list") { bridge.post(\.applyOrderedListRequest) }
            toolbarButton(nil, icon: "text.quote", help: "Blockquote") { bridge.post(\.applyBlockquoteRequest) }
            toolbarButton(nil, icon: "curlybraces", help: "Code block") { bridge.post(\.applyCodeBlockRequest) }

            toolbarSeparator

            toolbarButton(nil, icon: "link", help: "Insert link") { bridge.post(\.applyLinkRequest) }
            toolbarButton(nil, icon: "minus", help: "Horizontal rule") { bridge.post(\.applyHorizontalRuleRequest) }

            toolbarSeparator

            toolbarButton(nil, icon: "arrow.uturn.backward", help: "Undo ⌘Z") {
                NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
            }
            toolbarButton(nil, icon: "arrow.uturn.forward", help: "Redo ⇧⌘Z") {
                NSApp.sendAction(Selector(("redo:")), to: nil, from: nil)
            }

            Spacer()

            Text("Markdown (Styled)")
                .font(.caption)
                .foregroundStyle(.secondary)
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
    }
}

// MARK: - Read-only cursor fix

/// Restores the standard text cursor in the read-only engine view: I-beam
/// over text, pointing hand over links. The engine itself is silenced via
/// `isCursorExcluded` (its overlay escape hatch), so this tracking overlay
/// is the only cursor owner. Clicks pass through (`hitTest` returns nil).
private struct EngineCursorFixView: NSViewRepresentable {
    func makeNSView(context: Context) -> CursorTrackingView { CursorTrackingView() }
    func updateNSView(_ nsView: CursorTrackingView, context: Context) {}

    final class CursorTrackingView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self
            ))
        }

        override func mouseMoved(with event: NSEvent) { applyCursor(for: event) }
        override func mouseEntered(with event: NSEvent) { applyCursor(for: event) }

        private func applyCursor(for event: NSEvent) {
            if let textView = engineTextView(),
               isOverLink(in: textView, event: event) {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.iBeam.set()
            }
        }

        private func isOverLink(in textView: NSTextView, event: NSEvent) -> Bool {
            guard let textStorage = textView.textStorage, textStorage.length > 0 else { return false }
            let point = textView.convert(event.locationInWindow, from: nil)
            let index = textView.characterIndexForInsertion(at: point)
            guard index >= 0, index < textStorage.length else { return false }
            return textStorage.attribute(.link, at: index, effectiveRange: nil) != nil
        }

        /// The engine's NSTextView lives in a sibling branch of the SwiftUI
        /// overlay — find it under the nearest ancestor that contains one.
        private func engineTextView() -> NSTextView? {
            var ancestor: NSView? = superview
            var hops = 0
            while let current = ancestor, hops < 8 {
                if let textView = Self.findTextView(in: current) { return textView }
                ancestor = current.superview
                hops += 1
            }
            return nil
        }

        private static func findTextView(in view: NSView) -> NSTextView? {
            if let textView = view as? NSTextView { return textView }
            for subview in view.subviews {
                if let found = findTextView(in: subview) { return found }
            }
            return nil
        }
    }
}

// MARK: - Engine Bridge (bus + find bar backend)

/// Owns the engine's notification bus with instance-unique names (bus
/// notifications are process-global, so two live engine instances must not
/// share them) and adapts ClipSlop's find bar to the engine's find pipeline.
@MainActor
final class MarkdownEngineBridge: SearchableContent {
    let configuration: MarkdownEditorConfiguration
    private let bus: MarkdownEditorBus
    private var resultsObserver: NSObjectProtocol?
    private var pendingCount: CheckedContinuation<Int, Never>?
    private var currentQuery = ""

    init() {
        let id = UUID().uuidString
        let bus = MarkdownEditorBus(
            applyBoldRequest: .init("cs.engine.bold.\(id)"),
            applyItalicRequest: .init("cs.engine.italic.\(id)"),
            applyHeadingRequest: .init("cs.engine.heading.\(id)"),
            applyStrikethroughRequest: .init("cs.engine.strike.\(id)"),
            applyInlineCodeRequest: .init("cs.engine.inlineCode.\(id)"),
            applyBlockquoteRequest: .init("cs.engine.blockquote.\(id)"),
            applyUnorderedListRequest: .init("cs.engine.ulist.\(id)"),
            applyOrderedListRequest: .init("cs.engine.olist.\(id)"),
            applyLinkRequest: .init("cs.engine.link.\(id)"),
            applyCodeBlockRequest: .init("cs.engine.codeBlock.\(id)"),
            applyHorizontalRuleRequest: .init("cs.engine.hrule.\(id)"),
            findClearHighlights: .init("cs.engine.findClear.\(id)"),
            findQuery: .init("cs.engine.findQuery.\(id)"),
            findResults: .init("cs.engine.findResults.\(id)")
        )
        self.bus = bus
        self.configuration = MarkdownEditorConfiguration(
            services: MarkdownEditorServices(bus: bus),
            // Match the padding of the other content views (Textual preview
            // uses 16pt) — the engine's default is zero, gluing text to the
            // window edges.
            textInsets: TextInsets(horizontal: 16, vertical: 14),
            heightBehavior: .fitsContent
        )

        resultsObserver = NotificationCenter.default.addObserver(
            forName: bus.findResults,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let count = (notification.userInfo?["count"] as? Int) ?? 0
            MainActor.assumeIsolated {
                guard let self, let continuation = self.pendingCount else { return }
                self.pendingCount = nil
                continuation.resume(returning: count)
            }
        }
    }

    // No deinit: block-based observers auto-unregister when the token
    // deallocates (macOS 10.11+), and a nonisolated deinit can't touch
    // main-actor state under strict concurrency anyway.

    func post(_ name: KeyPath<MarkdownEditorBus, Notification.Name?>, userInfo: [String: Any]? = nil) {
        guard let notificationName = bus[keyPath: name] else { return }
        NotificationCenter.default.post(name: notificationName, object: nil, userInfo: userInfo)
    }

    // MARK: SearchableContent

    func performSearch(query: String) async -> Int {
        currentQuery = query
        guard !query.isEmpty, let queryName = bus.findQuery else {
            clearSearch()
            return 0
        }
        return await withCheckedContinuation { continuation in
            pendingCount = continuation
            // The engine's handler runs inline during post and answers via
            // the findResults notification, which resumes the continuation.
            NotificationCenter.default.post(
                name: queryName,
                object: nil,
                userInfo: ["query": query, "currentIndex": 0]
            )
            // No engine listening (view torn down) — don't hang the find bar.
            if let pending = pendingCount {
                pendingCount = nil
                pending.resume(returning: 0)
            }
        }
    }

    func highlightMatch(at index: Int) {
        guard !currentQuery.isEmpty, let queryName = bus.findQuery else { return }
        NotificationCenter.default.post(
            name: queryName,
            object: nil,
            userInfo: ["query": currentQuery, "currentIndex": index]
        )
    }

    func clearSearch() {
        if let clearName = bus.findClearHighlights {
            NotificationCenter.default.post(name: clearName, object: nil)
        }
    }
}
