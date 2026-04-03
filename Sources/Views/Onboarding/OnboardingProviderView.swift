import SwiftUI

struct OnboardingProviderView: View {
    let appState: AppState

    private let loc = Loc.shared
    private var providerStore: ProviderStore { appState.providerStore }

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "brain")
                .font(.system(size: 48))
                .foregroundStyle(.blue)

            Text(loc.t("onboarding.provider.title"))
                .font(.title.bold())

            Text(loc.t("onboarding.provider.subtitle"))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            // Current provider status
            if let provider = providerStore.defaultProvider {
                VStack(spacing: 8) {
                    Label {
                        Text(provider.name + " — " + provider.modelID)
                            .font(.callout.weight(.medium))
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }

                    Text(loc.t("onboarding.provider.configured"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
                .frame(maxWidth: 400)
                .background(Color.green.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.green.opacity(0.2))
                )
            } else {
                VStack(spacing: 8) {
                    Label {
                        Text(loc.t("onboarding.provider.not_configured"))
                            .font(.callout.weight(.medium))
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }

                    Text(loc.t("onboarding.provider.not_configured_hint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(16)
                .frame(maxWidth: 400)
                .background(Color.orange.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.orange.opacity(0.2))
                )
            }

            Button {
                appState.openSettingsToProviders()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "gear")
                    Text(loc.t("onboarding.provider.configure"))
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Spacer()
        }
        .padding(32)
    }
}
