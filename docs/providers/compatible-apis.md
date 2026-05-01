---
sidebar_position: 5
title: OpenAI-compatible APIs
---

# OpenAI-compatible APIs

Any provider that speaks the OpenAI Chat Completions protocol works with ClipSlop. Common targets:

- **[OpenRouter](https://openrouter.ai)** — single key, hundreds of models from different vendors.
- **[LM Studio](https://lmstudio.ai)** — local model runner with an OpenAI-compatible HTTP server.
- **[Together](https://www.together.ai)**, **[Groq](https://groq.com)**, **[Fireworks](https://fireworks.ai)** — cloud inference platforms.
- **Self-hosted** — vLLM, Text Generation Inference, or any server exposing `/v1/chat/completions`.

## Setup

1. Open **Settings → Providers** → **OpenAI-compatible**.
2. Set:
   - **Base URL** — e.g. `https://openrouter.ai/api/v1` or `http://localhost:1234/v1` for LM Studio.
   - **API key** (if the endpoint requires one).
   - **Model** — pick or type the model identifier.
3. Click **Test connection**.

## CLI providers

ClipSlop also supports invoking command-line tools as providers. Useful for:

- `claude` CLI on a developer Mac.
- `gemini` CLI.
- Any custom script that takes a prompt on stdin and emits the response on stdout.

Configure the binary path and arguments in **Settings → Providers → CLI**.

## When to use this vs the dedicated providers

| Scenario                                | Use                       |
|-----------------------------------------|---------------------------|
| ChatGPT Plus / Pro / Team account       | [Sign in with ChatGPT](./chatgpt.md) |
| OpenAI API key                          | [OpenAI API](./openai-api.md)        |
| Anthropic API key                       | [Anthropic](./anthropic.md)          |
| Local on the same Mac                   | [Ollama](./ollama.md) or LM Studio   |
| Multiple vendors via one key            | OpenRouter (this page)               |
| Specialised hosting (Groq, Fireworks…)  | This page                            |
