<p align="center">
  <img src="docs/icon.png" width="128" height="128" alt="ClipSlop icon">
</p>

<h1 align="center">ClipSlop</h1>

<p align="center">
  <strong>Select text. Press a hotkey. Grammar fixed.</strong><br>
  AI-powered text transformations for macOS — fix grammar, translate, rewrite, format — without leaving your app.<br>
  Free and open-source.
</p>

<p align="center">
  <a href="https://github.com/mekedron/ClipSlop/releases/latest">Download</a> &nbsp;·&nbsp;
  <a href="https://buymeacoffee.com/mekedron">Buy Me a Coffee ☕</a>
</p>

---

ClipSlop is a free, open-source AI writing tool for macOS that works in any app. Fix grammar, translate text, rewrite in different tones, format as email or Markdown — all with a keyboard shortcut. Use it as a simple AI grammar checker with a single hotkey, or chain multiple AI prompts into a full text transformation pipeline. Supports ChatGPT (free sign-in), OpenAI API, Anthropic Claude, Ollama (local models), and any OpenAI-compatible provider.

## Table of Contents

- [Why ClipSlop?](#why-clipslop)
- [Demos](#demos)
- [How it works](#how-it-works)
- [Built-in prompts](#built-in-prompts)
- [Keyboard shortcuts](#keyboard-shortcuts)
- [Features](#features)
- [Comparison with other AI writing tools](#comparison-with-other-ai-writing-tools)
- [Install](#install)
- [Requirements](#requirements)
- [Contributing](#contributing)
- [Acknowledgements](#acknowledgements)
- [License](#license)
- [Support](#support)

---

## Why ClipSlop?

Most AI writing tools make you copy text, switch to a browser, paste, wait, copy the result, switch back, paste. ClipSlop does it with a hotkey — right where you're already typing.

**Fix grammar without thinking about it:**
```
select text → ⌃⌘G → grammar is fixed in place. Done.
```

That's **Inline Run** — assign any prompt to a global hotkey, and it runs inline: captures the selected text, transforms it, pastes the result back. You never leave your app.

**Need more than one step?** Chain transformations into a pipeline:

```
⌃⌘C → RB → TE → FE → done.
```

Each key picks a prompt from a navigable tree — `RB` Rewrite → Business, `TE` Translate → English, `FE` Format → Email. Every step is saved, arrow keys to go back, branch from any point. No browser, no copy-paste, no tab switching.

Free, open-source, works with any AI provider — ChatGPT, Claude, Ollama, or your own API.

---

<p align="center">
  <img src="docs/screenshot.png?v=2" width="680" alt="ClipSlop — AI text transformations for macOS with prompt tree, Inline Run, transformation history, and search">
</p>

## Demos

Unedited screen recordings of the released app.

### Run inline anywhere &nbsp;·&nbsp; Inline Run &nbsp;·&nbsp; `⌃⌘G` · `⌃⌘T` · `⌃⌘/`

Three lines, three global shortcuts. Select the first line — **Fix Grammar**. Select the second — **Translate → English**. Select the third (prefixed with `//`) — **Run Custom Prompt** with the instruction typed inline after `//`. Every result pastes back where the cursor is.

https://github.com/user-attachments/assets/456456ff-75af-4920-a2f9-e7b5b6d3de4f

> More on this mode in the docs: [Inline Run](https://mekedron.github.io/ClipSlop/docs/use/quick-paste).

### Chain prompts across providers &nbsp;·&nbsp; Full pipeline &nbsp;·&nbsp; `⌃⌘C → R B → T F`

A rough draft typed straight into Gmail: trigger ClipSlop, rewrite for business tone, translate to Finnish, paste back into the same message. Every step is saved as a history node — branch off if you want a different turn.

https://github.com/user-attachments/assets/7964a98f-84a3-4194-93df-98e9cd85f2b1

> More on this mode in the docs: [The full pipeline](https://mekedron.github.io/ClipSlop/docs/use/full-pipeline).

### Analyze any selection on the web &nbsp;·&nbsp; Run in Editor &nbsp;·&nbsp; `⌃⌘⌥T → A S`

Open a Finnish news article, highlight a paragraph, translate to English with **Run in Editor**, then condense it into a short summary with **Analyze → Summary**. The full pipeline goes anywhere you can highlight text.

https://github.com/user-attachments/assets/c323d995-c262-4f9c-ad39-8e62065e4170

> More on this mode in the docs: [Run in Editor](https://mekedron.github.io/ClipSlop/docs/use/open-and-run).

### OCR images, then keep going &nbsp;·&nbsp; Screen OCR &nbsp;·&nbsp; `⇧⌘2 → T E → A S`

Capture a region of the screen. Apple Vision recognises the text on-device, drops it into the panel, and you can keep chaining — translate, then summarise, then copy. Useful when the source is an image, a PDF, or an app that won't let you `⌘C` its text.

https://github.com/user-attachments/assets/74a685ae-9561-4fa0-a73f-856652bcc18e

> More on this mode in the docs: [Screen OCR](https://mekedron.github.io/ClipSlop/docs/use/screen-ocr).

## How it works

### Inline Run (fastest)

```
Select text → ⌃⌘G → grammar fixed in place
```

Assign any prompt to a global hotkey. ClipSlop captures the text, runs the prompt, pastes the result — all in the background.

### Full pipeline

```
Select text → ⌃⌘C → Navigate prompts with keys → Chain transformations → Copy result
```

1. **Trigger** — Select text anywhere, press `⌃⌘C`. Text appears in a floating panel.
2. **Navigate** — Prompt tree with single-key mnemonics: `T` → Translate, `R` → Rewrite, `F` → Format. Drill into folders, pick a prompt — one keypress each.
3. **Chain** — Result becomes input for the next prompt. Translate → Elaborate → Format as Email. Each step saved.
4. **History** — Arrow keys navigate the full transformation chain. Jump to any step, branch off.
5. **Use** — Copy (`⌘C`), edit (`⌘E`), save (`⌘S`), or keep chaining.

## Features

- **Inline Run** — Assign a global hotkey to any prompt. Captures selected text, runs the prompt, pastes the result inline — you never leave your app
- **Run in Editor** — Like Inline Run, but opens ClipSlop and auto-runs the prompt so you can review, edit, or keep chaining
- **Prompt shortcuts** — Configure per-prompt in Settings → Prompts; shortcuts appear in the menu bar organized by folder
- **Keyboard-first** — Single-key mnemonics for prompt navigation, all actions have shortcuts
- **Full pipeline** — Chain unlimited transformations, navigate history with arrow keys, branch from any step
- **Multi-provider** — OpenAI (sign in with ChatGPT or API key), Anthropic, Ollama, CLI tools, any OpenAI-compatible API
- **Nested prompt tree** — Organize prompts in folders, each with a mnemonic key
- **Built-in prompts** — Translate (18 languages), Rewrite (7 tones), Format (7 tools), Dev (6 tools), Analyze (4), Convert
- **Manual editing** — Edit any result inline (`⌘E`), saved as a history step
- **Find in text** — `⌘F` search with highlighting across all display modes
- **Screen OCR** — Capture and recognize text from any screen region with OCR (`⇧⌘2`)
- **Blank editor** — Open an empty editor (`⌃⌘N`), write text, run prompts on it
- **Generate prompts with AI** — Describe what you want, AI writes the system prompt
- **Per-prompt settings** — Override provider, display mode per prompt
- **Import/Export** — Share prompt configurations as JSON
- **iCloud Sync** — Prompts sync across Macs
- **Temperature & reasoning** — Per-provider temperature control, reasoning effort for ChatGPT models
- **Multiple display modes** — Plain text, Markdown (native or HTML renderer), HTML
- **Adjustable UI** — Opacity, size, theme, launch at login

## Built-in prompts

```
[⌘/] // Your prompt — type // followed by your instruction to run a one-off custom prompt
[T]  Translate   → English, Finnish, Russian, Spanish, French, German, + 12 more
[R]  Rewrite     → Elaborate, Neutral, Professional, Warm, Business, Playful, Biblical
[F]  Format      → Fix Grammar, Clean Up, Beautify Code, Reformat, Email, Markdownify, HTMLify
[D]  Dev         → Add Comments, Beautify Code, Clean Logs, Explain Code, Explain Stack Trace, Naming
[A]  Analyze     → Summary, Explain Simply, TL;DR, Condense 20%
[C]  Convert     → HTML, Markdown
```

Some prompts ship with default global keyboard shortcuts (Inline Run pastes the result inline, Run in Editor opens ClipSlop):

| Shortcut | Prompt | Mode |
|----------|--------|------|
| `⌃⌘/` | // Your prompt | Inline Run |
| `⌃⌘⌥/` | // Your prompt | Run in Editor |
| `⌃⌘G` | Fix Grammar | Inline Run |
| `⌃⌘F` | Reformat | Inline Run |
| `⌃⌘T` | Translate → English | Inline Run |
| `⌃⌘⌥T` | Translate → English | Run in Editor |
| `⌃⌘⌥A` | Explain Simply | Run in Editor |

Fully customizable — add your own prompts, folders, mnemonics, and global shortcuts in Settings → Prompts.

## Keyboard shortcuts

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
| `↑↓` | Navigate history (↑ newer step, ↓ older step) |
| `Space` | Page down |
| `⇧Space` | Page up |
| `Esc` | Close / Back |

## Comparison with other AI writing tools

| | ClipSlop | RewriteBar | WritingTools | Cai | ClipboardAI | WritersBrew | Elephas | Fixkey | ShortcutAI | Raycast AI | PopClip | ChatGPT (web) |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| **Prompt chaining** | ✅ Unlimited chaining, full history | ⚠️ Sequential action flow, no history | ❌ One action | ❌ One action | ❌ One action | ❌ One action | ❌ One action | ❌ One action | ❌ One action | ⚠️ Limited, no true pipeline | ❌ One action | ❌ Manual workflow |
| **Keyboard-first** | ✅ Single-key mnemonics, full pipeline navigation, global shortcuts for text fields (Inline Run, Run in Editor) and on-screen text (OCR) | ⚠️ Shortcut + action picker | ⚠️ Hotkey + action picker | ⚠️ ⌥C hotkey + action list | ⚠️ Per-prompt shortcuts | ⚠️ Shortcut + menu | ⚠️ Super Command shortcut | ⚠️ Custom shortcuts | ⚠️ Shortcuts + `//` text commands | ⚠️ Launcher, menu-based AI | ❌ Mouse-driven | ❌ Browser UI |
| **Prompt organization** | ✅ Nested folders with mnemonics | ⚠️ Flat action list | ⚠️ Fixed presets + custom instructions | ⚠️ Flat action list | ⚠️ Flat list | ⚠️ Flat preset list | ⚠️ Flat snippets | ⚠️ Flat list | ⚠️ Flat list | ⚠️ Flat command list | ⚠️ Flat list | ❌ Chat history |
| **Step history** | ✅ Navigate back/forward, branch from any step | ❌ No | ❌ No | ❌ No | ❌ No | ❌ No | ❌ No | ❌ No | ❌ No | ❌ No | ❌ No | ⚠️ Scroll up |
| **Branching history** | ✅ Branch from any intermediate step | ❌ No | ❌ No | ❌ No | ❌ No | ❌ No | ❌ No | ❌ No | ❌ No | ❌ No | ❌ No | ❌ No |
| **Provider freedom** | ✅ ChatGPT sign-in (free), API keys, Ollama (local), CLI tools | ✅ 37+ providers, local models, Apple Intelligence | ✅ Gemini (free), OpenAI, Anthropic, Ollama, MLX local | ✅ Built-in local, Ollama, LM Studio, Apple Intelligence, cloud APIs | ⚠️ BYO key (OpenAI, OpenRouter) | ⚠️ BYO OpenAI key only | ⚠️ Built-in + BYO keys (OpenAI, Anthropic, Gemini) | ❌ Built-in only (provider unclear) | ❌ Managed API only (no BYO keys) | ⚠️ Multiple, not fully open BYO | ⚠️ OpenAI API | ❌ OpenAI only |
| **Screen OCR** | ✅ Capture any screen region (`⇧⌘2`) | ❌ No | ⚠️ Image processing via AI vision | ✅ Screenshot text extraction | ❌ No | ✅ OCR to Text AI | ❌ No | ❌ No | ❌ No | ❌ No | ❌ No | ⚠️ Image uploads only |
| **Platform** | ⚠️ macOS (native, works in any app) | ⚠️ macOS (native, works in any app) | ✅ macOS + Windows + Linux | ⚠️ macOS (native, works in any app) | ✅ macOS + Windows (native, works in any app) | ⚠️ macOS (native, works in any app) | ⚠️ macOS + iOS | ⚠️ macOS | ❌ Chrome extension only (browser text fields) | ⚠️ macOS | ⚠️ macOS | ✅ Web (any platform) |
| **Price** | ✅ Free, open-source | ⚠️ $29 one-time (BYO key) or $5/mo | ✅ Free, open-source | ✅ Free, open-source | ⚠️ €29 one-time (7-day trial) | ⚠️ $24–$49 one-time + API costs | ❌ $9.99–$39.99/mo | ❌ $48/year | ⚠️ Free (limited) / $5.90–$19.90/mo | ⚠️ Free tier + Pro ~$8/mo | ⚠️ $30 one-time + API costs | ❌ $20/mo |

## Install

### Homebrew

```bash
brew tap mekedron/tap
brew install --cask clipslop
```

### Download

Grab the latest `.dmg` from [Releases](https://github.com/mekedron/ClipSlop/releases/latest). Drag to Applications.

#### Opening the app

Drag `ClipSlop.app` to **Applications** and double-click. That's it — no Gatekeeper warning, no "Open Anyway" dance.

ClipSlop is signed with an Apple Developer ID and notarised by Apple, so macOS opens it like any other app.

**The app is safe, and you don't have to take my word for it.** The source is fully open, and every release is built and signed automatically by [GitHub Actions](https://github.com/mekedron/ClipSlop/actions) straight from this repository — nothing is added to the binary that isn't here. You can check the signature yourself:

```bash
spctl -a -vvv -t exec /Applications/ClipSlop.app
# ClipSlop.app: accepted
# source=Notarized Developer ID
```

> **Upgrading from v1.x?** Those releases were unsigned (v2.0.0 was the first signed one). macOS ties Accessibility and Screen Recording permissions to the app's signature, so the first signed version you install may need those granted once more: **System Settings → Privacy & Security → Accessibility**, remove any stale ClipSlop entry with **−**, then re-add `ClipSlop.app` with **+**. Repeat under **Screen Recording** if you use OCR. Your prompts, providers, and settings are untouched — and this is a one-time migration, not a per-update chore.

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

## Contributing

### Pre-commit hooks (required)

ClipSlop ships with a pre-commit hook that blocks commits when any localization key is missing in any of the 16 translated languages. **Install it once after cloning** — `.git/hooks/` is not versioned, so the hook is not active out of the box:

```bash
./Scripts/install-hooks.sh
```

What the hook does:

- Runs only when a `*.lproj/Localizable.strings` file is in the commit.
- Compares every key in `en.lproj/Localizable.strings` against the other 16 languages.
- Blocks the commit if any translation is missing, and prints the offending keys per language.

To check translations manually at any time:

```bash
./Scripts/check-localizations.sh
```

Re-run `./Scripts/install-hooks.sh` whenever the contents of `Scripts/hooks/` change. Bypassing the hook with `--no-verify` is strongly discouraged — missing translations break the UI for users of those languages.

## Acknowledgements

ClipSlop is built with these open-source libraries:

- [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) by Sindre Sorhus — customizable global keyboard shortcuts
- [LaunchAtLogin](https://github.com/sindresorhus/LaunchAtLogin-Modern) by Sindre Sorhus — launch at login support
- [Sparkle](https://github.com/sparkle-project/Sparkle) — software update framework for macOS
- [swift-markdown](https://github.com/swiftlang/swift-markdown) by Apple / Swift Project — Markdown parsing and rendering
- [Textual](https://github.com/gonzalezreal/textual) by Guillermo Gonzalez — native SwiftUI Markdown rendering
- [swift-rich-html-editor](https://github.com/Infomaniak/swift-rich-html-editor) by Infomaniak — WYSIWYG rich HTML editor
- [Lobe Icons](https://github.com/lobehub/lobe-icons) by LobeHub — provider icons for OpenAI, Anthropic, Ollama, Claude, Codex

## License

MIT License — see [LICENSE](LICENSE).

## Support

If ClipSlop saves you time, consider [buying me a coffee ☕](https://buymeacoffee.com/mekedron)
