# tau Troubleshooting FAQ

Every error tau can print, what it means, and how to fix it.

tau reports failures on **stderr** as a single-line JSON envelope — even in
`--mode text`:

```json
{"err":{"code":106,"type":"AuthFailed","message":"no API key for provider 'openai' — set OPENAI_API_KEY env var, or use --api-key <key>","recoverable":false,"docs":"https://github.com/javimosch/tau/blob/master/docs/troubleshooting.md"}}
```

- `code` is also the process exit code — scripts can branch on `$?`.
- `message` is human-readable and usually names the exact fix.
- `docs` always links back to this page.

Non-fatal problems use a separate `{"warn":{"message":"..."}}` envelope and the
run continues.

---

## Quick index by exit code

| Exit code | Envelope `type`        | Meaning                                | First thing to check |
|-----------|------------------------|----------------------------------------|----------------------|
| `0`       | —                      | Success                                | — |
| `1`       | `not_found`            | Named resource missing                 | The `message` names what wasn't found |
| `80`      | `invalid_argument`     | Bad flag, value, or subcommand         | `tau --help` / `tau --help-json` |
| `82`      | `missing_required_field` | Required input missing               | The `message` names what's missing |
| `105`     | `Timeout`              | HTTP request timed out                 | `--timeout-ms`, network, endpoint |
| `106`     | `AuthFailed`           | Missing or rejected API key            | Key resolution order (below) |
| `110`     | `internal_error`, `HTTPRequestFailed`, `Timeout`-adjacent | Request/tool/internal failure | Re-run with `--debug` |
| `111`     | —                      | Not implemented on this platform       | The `message` names the workaround |

---

## Authentication failures (exit 106)

### `no API key for provider '<name>' — set <ENV> env var, or use --api-key <key>`

tau could not find a usable key anywhere in the resolution chain. The message
names the provider's own env var(s). Fix it by providing a key at any level:

| Order | Source | Example |
|-------|--------|---------|
| 1 | `--api-key` flag | `tau --api-key sk-... "hi"` |
| 2 | config `keys["<provider>"]` | `{"keys": {"openai": "sk-..."}}` in `~/.config/tau/config.json` |
| 3 | provider env var | `OPENAI_API_KEY`, `DEEPSEEK_API_KEY`, `XIAOMI_API_KEY`/`PIZIG_API_KEY`, `OPENCODE_API_KEY` |
| 4 | config global `api_key` | `{"api_key": "sk-..."}` in `~/.config/tau/config.json` |
| 5 | `TAU_API_KEY` env var | `export TAU_API_KEY=sk-...` |
| 6 | provider builtin key | only providers that ship one |

Empty values are skipped at every level.

### Exit 106 with **no** error output

`resolveApiKey` found nothing, so the run exits before the first request.
Same fix as above — set any key source.

### 106 even though `TAU_API_KEY` is set

A stale `api_key` or `keys[provider]` in `~/.config/tau/config.json` silently
outranks `TAU_API_KEY` (levels 2 and 4 beat level 5). Inspect the file with
`cat ~/.config/tau/config.json` and remove the stale key, or pass
`--api-key` to override everything.

### Valid key still rejected

The provider returned an auth error (401-class response). Check that the key
isn't expired/revoked, and — if you use `TAU_ENDPOINT` — that the endpoint
expects the same auth scheme (`Authorization: Bearer <key>`).

---

## Timeouts (exit 105)

### `{"err":{"code":105,"type":"Timeout","message":"request failed",...}}`

The `curl` request exceeded `--timeout-ms` (default **120000** ms = 2 min).

- Long generations / big tool loops → raise it: `--timeout-ms 300000`.
- Slow endpoint or proxy → verify `curl -sS <endpoint>` responds at all.
- Streaming (`-N` SSE) uses the same budget; add `--no-stream` for batch-style
  calls that sit on one large request.

---

## Internal errors (exit 110)

### `{"err":{"code":110,"type":"HTTPRequestFailed","message":"request failed",...}}`

The HTTP layer failed after **3 attempts** (transient failures retry with
backoff automatically). Usual causes:

- **`curl` missing** — tau shells out to `curl` for all LLM HTTP. `which curl`.
- **Endpoint unreachable** — DNS/proxy/firewall, or a typo in `TAU_ENDPOINT`.
- **Endpoint keeps returning errors** — rate limits (429) and 5xx retry, then
  give up. Check provider status; try again or switch `--provider`.
- **Malformed response** — the endpoint isn't OpenAI-compatible
  (`/chat/completions` shape). Re-run with `--debug` to see the raw body.

Re-run with `--debug` — it prints perf stats and the raw API response to stderr.

### `fleet failed`, `acp failed`, `skills scan failed`, `agents scan failed`

The `type` field carries the Zig error name (e.g. `OutOfMemory`,
`FileNotFound`). These are environmental or internal faults — file an issue
with the full envelope if it reproduces.

### `InvalidWorkItem at index <n>: missing or non-string field '<field>'`

`tau fleet run --items '<json>'` received an item that doesn't match the work
schema. Every item needs the required string fields — compare your JSON with
the `--items` example in `tau --help`.

### Exit 110 **without** an envelope, after a long tool loop

Not an HTTP failure: the run hit `--max-iterations` (default 100) — the
runaway backstop. tau still emits the last answer, but exits 110 unless the
model had already produced a final turn. Fixes:

- `--max-iterations 200` for genuinely long tool chains
- `--tools <csv>` to narrow the allowlist so the model converges faster
- `--no-tools` if tool use wasn't intended at all

---

## Invalid arguments (exit 80)

All of these carry `"type":"invalid_argument"` and print the offending value.

| Message | Cause | Fix |
|---------|-------|-----|
| `unknown option: --<flag>` | Typo or unsupported flag | `tau --help` lists every flag; `tau --help-json` for machines |
| `missing value for --<flag>` | Flag needs an argument | `--model openai/gpt-4o-mini`, not a bare `--model` |
| `invalid --mode (want text\|json): <v>` | Bad `--mode` | Only `text` or `json` |
| `invalid --role (want author\|critic\|coordinator\|none): <v>` | Bad `--role` | One of the four roles |
| `invalid --<flag>: <v>` (temperature, max-tokens, timeout-ms, context-window, iterations…) | Non-numeric value | Pass a number: `--temperature 0.7` |
| `unknown provider '<name>' — valid providers: … (run 'tau models' for details)` | `--provider` or `--model p/m` used an unregistered provider | `tau models` lists valid names: `xiaomi`, `openai`, `deepseek`, `opencode-go` |
| `skills subcommand required: list \| search \| load` | Bare `tau skills` | Pick a subcommand |
| `invalid skills subcommand (want list\|search\|load): <v>` | Bad subcommand | `list`, `search`, or `load` |
| `fleet subcommand required: run \| status \| list \| logs \| cancel` | Bare `tau fleet` | Pick a subcommand |
| `unknown fleet argument: <v>` / `unknown fleet subcommand` | Flag/subcommand not in the fleet grammar | See the Fleet section of `tau --help` |
| `unknown acp argument: <v>` | Flag passed after `tau acp` | `tau acp serve\|start\|stop\|status` only |
| `cannot read schema file: <path>` | `--schema @file` unreadable | Check the path; or pass the schema inline |
| `/goal subcommands require --session <name>` | `/goal status\|pause\|resume\|clear\|complete` without a session | Add `--session <name>` |
| `argument parsing failed` (type `internal_error`) | Arg parser itself failed (OOM etc.) | Report it — not user error |

---

## Missing required fields (exit 82)

| Message | Fix |
|---------|-----|
| `fleet <cmd> requires <what>` (e.g. `fleet run requires --goal`) | Supply the named flag: `tau fleet run --goal "…"` |
| `skill name required` | `tau skills load <name>` — find names via `tau skills list` |
| `HOME not set` | tau builds `~/.config/tau` paths from `$HOME`; export it |

Exit 82 **without** a message means tau was invoked with no prompt, no active
goal, and nothing to continue — give it a prompt or resume a goal session.

---

## Not found (exit 1)

| Message | Fix |
|---------|-----|
| `skill not found: <name>` | `tau skills list` — skills live in `~/.agents/skills/` |
| `AGENTS.md not found: <path>` | `--load-agents-md` needs a real file; `--scan-agents` lists what's discoverable |
| `Tool '<name>' not found` (inside the tool loop, not the envelope) | The model called an unregistered tool. Valid names: `bash`, `read`, `write`, `edit`, `ls`, `grep`, `find`, `calculator`. tau feeds the error back to the model and continues — no action needed unless it loops |

---

## Unimplemented (exit 111)

### `acp daemon (start/stop/status) is unsupported on this platform; use 'tau acp serve' over stdio`

`tau acp start|stop|status` needs a Unix socket. On platforms without one, run
`tau acp serve` in the foreground over stdio instead.

---

## Warnings (run continues)

### `{"warn":{"message":"config file has invalid JSON and was ignored: <path> — fix the JSON syntax or delete the file"}}`

`~/.config/tau/config.json` exists but doesn't parse. tau falls back to
defaults — flags and env vars still work. Fix the syntax or delete the file.
Trailing commas and comments are **not** allowed — it must be strict JSON.

### `failed to save session <name>: <err>` (stderr, non-fatal)

The conversation result was still printed; only persistence to
`~/.config/tau/sessions/<name>.json` failed — usually a permissions or disk
problem. Check the directory is writable.

---

## Tool-loop problems (model-side, recoverable)

These appear as `role:"tool"` messages inside the transcript — the run usually
continues and self-corrects.

| Message | Meaning | Nudge |
|---------|---------|-------|
| `Tool '<name>' not found` | Model hallucinated a tool name | Restrict with `--tools`, or add the real tool name to the prompt |
| `Tool execution failed: MissingArgument` | Model omitted a required arg | Reprompt with the required params spelled out |
| `Tool execution failed: UnsafeArgument` | Path traversal (`..`) or NUL bytes blocked by validation | Working as intended — keep paths inside the project |
| `Error: <stderr>` from `bash` | The command itself failed | Read the embedded stderr; the model sees it too |

Use `--dry-run` to preview which tools the model *would* call without executing
any of them.

---

## Looks broken but isn't

| Symptom | Explanation |
|---------|-------------|
| `tau` with no args prints help and exits | Expected — tau is non-interactive; give it a prompt |
| Output is JSON when you wanted prose | JSON is the default. `--mode text` |
| Errors are JSON even in `--mode text` | By design — stderr always uses the envelope |
| `"content":""` with `done:true` | Legitimate empty reply (often after a tool-call turn) |
| Nothing persisted | Sessions only persist with `--session <name>` |
| `tau acp serve` reads no `TAU_MODEL`-style env var | Model comes from config or `--model` |
| `--no-stream` still shows a "stream" in config | Config `stream` default is `true`; the flag wins at runtime |

---

## Diagnostic toolkit

| Command | Use it to |
|---------|-----------|
| `tau --debug "<prompt>"` | Perf stats, tool-call I/O, raw API response on stderr |
| `tau --dry-run --tools bash,read "<prompt>"` | See planned tool calls, execute none |
| `tau --thinking "<prompt>"` | Show model reasoning chunks |
| `tau models` | List providers + default models (JSON) |
| `tau --help-json` | Machine-readable flag catalog |
| `tau guide` / `tau guide --human` | Embedded operator manual (JSON / markdown) |
| `tau acp status` | Is the ACP daemon running? |
| `echo $?` after a failure | Semantic exit code for scripting |

Still stuck? Re-run with `--debug`, copy the full `{"err":...}` envelope, and
open an issue: <https://github.com/javimosch/tau/issues>
