import AppKit
import CryptoKit
import Foundation
import Network

/// Handles ChatGPT OAuth 2.0 + PKCE authentication flow.
/// Spins up a local HTTP callback server, opens the browser for sign-in,
/// exchanges the authorization code for tokens, and supports token refresh.
actor ChatGPTAuthService {

    // MARK: - Types

    struct TokenResponse: Sendable {
        let idToken: String
        let accessToken: String
        let refreshToken: String
    }

    struct UserInfo: Codable, Sendable {
        let email: String?
        let planType: String?
        let accountID: String?
        let userID: String?
    }

    enum AuthError: LocalizedError {
        case pkceGenerationFailed
        case serverBindFailed(String)
        case callbackTimeout
        case stateMismatch
        case missingAuthorizationCode
        case oauthError(code: String, description: String?)
        case tokenExchangeFailed(String)
        case tokenRefreshFailed(String)
        case invalidJWT
        case cancelled

        var errorDescription: String? {
            switch self {
            case .pkceGenerationFailed:
                "Failed to generate PKCE codes"
            case .serverBindFailed(let detail):
                "Failed to start callback server: \(detail)"
            case .callbackTimeout:
                "Sign-in timed out. Please try again."
            case .stateMismatch:
                "Security validation failed (state mismatch). Please try again."
            case .missingAuthorizationCode:
                "No authorization code received from ChatGPT."
            case .oauthError(let code, let description):
                "Sign-in error (\(code)): \(description ?? "unknown")"
            case .tokenExchangeFailed(let detail):
                "Token exchange failed: \(detail)"
            case .tokenRefreshFailed(let detail):
                "Token refresh failed: \(detail)"
            case .invalidJWT:
                "Failed to parse authentication token."
            case .cancelled:
                "Sign-in was cancelled."
            }
        }
    }

    // MARK: - PKCE

    private struct PKCECodes {
        let verifier: String
        let challenge: String
    }

    private func generatePKCE() throws -> PKCECodes {
        var bytes = [UInt8](repeating: 0, count: 64)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw AuthError.pkceGenerationFailed }

        let verifier = Data(bytes).base64URLEncodedNoPad()
        let challengeData = Data(SHA256.hash(data: Data(verifier.utf8)))
        let challenge = challengeData.base64URLEncodedNoPad()

        return PKCECodes(verifier: verifier, challenge: challenge)
    }

    private func generateState() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncodedNoPad()
    }

    // MARK: - Authorization URL

    private func buildAuthorizeURL(pkce: PKCECodes, state: String, redirectURI: String) -> URL? {
        var components = URLComponents(string: Constants.ChatGPT.authIssuer + "/oauth/authorize")
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: Constants.ChatGPT.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: Constants.ChatGPT.scopes),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "originator", value: "clipslop"),
        ]
        return components?.url
    }

    // MARK: - Login Flow

    /// Starts the full OAuth login flow: opens browser, waits for callback, exchanges code.
    /// Calls `onAuthURL` with the authorization URL so the UI can display it for manual copy.
    func startLogin(onAuthURL: @Sendable (URL) -> Void = { _ in }) async throws -> TokenResponse {
        let pkce = try generatePKCE()
        let state = generateState()
        let port = Constants.ChatGPT.callbackPort
        let redirectURI = "http://localhost:\(port)/auth/callback"

        guard let authURL = buildAuthorizeURL(pkce: pkce, state: state, redirectURI: redirectURI) else {
            throw AuthError.serverBindFailed("Failed to build authorization URL")
        }

        onAuthURL(authURL)

        // Wait for the OAuth callback via a local HTTP server
        let callbackResult = try await withCallbackServer(port: port, expectedState: state) {
            // Open browser after server is ready
            NSWorkspace.shared.open(authURL)
        }

        // Exchange the authorization code for tokens
        var tokens = try await exchangeCodeForTokens(
            code: callbackResult.code,
            verifier: pkce.verifier,
            redirectURI: redirectURI
        )

        return tokens
    }

    // MARK: - Local Callback Server

    private struct CallbackResult {
        let code: String
    }

    private func withCallbackServer(
        port: UInt16,
        expectedState: String,
        onReady: @escaping @Sendable () -> Void
    ) async throws -> CallbackResult {
        let gate = ContinuationGate<CallbackResult>()

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CallbackResult, Error>) in
            gate.setContinuation(continuation)

            let params = NWParameters.tcp
            let listener: NWListener
            do {
                listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            } catch {
                gate.resume(with: .failure(AuthError.serverBindFailed(error.localizedDescription)))
                return
            }

            let listenerRef = SendableBox(listener)

            // Timeout after 5 minutes
            Task {
                try? await Task.sleep(for: .seconds(300))
                listenerRef.value.cancel()
                gate.resume(with: .failure(AuthError.callbackTimeout))
            }

            listener.newConnectionHandler = { connection in
                connection.start(queue: .global())
                connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                    defer { listenerRef.value.cancel() }

                    guard let data, let request = String(data: data, encoding: .utf8) else {
                        Self.sendHTTPResponse(connection: connection, status: "400 Bad Request", body: "Bad Request")
                        gate.resume(with: .failure(AuthError.missingAuthorizationCode))
                        return
                    }

                    let result = Self.parseCallbackRequest(request: request, expectedState: expectedState)
                    switch result {
                    case .success(let callbackResult):
                        let html = Self.successHTML
                        Self.sendHTTPResponse(connection: connection, status: "200 OK", body: html, contentType: "text/html")
                        gate.resume(with: .success(callbackResult))

                    case .failure(let error):
                        let message = error.errorDescription ?? "Sign-in failed"
                        Self.sendHTTPResponse(connection: connection, status: "400 Bad Request", body: message)
                        gate.resume(with: .failure(error))
                    }
                }
            }

            listener.stateUpdateHandler = { [weak listener] state in
                switch state {
                case .ready:
                    onReady()
                case .failed(let error):
                    listener?.cancel()
                    gate.resume(with: .failure(AuthError.serverBindFailed(error.localizedDescription)))
                default:
                    break
                }
            }

            listener.start(queue: .global())
        }
    }

    /// Thread-safe wrapper to resume a continuation exactly once.
    private final class ContinuationGate<T: Sendable>: @unchecked Sendable {
        private var continuation: CheckedContinuation<T, Error>?
        private let lock = NSLock()

        func setContinuation(_ c: CheckedContinuation<T, Error>) {
            lock.withLock { continuation = c }
        }

        func resume(with result: Result<T, Error>) {
            lock.withLock {
                guard let c = continuation else { return }
                continuation = nil
                c.resume(with: result)
            }
        }
    }

    /// Sendable box for NWListener reference.
    private final class SendableBox<T: AnyObject>: @unchecked Sendable {
        let value: T
        init(_ value: T) { self.value = value }
    }

    private static func parseCallbackRequest(request: String, expectedState: String) -> Result<CallbackResult, AuthError> {
        // Extract URL from first line: "GET /path?query HTTP/1.1"
        guard let firstLine = request.split(separator: "\r\n").first,
              let urlPart = firstLine.split(separator: " ").dropFirst().first,
              let components = URLComponents(string: "http://localhost" + String(urlPart))
        else {
            return .failure(.missingAuthorizationCode)
        }

        let params = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
                item.value.map { (item.name, $0) }
            }
        )

        // Check for OAuth error
        if let errorCode = params["error"] {
            return .failure(.oauthError(code: errorCode, description: params["error_description"]))
        }

        // Validate state
        guard params["state"] == expectedState else {
            return .failure(.stateMismatch)
        }

        // Extract code
        guard let code = params["code"], !code.isEmpty else {
            return .failure(.missingAuthorizationCode)
        }

        return .success(CallbackResult(code: code))
    }

    private static func sendHTTPResponse(
        connection: NWConnection,
        status: String,
        body: String,
        contentType: String = "text/plain"
    ) {
        let response = """
        HTTP/1.1 \(status)\r
        Content-Type: \(contentType); charset=utf-8\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """
        let data = Data(response.utf8)
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static let successHTML = """
    <!DOCTYPE html>
    <html>
    <head><title>ClipSlop - Sign In Successful</title>
    <style>
    body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; display: flex;
           justify-content: center; align-items: center; height: 100vh; margin: 0;
           background: #f5f5f7; color: #1d1d1f; }
    .container { text-align: center; padding: 40px; }
    h1 { font-size: 24px; margin-bottom: 8px; }
    p { font-size: 16px; color: #6e6e73; }
    </style></head>
    <body><div class="container">
    <h1>&#10003; Signed in successfully</h1>
    <p>You can close this tab and return to ClipSlop.</p>
    </div></body></html>
    """

    // MARK: - Token Exchange

    private func exchangeCodeForTokens(code: String, verifier: String, redirectURI: String) async throws -> TokenResponse {
        guard let url = URL(string: Constants.ChatGPT.tokenEndpoint) else {
            throw AuthError.tokenExchangeFailed("Invalid token endpoint URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let bodyParts = [
            "grant_type=authorization_code",
            "code=\(urlEncode(code))",
            "redirect_uri=\(urlEncode(redirectURI))",
            "client_id=\(urlEncode(Constants.ChatGPT.clientID))",
            "code_verifier=\(urlEncode(verifier))",
        ]
        request.httpBody = bodyParts.joined(separator: "&").data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.tokenExchangeFailed("Invalid response")
        }
        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AuthError.tokenExchangeFailed("HTTP \(httpResponse.statusCode): \(body)")
        }

        struct TokenJSON: Decodable {
            let id_token: String
            let access_token: String
            let refresh_token: String
        }

        let tokens = try JSONDecoder().decode(TokenJSON.self, from: data)
        return TokenResponse(
            idToken: tokens.id_token,
            accessToken: tokens.access_token,
            refreshToken: tokens.refresh_token
        )
    }
    // MARK: - Token Refresh

    func refreshAccessToken(refreshToken: String) async throws -> TokenResponse {
        guard let url = URL(string: Constants.ChatGPT.tokenEndpoint) else {
            throw AuthError.tokenRefreshFailed("Invalid token endpoint URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        struct RefreshBody: Encodable {
            let client_id: String
            let grant_type: String
            let refresh_token: String
        }

        request.httpBody = try JSONEncoder().encode(RefreshBody(
            client_id: Constants.ChatGPT.clientID,
            grant_type: "refresh_token",
            refresh_token: refreshToken
        ))

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.tokenRefreshFailed("Invalid response")
        }
        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AuthError.tokenRefreshFailed("HTTP \(httpResponse.statusCode): \(body)")
        }

        struct RefreshJSON: Decodable {
            let id_token: String
            let access_token: String
            let refresh_token: String
        }

        let tokens = try JSONDecoder().decode(RefreshJSON.self, from: data)
        return TokenResponse(
            idToken: tokens.id_token,
            accessToken: tokens.access_token,
            refreshToken: tokens.refresh_token
        )
    }

    // MARK: - JWT Parsing

    /// Parses user info from the id_token JWT without signature verification (same as Codex).
    static func parseJWTClaims(idToken: String) -> UserInfo {
        guard let payload = decodeJWTPayload(idToken) else {
            return UserInfo(email: nil, planType: nil, accountID: nil, userID: nil)
        }

        // Top-level email
        let email = payload["email"] as? String
            ?? (payload["https://api.openai.com/profile"] as? [String: Any])?["email"] as? String

        // Auth claims
        let auth = payload["https://api.openai.com/auth"] as? [String: Any]
        let planType = auth?["chatgpt_plan_type"] as? String
        let userID = (auth?["chatgpt_user_id"] as? String) ?? (auth?["user_id"] as? String)
        let accountID = auth?["chatgpt_account_id"] as? String

        return UserInfo(email: email, planType: planType, accountID: accountID, userID: userID)
    }

    /// Parses the `exp` claim from a JWT to determine expiration.
    static func parseJWTExpiration(jwt: String) -> Date? {
        guard let payload = decodeJWTPayload(jwt),
              let exp = payload["exp"] as? TimeInterval
        else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    private static func decodeJWTPayload(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { return nil }

        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Pad to multiple of 4
        while base64.count % 4 != 0 { base64.append("=") }

        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }

    // MARK: - Helpers

    private func urlEncode(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? string
    }
}

// MARK: - Base64URL

extension Data {
    func base64URLEncodedNoPad() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
