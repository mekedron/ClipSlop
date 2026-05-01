---
sidebar_position: 4
---

# Built-in Prompts

ClipSlop ships with a curated catalogue. Six top-level groups, each with a single-letter mnemonic.

```
[⌘/]  // Your prompt — type // followed by your instruction to run a one-off custom prompt
[T]   Translate   → English, Finnish, Russian, Spanish, French, German, + 12 more
[R]   Rewrite     → Elaborate, Neutral, Professional, Warm, Business, Playful, Biblical
[F]   Format      → Fix Grammar, Clean Up, Beautify Code, Reformat, Email, Markdownify, HTMLify
[D]   Dev         → Add Comments, Beautify Code, Clean Logs, Explain Code, Explain Stack Trace, Naming
[A]   Analyze     → Summary, Explain Simply, TL;DR, Condense 20%
[C]   Convert     → HTML, Markdown
```

## Default global shortcuts

A handful of prompts ship with a default global keyboard shortcut. **Quick Paste** runs the prompt inline; **Open & Run** opens ClipSlop with the result ready.

| Shortcut    | Prompt                | Mode        |
|-------------|-----------------------|-------------|
| `⌃⌘/`       | // Your prompt        | Quick Paste |
| `⌃⌘⌥/`      | // Your prompt        | Open & Run  |
| `⌃⌘G`       | Fix Grammar           | Quick Paste |
| `⌃⌘F`       | Reformat              | Quick Paste |
| `⌃⌘T`       | Translate → English   | Quick Paste |
| `⌃⌘⌥T`      | Translate → English   | Open & Run  |
| `⌃⌘⌥A`      | Explain Simply        | Open & Run  |

All of these can be reassigned, removed, or added to other prompts in **Settings → Prompts**.

## Customising

Every built-in prompt is editable. You can also:

- **Add new prompts.** System prompt, model, provider, display mode, optional global shortcut.
- **Add folders.** Group prompts and give the folder its own mnemonic.
- **Reorder.** Drag-and-drop in Settings.
- **Generate with AI.** Describe what you want — ClipSlop writes the system prompt for you.
- **Export / Import.** Share configurations as JSON. iCloud Sync mirrors prompts across Macs.

For the full keyboard map (not just prompt shortcuts), see [Keyboard Shortcuts](./keyboard-shortcuts.md).
