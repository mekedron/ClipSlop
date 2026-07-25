---
sidebar_position: 2
title: Keyboard map
description: Every default shortcut in one place — global, panel, prompt navigation. For customisation, see Configure → Keyboard shortcuts.
---

# Keyboard map

The full read-only reference. For *customising* shortcuts, see [Configure → Keyboard shortcuts](../configure/keyboard-shortcuts.md).

## Global

Work everywhere on macOS — even when ClipSlop is in the background.

| Shortcut | Action                              |
|----------|-------------------------------------|
| `⌃⌘C`    | Trigger ClipSlop with selected text |
| `⌃⌘V`    | Process clipboard                   |
| `⌃⌘N`    | Blank editor                        |
| `⇧⌘2`    | Screen capture (OCR)                |
| `⌃⌘⌥P`   | Settings Assistant                  |

Default per-prompt global shortcuts:

| Shortcut    | Prompt                | Mode        |
|-------------|-----------------------|-------------|
| `⌃⌘/`       | // Your prompt        | Inline Run |
| `⌃⌘⌥/`      | // Your prompt        | Run in Editor  |
| `⌃⌘G`       | Fix Grammar           | Inline Run |
| `⌃⌘F`       | Reformat              | Inline Run |
| `⌃⌘T`       | Translate → English   | Inline Run |
| `⌃⌘⌥T`      | Translate → English   | Run in Editor  |
| `⌃⌘⌥A`      | Explain Simply        | Run in Editor  |

## Inside the panel

When the floating panel is open:

| Shortcut | Action             |
|----------|--------------------|
| `⌘E`     | Edit mode          |
| `⌘F`     | Find in text       |
| `⌘S`     | Save to file       |
| `⌘O`     | Open in TextEdit   |
| `⌘D`     | Cycle display mode |
| `⌘,`     | Settings           |
| `↑` `↓`  | Navigate history (↑ newer step, ↓ older step) |
| `Space`  | Page down          |
| `⇧Space` | Page up            |
| `Esc`    | Close / Back       |

## Prompt navigation

Inside the prompt tree:

- **Single letters** — pick a prompt or open a folder by its mnemonic.
- `⌘/` — run a one-off custom prompt (type `//` followed by your instruction).
- `Esc` — go back one level.

## Cheat-sheet for muscle memory

The patterns underneath the defaults:

- `⌃⌘<letter>` runs a per-prompt **Inline Run**.
- `⌃⌘⌥<letter>` runs the **Run in Editor** variant of the same prompt.
- `⌃⌘<symbol>` triggers an app-level action (`C` = trigger, `V` = clipboard, `N` = blank, `/` = custom).
- `⇧⌘<digit>` for screen actions (mirrors macOS conventions — `⇧⌘3`/`⇧⌘4` already taken by macOS).

Pick your custom shortcuts to extend these patterns and your hands will pick them up faster.
