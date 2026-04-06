import SwiftUI
import Combine

struct ProcessingView: View {
    let appState: AppState
    @State private var scrollTrigger = false
    @State private var isAtBottom = true
    private let loc = Loc.shared

    var body: some View {
        VStack(spacing: 16) {
            if appState.streamingText.isEmpty {
                Spacer()

                ProgressView()
                    .controlSize(.large)

                Text(loc.t("popup.processing"))
                    .font(.headline)
                    .foregroundStyle(.secondary)

                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(appState.streamingText)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)

                        Color.clear
                            .frame(height: 1)
                            .id("streamingEnd")

                        // Monitors NSScrollView to detect if user is near the bottom
                        ScrollBottomDetector(isAtBottom: $isAtBottom)
                            .frame(height: 0)
                    }
                    .onChange(of: scrollTrigger) {
                        if isAtBottom {
                            proxy.scrollTo("streamingEnd", anchor: .bottom)
                        }
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
                Text(loc.t("popup.receiving"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(loc.t("popup.cancel")) {
                    appState.cancelProcessing()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }
}

// MARK: - NSScrollView bottom detection

/// Hooks into the enclosing NSScrollView to report whether the scroll
/// position is near the bottom. Works reliably even as content grows.
struct ScrollBottomDetector: NSViewRepresentable {
    @Binding var isAtBottom: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let scrollView = view.enclosingScrollView else { return }
            scrollView.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                context.coordinator,
                selector: #selector(Coordinator.boundsDidChange),
                name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView
            )
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(isAtBottom: $isAtBottom) }

    final class Coordinator: NSObject {
        private let isAtBottom: Binding<Bool>

        init(isAtBottom: Binding<Bool>) {
            self.isAtBottom = isAtBottom
        }

        @objc func boundsDidChange(_ note: Notification) {
            guard let clipView = note.object as? NSClipView,
                  let docHeight = clipView.documentView?.frame.height else { return }
            let viewHeight = clipView.bounds.height
            let scrollY = clipView.bounds.origin.y
            let distanceFromBottom = docHeight - scrollY - viewHeight
            let atBottom = distanceFromBottom < 40
            if isAtBottom.wrappedValue != atBottom {
                isAtBottom.wrappedValue = atBottom
            }
        }
    }
}
