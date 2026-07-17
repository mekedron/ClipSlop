import AppKit
import SwiftUI

/// Root view of the prompt-library assistant window: a provider notice when
/// tool calling isn't available, otherwise the chat transcript + input bar.
struct AssistantChatView: View {
    let appState: AppState
    private let loc = Loc.shared

    private var service: PromptAssistantService { appState.promptAssistant }

    var body: some View {
        Group {
            if let provider = service.activeProvider {
                chatBody(provider: provider)
            } else {
                UnsupportedProviderNotice(appState: appState)
            }
        }
        .frame(minWidth: 380, minHeight: 420)
        .background(
            AssistantVisualEffectBlur(material: .menu, blendingMode: .behindWindow)
                .ignoresSafeArea()
        )
        .background(AssistantKeyHandler(appState: appState))
    }

    private func chatBody(provider: AIProviderConfig) -> some View {
        VStack(spacing: 0) {
            header(provider: provider)
            Divider()
            transcript
            if let error = service.errorMessage {
                errorBanner(error)
            }
            Divider()
            AssistantInputBar(service: service)
        }
    }

    // MARK: - Header

    private func header(provider: AIProviderConfig) -> some View {
        HStack {
            providerControl(provider: provider)
            Spacer()
            Button {
                service.reset()
            } label: {
                Label(loc.t("assistant.new_chat"), systemImage: "square.and.pencil")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(service.items.isEmpty && !service.isBusy)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Shows the active provider and lets the user switch among tool-calling
    /// providers, with a jump to Provider Settings. Locked while the assistant
    /// is busy so the provider can't change mid-run.
    private func providerControl(provider: AIProviderConfig) -> some View {
        Menu {
            ForEach(service.toolCallingProviders) { candidate in
                Button {
                    service.selectProvider(candidate.id)
                } label: {
                    if candidate.id == provider.id {
                        Label(candidate.name, systemImage: "checkmark")
                    } else {
                        Text(candidate.name)
                    }
                }
            }
            Divider()
            Button(loc.t("assistant.unsupported.open_settings")) {
                appState.openSettingsToProviders()
            }
        } label: {
            HStack(spacing: 3) {
                Text(loc.t("assistant.using", provider.name))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(service.isBusy)
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if service.items.isEmpty {
                        emptyState
                    }
                    ForEach(service.items) { item in
                        AssistantChatItemView(item: item, service: service)
                    }
                    if service.phase == .thinking {
                        thinkingRow
                    }
                    Color.clear.frame(height: 1).id(bottomAnchor)
                }
                .padding(12)
            }
            .onChange(of: service.items.count) {
                withAnimation { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
            }
            .onChange(of: service.phase) {
                withAnimation { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "wand.and.stars")
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text(loc.t("assistant.empty.title"))
                .font(.callout.weight(.medium))
            Text(loc.t("assistant.empty.body"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }

    private var thinkingRow: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(loc.t("assistant.thinking"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var bottomAnchor: String { "assistant-bottom" }

    // MARK: - Error banner

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.08))
    }
}

// MARK: - Input bar

/// The chat input + send button. Split out so typing (which mutates
/// `service.draft` on every keystroke) re-renders only this view, not the whole
/// transcript. Sizing mirrors `AdHocPromptBar`: grows one line per newline up
/// to `maxAutoLines`, then the editor scrolls internally.
private struct AssistantInputBar: View {
    @Bindable var service: PromptAssistantService
    private let loc = Loc.shared

    private static let lineHeight: CGFloat = {
        NSLayoutManager()
            .defaultLineHeight(for: NSFont.preferredFont(forTextStyle: .body))
            .rounded(.up)
    }()
    private static let verticalInset: CGFloat = 8
    private static let maxAutoLines = 5

    private var oneLineHeight: CGFloat { Self.lineHeight + Self.verticalInset }

    private var editorHeight: CGFloat {
        let lines = max(1, service.draft.components(separatedBy: "\n").count)
        return CGFloat(min(lines, Self.maxAutoLines)) * Self.lineHeight + Self.verticalInset
    }

    private var canSend: Bool {
        service.phase == .idle
            && !service.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ChatInputTextView(
                text: $service.draft,
                verticalInset: Self.verticalInset / 2
            )
            .frame(height: editorHeight)
            .overlay(alignment: .topLeading) {
                if service.draft.isEmpty {
                    Text(loc.t("assistant.input.placeholder"))
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .padding(.top, Self.verticalInset / 2)
                        .allowsHitTesting(false)
                }
            }
            .pointerStyle(.horizontalText)

            Button {
                service.send(service.draft)
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title3)
                    .foregroundStyle(canSend ? Color.accentColor : Color.secondary.opacity(0.5))
                    .frame(width: 24, height: oneLineHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .help(loc.t("assistant.send") + " (↩)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - Unsupported provider notice

private struct UnsupportedProviderNotice: View {
    let appState: AppState
    private let loc = Loc.shared

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "wand.and.stars.inverse")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text(loc.t("assistant.unsupported.title"))
                .font(.headline)
            Text(loc.t("assistant.unsupported.body"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                appState.openSettingsToProviders()
            } label: {
                Text(loc.t("assistant.unsupported.open_settings"))
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Frosted window background

/// Fills the transparent panel with a behind-window blur so content behind the
/// window doesn't show through (the window itself is `.clear`/non-opaque for
/// rounded corners). Mirrors QuickAccess's visual-effect background.
private struct AssistantVisualEffectBlur: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

// MARK: - Key handling (Enter sends, Shift+Enter newline, Esc closes)

private struct AssistantKeyHandler: NSViewRepresentable {
    let appState: AppState

    func makeNSView(context: Context) -> KeyView {
        let view = KeyView()
        view.appState = appState
        return view
    }

    func updateNSView(_ nsView: KeyView, context: Context) {
        nsView.appState = appState
    }

    final class KeyView: NSView {
        var appState: AppState?
        private var monitor: Any?

        private enum KeyCode {
            static let escape: UInt16 = 53
            static let enter: UInt16 = 36
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil, monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard let self, let appState = self.appState else { return event }
                    guard event.window === self.window else { return event }
                    return self.handle(event, appState: appState) ? nil : event
                }
            }
        }

        override func removeFromSuperview() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            super.removeFromSuperview()
        }

        @MainActor
        private func handle(_ event: NSEvent, appState: AppState) -> Bool {
            let flags = event.modifierFlags
            switch event.keyCode {
            case KeyCode.escape:
                appState.dismissAssistant()
                return true
            case KeyCode.enter where !flags.contains(.shift) && !flags.contains(.command):
                // Enter sends; Shift+Enter falls through to insert a newline.
                appState.promptAssistant.send(appState.promptAssistant.draft)
                return true
            default:
                return false
            }
        }
    }
}
