import SwiftUI
import KeyboardShortcuts
import LaunchAtLogin

struct GeneralSettingsView: View {
    let appState: AppState

    @State private var accessibilityGranted = AXIsProcessTrusted()
    @State private var screenCaptureGranted = CGPreflightScreenCaptureAccess()

    private let loc = Loc.shared

    var body: some View {
        @Bindable var settings = appState.settings
        @Bindable var locBinding = Loc.shared

        Form {
            Section(loc.t("settings.general.language")) {
                Picker(loc.t("settings.general.language"), selection: $locBinding.language) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text("\(lang.flag) \(lang.nativeName)").tag(lang)
                    }
                }
            }

            Section(loc.t("settings.general.icloud")) {
                HStack {
                    Toggle(loc.t("settings.general.icloud.toggle"), isOn: $settings.iCloudSyncEnabled)
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
                    Text(loc.t("settings.general.icloud.sign_in"))
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

            Section(loc.t("settings.general.shortcuts")) {
                KeyboardShortcuts.Recorder(loc.t("settings.general.shortcuts.trigger"), name: .triggerClipSlop)
                KeyboardShortcuts.Recorder(loc.t("settings.general.shortcuts.clipboard"), name: .triggerFromClipboard)
                KeyboardShortcuts.Recorder(loc.t("settings.general.shortcuts.blank"), name: .triggerBlankEditor)
                KeyboardShortcuts.Recorder(loc.t("settings.general.shortcuts.ocr"), name: .triggerScreenCapture)
            }

            Section(loc.t("settings.general.behavior")) {
                Toggle(loc.t("settings.general.behavior.streaming"), isOn: $settings.streamingEnabled)
                LaunchAtLogin.Toggle(loc.t("settings.general.behavior.launch_login"))
                Toggle(loc.t("settings.general.behavior.keycodes"), isOn: $settings.useKeyCodes)
                    .help(loc.t("settings.general.behavior.keycodes_help"))
                Toggle(loc.t("settings.general.behavior.close_on_escape"), isOn: $settings.closeOnEscape)
                    .help(loc.t("settings.general.behavior.close_on_escape_help"))
                LabeledContent(loc.t("settings.general.behavior.markdown_renderer")) {
                    Picker("", selection: $settings.markdownRenderer) {
                        ForEach(MarkdownRenderer.allCases) { renderer in
                            Text(renderer.displayName).tag(renderer)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                }
                .help(loc.t("settings.general.behavior.markdown_renderer_help"))

                if settings.markdownRenderer == .textual {
                    Toggle(loc.t("settings.general.behavior.show_images_markdown"), isOn: $settings.showImagesInMarkdown)
                        .help(loc.t("settings.general.behavior.show_images_markdown_help"))
                }

                if settings.markdownRenderer == .htmlEditor {
                    Toggle(loc.t("settings.general.behavior.preserve_image_widths"), isOn: $settings.preserveImageWidths)
                        .help(loc.t("settings.general.behavior.preserve_image_widths_help"))
                }
                LabeledContent(loc.t("settings.general.behavior.editor_mode")) {
                    Picker("", selection: $settings.editorMode) {
                        Text(loc.t("settings.general.behavior.editor_mode.plain")).tag(EditorMode.plainText)
                        Text(loc.t("settings.general.behavior.editor_mode.html")).tag(EditorMode.html)
                        Text(loc.t("settings.general.behavior.editor_mode.markdown")).tag(EditorMode.markdown)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 250)
                }
                .help(loc.t("settings.general.behavior.editor_mode_help"))
                LabeledContent(loc.t("settings.general.behavior.rich_text_mode")) {
                    Picker("", selection: $settings.richTextMode) {
                        Text(loc.t("settings.general.behavior.rich_text_mode.plain")).tag(RichTextMode.plainText)
                        Text(loc.t("settings.general.behavior.rich_text_mode.html")).tag(RichTextMode.html)
                        Text(loc.t("settings.general.behavior.rich_text_mode.markdown")).tag(RichTextMode.markdown)
                        Text(loc.t("settings.general.behavior.rich_text_mode.markdown_ai")).tag(RichTextMode.markdownAI)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 320)
                }
                .help(loc.t("settings.general.behavior.rich_text_mode_help"))

                if settings.richTextMode == .markdownAI {
                    Toggle(loc.t("settings.general.behavior.markdown_ai_only_rich"),
                           isOn: $settings.markdownAIOnlyRichText)
                        .help(loc.t("settings.general.behavior.markdown_ai_only_rich_help"))

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(loc.t("settings.general.behavior.conversion_prompt"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(loc.t("settings.general.behavior.reset_default")) {
                                settings.customConversionPrompt = AppSettings.defaultConversionPrompt
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .disabled(settings.customConversionPrompt == AppSettings.defaultConversionPrompt)
                        }
                        TextEditor(text: $settings.customConversionPrompt)
                            .font(.system(.caption, design: .monospaced))
                            .frame(height: 80)
                            .scrollContentBackground(.hidden)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(.quaternary)
                            )
                    }
                }
            }

            Section(loc.t("settings.general.appearance")) {
                Picker(loc.t("settings.general.appearance.theme"), selection: $settings.appColorScheme) {
                    ForEach(AppColorScheme.allCases) { scheme in
                        Text(loc.t("settings.general.appearance.theme.\(scheme.rawValue)")).tag(scheme)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: settings.appColorScheme) {
                    applyColorScheme(settings.appColorScheme)
                }

                LabeledContent(loc.t("settings.general.appearance.opacity")) {
                    Text("\(Int(settings.popupOpacity * 100))%")
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: $settings.popupOpacity, in: 0.3...1.0, step: 0.05)

                LabeledContent(loc.t("settings.general.appearance.width")) {
                    Text("\(Int(settings.popupWidth))px")
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: $settings.popupWidth, in: 500...1200, step: 10)

                LabeledContent(loc.t("settings.general.appearance.height")) {
                    Text("\(Int(settings.popupHeight))px")
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: $settings.popupHeight, in: 350...900, step: 10)

                Toggle(loc.t("settings.general.appearance.hide_menubar"), isOn: $settings.hideMenuBarIcon)
                    .onChange(of: settings.hideMenuBarIcon) {
                        NotificationCenter.default.post(name: .menuBarVisibilityChanged, object: nil)
                    }

                Toggle(loc.t("settings.general.appearance.hide_dock"), isOn: $settings.hideDockIcon)
                    .onChange(of: settings.hideDockIcon) {
                        NSApplication.shared.setActivationPolicy(settings.hideDockIcon ? .accessory : .regular)
                    }
            }

            Section(loc.t("settings.general.permissions")) {
                permissionRow(
                    title: loc.t("settings.general.permissions.accessibility"),
                    detail: loc.t("settings.general.permissions.accessibility_detail"),
                    isGranted: accessibilityGranted,
                    settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                )
                permissionRow(
                    title: loc.t("settings.general.permissions.screen_recording"),
                    detail: loc.t("settings.general.permissions.screen_recording_detail"),
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
                Button(isGranted ? loc.t("settings.general.permissions.open_settings") : loc.t("settings.general.permissions.grant")) {
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

    private func applyColorScheme(_ scheme: AppColorScheme) {
        switch scheme {
        case .system:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    @ViewBuilder
    private var syncStatusIndicator: some View {
        switch appState.syncService.status {
        case .disabled:
            EmptyView()
        case .unavailable:
            Image(systemName: "exclamationmark.icloud")
                .foregroundStyle(.orange)
                .help(loc.t("settings.general.icloud.unavailable"))
        case .current:
            Image(systemName: "checkmark.icloud")
                .foregroundStyle(.green)
                .help(loc.t("settings.general.icloud.synced"))
        case .syncing:
            ProgressView()
                .controlSize(.small)
                .help(loc.t("settings.general.icloud.syncing"))
        case .pendingConflict:
            Image(systemName: "questionmark.app.dashed")
                .foregroundStyle(.orange)
        case .error:
            Image(systemName: "xmark.icloud")
                .foregroundStyle(.red)
                .help(loc.t("settings.general.icloud.sync_error"))
        }
    }

    private var iCloudConflictView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(loc.t("settings.general.icloud.conflict.title"), systemImage: "icloud.and.arrow.down")
                .font(.subheadline.weight(.medium))

            Text(loc.t("settings.general.icloud.conflict.message"))
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button {
                    appState.syncService.resolveUseCloud()
                } label: {
                    Label(loc.t("settings.general.icloud.conflict.use_cloud"), systemImage: "icloud.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    appState.syncService.resolveUseLocal()
                } label: {
                    Label(loc.t("settings.general.icloud.conflict.upload_local"), systemImage: "icloud.and.arrow.up")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
    }
}
