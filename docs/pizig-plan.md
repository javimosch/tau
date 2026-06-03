# pizig — rebrand + pi core feature plan

> Shared coordination doc for the 2-agent a2a team (`claude-sub` + main agent).
> Project bus: `A2A_PROJECT=piz`. Goal: rebrand `piz` → `pizig` and implement
> the **non-interactive** core of `pi` (skip the interactive TUI).

## Scope: which `pi` features (from `pi --help`)

In scope (non-interactive `-p` mode):
- Positional prompt + `-p/--print`, `--help/-h`, `--version/-v`
- `@files...` inclusion in the initial message
- `--provider`, `--model` (supports `provider/id`), `--api-key`
- `--system-prompt`, `--append-system-prompt`
- `--mode text|json` output modes (rpc deferred)
- Built-in tools: `read`, `write`, `edit`, `bash`, `ls`, `grep`, `find`
- `--tools/-t`, `--no-tools/-nt`, `--exclude-tools/-xt`
- `--thinking <level>` (pass-through to provider if supported)
- API keys from env (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, …)

Out of scope (for now): interactive TUI, sessions (`--continue/--resume`),
extensions, skills loading, themes, prompt templates, HTML export, `--mode rpc`.

## Current state (HEAD 2d24774)

- Single file `src/main.zig`. Hardcoded prompt + creds. No arg parsing.
- ✅ zig timeout blocker RESOLVED (Config.timeout_ms=120000). Builds, exits 0.
- 🐞 `printHelpJson` emits literal `{{`/`}}` → malformed JSON (plain string, not fmt).
- 🐞 JSON request body not escaped → breaks on quotes/newlines in prompt.
- One hardcoded OpenAI-compatible provider (xiaomi mimo-v2.5).

## Proposed file layout (matches roadmap architecture)

```
src/
  main.zig            # entry: parse args -> build Config -> run agent loop
  args.zig            # CLI argument parser  -> Config
  config.zig          # Config struct, env-key resolution, provider table
  json.zig            # JSON escape/encode + minimal response extraction helpers
  llm/
    provider.zig      # request build + HTTP(curl) call + response parse
  tools/
    registry.zig      # tool list, allow/deny filtering
    terminal.zig      # bash
    fs.zig            # read/write/edit/ls
    search.zig        # grep/find
  agent.zig           # agentic loop: call LLM -> exec tool_calls -> repeat
```

## Proposed work split (minimize main.zig collisions)

**claude-sub (me) — plumbing & rebrand:**
- `args.zig`, `config.zig`, `json.zig` (escaping), env-key resolution
- Rebrand piz→pizig everywhere (build.zig exe, help/version, README, docs)
- Fix malformed help JSON + proper `--help`/`--version`
- Refactor `main.zig` to: parse args → Config → call `agent.run(...)`
- Define the `agent.run()` + `provider.complete()` interface signatures

**main agent — intelligence & tools:**
- `llm/provider.zig`: provider table (anthropic/openai/xiaomi), request build
  with system prompt + message array, proper tool schema, response/tool_call parse
- `tools/*`: read/write/edit/bash/ls/grep/find implementations
- `agent.zig`: the tool-calling loop (call → exec tools → feed results → repeat)

### Interface contract (draft — confirm on bus)

```zig
// config.zig
pub const Config = struct { /* fields below */ };

// agent.zig
pub fn run(io: std.Io, gpa: std.mem.Allocator, cfg: Config) !u8; // returns exit code

// llm/provider.zig
pub const Message = struct { role: []const u8, content: []const u8 };
pub fn complete(io: std.Io, gpa: std.mem.Allocator, cfg: Config,
                messages: []const Message, tools_json: ?[]const u8) !Response;
pub const Response = struct { content: []const u8, tool_calls: []ToolCall };
```

## Milestones

1. M1 — plumbing: args + config + rebrand build green, `pizig -p "hi"` works text+json.
2. M2 — provider abstraction + JSON escaping + system prompt.
3. M3 — tools + agentic loop (read/bash first, then write/edit/search).
4. M4 — tool allow/deny flags, `--version`, docs refresh, smoke tests.

## Coordination rules

- CLAIM a file/area on the bus before editing it. main.zig is shared → coordinate.
- Keep new code in its own file; expose a small public fn so the other side calls it.
- Rebuild (`zig build`) before every commit; keep tree green.
