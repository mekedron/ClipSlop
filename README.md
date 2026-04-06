<p align="center">
  <img src="docs/icon.png" width="128" height="128" alt="ClipSlop icon">
</p>

<h1 align="center">ClipSlop</h1>

<p align="center">
  <strong>Keyboard-first AI text pipeline for macOS.</strong><br>
  Chain prompts, transform text, never leave your keyboard.<br>
  Free and open-source.
</p>

<p align="center">
  <a href="https://github.com/mekedron/ClipSlop/releases/latest">Download</a> &nbsp;·&nbsp;
  <a href="https://buymeacoffee.com/mekedron">Buy Me a Coffee ☕</a>
</p>

---

## Why?

Raycast, PopClip, and ChatGPT all let you run text through AI. But they don't support true multi-step pipelines with persistent history and branching. You can chain translate → fix grammar → make formal → format as email manually, but not as a fast, keyboard-driven, persistent pipeline. And you don't get step-level navigation with the ability to branch and continue from any intermediate result.

ClipSlop treats text transformation as a versioned pipeline, not a linear interaction. Select text, press a shortcut, navigate a prompt tree with single-key mnemonics, chain as many transformations as you want — each step saved in history. Fully keyboard-driven pipeline navigation, not just triggering actions. All in a floating panel, all without touching a browser.

It's also completely free, open-source, and works with any AI provider — your own API keys, ChatGPT sign-in, local Ollama, or CLI tools like Claude Code.

---

<p align="center">
  <img src="docs/screenshot.png?v=2" width="680" alt="ClipSlop — keyboard-driven AI text pipeline with prompt tree, transformation history, and search">
</p>

## How it works

```
Select text → ⌃⌘C → Navigate prompts with keys → Chain transformations → Copy result
```

1. **Trigger** — Select text anywhere, press `⌃⌘C`. Text appears in a floating panel.
2. **Navigate** — Prompt tree with single-key mnemonics: `T` → Translate, `R` → Rewrite, `F` → Format. Drill into folders, pick a prompt — one keypress each.
3. **Chain** — Result becomes input for the next prompt. Translate → Elaborate → Format as Email. Each step saved.
4. **History** — Arrow keys navigate the full transformation chain. Jump to any step, branch off.
5. **Use** — Copy (`⌘C`), edit (`⌘E`), save (`⌘S`), or keep chaining.

## What makes it different

| | ClipSlop | Raycast AI | PopClip | ChatGPT |
|---|---|---|---|---|
| **Prompt chaining** | Chain unlimited transformations, full history | Limited chaining (via commands/chat), no true pipeline or step history | One action | No native prompt chaining; manual workflow required |
| **Keyboard-first** | Single-key mnemonics, fully keyboard-driven pipeline navigation | Keyboard-driven launcher, menu-based AI | Primarily mouse-driven | Browser UI |
| **Prompt organization** | Nested folders with mnemonics | Flat command list | Flat list | Chat history |
| **Step history** | Navigate back/forward, branch from any step | No step history | No history | Scroll up |
| **Branching history** | Branch from any intermediate step | No | No | No |
| **Provider freedom** | Any: ChatGPT sign-in, API keys, Ollama, CLI tools | Multiple providers (built-in + extensions), not fully open BYO | OpenAI API | OpenAI ecosystem (no external providers) |
| **Price** | Free, open-source | Free tier + paid Pro (~$8/mo for extended AI) | $30 one-time + API costs | $20/mo |

## Features

- **Full pipeline** — Chain unlimited transformations, navigate history with arrow keys, branch from any step
- **Keyboard-first** — Single-key mnemonics for prompt navigation, all actions have shortcuts
- **Multi-provider** — OpenAI (sign in with ChatGPT or API key), Anthropic, Ollama, CLI tools, any OpenAI-compatible API
- **Nested prompt tree** — Organize prompts in folders, each with a mnemonic key
- **Built-in prompts** — Translate (16 languages), Rewrite (6 tones), Format (7 tools), Analyze, Convert
- **Manual editing** — Edit any result inline (`⌘E`), saved as a history step
- **Find in text** — `⌘F` search with highlighting across all display modes
- **Screen OCR** — Capture and recognize text from any screen region (`⇧⌘2`)
- **Blank editor** — Open an empty editor (`⌃⌘N`), write text, run prompts on it
- **Generate prompts with AI** — Describe what you want, AI writes the system prompt
- **Per-prompt settings** — Override provider, display mode per prompt
- **Import/Export** — Share prompt configurations as JSON
- **iCloud Sync** — Prompts sync across Macs
- **Temperature & reasoning** — Per-provider temperature control, reasoning effort for ChatGPT models
- **Multiple display modes** — Plain text, Markdown (native or HTML renderer), HTML
- **Adjustable UI** — Opacity, size, theme, launch at login

## Default shortcuts

| Shortcut | Action |
|----------|--------|
| `⌃⌘C` | Trigger ClipSlop (selected text) |
| `⌃⌘V` | Process from clipboard |
| `⌃⌘N` | Blank editor |
| `⇧⌘2` | Screen capture (OCR) |
| `⌘E` | Edit mode |
| `⌘F` | Find in text |
| `⌘S` | Save to file |
| `⌘O` | Open in TextEdit |
| `⌘D` | Cycle display mode |
| `⌘,` | Settings |
| `←→` | Navigate history |
| `↑↓` | Scroll text |
| `Space` | Page down |
| `Esc` | Close / Back |

## Default prompts

```
[T] Translate  → English, Finnish, Russian, Spanish, French, German, + 10 more
[R] Rewrite    → Elaborate, Neutral, Professional, Warm, Business, Playful, Biblical
[F] Format     → Fix Grammar, Clean Up, Beautify Code, Reformat, Email, Markdownify, HTMLify
[A] Analyze    → Summary, Explain Simply, TL;DR
[C] Convert    → JSON, CSV
```

Fully customizable — add your own prompts, folders, and mnemonics in Settings → Prompts.

## Install

### Download

Grab the latest `.dmg` from [Releases](https://github.com/mekedron/ClipSlop/releases/latest). Drag to Applications.

#### Opening the app (important)

ClipSlop is not signed with an Apple Developer certificate, so macOS will block it on first launch. This is expected — I simply don't want to pay Apple $99/year for a developer account.

**The app is safe.** The source code is fully open, and all release builds are produced automatically by [GitHub Actions](https://github.com/mekedron/ClipSlop/actions) — nothing is added to the binary that isn't in this repository.

To open ClipSlop:

1. **Drag** `ClipSlop.app` to your **Applications** folder
2. **Double-click** to open — macOS will show a warning and refuse
3. Open **System Settings → Privacy & Security**
4. Scroll down — you'll see *"ClipSlop was blocked from use because it is not from an identified developer"*
5. Click **Open Anyway**, then confirm

You only need to do this once. After that, the app opens normally.

#### After updating to a new version

Because the app is unsigned, macOS may change its internal bundle identifier between versions. When this happens, previously granted permissions (Accessibility, Screen Recording) stop working. To fix this:

1. Open **System Settings → Privacy & Security → Accessibility**
2. Find ClipSlop in the list and **remove it** (select → click "−")
3. Click "+" and **re-add** `ClipSlop.app` from your Applications folder
4. Do the same for **Screen Recording** if you use the OCR feature

This is an unfortunate side effect of not having a signed app. Your prompts, providers, and settings are not affected.

### Build from source

```bash
git clone https://github.com/mekedron/ClipSlop.git
cd ClipSlop
swift build
# Or open Package.swift in Xcode → Run
```

Requires macOS 14+ and Xcode with Swift 6.0+.

## Requirements

- macOS 14.0+
- An AI provider: sign in with ChatGPT (free), API key (Anthropic, OpenAI), local Ollama, or CLI tools

## Acknowledgements

ClipSlop is built with these open-source libraries:

- [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) by Sindre Sorhus — customizable global keyboard shortcuts
- [LaunchAtLogin](https://github.com/sindresorhus/LaunchAtLogin-Modern) by Sindre Sorhus — launch at login support
- [Sparkle](https://github.com/sparkle-project/Sparkle) — software update framework for macOS
- [swift-markdown](https://github.com/swiftlang/swift-markdown) by Apple / Swift Project — Markdown parsing and rendering
- [Textual](https://github.com/gonzalezreal/textual) by Guillermo Gonzalez — native SwiftUI Markdown rendering
- [swift-rich-html-editor](https://github.com/Infomaniak/swift-rich-html-editor) by Infomaniak — WYSIWYG rich HTML editor

## License

MIT License — see [LICENSE](LICENSE).

## Support

If ClipSlop saves you time, consider [buying me a coffee ☕](https://buymeacoffee.com/mekedron)
