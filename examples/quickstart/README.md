# quickstart — try tau with zero credentials

A runnable, zero-config tour of tau. One command, no API key, no config file,
no network:

```bash
sh examples/quickstart/quickstart.sh
```

It exercises the three surfaces a new user cares about:

| Step | Command shape | What you see |
|------|---------------|--------------|
| 1 | `tau --no-tools "…"` | The default JSON stream (`{"chunk":…}` NDJSON + final envelope) |
| 2 | `tau --tools read --mode text "…"` | The agentic loop: stub requests a `read` tool call, tau executes it for real, streams the follow-up answer |
| 3 | `printf <JSON-RPC> \| tau acp serve` | tau as an ACP agent over stdio — `initialize`, `session/new`, `session/prompt` with live `session/update` notifications |

## How it works

tau doesn't speak HTTP itself — it shells out to `curl` and reads the response
body from the child's stdout. `stub/curl` exploits that: it's a POSIX shell
script shadowed onto `PATH` ahead of the real curl, so every provider request
lands on it. It inspects the `--data-raw` body and answers with a canned
OpenAI-compatible payload:

- `"stream":true` → SSE `data:` frames ending in `data: [DONE]`
- otherwise → a single `chat.completion` JSON object
- body carries `"tools":[` but no result yet → a `read` tool_call for the
  bundled `hello.txt`
- body carries `"tool_call_id"` → the tool result was submitted → closing
  summary

The script also sandboxes `HOME` into a temp dir (so no config is read and no
session files touch your real `~/.config/tau`) and exports
`TAU_API_KEY=tau-quickstart-stub` so key resolution succeeds. Nothing leaves
your machine — the endpoint URL is never contacted.

## Requirements

- `sh`, `sed`, `mktemp` (any POSIX box)
- a tau binary: `zig build` in the repo root, a `tau` on `PATH`, or
  `TAU_BIN=/path/to/tau`

## Files

| File | Purpose |
|------|---------|
| `quickstart.sh` | The runnable demo — three steps + explanation |
| `stub/curl` | The stub model server (a curl-compatible stdio shim) |
| `hello.txt` | Sample file the stubbed `read` call points at |

## Go live for real

```bash
export TAU_API_KEY="your-key"   # or OPENAI_API_KEY / DEEPSEEK_API_KEY / XIAOMI_API_KEY
tau --mode text "Say hello"
```

Then the same loop runs against a real provider. See
[docs/configuration.md](../../docs/configuration.md) for key resolution and
[docs/acp.md](../../docs/acp.md) for wiring tau into an editor.
