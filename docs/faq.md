# tau FAQ

Curated answers to the questions that come up most often when installing tau,
wiring up credentials, and getting a first successful run. For the full
error-message → fix catalog see **[docs/troubleshooting.md](troubleshooting.md)**;
for every config key see **[docs/configuration.md](configuration.md)**.

## Install & setup

### How do I install tau?

Build from source — you need **Zig 0.16.0** (the exact version), `curl`, and `git`:

```bash
git clone https://github.com/javimosch/tau.git
cd tau
zig build                # produces ./zig-out/bin/tau
```

Optionally put it on your `PATH`: `export PATH="$PWD/zig-out/bin:$PATH"`.

### `zig build` fails with errors that don't look like my fault

Check `zig version` — tau pins **0.16.0** and uses the new `std.Io` API surface.
Older or newer Zig releases will not compile it. Install 0.16.0 from
<https://ziglang.org/download/> and rebuild.

### Why does tau need `curl` on `PATH`?

tau shells out to `curl` for all LLM HTTP (including SSE streaming) instead of
shipping its own HTTP client. If `curl` is missing you'll get exit `110` —
install it with your package manager.

### Which platforms are supported?

Linux and macOS are the primary targets. `tau acp start|stop|status` (the ACP
daemon) needs a Unix socket and is POSIX-only — on other platforms use
`tau acp serve` in the foreground over stdio (exit `111` names this workaround).

### Where does tau store its files?

Everything lives under `~/.config/tau/`:

| Path | What it is |
|------|------------|
| `~/.config/tau/config.json` | Optional config file (strict JSON) |
| `~/.config/tau/sessions/<name>.json` | Conversations saved via `--session <name>` |
| `~/.config/tau/debug/<timestamp>.log` | Redacted logs written by `--debug` |
| `~/.config/tau/fleets/<id>.json` | Fleet manifests |

All paths derive from `$HOME` — if `HOME` is unset, tau exits `82`.

### Are there shell completions?

Yes — `completions/tau.bash` (bash) and `completions/_tau` (zsh) ship in the
repo. Source the bash file or drop `_tau` on your `fpath`; see
[completions/README.md](../completions/README.md).

## Authentication & providers

### Which providers does tau support?

`tau models` prints the live registry (JSON). Today: `xiaomi` (default,
`mimo-v2.5`), `openai` (`gpt-4o-mini`), `deepseek` (`deepseek-chat`), and
`opencode-go` (`deepseek-v4-flash`). Switch with `--provider <name>` or the
`--model provider/id` shorthand (e.g. `--model openai/gpt-4o-mini`).

### Which API key does tau want, and where do I put it?

Any one of these works — tau checks them in this order and uses the first
non-empty value:

1. `--api-key <key>` flag
2. `keys["<provider>"]` in `~/.config/tau/config.json` (per-provider keys)
3. The provider's env var (`XIAOMI_API_KEY`/`PIZIG_API_KEY`, `OPENAI_API_KEY`,
   `DEEPSEEK_API_KEY`, `OPENCODE_API_KEY`)
4. `api_key` in `~/.config/tau/config.json` (global fallback)
5. `TAU_API_KEY` env var
6. A provider-shipped builtin key (none currently set one)

For a single provider, `export TAU_API_KEY=...` or the provider's own env var
is simplest. For multiple providers, use `keys` in the config file:

```json
{ "provider": "openai", "keys": { "openai": "sk-...", "deepseek": "..." } }
```

### `TAU_API_KEY` is set but I still get exit 106

A stale `api_key` or `keys[provider]` in `~/.config/tau/config.json` silently
outranks `TAU_API_KEY` (config levels 2 and 4 beat env level 5). Inspect the
file, remove the stale entry, or pass `--api-key` to override everything.
The full precedence story: [docs/troubleshooting.md — Authentication failures](troubleshooting.md#authentication-failures-exit-106).

### Can I point tau at another OpenAI-compatible endpoint (OpenRouter, a proxy, a local server)?

Yes — `TAU_ENDPOINT` overrides the provider's endpoint URL. Combine with
`--model provider/id` and a matching key:

```bash
TAU_ENDPOINT=https://openrouter.ai/api/v1/chat/completions \
TAU_API_KEY=sk-or-... \
tau --model deepseek/deepseek-v4-flash "hi"
```

The endpoint must speak the OpenAI `/chat/completions` shape.

### My valid key still returns auth failure

That's the provider rejecting the key (401-class). Check the key isn't
expired or revoked, and — with `TAU_ENDPOINT` set — that the endpoint expects
`Authorization: Bearer <key>`. Exit code is still `106`.

## First run

### Why is the output JSON?

JSON is the default because tau is built for agents — a `{"version":...,"content":"...","done":true}`
envelope parses deterministically. For humans, `--mode text` prints prose.
Errors are always the JSON `{"err":...}` envelope on stderr, even in text mode —
that's by design so scripts can rely on one shape.

### `tau` with no arguments just prints help

Expected. tau is non-interactive — give it a prompt: `tau "What is 2+2?"`.
It runs one agentic turn and exits; there is no REPL.

### How do I let the model use tools — or stop it from using them?

- `--tools bash,read,ls` — allowlist specific tools
- `--exclude-tools bash` — denylist (all others still on)
- `--no-tools` — plain chat, no tool use
- `--dry-run` — show which tools the model *would* call, execute none

Available tools: `bash`, `read`, `write`, `edit`, `ls`, `grep`, `find`,
`calculator`.

### The run ended with a partial answer / exit 110 after lots of tool calls

The run hit `--max-iterations` (default 100), the runaway backstop. Raise it
(`--max-iterations 200`), narrow `--tools` so the model converges faster, or
add `--no-tools` if tools weren't needed. Details:
[docs/troubleshooting.md — Internal errors](troubleshooting.md#internal-errors-exit-110).

### How do I keep context between runs?

Use `--session <name>` — the conversation persists to
`~/.config/tau/sessions/<name>.json` and the next `--session <name>` call
resumes it. Without `--session`, nothing is persisted. Goal mode
(`/goal add …` inside a session) builds on this for autonomous work.

### A request timed out (exit 105)

Raise `--timeout-ms` (default 120000 — two minutes) for long generations or
big tool loops, check the endpoint/network (`TAU_ENDPOINT` typos included),
or try `--no-stream` for batch-style calls.

### How do I see what tau actually did?

- `--debug` — perf stats, tool-call I/O, and the raw API response on stderr,
  plus a **redacted** log file under `~/.config/tau/debug/` (credentials are
  masked; `TAU_DEBUG_LOG` overrides the path)
- `--thinking` — show the model's reasoning chunks
- `--dry-run` — preview tool calls without executing

### Something else went wrong — what do the exit codes mean?

`code` in the `{"err":...}` envelope equals the process exit code. The map:

| Code | Meaning | Quick fix |
|------|---------|-----------|
| `0` | Success | — |
| `1` | Not found | `message` names it |
| `80` | Invalid argument | `tau --help` |
| `82` | Missing required input | `message` names it |
| `105` | Timeout | raise `--timeout-ms` |
| `106` | Auth failed | provide an API key (see ladder above) |
| `110` | Internal/HTTP failure | re-run with `--debug` |
| `111` | Not supported on platform | `message` names the workaround |

Every envelope also carries `hint` (short remediation) and `docs` (a link into
[docs/troubleshooting.md](troubleshooting.md)).

### How do I report a bug?

Re-run with `--debug`, then open an issue at
<https://github.com/javimosch/tau/issues> with the `{"err":...}` envelope and
the debug-log path it prints. The log is credential-redacted
(`***REDACTED***`) but review it before sharing — it still contains tool I/O
and endpoint details.

## Still stuck?

- **[docs/troubleshooting.md](troubleshooting.md)** — every error message, mapped to fixes
- **[docs/configuration.md](configuration.md)** — full config-file reference
- **[docs/acp.md](acp.md)** — editor/ACP client setup
- `tau guide` / `tau guide --human` — the embedded operator manual
- `tau --help` / `tau --help-json` — every flag
