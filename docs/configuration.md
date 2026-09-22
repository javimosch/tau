# tau Configuration Reference

Complete reference for every way to configure tau: the config file, environment
variables, CLI flags, and the precedence rules that tie them together.

Resolution model: **CLI flags > environment > config file > in-code defaults.**
The config file is loaded first as the base, then command-line flags override it.
Each section below lists the exact precedence order used by the code.

---

## Config file

Path: `~/.config/tau/config.json` (built from `$HOME`).

The file is **optional** — tau runs fine without it. Behavior on load:

- Missing file, unreadable file, or unset `HOME` → all defaults are used.
- Invalid JSON → a warning is printed to stderr and defaults are used; tau does
  not exit. Fix the syntax or delete the file.
- Unknown keys are ignored silently, so the file is forward-compatible.
- Keys set in the file become the *base* config; any matching CLI flag
  overrides them for that invocation.

### All supported keys

| Key | Type | Default | CLI equivalent | Notes |
|-----|------|---------|----------------|-------|
| `provider` | string | `"xiaomi"` | `--provider <name>` | Must match a name in the [provider table](#providers). |
| `model` | string | provider's default model | `--model <id>` | See [model precedence](#provider-model-and-endpoint). |
| `api_key` | string | — | `--api-key <key>` | Global fallback key; sits *below* per-provider `keys` in precedence. |
| `keys` | object | — | — | Per-provider keys: `{"openai": "sk-...", "deepseek": "..."}`. Non-string values are skipped. |
| `mode` | `"text"` \| `"json"` | `"json"` | `--mode <text\|json>` | Unrecognized values are ignored (stays `json`). |
| `stream` | bool | `true` | `--stream` / `--no-stream` | SSE token streaming; `--no-stream` for batch. |
| `thinking` | bool | `false` | `--thinking` | Emit reasoning/thinking chunks. |
| `debug` | bool | `false` | `--debug` | Perf stats + tool I/O on stderr. |
| `temperature` | float | `0.7` | `--temperature <f>` | Sampling temperature. |
| `max_tokens` | int | — (uncapped) | `--max-tokens <n>` | Output token cap. |
| `timeout_ms` | int | `120000` | `--timeout-ms <n>` | HTTP request timeout in milliseconds. |
| `context_window` | int | per-provider (`256000` fallback) | `--context-window <n>` | Token capacity used for the compaction threshold. |
| `auto_compact` | bool | `true` | `--no-compact` | Auto-compact history when it grows too large. |
| `compact_threshold` | float | `0.5` | `--compact-threshold <f>` | Fraction of `context_window` that triggers compaction. |
| `compact_keep_recent_tokens` | int | `20000` | `--compact-keep-recent <n>` | Recent tokens kept verbatim during compaction. |
| `goal_max_iterations` | int | `50` | `--goal-max-iterations <n>` | Per-run agentic loop cap in `/goal` mode. |
| `goal_max_continues` | int | `500` | — | Cross-invocation continuation cap for goal mode. |

### Example

```json
{
  "provider": "openai",
  "model": "gpt-4o-mini",
  "mode": "json",
  "stream": true,
  "temperature": 0.4,
  "timeout_ms": 180000,
  "auto_compact": true,
  "compact_threshold": 0.5,
  "compact_keep_recent_tokens": 20000,
  "keys": {
    "openai": "sk-...",
    "deepseek": "sk-..."
  }
}
```

Not everything is file-configurable. Flag-only settings include `--session`,
`--system-prompt` / `--append-system-prompt`, `--tools` / `--exclude-tools` /
`--no-tools`, `--dry-run`, `--role`, `--schema`, `--max-iterations`, and the
AGENTS.md flags (`--scan-agents`, `--load-agents-md`, `--auto-agents-md`).
See `tau --help` or `tau --help-json` for the full flag list.

---

## Providers

tau supports OpenAI-compatible chat-completions endpoints. The built-in
provider table (also visible via `tau models`):

| Provider | Endpoint | Env var(s), tried in order | Default model | Context window |
|----------|----------|----------------------------|---------------|----------------|
| `xiaomi` (default) | `https://token-plan-ams.xiaomimimo.com/v1/chat/completions` | `XIAOMI_API_KEY`, then `PIZIG_API_KEY` | `mimo-v2.5` | 256,000 |
| `openai` | `https://api.openai.com/v1/chat/completions` | `OPENAI_API_KEY` | `gpt-4o-mini` | 128,000 |
| `deepseek` | `https://api.deepseek.com/v1/chat/completions` | `DEEPSEEK_API_KEY` | `deepseek-chat` | 65,536 |
| `opencode-go` | `https://opencode.ai/zen/go/v1/chat/completions` | `OPENCODE_API_KEY` | `deepseek-v4-flash` | 204,800 |

No provider currently ships a built-in key — supply one via any of the
mechanisms below. An unknown provider name is rejected with exit code `80`.

---

## Environment variables

### Read by tau itself

| Variable | Purpose |
|----------|---------|
| `TAU_API_KEY` | Fallback API key, used after provider-specific env vars. |
| `TAU_ENDPOINT` | Overrides the provider's endpoint URL (works for chat and `tau acp`). Useful for proxies, gateways, and local OpenAI-compatible servers. |
| `XIAOMI_API_KEY`, `PIZIG_API_KEY` | API keys for the `xiaomi` provider (tried in that order). |
| `OPENAI_API_KEY` | API key for the `openai` provider. |
| `DEEPSEEK_API_KEY` | API key for the `deepseek` provider. |
| `OPENCODE_API_KEY` | API key for the `opencode-go` provider. |
| `HOME` | Root of all tau state: `~/.config/tau/` and `~/.agents/skills/`. If unset, config file, sessions, fleets, skills, and the ACP daemon are all disabled. |

### Read by the a2a-spawn launcher (not tau)

The [a2a-spawn](https://github.com/javimosch/a2a-skill) script launches tau as
a peer on the a2a message bus and translates these into CLI flags:

| Variable | Default | Effect |
|----------|---------|--------|
| `TAU_TOOLS` | `bash` | Passed to `--tools` (e.g. `TAU_TOOLS="bash,read"`). |
| `TAU_THINKING` | `0` | `1` adds `--thinking`. |
| `TAU_DEBUG` | `0` | `1` adds `--debug`. |
| `TAU_BIN` | auto-detect | Path to the tau binary (skips PATH resolution). |

---

## Precedence rules

### API key resolution

`resolveApiKey` returns the **first non-empty** value found, in this order:

1. `--api-key` flag
2. Config file `keys["<provider>"]` — per-provider key for the selected provider
3. Provider env var(s), in the order listed in the provider table
   (e.g. `XIAOMI_API_KEY` before `PIZIG_API_KEY`)
4. Config file `api_key` — the global key
5. `TAU_API_KEY` environment variable
6. Provider built-in key (none currently defined)

Empty strings are skipped at every level. If nothing resolves, the request
fails with exit code `106` (auth failed).

### Provider, model, and endpoint

**Provider** — first match wins:

1. `--provider <name>`
2. `provider/` prefix inside `--model provider/id` — but only when `--provider`
   was *not* given. With both flags, `--provider` wins the provider half and
   the `--model` prefix contributes only the model id.
3. Config file `provider`
4. Default: `xiaomi` (first entry in the provider table)

**Model**:

1. `--model <id>` (the part after `/` when the `provider/id` form is used)
2. If the provider was changed via CLI, the *new* provider's `default_model` —
   a config-file model tied to the old provider is not carried over
3. Config file `model` (sticky once set)
4. The resolved provider's `default_model`

**Endpoint**:

1. `TAU_ENDPOINT` env var — always wins when non-empty
2. The resolved provider's built-in endpoint

There is no config-file key or CLI flag for the endpoint.

### Context window

1. `--context-window <n>`
2. Config file `context_window`
3. The resolved provider's `context_window` (`256000` when unknown)

### Compaction

`auto_compact` is on unless `--no-compact` or `"auto_compact": false`. When
estimated history exceeds `compact_threshold × context_window`, older turns
are summarized and the most recent `compact_keep_recent_tokens` tokens are
kept verbatim. Each knob is independently overridable by flag, then config
file, then default.

### Boolean flags

Boolean config keys (`stream`, `thinking`, `debug`, `auto_compact`) accept
`true`/`false` in the file. On the CLI, only explicit flags toggle them —
e.g. `--stream` re-enables streaming when the config file set
`"stream": false`, and `--no-compact` disables compaction when the file left
it on. There are no `--no-thinking`/`--no-debug` flags.

---

## Storage paths

All paths derive from `$HOME`:

| Path | Purpose |
|------|---------|
| `~/.config/tau/config.json` | This config file |
| `~/.config/tau/sessions/<name>.json` | `--session` conversation + goal state |
| `~/.config/tau/fleets/<id>.json` | Fleet manifests (spec + per-item status) |
| `~/.config/tau/acp.sock` | Default ACP daemon Unix socket |
| `~/.config/tau/acp.pid` | ACP daemon PID file |
| `~/.config/tau/acp.log` | ACP daemon log |
| `~/.agents/skills/<name>/SKILL.md` | Skills discovered by `tau skills` |
