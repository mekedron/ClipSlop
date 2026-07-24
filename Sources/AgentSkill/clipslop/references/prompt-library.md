# The prompt library — workflows/library/** reference

Since the §7.3 unification, the prompt library **is** part of the workflow
store: every prompt is a markdown workflow card under
`~/.clipslop/workflows/library/`, and the popup, Quick Access tiles,
global hotkeys, Spotlight, and App Intents are all views over these files.
Edits hot-reload when the popup or Quick Access opens.

## Layout

```
workflows/library/
├── fix-grammar.md          # a prompt: one card, body = system prompt
├── translations/           # a folder = a subdirectory
│   ├── _folder.md          # the folder's own metadata card
│   ├── to-english.md
│   └── to-finnish.md
└── …
```

(The library root itself carries no `_folder.md` — only subfolders do.)

- **Folders are subdirectories.** Each subdirectory carries a `_folder.md`
  metadata card (uuid, title, mnemonic, order). `_folder.md` is skipped by
  the workflow file scan — it is folder metadata, not a prompt.
- **Prompts are cards without `when:`** — they never enter routing and
  need no `summary`/`intents`. The markdown body below the frontmatter is
  the prompt's **system prompt**, sent to the AI when the prompt runs.
- Ordering in the popup: `order:` (position among siblings), then
  filename.

## Slug rules (filenames)

Filenames are slugs of the display name: lowercase ASCII letters/digits
with dashes ("TL;DR" → `tl-dr.md`). Deliberately not transliterated — a
fully non-ASCII name falls back to the stem `item`. Collisions among
siblings get `-2`, `-3`, … suffixes. The display name lives in `title:`;
when `title:` is absent the name is derived from the stem (`tl-dr` →
"Tl Dr"). Renaming a prompt in the app renames the file to the new slug.

The workflow `id` of a library card is its path slugged and joined under
the `library.` namespace: `translations/to-english.md` →
`library.translations.to-english`. When creating a file by hand, follow
this convention; on mismatch the app treats the frontmatter `id` as
authoritative for routing identity, but keep them consistent.

## UUID rules (identity)

`uuid:` is the prompt's **stable identity**. Global hotkeys
(`prompt_quickPaste_<uuid>` shortcut names), Quick Access tiles, Spotlight
entries, and App Intents all bind to it.

- **Never change an existing `uuid:`** — that silently unbinds the user's
  hotkeys and tiles.
- **Never duplicate a uuid** — a duplicate is detected at load and the
  second file is assigned a fresh identity (breaking whatever pointed at
  it).
- When creating a new prompt file you may omit `uuid:` — the app
  generates one and writes it back into the file on next load. Generating
  your own (any standard UUID) is equally fine.

## Card keys (on top of the workflow schema)

A library card is `kind: workflow, mode: direct, version: 1` plus:

| Key | Type | Semantics |
|---|---|---|
| `uuid` | UUID | Stable identity (see above). |
| `title` | string | Display name (filename stays the slug). |
| `order` | int | Position among siblings in the popup. |
| `mnemonic` | string | Single-key popup navigation ("t", "delete", "f5"). Unique among siblings. |
| `mnemonic_modifiers` | list | Any of `shift`, `control`, `option`, `command`. |
| `provider` | UUID | Per-prompt AI provider override (a provider id from providers.yaml). |
| `display_mode` | enum | `plainText` \| `html` \| `markdown` — result-window rendering override. |
| `select_all` | bool | Press ⌘A before capturing (whole-field transforms). |
| `shortcut_inline` | flow map | `{key: <carbon keyCode>, modifiers: <carbon modifier mask>}` — the quick-paste global hotkey (transform selection in place). This is the exact encoding the app stores; e.g. `{key: 5, modifiers: 768}` is ⌘⇧G. |
| `shortcut_popup` | flow map | Same encoding — the open-popup-and-run hotkey. |

`_folder.md` uses the subset: `uuid`, `title`, `mnemonic`,
`mnemonic_modifiers`, `order` (with `id`/`kind`/`mode`/`version` present
like any card).

Example prompt card:

```yaml
---
id: library.fix-grammar
kind: workflow
mode: direct
version: 1
uuid: 1B671A64-40D5-491E-99B0-DA01FF1F3341
title: "Fix Grammar"
order: 0
mnemonic: g
select_all: false
shortcut_inline: {key: 5, modifiers: 4352}
---
Fix the grammar and spelling of the text. Preserve meaning, tone, and
formatting. Output only the corrected text.
```

## The prompts.json mirror — never edit it

`~/Library/Application Support/ClipSlop/prompts.json` survives as a
**derived mirror** of this tree: the app regenerates it after every
library mutation so iCloud sync and cold-launch App Intents keep working.

- **Never edit prompts.json directly** — your edit is overwritten by the
  next regeneration, and a hand-broken mirror can confuse sync.
- Inbound cloud changes are decoded and diff-written back into the
  markdown tree by the app; the markdown tree is always the authority on
  this machine.
- `prompts.json.pre-unification.bak` is the pre-migration backup — leave
  it alone.

## Editing etiquette

- The app's writer is diff-based: untouched files keep their mtimes. When
  editing by hand, touch only the files you mean to change.
- An unparseable hand-edited file is skipped with a visible issue, not
  destroyed — but the prompt disappears from the popup until fixed.
- Deleting a file deletes the prompt (after the next reload). Prefer
  asking the user before destructive changes; there is no undo beyond
  Time Machine and the cloud copy.
