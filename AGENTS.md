# Tau Agent Guide

This guide helps AI agents work with the tau codebase and add new LLM providers.

## Project Overview

Tau is a non-interactive, agent-first AI CLI written in Zig (0.16.0). It's designed for AI agents, not humans, with JSON-first output and deterministic behavior.

## Key Architecture

- **Provider System**: Located in `src/llm/provider.zig`
- **Config**: Located in `src/config.zig` 
- **Main Entry**: `src/main.zig`
- **Agent Loop**: `src/agent.zig`
- **Goal Mode**: `src/goal.zig`

## CLI Cheatsheet — Using tau End-to-End

### Quick Reference: All Flags

```bash
tau [flags] "prompt"                    # Single-shot chat (JSON by default)
tau [flags] "prompt1" "prompt2" ...     # Multi-message user turns
tau [flags] "@file.txt" "prompt"        # Inject file content + prompt
```

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `-p, --print` | — | on | Non-interactive mode (always on) |
| `--provider <name>` | string | xiaomi | LLM provider: xiaomi, openai, deepseek |
| `--model <id>` | string | provider default | Model id or `provider/id` shorthand |
| `--api-key <key>` | string | — | Override API key |
| `--system-prompt <text>` | string | — | Set system prompt |
| `--append-system-prompt <text>` | string | — | Append to system prompt (repeatable) |
| `--mode <text\|json>` | enum | json | Output format |
| `--no-stream` | flag | — | Disable SSE streaming (streaming is default) |
| `-t, --tools <csv>` | string | all | Allowlist tool names |
| `-xt, --exclude-tools <csv>` | string | — | Denylist tool names |
| `-nt, --no-tools` | flag | — | Disable all tools |
| `--thinking` | flag | off | Show thinking/reasoning chunks |
| `--debug` | flag | off | Log perf stats + tool I/O to stderr |
| `--dry-run` | flag | off | Plan tool calls, execute none |
| `--temperature <f>` | float | 0.7 | Sampling temperature |
| `--max-tokens <n>` | int | — | Cap output tokens |
| `--timeout-ms <n>` | int | 120000 | HTTP timeout in ms |
| `--session <name>` | string | — | Persist to `~/.config/tau/sessions/<name>.json` |
| `--context-window <n>` | int | per-provider | Token capacity for compaction threshold |
| `--compact-threshold <f>` | float | 0.5 | Fraction of window that triggers compaction |
| `--compact-keep-recent <n>` | int | 20000 | Tokens kept verbatim after compaction |
| `--no-compact` | flag | — | Disable auto-compaction |
| `--role <author\|critic\|coordinator\|none>` | enum | none | Set agent role |
| `--schema <json\|@file>` | string | — | JSON Schema for structured output |
| `--scan-agents` | flag | — | Scan CWD for AGENTS.md files |
| `--load-agents-md <path>` | string | — | Load AGENTS.md file into system context |
| `--auto-agents-md` | flag | — | Auto-load cwd/AGENTS.md on startup |
| `--max-iterations <n>` | int | 100 | Tool-loop runaway backstop |
| `--goal-max-iterations <n>` | int | 50 | Per-run cap in goal mode |
| `--help-json` | — | — | Machine-readable help as JSON |
| `-h, --help` | — | — | Show help text |
| `-v, --version` | — | — | Show version |

### Output Formats

**JSON mode (default):**
```json
{"version":"0.4.0","model":"xiaomi/mimo-v2.5","content":"...","done":true}
```

**JSON streaming (NDJSON):**
```json
{"chunk":"token","done":false}
...
{"model":"xiaomi/mimo-v2.5","done":true}
```

**Text mode (`--mode text`):** Plain text on stdout.

**Error envelope (stderr):**
```json
{"err":{"code":80,"type":"invalid_argument","message":"..."}}
```

### Exit Codes

| Code | Meaning |
|------|---------|
| `0` | Success |
| `80` | Invalid argument (bad flag, unknown provider, etc.) |
| `82` | Missing required field (e.g., `fleet run` without `--goal`) |
| `105` | Connection timeout |
| `106` | Auth failed (bad/missing API key) |
| `110` | Internal error (HTTP failure, JSON parse error, etc.) |
| `111` | Unimplemented |

### Tools Reference

All tools send JSON-schema'd parameters to the model. Allowlist with `--tools <csv>`, denylist with `--exclude-tools <csv>`, disable all with `--no-tools`.

| Tool | Purpose | Key Params |
|------|---------|------------|
| `bash` | Execute shell commands | `command` (required) |
| `read` | Read file contents | `path` (required), `max_lines` |
| `write` | Create/overwrite files | `path`, `content` (required) |
| `edit` | Replace strings in files | `path`, `old_string`, `new_string` |
| `ls` | List directory contents | `path` (required) |
| `grep` | Search files with regex | `pattern` (required), `path` |
| `find` | Find files by glob pattern | `pattern` (required), `path` |

### Common Workflows

#### 1. Single-Shot (No Tools)
```bash
tau "What is Zig?"                           # JSON response
tau --mode text "Explain this error"          # Human-readable
tau --no-tools "What is 2+2?"                 # Force no tool use
tau --model openai/gpt-4o-mini "hello"        # Provider/model shorthand
```

#### 2. Tool-Calling Loop
```bash
tau --tools bash "Run: echo hello"            # Single tool
tau --tools bash,read,write "analyze src/"    # Multiple tools
tau --exclude-tools bash "list files"         # Deny specific tools
tau --no-tools "plain chat"                   # No tools at all
```

#### 3. Session Persistence
```bash
tau --session mywork "Remember: zig 0.16"     # Creates session
tau --session mywork "What zig version?"       # Recalls from history
# Session file: ~/.config/tau/sessions/mywork.json
```

#### 4. Goal Mode (Autonomous)
```bash
tau --session proj "/goal add tests for config"  # Start goal
tau --session proj "/goal status"                 # Check progress
tau --session proj "/goal pause"                  # Pause
tau --session proj "/goal resume"                 # Resume
tau --session proj "/goal clear"                  # Reset
tau --session proj "/goal complete"               # Mark done
# Goal budget: /goal --tokens 500K "objective"
```

#### 5. Author↔Critic Loop
```bash
# Author: code with tools, emit <READY_FOR_REVIEW> when done
tau --role author --tools bash,write,edit --session pr1 \
    "Implement feature X with tests"

# Critic: read-only review, emit <APPROVED> or <BLOCKED>
tau --role critic --tools read,grep,ls --session pr1 \
    "Review implementation against spec"

# Coordinator: decompose goal into work items (JSON)
tau --role coordinator --no-tools \
    "Decompose: add OAuth login"
```

#### 6. Fleet Orchestration
```bash
tau fleet run --goal "ship the redesign"          # Plan + dispatch
tau fleet run --goal "x" --items '{"items":[...]}' # Pre-supplied items
tau fleet run --goal "x" --coordinator-model openai/gpt-4o-mini
tau fleet run --goal "x" --sequential              # Sequential workers
tau fleet list                                     # Active fleets
tau fleet status <id>                              # Full manifest
tau fleet logs <id>                                # Per-worker session hints
tau fleet cancel <id>                              # Cancel fleet
```

#### 7. ACP Server
```bash
tau acp serve                        # JSON-RPC over stdio
tau acp serve --acp-socket /tmp/sock # Unix socket
tau acp start                        # Background daemon
tau acp status                       # Daemon status (JSON)
tau acp stop                         # Stop daemon
```

#### 8. File Injection & System Prompts
```bash
# @path expands to a user message containing the file contents
# It's positional: each @path arg becomes a separate user message
tau "@file.txt" "summarize this"                # 2 user messages: file content + prompt
tau --system-prompt "You are a critic" "review" # Set system prompt
tau --append-system-prompt "Be concise" "x"     # Append to system prompt
tau --append-system-prompt "A" --append-system-prompt "B" "x"  # Repeatable
```

#### 9. Dry-Run & Debugging
```bash
tau --dry-run --tools bash "touch /tmp/x"   # Plan only, no execution
tau --debug "test"                          # Stderr: perf stats + tool I/O
tau --thinking "complex reasoning task"     # Show model's thinking chunks
tau --max-iterations 1 --tools bash "x"     # Cap tool loops
```

#### 10. A2A Integration (a2a-spawn env vars)

The [a2a-spawn](https://github.com/javimosch/a2a-skill) script launches tau as a peer agent on the a2a message bus. It respects these environment variables:

| Env Var | Default | Effect |
|---------|---------|--------|
| `TAU_TOOLS` | `bash` | Tools passed to `--tools` (e.g., `TAU_TOOLS="bash,read"`) |
| `TAU_THINKING` | `0` | Set to `1` to enable `--thinking` (show reasoning chunks in agent logs) |
| `TAU_DEBUG` | `0` | Set to `1` to enable `--debug` (perf stats + tool I/O to stderr) |
| `TAU_BIN` | — | Override tau binary path (skips `./zig-out/bin/tau` → `~/ai/tau/zig-out/bin/tau` → `PATH` resolution) |

#### 11. Structured Output (JSON Schema)
```bash
tau --schema '{"type":"object","properties":{"result":{"type":"string"}}}' \
  --mode text "extract the main point"
tau --schema @schemas/work-breakdown.json \
  fleet run --goal "refactor auth"  # Fleet coordinator uses schema automatically
```

#### 12. Skills Autodiscovery
```bash
tau skills list                          # List all ~113 skills
# → {"skills":[{"name":"agent-memory-toolbox","description":"..."},...]}
tau skills search memory                 # Find memory-related skills
tau skills load agent-memory-toolbox     # Load skill into system context
# → {"skill":"agent-memory-toolbox","content":"# Agent Memory Toolbox..."}
```

#### 13. Model Discovery
```bash
tau models
# → {"providers":[{"name":"opencode-go","default_model":"deepseek-v4-flash",...}]}
```

#### 14. AGENTS.md Context
```bash
tau --scan-agents                        # Find AGENTS.md files in CWD
tau --load-agents-md ./docs/AGENTS.md \
  --mode text "follow the guide"         # Load specific AGENTS.md
tau --auto-agents-md \
  --mode text "follow project rules"     # Auto-load cwd/AGENTS.md
```

```bash
# Debug a misbehaving tau agent:
TAU_THINKING=1 TAU_DEBUG=1 a2a-spawn --cli tau --id debug-agent --kit-file kit.txt

# Give a tau agent read access to the codebase:
TAU_TOOLS="bash,read,ls,grep" a2a-spawn --cli tau --id reader --kit-file kit.txt

# Point to a custom tau build:
TAU_BIN="$HOME/ai/tau-custom/zig-out/bin/tau" a2a-spawn --cli tau --id custom --kit-file kit.txt
```

Hard flags set by a2a-spawn when launching tau: `-p --no-stream --max-iterations 40 --timeout-ms 300000`.

### Storage Paths

| Path | Purpose |
|------|---------|
| `~/.config/tau/config.json` | Provider, model, mode defaults |
| `~/.config/tau/sessions/<name>.json` | Session conversation + goal state |
| `~/.config/tau/fleets/<id>.json` | Fleet manifests (spec + per-item status) |
| `~/.config/tau/acp.sock` | ACP Unix socket (daemon mode) |
| `~/.config/tau/acp.pid` | ACP daemon PID file |
| `~/.config/tau/acp.log` | ACP daemon log |

### How to Extend Tau

#### File Map (by subsystem)

| File | What It Does | When to Edit |
|------|-------------|-------------|
| `src/main.zig` | CLI dispatch, `help_text`, `flag_specs` | Adding CLI flags, subcommands |
| `src/args.zig` | Argv parser, `Action` enum | Adding new subcommands |
| `src/agent.zig` | Single-turn agentic tool loop | Modifying agent behavior |
| `src/goal.zig` | Goal directive parsing + sentinels | Changing goal mode logic |
| `src/loop.zig` | Author↔Critic primitive | A/C loop changes |
| `src/fleet.zig` | Fleet orchestration | Fleet command changes |
| `src/config.zig` | `Config` struct + `Role` enum + key resolution | Adding config fields |
| `src/configfile.zig` | `~/.config/tau/config.json` loader | Config file format changes |
| `src/session.zig` | Session persistence | Session format changes |
| `src/context.zig` | Auto-compaction logic | Compaction algorithm |
| `src/llm/provider.zig` | LLM providers, HTTP, streaming | Adding providers |
| `src/llm/acp.zig` | ACP JSON-RPC server | ACP protocol changes |
| `src/tools/*.zig` | Built-in tools (bash,read,write,edit,ls,grep,find) | Adding/modifying tools |
| `src/tools/registry.zig` | Tool registry + allowlist/denylist | Registering new tools |
| `src/json.zig` | Hand-rolled JSON escape/unescape | JSON handling fixes |
| `src/term.zig` | Portable stdout/stderr | Terminal output changes |

#### Validation Commands

```bash
zig build                    # Compile (fast)
zig build test               # Full unit test suite
./scripts/smoke.sh           # Offline smoke: help, flags, parsing
./scripts/smoke.sh --net     # Online smoke: LLM calls (needs API key)
./scripts/smoke.sh --bench   # Resource benchmarks
./scripts/smoke.sh --group fleet,role  # Run specific groups
./scripts/smoke.sh --list-groups       # List all test groups
./scripts/smoke.sh --bench             # Smoke + resource benchmarks
./scripts/benchmark-resources.sh       # Standalone resource benchmarks
./zig-out/bin/tau --help               # Verify help text
./zig-out/bin/tau --help-json          # Verify JSON schema
```

#### Zig 0.16 Gotchas

1. **`orelse try` requires a block** — wrap in `blk: { ... break :blk ... }`
2. **`if (x) |y| defer ...;` is invalid** — use `const cr: ?[]u8 = ...; defer if (cr) |c| gpa.free(c);`
3. **Empty string `""` is `*const [0:0]u8`** — use `&.{}` for empty slices
4. **`spawn` returns `*const Child`** — use `var child = ...; if (child) |*ch| { ch.wait() }`
5. **Analyzer flags params as "unused"** in early-return paths — add `_ = env;` workaround
6. **`?[]const T` fields can't be reassigned** — use `ArrayList` + `toOwnedSlice`
7. **Config is passed by value** — use `anytype` in helpers so tests can inject mocks

## Adding New LLM Providers

### Step 1: Add Provider to Provider Table

Edit `src/llm/provider.zig` and add a new entry to the `providers` array:

```zig
pub const providers = [_]Provider{
    // ... existing providers ...
    .{
        .name = "provider-name",
        .endpoint = "https://api.example.com/v1/chat/completions",
        .default_model = "default-model-name",
        .env_keys = &.{"PROVIDER_API_KEY"},
        .context_window = 128_000,
    },
};
```

**Provider Fields:**
- `name`: Internal identifier (used in config and CLI args)
- `endpoint`: Full API endpoint URL for chat completions
- `default_model`: Default model to use if none specified
- `env_keys`: Array of environment variable names to check for API keys
- `context_window`: Model context window size in tokens (for compaction threshold)
- `builtin_key`: Optional hardcoded key (avoid for security)

### Step 2: Update Config File

Create or update `~/.config/tau/config.json` to use the new provider:

```json
{
  "provider": "provider-name",
  "model": "model-name",
  "api_key": "your-api-key-here"
}
```

**Config Fields:**
- `provider`: Must match a provider name from the provider table
- `model`: Specific model to use (or omit for provider default)
- `api_key`: API key (optional if using env var)

### Step 3: Build and Test

```bash
# Build tau
zig build

# Test the new provider
./zig-out/bin/tau --mode text "Say hello from new provider"
```

### Step 4: Debug Mode

If authentication fails, use debug mode to see the actual error:

```bash
./zig-out/bin/tau --debug --mode text "Test message"
```

## Provider Discovery from Other Tools

When syncing providers from other AI tools (OpenCode, Paseo, etc.):

1. **Find the provider config**: Look for JSON config files in the tool's config directory
2. **Extract key information**: 
   - API endpoint URL
   - Default model name
   - Authentication method
   - Environment variable names
3. **Map to tau structure**: Convert the external config to tau's Provider struct
4. **Test authentication**: Verify the API key works with tau's HTTP client

## Common Provider Patterns

### OpenAI-Compatible APIs

Most modern LLM providers use OpenAI-compatible APIs:

```zig
.{
    .name = "provider-name",
    .endpoint = "https://api.provider.com/v1/chat/completions",
    .default_model = "model-name",
    .env_keys = &.{"PROVIDER_API_KEY"},
    .context_window = 128_000,
}
```

### Custom Endpoints

Some providers use non-standard endpoints:

```zig
.{
    .name = "custom-provider",
    .endpoint = "https://custom.example.com/api/v1/generate",
    .default_model = "custom-model",
    .env_keys = &.{"CUSTOM_API_KEY"},
    .context_window: 256_000,
}
```

## API Key Resolution Order

Tau resolves API keys in this order:

1. Explicit `--api-key` CLI flag
2. Config file `api_key` field
3. Provider-specific environment variable (from `env_keys`)
4. Global `TAU_API_KEY` environment variable
5. Provider `builtin_key` (avoid using)

## Context Windows

Set appropriate context windows for compaction threshold:

- Small models: 32K-65K tokens
- Medium models: 128K-200K tokens  
- Large models: 256K-1M tokens

## Testing Checklist

- [ ] Provider added to `src/llm/provider.zig`
- [ ] Config created/updated in `~/.config/tau/config.json`
- [ ] `zig build` succeeds
- [ ] Basic test: `./zig-out/bin/tau --mode text "hello"`
- [ ] Tool calling test: `./zig-out/bin/tau --tools bash "echo test"`
- [ ] Debug mode shows no auth errors
- [ ] Context window is appropriate for model

## Troubleshooting

### Auth Failed (exit code 106)
- Check API key is correct
- Verify environment variable name matches `env_keys`
- Ensure endpoint URL is correct

### HTTP Request Failed (exit code 110)
- Check network connectivity
- Verify endpoint is accessible
- Use `--debug` flag to see actual error

### Timeout (exit code 105)
- Increase timeout with `--timeout-ms`
- Check if provider is experiencing issues
- Try a simpler model

## Existing Providers Reference

Current providers in tau:

| Provider | Default Model | Context Window | Env Var |
|----------|---------------|---------------|---------|
| xiaomi | mimo-v2.5 | 256K | XIAOMI_API_KEY |
| openai | gpt-4o-mini | 128K | OPENAI_API_KEY |
| deepseek | deepseek-chat | 65K | DEEPSEEK_API_KEY |
| opencode-go | deepseek-v4-flash | 204K | OPENCODE_API_KEY |

## File Size Limits

Keep source files under 500 LOC per global rules. If a file exceeds this limit, split or refactor it.