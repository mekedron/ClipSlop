import SwiftUI
import KeyboardShortcuts

struct OnboardingView: View {
    let appState: AppState
    @State private var currentStep = UserDefaults.standard.integer(forKey: "onboardingStep")
    @State private var accessibilityGranted = false
    @State private var screenRecordingGranted = false
    @State private var accessibilityPending = false
    @State private var screenRecordingPending = false

    private let loc = Loc.shared
    private let totalSteps = 7

    var body: some View {
        VStack(spacing: 0) {
            // Content
            Group {
                switch currentStep {
                case 0: OnboardingLanguageView()
                case 1: welcomeStep
                case 2: permissionsStep
                case 3: shortcutsStep
                case 4: providerStep
                case 5: iCloudStep
                case 6: demoStep
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
                    Button(loc.t("onboarding.back")) {
                        withAnimation { currentStep -= 1 }
                    }
                }

                if currentStep < totalSteps - 1 {
                    Button(loc.t("onboarding.continue")) {
                        withAnimation { currentStep += 1 }
                    }
                    .buttonStyle(AlwaysProminentButtonStyle())
                } else {
                    Button(loc.t("onboarding.get_started")) {
                        appState.completeOnboarding()
                    }
                    .buttonStyle(AlwaysProminentButtonStyle())
                }
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: currentStep) {
            UserDefaults.standard.set(currentStep, forKey: "onboardingStep")
        }
        .onAppear { refreshPermissions() }
    }

    // MARK: - Step 2: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 64))
                .foregroundStyle(.blue)

            Text(loc.t("onboarding.welcome.title"))
                .font(.largeTitle.bold())

            Text(loc.t("onboarding.welcome.subtitle"))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 400)

            VStack(alignment: .leading, spacing: 8) {
                featureRow(icon: "text.cursor", text: loc.t("onboarding.welcome.feature.grab"))
                featureRow(icon: "camera.viewfinder", text: loc.t("onboarding.welcome.feature.ocr"))
                featureRow(icon: "brain", text: loc.t("onboarding.welcome.feature.providers"))
                featureRow(icon: "folder", text: loc.t("onboarding.welcome.feature.folders"))
                featureRow(icon: "clock.arrow.circlepath", text: loc.t("onboarding.welcome.feature.history"))
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

    // MARK: - Step 3: Permissions

    private var permissionsStep: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "lock.shield")
                .font(.system(size: 48))
                .foregroundStyle(.blue)

            Text(loc.t("onboarding.permissions.title"))
                .font(.title.bold())

            Text(loc.t("onboarding.permissions.subtitle"))
                .foregroundStyle(.secondary)

            VStack(spacing: 12) {
                PermissionCard(
                    title: loc.t("onboarding.permissions.accessibility"),
                    description: loc.t("onboarding.permissions.accessibility.desc"),
                    icon: "hand.raised",
                    isGranted: accessibilityGranted,
                    grantLabel: accessibilityPending
                        ? loc.t("permission_alert.validate")
                        : loc.t("onboarding.permissions.grant"),
                    onRequest: {
                        if accessibilityPending {
                            accessibilityGranted = PermissionService.isAccessibilityGranted
                            if !accessibilityGranted {
                                moveOnboardingAside()
                                PermissionService.requestAccessibility()
                            }
                        } else {
                            accessibilityPending = true
                            moveOnboardingAside()
                            PermissionService.requestAccessibility()
                        }
                    }
                )

                PermissionCard(
                    title: loc.t("onboarding.permissions.screen_recording"),
                    description: loc.t("onboarding.permissions.screen_recording.desc"),
                    icon: "rectangle.dashed.badge.record",
                    isGranted: screenRecordingGranted,
                    grantLabel: screenRecordingPending
                        ? loc.t("permission_alert.validate")
                        : loc.t("onboarding.permissions.grant"),
                    onRequest: {
                        if screenRecordingPending {
                            Task {
                                let granted = await PermissionService.checkScreenRecordingLive()
                                await MainActor.run { screenRecordingGranted = granted }
                                if !granted {
                                    await MainActor.run {
                                        moveOnboardingAside()
                                        PermissionService.requestScreenRecording()
                                    }
                                }
                            }
                        } else {
                            screenRecordingPending = true
                            moveOnboardingAside()
                            PermissionService.requestScreenRecording()
                        }
                    }
                )
            }
            .frame(maxWidth: 420)

            Text(loc.t("onboarding.permissions.hint"))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            Spacer()
        }
        .padding(32)
    }

    // MARK: - Step 4: Shortcuts

    private var shortcutsStep: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "keyboard")
                .font(.system(size: 48))
                .foregroundStyle(.blue)

            Text(loc.t("onboarding.shortcuts.title"))
                .font(.title.bold())

            Text(loc.t("onboarding.shortcuts.subtitle"))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 16) {
                ShortcutRow(
                    label: loc.t("onboarding.shortcuts.trigger"),
                    name: .triggerClipSlop
                )
                ShortcutRow(
                    label: loc.t("onboarding.shortcuts.clipboard"),
                    name: .triggerFromClipboard
                )
                ShortcutRow(
                    label: loc.t("onboarding.shortcuts.blank"),
                    name: .triggerBlankEditor
                )
                ShortcutRow(
                    label: loc.t("onboarding.shortcuts.ocr_clipboard"),
                    name: .triggerOCRToClipboard
                )
                ShortcutRow(
                    label: loc.t("onboarding.shortcuts.ocr_clipslop"),
                    name: .triggerScreenCapture
                )
            }
            .frame(maxWidth: 420)

            Spacer()
        }
        .padding(32)
    }

    // MARK: - Step 5: Provider Setup

    private var providerStep: some View {
        OnboardingProviderView(appState: appState)
    }

    // MARK: - Step 6: iCloud Sync

    private var iCloudStep: some View {
        OnboardingICloudView(appState: appState)
    }

    // MARK: - Step 7: Demo

    private var demoStep: some View {
        OnboardingDemoView(appState: appState)
    }

    // MARK: - Helpers

    private func refreshPermissions() {
        accessibilityGranted = PermissionService.isAccessibilityGranted
        screenRecordingGranted = PermissionService.isScreenRecordingGranted
    }

    private func moveOnboardingAside() {
        if let window = NSApp.windows.first(where: { $0 is OnboardingWindow }) as? OnboardingWindow {
            window.moveAside()
        }
    }
}

// MARK: - Permission Card

struct PermissionCard: View {
    let title: String
    let description: String
    let icon: String
    let isGranted: Bool
    var grantLabel: String = "Grant"
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
                Button(grantLabel) {
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
