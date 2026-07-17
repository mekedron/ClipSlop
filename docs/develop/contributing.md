---
sidebar_position: 3
title: Contributing
description: How to get a working development setup, what we want help with, and the unwritten rules of this codebase.
---

# Contributing

ClipSlop is small enough that a tour of `Sources/` and `Tests/` is the fastest way in. This page is for people who want to push commits.

## Getting set up

See [Building from source](./building-from-source.md) for the prerequisites and a clone-build-test cycle.

## What we want help with

In rough priority:

1. **Bug fixes with regression tests.** A reproducer in `Tests/` is more valuable than the fix itself.
2. **More built-in prompts.** Especially translation languages, code-language-specific Dev prompts, and recipes that need their own pre-baked chain.
3. **Provider integrations.** New OpenAI-compatible APIs go in `Sources/Services/Providers/`. The existing files are a good template.
4. **Accessibility audits.** Keyboard-only flows should keep working with VoiceOver and Full Keyboard Access.
5. **Documentation.** Spotted something wrong, missing, or fuzzy on this site? Edit the file and open a PR — every doc page has an *Edit on GitHub* link.

## What we don't want

- **Telemetry / analytics PRs.** No.
- **Required-account features.** ClipSlop is local-first; nothing should require a ClipSlop account because there *is no* ClipSlop account.
- **Bundling our own AI.** We integrate with providers, we don't ship a model.
- **Major UI rewrites without a discussion.** Open an issue first — the keyboard-first / single-key-mnemonic surface is load-bearing, and it's very easy to break it accidentally.

## Code style

- Swift Concurrency over Combine where possible.
- Domain types in `Models/`, IO in `Services/`, UI in `Views/`. Don't mix.
- Tests in `Tests/<MirrorOfSourcesFolder>/`. Use real types, not mocks, where the real type is small.
- Keep `Sources/` files under ~400 lines. Extract a sibling file before letting one grow.

## License

By contributing, you agree your code ships under the project's [MIT License](https://github.com/mekedron/ClipSlop/blob/main/LICENSE). No CLA — the MIT terms are short, sufficient, and well-understood.

## Releases & signing

The release pipeline lives in `.github/workflows/release.yml`. Official releases are signed with a Developer ID certificate and notarised with Apple — see [FAQ → Is ClipSlop signed by Apple?](../reference/faq.md#is-clipslop-signed-by-apple).

Signing is gated on the `HAS_SIGNING` condition, which is true only when the `MACOS_CERTIFICATE_P12_BASE64` and `MACOS_NOTARY_KEY_P8_BASE64` secrets are present. **Forks don't inherit those secrets**, so a release build from your fork falls back to an ad-hoc signature and Gatekeeper will refuse it. That's expected — it only affects your own fork's artifacts, never the releases published from this repo.

## Asset asks

The [design notes](https://github.com/mekedron/ClipSlop/tree/main/docs-site) flag a few visual assets we'd like:

- A transparent-bg, square-cropped app icon at 26 / 30 / 56 px for use in the brand mark.
- Annotated screenshots of the panel with a consistent macOS chrome and drop shadow, max 720 px wide.
- Monochrome SVG provider logos.

If illustration / icon work is your thing, this is a low-stakes way to make the docs site noticeably better.
