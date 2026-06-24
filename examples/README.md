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
```

See `tau --help` for the full flag reference.
