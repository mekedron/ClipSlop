---
sidebar_position: 4
title: Troubleshooting
description: Common breakages — shortcuts stop working after upgrade, providers refusing auth, OCR returning blanks.
---

# Troubleshooting

## Shortcuts stopped working after an update

Symptom: ClipSlop runs, but pressing the global hotkey does nothing in any app.

Cause: macOS revoked Accessibility permission because the app's bundle changed (ClipSlop is unsigned).

Fix:

1. **System Settings → Privacy & Security → Accessibility**.
2. Find ClipSlop, click **−** to remove it.
3. Click **+** to re-add `ClipSlop.app` from Applications.
4. Restart ClipSlop.

Same procedure for **Screen Recording** if OCR (`⇧⌘2`) stops working.

See [Install & first run → After updating](../install.mdx#after-updating-to-a-new-version) for the full procedure.

## Provider says "unauthorized" or "401"

Symptom: prompts fail with an authentication error from OpenAI / Anthropic / OpenRouter.

Common causes:

- **Expired or revoked key.** Issue a fresh key in the provider dashboard, paste into **Settings → Providers**.
- **ChatGPT OAuth session expired.** Sign out and back in from **Settings → Providers → ChatGPT**.
- **Wrong key in the wrong field.** OpenAI keys start `sk-`, Anthropic keys `sk-ant-`. Check the prefix matches the provider you pasted into.
- **Network blocking.** If you're on a corporate VPN, the provider's API host may be blocked.

## OCR returns a blank or black image

Symptom: pressing `⇧⌘2` captures a region but the recognised text is empty or garbled.

Cause: **Screen Recording** permission is missing or was revoked.

Fix: **System Settings → Privacy & Security → Screen Recording** → re-add ClipSlop. Restart the app.

## Quick Paste pastes the *wrong* text

Symptom: the result pastes somewhere unexpected, or pastes the original text instead of the transformed result.

Common causes:

- **The frontmost app changed** between when you pressed the hotkey and when ClipSlop pasted. ClipSlop pastes into whichever text field is focused at paste time, not at trigger time.
- **The frontmost app uses non-standard text fields** that don't accept simulated <kbd>⌘V</kbd>. Some Electron and game apps fall into this bucket.
- **The clipboard restoration race.** Very rare — if your input was tiny and the model was instant, the restored clipboard can briefly overlap with the paste. Use [Open & Run](../use/open-and-run.mdx) instead and copy manually.

## Ollama returns "connection refused"

Symptom: prompts fail with a connection error when Ollama is the configured provider.

Fix:

- Make sure `ollama serve` (or the Ollama macOS app) is running.
- The endpoint defaults to `http://localhost:11434`. If you've changed it, update **Settings → Providers → Ollama → Endpoint**.
- Test the model is actually pulled: `ollama list` should show the model name configured in ClipSlop.

## Still stuck

[Open an issue](https://github.com/mekedron/ClipSlop/issues) with the symptom, what you were doing, your macOS version, and which provider you have configured. Don't include API keys.
