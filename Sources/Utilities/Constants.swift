import Foundation

enum Constants {
    static let appName = "ClipSlop"
    static let bundleIdentifier = "com.clipslop.app"

    static let appSupportDirectory: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClipSlop")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static let promptsFileURL: URL = appSupportDirectory.appendingPathComponent("prompts.json")
    static let providersFileURL: URL = appSupportDirectory.appendingPathComponent("providers.json")

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
