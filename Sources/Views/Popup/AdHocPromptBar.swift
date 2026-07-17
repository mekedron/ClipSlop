import SwiftUI

/// Multi-line input for the ⌘K one-off instruction. Replaces the
/// breadcrumb + prompt-grid block while active. Enter runs the instruction,
/// Shift+Enter inserts a newline, Esc closes — all handled by the popup's
/// `KeyEventHandler`; this view only owns the text, focus, and sizing.
///
/// Sizing: starts one text line tall and grows a line per Shift+Enter up to
/// `maxAutoLines`; beyond that the editor scrolls internally. Dragging the
/// divider handle above switches to a manual height (session-only, resets on
/// the next activation so the bar always reopens compact).
struct AdHocPromptBar: View {
    let appState: AppState
    /// 0 = automatic line-count sizing; > 0 = height picked with the handle.
    @State private var manualHeight: Double = 0
    @State private var dragStartHeight: Double = 0
    private let loc = Loc.shared

    private static let lineHeight: CGFloat = {
        NSLayoutManager()
            .defaultLineHeight(for: NSFont.preferredFont(forTextStyle: .body))
            .rounded(.up)
    }()
    /// Top + bottom text inset — ours to set now, `AdHocPromptTextView` pins
    /// its NSTextView insets to exactly half of this per edge, so the caret,
    /// typed text, and placeholder overlay all share one origin.
    private static let verticalInset: CGFloat = 8
    private static let maxAutoLines = 5

    private var oneLineHeight: CGFloat { Self.lineHeight + Self.verticalInset }

    private var autoHeight: CGFloat {
        let lines = max(1, appState.adHocPromptText.components(separatedBy: "\n").count)
        return CGFloat(min(lines, Self.maxAutoLines)) * Self.lineHeight + Self.verticalInset
    }

    private var editorHeight: CGFloat {
        manualHeight > 0 ? manualHeight : autoHeight
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "wand.and.stars")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .frame(height: oneLineHeight)

                AdHocPromptTextView(
                    text: Bindable(appState).adHocPromptText,
                    verticalInset: Self.verticalInset / 2
                )
                .frame(height: editorHeight)
                .overlay(alignment: .topLeading) {
                    if appState.adHocPromptText.isEmpty {
                        Text(loc.t("popup.adhoc.placeholder"))
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .padding(.top, Self.verticalInset / 2)
                            .allowsHitTesting(false)
                    }
                }
                // SwiftUI's pointer manager resets NSCursor-pushed cursors;
                // the I-beam must be declared at the SwiftUI layer to stick.
                .pointerStyle(.horizontalText)

                Button {
                    appState.runAdHocPrompt()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title3)
                        .foregroundStyle(canSend ? Color.accentColor : Color.secondary.opacity(0.5))
                        .frame(width: 24, height: oneLineHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .help(loc.t("popup.hint.adhoc_run") + " (↩)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.25))
            // The grab strip straddles the divider like the prompt-grid
            // handle; overlaying it keeps the gray slab flush against the
            // divider (a sibling strip would read as a light gap above it).
            .overlay(alignment: .top) {
                ResizeHandle(
                    height: $manualHeight,
                    dragStartHeight: $dragStartHeight,
                    minHeight: oneLineHeight,
                    maxHeight: 300,
                    storageKey: nil,
                    initialHeight: { autoHeight }
                )
                .frame(height: 8)
                .offset(y: -4)
            }
        }
        .background(WindowDragBlocker())
    }

    private var canSend: Bool {
        !appState.adHocPromptText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }
}

/// Editable NSTextView replacing SwiftUI `TextEditor`, whose ~5pt internal
/// insets aren't exposed and left the caret misaligned with the placeholder
/// overlay. Zero line-fragment padding + an explicit container inset make
/// every metric the bar lays out against exact. The popup's window-level key
/// monitor still owns Enter/Esc/⌘K; plain keys reach this view as the first
/// responder.
private struct AdHocPromptTextView: NSViewRepresentable {
    @Binding var text: String
    let verticalInset: CGFloat

    func makeNSView(context: Context) -> NSScrollView {
        // TextKit 1 stack — see SearchableTextView for the macOS 26
        // TextKit 2 main-thread-freeze rationale.
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(
            containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        )
        textContainer.widthTracksTextView = true
        textContainer.lineFragmentPadding = 0
        layoutManager.addTextContainer(textContainer)

        let textView = NSTextView(frame: .zero, textContainer: textContainer)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = NSFont.preferredFont(forTextStyle: .body)
        textView.textContainerInset = NSSize(width: 0, height: verticalInset)
        textView.drawsBackground = false
        textView.delegate = context.coordinator
        textView.string = text
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        // NSTextView's default maxSize is its (zero) init frame — without
        // lifting it the view can't outgrow the clip, so past the 5-line cap
        // the caret walks out of the visible area instead of auto-scrolling.
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.documentView = textView

        // Focus once the panel has finished ordering front — the view isn't
        // in a window yet at makeNSView time.
        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        // Programmatic sets don't fire textDidChange, so no feedback loop.
        if textView.string != text {
            textView.string = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        private let text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}
