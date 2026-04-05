# ChatGPT OAuth Integration

Technical documentation for the OpenAI (Sign In) provider — OAuth 2.0 + PKCE authentication via ChatGPT, using the Codex backend Responses API.

## Architecture Overview

```
User clicks "Sign in"
  → Local HTTP server starts on localhost:1455
  → Browser opens auth.openai.com/oauth/authorize
  → User authenticates on ChatGPT
  → Browser redirects to localhost:1455/auth/callback?code=...&state=...
  → App exchanges code for tokens (access_token, refresh_token, id_token)
  → Tokens stored in Keychain
  → API calls use access_token with chatgpt.com/backend-api/codex/responses
```

## Reference Implementation

This integration is based on the [Codex CLI](https://github.com/openai/codex) project (Rust). Key source files:

| Component | Codex File | ClipSlop File |
|-----------|-----------|---------------|
| OAuth server & callback | `codex-rs/login/src/server.rs` | `Sources/Services/AI/ChatGPTAuthService.swift` |
| PKCE generation | `codex-rs/login/src/pkce.rs` | `ChatGPTAuthService.swift` (generatePKCE) |
| Token exchange | `codex-rs/login/src/server.rs` (exchange_code_for_tokens) | `ChatGPTAuthService.swift` (exchangeCodeForTokens) |
| Token refresh | `codex-rs/login/src/auth/manager.rs` (request_chatgpt_token_refresh) | `ChatGPTAuthService.swift` (refreshAccessToken) |
| JWT claims parsing | `codex-rs/login/src/token_data.rs` | `ChatGPTAuthService.swift` (parseJWTClaims) |
| Auth state management | `codex-rs/login/src/auth/manager.rs` | `Sources/Services/AI/ChatGPTTokenManager.swift` |
| API key exchange | `codex-rs/login/src/server.rs` (obtain_api_key) | Not used (see "API Key Exchange" below) |
| Responses API client | `codex-rs/codex-api/src/endpoint/responses.rs` | `Sources/Services/AI/ChatGPTService.swift` |
| SSE event parsing | `codex-rs/codex-api/src/sse/responses.rs` | `ChatGPTService.swift` (stream method) |
| Model fetching | `codex-rs/models-manager/src/manager.rs` | `Sources/Services/AI/ModelFetcher.swift` |
| Model catalog | `codex-rs/models-manager/models.json` | Hardcoded fallback in ModelFetcher.knownModels |
| Provider config | `codex-rs/model-provider-info/src/lib.rs` | `Sources/Models/AIProvider.swift` |

## Constants

All values sourced from Codex source code:

```
Auth issuer:     https://auth.openai.com
Client ID:       app_EMoamEEZ73f0CkXaXp7hrann
Callback port:   1455
Redirect URI:    http://localhost:1455/auth/callback
Token endpoint:  https://auth.openai.com/oauth/token
API base URL:    https://chatgpt.com/backend-api/codex
Scopes:          openid profile email offline_access api.connectors.read api.connectors.invoke
```

**Source**: `codex-rs/login/src/server.rs` (DEFAULT_ISSUER, DEFAULT_PORT), `codex-rs/login/src/auth/manager.rs` (CLIENT_ID), `codex-rs/model-provider-info/src/lib.rs` (base URL).

## OAuth Flow Details

### Step 1: PKCE Generation

Generate 64 random bytes, encode as base64url-no-pad = `code_verifier`. SHA256 the verifier, encode as base64url-no-pad = `code_challenge`.

**Codex ref**: `codex-rs/login/src/pkce.rs`

### Step 2: Authorization URL

```
GET https://auth.openai.com/oauth/authorize
  ?response_type=code
  &client_id=app_EMoamEEZ73f0CkXaXp7hrann
  &redirect_uri=http://localhost:1455/auth/callback
  &scope=openid profile email offline_access api.connectors.read api.connectors.invoke
  &code_challenge={challenge}
  &code_challenge_method=S256
  &state={random_32_bytes_base64url}
  &id_token_add_organizations=true
  &codex_cli_simplified_flow=true
  &originator=clipslop
```

**Codex ref**: `codex-rs/login/src/server.rs` → `build_authorize_url()`

### Step 3: Local Callback Server

Bind TCP listener on `127.0.0.1:1455`. Accept one connection, parse HTTP GET request, extract `code` and `state` from query parameters. Validate `state` matches. Return success HTML page.

**Implementation**: Uses `NWListener` (Network framework). The Codex version uses `tiny_http` crate.

**Codex ref**: `codex-rs/login/src/server.rs` → `run_login_server()`, `process_request()`

### Step 4: Token Exchange

```
POST https://auth.openai.com/oauth/token
Content-Type: application/x-www-form-urlencoded

grant_type=authorization_code
&code={authorization_code}
&redirect_uri=http://localhost:1455/auth/callback
&client_id=app_EMoamEEZ73f0CkXaXp7hrann
&code_verifier={verifier}
```

Response:
```json
{
  "id_token": "eyJ...",
  "access_token": "eyJ...",
  "refresh_token": "..."
}
```

**Codex ref**: `codex-rs/login/src/server.rs` → `exchange_code_for_tokens()`

### Step 5: JWT Claims Parsing

Split `id_token` by `.`, base64url-decode the middle segment, parse JSON:

```json
{
  "email": "user@example.com",
  "https://api.openai.com/profile": { "email": "user@example.com" },
  "https://api.openai.com/auth": {
    "chatgpt_plan_type": "plus",
    "chatgpt_user_id": "user-...",
    "chatgpt_account_id": "..."
  },
  "exp": 1234567890
}
```

Client does NOT validate JWT signature (same as Codex).

**Codex ref**: `codex-rs/login/src/token_data.rs` → `parse_chatgpt_jwt_claims()`

### Step 6: Token Storage

Tokens stored in macOS Keychain as JSON under key `clipslop.chatgpt.tokens.{provider-UUID}`:

```json
{
  "accessToken": "eyJ...",
  "refreshToken": "...",
  "idToken": "eyJ...",
  "accountID": "...",
  "email": "...",
  "planType": "plus"
}
```

**Codex ref**: `codex-rs/login/src/auth/storage.rs` (uses file `~/.codex/auth.json` or system keyring)

## Token Refresh

Triggered when `access_token` JWT `exp` claim is within 5 minutes of now.

```
POST https://auth.openai.com/oauth/token
Content-Type: application/json

{
  "client_id": "app_EMoamEEZ73f0CkXaXp7hrann",
  "grant_type": "refresh_token",
  "refresh_token": "{stored_refresh_token}"
}
```

Returns new `id_token`, `access_token`, `refresh_token`. The old refresh token becomes invalid (rotation).

**Permanent failures** (HTTP 401): `refresh_token_expired`, `refresh_token_reused`, `refresh_token_invalidated` — clears tokens, user must re-authenticate.

**Codex ref**: `codex-rs/login/src/auth/manager.rs` → `request_chatgpt_token_refresh()`, `classify_refresh_token_failure()`

## API Calls (Responses API)

### Endpoint

```
POST https://chatgpt.com/backend-api/codex/responses
```

**Important**: The ChatGPT Codex backend requires `stream: true`. Non-streaming requests return HTTP 400.

### Headers

```
Authorization: Bearer {access_token}
ChatGPT-Account-Id: {account_id}
Content-Type: application/json
```

### Request Body

```json
{
  "model": "gpt-5.3-codex",
  "instructions": "system prompt",
  "input": [
    {
      "type": "message",
      "role": "user",
      "content": [
        { "type": "input_text", "text": "user message" }
      ]
    }
  ],
  "stream": true,
  "store": false
}
```

**Codex ref**: `codex-rs/codex-api/src/common.rs` → `ResponsesApiRequest`

### Streaming Response (SSE)

```
event: response.output_text.delta
data: {"type":"response.output_text.delta","delta":"Hello"}

event: response.output_text.delta
data: {"type":"response.output_text.delta","delta":" world"}

event: response.completed
data: {"type":"response.completed","response":{...}}
```

Text deltas are in the `delta` field of `response.output_text.delta` events. Stream ends with `response.completed`.

Error: `response.failed` event with `response.error.message`.

**Codex ref**: `codex-rs/codex-api/src/sse/responses.rs` → `ResponsesStreamEvent`

## Model Fetching

### Endpoint

```
GET https://chatgpt.com/backend-api/codex/models?client_version=1.0.0
Authorization: Bearer {access_token}
ChatGPT-Account-Id: {account_id}
```

### Response Format

```json
{
  "models": [
    {
      "slug": "gpt-5.3-codex",
      "display_name": "gpt-5.3-codex",
      "visibility": "list",
      "priority": 0,
      ...
    }
  ]
}
```

Filter by `visibility == "list"`, sort by `priority` ascending.

**Note**: Field is `slug` (not `id` like standard OpenAI API). Requires `client_version` query parameter.

**Codex ref**: `codex-rs/codex-api/src/endpoint/models.rs`, `codex-rs/models-manager/models.json`

### Currently Available Models (as of 2026-04)

| Model | Priority | Description |
|-------|----------|-------------|
| gpt-5.3-codex | 0 | Default. Latest Codex model. |
| gpt-5.4 | 0 | Latest frontier model. |
| gpt-5.4-mini | 0 | Lightweight frontier. |
| gpt-5.2-codex | 3 | Previous Codex model. |
| gpt-5.1-codex-max | 4 | High-capacity Codex model. |
| gpt-5.2 | 6 | Previous frontier. |
| gpt-5.1-codex-mini | 12 | Lightweight Codex model. |

## API Key Exchange (Not Used)

Codex optionally exchanges the `id_token` for an OpenAI API key:

```
POST https://auth.openai.com/oauth/token
Content-Type: application/x-www-form-urlencoded

grant_type=urn:ietf:params:oauth:grant-type:token-exchange
&client_id=app_EMoamEEZ73f0CkXaXp7hrann
&requested_token=openai-api-key
&subject_token={id_token}
&subject_token_type=urn:ietf:params:oauth:token-type:id_token
```

This fails for accounts without an organization (`missing organization_id`). The returned API key works with `api.openai.com/v1` but is not needed for the Codex backend.

**Codex ref**: `codex-rs/login/src/server.rs` → `obtain_api_key()`

We don't use this because:
1. It fails for personal ChatGPT accounts (no org)
2. The Codex backend (`chatgpt.com/backend-api/codex`) works directly with the OAuth access_token
3. The Codex backend uses different models (gpt-5.x-codex) than the standard API

## Troubleshooting

### Port 1455 already in use
Another instance of ClipSlop or Codex CLI may be running a login server. Kill it or wait.

### "Stream must be set to true"
The Codex backend requires streaming. Our `process()` method internally uses streaming and collects deltas.

### "Model X is not supported"
Use models from the `/models` endpoint or the fallback list. Standard OpenAI models (gpt-4o, etc.) are NOT supported on the Codex backend.

### Token refresh fails with 401
Refresh token has been rotated, expired, or revoked. User must sign out and sign in again.

### Missing organization_id
The API key exchange step fails for personal accounts. This is expected and handled — we use the access_token directly instead.

## File Map

```
Sources/Services/AI/
  ChatGPTAuthService.swift   - OAuth flow, PKCE, callback server, token exchange/refresh, JWT parsing
  ChatGPTTokenManager.swift  - Keychain persistence, auto-refresh, user info
  ChatGPTService.swift       - AIService using Responses API with streaming
  ModelFetcher.swift          - Dynamic model list from /models endpoint

Sources/Models/
  AIProvider.swift            - AIProviderType.openAIChatGPT case

Sources/Utilities/
  Constants.swift             - Constants.ChatGPT namespace

Sources/Views/Settings/
  ProvidersSettingsView.swift - Sign in/out UI, auth state display

Tests/
  ChatGPTIntegrationTests.swift - JWT parsing, PKCE, Responses API integration tests

Scripts/
  extract-chatgpt-token.sh   - Extract OAuth token from Keychain for tests
```
