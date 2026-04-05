import SwiftUI

struct HistorySidebarView: View {
    let appState: AppState
    private let loc = Loc.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 2) {
                if let session = appState.currentSession {
                    // Newest steps first
                    ForEach(Array(session.steps.enumerated().reversed()), id: \.element.id) { index, step in
                        historyItem(
                            index: index,
                            label: step.promptName,
                            icon: "wand.and.stars",
                            preview: step.outputText,
                            isSelected: isStepSelected(index, session: session)
                        )
                    }

                    // Original text at the bottom
                    VStack(spacing: 4) {
                        historyItem(
                            index: -1,
                            label: loc.t("popup.history.original"),
                            icon: "doc.text",
                            preview: session.originalText,
                            isSelected: appState.selectedHistoryStepIndex == -1
                        )

                        if appState.selectedHistoryStepIndex == -1 {
                            Picker("", selection: Bindable(appState).originalViewMode) {
                                Text("Plain").tag(RichTextMode.plainText)
                                Text("HTML").tag(RichTextMode.html)
                                Text("MD").tag(RichTextMode.markdown)
                                Text("MD (AI)").tag(RichTextMode.markdownAI)
                            }
                            .pickerStyle(.segmented)
                            .controlSize(.mini)
                            .padding(.horizontal, 4)
                            .onChange(of: appState.originalViewMode) { _, newMode in
                                if newMode == .markdownAI {
                                    appState.convertOriginalWithAI()
                                }
                            }
                        }
                    }
                }
            }
            .padding(6)
        }
        .background(.background.opacity(0.3))
    }

    private func isStepSelected(_ index: Int, session: TransformationSession) -> Bool {
        if let selected = appState.selectedHistoryStepIndex {
            return selected == index
        }
        return index == session.steps.count - 1
    }

    private func historyItem(
        index: Int,
        label: String,
        icon: String,
        preview: String,
        isSelected: Bool
    ) -> some View {
        Button {
            appState.selectHistoryStep(at: index)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(isSelected ? .white : .secondary)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(isSelected ? .white : .primary)
                        .lineLimit(1)

                    Text(preview.prefix(50))
                        .font(.caption2)
                        .foregroundStyle(isSelected ? .white.opacity(0.7) : .secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(isSelected ? Color.accentColor : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .contextMenu {
            if index >= 0 {
                Button(role: .destructive) {
                    appState.removeHistoryStep(at: index)
                } label: {
                    Label(loc.t("popup.history.delete"), systemImage: "trash")
                }
            }
        }
    }
}
