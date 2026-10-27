# tau Configuration Reference

Complete reference for every way to configure tau: the config file, environment
variables, CLI flags, and the precedence rules that tie them together.

Resolution model: **CLI flags > environment > config file > in-code defaults.**
The config file is loaded first as the base, then command-line flags override it.
Each section below lists the exact precedence order used by the code.

> **Tip:** `tau doctor` validates this whole chain end-to-end and prints a JSON
> report — config file parse + permission bits, resolved provider/model/endpoint,
> which source supplied the API key (never the key itself), shell completions,
> curl availability, endpoint reachability, and (with `--deep`) an authenticated
> probe. Exit code is `0` when no check fails, `1` otherwise; `--offline` skips
> network checks. `tau doctor --selftest` adds a credential-free end-to-end
> session against a loopback stub provider — it runs even under `--offline`
> since it never touches the real network. `tau doctor --fix` remediates the fixable outcomes — scaffold
> a missing config (or move an unparseable one to `config.json.bak` and
> re-scaffold), tighten permissions to `0700`/`0600`, install completions —
> prompting per fix on a TTY; `--yes` applies without prompting for
> non-interactive use.

---

## Config file

Path: `~/.config/tau/config.json` (built from `$HOME`).

The file is **optional** — tau runs fine without it. `tau init` scaffolds a
commented starter: it detects which provider API keys are already in your
environment, selects a matching `provider`, and lists every provider's env var
in comments. It never copies secret values into the file, and refuses to
overwrite an existing config unless `--force` is passed (`--stdout` previews
without writing, `--provider <name>` picks a provider explicitly).

`tau setup` wraps this into one-shot onboarding: it scaffolds the config the
same way (keeping an existing file instead of failing), installs shell
completions for the detected shell, then prints the `tau doctor` health
report — one NDJSON object per step, exit 0 only when everything is healthy.

For unattended onboarding (devcontainers, dotfiles scripts, CI), pass
`--yes` (`-y`) and/or `--non-interactive`, or set `TAU_YES=1` /
`TAU_NONINTERACTIVE=1`. Setup never prompts and never reads stdin either
way — the flags are an explicit contract, recorded as
`"non_interactive":true`/`"yes":true` in the final verdict so scripts can
assert it. `TAU_SETUP_SHELL` and `TAU_SETUP_CLIENT` supply `--shell` /
`--client` when the flags are absent (flag > env > `$SHELL` detection); `CI`
is deliberately not auto-detected — opt in explicitly.

The file is **JSONC**: `//` line comments and `/* */` block comments are
stripped before parsing, so a commented config (like the one `tau init`
writes) loads cleanly.

Behavior on load:

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
| `debug` | bool | `false` | `--debug` | Perf stats + tool I/O on stderr, plus a redacted diagnostic log under `~/.config/tau/debug/`. |
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

### JSON Schema and editor autocomplete

`tau config schema` prints the config file's JSON Schema (draft 2020-12) to
stdout. It is generated from the same `FileConfig` struct the loader and
`tau config validate` derive their checks from, so the schema can't drift from
the keys tau accepts: unknown keys are rejected (`additionalProperties:
false`), `provider` enumerates the provider table, `keys` restricts its member
names to providers, and integer/range constraints mirror the validator. The
generated, drift-checked key-by-key reference rendered from that schema lives
at [docs/config.md](config.md).

A canonical copy is checked in at [`schema/tau-config.schema.json`](../schema/tau-config.schema.json)
and is reachable at a stable URL:

```
https://raw.githubusercontent.com/javimosch/tau/master/schema/tau-config.schema.json
```

To get autocomplete, hover docs, and validation in an editor:

- **Per file** — add a `$schema` key. `tau init` writes one automatically;
  the loader ignores it and `tau config validate` accepts it:

  ```json
  { "$schema": "https://raw.githubusercontent.com/javimosch/tau/master/schema/tau-config.schema.json" }
  ```

- **VS Code, globally** — map the path in `json.schemas` settings:

  ```json
  "json.schemas": [
    {
      "fileMatch": ["**/.config/tau/config.json"],
      "url": "https://raw.githubusercontent.com/javimosch/tau/master/schema/tau-config.schema.json"
    }
  ]
  ```

- **Offline / pinned** — emit a local copy (`tau config schema >
  tau-config.schema.json`) and point `$schema` or `fileMatch` at the file.

Editors using the standard JSON language service honor `$schema` even in
JSONC files, so a commented `tau init` config still gets completions.

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
Per-provider credential setup and auth troubleshooting:
[providers.md](providers.md).

---

## Provider setup examples

Each example sets the provider's env var, then verifies the setup with a
single-shot call. Any of them can be made permanent by writing
`"provider": "<name>"` into `~/.config/tau/config.json` instead of passing
`--provider`.

### xiaomi (default)

```bash
export XIAOMI_API_KEY="..."        # PIZIG_API_KEY also works
tau --mode text "say hi"           # no flags needed — xiaomi is the default
```

### openai

```bash
export OPENAI_API_KEY="sk-..."
tau --provider openai --mode text "say hi"          # default model: gpt-4o-mini
tau --model openai/gpt-4o --mode text "say hi"      # provider/id shorthand
```

### deepseek

```bash
export DEEPSEEK_API_KEY="sk-..."
tau --provider deepseek --mode text "say hi"        # default model: deepseek-chat
```

### opencode-go

```bash
export OPENCODE_API_KEY="..."
tau --provider opencode-go --mode text "say hi"     # default model: deepseek-v4-flash
```

### Custom / self-hosted endpoint

Point any provider at an OpenAI-compatible server (proxy, gateway, or local
model) with `TAU_ENDPOINT`:

```bash
export OPENAI_API_KEY="sk-..."
export TAU_ENDPOINT="http://localhost:8080/v1/chat/completions"
tau --provider openai --mode text "say hi"
```

`TAU_ENDPOINT` always wins over the provider's built-in endpoint — see
[endpoint precedence](#provider-model-and-endpoint).

### Keys without environment variables

If you'd rather keep keys out of the environment, put them in the config
file — per-provider `keys` outrank the global `api_key`:

```json
{
  "provider": "deepseek",
  "keys": { "deepseek": "sk-...", "openai": "sk-..." }
}
```

See [API key resolution](#api-key-resolution) for the full precedence order.

---

## Environment variables

### Read by tau itself

| Variable | Purpose |
|----------|---------|
| `TAU_API_KEY` | Fallback API key, used after provider-specific env vars. |
| `TAU_ENDPOINT` | Overrides the provider's endpoint URL (works for chat and `tau acp`). Useful for proxies, gateways, and local OpenAI-compatible servers. |
| `TAU_DEBUG_LOG` | Overrides the `--debug` diagnostic log destination (default `~/.config/tau/debug/<timestamp>.log`). |
| `TAU_NO_UPDATE_CHECK` | Any non-empty, non-`0` value disables the update check everywhere — `tau version --check`, `tau upgrade`, and the `tau doctor` `update_available` warning. |
| `TAU_UPDATE_URL` | Overrides the release lookup URL used by the update check (default: the GitHub latest-release API). Useful for mirrors/proxies and `file://` stubs in tests. |
| `TAU_INSTALL_URL` | Overrides the installer script `tau upgrade` downloads and runs (default: the `install.sh` shipped at the release tag). Useful for mirrors and `file://` stubs in tests. |
| `TAU_INSTALL_DIR` | `tau upgrade` install destination when `--dir` is absent (default: the running binary's own directory, else the installer's `~/.local/bin`). Also honored by `install.sh` itself. |
| `XIAOMI_API_KEY`, `PIZIG_API_KEY` | API keys for the `xiaomi` provider (tried in that order). |
| `OPENAI_API_KEY` | API key for the `openai` provider. |
| `DEEPSEEK_API_KEY` | API key for the `deepseek` provider. |
| `OPENCODE_API_KEY` | API key for the `opencode-go` provider. |
| `TAU_YES` | `1`/`true`/`yes`/`on` enables `tau setup --yes` (approve all write steps) and `tau upgrade --yes` (self-update without prompting). Any other value, including `0`, is off. |
| `TAU_NONINTERACTIVE` | Same truthiness rules; enables `tau setup --non-interactive` (unattended contract for scripts/CI). |
| `TAU_SETUP_SHELL` | `tau setup` shell override when `--shell` is absent (`bash|zsh|fish|pwsh|all`); invalid values fail with exit 80. |
| `TAU_SETUP_CLIENT` | `tau setup` editor client when `--client` is absent (`zed|nvim|vscode|jetbrains|all`); invalid values fail with exit 80. |
| `HOME` | Root of all tau state: `~/.config/tau/` and `~/.agents/skills/`. If unset, config file, sessions, fleets, skills, and the ACP daemon are all disabled. |
| `TAU_EDITOR`, `VISUAL`, `EDITOR` | Editor for `tau config edit`, tried in that order (fallback: `vi` / `notepad`). May include arguments, e.g. `TAU_EDITOR="code --wait"`. |

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

## Inspecting the resolved config

`tau config show` prints the effective configuration as JSON — the same merge
a run would see: config file → environment → CLI flags. It's a read-only
diagnostic; it makes no network calls and never requires an API key.

```bash
tau config show                       # effective config right now
tau config show --provider openai     # preview overrides without running
```

Secrets are never printed. The resolved key is masked (`"***"` plus the last
four characters) and `api_key.source` reports which precedence level supplied
it — `"--api-key"`, `"config keys[<provider>]"`, `"env <VAR>"`,
`"config api_key"`, `"env TAU_API_KEY"`, or `"builtin"`. The `keys` map lists
each configured per-provider key, also masked. `endpoint_source` says whether
the endpoint came from the provider table or `env:TAU_ENDPOINT`, and
`config_file` reports the probed path, whether a file was found, and any parse
warning.

Subcommand discipline matches `tau fleet`/`tau skills`: bare `tau config` and
unknown subcommands exit `80`; `tau config show` takes no prompt and rejects
positional arguments.

## Validating a config file

`tau config validate [path]` checks a config file against the schema without
running an agent — fully offline, so it is safe for CI jobs and pre-commit
hooks. With no `path` it validates `~/.config/tau/config.json`.

```bash
tau config validate                    # validate ~/.config/tau/config.json
tau config validate ci/prod.json       # validate an explicit file
tau config validate --mode text        # human-readable errors instead of JSON
```

The report goes to **stdout** as `{"path":…,"ok":bool,"errors":[{key,message}]}`
(JSON mode) or one `path: error in "key": message` line per problem (text mode).
Exit codes: `0` when the file is valid, `1` when any problem is found, `80` for
CLI misuse. Every problem is listed at once — unknown keys, wrong value types,
unknown `provider`/`mode` values, out-of-range numbers (`compact_threshold`
outside 0–1, negative `temperature`, negative or overflowing integers), and
`keys` entries that aren't strings or name an unknown provider. Syntax errors
report a line and column. Key *values* are never echoed — `api_key`/`keys`
contents stay secret.

Example failure output:

```json
{"path":"bad.json","ok":false,"errors":[{"key":"provider","message":"\"provider\" is not a known provider: \"nope\" — valid providers: xiaomi, openai, deepseek, opencode-go"}]}
```

The validator is deliberately stricter than the loader: at startup tau ignores
unknown keys, `null` values, and even invalid JSON, but `config validate`
reports all of them — dead config is almost always a typo.

## Editing the config file programmatically

`tau config set|get|unset` edit the config **file** directly — the `git config`
model, not the merged view (`config show` still reports effective values). They
exist for CI and agent-driven setup, where shelling out to `jq` or hand-editing
JSONC is fragile. With no `path` they operate on `~/.config/tau/config.json`.

```bash
tau config set provider openai          # write ~/.config/tau/config.json
tau config set stream false             # booleans: true/false
tau config set temperature 0.2          # numbers validated per field
tau config set keys.openai sk-...       # per-provider API key
tau config set keys '{"openai":"sk-"}'  # ...or the whole map as a JSON object
tau config get provider                 # "openai"
tau config get api_key --raw            # secrets are redacted without --raw
tau config unset keys.openai            # remove a key
tau config set provider openai ./ci.json  # explicit path (like validate)
```

- **Schema-checked**: `set` only accepts keys from the table above (plus
  `keys.<provider>`), and values are coerced with the same rules
  `config validate` reports — wrong types, unknown providers/modes, and
  out-of-range numbers exit `80` before anything is written.
- **Comment-preserving**: edits are surgical text splices, so the commented
  `tau init` scaffold and hand-written comments survive a `config set`.
- **Atomic**: writes go to a temp file renamed over the original; existing
  permissions are kept, and a newly created file is `0600` (it may hold keys).
  `set` creates the file — and `~/.config/tau/` — when they don't exist.
- **git-config semantics**: `get`/`unset` of an absent key exit `1` with a
  `not_found` envelope; a missing or malformed file also exits `1`. CLI misuse
  (unknown key, bad value, stray args) exits `80`.
- **Secrets**: `api_key` and `keys.*` values are masked (`***last4`) in all
  `set`/`get` output; `get --raw` prints the stored value verbatim.

JSON mode (the default) emits one object per invocation — e.g.
`{"ok":true,"path":…,"key":"provider","value":"openai","created":false}` for
`set`, `{"path":…,"key":…,"set":true,"value":…}` for `get`, and
`{"ok":true,…,"removed":true}` for `unset`. `--mode text` prints the bare value
for `get` and one human-readable line for `set`/`unset`.

## Editing the config file interactively

`tau config edit [path]` opens the config file in your editor — the human
counterpart to `config set`, for when you'd rather edit JSONC by hand. The
editor command resolves like git's: `TAU_EDITOR` > `VISUAL` > `EDITOR` >
`vi` (`notepad` on Windows), run through the system shell so values with
arguments like `EDITOR="code --wait"` work.

```bash
tau config edit                     # edit ~/.config/tau/config.json
tau config edit ./ci.json           # edit an explicit file
TAU_EDITOR="code --wait" tau config edit
```

- **Missing file**: seeded with the commented `tau init` scaffold first
  (`"created":true` in the JSON output), so the editor opens on real content.
- **Validated on save**: when the editor exits cleanly, the file is checked
  with the same rules as `config validate`. On a clean save the JSON report is
  `{"ok":true,"path":…,"editor":…,"created":bool,"valid":true}` (or
  `<path>: ok` in text mode). On failure the report lists every problem —
  misspelled keys include `did you mean "…"?` hints — the file stays on disk
  so you can rerun `tau config edit` (or fix with `config set`), and tau exits
  `1`.
- **Editor failures**: an editor that exits non-zero or can't be launched
  emits an `editor_failed` envelope and exits `1`; `80` for CLI misuse.

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
