# Traces, spend, and the debug log — field vocabulary

## traces-YYYY-MM-DD.jsonl (always on, contentless)

One JSON object per line, one line per Magic Button press, in
`~/.clipslop/logs/`. Daily files, retained 30 days. **Contentless by
construction**: the record has no fields that could carry field text,
generated output, surrounding content, window titles, or full URLs — only
the URL host survives. Old lines that predate newer fields decode with
those fields absent — count them, never assume every line has every key.

| Field | Type | Meaning |
|---|---|---|
| `ts` | ISO-8601 date | Press timestamp. |
| `traceID` | UUID | Links the trace to its debug-log file (when enabled). |
| `situationClass` | string | Routed situation label, `unrouted` when routing never ran. |
| `appBundleID` | string? | Frontmost app at press time. |
| `urlHost` | string? | Host only — never the full URL. |
| `grammarRow` | string | Interaction-grammar row (empty field / draft / selection / non-editable). |
| `fieldState` | string | `empty` \| `draft` \| `selection`. |
| `selectionClass` | string? | Classifier's top class: `instruction` \| `material` \| `mixed`. |
| `selectionWasTie` | bool? | Classifier could not decide — forces chips. |
| `tier` | string | `exact` \| `domain` \| `base` \| `none`. |
| `candidateIDs` | [string] | Workflow ids counted at the winning tier (after intent dedup). |
| `chosenID` | string? | The workflow that ran. |
| `presentation` | string | `silent` \| `chips` \| `chips_forced`. |
| `chipIndexChosen` | int? | 0-based index of the chip the user picked — the ground truth for chip top-1 accuracy. |
| `hintUsed` | bool | Free-text hint typed in the chip panel. |
| `slotTokens` | {string: int} | Estimated tokens per prompt slot (pinned, workflow, few_shot, surrounding, field_input). |
| `totalTokens` | int | Estimated total prompt tokens. |
| `providerType` | string? | Provider type that served the call. |
| `modelID` | string? | Model id. |
| `verifierPassed` | bool? | Overall verifier verdict (null = never got there). |
| `verifierChecks` | [string] | **Failed** check ids only, never the warning text. Values: `language`, `length`, `constraints`, `concreteness`, `actionableUngrounded`. |
| `warmHit` | bool | Warm observer had fresh cheap context for this press — the observer's hit-rate health metric. |
| `axErrors` | int | `kAXErrorCannotComplete` count during capture — accessibility trouble on this surface. |
| `latencyMs` | object | Breakdown, see below. |
| `outcome` | string | How the press ended, see below. |

### `latencyMs` fields

| Field | Meaning |
|---|---|
| `snapshot` | Screen capture (collector). High → collector budgets/deadline in config.yaml, or a hostile surface (check `axErrors`). |
| `route` | Routing decision (should be ~0). |
| `assemble` | Prompt assembly. |
| `generate` | The single model call. Usually dominates — provider/model choice. |
| `verify` | Deterministic verifier (< 50 ms by design). |
| `paste` | **Press → paste landed. The SLO number**: direct presses target p50 ≤ 3000, p95 ≤ 6000. Absent on presses that never inserted and on old lines. |
| `total` | Press → outcome stamped. Includes toast lifetime and user think time — NOT the SLO number; do not confuse it with `paste`. |

### `outcome` values

| Value | Meaning |
|---|---|
| `inserted` | Pasted into the field, verifier clean. |
| `insertedAnyway` | User held "Insert anyway" past a verifier warning (rate is a guard-health metric). |
| `panelOnly` | Result delivered to toast + clipboard only (non-editable target). |
| `focusMismatch` | Focus changed between snapshot and paste — never blind-pasted; result went to toast + clipboard. |
| `regenerated` | User pressed regenerate/refine; a new generation followed (same trace lineage). |
| `cancelled` | User cancelled during generation. |
| `copied` | User copied the result instead of inserting. |
| `dismissed` | Toast dismissed without acting. |
| `undone` | User undid the insertion. |
| `dead:<reason>` | Press was dead on arrival (secure field, no field, …). |
| `error:generation:<kind>` | Generation failed; `<kind>` includes `noCloud` (privacy binding refused), provider errors, `costFloor` refusals. |
| `…:unconfirmed` suffix | The paste could not be verified by watching the field's value (some fields are unreadable — Mail's web area). |

### Reading traces well

- Newest lines are at the end of the newest file; press = one line even
  when it ends in an error.
- "Why chips?" → `presentation` + `candidateIDs` (N counted candidates)
  + `selectionWasTie`.
- "Why this workflow?" → `tier` + `chosenID` + the cards' `when:`/
  `priority`. Remember: highest tier counted, primary-intent dedup.
- "Why flagged?" → `verifierChecks`; `constraints` points at
  core/constraints.md; `length` at the card's `output.max_chars` or
  `output_max_chars_default`; `actionableUngrounded` means actionable data
  (money, IBAN, email, phone, commitment dates) was grounded only by
  untrusted screen content.
- Quality gates the project watches: silent-rate, chip top-1 rate
  (target ≥ 70 %), undo rate, insert-anyway rate, warm-hit rate, axErrors.

## spend-YYYY-MM.jsonl (always on, contentless)

One JSON line per generation, monthly files:

| Field | Meaning |
|---|---|
| `ts` | ISO-8601 timestamp. |
| `role` | Engine role (`generation.magic`, `chat.assistant`). |
| `provider` | Provider type string. |
| `model` | Model id. |
| `inputTokens` / `outputTokens` | Token counts. |
| `estimated` | `true` when the API reported no usage and counts are chars/4 estimates (ChatGPT SSE path, CLI tools). |

## logs/debug/ (opt-in, full content, 7-day prune)

Enabled by `debug_log_enabled: 1` in config.yaml (same switch as the
Settings → Magic checkbox). One markdown file per press,
`press-<yyyy-MM-dd-HHmmss>-<traceID-prefix>.md`, containing the FULL
story: the snapshot (field value, selection, surroundings, ancestor AX
roles, window/URL), classification signals, routing decision, the verbatim
assembled prompt, the raw model output, the verifier verdict, and any
error. **These files contain the user's real screen content and drafts** —
that is the point, and the risk. Enable only with explicit user consent,
and prefer switching it back off after the investigation. Files are pruned
automatically after 7 days; deleting them earlier is always safe.
