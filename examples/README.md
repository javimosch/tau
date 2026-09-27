# tau — examples

Ready-to-run shell scripts covering the most common tau workflows.

## Prerequisites

- tau installed: `zig build` from the repo root produces `zig-out/bin/tau`. Add it to your `PATH` or set `TAU_BIN=/path/to/tau`.
- At least one API key exported in your shell:

```bash
export XIAOMI_API_KEY="..."   # default provider
export OPENAI_API_KEY="..."   # for --provider openai examples
export DEEPSEEK_API_KEY="..."  # for --provider deepseek examples
```

Or set a universal fallback: `export TAU_API_KEY="..."`.

---

## Examples

### `01-file-editing.sh` — read, write, and edit files

Covers tau's built-in file tools: `read`, `write`, `edit`.

```bash
bash examples/01-file-editing.sh
```

What it demonstrates:

| Step | Command pattern | What happens |
|------|----------------|--------------|
| Read | `tau --tools read "Read /path/to/file …"` | Model calls the `read` tool and describes the file |
| Write | `tau --tools write "Write /path/to/dest …"` | Model creates a new file on disk |
| Edit | `tau --tools edit "Replace X with Y in /path …"` | Model performs an exact string replacement |
| Multi-tool | `tau --tools read,write "Read A, transform, write B"` | Model chains tools automatically |
| JSON output | `tau --tools read --mode json "Parse CSV …"` | Structured JSON response with `.content` field |

### `02-multi-turn-qa.sh` — persistent sessions and goal mode

Covers `--session` for conversation history and `/goal` for autonomous multi-step work.

```bash
bash examples/02-multi-turn-qa.sh
```

What it demonstrates:

| Step | Command pattern | What happens |
|------|----------------|--------------|
| Session turn 1 | `tau --session name "…"` | Seeds the session with context |
| Session turn 2 | `tau --session name "follow-up?"` | Model recalls prior turns |
| Goal mode | `tau --session name "/goal <objective>"` | Model loops with tools until done |
| Status check | `tau --session name "/goal status"` | Returns current goal state without an LLM call |

Session files live at `~/.config/tau/sessions/<name>.json`. Goal lifecycle:

```bash
tau --session myproject "/goal pause"     # suspend
tau --session myproject "/goal resume"    # continue
tau --session myproject "/goal clear"     # reset goal, keep history
tau --session myproject "/goal complete"  # mark done manually
```

### `03-provider-switching.sh` — switch providers and models

Covers `--provider`, `--model`, `--api-key`, and `~/.config/tau/config.json`.

```bash
bash examples/03-provider-switching.sh
```

What it demonstrates:

| Step | Command pattern | What happens |
|------|----------------|--------------|
| Default provider | `tau "…"` | Uses xiaomi / mimo-v2.5 |
| Switch provider | `tau --provider openai "…"` | Uses openai / gpt-4o-mini |
| Model shorthand | `tau --model openai/gpt-4o "…"` | Sets provider + model in one flag |
| Inline key | `tau --provider openai --api-key sk-… "…"` | Per-call credential override |
| Parallel compare | Two `tau` calls in the background | Side-by-side responses from different providers |
| Temperature | `tau --temperature 0.2 --max-tokens 60 "…"` | Control creativity and response length |

**Persistent config** (`~/.config/tau/config.json`):

```json
{
  "provider": "openai",
  "model": "gpt-4o-mini",
  "keys": {
    "openai": "sk-...",
    "deepseek": "sk-..."
  }
}
```

CLI flags always override the config file.

### `04-json-event-stream.py` — consume the JSON stdout event stream

A minimal Python (stdlib-only) consumer for tau's streaming NDJSON output.
Arguments are passed through to tau verbatim:

```bash
python3 examples/04-json-event-stream.py "Summarise Zig in one line"
python3 examples/04-json-event-stream.py --no-tools "What is 2+2?"
```

What it demonstrates:

| Event | Shape | Handling |
|-------|-------|----------|
| Content delta | `{"chunk":"…","done":false}` | Rendered live to stdout |
| Thinking delta | `{"reasoning":"…","done":false}` | Forwarded to stderr (`--thinking` only) |
| Final envelope | `{"version","model","content","done":true}` | `.content` holds the full response |
| Command result | `{"goal":…}`, `{"dry_run":…}` | Pretty-printed |
| Warning | `{"warn":{"message":…}}` on stderr | Decoded and reported |
| Error | `{"err":{"code","type","message","recoverable"}}` on stderr | Decoded; exit code propagated |

The script exits with tau's own exit code. Two quirks worth knowing: a
missing API key exits `106` with *no* stderr envelope, and `tau fleet`
results are pretty-printed multi-line JSON rather than NDJSON — collect all
of stdout for those commands.

### `ci/` — non-interactive CI usage

`ci/run.sh` is a CI-ready wrapper: it runs tau with `--no-stream --mode json
--no-tools --timeout-ms`, maps every exit code to an actionable failure
message, parses `.content` from the JSON envelope, and writes it to
`tau-output.md` (plus `$GITHUB_STEP_SUMMARY` when present). The demo task
drafts release notes from `git log` — swap in whatever your pipeline needs.

`ci/github-actions.yml` is a copy-paste workflow that builds tau from
source, runs the script with a secret API key, and uploads the output as an
artifact.

```bash
TAU_BIN=./zig-out/bin/tau bash examples/ci/run.sh
```

To adopt: copy `examples/ci/` into your repo, copy the workflow to
`.github/workflows/`, and add a provider key (`XIAOMI_API_KEY`,
`OPENAI_API_KEY`, `DEEPSEEK_API_KEY`, or `TAU_API_KEY`) as a CI secret.

---

## Quick reference

```bash
# One-shot — JSON output (default)
tau "List files in src/"

# Human-readable text
tau --mode text "Explain this error"

# Tool-calling loop
tau --tools bash,read,write "Analyse the codebase and suggest improvements"

# Persistent conversation
tau --session myproject "What files are in this repo?"
tau --session myproject "Summarise what build.zig does"

# Autonomous goal
tau --session myproject "/goal Add a --version flag and verify zig build passes"

# Switch provider
tau --provider openai --model openai/gpt-4o "Translate this to French"

# Structured output with JSON Schema
tau --schema '{"type":"object","properties":{"score":{"type":"integer"}}}' \
    "Rate the code quality of the snippet below out of 10" @src/main.zig

# Consume the JSON event stream (NDJSON)
tau "…" | jq -r '.chunk // empty'                      # live deltas only
python3 examples/04-json-event-stream.py "…"            # full consumer script
```

See `tau --help` for the full flag reference.
