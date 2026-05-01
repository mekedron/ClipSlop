---
sidebar_position: 3
title: Anthropic Claude
---

# Anthropic Claude

Use Claude as your AI provider. Bring-your-own API key.

## Setup

1. Generate a key at [console.anthropic.com](https://console.anthropic.com/).
2. In ClipSlop, open **Settings → Providers**.
3. Click **Anthropic**.
4. Paste your key.

Stored in the macOS Keychain.

## Settings

- **Model** — Claude Opus, Sonnet, Haiku, and the latest 4.x family.
- **Temperature** — global default.
- **Max tokens** — per response cap.

## Per-prompt overrides

Like OpenAI, any prompt can override the model. A common pattern:

- **Fix Grammar / Reformat** → Haiku (fast, cheap).
- **Rewrite / Translate** → Sonnet (balanced).
- **Explain Simply / Analyze** → Opus (deepest reasoning).

## Costs

Pay Anthropic directly per token. No ClipSlop markup.
