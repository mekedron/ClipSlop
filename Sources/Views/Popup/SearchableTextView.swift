import SwiftUI

/// Read-only NSTextView with search highlighting support.
/// Replaces SwiftUI `Text` for plain text display mode.
struct SearchableTextView: NSViewRepresentable {
    let text: String
    let findBarState: FindBarState

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.drawsBackground = false
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
        context.coordinator.textView = textView

        // Register as the active search backend
        findBarState.activeBackend = context.coordinator

        // If search is already active, re-execute
        if findBarState.isVisible, !findBarState.searchQuery.isEmpty {
            findBarState.executeSearchImmediately()
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
            // Re-run search if active
            if findBarState.isVisible, !findBarState.searchQuery.isEmpty {
                findBarState.executeSearchImmediately()
            }
        }
        context.coordinator.textView = textView
        findBarState.activeBackend = context.coordinator
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    final class Coordinator: NSObject, SearchableContent {
        weak var textView: NSTextView?
        private var matchRanges: [NSRange] = []

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

            // Highlight all matches in yellow
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

            // Reset all to yellow
            for range in matchRanges {
                layoutManager?.addTemporaryAttribute(
                    .backgroundColor,
                    value: NSColor.systemYellow.withAlphaComponent(0.4),
                    forCharacterRange: range
                )
            }

            // Current match in orange
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
