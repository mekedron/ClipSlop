import AppKit
import SwiftUI

enum AppColorScheme: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    var streamingEnabled: Bool {
        didSet { UserDefaults.standard.set(streamingEnabled, forKey: "streamingEnabled") }
    }

    var showInDock: Bool {
        didSet { UserDefaults.standard.set(showInDock, forKey: "showInDock") }
    }

    var hasCompletedOnboarding: Bool {
        didSet { UserDefaults.standard.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding") }
    }

    var selectedProviderID: String {
        didSet { UserDefaults.standard.set(selectedProviderID, forKey: "selectedProviderID") }
    }

    var popupOpacity: Double {
        didSet { UserDefaults.standard.set(popupOpacity, forKey: "popupOpacity") }
    }

    var popupWidth: Double {
        didSet { UserDefaults.standard.set(popupWidth, forKey: "popupWidth") }
    }

    var popupHeight: Double {
        didSet { UserDefaults.standard.set(popupHeight, forKey: "popupHeight") }
    }

    var hideMenuBarIcon: Bool {
        didSet { UserDefaults.standard.set(hideMenuBarIcon, forKey: "hideMenuBarIcon") }
    }

    var hideDockIcon: Bool {
        didSet { UserDefaults.standard.set(hideDockIcon, forKey: "hideDockIcon") }
    }

    var iCloudSyncEnabled: Bool {
        didSet { UserDefaults.standard.set(iCloudSyncEnabled, forKey: "iCloudSyncEnabled") }
    }

    var useKeyCodes: Bool {
        didSet { UserDefaults.standard.set(useKeyCodes, forKey: "useKeyCodes") }
    }

    var appColorScheme: AppColorScheme {
        didSet { UserDefaults.standard.set(appColorScheme.rawValue, forKey: "appColorScheme") }
    }

    private init() {
        // Load from UserDefaults (didSet does NOT fire during init)
        let defaults = UserDefaults.standard
        streamingEnabled = defaults.object(forKey: "streamingEnabled") as? Bool ?? true
        showInDock = defaults.bool(forKey: "showInDock")
        hasCompletedOnboarding = defaults.bool(forKey: "hasCompletedOnboarding")
        selectedProviderID = defaults.string(forKey: "selectedProviderID") ?? ""
        popupOpacity = defaults.object(forKey: "popupOpacity") as? Double ?? 0.85
        popupWidth = defaults.object(forKey: "popupWidth") as? Double ?? 850
        popupHeight = defaults.object(forKey: "popupHeight") as? Double ?? 520
        hideMenuBarIcon = defaults.bool(forKey: "hideMenuBarIcon")
        hideDockIcon = defaults.object(forKey: "hideDockIcon") as? Bool ?? true
        iCloudSyncEnabled = defaults.bool(forKey: "iCloudSyncEnabled")
        useKeyCodes = defaults.bool(forKey: "useKeyCodes")
        appColorScheme = defaults.string(forKey: "appColorScheme")
            .flatMap(AppColorScheme.init(rawValue:)) ?? .system
    }
}

