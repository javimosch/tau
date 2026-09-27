# tau Integration Contract

Stable, machine-consumable surface for programs that invoke tau: the JSON
output schemas, stream events, error envelopes, and exit codes you can rely
on. Everything on this page is pinned by tests (`zig build test` and
`scripts/smoke.sh --group contract`) — a change that breaks this contract
breaks the build.

Scope: this covers the **CLI process surface** (argv → stdout/stderr → exit
code). The ACP protocol is a separate contract; see [acp.md](acp.md).

---

## Process model

tau is non-interactive: one invocation runs one agentic turn (LLM + tool
loop) and exits. It never blocks on stdin and never prompts.

- **stdout** carries result data only: the final answer envelope, NDJSON
  stream events, or a command's JSON result.
- **stderr** carries diagnostics: error envelopes, warnings, and `--debug`
  output. A successful run may still print warnings to stderr.
- **Exit code** is the authoritative success/failure signal. A non-zero exit
  may produce no stdout at all.

## Exit codes

| Code | Name | When |
|------|------|------|
| `0` | success | Normal completion (including "nothing to report" results like `{"fleet":null}`). |
| `1` | generic_failure | Non-semantic failures, e.g. `tau skills load <name>` for an unknown skill, `--load-agents-md` on a missing file. |
| `80` | invalid_argument | Bad/unknown flag, unknown provider or subcommand, missing `@file`, `/goal` subcommand without `--session`. |
| `82` | missing_required_field | A required input was absent, e.g. `tau fleet run` without `--goal`, or a run with no prompt and no active goal. |
| `105` | connection_timeout | The provider request exceeded `--timeout-ms`. |
| `106` | auth_failed | No API key resolved (see [configuration.md](configuration.md) for precedence) or the endpoint rejected the key. |
| `110` | internal_error | HTTP/parse failure, malformed `--items` JSON, tool-loop cap exhausted in goal mode. |
| `111` | unimplemented | e.g. `tau acp start|stop|status` on an unsupported platform. |

The `--help-json` `exit_codes` map advertises all of the above **except** `1`
(generic_failure) — this table is authoritative.

Caveats consumers must handle:

- **Some exits are silent.** A missing API key on the chat path exits `106`
  with no envelope; an exhausted `--max-iterations` loop can exit `110` after
  already streaming content. Never require an `err` object — check the code.
- **`--max-iterations` is a backstop, not a failure mode.** When the tool
  loop hits the cap outside goal mode, tau forces one final answer and exits
  `0`; the cap is only visible in goal mode.

## Chat result (the run path)

`tau [flags] "prompt"` produces one of two shapes depending on `--mode` and
streaming (`--no-stream` disables streaming; it is on by default).

### JSON mode, non-streaming (`--mode json --no-stream`)

Exactly one line on stdout:

```json
{"version":"0.4.0","model":"xiaomi/mimo-v2.5","content":"The answer.","done":true}
```

| Field | Type | Meaning |
|-------|------|---------|
| `version` | string | tau release version |
| `model` | string | resolved `provider/model` id |
| `content` | string | the assistant's full answer (JSON-escaped; may contain `\n`) |
| `done` | `true` | terminal marker — always present, always `true` |

### JSON mode, streaming (default)

Newline-delimited JSON (NDJSON) — **one complete JSON object per line**:

```json
{"reasoning":"Let me think…","done":false}
{"chunk":"The ","done":false}
{"chunk":"answer.","done":false}
{"model":"xiaomi/mimo-v2.5","done":true}
```

| Event | Fields | Emitted when |
|-------|--------|--------------|
| content delta | `{"chunk":"<text>","done":false}` | each streamed token/fragment |
| reasoning delta | `{"reasoning":"<text>","done":false}` | `--thinking` only; reasoning fragments |
| terminal | `{"model":"<id>","done":true}` | exactly once, as the last line |

Consume by reading lines until a line whose `"done"` is `true`. During
tool-loop turns stdout is quiet while tools execute; the stream resumes on
the next model turn. The terminal line carries no `content` — accumulate
`chunk` values for the final turn's text.

### Text mode (`--mode text`)

stdout is the raw answer text plus a trailing newline. `--thinking` prints
`[THINKING] <text>` lines. Errors are still JSON envelopes on stderr — text
mode changes stdout only.

### Dry run (`--dry-run`)

Plans one turn, executes no tools, exits `0`. JSON mode:

```json
{"dry_run":true,"tool_calls":[{"name":"bash","arguments":"{\"command\":\"ls\"}"}]}
```

`arguments` is a JSON **string** (the raw argument payload) — parse it a
second time to get the tool's parameters. Text mode prints
`[dry-run] tau would call:` followed by `  - <name> <arguments>` lines.

### Structured output (`--schema <json|@file>`)

`content` remains a string, but the model is instructed to fill it with JSON
conforming to your schema. Parse `content` as JSON after unwrapping the
envelope. (`--schema` is a best-effort instruction, not a validator.)

## Error and warning envelopes

Errors are always JSON, in every mode. The guaranteed minimum shape:

```json
{"err":{"code":80,"type":"invalid_argument","message":"unknown option: --bogus","recoverable":false}}
```

| Field | Guarantee |
|-------|-----------|
| `err.code` | always present; integer equal to the process exit code |
| `err.message` | always present; human-readable detail |
| `err.type` | present on most envelopes; a short tag like `invalid_argument`, `not_found`, `AuthFailed`, or a Zig error name |
| `err.recoverable` | only on envelopes from the top-level dispatcher; omit-tolerant |

Two variants exist in the wild: the top-level dispatcher emits the full
shape above, while some subcommand paths (fleet validation, `acp` daemon
checks, `/goal` guard rails) emit the minimal `{"err":{"code","message"}}`
shape. **Fleet error envelopes are written to stdout**, not stderr — parse
any line/body containing a top-level `"err"` key on either channel.

Warnings use a separate envelope and never indicate failure:

```json
{"warn":{"message":"config file has invalid JSON and was ignored: /path — fix the JSON syntax or delete the file"}}
```

Emitted on stderr when `~/.config/tau/config.json` exists but is invalid —
defaults are used and execution continues, so a `warn` line may precede
normal output even on `0` exits (including `--help`/`--version`).

## Command results

All of the following exit `0` and write JSON to stdout. Unless noted, the
output is a single line. Every object below lists its pinned keys; consumers
must tolerate additional keys being added.

| Command | Shape |
|---------|-------|
| `tau --help-json` | `{"version","name","description","flags":[{"name","arg"?}],"goal_commands":[string],"output_modes":["text","json"],"defaults":{"mode","stream","auto_compact"},"exit_codes":{"<code>":"<name>"}}` |
| `tau models` | `{"providers":[{"name","default_model","endpoint","context_window"}]}` |
| `tau skills list` / `tau skills search <q>` | `{"skills":[{"name","description"}]}` — empty array when none match |
| `tau skills load <name>` | `{"skill":"<name>","content":"<markdown>"}`; unknown name → exit `1`, `not_found` envelope |
| `tau --scan-agents` | `{"agents_md_files":[{"path","first_line","size"}]}` — empty array when none found |
| `tau guide` | `{"one_liner","model","loop","concepts":[{"term","desc"}],"commands":[{"cmd","desc"}],"examples":[{"cmd","desc"}],"gotchas":[string],"see_also":[string],"version"}` |
| `tau --session s "/goal status\|pause\|resume\|clear\|complete"` | `{"goal":{"objective","status","continues","tokens_used"}}` or `{"goal":null}` |
| `tau fleet list` | `{"fleets":["<id>"]}` — empty array when none |
| `tau fleet status <id>` | pretty-printed manifest (below), or `{"fleet":null}` when the id doesn't exist |
| `tau fleet cancel <id>` | updated manifest; `{"fleet":null}` when the id doesn't exist |
| `tau fleet logs <id>` | `{"note":"<session hint>"}` |
| `tau fleet run` | final manifest (below); progress also streams per-worker output |

**Multi-line exception:** `fleet status`, `fleet cancel`, and `fleet run`
print the manifest pretty-printed (indented, multi-line). Parse stdout as a
whole for fleet commands — not line-by-line.

### Fleet manifest

`tau fleet run` prints it on completion; `status`/`cancel` print it directly.
The same shape is persisted at `~/.config/tau/fleets/<id>.json`.

```json
{
  "version": 1,
  "id": "fleet-1727000000000",
  "spec": {
    "goal": "…",
    "items": [{"id","title","scope","deliverables","acceptance","depends_on":[]}],
    "max_fleet_iterations": 3,
    "worker_max_iterations": 8,
    "parallel": true,
    "token_budget": null,
    "coordinator_model": null,
    "worker_model": null
  },
  "items": [{
    "item": {"id","title","scope","deliverables","acceptance","depends_on":[]},
    "status": "pending|running|approved|blocked|failed",
    "iterations": 0,
    "feedback_history": []
  }],
  "created_at": 1727000000000,
  "updated_at": 1727000000000,
  "global_status": "running|done|partial|failed|cancelled"
}
```

## Consumer rules

1. **Exit code first.** `0` means the command succeeded even when stdout is
   `{"fleet":null}` or an empty array. Non-zero may still have partial NDJSON
   output on stdout.
2. **Line-delimited, except fleet manifests.** Streaming output and all
   single-object results are one JSON object per line. Fleet manifest output
   is pretty-printed — read stdout fully and parse once.
3. **Tolerate unknown keys.** New fields may be added to any object; never
   rely on key order.
4. **`done` is the termination signal** for streams; a line with
   `"done":true` is always last.
5. **Strings are pre-escaped** — `content`, `chunk`, `message`,
   `arguments` arrive JSON-escaped; `arguments` and `content` (with
   `--schema`) need a second parse.
6. **`err` and `warn` can appear on either channel** in rare paths; treat
   any top-level `{"err":…}` object as an error regardless of the stream it
   arrived on.

## Versioning

This contract is pinned by `src/contract.zig` (exact serializer shapes) and
the `contract` group in `scripts/smoke.sh` (live-binary checks). Additive
changes (new fields, new event types) are non-breaking; removals or renames
are breaking and will be called out in [CHANGELOG.md](../CHANGELOG.md).
