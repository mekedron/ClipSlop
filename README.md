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

That's **Quick Paste** — assign any prompt to a global hotkey, and it runs inline: captures the selected text, transforms it, pastes the result back. You never leave your app.

**Need more than one step?** Chain transformations into a pipeline:

```
⌃⌘C → RB → TE → FE → done.
```

Each key picks a prompt from a navigable tree — `RB` Rewrite → Business, `TE` Translate → English, `FE` Format → Email. Every step is saved, arrow keys to go back, branch from any point. No browser, no copy-paste, no tab switching.

Free, open-source, works with any AI provider — ChatGPT, Claude, Ollama, or your own API.

---

<p align="center">
  <img src="docs/screenshot.png?v=2" width="680" alt="ClipSlop — AI text transformations for macOS with prompt tree, Quick Paste, transformation history, and search">
</p>

## Demos

Unedited screen recordings of the released app. Click the thumbnails below to play (GitHub renders `<video>` inline on most browsers; if your client falls back to a download link, the videos open in any media player).

### Run inline anywhere &nbsp;·&nbsp; Quick Paste &nbsp;·&nbsp; `⌃⌘G` · `⌃⌘T` · `⌃⌘/`

Three lines, three global shortcuts. Select the first line — **Fix Grammar**. Select the second — **Translate → English**. Select the third (prefixed with `//`) — **Run Custom Prompt** with the instruction typed inline after `//`. Every result pastes back where the cursor is.

<p align="center">
  <video src="https://github.com/mekedron/ClipSlop/raw/main/docs-site/static/demos/videos/inline-run.mp4" controls muted playsinline width="720"></video>
</p>

▶ [Watch `inline-run.mp4`](docs-site/static/demos/videos/inline-run.mp4) · [open in the docs](https://mekedron.github.io/ClipSlop/docs/use/quick-paste)

### Chain prompts across providers &nbsp;·&nbsp; Full pipeline &nbsp;·&nbsp; `⌃⌘C → R B → T F`

A rough draft typed straight into Gmail: trigger ClipSlop, rewrite for business tone, translate to Finnish, paste back into the same message. Every step is saved as a history node — branch off if you want a different turn.

<p align="center">
  <video src="https://github.com/mekedron/ClipSlop/raw/main/docs-site/static/demos/videos/prompt-chaining.mp4" controls muted playsinline width="720"></video>
</p>

▶ [Watch `prompt-chaining.mp4`](docs-site/static/demos/videos/prompt-chaining.mp4) · [open in the docs](https://mekedron.github.io/ClipSlop/docs/use/full-pipeline)

### Analyze any selection on the web &nbsp;·&nbsp; Open & Run &nbsp;·&nbsp; `⌃⌘⌥T → A S`

Open a Finnish news article, highlight a paragraph, translate to English with **Open & Run**, then condense it into a short summary with **Analyze → Summary**. The full pipeline goes anywhere you can highlight text.

<p align="center">
  <video src="https://github.com/mekedron/ClipSlop/raw/main/docs-site/static/demos/videos/analyze-any-text.mp4" controls muted playsinline width="720"></video>
</p>

▶ [Watch `analyze-any-text.mp4`](docs-site/static/demos/videos/analyze-any-text.mp4) · [open in the docs](https://mekedron.github.io/ClipSlop/docs/use/open-and-run)

### OCR images, then keep going &nbsp;·&nbsp; Screen OCR &nbsp;·&nbsp; `⇧⌘2 → T E → A S`

Capture a region of the screen. Apple Vision recognises the text on-device, drops it into the panel, and you can keep chaining — translate, then summarise, then copy. Useful when the source is an image, a PDF, or an app that won't let you `⌘C` its text.

<p align="center">
  <video src="https://github.com/mekedron/ClipSlop/raw/main/docs-site/static/demos/videos/screen-ocr.mp4" controls muted playsinline width="720"></video>
</p>

▶ [Watch `screen-ocr.mp4`](docs-site/static/demos/videos/screen-ocr.mp4) · [open in the docs](https://mekedron.github.io/ClipSlop/docs/use/screen-ocr)

## How it works

### Quick Paste (fastest)

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

- **Quick Paste** — Assign a global hotkey to any prompt. Captures selected text, runs the prompt, pastes the result inline — you never leave your app
- **Open & Run** — Like Quick Paste, but opens ClipSlop and auto-runs the prompt so you can review, edit, or keep chaining
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

Some prompts ship with default global keyboard shortcuts (Quick Paste pastes the result inline, Open & Run opens ClipSlop):

| Shortcut | Prompt | Mode |
|----------|--------|------|
| `⌃⌘/` | // Your prompt | Quick Paste |
| `⌃⌘⌥/` | // Your prompt | Open & Run |
| `⌃⌘G` | Fix Grammar | Quick Paste |
| `⌃⌘F` | Reformat | Quick Paste |
| `⌃⌘T` | Translate → English | Quick Paste |
| `⌃⌘⌥T` | Translate → English | Open & Run |
| `⌃⌘⌥A` | Explain Simply | Open & Run |

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
| `←→` | Navigate history |
| `↑↓` | Scroll text |
| `Space` | Page down |
| `Esc` | Close / Back |

## Comparison with other AI writing tools

| | ClipSlop | RewriteBar | WritingTools | Cai | ClipboardAI | WritersBrew | Elephas | Fixkey | ShortcutAI | Raycast AI | PopClip | ChatGPT (web) |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| **Prompt chaining** | ✅ Unlimited chaining, full history | ⚠️ Sequential action flow, no history | ❌ One action | ❌ One action | ❌ One action | ❌ One action | ❌ One action | ❌ One action | ❌ One action | ⚠️ Limited, no true pipeline | ❌ One action | ❌ Manual workflow |
| **Keyboard-first** | ✅ Single-key mnemonics, full pipeline navigation, global shortcuts for text fields (Quick Paste, Open & Run) and on-screen text (OCR) | ⚠️ Shortcut + action picker | ⚠️ Hotkey + action picker | ⚠️ ⌥C hotkey + action list | ⚠️ Per-prompt shortcuts | ⚠️ Shortcut + menu | ⚠️ Super Command shortcut | ⚠️ Custom shortcuts | ⚠️ Shortcuts + `//` text commands | ⚠️ Launcher, menu-based AI | ❌ Mouse-driven | ❌ Browser UI |
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
- [Lobe Icons](https://github.com/lobehub/lobe-icons) by LobeHub — provider icons for OpenAI, Anthropic, Ollama, Claude, Codex

## License

MIT License — see [LICENSE](LICENSE).

## Support

If ClipSlop saves you time, consider [buying me a coffee ☕](https://buymeacoffee.com/mekedron)
