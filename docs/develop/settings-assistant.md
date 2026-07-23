---
sidebar_position: 5
title: Settings Assistant internals
---

# Settings Assistant — how it works

The Settings Assistant (default **⌘⌃⌥P**) is the evolution of the Prompt
Assistant: one floating tool-calling chat window that manages **everything
ClipSlop is configured by** — the prompt library it always managed, plus the
whole Magic Button engine tree under `~/.clipslop/` (workflows, core files,
config.yaml, providers.yaml, roles.yaml) and the engine's observability
(traces, trace stats, spend). It is the implementation of the design doc's
§16 "Chat with the engine", hats 1 and 2: *system introspection* (instant,
read-only) and *catalog management* (validated file operations behind
confirmation). Hat 3 (life research) does not exist yet.

Two invariants carry over from the engine unchanged:

- **Files first (§15).** The assistant is an editor over `~/.clipslop/`,
  never a parallel store. It writes the same files the engine's mtime-based
  hot reload watches, so every accepted edit is live on the next press.
- **Visible, never silent (§15.3).** Every mutation shows an Approve/Reject
  card with a before→after diff, and every write is validated with the
  *same parser the engine uses* before it touches disk. The assistant can
  never write a file the engine cannot parse.

## Architecture

The agent loop is unchanged from the Prompt Assistant
(`SettingsAssistantService`, `Sources/Services/Assistant/`): send → model
replies with text and/or tool calls → read-only tools run immediately,
mutating tools pause on a `CheckedContinuation` until the user resolves the
proposal card → results feed back → repeat (≤ 15 iterations). Model dispatch
goes through the `chat.assistant` engine role (`EngineRoleStore`,
roles.yaml), capability-filtered to tool-calling providers.

What changed is the tool registry. Tools now live in two executors behind
one dispatch seam:

- `PromptLibraryToolExecutor` (`PromptLibraryTools.swift`) — the existing
  ten library tools, untouched. Kept deliberately separate because §7.3
  (prompt library → markdown files under `workflows/library/`) will replace
  this executor's *implementation* while the tool names and schemas stay —
  the model-facing contract survives the storage swap.
- `EngineToolExecutor` (`EngineTools.swift`, `EngineToolExecutor.swift`,
  `TraceInspector.swift`) — the new engine tools, described below.

`SettingsAssistantService` routes each call by name
(`EngineTools.contains(name)`) and unions both tool lists into every
request. Both executors follow the same shape: `@MainActor` class holding
store references, `makeProposal(for:)` for the confirmation card,
`perform(_:)` for execution, with all decision logic in `nonisolated static`
pure functions so tests drive them against temp directories.

## The tool inventory

### Read-only (auto-run, activity row in the chat)

| Tool | Arguments | Returns |
|---|---|---|
| `list_engine_files` | — | The engine tree: config.yaml / system-prompt.md / providers.yaml / roles.yaml presence, core/*.md, every workflows/**.md with its parsed `id` and disabled/error state |
| `read_engine_file` | `path` (engine-relative) | Raw file content |
| `engine_status` | — | Store health: workflow load errors/warnings, config parse warnings, providers/roles parse warnings, role resolution per role (provider or refusal reason) |
| `read_traces` | `count?`, `app?`, `outcome_prefix?`, `presentation?`, `situation_contains?`, `verifier_failed?` | Newest-first contentless trace records (JSON), filtered |
| `explain_press` | `trace_id?` (prefix; latest when omitted) | Human-readable walk of one press: routing, tiers, verifier, latency vs SLO, outcome decoded |
| `trace_stats` | — | The `TraceStats` gate report (SLO percentiles, chip top-1, silent/undo/insert-anyway/warm rates, axErrors) |
| `spend_summary` | — | Token spend per role, today / this month, `estimated` flagged |

### Mutating (proposal card, validated before write)

| Tool | Arguments | Validation before any write |
|---|---|---|
| `write_workflow` | `path` (under `workflows/`, `.md`), `content` | `FrontmatterParser` + `WorkflowCardParser.make` + a full-catalog `WorkflowResolver.resolve` simulation with the new content overlaid — duplicate ids, missing/cyclic `extends`, missing intents all reject with the parser's line-numbered message |
| `delete_workflow` | `path` | Path-confined; the proposal warns when other workflows `extends` an id defined in the file, and when the file is in `base/` |
| `write_core_file` | `name` (whitelist: identity.md, writing-style.md, constraints.md, aliases.md, system-prompt.md), `content` | Prose is never rejected; for constraints.md the result reports how many machine-checkable rules `CoreFileStore.parseConstraints` recognized, so a mis-shaped bullet is caught conversationally |
| `set_config` | `values` (key → int, list for `no_cloud`, or null to reset) | The edit is applied to the YAML text (comments preserved), then the result runs through `MagicEngineConfig.parse`; any warning naming a changed key (unknown key, wrong type, out-of-range → clamp) rejects with the range |
| `set_role` | `role`, `provider?`, `fallbacks?`, `timeout_seconds?`, `min_cost_class?` | Role and cost-class enums, timeout 1–600, provider names resolved against providers.yaml; serialized via `RolesFile.serialize` (the codec Settings uses) |
| `set_provider_metadata` | `provider` (name or id), `locality?`, `cost_class?` | Only those two fields — parse providers.yaml, patch, re-serialize via `ProvidersFile.serialize` |

Notably absent, on purpose (see *Cuts* below): no generic write tool, no
key management, no log access beyond traces/spend.

## The safety model

1. **Path confinement.** Every path argument is engine-relative and resolves
   through one gate (`EngineTools.resolve`): absolute paths, `..`, `~`, and
   anything standardizing outside `Constants.Engine.rootDirectory` are
   rejected. Readable files are a whitelist: the four top-level engine files,
   `core/*.md`, `workflows/**.md`. There is no tool that takes an arbitrary
   filesystem path.
2. **Validate with the engine's own parsers, before write.** `write_workflow`
   runs the exact load path (`FrontmatterParser` → `WorkflowCardParser` →
   `WorkflowResolver` over the whole catalog); `set_config` re-parses the
   edited text with `MagicEngineConfig.parse`; `set_role` /
   `set_provider_metadata` go through `RolesFile` / `ProvidersFile`. A
   validation failure returns the line-numbered error to the model as the
   tool result — the file on disk is untouched, and the model gets exactly
   the message a human would see as a Settings badge.
3. **Confirmation cards for every mutation** (§16 rule 5): before→after
   diff, destructive styling for deletes, special warnings for
   `constraints.md` (the verifier's hard rules) and `base/` workflow edits.
   A declined card feeds "User declined" back to the model.
4. **Secrets stay out of reach.** API keys live in Keychain, referenced from
   providers.yaml by id; the assistant can read providers.yaml (which never
   contains keys) and may edit only `locality` and `cost_class`. There is no
   tool that touches Keychain, and no tool that edits a provider's
   `api_key_ref`, endpoint, or OAuth state.
5. **No untrusted content in the writer's context.** Traces are contentless
   *by construction* (`PressTrace` has no content-carrying fields), so the
   debugging tools never inject screen content into a conversation that also
   holds write tools — the §16 "lethal trifecta" separation. This is why the
   full-content debug logs (`logs/debug/`) are deliberately **not**
   readable by any tool.
6. **Store coherence.** After an accepted write the executor pokes the
   owning store (`reloadIfChanged()`), so Settings badges update
   immediately; the press path would have picked the change up anyway via
   mtime on the next press.
7. **No lossy rewrites.** roles.yaml / providers.yaml edits are
   parse-modify-serialize round trips; if the current file contains records
   the lenient parser *skipped* (a broken hand edit), a rewrite would
   silently drop them — so the tool refuses and points at `engine_status`
   until the file is fixed. config.yaml is edited line-wise instead,
   preserving comments and unknown-to-us content.

## How the assistant knows the engine

`AssistantSystemPrompt.build` teaches the model the engine in a compact
reference block: the file tree and each file's responsibility, the workflow
card schema (`id`/`extends`/`priority`/`when:` conditions and their tier
effect/`intents`/`budget`/`output`), the routing tiers and the silent-vs-chips
rule, every config.yaml key with its range and meaning, the role/provider
model (bindings, fallbacks, cost floor, locality, no_cloud), and the trace
vocabulary (fields, outcome strings, verifier check ids).

**Decision (supersedes the original hand-curated-string decision): the
block is single-sourced from the bundled Agent Skill.** The engine
knowledge lives in `Sources/AgentSkill/clipslop/SKILL.md` between
`<!-- engine-reference:begin -->` / `<!-- engine-reference:end -->`
markers; `AgentSkill.engineReference()` extracts that region at prompt
build time and `AssistantSystemPrompt.build` splices it between the
assistant's tool-specific sections (workflow rules, the library tool
model, hard limits — those stay in Swift because they describe *tools*,
not the engine). The same SKILL.md is what Settings → Magic → "Install
Agent Skill…" exports to external agents, so the in-app assistant and an
installed skill can never describe two different engines
(docs/configure/agent-skill.mdx is the user-facing page).

Mechanics worth knowing:

- The region is **agent-agnostic by contract** — files and semantics only,
  no tool names; a test rejects tool names inside it. It weighs ~1.9k
  tokens (the whole assistant prompt ~2.8k, previously ~2.3k).
- Dynamic splices (provider names) stay in `build`.
- Drift protection moved from "acceptable risk" to tests:
  `AgentSkillTests` regenerates the config table from
  `MagicEngineConfig.keyTable()` (the ranges table is now exported for
  exactly this) and the schema key lists from `WorkflowCardParser` /
  `ProvidersFile` / `RolesFile` / `PressTrace`, and asserts the skill's
  markdown names them all. Enforcement still never depends on the prose —
  every write is validated by the engine's own parsers at write time.
- If the bundle resource ever failed to load, the assistant falls back to
  a one-line notice and keeps working off validator messages; a test
  asserts the resource is present so this path stays theoretical.

The output schema is described as the parallel work shapes it:
`output.max_chars` optional per card, falling back to the config default
(`output_max_chars_default`) — nothing in the assistant hard-codes the old
required shape.

## Trace debugging ("why did my press do X")

`TraceInspector` (pure, `nonisolated`) answers the question from trace data
alone:

- `loadTraces(from:)` — decodes every `traces-*.jsonl`, newest first,
  counting undecodable lines (old schema) instead of dropping them.
- `filter(...)` — app / outcome-prefix / presentation / situation /
  verifier-failed filters for `read_traces`.
- `explain(_:)` — renders one trace as a story: the situation (app, host,
  grammar row, field state, selection class and tie), the routing decision
  (tier, counted candidates, why silent — exactly one candidate — or why
  chips — N candidates / classifier tie / forced), the generation (provider,
  model, slot token budget), the verifier verdict with each failed check id
  expanded to what it means (e.g. `length` → "longer than the workflow's
  output.max_chars", `actionableUngrounded` → "actionable data grounded only
  by untrusted screen content"), the latency breakdown against the §3.6
  SLOs, and the outcome string decoded (`dead:*`, `error:generation:*`,
  `focusMismatch`, `:unconfirmed`, …).

The system prompt tells the model to reach for `read_traces` /
`explain_press` whenever the user asks why a press behaved some way, and to
answer from trace evidence rather than speculation.

## The rename: Prompt Assistant → Settings Assistant

User-visible name changes everywhere; persisted identifiers change nowhere.

| Stays (persisted) | Why |
|---|---|
| `KeyboardShortcuts.Name("togglePromptAssistant")` raw value | user-recorded shortcuts are stored under this key in UserDefaults |
| `AssistantWindow` frame autosave name `"AssistantWindow"` | window position persistence |
| `assistantInputHeight` UserDefaults key | input-bar drag height |
| Localization *keys* (`assistant.*`, `onboarding.assistant.*`, …) | only values change; key churn across 17 files buys nothing |
| `chat.assistant` role raw value | persisted in roles.yaml |

Renamed in code: `PromptAssistantService` → `SettingsAssistantService`
(file too), `AppState.promptAssistant` → `AppState.settingsAssistant`, the
`KeyboardShortcuts.Name` *static property* `togglePromptAssistant` →
`toggleSettingsAssistant` (raw value untouched). `PromptLibraryTools` /
`PromptLibraryToolExecutor` keep their names — they really are the
prompt-library subset. Strings: en rewritten, ru/fi translated, the other
14 languages get the English values (the repo's convention for
not-yet-translated copy). Docs: `docs/configure/prompt-assistant.mdx` →
`settings-assistant.mdx` with all inbound links updated.

## Testing

`EngineToolExecutorTests` and `TraceInspectorTests` (swift-testing,
`@Suite`/`@Test`/`#expect`) run every tool against a per-test temp engine
root — the executor takes `root:` and the trace/spend directories in its
initializer precisely so no test can touch the real `~/.clipslop` (or
`-dev`) tree; store references are optional and absent in tests. Covered:
path-confinement rejections, every validation-rejection path (bad
frontmatter with line number, duplicate id, missing `extends`, out-of-range
config value with the range in the message, unknown config key, bad role /
cost class), successful writes producing files the engine parsers load
cleanly, comment preservation in config.yaml edits, and the trace
filter/explanation logic over synthetic traces.

## Cuts (deliberate, V0 of the Settings Assistant)

- **No golden-set run** after workflow edits (§7.1) — the golden-set harness
  doesn't exist yet; schema validation checks form, nothing checks conduct.
- **No provider create/delete, no key entry** — Settings UI only. The
  assistant edits metadata on providers that already exist.
- **No debug-log access** — full-content logs stay human-only (safety model
  #5).
- **No trace date-range arguments** — `read_traces` filters the loaded set;
  retention is already 30 days.
- **No workflow enable/disable toggle** — disabling is expressed by the
  engine as a load error; the assistant edits or deletes files instead.
- **Assistant spend still unreported** — `ToolChatService` returns no usage
  (existing M3 cut); `spend_summary` shows whatever the ledger holds.
- **Prompt library unification (§7.3) not implemented** — only the executor
  seam is shaped for it.
