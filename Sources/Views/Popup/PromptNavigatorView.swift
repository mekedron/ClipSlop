import SwiftUI

struct PromptNavigatorView: View {
    let appState: AppState

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
                Text("Press a key to select")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                if !appState.navigationPath.isEmpty {
                    Text("⌫ Back")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Text("Esc Close")
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

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                // Mnemonic key badge
                Text(node.mnemonicKey.uppercased())
                    .font(.system(.title2, design: .rounded, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(node.isFolder ? Color.blue : Color.purple)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 2) {
                    Text(node.name)
                        .font(.headline)
                        .lineLimit(1)

                    if node.isFolder {
                        Text("\(node.children?.count ?? 0) items")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if node.isFolder {
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(12)
            .background(.background.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(.quaternary)
            )
        }
        .buttonStyle(.plain)
    }
}
