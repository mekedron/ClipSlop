import SwiftUI

struct PromptNavigatorView: View {
    let appState: AppState
    private let loc = Loc.shared

    var body: some View {
        VStack(spacing: 0) {
            // Original text preview
            if let session = appState.currentSession {
                textPreview(session.currentText)
                Divider()
            }

            // Prompt grid
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 200), spacing: 12)],
                    spacing: 12
                ) {
                    ForEach(appState.currentPrompts) { node in
                        PromptCard(node: node) {
                            appState.navigateInto(node)
                        }
                    }
                }
                .padding(16)
            }

            Divider()

            // Bottom hints
            HStack {
                Text(loc.t("popup.navigator.press_key"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                if !appState.navigationPath.isEmpty {
                    Text("⌫ \(loc.t("popup.navigator.back"))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Text("Esc \(loc.t("popup.navigator.close"))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private func textPreview(_ text: String) -> some View {
        HStack {
            Text(text.prefix(200))
                .font(.system(.body, design: .monospaced))
                .lineLimit(3)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(16)
        .background(.quaternary.opacity(0.5))
    }
}

struct PromptCard: View {
    let node: PromptNode
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(node.mnemonicDisplay)
                    .font(.system(node.mnemonicModifiers == nil ? .body : .caption, design: .rounded, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(minWidth: 28, minHeight: 28)
                    .padding(.horizontal, node.mnemonicModifiers == nil ? 0 : 4)
                    .background(node.isFolder ? Color.blue : Color.purple)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                Text(node.name)
                    .font(.subheadline)
                    .lineLimit(1)

                Spacer()

                if node.isFolder {
                    Text("\(node.children?.count ?? 0)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(isHovered ? AnyShapeStyle(.primary.opacity(0.08)) : AnyShapeStyle(.background.opacity(0.6)))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isHovered ? AnyShapeStyle(.primary.opacity(0.2)) : AnyShapeStyle(.quaternary))
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .background(WindowDragBlocker())
        .help(node.systemPrompt ?? (node.isFolder ? "\(node.name) (\(node.children?.count ?? 0))" : node.name))
    }
}

/// Blocks window drag on this area by intercepting mouseDown.
/// This lets users cancel a click by dragging off the button without moving the window.
struct WindowDragBlocker: NSViewRepresentable {
    func makeNSView(context: Context) -> DragBlockerView { DragBlockerView() }
    func updateNSView(_ nsView: DragBlockerView, context: Context) {}

    class DragBlockerView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
    }
}
