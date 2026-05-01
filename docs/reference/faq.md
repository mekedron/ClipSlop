---
sidebar_position: 5
title: FAQ
description: Common questions — pricing, privacy, why it's unsigned, how to run fully offline.
---

# FAQ

### Is ClipSlop really free?

Yes. The app is MIT-licensed and free of charge. You only ever pay your AI provider — and the free **ChatGPT sign-in** counts as a zero-cost provider.

### Why isn't ClipSlop signed by Apple?

Because the developer doesn't want to pay Apple's $99/year fee. The source is on GitHub and every release is built by GitHub Actions directly from the public repo, so the binary you download matches the source you can read.

The downside is one-time-per-version friction at install (see [Install & first run](../install.mdx)). The upside is no subscription tax going to Apple.

### Does ClipSlop send my text anywhere?

Only to the AI provider you configured. ClipSlop has **no backend** — there's no Anthropic-hosted server in the loop, no telemetry, no analytics. See [Privacy & data](../guides/privacy-and-data.mdx).

If you want zero network calls, configure [Ollama](../configure/providers/ollama.md) and disable iCloud sync.

### Can I use it offline?

Yes — with [Ollama](../configure/providers/ollama.md). The model runs locally on your machine, no internet needed.

### Why is it called *ClipSlop*?

It's a clipboard tool that produces a slop of AI-transformed text. We named it before we knew what we were building.

### Is there a Windows or Linux version?

No. ClipSlop uses macOS-specific APIs (Accessibility, Vision for OCR) extensively. A port would be a near-rewrite. If you need cross-platform, [WritingTools](https://github.com/theJayTea/WritingTools) is open source and supports Windows + Linux.

### Does it support [Apple Intelligence / MLX / your favourite local model]?

If your local runtime exposes an OpenAI-compatible API (LM Studio, ollama-openai-bridge, etc.), point ClipSlop's [Compatible APIs](../configure/providers/compatible-apis.md) provider at it. Direct integration with Apple's on-device models isn't available yet — they aren't exposed via a public API to third-party menu-bar apps.

### Can I share my prompt library with my team?

Export it as JSON from **Settings → Prompts → … → Export**, share the file, and have teammates import it. Or use [iCloud sync](../configure/icloud-sync.mdx) for your personal Macs.

### Where are my prompts stored?

`~/Library/Application Support/ClipSlop/`. API keys are in the macOS Keychain, not in plain files.

### How do I uninstall?

Drag `ClipSlop.app` to the Trash. Optionally also `rm -rf ~/Library/Application\ Support/ClipSlop` to wipe the prompt library and settings.
