import Foundation

enum Constants {
    static let appName = "ClipSlop"

    /// Keychain service name. Deliberately the *release* identifier even in dev
    /// builds, so a locally-bundled ClipSlop can reuse the API keys already
    /// stored on this machine instead of demanding they be re-entered.
    static let bundleIdentifier = "com.mekedron.clipslop"

    /// True when running from the locally-built dev bundle (see Scripts/make-app-bundle.sh),
    /// which ships as `com.mekedron.clipslop.dev` so it gets its own LaunchServices
    /// registration and TCC identity instead of colliding with an installed release.
    static let isDevBuild: Bool = Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true

    /// Data directory, scoped by build flavour.
    ///
    /// A dev bundle has a different bundle identifier, therefore a *different and
    /// empty* UserDefaults domain — which means `useDefaultPrompts` reads back as
    /// its `true` default and `PromptStore.init` immediately does
    /// `saveToDisk(loadDefaults())`. If dev and release shared this directory that
    /// would overwrite the real prompt library with the bundled defaults on first
    /// launch, and iCloud would then propagate the loss to every other Mac.
    static let appSupportDirectory: URL = {
        let folder = isDevBuild ? "ClipSlop-dev" : "ClipSlop"
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(folder)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static let promptsFileURL: URL = appSupportDirectory.appendingPathComponent("prompts.json")
    static let providersFileURL: URL = appSupportDirectory.appendingPathComponent("providers.json")
    static let quickAccessFileURL: URL = appSupportDirectory.appendingPathComponent("quick-access.json")

    enum Anthropic {
        static let baseURL = "https://api.anthropic.com"
        static let apiVersion = "2023-06-01"
        static let defaultModel = "claude-sonnet-4"
    }

    enum OpenAI {
        static let baseURL = "https://api.openai.com"
        static let defaultModel = "gpt-4o"
    }

    enum Ollama {
        static let baseURL = "http://localhost:11434"
        static let defaultModel = "llama3.2"
    }

    enum ChatGPT {
        static let authIssuer = "https://auth.openai.com"
        static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
        static let callbackPort: UInt16 = 1455
        static let redirectURI = "http://localhost:1455/auth/callback"
        static let tokenEndpoint = "https://auth.openai.com/oauth/token"
        static let scopes = "openid profile email offline_access api.connectors.read api.connectors.invoke"
        static let baseURL = "https://chatgpt.com/backend-api/codex"
        static let defaultModel = "gpt-5.4-mini"
    }

    enum Defaults {
        static let maxTokens = 4096
        static let temperature = 1.0
        static let streamingEnabled = true
    }
}
