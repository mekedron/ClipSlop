import SwiftUI

/// Editable NSTextView replacing SwiftUI `TextEditor`, whose ~5pt internal
/// insets aren't exposed and left the caret misaligned with a placeholder
/// overlay. Zero line-fragment padding + an explicit container inset make
/// every metric the caller lays out against exact.
///
/// The hosting window's key monitor owns Enter/Esc; plain keys reach this view
/// as the first responder. Shared by the ⌘K ad-hoc bar (`AdHocPromptBar`) and
/// the prompt-assistant chat window (`AssistantChatView`).
struct ChatInputTextView: NSViewRepresentable {
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
        // lifting it the view can't outgrow the clip, so past the line cap
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
