---
sidebar_position: 2
---

# Getting Started

Install ClipSlop, grant permissions, and pick an AI provider — that's everything you need before your first transformation.

## Install

### Via Homebrew

```bash
brew tap mekedron/tap
brew install --cask clipslop
```

### Via the DMG

Grab the latest `.dmg` from [Releases](https://github.com/mekedron/clipslop/releases/latest) and drag `ClipSlop.app` to your **Applications** folder.

## Opening the app for the first time

ClipSlop is **not signed with an Apple Developer certificate** — we don't pay Apple's $99/year. macOS will block it on first launch, which is expected.

The app is safe: the source is fully open and every release is built by [GitHub Actions](https://github.com/mekedron/clipslop/actions) directly from the public repository.

To open it:

1. Drag `ClipSlop.app` to your **Applications** folder.
2. Double-click — macOS shows a warning and refuses.
3. Open **System Settings → Privacy & Security**.
4. Scroll down — you'll see _"ClipSlop was blocked from use because it is not from an identified developer"_.
5. Click **Open Anyway**, then confirm.

Subsequent launches open normally.

## Grant permissions

ClipSlop needs two macOS permissions to work in any app:

- **Accessibility** — required to read the text you've selected and paste results back. Grant in **System Settings → Privacy & Security → Accessibility**.
- **Screen Recording** — only needed for the OCR feature (`⇧⌘2`). Grant in **System Settings → Privacy & Security → Screen Recording**.

:::warning After updating to a new version
Because the app is unsigned, macOS may change the bundle identifier between versions and invalidate previously granted permissions. If shortcuts stop working after an update:

1. Open **System Settings → Privacy & Security → Accessibility**.
2. Find ClipSlop in the list and **remove it** (select → click "−").
3. Click "+" and **re-add** `ClipSlop.app` from your Applications folder.
4. Repeat for **Screen Recording** if you use OCR.

Your prompts and settings are never affected.
:::

## Pick a provider

ClipSlop calls a real AI model for every transformation, so you need at least one provider configured:

- **[Sign in with ChatGPT](./providers/chatgpt.md)** — free, OAuth-based, no API key needed. Best starting point.
- **[OpenAI API](./providers/openai-api.md)** — paid, bring-your-own-key. More control, all OpenAI models.
- **[Anthropic Claude](./providers/anthropic.md)** — paid, bring-your-own-key.
- **[Ollama](./providers/ollama.md)** — free, runs entirely on your machine.
- **[Other OpenAI-compatible APIs](./providers/compatible-apis.md)** — OpenRouter, LM Studio, custom endpoints.

Open **Settings → Providers** in the menu bar (or `⌘,`) to add credentials.

## Your first transformation

1. Select some text in any app.
2. Press `⌃⌘G`. ClipSlop runs **Fix Grammar** in the background.
3. The corrected text is pasted in place.

That's **Quick Paste**. For something fancier, see [How it works](./how-it-works.md).
