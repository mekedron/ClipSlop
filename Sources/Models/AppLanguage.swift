import Foundation

enum AppLanguage: String, CaseIterable, Identifiable, Codable, Sendable {
    case en, de, ru, pl, cs, fr, es, fi, sv, nb
    case it, pt, nl, uk, ro, hu, da

    var id: String { rawValue }

    var nativeName: String {
        switch self {
        case .en: "English"
        case .de: "Deutsch"
        case .ru: "Русский"
        case .pl: "Polski"
        case .cs: "Čeština"
        case .fr: "Français"
        case .es: "Español"
        case .fi: "Suomi"
        case .sv: "Svenska"
        case .nb: "Norsk"
        case .it: "Italiano"
        case .pt: "Português"
        case .nl: "Nederlands"
        case .uk: "Українська"
        case .ro: "Română"
        case .hu: "Magyar"
        case .da: "Dansk"
        }
    }

    var flag: String {
        switch self {
        case .en: "🇬🇧"
        case .de: "🇩🇪"
        case .ru: "🇷🇺"
        case .pl: "🇵🇱"
        case .cs: "🇨🇿"
        case .fr: "🇫🇷"
        case .es: "🇪🇸"
        case .fi: "🇫🇮"
        case .sv: "🇸🇪"
        case .nb: "🇳🇴"
        case .it: "🇮🇹"
        case .pt: "🇵🇹"
        case .nl: "🇳🇱"
        case .uk: "🇺🇦"
        case .ro: "🇷🇴"
        case .hu: "🇭🇺"
        case .da: "🇩🇰"
        }
    }

    static var systemDefault: AppLanguage {
        let preferred = Locale.preferredLanguages.first ?? "en"
        let code = String(preferred.prefix(2))
        // Norwegian: system may report "no" but we use "nb" (Bokmal)
        if code == "no" || code == "nb" || code == "nn" { return .nb }
        return AppLanguage(rawValue: code) ?? .en
    }
}
