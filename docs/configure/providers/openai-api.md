---
sidebar_position: 2
title: OpenAI API
---

# OpenAI API

Bring your own OpenAI API key. Better fit if you want full model control or are running through an organisational account.

## Setup

1. Generate a key at [platform.openai.com/api-keys](https://platform.openai.com/api-keys).
2. Open **Settings → Providers** in ClipSlop.
3. Click **OpenAI (API key)**.
4. Paste your key.

The key is stored in the macOS Keychain. ClipSlop never sends it anywhere except to OpenAI.

## Settings

- **Model** — pick any model your account has access to (GPT-4.1, GPT-4o, o-series, etc.).
- **Temperature** — global default; can be overridden per prompt.
- **Reasoning effort** — for o-series and reasoning-capable models.

## Per-prompt overrides

Any prompt can override the global model and temperature:

1. Open **Settings → Prompts** and select a prompt.
2. Toggle **Use custom provider settings**.
3. Pick a different model or temperature for this prompt only.

Useful for routing cheap tasks (Fix Grammar) to a smaller model and reasoning-heavy ones (Explain Simply) to a larger one.

## Costs

You pay OpenAI directly per token. ClipSlop adds nothing on top. Each transformation is a single request — no streaming overhead, no chat history to re-send.
