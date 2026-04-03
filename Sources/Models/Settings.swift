import Foundation

@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    var streamingEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "streamingEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "streamingEnabled") }
    }

    var showInDock: Bool {
        get { UserDefaults.standard.bool(forKey: "showInDock") }
        set { UserDefaults.standard.set(newValue, forKey: "showInDock") }
    }

    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    var selectedProviderID: String {
        get { UserDefaults.standard.string(forKey: "selectedProviderID") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "selectedProviderID") }
    }

    var popupOpacity: Double {
        get { UserDefaults.standard.object(forKey: "popupOpacity") as? Double ?? 0.85 }
        set { UserDefaults.standard.set(newValue, forKey: "popupOpacity") }
    }

    private init() {}
}
