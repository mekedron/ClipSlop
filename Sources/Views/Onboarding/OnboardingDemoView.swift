import SwiftUI
import KeyboardShortcuts

struct OnboardingDemoView: View {
    let appState: AppState
    @State private var sampleText: String
    @State private var isAllSelected = false

    private let loc = Loc.shared

    init(appState: AppState) {
        self.appState = appState
        self._sampleText = State(initialValue: Loc.shared.t("onboarding.demo.sample_text"))
    }

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "sparkles")
                .font(.system(size: 48))
                .foregroundStyle(.blue)

            Text(loc.t("onboarding.demo.title"))
                .font(.title.bold())

            Text(loc.t("onboarding.demo.subtitle"))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            // Sample text
            VStack(spacing: 0) {
                TextEditor(text: $sampleText)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .frame(height: 90)
                    .padding(8)

                Divider()

                HStack {
                    Button(loc.t("onboarding.demo.select_all")) {
                        selectAllInEditor()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    if isAllSelected {
                        Label(loc.t("onboarding.demo.selected_hint"), systemImage: "checkmark")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }

                    Spacer()
                }
                .padding(8)
            }
            .background(.background)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.quaternary)
            )
            .padding(.horizontal, 32)

            // Trigger hint
            VStack(spacing: 8) {
                Text(loc.t("onboarding.demo.trigger_heading"))
                    .font(.headline)

                HStack(spacing: 16) {
                    // Shortcut hint
                    VStack(spacing: 4) {
                        KeyboardShortcuts.Recorder(for: .triggerClipSlop)
                            .disabled(true)
                        Text(loc.t("onboarding.demo.selected_text"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Text(loc.t("onboarding.demo.or"))
                        .foregroundStyle(.tertiary)

                    VStack(spacing: 4) {
                        KeyboardShortcuts.Recorder(for: .triggerFromClipboard)
                            .disabled(true)
                        Text(loc.t("onboarding.demo.from_clipboard"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Text(loc.t("onboarding.demo.or"))
                        .foregroundStyle(.tertiary)

                    // Manual button
                    VStack(spacing: 4) {
                        Button(loc.t("onboarding.demo.trigger")) {
                            // Select all text in the editor for visual feedback
                            selectAllInEditor()
                            // Put sample text on clipboard and trigger
                            ClipboardService.setText(sampleText)
                            appState.triggerFromClipboard()
                        }
                        .buttonStyle(AlwaysProminentButtonStyle())

                        Text(loc.t("onboarding.demo.manual"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(16)
            .background(.background)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(.quaternary)
            )
            .padding(.horizontal, 32)

            Spacer()
        }
        .padding(16)
        .onChange(of: loc.language) {
            sampleText = loc.t("onboarding.demo.sample_text")
        }
    }

    private func selectAllInEditor() {
        if let window = NSApp.windows.first(where: { $0 is OnboardingWindow }) {
            window.makeFirstResponder(findTextView(in: window.contentView))
            NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
        }
        isAllSelected = true
    }

    /// Recursively find NSTextView inside the view hierarchy (backing TextEditor)
    private func findTextView(in view: NSView?) -> NSTextView? {
        guard let view else { return nil }
        if let textView = view as? NSTextView { return textView }
        for subview in view.subviews {
            if let found = findTextView(in: subview) { return found }
        }
        return nil
    }
}
