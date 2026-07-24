# config.yaml — key reference

`~/.clipslop/config.yaml` tunes the Magic Button engine. Same constrained
YAML subset as workflow frontmatter (the whole file sits between `---`
fences). Hot-reloaded on the next press.

Behavior of the parser:

- Missing key → the built-in default applies. Deleting a line is a reset.
- Out-of-range value → **clamped** to the nearest bound, with a warning
  shown in Settings → Magic.
- Wrong type or unknown key → warning, value ignored.
- A file that fails to parse entirely → all defaults, one warning.

## Integer keys

| Key | Default | Range | Meaning |
|---|---|---|---|
| `capture_deadline_ms` | 1600 | 300–10000 | Total snapshot deadline per press — the press never waits longer for screen capture. |
| `ax_call_budget` | 350 | 50–5000 | Accessibility call budget for the native (non-web) surrounding walk. |
| `web_call_budget` | 900 | 50–10000 | Accessibility call budget for web-content walks (Chromium wraps everything in groups, so web needs far more calls). |
| `max_gather_depth` | 6 | 1–50 | Depth of the text gather inside one native sibling subtree. |
| `max_web_depth` | 30 | 5–100 | Depth cap inside web subtrees. |
| `max_siblings_per_level` | 16 | 2–200 | Siblings visited per level in the native walk. |
| `max_web_children_per_node` | 60 | 5–500 | Children visited per node in web subtrees. |
| `surrounding_max_chars` | 6000 | 500–50000 | Cap on the assembled surrounding text. |
| `web_before_keep_chars` | 4500 | 200–40000 | Web walk: text *before* the field kept (a chat's newest messages live here). |
| `web_after_keep_chars` | 1000 | 0–20000 | Web walk: text *after* the field kept. |
| `field_value_max_chars` | 50000 | 1000–500000 | Cap on reading the focused field's own value. |
| `toast_dismiss_seconds` | 8 | 2–120 | Post-insert toast auto-dismiss. |
| `output_max_chars_default` | 1200 | 100–100000 | Character ceiling for generated output when the routed workflow card sets no `output.max_chars` of its own. The model is told this number and the verifier warns beyond it; a card's explicit value always wins. |
| `warm_observer_enabled` | 1 | 0–1 | Warm frontmost-app observer: keeps cheap context (URL, window title, focused element) fresh between presses and pre-builds Chromium's accessibility tree on app switch. 0 = pure collect-on-press (also the Chromium-CPU kill switch). |
| `warm_context_ttl_seconds` | 30 | 5–300 | How long the observer's cheap context stays usable as press-time backfill. |
| `observer_debounce_ms` | 200 | 50–2000 | Debounce between a focus-change notification and the observer's cheap read. |
| `planner_timeout_ms` | 900 | 0–5000 | Fast-mode chip planner: hard time cap for the one tiny model call that may auto-pick the obvious chip when routing was ambiguous (trace presentation `chips_planner`, role `planner.magic`). Confident answer in time → the press proceeds as if that chip was picked; timeout / unsure / error → the chip panel shows unchanged. **0 disables the planner** (always ask). Forced-chips presses (the always-ask hotkey) never use it. |
| `debug_log_enabled` | 0 | 0–1 | Full-content per-press debug log (one markdown file per press under `logs/debug/`): complete snapshot with real screen content, the verbatim prompt, the raw model output, the verifier verdict. **Privacy tradeoff — enable only with the user's explicit consent.** Files are pruned after 7 days. This key is the same switch as the Settings → Magic checkbox (config.yaml is authoritative). |

## `no_cloud` (list)

Apps/domains whose field content must never reach a cloud provider.
Entries are matched case-insensitively:

- substring of the app **bundle id** (`telegram`, `com.tinyspeck.slackmacgap`), or
- **exact or suffix** match of the page URL's host (`gmail.com` matches
  `mail.gmail.com`).

A press on a matching surface switches to a `locality: local` provider
from the role's fallback chain, or **refuses honestly** (trace outcome
`error:generation:noCloud`) when none exists. The role's `min_cost_class`
still holds during the swap.

```yaml
no_cloud: [telegram, com.tinyspeck.slackmacgap, gmail.com]
```

## What is NOT here

- Per-workflow prompt/time budgets — those live in each workflow card's
  `budget:` frontmatter.
- Provider/model choice — `providers.yaml` and `roles.yaml`.
- Hotkeys — managed in the app (Settings → General), not files.
