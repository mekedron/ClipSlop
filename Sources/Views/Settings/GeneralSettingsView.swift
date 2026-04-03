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
            Section("iCloud") {
                HStack {
                    Toggle("Sync prompts via iCloud", isOn: $settings.iCloudSyncEnabled)
                        .onChange(of: settings.iCloudSyncEnabled) {
                            if settings.iCloudSyncEnabled {
                                appState.syncService.start(promptStore: appState.promptStore)
                            } else {
                                appState.syncService.stop()
                            }
                        }

                    Spacer()

                    syncStatusIndicator
                }

                if case .unavailable = appState.syncService.status {
                    Text("Sign in to iCloud in System Settings to enable sync.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if case .error(let message) = appState.syncService.status {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if case .pendingConflict = appState.syncService.status {
                    iCloudConflictView
                }
            }

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

    @ViewBuilder
    private var syncStatusIndicator: some View {
        switch appState.syncService.status {
        case .disabled:
            EmptyView()
        case .unavailable:
            Image(systemName: "exclamationmark.icloud")
                .foregroundStyle(.orange)
                .help("iCloud is not available")
        case .current:
            Image(systemName: "checkmark.icloud")
                .foregroundStyle(.green)
                .help("Synced")
        case .syncing:
            ProgressView()
                .controlSize(.small)
                .help("Syncing...")
        case .pendingConflict:
            Image(systemName: "questionmark.app.dashed")
                .foregroundStyle(.orange)
        case .error:
            Image(systemName: "xmark.icloud")
                .foregroundStyle(.red)
                .help("Sync error")
        }
    }

    private var iCloudConflictView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Existing prompts found in iCloud", systemImage: "icloud.and.arrow.down")
                .font(.subheadline.weight(.medium))

            Text("Would you like to use the prompts from iCloud or upload your current prompts?")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button {
                    appState.syncService.resolveUseCloud()
                } label: {
                    Label("Use iCloud", systemImage: "icloud.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    appState.syncService.resolveUseLocal()
                } label: {
                    Label("Upload Local", systemImage: "icloud.and.arrow.up")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
    }
}
