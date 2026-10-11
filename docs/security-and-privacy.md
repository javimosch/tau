# Security & Privacy

What tau sends over the network, where it writes data locally, how it handles
credentials, and exactly what the `--debug` log redaction guarantees — plus
how to constrain the agent's tool access.

Reporting a vulnerability → [../SECURITY.md](../SECURITY.md).

---

## Threat model

- **tau runs with your privileges.** There is no sandbox around tool
  execution: a `bash` or `write` tool call runs as the invoking user and can
  touch anything that user can.
- **The model drives tools by default.** Unless you pass `--no-tools` or an
  allowlist, the LLM decides which tools run and with what arguments. Content
  the model reads (files, command output, web pages via `bash curl`) can
  prompt-inject it — treat tool calls as untrusted.
- **One outbound channel.** tau makes exactly one kind of network connection:
  HTTPS POSTs to the configured chat-completions endpoint, via `curl` on
  `PATH`. There is **no** telemetry, analytics, crash reporting, update check,
  or other phone-home.
- **Everything the tools touch can leave the machine.** Tool results are
  appended to the conversation and sent to the provider on the next turn.

```
 you ──► tau ──► tools (read/bash/grep/...)          your host
           │                                           ▲
           │ HTTPS POST <endpoint>/chat/completions    │ tool results,
           │ Authorization: Bearer <key>               │ file contents
           ▼                                           │
        LLM provider (OpenAI-compatible endpoint)
```

---

## Data flows

### What is sent to the provider

Every `/chat/completions` request body contains:

| Field | Contents |
|-------|----------|
| `model` | Resolved model id |
| `messages` | System prompt + `--append-system-prompt` text + AGENTS.md content (with `--load-agents-md`/`--auto-agents-md`) + loaded skill content; all user messages (prompts and `@file` contents); prior assistant messages including `tool_calls`; **tool results** (file contents, directory listings, grep matches, bash stdout/stderr) |
| `tools` | JSON schemas for the enabled built-in tools |
| `temperature`, `max_tokens` | Sampling parameters when set |
| `response_format` | Your `--schema` JSON Schema, when given |

Practical consequence: if a tool reads `~/.ssh/config`, an `.env` file, or a
secrets store, **that content goes to the provider** on the next turn.
Restrict tools (below) or keep secrets out of the working directory.

### What is sent elsewhere

Nothing. tau has no second destination. However:

- **`TAU_ENDPOINT` redirects everything.** It is used verbatim as the POST
  URL. A plain-`http://` endpoint sends prompts, tool results, *and* your API
  key in cleartext. Only point it at endpoints you trust.
- **Providers see what you send.** Your prompts and tool output are governed
  by the provider's own data policy — check it before sending sensitive code.

### The curl transport — argv visibility caveat

tau delegates HTTP to a `curl` subprocess. Two things ride on curl's command
line: `-H "Authorization: Bearer <key>"` and `--data-raw <request body>`.
Process arguments are visible to other local users via `ps`/`/proc` **for the
duration of the request**. On a shared machine, assume anything in the request
(prompts included) can be observed that way; prefer running tau on
single-user systems or accept this exposure. The same caveat applies to
`--api-key` on tau's own command line, which also lands in shell history —
prefer environment variables.

### What is stored locally

All state lives under `~/.config/tau/` (or `$HOME/.config/tau/`):

| Path | Contents | Permissions |
|------|----------|-------------|
| `config.json` | Provider/model/mode defaults; **may contain `api_key`/`keys` in plaintext** | Process default (umask) — `chmod 600` recommended |
| `sessions/<name>.json` | Full conversation history including tool results, plus goal state | Process default (umask) |
| `fleets/<id>.json` | Fleet goal, work breakdown, per-item status | Process default (umask) |
| `debug/<ts>.log` | Redacted `--debug` diagnostic log | `0600` (POSIX) |
| `acp.sock`, `acp.pid`, `acp.log` | ACP daemon socket, pid file, daemon stdout/stderr | Process default (umask) |

Session names and fleet ids are validated before becoming paths
(`[a-zA-Z0-9._-]` only, `.`/`..` rejected), so a hostile name cannot write
outside these directories.

**Cleanup is manual.** Deleting a session/fleet/debug file removes it; tau
never expires or scrubs them itself. Session and debug logs can contain
sensitive conversation content — delete `~/.config/tau/sessions/` and
`~/.config/tau/debug/` entries you no longer need.

---

## Credential handling

### Resolution order

`resolveApiKey` (`src/config.zig`) tries, in order:

1. `--api-key <key>` flag
2. Config file `keys[<provider>]` (per-provider map)
3. Provider env var(s) — e.g. `OPENAI_API_KEY`, `XIAOMI_API_KEY`/`PIZIG_API_KEY`
4. Config file global `api_key`
5. `TAU_API_KEY` (generic fallback)
6. Provider `builtin_key` (no shipped provider sets one)

Empty values are skipped at every level. The resolved key is used for exactly
one thing: the `Authorization: Bearer` header on provider requests.

### Where credentials can and can't end up

- **Never written:** API keys are not persisted into session files, fleet
  manifests, debug logs, or stdout output. Error envelopes carry codes and
  messages, never key material.
- **Config file:** storing keys in `~/.config/tau/config.json` keeps them on
  disk in plaintext. Prefer env vars; if you do use the config file,
  `chmod 600 ~/.config/tau/config.json`.
- **Environment inheritance:** tool subprocesses (including `bash` commands
  the model runs) inherit tau's environment — so `OPENAI_API_KEY` etc. are
  readable by any command the model executes, and a command's output goes back
  to the provider. On a shared or prompt-injection-prone workload, this is the
  largest realistic leak path. Mitigate with `--tools` allowlists that exclude
  `bash`, or inject keys per-invocation rather than exporting them globally.
- **Process lists:** see the curl argv caveat above.

---

## `--debug` log redaction — guarantees and limits

With `--debug`, every `[DEBUG]` line (tool calls, tool results, raw API
response) plus a perf summary is written to **two** places:

| Destination | Redacted? | Permissions |
|-------------|-----------|-------------|
| stderr | **No — verbatim** | — |
| `~/.config/tau/debug/<UTC>-<rand>.log` (override: `TAU_DEBUG_LOG`) | **Yes** | `0600` (POSIX); custom `TAU_DEBUG_LOG` paths use umask |

The file is what you attach to a bug report; the path is printed on stderr and
linked from error envelopes via `debug_log`.

### What is masked (replaced with `***REDACTED***`)

1. **Every registered credential literal** — not just the winning key. At log
   open, tau registers: the resolved key, the `--api-key` value, the config
   global `api_key`, every `keys[...]` value, `TAU_API_KEY`, every provider
   env var currently set, and any provider `builtin_key`. Literals shorter
   than 6 characters are skipped (masking a tiny string would corrupt the
   log).
2. **`Bearer <token>`** — the Authorization-header shape, case-insensitive,
   even for tokens that were never registered.
3. **JSON credential fields** — `"api_key"`, `"apikey"`, `"api-key"`,
   `"authorization"`, `"x-api-key"`, `"access_token"`, `"refresh_token"`,
   `"id_token"`, `"client_secret"`, `"token"`, `"secret"`, `"password"`
   (case-insensitive) have their string values masked.
4. **`NAME=value` env-style assignments** where `NAME` is a generic credential
   name (`key`, `token`, `secret`, `password`, `auth`, `authorization`,
   `access_token`, `client_secret`, `credential`, …) or ends in `_KEY`,
   `_TOKEN`, `_SECRET`, `_PASSWORD`, `_APIKEY`, `_CREDENTIAL`
   (e.g. `OPENAI_API_KEY=sk-…`).

Additional limits: each logged line is capped at 8 KiB (with an explicit
`[debuglog: truncated N bytes]` marker), and the file opens with a provenance
header (version, provider, model, endpoint, whether a key resolved — never
the key itself). Masking is covered by unit tests in `src/debuglog.zig` and
end-to-end checks in `scripts/smoke.sh`.

### What is NOT guaranteed

Redaction is best-effort, not a proof:

- **stderr is raw.** The live `[DEBUG]` stream on stderr is unredacted — pipe
  it carefully (`tau --debug … 2>/dev/null` still writes the file).
- **Foreign secrets may pass through.** A token inside a file a tool reads —
  one that isn't a registered credential and doesn't match the patterns above
  (e.g. `-----BEGIN … PRIVATE KEY-----` blocks, bespoke token shapes) — is
  logged as-is.
- **Keys under 6 characters** are not literal-masked.
- **Tool output content is kept.** The log intentionally retains tool I/O and
  endpoint details so it is useful for debugging — file paths, command
  output, and partial API responses are present in the clear.

**Always review the file before attaching it to a bug report** — the header
says the same. Rotate any key that appeared in a log you shared.

---

## Tool execution model

### Validation applied (`buildToolArgs`, `src/agent.zig`)

- Null bytes rejected in every argument.
- `..` path components rejected in path arguments (no `../../etc/passwd`).
- Empty `bash` commands rejected.
- Unknown tool names and missing required arguments rejected.

### What is NOT restricted

- `bash` runs `sh -c <command>` — arbitrary shell with full user privileges,
  including network access and reading your environment.
- Absolute paths are allowed — `read`/`write`/`edit` can touch any file the
  user can.
- There is no working-directory jail.

### Controls

| Flag | Effect |
|------|--------|
| `--tools read,ls,grep` | Allowlist — safest default for untrusted input |
| `--exclude-tools bash` | Denylist specific tools |
| `--no-tools` | Pure chat turn; nothing executes |
| `--dry-run` | Report planned tool calls, execute none (audit before enabling) |
| `--max-iterations <n>` | Cap the tool-call loop |

In the Author↔Critic loop (`src/loop.zig`), the critic role defaults to a
read-only allowlist (`read`, `grep`, `find`, `ls`). A standalone
`--role critic` turn does **not** restrict tools by itself — pass `--tools`.

### Prompt-injection hygiene

If tau reads untrusted content (a repo you're reviewing, issue text, fetched
pages), assume the model may be steered. Run with a read-only allowlist, or
review with `--dry-run` first.

---

## ACP server

`tau acp serve` speaks JSON-RPC over **stdio**; `tau acp start` runs a
background daemon on the Unix socket `~/.config/tau/acp.sock`.

- **No authentication.** Any local process that can open the socket can drive
  the agent, including invoking enabled tools. Keep `~/.config/tau/` at
  `0700` if you run the daemon on a multi-user system.
- The daemon log (`acp.log`) captures the server's stdout/stderr and is not
  redacted — it can contain tool I/O.

---

## Hardening checklist

- [ ] Prefer env vars over config-file keys; `chmod 600` the config file if you store keys there.
- [ ] `chmod 700 ~/.config/tau` on shared machines (sessions, debug logs, ACP socket all live inside).
- [ ] Use `--tools`/`--no-tools`/`--dry-run` whenever prompts or tool input are untrusted.
- [ ] Only set `TAU_ENDPOINT` to `https://` endpoints you trust.
- [ ] Review `~/.config/tau/debug/*.log` before sharing; rotate keys that leaked.
- [ ] Delete old `sessions/`, `fleets/`, and `debug/` files — nothing expires them automatically.

---

See also: [configuration.md](configuration.md) (config keys, env vars,
precedence) · [troubleshooting.md](troubleshooting.md) (error envelopes and
the diagnostic toolkit) · [acp.md](acp.md) (editor integration setup).
