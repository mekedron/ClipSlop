import SwiftUI
import KeyboardShortcuts

struct OnboardingView: View {
    let appState: AppState
    @State private var currentStep = 0

    private let totalSteps = 5

    var body: some View {
        VStack(spacing: 0) {
            // Content
            Group {
                switch currentStep {
                case 0: welcomeStep
                case 1: permissionsStep
                case 2: shortcutsStep
                case 3: providerStep
                case 4: demoStep
                default: EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Navigation
            HStack {
                // Step indicator
                HStack(spacing: 6) {
                    ForEach(0..<totalSteps, id: \.self) { step in
                        Circle()
                            .fill(step == currentStep ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: 8, height: 8)
                    }
                }

                Spacer()

                if currentStep > 0 {
                    Button("Back") {
                        withAnimation { currentStep -= 1 }
                    }
                }

                if currentStep < totalSteps - 1 {
                    Button("Continue") {
                        withAnimation { currentStep += 1 }
                    }
                    .buttonStyle(AlwaysProminentButtonStyle())
                } else {
                    Button("Get Started") {
                        appState.completeOnboarding()
                    }
                    .buttonStyle(AlwaysProminentButtonStyle())
                }
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 64))
                .foregroundStyle(.blue)

            Text("Welcome to ClipSlop")
                .font(.largeTitle.bold())

            Text("Transform any text with AI — translate, reformat, analyze.\nJust select text, press a shortcut, and pick a prompt.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 400)

            VStack(alignment: .leading, spacing: 8) {
                featureRow(icon: "text.cursor", text: "Grab selected text from any app")
                featureRow(icon: "camera.viewfinder", text: "OCR — scan text from screen")
                featureRow(icon: "brain", text: "Claude, GPT, Ollama — any AI provider")
                featureRow(icon: "folder", text: "Organize prompts in nested folders")
                featureRow(icon: "clock.arrow.circlepath", text: "Full transformation history with undo")
            }
            .padding(.top, 8)

            Spacer()
        }
        .padding(32)
    }

    private func featureRow(icon: String, text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .frame(width: 24)
                .foregroundStyle(.blue)
            Text(text)
                .font(.body)
        }
    }

    // MARK: - Step 2: Permissions

    private var permissionsStep: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "lock.shield")
                .font(.system(size: 48))
                .foregroundStyle(.blue)

            Text("Permissions")
                .font(.title.bold())

            Text("ClipSlop needs a couple of permissions to work.")
                .foregroundStyle(.secondary)

            VStack(spacing: 12) {
                PermissionCard(
                    title: "Accessibility",
                    description: "Required to capture selected text from other apps",
                    icon: "hand.raised",
                    isGranted: TextCaptureService.isAccessibilityEnabled(),
                    onRequest: {
                        TextCaptureService.requestAccessibility()
                    }
                )

                PermissionCard(
                    title: "Screen Recording",
                    description: "Required for OCR — scanning text from screen regions",
                    icon: "rectangle.dashed.badge.record",
                    isGranted: screenRecordingGranted(),
                    onRequest: {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                )
            }
            .frame(maxWidth: 420)

            Text("You can always change these later in System Settings → Privacy & Security")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            Spacer()
        }
        .padding(32)
    }

    // MARK: - Step 3: Shortcuts

    private var shortcutsStep: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "keyboard")
                .font(.system(size: 48))
                .foregroundStyle(.blue)

            Text("Keyboard Shortcuts")
                .font(.title.bold())

            Text("These are your global shortcuts. Customize them anytime in Settings.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 16) {
                ShortcutRow(
                    label: "Trigger ClipSlop",
                    name: .triggerClipSlop
                )
                ShortcutRow(
                    label: "From clipboard",
                    name: .triggerFromClipboard
                )
                ShortcutRow(
                    label: "Blank editor",
                    name: .triggerBlankEditor
                )
                ShortcutRow(
                    label: "Screen capture (OCR)",
                    name: .triggerScreenCapture
                )
            }
            .frame(maxWidth: 420)

            Spacer()
        }
        .padding(32)
    }

    // MARK: - Step 4: Provider Setup

    private var providerStep: some View {
        OnboardingProviderView(appState: appState)
    }

    // MARK: - Step 5: Demo

    private var demoStep: some View {
        OnboardingDemoView(appState: appState)
    }

    // MARK: - Helpers

    private func screenRecordingGranted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    private func requestScreenRecording() {
        CGRequestScreenCaptureAccess()
    }
}

// MARK: - Permission Card

struct PermissionCard: View {
    let title: String
    let description: String
    let icon: String
    let isGranted: Bool
    let onRequest: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(isGranted ? .green : .orange)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isGranted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title3)
            } else {
                Button("Grant") {
                    onRequest()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(16)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isGranted ? Color.green.opacity(0.3) : Color.orange.opacity(0.3))
        )
    }
}

// MARK: - Shortcut Row

struct ShortcutRow: View {
    let label: String
    let name: KeyboardShortcuts.Name

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            KeyboardShortcuts.Recorder(for: name)
                .frame(width: 160)
        }
        .padding(12)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.quaternary)
        )
    }
}

// MARK: - Button style that stays blue even when window is inactive

struct AlwaysProminentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .foregroundStyle(.white)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isEnabled ? Color.accentColor : Color.accentColor.opacity(0.5))
                    .opacity(configuration.isPressed ? 0.8 : 1.0)
            )
    }
}
