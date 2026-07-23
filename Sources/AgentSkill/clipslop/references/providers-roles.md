# providers.yaml and roles.yaml — full reference

Workflows never name models. A workflow runs under a **role**, the role
resolves to a **provider** — both mappings are files in `~/.clipslop/`.
Both stores reload on mtime (press-time and on Settings open).

These two files are round-tripped by the app: Settings edits re-serialize
them. Hand edits are supported and validated leniently — a broken record
is **skipped with a warning naming the line**, never a silent drop of the
whole file. Before overwriting a providers.yaml that parses to an empty
list, the app preserves it as `providers.yaml.broken`. The pre-migration
JSON originals are kept as `.bak` files. Leave `.bak`/`.broken` files
alone — they are the user's recovery path.

## providers.yaml

```yaml
---
providers:
  - id: 6F9619FF-8B86-D011-B42D-00C04FC964FF   # UUID, stable identity
    name: "My Anthropic"
    type: anthropic
    model: "claude-sonnet-4-5"
    max_tokens: 4096
    temperature: 0.7
    default: 1
    locality: cloud
    cost_class: premium
---
```

Record keys:

| Key | Required | Semantics |
|---|---|---|
| `id` | yes | UUID. The provider's stable identity — roles.yaml and library-card `provider:` overrides reference it. Duplicates are skipped. |
| `name` | no | Display name (defaults to the type's display name). |
| `type` | yes | `openAIChatGPT` \| `openAI` \| `anthropic` \| `ollama` \| `openAICompatible` \| `cliTool`. |
| `base_url` | no | Endpoint override (Ollama host, OpenAI-compatible server, …). |
| `api_key_ref` | no | Keychain reference key — **never a secret, and never yours to touch**. Written only when it differs from the default `clipslop.api-key.<id>`. Do not create, edit, or move it. |
| `model` | no | Model id sent to the API. |
| `max_tokens` | no | Response token cap (integer). |
| `temperature` | no | Sampling temperature (number). |
| `reasoning_effort` | no | For reasoning models; omitted = provider default. |
| `default` | no | `1`/`true` marks the app-default provider. More than one → first kept, warning. |
| `locality` | no | `local` \| `cloud`. **The data path**, not where the binary runs: a CLI tool that calls a cloud API is `cloud`. Derived from type/base_url when omitted — only provably local endpoints (e.g. Ollama on localhost) derive `local`. Set it explicitly only when the derivation is wrong. |
| `cost_class` | no | `local` \| `mid` \| `premium`. Coarse spend/quality class; derived when omitted. |

Secrets never appear in this file: API keys live in the macOS Keychain
referenced by provider id; OAuth state (ChatGPT sign-in) stays
app-internal. There is no legitimate reason for an agent to edit anything
here beyond `locality` and `cost_class`; creating providers or entering
keys is done by the user in Settings.

## roles.yaml

```yaml
---
roles:
  - role: generation.magic
    provider: 6F9619FF-8B86-D011-B42D-00C04FC964FF
    fallbacks: [0A8F6B21-3C44-4E55-9B66-77D888E99F00]
    timeout_seconds: 30
    min_cost_class: mid
---
```

Record keys:

| Key | Required | Semantics |
|---|---|---|
| `role` | yes | `generation.magic` (the Magic Button) or `chat.assistant` (the in-app Settings Assistant). Duplicates: first record kept. |
| `provider` | no | Provider id (UUID) bound to the role. |
| `fallbacks` | no | Provider ids tried in order after the bound provider. |
| `timeout_seconds` | no | 1–600; stamped onto each request for this role. |
| `min_cost_class` | no | `local` \| `mid` \| `premium`. A cost **floor**: when nothing at or above it is available in the chain, the role **refuses generation instead of silently downgrading**. |

## Resolution order

For a role, candidates are tried in this order, skipping any provider that
lacks a required capability (tool calling for `chat.assistant`):

1. the bound `provider`
2. each of `fallbacks`, in order
3. the app default provider (`default: 1` in providers.yaml)
4. the first (capable) provider in the list

`min_cost_class` filters **last** — a qualified chain that only has
too-cheap providers refuses rather than downgrading.

## Privacy binding (`no_cloud`)

The `no_cloud` list in config.yaml interacts with this layer: a press on a
matching app/domain swaps to a `locality: local` provider from the role's
chain, or refuses with trace outcome `error:generation:noCloud`. The cost
floor still holds during the swap. This is why `locality` must be honest —
marking a cloud-backed provider `local` would leak protected surfaces to
the cloud.

## Spend

Every generation appends one contentless line to
`~/.clipslop/logs/spend-YYYY-MM.jsonl` (see `traces.md`) — tokens only, no
dollar tables. Settings → Providers shows per-role today/month totals.
