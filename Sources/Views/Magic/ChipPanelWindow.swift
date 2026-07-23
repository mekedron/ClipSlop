import AppKit
import SwiftUI

/// One selectable intent in the chip panel.
struct MagicChip: Identifiable, Sendable {
    let index: Int          // 0-based; shown as 1-based number key
    let workflowID: String
    let title: String
    let subtitle: String?

    var id: String { workflowID }
}

/// The confidence-gate panel (§3.3): 2–4 ranked intent chips plus a
/// free-text hint field, anchored at the caret.
///
/// R2, resolved for V0: number keys and the hint field need key status and
/// R10 forbids a global event tap, so the panel **takes key on show** — the
/// QuickAccess precedent — and every dismissal path runs the focus-return
/// dance. The coordinator re-asserts the captured selection after focus
/// returns, and the pre-paste focus re-verification (not timing) is what
/// keeps a mid-dance mistake non-destructive.
final class ChipPanelWindow: NSPanel {
    private let onDismiss: () -> Void

    @MainActor
    init(
        chips: [MagicChip],
        onSelect: @escaping (Int) -> Void,
        onHint: @escaping (String) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.onDismiss = onDismiss
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 200),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        isMovableByWindowBackground = false
        collectionBehavior = [.canJoinAllSpaces, .transient]

        let hosting = NSHostingView(rootView: ChipPanelView(
            chips: chips, onSelect: onSelect, onHint: onHint
        ))
        contentView = hosting
        setContentSize(hosting.fittingSize)
    }

    @MainActor
    func show(anchoredAt anchor: NSRect) {
        guard let visible = CaretLocator.screenFor(anchor: anchor)?.visibleFrame else { return }
        let origin = CaretLocator.panelOrigin(anchor: anchor, panelSize: frame.size, visibleFrame: visible)
        setFrameOrigin(origin)
        // Same rationale as QuickAccessWindow.showNearCursor: the hotkey
        // fires in the source app's context; without explicit activation the
        // panel never receives the number keys or hint keystrokes.
        makeKeyAndOrderFront(nil)
        NSApplication.shared.activate()
    }

    override func cancelOperation(_ sender: Any?) {
        onDismiss()
    }

    override func resignKey() {
        super.resignKey()
        onDismiss()
    }

    override var canBecomeKey: Bool { true }
}

// MARK: - Content

private struct ChipPanelView: View {
    let chips: [MagicChip]
    let onSelect: (Int) -> Void
    let onHint: (String) -> Void

    @State private var hintText = ""
    @State private var hintHeight: CGFloat = 22

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(chips) { chip in
                Button {
                    onSelect(chip.index)
                } label: {
                    HStack(spacing: 10) {
                        Text("\(chip.index + 1)")
                            .font(.system(.caption, design: .monospaced, weight: .bold))
                            .frame(width: 18, height: 18)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(chip.title)
                                .font(.system(.body, weight: .medium))
                                .lineLimit(1)
                            if let subtitle = chip.subtitle {
                                Text(subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(ChipButtonStyle())
            }

            Divider()

            ChatInputTextView(text: $hintText, verticalInset: 3) { height in
                hintHeight = min(max(height, 22), 66)
            }
            .frame(height: hintHeight)
            .overlay(alignment: .topLeading) {
                if hintText.isEmpty {
                    Text(Loc.shared.t("magic.chips.hint_placeholder"))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 3)
                        .allowsHitTesting(false)
                }
            }

            Text(Loc.shared.t("magic.chips.footer"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(width: 340)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .background(ChipKeyHandler(
            chipCount: chips.count,
            hintIsEmpty: { hintText.isEmpty },
            hintText: { hintText },
            onSelect: onSelect,
            onHint: onHint
        ))
    }
}

private struct ChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(configuration.isPressed ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
            )
    }
}

/// Window-scoped key monitor (the PopupContentView `KeyEventHandler`
/// pattern): digits 1–4 select a chip while the hint is empty; Enter submits
/// the hint (or accepts the top chip when empty). Esc reaches the panel's
/// `cancelOperation` untouched.
private struct ChipKeyHandler: NSViewRepresentable {
    let chipCount: Int
    let hintIsEmpty: () -> Bool
    let hintText: () -> String
    let onSelect: (Int) -> Void
    let onHint: (String) -> Void

    func makeNSView(context: Context) -> KeyView {
        let view = KeyView()
        view.configure(self)
        return view
    }

    func updateNSView(_ nsView: KeyView, context: Context) {
        nsView.configure(self)
    }

    final class KeyView: NSView {
        private var handler: ChipKeyHandler?
        private var monitor: Any?

        func configure(_ handler: ChipKeyHandler) {
            self.handler = handler
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let handler = self.handler else { return event }
                guard event.window === self.window else { return event }

                // Physical digit-row key codes 1–4 (layout-independent).
                let digitKeyCodes: [UInt16: Int] = [18: 0, 19: 1, 20: 2, 21: 3]
                if handler.hintIsEmpty(),
                   event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
                   let index = digitKeyCodes[event.keyCode], index < handler.chipCount {
                    handler.onSelect(index)
                    return nil
                }
                if event.keyCode == 36 || event.keyCode == 76 {  // Return / keypad Enter
                    let text = handler.hintText().trimmingCharacters(in: .whitespacesAndNewlines)
                    if text.isEmpty {
                        handler.onSelect(0)
                    } else {
                        handler.onHint(text)
                    }
                    return nil
                }
                return event
            }
        }

        override func removeFromSuperview() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            super.removeFromSuperview()
        }
    }
}
