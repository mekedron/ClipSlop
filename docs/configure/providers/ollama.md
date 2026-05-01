---
sidebar_position: 4
title: Ollama (local)
---

# Ollama

Run everything locally. No data leaves your Mac, no API costs.

## Setup

1. Install [Ollama](https://ollama.com).
2. Pull a model:
   ```bash
   ollama pull llama3.2
   ```
3. Make sure the Ollama server is running (the menu-bar app handles this).
4. In ClipSlop, open **Settings → Providers** → **Ollama**.
5. Confirm the host (`http://localhost:11434` by default) and pick a model.

ClipSlop will list every model Ollama has pulled.

## Recommended models for this workload

ClipSlop transformations are short, single-shot, and benefit from instruction-following more than raw size. Good starting points:

- **`llama3.2`** (3B / 8B) — solid baseline for grammar, formatting, summarising.
- **`qwen2.5`** (7B / 14B) — strong on translation, especially Asian languages.
- **`phi3`** — small, fast, good for grammar fixes when you want minimum latency.
- **`mistral-nemo`** — wide language coverage, good for Rewrite tasks.

For coding-focused prompts (`Dev → Beautify Code`, `Explain Stack Trace`), try a code-specialised model like `deepseek-coder` or `qwen2.5-coder`.

## Trade-offs

- ✅ Private. Nothing leaves your Mac.
- ✅ Free.
- ⚠️ Slower than cloud APIs unless you have a beefy GPU.
- ⚠️ Quality is below frontier models. Expect more retries on nuanced rewrites.

## Mixing providers

You can mix Ollama with cloud providers per prompt. E.g. Fix Grammar on Ollama, Translate on Claude.
