import AppIntents
import Foundation

/// Errors surfaced to Spotlight, Shortcuts and Siri.
///
/// Every message is one line and ends with something the user can act on — these
/// render as a single failure row with no room to explain themselves.
enum ClipSlopIntentError: Swift.Error, CustomLocalizedStringResourceConvertible {
    case appNotReady
    case promptNotFound
    case noInputText
    case noProviderConfigured
    case providerNeedsSignIn
    case failed(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .appNotReady:
            "ClipSlop is still starting up. Try again in a moment."
        case .promptNotFound:
            "That prompt is no longer in your ClipSlop library."
        case .noInputText:
            "There's no text to work with. Copy something first, or pass text into this action."
        case .noProviderConfigured:
            "No AI provider is set up. Open ClipSlop Settings to add one."
        case .providerNeedsSignIn:
            "Your AI provider needs you to sign in again. Open ClipSlop Settings."
        case .failed(let message):
            "\(message)"
        }
    }

    /// Maps a thrown error onto a user-facing case.
    ///
    /// The truncation is load-bearing, not cosmetic: `AIServiceError.httpError`
    /// interpolates the provider's **raw response body** into its description for
    /// any status it doesn't special-case, so an unbounded message would dump a
    /// wall of provider JSON into a Spotlight error banner.
    nonisolated static func wrap(_ error: Error, detailLimit: Int = 200) -> ClipSlopIntentError {
        guard let aiError = error as? AIServiceError else {
            return .failed(String(error.localizedDescription.prefix(detailLimit)))
        }
        switch aiError {
        case .missingAPIKey, .oauthLoginRequired, .oauthTokenExpired:
            return .providerNeedsSignIn
        case .httpError(let statusCode, _) where statusCode == 401:
            return .providerNeedsSignIn
        default:
            let description = aiError.errorDescription ?? "The AI request failed."
            return .failed(String(description.prefix(detailLimit)))
        }
    }
}

/// Formats a result for the spoken/short dialog Spotlight shows alongside the value.
enum IntentDialogFormatter {
    nonisolated static func summarize(_ text: String, limit: Int = 400) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)) + "…"
    }
}
