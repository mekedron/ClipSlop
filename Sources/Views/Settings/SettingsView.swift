import SwiftUI

struct SettingsView: View {
    let appState: AppState

    var body: some View {
        TabView {
            GeneralSettingsView(appState: appState)
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            ProvidersSettingsView(appState: appState)
                .tabItem {
                    Label("Providers", systemImage: "brain")
                }

            PromptsSettingsView(appState: appState)
                .tabItem {
                    Label("Prompts", systemImage: "text.bubble")
                }

            SamplesView(appState: appState)
                .tabItem {
                    Label("Samples", systemImage: "doc.text.magnifyingglass")
                }
        }
        .frame(width: 600, height: 450)
    }
}
