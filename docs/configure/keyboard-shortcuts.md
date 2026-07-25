---
sidebar_position: 2
title: Keyboard shortcuts
description: "Customise every shortcut — the four global app actions plus per-prompt Inline Run and Run in Editor bindings."
---

# Keyboard shortcuts

This page is about **customising** shortcuts. For the full read-only reference of every default key, see [Keyboard map](../reference/keyboard-map.md).

## What you can rebind

ClipSlop has two layers of shortcuts:

1. **Four global app actions** — Trigger, Process clipboard, Blank editor, Screen OCR. Configure in **Settings → Keyboard**.
2. **Per-prompt global shortcuts** — every prompt can have its own Inline Run and Run in Editor binding. Configure in **Settings → Prompts**.

## Global app actions

Open **Settings → Keyboard** and click any row to rebind. Defaults:

| Default  | Action                              |
|----------|-------------------------------------|
| `⌃⌘C`    | Trigger ClipSlop (selected text)    |
| `⌃⌘V`    | Process from clipboard              |
| `⌃⌘N`    | Blank editor                        |
| `⇧⌘2`    | Screen capture (OCR)                |

Press the new combination to record it; press <kbd>Esc</kbd> to clear the binding entirely.

The [Settings Assistant](./settings-assistant.mdx) has its own global shortcut — <kbd>⌃⌘⌥P</kbd> by default — rebindable in **Settings → General → Keyboard Shortcuts**.

## Per-prompt shortcuts

Each prompt in the library can have:

- **Inline Run** — runs the prompt inline without opening the panel. See [Inline Run](../use/quick-paste.mdx).
- **Run in Editor** — opens the panel with the result so you can review or chain. See [Run in Editor](../use/open-and-run.mdx).

Open **Settings → Prompts**, pick a prompt, scroll to the **Shortcuts** section, and assign one or both bindings.

<Callout type="tip">
  Free conventions: <kbd>⌃⌘&lt;letter&gt;</kbd> for Inline Run, <kbd>⌃⌘⌥&lt;letter&gt;</kbd> for the Run in Editor variant of the same prompt. Pairs of bindings keep your muscle memory consistent.
</Callout>

## Inside the panel

When the floating panel is open, these are fixed (not rebindable):

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
