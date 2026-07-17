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

                ChatInputTextView(
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
