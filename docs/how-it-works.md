---
sidebar_position: 3
---

# How it works

ClipSlop has two modes: **Quick Paste** for one-shot inline transformations, and the **full pipeline** for chaining prompts together.

## Quick Paste — fastest

```
Select text → ⌃⌘G → grammar fixed in place
```

Assign any prompt to a global hotkey. ClipSlop runs entirely in the background:

1. Captures the currently selected text.
2. Sends it through the prompt.
3. Pastes the result back, replacing the selection.

You never leave your app. Configure shortcuts per prompt in **Settings → Prompts**.

There's also **Open & Run**: same thing, but ClipSlop opens its panel with the result ready, so you can review, tweak, or keep chaining. Useful for translations and longer rewrites.

## Full pipeline

```
Select text → ⌃⌘C → R → B → T → E → done
```

When one transformation isn't enough:

1. **Trigger.** Select text anywhere, press `⌃⌘C`. The selection appears in a floating panel.
2. **Navigate.** A nested prompt tree with single-key mnemonics: `T` → Translate, `R` → Rewrite, `F` → Format. Drill into folders, pick a prompt — one keypress each.
3. **Chain.** Each result becomes the input for the next prompt. *Translate → Elaborate → Format as Email.* Every step is saved.
4. **History.** Use ←/→ to walk the full transformation chain. Branch from any step.
5. **Use.** Copy (`⌘C`), edit (`⌘E`), save (`⌘S`), or keep chaining.

## The prompt tree

Prompts live in folders. Each folder has a mnemonic key:

```
[T] Translate
    [E] English
    [F] Finnish
    [R] Russian
    ...
[R] Rewrite
    [B] Business
    [P] Professional
    [W] Warm
    ...
[F] Format
    [G] Fix Grammar
    [E] Email
    [M] Markdownify
    ...
```

So `T` → `E` translates to English. `R` → `B` rewrites in a business tone. `F` → `M` reformats as Markdown.

Add your own prompts and folders in **Settings → Prompts**. Mnemonic keys are configurable per item.

## History and branching

Every transformation in a session is saved as a step.

- **←** / **→** walk back and forward through the chain.
- Press a prompt key from any step to **branch** — the new result becomes a sibling, not a replacement.
- `⌘E` lets you edit any result manually; the edit becomes its own step.

## What happens off-screen

- Results stream incrementally so you see output as the model produces it.
- The clipboard is restored to whatever was on it before Quick Paste ran.
- Conversations are not stored across sessions. There's no chat history file.
- API requests go directly from your Mac to the provider you chose. ClipSlop has no backend.

Continue with [Built-in Prompts](./built-in-prompts.md) to see what ships out of the box.
