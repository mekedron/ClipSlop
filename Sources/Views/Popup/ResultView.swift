import SwiftUI

struct ResultView: View {
    let appState: AppState
    @State private var showCopiedFeedback = false

    var body: some View {
        VStack(spacing: 0) {
            // Result text
            ScrollView {
                Text(appState.currentDisplayText)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }

            Divider()

            // Action bar
            HStack(spacing: 12) {
                actionButton("Copy", icon: "doc.on.doc", key: "C") {
                    if appState.settings.closeOnCopy {
                        appState.copyAndDismiss()
                    } else {
                        appState.copyCurrentText()
                        showCopiedFeedback = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            showCopiedFeedback = false
                        }
                    }
                }

                actionButton("Paste", icon: "doc.on.clipboard", key: "V") {
                    appState.pasteCurrentText()
                }

                actionButton("Transform", icon: "arrow.triangle.2.circlepath", key: "M") {
                    appState.transformAgain()
                }

                if appState.currentSession?.hasSteps == true {
                    actionButton("Undo", icon: "arrow.uturn.backward", key: "U") {
                        appState.undoLastStep()
                    }
                }

                Spacer()

                if showCopiedFeedback {
                    Label("Copied!", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: showCopiedFeedback)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private func actionButton(
        _ label: String,
        icon: String,
        key: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                Text(label)
                Text("[\(key)]")
                    .foregroundStyle(.tertiary)
            }
            .font(.caption)
        }
        .buttonStyle(.bordered)
    }
}
