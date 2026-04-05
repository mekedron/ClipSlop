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

enum EditorMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case plainText
    case html
    case markdown

    var id: String { rawValue }
}

enum RichTextMode: String, CaseIterable, Identifiable, Sendable {
    case plainText
    case html
    case markdown
    case markdownAI

    var id: String { rawValue }
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

    var showImagesInMarkdown: Bool {
        didSet { UserDefaults.standard.set(showImagesInMarkdown, forKey: "showImagesInMarkdown") }
    }

    var keepOpenOnEscape: Bool {
        didSet { UserDefaults.standard.set(keepOpenOnEscape, forKey: "keepOpenOnEscape") }
    }

    var appColorScheme: AppColorScheme {
        didSet { UserDefaults.standard.set(appColorScheme.rawValue, forKey: "appColorScheme") }
    }

    var editorMode: EditorMode {
        didSet { UserDefaults.standard.set(editorMode.rawValue, forKey: "editorMode") }
    }

    var richTextMode: RichTextMode {
        didSet { UserDefaults.standard.set(richTextMode.rawValue, forKey: "richTextMode") }
    }

    var markdownAIOnlyRichText: Bool {
        didSet { UserDefaults.standard.set(markdownAIOnlyRichText, forKey: "markdownAIOnlyRichText") }
    }

    var useCustomConversionPrompt: Bool {
        didSet { UserDefaults.standard.set(useCustomConversionPrompt, forKey: "useCustomConversionPrompt") }
    }

    var customConversionPrompt: String {
        didSet { UserDefaults.standard.set(customConversionPrompt, forKey: "customConversionPrompt") }
    }

    static let defaultConversionPrompt = """
    Convert the following HTML to clean, well-structured Markdown. \
    Extract only meaningful content. Skip all presentational HTML \
    (layout tables, spacers, style attributes, tracking pixels). \
    Preserve headings, links, images with alt text, lists, and text formatting (bold, italic). \
    For data that looks tabular, use Markdown tables. \
    Output ONLY the Markdown, no explanations or commentary.
    """

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
        showImagesInMarkdown = defaults.object(forKey: "showImagesInMarkdown") as? Bool ?? true
        keepOpenOnEscape = defaults.bool(forKey: "keepOpenOnEscape")
        appColorScheme = defaults.string(forKey: "appColorScheme")
            .flatMap(AppColorScheme.init(rawValue:)) ?? .system
        editorMode = defaults.string(forKey: "editorMode")
            .flatMap(EditorMode.init(rawValue:)) ?? .markdown
        richTextMode = defaults.string(forKey: "richTextMode")
            .flatMap(RichTextMode.init(rawValue:)) ?? .markdown
        markdownAIOnlyRichText = defaults.object(forKey: "markdownAIOnlyRichText") as? Bool ?? true
        useCustomConversionPrompt = defaults.bool(forKey: "useCustomConversionPrompt")
        customConversionPrompt = defaults.string(forKey: "customConversionPrompt") ?? AppSettings.defaultConversionPrompt
    }
}

