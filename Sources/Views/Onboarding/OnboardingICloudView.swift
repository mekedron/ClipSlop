import SwiftUI

struct OnboardingICloudView: View {
    let appState: AppState
    private let loc = Loc.shared

    var body: some View {
        @Bindable var settings = appState.settings

        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "icloud")
                .font(.system(size: 48))
                .foregroundStyle(.blue)

            Text(loc.t("onboarding.icloud.title"))
                .font(.title.bold())

            Text(loc.t("onboarding.icloud.subtitle"))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 400)

            // Toggle
            VStack(spacing: 12) {
                Toggle(loc.t("onboarding.icloud.toggle"), isOn: $settings.iCloudSyncEnabled)
                    .toggleStyle(.switch)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(.background)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(.quaternary)
                    )
                    .onChange(of: settings.iCloudSyncEnabled) {
                        if settings.iCloudSyncEnabled {
                            appState.syncService.start(promptStore: appState.promptStore)
                        } else {
                            appState.syncService.stop()
                        }
                    }

                // Status
                syncStatusRow
            }
            .frame(maxWidth: 360)

            // Conflict resolution
            if case .pendingConflict = appState.syncService.status {
                conflictCard
                    .frame(maxWidth: 420)
            }

            Text(loc.t("onboarding.icloud.change_later"))
                .font(.caption)
                .foregroundStyle(.tertiary)

            Spacer()
        }
        .padding(32)
    }

    @ViewBuilder
    private var syncStatusRow: some View {
        switch appState.syncService.status {
        case .unavailable:
            Label(loc.t("onboarding.icloud.unavailable"), systemImage: "exclamationmark.icloud")
                .font(.caption)
                .foregroundStyle(.orange)
        case .current:
            Label(loc.t("onboarding.icloud.synced"), systemImage: "checkmark.icloud")
                .font(.caption)
                .foregroundStyle(.green)
        case .syncing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(loc.t("onboarding.icloud.syncing")).font(.caption).foregroundStyle(.secondary)
            }
        case .error(let message):
            Label(message, systemImage: "xmark.icloud")
                .font(.caption)
                .foregroundStyle(.red)
        case .disabled, .pendingConflict:
            EmptyView()
        }
    }

    private var conflictCard: some View {
        VStack(spacing: 12) {
            Label(loc.t("onboarding.icloud.conflict.title"), systemImage: "icloud.and.arrow.down")
                .font(.subheadline.weight(.medium))

            Text(loc.t("onboarding.icloud.conflict.message"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                Button {
                    appState.syncService.resolveUseCloud()
                } label: {
                    Label(loc.t("onboarding.icloud.conflict.use_cloud"), systemImage: "icloud.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    appState.syncService.resolveUseLocal()
                } label: {
                    Label(loc.t("onboarding.icloud.conflict.upload_local"), systemImage: "icloud.and.arrow.up")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(16)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.orange.opacity(0.3))
        )
    }
}
