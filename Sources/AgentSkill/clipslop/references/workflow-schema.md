# Workflow card schema — full reference

A workflow is one markdown file under `~/.clipslop/workflows/` (dev builds:
`~/.clipslop-dev/`): YAML frontmatter between `---` fences (the **card**,
what the router matches) followed by a markdown body (the instructions the
model receives when the workflow is chosen).

## The YAML subset

Parsing is a deliberate subset, not full YAML:

- `key: value` scalars; quotes optional, double quotes support backslash
  escapes (`"linkedin\\.com/feed"`).
- Flow lists `[a, b, c]` and flow maps `{k: v, k2: v2}`.
- Exactly one nesting level, used by `when:` (indented `key: value` lines).
- `#` comments and blank lines are ignored.
- No anchors, no multi-line strings, no block sequences (except the
  `providers:`/`roles:` record lists in those two files).

Errors carry line numbers; a file that fails to parse is **disabled with a
visible error** (Settings badge), never silently dropped.

## Keys

| Key | Required | Type | Semantics |
|---|---|---|---|
| `id` | yes | scalar | `^[a-z][a-z0-9.-]*$`, unique across ALL workflow files (including `workflows/library/**`). Duplicate ids disable *both* claimants. |
| `kind` | yes | scalar | Only `workflow`. |
| `mode` | yes | scalar | Only `direct`. |
| `version` | yes | int | Card version, author-managed. Never inherited. |
| `extends` | no | scalar | Parent card id. The chain resolves root-first; a cycle or missing parent disables the file. |
| `abstract` | no | bool | `true` = exists only as an `extends` target, never routed (e.g. `base.generation`). |
| `priority` | no | int 0–100 | Tie-break *within* a tier; default 50. Higher wins the intent dedup. |
| `surface` | no | enum | `public` \| `team` \| `private` (default). Parsed and written to traces; the surface *gate* is not enforced yet. |
| `summary` | conditional | scalar | The chip label. Required on routable cards (has `when:`, not abstract). Never inherited — every routable card labels its own chip. |
| `intents` | no | list | First entry = primary intent, used to dedupe chips (two cards sharing a primary intent are ranking, not ambiguity). Inheritable. |
| `when` | no | nested block | Match conditions, see below. Absent → the card never enters routing (prompt-library cards; invocable by id/uuid only). |
| `budget` | no | flow map | `{prompt_tokens_total: 3500, ms: 6000}` (defaults shown). Prompt-assembly token budget and time budget. Inheritable. |
| `output` | no | flow map | `{lang: match_context, max_chars: 400, format: plain}`. `lang`: `match_context` (default) or a fixed code like `en`. `max_chars` is optional — when absent, config.yaml `output_max_chars_default` applies; a card's explicit value always wins. `format`: only `plain`. Inheritable. |

Forward-compatible keys parsed for later milestones — they produce a
warning and are ignored, not an error: `needs`, `authorship`, `execution`,
`permissions`. Any other unknown key is an **error** (typo protection).

Prompt-library cards (under `workflows/library/`) may additionally carry
the §7.3 library metadata keys: `uuid`, `title`, `order`, `mnemonic`,
`mnemonic_modifiers`, `provider`, `display_mode`, `select_all`,
`shortcut_inline`, `shortcut_popup` — see `prompt-library.md` for their
semantics. They are never inherited via `extends`.

## `when:` conditions

ALL present conditions must pass (AND). Presence of a condition sets the
card's **tier**:

| Condition | Type | Tier effect | Semantics |
|---|---|---|---|
| `app` | list | → **domain** | App bundle ids, exact match (e.g. `[com.apple.mail]`). |
| `url` | scalar | → **exact** | Regular expression (NSRegularExpression syntax) matched against the page URL. Validated compilable at load time. |
| `field.role` | list | — | Raw AX roles, case-insensitive (e.g. `[AXTextArea]`). |
| `field.state` | list | — | `empty` \| `draft` \| `selection` — the interaction-grammar row. |
| `selection` | list | — | `instruction` \| `material` \| `mixed` — gates on the selection classifier's top class. |

No `when:` at all → base tier if routed via inheritance… in practice: a
card without `when:` is **not routable** (library cards). A card whose
`when:` has neither `url` nor `app` is **base** tier.

Unknown `when` condition names are errors.

## Inheritance (`extends`)

- The chain resolves root-first: `base.generation` → `base.reply` →
  `reply.thread` → `reply.thread.web`.
- `id`, `when`, `summary`, `abstract`, `version` are **never** inherited.
- `intents`, `priority`, `surface`, `budget`, `output` inherit when unset.
- Bodies concatenate ancestor-first (root's rules come first).
- Cycles and missing parents disable the file with a retained, visible
  error.

## Routing recap

Tiers: **exact** (url matched) ≻ **domain** (app matched) ≻ **base**.
Candidates are counted at the highest tier that produced a match; lower
tiers stay available as chip alternatives but do not add ambiguity.
Candidates sharing a primary intent count once (highest priority).
Silent execution iff exactly one counted candidate and the selection
classification (when a selection exists) was decisive; otherwise 2–4
chips. One fixed contextual rule: on an empty field, visible surroundings
favor `reply` over `write`; a blank context favors `write`.

## Body conventions

```markdown
## Rules
- Behavior rules, one per line.
## Examples
Good outputs (optional).
## Anti-examples
What never to produce (optional).
```

Under prompt-budget pressure the body trims `## Anti-examples` first, then
`## Examples`, then `## Rules` — put the load-bearing rules first.

## Example card

```yaml
---
id: comment.social
kind: workflow
mode: direct
version: 1
extends: base.generation
priority: 70
surface: public
summary: "Comment in your voice"
intents: [comment, reply]
when:
  url: "(linkedin\\.com/(feed|posts)|x\\.com/)"
  field.state: [empty, draft, selection]
output: {lang: match_context, max_chars: 400, format: plain}
---
## Rules
- One or two sentences that add something. Never bare agreement.
```
