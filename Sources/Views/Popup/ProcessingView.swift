import SwiftUI
import Combine

struct ProcessingView: View {
    let appState: AppState
    @State private var scrollTrigger = false

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
                    .onChange(of: scrollTrigger) {
                        proxy.scrollTo("streamingEnd", anchor: .bottom)
                    }
                }
                .onReceive(
                    Timer.publish(every: 0.15, on: .main, in: .common).autoconnect()
                ) { _ in
                    if !appState.streamingText.isEmpty {
                        scrollTrigger.toggle()
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
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }
}
