import SwiftUI

struct PermissionAlertView: View {
    let appState: AppState

    @State private var accessibilityGranted = PermissionService.isAccessibilityGranted
    @State private var screenCaptureGranted = PermissionService.isScreenRecordingGranted
    @State private var accessibilityPending = false
    @State private var screenRecordingPending = false

    private let loc = Loc.shared

    var body: some View {
        @Bindable var settings = appState.settings

        VStack(spacing: 20) {
            Spacer().frame(height: 8)

            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.orange)

            Text(loc.t("permission_alert.title"))
                .font(.title2.bold())

            Text(loc.t("permission_alert.subtitle"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

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
                            // Validate step
                            accessibilityGranted = PermissionService.isAccessibilityGranted
                            if !accessibilityGranted {
                                appState.movePermissionAlertAside()
                                PermissionService.requestAccessibility()
                            }
                        } else {
                            // Grant step
                            accessibilityPending = true
                            appState.movePermissionAlertAside()
                            PermissionService.requestAccessibility()
                        }
                    }
                )

                PermissionCard(
                    title: loc.t("onboarding.permissions.screen_recording"),
                    description: loc.t("onboarding.permissions.screen_recording.desc"),
                    icon: "rectangle.dashed.badge.record",
                    isGranted: screenCaptureGranted,
                    grantLabel: screenRecordingPending
                        ? loc.t("permission_alert.validate")
                        : loc.t("onboarding.permissions.grant"),
                    onRequest: {
                        if screenRecordingPending {
                            // Validate step — live check via ScreenCaptureKit
                            Task {
                                let granted = await PermissionService.checkScreenRecordingLive()
                                await MainActor.run { screenCaptureGranted = granted }
                                if !granted {
                                    await MainActor.run {
                                        appState.movePermissionAlertAside()
                                        PermissionService.requestScreenRecording()
                                    }
                                }
                            }
                        } else {
                            // Grant step
                            screenRecordingPending = true
                            appState.movePermissionAlertAside()
                            PermissionService.requestScreenRecording()
                        }
                    }
                )
            }
            .frame(maxWidth: 420)

            VStack(alignment: .leading, spacing: 8) {
                Label(loc.t("permission_alert.instructions_title"), systemImage: "wrench.and.screwdriver")
                    .font(.subheadline.bold())

                VStack(alignment: .leading, spacing: 4) {
                    instructionStep("1", loc.t("permission_alert.step1"))
                    instructionStep("2", loc.t("permission_alert.step2"))
                    instructionStep("3", loc.t("permission_alert.step3"))
                }
                .font(.subheadline)
            }
            .padding(12)
            .frame(maxWidth: 420, alignment: .leading)
            .background(.orange.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(.orange.opacity(0.3))
            )

            Spacer()

            HStack {
                Toggle(loc.t("permission_alert.dont_show_again"), isOn: $settings.suppressPermissionAlert)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)

                Spacer()

                Button(loc.t("permission_alert.close")) {
                    appState.dismissPermissionAlert()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(32)
    }

    private func instructionStep(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(number)
                .font(.subheadline.bold().monospacedDigit())
                .foregroundStyle(.orange)
                .frame(width: 16)
            Text(text)
        }
    }
}
