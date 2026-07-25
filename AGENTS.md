# ClipSlop — agent notes

macOS menu-bar app: library prompts on system-wide hotkeys, plus the Magic
Button (⌘⌃M) driven by a file-based engine at `~/.clipslop/`.

## Build & run

```
swift build
swift test                  # 9 failures without ANTHROPIC_API_KEY /
                            # CHATGPT_ACCESS_TOKEN are expected
./Scripts/run-debug.sh      # build + codesign + relaunch
./Scripts/check-localizations.sh
```

Always launch via `run-debug.sh` (or `Scripts/codesign.sh` first) — an
unsigned rebuild re-prompts for Keychain and Accessibility every time.
Rebuild and relaunch after changing app code.

## Comments: state the invariant, not its history

Global rule, repeated here because this codebase is why it was written.

Don't write "this **used to** …", "the **old** check was …", "**before**
this fix …", "**now that** X, …", or the story of a review round. Write the
rule the code obeys, present tense, plus the hazard it exists for.

```swift
// BAD  — decays the moment the code moves
// The old test was role + value alone, which every empty composer in the
// window satisfies, so a field focused during generation took the paste.

// GOOD — the invariant, and why it has to be this strong
// Corroboration must be strong enough that a DIFFERENT field cannot supply
// it: role and window title, then frame or a distinctive value. An empty
// value matches every empty composer.
```

Most relevant in `Sources/Services/Magic/` and `Sources/Engine/`, where the
comments are genuinely load bearing: why a guard is asymmetric is worth
three paragraphs, the incident that prompted it none.

## Layout & conventions

- `Sources/Engine/` — pure logic (parser, router, assembler, verifier,
  provider layer). Keep decisions `nonisolated` and pure so they stay
  testable without AppKit.
- `Sources/Services/Magic/` — the press band; every safety invariant lives
  here. AX and bulk pasteboard I/O stay **off the main actor** (synchronous
  cross-process IPC, 0.35 s per-call timeout).
- `EngineTools.confine` is a security boundary.
- `~/.clipslop/` (`-dev` in debug) is user-owned, hand-edited and
  hot-reloaded — parse defensively: a typo gets a warning and a safe
  fallback, never a crash or a silent drop.
- `prompts.json` is a derived mirror of `workflows/library/**`; never edit
  it directly. API keys live in the Keychain, never in the engine tree.
- New user-facing strings need keys in all 17 `.lproj` files.
- Conventional commits.
