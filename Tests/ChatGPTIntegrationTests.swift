import Foundation
import Testing
@testable import ClipSlop

/// Integration tests for the ChatGPT OAuth provider.
///
/// These tests require real ChatGPT tokens provided via environment variables:
///   CHATGPT_ACCESS_TOKEN - OAuth access token
///   CHATGPT_ACCOUNT_ID   - ChatGPT account/workspace ID (optional)
///
/// Run: ./Scripts/extract-chatgpt-token.sh --run-tests
/// Or:  eval $(./Scripts/extract-chatgpt-token.sh) && swift test --filter ChatGPT

// MARK: - Test Helpers

private func skipUnlessTokenAvailable() throws -> (accessToken: String, accountID: String?) {
    guard let token = ProcessInfo.processInfo.environment["CHATGPT_ACCESS_TOKEN"], !token.isEmpty else {
        throw SkipError("CHATGPT_ACCESS_TOKEN not set. Run: eval $(./Scripts/extract-chatgpt-token.sh)")
    }
    let accountID = ProcessInfo.processInfo.environment["CHATGPT_ACCOUNT_ID"]
    return (token, accountID)
}

private struct SkipError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { self.description = message }
}

private func makeTestConfig(model: String = Constants.ChatGPT.defaultModel) -> AIProviderConfig {
    AIProviderConfig(
        name: "Test ChatGPT",
        providerType: .openAIChatGPT,
        modelID: model
    )
}

// MARK: - JWT Parsing Tests

@Suite("ChatGPT JWT Parsing")
struct JWTParsingTests {

    @Test("Parse email from id_token claims")
    func parseEmail() {
        // Build a fake JWT with known claims
        let claims: [String: Any] = [
            "email": "test@example.com",
            "https://api.openai.com/auth": [
                "chatgpt_plan_type": "plus",
                "chatgpt_user_id": "user-123",
                "chatgpt_account_id": "acct-456",
            ] as [String: Any],
        ]
        let jwt = buildFakeJWT(claims: claims)
        let info = ChatGPTAuthService.parseJWTClaims(idToken: jwt)

        #expect(info.email == "test@example.com")
        #expect(info.planType == "plus")
        #expect(info.userID == "user-123")
        #expect(info.accountID == "acct-456")
    }

    @Test("Parse email from profile claims fallback")
    func parseEmailFromProfile() {
        let claims: [String: Any] = [
            "https://api.openai.com/profile": ["email": "fallback@example.com"] as [String: Any],
        ]
        let jwt = buildFakeJWT(claims: claims)
        let info = ChatGPTAuthService.parseJWTClaims(idToken: jwt)

        #expect(info.email == "fallback@example.com")
    }

    @Test("Parse expiration from JWT")
    func parseExpiration() {
        let exp = Date(timeIntervalSinceNow: 3600).timeIntervalSince1970
        let claims: [String: Any] = ["exp": exp]
        let jwt = buildFakeJWT(claims: claims)
        let expiration = ChatGPTAuthService.parseJWTExpiration(jwt: jwt)

        #expect(expiration != nil)
        #expect(abs(expiration!.timeIntervalSinceNow - 3600) < 5)
    }

    @Test("Invalid JWT returns nil")
    func invalidJWT() {
        let info = ChatGPTAuthService.parseJWTClaims(idToken: "not.a.valid-jwt")
        #expect(info.email == nil)
        #expect(info.planType == nil)

        let exp = ChatGPTAuthService.parseJWTExpiration(jwt: "garbage")
        #expect(exp == nil)
    }

    private func buildFakeJWT(claims: [String: Any]) -> String {
        let header = Data("{}".utf8).base64URLEncodedNoPad()
        let payloadData = try! JSONSerialization.data(withJSONObject: claims)
        let payload = payloadData.base64URLEncodedNoPad()
        let signature = Data("sig".utf8).base64URLEncodedNoPad()
        return "\(header).\(payload).\(signature)"
    }
}

// MARK: - PKCE Tests

@Suite("ChatGPT PKCE")
struct PKCETests {

    @Test("Base64URL encoding produces correct characters")
    func base64URLEncoding() {
        let data = Data([0xFF, 0xFE, 0xFD, 0xFC, 0xFB])
        let encoded = data.base64URLEncodedNoPad()

        #expect(!encoded.contains("+"))
        #expect(!encoded.contains("/"))
        #expect(!encoded.contains("="))
        #expect(encoded.contains("-") || encoded.contains("_") || encoded.allSatisfy(\.isLetter))
    }
}

// MARK: - Responses API Integration Tests

@Suite("ChatGPT Responses API Integration")
struct ResponsesAPITests {

    @Test("Non-streaming request returns text")
    func nonStreamingRequest() async throws {
        let (accessToken, accountID) = try skipUnlessTokenAvailable()
        let config = makeTestConfig()

        let response = try await makeResponsesAPICall(
            text: "Reply with exactly: HELLO_TEST_OK",
            systemPrompt: "You are a test assistant. Follow instructions exactly.",
            config: config,
            accessToken: accessToken,
            accountID: accountID,
            stream: false
        )

        #expect(response.contains("HELLO_TEST_OK"))
    }

    @Test("Streaming request yields deltas")
    func streamingRequest() async throws {
        let (accessToken, accountID) = try skipUnlessTokenAvailable()
        let config = makeTestConfig()

        var chunks: [String] = []
        let stream = makeResponsesAPIStream(
            text: "Count from 1 to 5, each number on a new line.",
            systemPrompt: "You are a test assistant.",
            config: config,
            accessToken: accessToken,
            accountID: accountID
        )

        for try await chunk in stream {
            chunks.append(chunk)
        }

        let fullText = chunks.joined()
        #expect(!chunks.isEmpty)
        #expect(fullText.contains("1"))
        #expect(fullText.contains("5"))
    }

    @Test("Invalid model returns error")
    func invalidModel() async throws {
        let (accessToken, accountID) = try skipUnlessTokenAvailable()
        let config = makeTestConfig(model: "nonexistent-model-xyz")

        await #expect(throws: AIServiceError.self) {
            _ = try await makeResponsesAPICall(
                text: "test",
                systemPrompt: "test",
                config: config,
                accessToken: accessToken,
                accountID: accountID,
                stream: false
            )
        }
    }

    @Test("Default model is supported")
    func defaultModelWorks() async throws {
        let (accessToken, accountID) = try skipUnlessTokenAvailable()
        let config = makeTestConfig(model: Constants.ChatGPT.defaultModel)

        let response = try await makeResponsesAPICall(
            text: "Say OK",
            systemPrompt: "Reply with just OK",
            config: config,
            accessToken: accessToken,
            accountID: accountID,
            stream: false
        )

        #expect(!response.isEmpty)
    }

    // MARK: - Helpers

    /// ChatGPT Codex backend requires stream=true; collect all deltas.
    private func makeResponsesAPICall(
        text: String,
        systemPrompt: String,
        config: AIProviderConfig,
        accessToken: String,
        accountID: String?,
        stream: Bool = true
    ) async throws -> String {
        var result = ""
        let stream = makeResponsesAPIStream(
            text: text, systemPrompt: systemPrompt, config: config,
            accessToken: accessToken, accountID: accountID
        )
        for try await chunk in stream {
            result += chunk
        }
        return result
    }

    private func makeResponsesAPIStream(
        text: String,
        systemPrompt: String,
        config: AIProviderConfig,
        accessToken: String,
        accountID: String?
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try buildRequest(
                        text: text, systemPrompt: systemPrompt, config: config,
                        accessToken: accessToken, accountID: accountID, stream: true
                    )
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)

                    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                        throw AIServiceError.networkError(URLError(.badServerResponse))
                    }

                    struct SSEEvent: Decodable {
                        let type: String
                        let delta: String?
                    }

                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard line.hasPrefix("data: "),
                              let data = String(line.dropFirst(6)).data(using: .utf8),
                              let event = try? JSONDecoder().decode(SSEEvent.self, from: data),
                              event.type == "response.output_text.delta",
                              let delta = event.delta
                        else { continue }
                        continuation.yield(delta)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    private func buildRequest(
        text: String,
        systemPrompt: String,
        config: AIProviderConfig,
        accessToken: String,
        accountID: String?,
        stream: Bool
    ) throws -> URLRequest {
        guard let url = URL(string: config.baseURL + "/responses") else {
            throw AIServiceError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        struct RequestBody: Encodable {
            let model: String
            let instructions: String
            let input: [InputItem]
            let stream: Bool
            let store: Bool
            struct InputItem: Encodable {
                let type: String
                let role: String
                let content: [ContentPart]
            }
            struct ContentPart: Encodable {
                let type: String
                let text: String
            }
        }

        let body = RequestBody(
            model: config.modelID,
            instructions: systemPrompt,
            input: [.init(type: "message", role: "user", content: [.init(type: "input_text", text: text)])],
            stream: stream,
            store: false
        )
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }
}
