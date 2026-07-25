import SwiftUI

struct SettingsView: View {
    let appState: AppState

    private let loc = Loc.shared

    private let tabIcons = ["gear", "brain", "text.bubble", "square.grid.3x3.fill", "wand.and.stars", "info.circle"]

    var body: some View {
        let tabNames = [
            loc.t("settings.tab.general"),
            loc.t("settings.tab.providers"),
            loc.t("settings.tab.prompts"),
            loc.t("settings.tab.quick_access"),
            loc.t("settings.tab.magic"),
            loc.t("settings.tab.about"),
        ]

        VStack(spacing: 0) {
            // Tab bar
            HStack(spacing: 2) {
                ForEach(Array(tabNames.enumerated()), id: \.offset) { index, name in
                    Button {
                        appState.settingsSelectedTab = index
                    } label: {
                        VStack(spacing: 5) {
                            Image(systemName: tabIcons[index])
                                .symbolRenderingMode(.hierarchical)
                                .font(.system(size: 18, weight: .medium))
                            Text(name)
                                .font(.caption2).fontWeight(.medium)
                        }
                        .foregroundStyle(appState.settingsSelectedTab == index ? .primary : .tertiary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .overlay(alignment: .bottom) {
                        if appState.settingsSelectedTab == index {
                            Capsule()
                                .fill(Color.accentColor)
                                .frame(width: 24, height: 3)
                                .offset(y: 1)
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)

            Divider()

            // Tab content
            Group {
                switch appState.settingsSelectedTab {
                case 0: GeneralSettingsView(appState: appState)
                case 1: ProvidersSettingsView(appState: appState)
                case 2: PromptsSettingsView(appState: appState)
                case 3: QuickAccessSettingsView(appState: appState)
                case 4: MagicSettingsView(appState: appState)
                case 5: AboutView()
                default: EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
