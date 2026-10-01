# Provider credentials & auth troubleshooting

How tau authenticates with each LLM provider, where it looks for API keys,
and how to fix `AuthFailed` (exit 106) errors.

Every `{"err":...}` envelope with `"code":106` links back to this page via its
`docs` field — agents can follow it programmatically.

## Provider table

| Provider | Endpoint | Env var(s), tried in order | Default model | Context window |
|----------|----------|----------------------------|---------------|----------------|
| `xiaomi` (default) | `https://token-plan-ams.xiaomimimo.com/v1/chat/completions` | `XIAOMI_API_KEY`, `PIZIG_API_KEY` | `mimo-v2.5` | 256000 |
| `openai` | `https://api.openai.com/v1/chat/completions` | `OPENAI_API_KEY` | `gpt-4o-mini` | 128000 |
| `deepseek` | `https://api.deepseek.com/v1/chat/completions` | `DEEPSEEK_API_KEY` | `deepseek-chat` | 65536 |
| `opencode-go` | `https://opencode.ai/zen/go/v1/chat/completions` | `OPENCODE_API_KEY` | `deepseek-v4-flash` | 204800 |

`tau models` prints this table as JSON. An unknown provider name is rejected
with exit code `80` before any key lookup happens.

All providers speak the OpenAI-compatible `POST /chat/completions` protocol
and authenticate with `Authorization: Bearer <key>`. `TAU_ENDPOINT` overrides
the endpoint for any provider — useful for proxies, gateways, and local
OpenAI-compatible servers (see [configuration.md](configuration.md)).

## Where tau looks for a key

tau resolves a credential by walking this chain — first hit wins, **empty
values are skipped at every level**:

| Order | Source | Example |
|-------|--------|---------|
| 1 | `--api-key` flag | `tau --api-key sk-... "hi"` |
| 2 | config `keys["<provider>"]` | `{"keys": {"openai": "sk-..."}}` in `~/.config/tau/config.json` |
| 3 | provider env var(s) | `OPENAI_API_KEY`, `XIAOMI_API_KEY`, … (table above, tried in order) |
| 4 | config global `api_key` | `{"api_key": "sk-..."}` in `~/.config/tau/config.json` |
| 5 | `TAU_API_KEY` env var | `export TAU_API_KEY=sk-...` |
| 6 | provider builtin key | no shipped provider has one today |

The same chain is used by `tau` runs, `tau fleet run` (the coordinator's key),
and `tau acp serve`. Two consequences worth knowing:

- A stale `keys["<provider>"]` or `api_key` in `config.json` **silently
  outranks** `TAU_API_KEY` (levels 2 and 4 beat level 5).
- `--api-key` beats everything — use it to test whether a config/env key is
  the problem.

## Per-provider setup

Each example exports the provider's env var and runs a smoke prompt. To make a
provider the default, put `"provider": "<name>"` in
`~/.config/tau/config.json` instead of passing `--provider` every time —
or use the `--model <provider>/<id>` shorthand to switch per call.

### xiaomi (default)

```bash
export XIAOMI_API_KEY="..."    # PIZIG_API_KEY is accepted as a fallback name
tau --mode text "say hi"       # default model: mimo-v2.5
```

### openai

```bash
export OPENAI_API_KEY="sk-..."
tau --provider openai --mode text "say hi"     # default model: gpt-4o-mini
tau --model openai/gpt-4o --mode text "say hi" # provider/id shorthand
```

### deepseek

```bash
export DEEPSEEK_API_KEY="sk-..."
tau --provider deepseek --mode text "say hi"   # default model: deepseek-chat
```

### opencode-go

```bash
export OPENCODE_API_KEY="..."
tau --provider opencode-go --mode text "say hi"  # default model: deepseek-v4-flash
```

### Keeping keys in the config file

`~/.config/tau/config.json` accepts a per-provider map — `keys` outranks the
global `api_key` for that provider:

```json
{
  "provider": "deepseek",
  "keys": {
    "deepseek": "sk-...",
    "openai": "sk-..."
  },
  "api_key": "fallback-key"
}
```

The file must be strict JSON (no comments or trailing commas).

## Auth troubleshooting (exit 106)

### `no API key for provider '<name>' — set <ENV> env var, or use --api-key <key>`

Nothing in the resolution chain produced a key. The `hint` names the
provider's own env var(s) — set one of them, or use `--api-key`.

### Exit 106 with **no** error output

A plain `tau "..."` run exits silently when `resolveApiKey` finds nothing —
the check fires before the first request, so no envelope is emitted. Same
fix: provide a key at any level above.

### Valid key still rejected (401-class response)

The provider answered with an auth error — `invalid key`, `Unauthorized`,
expired or revoked token. Envelope `type` is `AuthFailed` with the same exit
code. Verify the key directly against the endpoint:

```bash
curl -sS "$TAU_ENDPOINT_OR_PROVIDER_ENDPOINT" \
  -H "Authorization: Bearer $YOUR_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"<model>","messages":[{"role":"user","content":"hi"}],"stream":false}'
```

If `TAU_ENDPOINT` is set, confirm the target server expects the same
`Bearer` auth scheme — a proxy that wants a different header or key format
surfaces as 106, not a connection error.

### Rate limits and 5xx are **not** auth failures

429/5xx responses retry with backoff and surface as exit `110`
(`internal_error` / `HTTPRequestFailed`), never 106 — see
[troubleshooting.md](troubleshooting.md).

## For agents and integrations

Auth envelopes point here via `docs`; other error classes keep pointing at
[troubleshooting.md](troubleshooting.md):

```json
{"err":{"code":106,"type":"AuthFailed","message":"no API key for provider 'openai' — set OPENAI_API_KEY env var, or use --api-key <key>","recoverable":false,"hint":"set OPENAI_API_KEY env var, or use --api-key <key>","docs":"https://github.com/javimosch/tau/blob/master/docs/providers.md"}}
```

Machine-readable exits: `106` = auth failure, `80` = unknown provider name,
`105` = timeout, `110` = transport/HTTP failure. The full contract is in
[troubleshooting.md](troubleshooting.md); flag/env-var details are in
[configuration.md](configuration.md).
