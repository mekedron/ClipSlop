import AppKit
import SwiftUI

enum MarkdownRenderer: String, CaseIterable, Identifiable, Sendable {
    case textual
    case htmlEditor

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .textual: "Textual"
        case .htmlEditor: "HTML Editor"
        }
    }
}

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

    /// Display format written by builds that shipped "Markdown (Styled)" as a
    /// fourth workspace mode. It is now plain `.markdown` plus a renderer
    /// choice — see `MarkdownViewerStyle` / `MarkdownEditorStyle`.
    static let legacyStyledRawValue = "markdownStyled"

    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        // Prompts and history steps saved before the split still carry
        // "markdownStyled". Fold unknown values into `.markdown` rather than
        // throwing — a single stale prompt must not fail the whole library
        // decode. `encode(to:)` stays synthesised, so we write the new value.
        self = EditorMode(rawValue: raw) ?? .markdown
    }
}

/// How read-only Markdown is rendered when the workspace display format is
/// `.markdown`. Orthogonal to `EditorMode` so viewing and editing can differ.
enum MarkdownViewerStyle: String, CaseIterable, Identifiable, Sendable {
    /// Raw Markdown source coloured in place by `MarkdownSourceHighlighter`
    /// (⌘-click opens links) — the read-only twin of `MarkdownEditorStyle.colored`.
    case colored
    /// Live-styled source via swift-markdown-engine, in read-only mode.
    case styled
    /// Fully rendered Markdown via `MarkdownPreviewView` — Textual or the HTML
    /// editor, per `markdownRenderer`. ClipSlop's original viewer.
    case rendered

    var id: String { rawValue }
}

/// How Markdown source is presented while editing, when the workspace display
/// format is `.markdown`.
enum MarkdownEditorStyle: String, CaseIterable, Identifiable, Sendable {
    /// Unstyled monospaced source.
    case plain
    /// Source with inline colour/weight from `MarkdownSourceHighlighter`.
    case colored
    /// swift-markdown-engine's live-styled editor.
    case styled

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

    var markdownRenderer: MarkdownRenderer {
        didSet { UserDefaults.standard.set(markdownRenderer.rawValue, forKey: "markdownRenderer") }
    }

    /// Renderer used for read-only Markdown. Applies whenever the display
    /// format is Markdown, so the workspace picker stays a single "Markdown".
    var markdownViewer: MarkdownViewerStyle {
        didSet { UserDefaults.standard.set(markdownViewer.rawValue, forKey: "markdownViewer") }
    }

    /// Renderer used while editing Markdown — chosen independently of
    /// `markdownViewer`, so e.g. rendered viewing + plain editing is valid.
    var markdownEditor: MarkdownEditorStyle {
        didSet { UserDefaults.standard.set(markdownEditor.rawValue, forKey: "markdownEditor") }
    }

    var preserveImageWidths: Bool {
        didSet { UserDefaults.standard.set(preserveImageWidths, forKey: "preserveImageWidths") }
    }

    var closeOnEscape: Bool {
        didSet { UserDefaults.standard.set(closeOnEscape, forKey: "closeOnEscape") }
    }

    var closeOnCopy: Bool {
        didSet { UserDefaults.standard.set(closeOnCopy, forKey: "closeOnCopy") }
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

    var suppressPermissionAlert: Bool {
        didSet { UserDefaults.standard.set(suppressPermissionAlert, forKey: "suppressPermissionAlert") }
    }

    var useDefaultPrompts: Bool {
        didSet { UserDefaults.standard.set(useDefaultPrompts, forKey: "useDefaultPrompts") }
    }

    var useDefaultQuickAccess: Bool {
        didSet { UserDefaults.standard.set(useDefaultQuickAccess, forKey: "useDefaultQuickAccess") }
    }

    /// Collapses the prompt navigator in the popup to just the breadcrumb
    /// row — for users who drive prompts by mnemonics and want the space back.
    var promptLibraryCollapsed: Bool {
        didSet { UserDefaults.standard.set(promptLibraryCollapsed, forKey: "promptLibraryCollapsed") }
    }

    /// System prompt template for the ⌘K one-off instruction bar. The typed
    /// instruction replaces `{instruction}`, or is appended when the
    /// placeholder is absent — see `AdHocPromptComposer`.
    var adHocSystemPrompt: String {
        didSet { UserDefaults.standard.set(adHocSystemPrompt, forKey: "adHocSystemPrompt") }
    }

    static let defaultAdHocSystemPrompt = """
    You are a text transformation assistant inside a clipboard utility. \
    Apply the user's instruction to the text they provide. \
    Output ONLY the resulting text — no explanations, no preamble, no code fences. \
    Preserve the original language of the text unless the instruction says otherwise.

    Instruction:
    {instruction}
    """

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
        popupWidth = defaults.object(forKey: "popupWidth") as? Double ?? 950
        popupHeight = defaults.object(forKey: "popupHeight") as? Double ?? 520
        hideMenuBarIcon = defaults.bool(forKey: "hideMenuBarIcon")
        hideDockIcon = defaults.object(forKey: "hideDockIcon") as? Bool ?? true
        iCloudSyncEnabled = defaults.bool(forKey: "iCloudSyncEnabled")
        useKeyCodes = defaults.bool(forKey: "useKeyCodes")
        showImagesInMarkdown = defaults.object(forKey: "showImagesInMarkdown") as? Bool ?? true
        markdownRenderer = defaults.string(forKey: "markdownRenderer")
            .flatMap(MarkdownRenderer.init(rawValue:)) ?? .textual
        preserveImageWidths = defaults.object(forKey: "preserveImageWidths") as? Bool ?? true
        closeOnEscape = defaults.object(forKey: "closeOnEscape") as? Bool ?? true
        closeOnCopy = defaults.object(forKey: "closeOnCopy") as? Bool ?? true
        appColorScheme = defaults.string(forKey: "appColorScheme")
            .flatMap(AppColorScheme.init(rawValue:)) ?? .system
        // "Markdown (Styled)" used to be a fourth display format. It is now
        // plain Markdown plus a renderer choice, so someone who had it
        // selected keeps the styled renderer instead of silently losing it.
        let storedEditorMode = defaults.string(forKey: "editorMode")
        let hadStyledDisplayFormat = storedEditorMode == EditorMode.legacyStyledRawValue
        editorMode = storedEditorMode.flatMap(EditorMode.init(rawValue:)) ?? .markdown
        markdownViewer = defaults.string(forKey: "markdownViewer")
            .flatMap(MarkdownViewerStyle.init(rawValue:))
            ?? (hadStyledDisplayFormat ? .styled : .rendered)
        markdownEditor = defaults.string(forKey: "markdownEditor")
            .flatMap(MarkdownEditorStyle.init(rawValue:))
            ?? (hadStyledDisplayFormat ? .styled : .colored)
        richTextMode = defaults.string(forKey: "richTextMode")
            .flatMap(RichTextMode.init(rawValue:)) ?? .markdown
        markdownAIOnlyRichText = defaults.object(forKey: "markdownAIOnlyRichText") as? Bool ?? true
        useCustomConversionPrompt = defaults.bool(forKey: "useCustomConversionPrompt")
        customConversionPrompt = defaults.string(forKey: "customConversionPrompt") ?? AppSettings.defaultConversionPrompt
        suppressPermissionAlert = defaults.bool(forKey: "suppressPermissionAlert")
        useDefaultPrompts = defaults.object(forKey: "useDefaultPrompts") as? Bool ?? true
        useDefaultQuickAccess = defaults.object(forKey: "useDefaultQuickAccess") as? Bool ?? true
        promptLibraryCollapsed = defaults.bool(forKey: "promptLibraryCollapsed")
        adHocSystemPrompt = defaults.string(forKey: "adHocSystemPrompt") ?? AppSettings.defaultAdHocSystemPrompt
        // Quick Access tile state lives in `QuickAccessStore` (disk-backed,
        // iCloud-synced, exportable). It used to live here in UserDefaults
        // and the store performs a one-shot migration on first launch.

        // `didSet` does not fire during init, so write the retired display
        // format back by hand. Rewriting "editorMode" makes this one-shot.
        if hadStyledDisplayFormat {
            defaults.set(editorMode.rawValue, forKey: "editorMode")
            defaults.set(markdownViewer.rawValue, forKey: "markdownViewer")
            defaults.set(markdownEditor.rawValue, forKey: "markdownEditor")
        }
    }
}

