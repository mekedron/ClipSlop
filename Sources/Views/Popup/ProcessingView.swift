import SwiftUI

struct ProcessingView: View {
    let appState: AppState

    var body: some View {
        VStack(spacing: 16) {
            if appState.streamingText.isEmpty {
                Spacer()

                ProgressView()
                    .controlSize(.large)

                Text("Processing...")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                Spacer()
            } else {
                // Streaming text display
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(appState.streamingText)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            .id("streamingEnd")
                    }
                    .onChange(of: appState.streamingText) {
                        proxy.scrollTo("streamingEnd", anchor: .bottom)
                    }
                }
            }

            Divider()

            HStack {
                ProgressView()
                    .controlSize(.small)
                Text("Receiving response...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") {
                    appState.cancelProcessing()
                }
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }
}
