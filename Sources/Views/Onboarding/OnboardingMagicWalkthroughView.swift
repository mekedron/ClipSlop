import SwiftUI
import KeyboardShortcuts

/// The grammar walkthrough (§9.3): the user *performs* each interaction row
/// with the real hotkey against a sandbox field — select-to-instruct is the
/// differentiated skill and nothing else teaches it. Steps complete when a
/// real press finishes (the coordinator reaches the toast phase), not by
/// simulation.
struct OnboardingMagicWalkthroughView: View {
    let appState: AppState

    @State private var sandboxText = ""
    @State private var completedSteps: Set<Int> = []
    @State private var activeStep = 0

    private let loc = Loc.shared

    private var coordinator: MagicPressCoordinator { appState.magicCoordinator }

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 4)

            Image(systemName: "graduationcap")
                .font(.system(size: 44))
                .foregroundStyle(.blue)

            Text(loc.t("onboarding.magic.walkthrough.title"))
                .font(.title.bold())

            HStack(spacing: 8) {
                Text(loc.t("onboarding.magic.walkthrough.subtitle"))
                    .foregroundStyle(.secondary)
                KeyboardShortcuts.Recorder(for: .triggerMagic)
                    .disabled(true)
            }

            VStack(alignment: .leading, spacing: 8) {
                stepRow(0, loc.t("onboarding.magic.walkthrough.step_empty"))
                stepRow(1, loc.t("onboarding.magic.walkthrough.step_continue"))
                stepRow(2, loc.t("onboarding.magic.walkthrough.step_instruct"))
            }
            .frame(maxWidth: 460, alignment: .leading)

            VStack(spacing: 0) {
                TextEditor(text: $sandboxText)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .frame(height: 100)
                    .padding(8)

                Divider()

                HStack {
                    Button(loc.t("onboarding.magic.walkthrough.select_note")) {
                        selectAllInEditor()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(sandboxText.isEmpty)

                    Spacer()

                    Button(loc.t("onboarding.magic.walkthrough.reset")) {
                        sandboxText = ""
                    }
                    .buttonStyle(.plain)
                    .controlSize(.small)
                    .foregroundStyle(.secondary)
                }
                .padding(8)
            }
            .background(.background)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
            .frame(maxWidth: 460)

            if !hasProvider {
                Label(loc.t("onboarding.magic.walkthrough.no_provider"), systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Spacer(minLength: 4)
        }
        .padding(24)
        .onChange(of: coordinator.phase) { _, newPhase in
            // A press that reached the post-insert toast = the row was
            // performed for real.
            if newPhase == .toast, activeStep < 3 {
                completedSteps.insert(activeStep)
                activeStep = min(activeStep + 1, 2)
            }
        }
    }

    private var hasProvider: Bool {
        appState.magicCoordinator.roleStore.provider(
            for: .generationMagic, in: appState.providerStore
        ) != nil
    }

    private func stepRow(_ index: Int, _ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: completedSteps.contains(index)
                  ? "checkmark.circle.fill"
                  : (index == activeStep ? "circle.dotted" : "circle"))
                .foregroundStyle(completedSteps.contains(index) ? .green : .secondary)
            Text(text)
                .font(.callout)
                .foregroundStyle(index == activeStep ? .primary : .secondary)
        }
    }

    private func selectAllInEditor() {
        if let window = NSApp.windows.first(where: { $0 is OnboardingWindow }) {
            window.makeFirstResponder(findTextView(in: window.contentView))
            NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
        }
    }

    private func findTextView(in view: NSView?) -> NSTextView? {
        guard let view else { return nil }
        if let textView = view as? NSTextView { return textView }
        for subview in view.subviews {
            if let found = findTextView(in: subview) { return found }
        }
        return nil
    }
}
