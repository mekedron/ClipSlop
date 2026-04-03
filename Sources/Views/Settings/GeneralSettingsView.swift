import SwiftUI
import KeyboardShortcuts
import LaunchAtLogin

struct GeneralSettingsView: View {
    let appState: AppState
    @State private var accessibilityGranted = AXIsProcessTrusted()
    @State private var screenCaptureGranted = CGPreflightScreenCaptureAccess()

    var body: some View {
        Form {
            Section("Keyboard Shortcuts") {
                KeyboardShortcuts.Recorder("Trigger (selected text):", name: .triggerClipSlop)
                KeyboardShortcuts.Recorder("Copy & process:", name: .triggerCopyAndProcess)
                KeyboardShortcuts.Recorder("Trigger (clipboard):", name: .triggerFromClipboard)
                KeyboardShortcuts.Recorder("Screen capture (OCR):", name: .triggerScreenCapture)
            }

            Section("Behavior") {
                Toggle("Enable streaming responses", isOn: Bindable(appState.settings).streamingEnabled)

                LaunchAtLogin.Toggle("Launch at login")
            }

            Section("Appearance") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Popup opacity")
                        Spacer()
                        Text("\(Int(appState.settings.popupOpacity * 100))%")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: Bindable(appState.settings).popupOpacity, in: 0.3...1.0, step: 0.05)
                }
            }

            Section("Permissions") {
                permissionRow(
                    title: "Accessibility",
                    detail: "Needed to capture selected text from other apps",
                    isGranted: accessibilityGranted,
                    settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                )

                permissionRow(
                    title: "Screen Recording",
                    detail: "Needed for OCR screen capture",
                    isGranted: screenCaptureGranted,
                    settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
                )
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear { refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
    }

    private func permissionRow(
        title: String,
        detail: String,
        isGranted: Bool,
        settingsURL: String
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: isGranted ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isGranted ? .green : .secondary)
                    Text(title)
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(isGranted ? "Open Settings" : "Grant") {
                if let url = URL(string: settingsURL) {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func refreshPermissions() {
        accessibilityGranted = AXIsProcessTrusted()
        screenCaptureGranted = CGPreflightScreenCaptureAccess()
    }
}
