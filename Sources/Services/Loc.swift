import Foundation

@MainActor
@Observable
final class Loc {
    static let shared = Loc()

    var language: AppLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: "appLanguage")
            reloadBundle()
        }
    }

    @ObservationIgnored private var currentBundle: Bundle

    private init() {
        let saved = UserDefaults.standard.string(forKey: "appLanguage")
        let lang = saved.flatMap(AppLanguage.init(rawValue:)) ?? AppLanguage.systemDefault
        self.language = lang

        if let path = Bundle.module.path(forResource: lang.rawValue, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            self.currentBundle = bundle
        } else {
            self.currentBundle = Bundle.module
        }
    }

    func t(_ key: String) -> String {
        // Access `language` to register observation tracking so SwiftUI re-renders on change
        let _ = language
        return currentBundle.localizedString(forKey: key, value: key, table: nil)
    }

    func t(_ key: String, _ args: CVarArg...) -> String {
        let template = t(key)
        return String(format: template, arguments: args)
    }

    private func reloadBundle() {
        if let path = Bundle.module.path(forResource: language.rawValue, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            currentBundle = bundle
        } else {
            currentBundle = Bundle.module
        }
    }
}
