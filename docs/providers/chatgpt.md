---
sidebar_position: 1
title: ChatGPT (free sign-in)
---

# Sign in with ChatGPT

Use your existing ChatGPT account — no API key, no separate billing. ClipSlop authenticates via OAuth 2.0 with PKCE and calls the same `chatgpt.com` backend the official Codex CLI uses.

## Setup

1. Open **Settings → Providers** (`⌘,`).
2. Click **OpenAI (Sign in with ChatGPT)**.
3. Click **Sign in**. Your browser opens `auth.openai.com`.
4. Authenticate (or confirm if you're already signed in).
5. The browser redirects back to `localhost:1455` and the connection completes automatically.

That's it. Tokens are stored in your macOS Keychain.

## What you get

- Free usage subject to your existing ChatGPT plan limits (Free, Plus, Pro, Team).
- Access to the same models and reasoning effort settings the ChatGPT app exposes.
- No separate API billing.

## When to use a different provider

- You need a model that isn't available through ChatGPT.
- You want fine-grained control over temperature, top-p, or other API-level parameters.
- You want to use ClipSlop heavily and stay within an organisational API quota.

In any of those cases, see [OpenAI API](./openai-api.md) instead.

## Under the hood

If you're curious about how the OAuth + PKCE handshake works, the [Development → ChatGPT OAuth Integration](../development/chatgpt-oauth-integration.md) page has the technical details.
