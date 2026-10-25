# tau config file reference

<!-- GENERATED FILE — do not edit by hand.
     Source of truth: `tau config schema` output (canonical copy:
     schema/tau-config.schema.json, generated from FileConfig in
     src/configfile.zig via src/configschema.zig).
     Regenerate:  python3 scripts/gen-config-doc.py
     Drift check: python3 scripts/gen-config-doc.py --check
     (the config-doc smoke group runs the drift check) -->

Schema for ~/.config/tau/config.json — a JSONC file (// and /* */ comments allowed). Every key is optional; `tau config validate` reports unknown keys.

This table is generated from that schema, so it cannot drift from the
keys the loader accepts.

This is the key-by-key reference. For the full configuration guide —
environment variables, CLI-flag equivalents, and precedence rules — see
[docs/configuration.md](configuration.md). Resolution model:
**CLI flags > environment > config file > in-code defaults.**

## Keys

| Key | Type | Constraints | Description |
|-----|------|-------------|-------------|
| `$schema` | `string` | — | Editor hint pointing at this schema. Written by `tau init`; accepted but ignored by the loader. |
| `provider` | `string` | one of `xiaomi` \| `openai` \| `deepseek` \| `opencode-go` | Active provider name — selects the API endpoint and default model. TAU_ENDPOINT overrides the endpoint. |
| `model` | `string` | — | Model id, or 'provider/id' shorthand. Defaults to the provider's default model. |
| `api_key` | `string` | non-empty | Global API key — used only when no keys[] entry or provider env var matches. Stored in plaintext; prefer env vars. |
| `keys` | `object` | member names: `xiaomi` \| `openai` \| `deepseek` \| `opencode-go`; values: non-empty strings | Per-provider API keys — an entry outranks that provider's env var and the global api_key. |
| `mode` | `string` | one of `text` \| `json` | Output format for results: 'json' (agent-friendly envelopes) or 'text' (human-readable prose). |
| `stream` | `boolean` | — | Stream responses token-by-token (SSE). |
| `thinking` | `boolean` | — | Emit reasoning/thinking chunks alongside the response. |
| `debug` | `boolean` | — | Write perf stats and tool I/O diagnostics to stderr. |
| `temperature` | `number` | `>= 0` | Sampling temperature. |
| `max_tokens` | `integer` | `0..4294967295` | Cap on output tokens per response. |
| `timeout_ms` | `integer` | `>= 0` | HTTP request timeout in milliseconds. |
| `context_window` | `integer` | `0..4294967295` | Token capacity used for the auto-compaction threshold; defaults to the provider's context window. |
| `auto_compact` | `boolean` | — | Auto-compact history when estimated tokens exceed compact_threshold of context_window. |
| `compact_threshold` | `number` | `0..1` | Fraction of context_window that triggers auto-compaction. |
| `compact_keep_recent_tokens` | `integer` | `0..4294967295` | Recent tokens kept verbatim through compaction. |
| `goal_max_iterations` | `integer` | `0..4294967295` | Per-run agentic loop cap in /goal mode. |
| `goal_max_continues` | `integer` | `0..4294967295` | Cross-invocation continuation cap for goal mode. |

## Example

```jsonc
{
  // Every key is optional — set only what you need. JSONC comments
  // like these are allowed in the real file.
  "$schema": "https://raw.githubusercontent.com/javimosch/tau/master/schema/tau-config.schema.json",
  "provider": "openai",
  "model": "gpt-4o-mini",
  "api_key": "sk-...",
  "keys": {"openai": "sk-...", "deepseek": "sk-..."},
  "mode": "json",
  "stream": true,
  "thinking": false,
  "debug": false,
  "temperature": 0.7,
  "max_tokens": 4096,
  "timeout_ms": 120000,
  "context_window": 256000,
  "auto_compact": true,
  "compact_threshold": 0.5,
  "compact_keep_recent_tokens": 20000,
  "goal_max_iterations": 50,
  "goal_max_continues": 500
}
```

## Validating and inspecting

- `tau config validate [file]` — reports unknown keys, wrong types, and
  out-of-range values against this schema (defaults to the real config).
- `tau config schema` — prints the JSON Schema this table is generated
  from. The canonical copy editors fetch is checked in at
  [schema/tau-config.schema.json](../schema/tau-config.schema.json);
  `tau init` writes its URL as the `$schema` key so autocomplete works
  out of the box — per-editor setup: [docs/editors.md](editors.md).

## Regenerating

After changing `FileConfig` or its schema metadata in
`src/configschema.zig`:

```sh
zig build && ./zig-out/bin/tau config schema > schema/tau-config.schema.json
python3 scripts/gen-config-doc.py
```

`--check` regenerates in memory and exits non-zero when this file is
stale; the `config-doc` smoke group
(`scripts/smoke.sh --group config-doc`) runs it, and `zig build test`
asserts every key row and description appears here verbatim.
