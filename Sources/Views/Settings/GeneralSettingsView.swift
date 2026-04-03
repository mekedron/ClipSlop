import SwiftUI
import KeyboardShortcuts
import LaunchAtLogin

struct GeneralSettingsView: View {
    let appState: AppState

    @State private var accessibilityGranted = AXIsProcessTrusted()
    @State private var screenCaptureGranted = CGPreflightScreenCaptureAccess()

    var body: some View {
        @Bindable var settings = appState.settings

        Form {
            Section("Keyboard Shortcuts") {
                KeyboardShortcuts.Recorder("Trigger ClipSlop:", name: .triggerClipSlop)
                KeyboardShortcuts.Recorder("From clipboard:", name: .triggerFromClipboard)
                KeyboardShortcuts.Recorder("Blank editor:", name: .triggerBlankEditor)
                KeyboardShortcuts.Recorder("Screen capture (OCR):", name: .triggerScreenCapture)
            }

            Section("Behavior") {
                Toggle("Enable streaming responses", isOn: $settings.streamingEnabled)
                LaunchAtLogin.Toggle("Launch at login")
            }

            Section("Appearance") {
                LabeledContent("Popup opacity") {
                    Text("\(Int(settings.popupOpacity * 100))%")
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: $settings.popupOpacity, in: 0.3...1.0, step: 0.05)

                LabeledContent("Popup width") {
                    Text("\(Int(settings.popupWidth))px")
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: $settings.popupWidth, in: 500...1200, step: 10)

                LabeledContent("Popup height") {
                    Text("\(Int(settings.popupHeight))px")
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: $settings.popupHeight, in: 350...900, step: 10)

                Toggle("Hide menu bar icon", isOn: $settings.hideMenuBarIcon)

                Toggle("Hide Dock icon", isOn: $settings.hideDockIcon)
            }

            Section("Permissions") {
                permissionRow(
                    title: "Accessibility",
                    detail: "Capture selected text from other apps",
                    isGranted: accessibilityGranted,
                    settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                )
                permissionRow(
                    title: "Screen Recording",
                    detail: "OCR screen capture",
                    isGranted: screenCaptureGranted,
                    settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
                )
            }
        }
        .formStyle(.grouped)
        .onAppear { refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { @MainActor in
                refreshPermissions()
            }
        }
    }

    private func permissionRow(
        title: String,
        detail: String,
        isGranted: Bool,
        settingsURL: String
    ) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                if isGranted {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                Button(isGranted ? "Open Settings" : "Grant") {
                    if let url = URL(string: settingsURL) {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func refreshPermissions() {
        accessibilityGranted = AXIsProcessTrusted()
        screenCaptureGranted = CGPreflightScreenCaptureAccess()
    }
}
