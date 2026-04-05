import Foundation

/// Persists ChatGPT OAuth tokens in Keychain and handles automatic refresh.
@MainActor
@Observable
final class ChatGPTTokenManager {

    // MARK: - Stored Token Model

    struct ChatGPTTokens: Codable, Sendable {
        var accessToken: String
        var refreshToken: String
        var idToken: String
        var accountID: String?
        var email: String?
        var planType: String?
    }

    static let shared = ChatGPTTokenManager()

    // MARK: - State

    /// In-memory cache of tokens per provider UUID, loaded lazily from Keychain.
    @ObservationIgnored
    private var cache: [UUID: ChatGPTTokens] = [:]

    /// Prevents concurrent refresh operations for the same provider.
    @ObservationIgnored
    private var refreshInFlight: [UUID: Task<ChatGPTTokens, Error>] = [:]

    private let authService = ChatGPTAuthService()

    // MARK: - Public API

    func isAuthenticated(for providerID: UUID) -> Bool {
        loadTokens(for: providerID) != nil
    }

    func getUserInfo(for providerID: UUID) -> (email: String?, planType: String?) {
        guard let tokens = loadTokens(for: providerID) else {
            return (nil, nil)
        }
        return (tokens.email, tokens.planType)
    }

    /// Returns a valid API key (or access token fallback) for making OpenAI API calls.
    func getValidAccessToken(for providerID: UUID) async throws -> (accessToken: String, accountID: String?) {
        guard var tokens = loadTokens(for: providerID) else {
            throw AIServiceError.oauthLoginRequired
        }

        // Check if access token is expired or about to expire (within 5 minutes)
        if let expiration = ChatGPTAuthService.parseJWTExpiration(jwt: tokens.accessToken),
           expiration.timeIntervalSinceNow < 300 {
            tokens = try await refreshTokens(for: providerID, currentTokens: tokens)
        }

        return (tokens.accessToken, tokens.accountID)
    }

    /// Saves tokens after a successful login.
    func saveTokens(_ response: ChatGPTAuthService.TokenResponse, for providerID: UUID) {
        let userInfo = ChatGPTAuthService.parseJWTClaims(idToken: response.idToken)
        let tokens = ChatGPTTokens(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken,
            idToken: response.idToken,
            accountID: userInfo.accountID,
            email: userInfo.email,
            planType: userInfo.planType
        )
        cache[providerID] = tokens
        persistToKeychain(tokens, for: providerID)
    }

    /// Clears all tokens for a provider (sign out).
    func clearTokens(for providerID: UUID) {
        cache.removeValue(forKey: providerID)
        refreshInFlight[providerID]?.cancel()
        refreshInFlight.removeValue(forKey: providerID)
        KeychainService.delete(key: keychainKey(for: providerID))
    }

    // MARK: - Token Refresh

    private func refreshTokens(for providerID: UUID, currentTokens: ChatGPTTokens) async throws -> ChatGPTTokens {
        // Coalesce concurrent refresh requests
        if let existing = refreshInFlight[providerID] {
            return try await existing.value
        }

        let refreshTask = Task<ChatGPTTokens, Error> { [authService, currentTokens] in
            let response = try await authService.refreshAccessToken(refreshToken: currentTokens.refreshToken)
            let userInfo = ChatGPTAuthService.parseJWTClaims(idToken: response.idToken)
            return ChatGPTTokens(
                accessToken: response.accessToken,
                refreshToken: response.refreshToken,
                idToken: response.idToken,
                    accountID: userInfo.accountID,
                email: userInfo.email,
                planType: userInfo.planType
            )
        }

        refreshInFlight[providerID] = refreshTask

        do {
            let newTokens = try await refreshTask.value
            refreshInFlight.removeValue(forKey: providerID)
            cache[providerID] = newTokens
            persistToKeychain(newTokens, for: providerID)
            return newTokens
        } catch {
            refreshInFlight.removeValue(forKey: providerID)
            // If refresh permanently failed, clear cached tokens
            if isRefreshPermanentFailure(error) {
                clearTokens(for: providerID)
            }
            throw AIServiceError.oauthTokenExpired
        }
    }

    private func isRefreshPermanentFailure(_ error: Error) -> Bool {
        guard let authError = error as? ChatGPTAuthService.AuthError,
              case .tokenRefreshFailed(let detail) = authError
        else { return false }
        // HTTP 401 = permanent (expired/revoked/reused refresh token)
        return detail.contains("HTTP 401")
    }

    // MARK: - Keychain Persistence

    private func keychainKey(for providerID: UUID) -> String {
        "clipslop.chatgpt.tokens.\(providerID.uuidString)"
    }

    private func loadTokens(for providerID: UUID) -> ChatGPTTokens? {
        if let cached = cache[providerID] {
            return cached
        }
        guard let json = KeychainService.load(key: keychainKey(for: providerID)),
              let data = json.data(using: .utf8),
              let tokens = try? JSONDecoder().decode(ChatGPTTokens.self, from: data)
        else { return nil }
        cache[providerID] = tokens
        return tokens
    }

    private func persistToKeychain(_ tokens: ChatGPTTokens, for providerID: UUID) {
        guard let data = try? JSONEncoder().encode(tokens),
              let json = String(data: data, encoding: .utf8)
        else { return }
        try? KeychainService.save(key: keychainKey(for: providerID), value: json)
    }
}
