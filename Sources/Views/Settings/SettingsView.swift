import SwiftUI

struct SettingsView: View {
    let appState: AppState
    @State private var selectedTab = 0

    private let tabs: [(String, String)] = [
        ("General", "gear"),
        ("Providers", "brain"),
        ("Prompts", "text.bubble"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar
            HStack(spacing: 2) {
                ForEach(Array(tabs.enumerated()), id: \.offset) { index, tab in
                    Button {
                        selectedTab = index
                    } label: {
                        VStack(spacing: 5) {
                            Image(systemName: tab.1)
                                .symbolRenderingMode(.hierarchical)
                                .font(.system(size: 18, weight: .medium))
                            Text(tab.0)
                                .font(.caption2).fontWeight(.medium)
                        }
                        .foregroundStyle(selectedTab == index ? .primary : .tertiary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .overlay(alignment: .bottom) {
                        if selectedTab == index {
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
                switch selectedTab {
                case 0: GeneralSettingsView(appState: appState)
                case 1: ProvidersSettingsView(appState: appState)
                case 2: PromptsSettingsView(appState: appState)
                default: EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
