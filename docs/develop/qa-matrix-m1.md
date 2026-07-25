# M1 QA matrix — mechanics gate

Gate (§19): **insert/undo ≥ 95 % across the matrix; unrecovered field-text
loss = 0.** Runs use the user's real logged-in apps, draft/compose surfaces
only; nothing is ever sent (P12 — Enter stays human).

## Protocol per surface

1. **read** — focus the field with representative content around it; DEBUG
   menu → *Magic Dry-Run to Clipboard*; report must show the correct
   field/selection and sane surrounding slots.
2. **insert** — type a short draft, press ⌘⌃M, expected workflow generates
   and the text lands at the caret (or replaces the selection). Repeated ≥ 3×.
3. **undo** — after an insert, toast **Undo**: the field returns to its
   pre-insert state (⌘Z path), or — when ⌘Z can't be trusted — the
   recoverable text is copied. Also probe raw ⌘Z once per surface for the
   R1 table below.
4. **restore-after-loss** — after an insert over a selection, break the
   happy path (switch focus away), then Undo/Restore from the toast: the
   pre-insert text must be recoverable from the clipboard. Zero-loss check.
5. **clipboard** — put a known marker string on the clipboard before the
   press; after the insert settles, the clipboard must hold the marker
   again (transient+concealed write, conditional restore).

Each press also feeds the traces — after a session, DEBUG menu → *Magic
Trace Stats to Clipboard* for warm-hit rate, `axErrors` (R4), and latency
percentiles.

## Results — 2026-07-23 session

| surface | read | insert | undo | restore | clipboard |
|---|---|---|---|---|---|
| TextEdit (native) | ✅ | ✅ 6/6 | ✅ | ⏳¹ | ✅ |
| Gmail (Chrome) | ⏳ | ⏳ | ⏳ | ⏳ | ⏳ |
| LinkedIn (Chrome) | ⏳ | ⏳ | ⏳ | ⏳ | ⏳ |
| Slack | ⏳ | ⏳ | ⏳ | ⏳ | ⏳ |
| X (Chrome) | ⏳ | ⏳ | ⏳ | ⏳ | ⏳ |
| Notion | ⏳ | ⏳ | ⏳ | ⏳ | ⏳ |

¹ restore-after-loss attempt was contaminated by concurrent user activity
(focus flapping); retest in the joint session.

Fixes that fell out of the TextEdit column (2026-07-23):
- **Continuation seam**: `execute()` trimmed the model's leading space, so
  drafts joined as `red.We`. Deterministic `ContinuationSeam.adjust` now
  owns the join (space iff both sides are word material; glue punctuation,
  openers, CJK respected). Verified live.
- **Toast accessibility**: the five toast buttons exposed no AX names
  (plain-style + hosting-view bridge). All toast controls now carry
  `accessibilityLabel` + stable `accessibilityIdentifier`
  (`magic.toast.undo` etc.) — VoiceOver-correct and rig-clickable. Note:
  button order in AX is close, undo, regenerate, copy, refine.
- **`latencyMs.paste`**: `total` is stamped at trace submission (includes
  toast lifetime), which is not the SLO number; presses now also stamp
  press→paste at insert completion. Trace stats prefer it.

## R1 — raw ⌘Z atomicity per surface

| surface | one ⌘Z reverts the whole paste? |
|---|---|
| TextEdit (AppKit) | **atomic** — paste is one undo group (2026-07-23) |
| Gmail compose | ⏳ |
| Notion | ⏳ |

## R4 / R11 measurements

- **R4** (`kAXErrorCannotComplete` frequency): collected automatically as
  `axErrors` in every trace; reported by the trace-stats tool. Numbers TBD
  from the matrix session.
- **R11** (Chromium AX CPU): measured 2026-07-23, fresh Chrome, hostile
  600-mutations/sec page, frontmost: 16.2 % → 19.1 % avg process-tree CPU
  after `AXEnhancedUserInterface` (+~3 pp). Bounded; kill switch
  `warm_observer_enabled` is the control. Details in `magic-button.md`.
