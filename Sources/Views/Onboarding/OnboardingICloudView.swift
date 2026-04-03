import SwiftUI

struct OnboardingICloudView: View {
    let appState: AppState

    var body: some View {
        @Bindable var settings = appState.settings

        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "icloud")
                .font(.system(size: 48))
                .foregroundStyle(.blue)

            Text("iCloud Sync")
                .font(.title.bold())

            Text("Keep your prompts in sync across all your Macs.\nChanges on one device appear everywhere automatically.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 400)

            // Toggle
            VStack(spacing: 12) {
                Toggle("Sync prompts via iCloud", isOn: $settings.iCloudSyncEnabled)
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

            Text("You can change this later in Settings.")
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
            Label("iCloud is not available. Sign in to iCloud in System Settings.", systemImage: "exclamationmark.icloud")
                .font(.caption)
                .foregroundStyle(.orange)
        case .current:
            Label("Synced", systemImage: "checkmark.icloud")
                .font(.caption)
                .foregroundStyle(.green)
        case .syncing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Syncing...").font(.caption).foregroundStyle(.secondary)
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
            Label("Existing prompts found in iCloud", systemImage: "icloud.and.arrow.down")
                .font(.subheadline.weight(.medium))

            Text("Another Mac has already synced prompts to iCloud. Would you like to use those or upload your current prompts?")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

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
        .padding(16)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.orange.opacity(0.3))
        )
    }
}
