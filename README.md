# pizig — agent-first AI CLI

A non-interactive Zig reimplementation of [pi](https://github.com/earendil-works/pi),
built for AI agents rather than human interactive use. It mirrors pi's
single-shot (`-p`) command surface while skipping the interactive TUI.

## Status

| Capability | State |
|---|---|
| Rebrand `piz` → `pizig` (binary, help, version) | ✅ done |
| CLI argument parsing | ✅ done |
| Provider abstraction (xiaomi / openai / deepseek) | ✅ done |
| Output modes `text` / `json` | ✅ done |
| `@file` inclusion, system prompt | ✅ done |
| Proper JSON request escaping + response decoding | ✅ done |
| Semantic exit codes | ✅ done |
| Built-in tools (read/write/edit/bash/ls/grep/find) | ⚙️ scaffolded |
| **Tool-calling loop** (schemas sent + tool execution) | 🚧 in progress |

Single-shot chat (text and json) works end-to-end against the configured
provider. The agentic tool-calling loop is scaffolded (tool files + registry +
loop), but tool schemas are not yet sent to the model and tool execution is a
placeholder — that is the active next milestone.

> Historical note: an earlier "URGENT: std.process.run fails (exit 110)" blocker
> was a **misdiagnosis**. `std.process.run` works correctly in Zig 0.16.0; the
> failure was a 30s request timeout being exceeded by a ~34s reasoning-model
> generation, surfacing as the tool's own `internal_error` (110). Fixed by a
> 120s default `timeout_ms`. See `docs/roadmap.md`.

## Build

```bash
zig build                 # produces zig-out/bin/pizig
zig build test            # unit tests (json escaping, etc.)
```

Requires Zig 0.16.0 and `curl` on PATH.

## Usage

```
pizig [options] [@files...] [prompt...]
```

Common options (see `pizig --help` for the full list):

| Flag | Meaning |
|---|---|
| `-p, --print` | Non-interactive (default; always on) |
| `--provider <name>` | `xiaomi` (default), `openai`, `deepseek` |
| `--model <pattern>` | Model id, or `provider/id` (e.g. `openai/gpt-4o-mini`) |
| `--api-key <key>` | API key (else provider env var, else builtin) |
| `--system-prompt <text>` | Set the system prompt |
| `--append-system-prompt <text>` | Append to the system prompt (repeatable) |
| `--mode <text\|json>` | Output mode (default: `text`) |
| `-t, --tools <csv>` | Tool allowlist |
| `-xt, --exclude-tools <csv>` | Tool denylist |
| `-nt, --no-tools` | Disable all tools |
| `--timeout-ms <n>` | Request timeout (default: 120000) |
| `--help-json` | Machine-readable help as JSON |
| `-h, --help` / `-v, --version` | Help / version |

### Examples

```bash
pizig -p "List the files in src/"
pizig --model openai/gpt-4o-mini "Explain this error" @log.txt
pizig --mode json --system-prompt "Be terse" "What is Zig?"
```

## Providers & API keys

Key resolution order: `--api-key` → provider env var → provider builtin key.

| Provider | Endpoint | Env var(s) | Default model |
|---|---|---|---|
| `xiaomi` (default) | `…xiaomimimo.com/v1/chat/completions` | `PIZIG_API_KEY`, `XIAOMI_API_KEY` | `mimo-v2.5` |
| `openai` | `api.openai.com/v1/chat/completions` | `OPENAI_API_KEY` | `gpt-4o-mini` |
| `deepseek` | `api.deepseek.com/v1/chat/completions` | `DEEPSEEK_API_KEY` | `deepseek-chat` |

All current providers speak the OpenAI chat-completions wire format.

## Output

- `--mode text` (default): assistant text on stdout.
- `--mode json`: one object: `{"version","model","content","done":true}`.
- Errors go to stderr as `{"err":{"code","type","message","recoverable"}}`.

## Exit codes (semantic)

| Code | Meaning |
|---|---|
| `0` | success |
| `80` | invalid argument |
| `82` | missing required field (e.g. no prompt) |
| `105` | connection timeout |
| `106` | auth failed (no API key) |
| `110` | internal error |
| `111` | unimplemented |

## Testing

```bash
scripts/smoke.sh          # deterministic offline CLI tests
scripts/smoke.sh --net    # also run real LLM calls (needs network + key)
```

## Layout

```
src/
  main.zig            entry: parse args -> Config -> agent.run
  args.zig            CLI argument parser
  config.zig          Config + API-key resolution (re-exports provider table)
  json.zig            JSON escape/unescape + field extraction
  llm/provider.zig    Message/Response + complete() (provider table, wire calls)
  tools/              read/write/edit/bash/ls/grep/find + registry
  agent.zig           agentic tool-calling loop
docs/
  roadmap.md          roadmap + status
  pizig-plan.md       multi-agent build plan / work split
scripts/smoke.sh      end-to-end test harness
```

## Design

pizig targets **agents, not humans**: deterministic structured output,
semantic exit codes, no interactive prompts, no hidden retries, pipe-friendly.
