# tau Roadmap

## Vision

tau is an agent-first AI CLI — a non-interactive, programmatic counterpart to pi. Designed for AI agents and CI pipelines: JSON output, streaming responses, tool execution, and semantic exit codes. Written in Zig 0.16.

---

## Current State (v0.3.0)

### Core CLI

- **Providers**: xiaomi (default), openai, deepseek, opencode-go — switchable via `--provider` / `--model`. `--model provider/id` shorthand supported.
- **API key resolution**: config file > provider env var > `TAU_API_KEY` > `--api-key` flag
- **Streaming**: SSE delta streaming by default; `--no-stream` for batch
- **Output modes**: JSON (default); text with `--mode text`
- **Help**: `--help` human text, `--help-json` machine-readable flag schema (auto-generated from `flag_specs` table)
- **Version**: `--version`
- **System prompt**: `--system-prompt <text>` and `--append-system-prompt <text>` for persona/role injection

### Tools

- `bash` — shell command execution with security validation (path traversal, null bytes, empty commands)
- `read` — file read
- `write` — file write
- `edit` — in-place text replacement
- `find` — recursive file finder
- `grep` — pattern search
- `ls` — directory listing

Tool allowlist (`-t`), denylist (`-xt`), and disable-all (`-nt`) flags. `--dry-run` previews tool calls without executing. Table-driven `buildToolArgs` with per-field validation.

### Agent loop

- Multi-turn tool loop until model stops calling tools (like Claude Code / OpenCode)
- `--max-iterations` runaway backstop (default 100)
- `@file` syntax to inject file contents into the prompt
- Context compaction: `--compact-threshold`, `--compact-keep-recent`, `--no-compact`
- Per-request `--context-window` and `--compact-*` overrides

### Goal mode

- `/goal <objective>` — autonomous multi-turn loop until `<GOAL_MET>` sentinel
- `/goal --tokens N <objective>` — soft output-token budget
- `/goal status|pause|resume|clear|complete` — manage goal state (requires `--session`)
- NUDGE mechanic: pushes model to audit and confirm completion before emitting sentinel### Sessions

- `--session <name>` persists conversation history to `~/.config/tau/sessions/<name>.json`
- Multi-turn memory across invocations

## Author↔Critic Loop

- `--role author|critic|coordinator|none` for adversarial self-review
- Sentinels (one per line): author emits `<READY_FOR_REVIEW>`, critic emits `<APPROVED>` or `<BLOCKED>`
- Each role runs the same agentic tool loop with a role-specific system directive and tool allowlist
- Lives in `src/loop.zig` as `AuthorCriticSpec` + `runAuthorCritic`

## Fleet Orchestration

- `tau fleet run|status|list|logs|cancel` — multi-agent work breakdown and dispatch
- Coordinator LLM decomposes a goal into work items (`depends_on` + `acceptance`)
- Workers re-invoke `tau --role author` per item (sequential by default, `--parallel` for waves)
- Manifests persist to `~/.config/tau/fleets/<id>.json`
- Per-role sessions: `~/.config/tau/sessions/<fleet-id>-<item-id>-<role>-<iter>.json`

## ACP (Agent Client Protocol)

- JSON-RPC 2.0 over stdio (Zed integration)
- Methods: `initialize`, `authenticate`, `session/new`, `session/load`, `session/prompt`
- `session/load`: extracts sessionId + cwd, compacts prior history via LLM (fallback: last 20 messages)
- Context compaction per prompt turn (`shouldCompact` + `compact` before each `provider.complete`)
- Hard message cap (80) as overflow backstop
- Editor write routing: sends `fs/write_text_file` to Zed for diff-visible edits; falls through to direct execution on rejection
- Default system prompt: nudges model to use tools when asked about project state
- Daemon: `tau acp start/stop/status` (Linux/macOS)
- Thinking chunks in ACP via `emitThoughtChunk` (agent_thought_chunk notifications)

### Cross-platform

- Linux, macOS, Windows (portable I/O via `term.zig`; no Linux-only syscalls in hot paths)
- macOS atomic binary replace: `cp tau.new ~/.local/bin/tau && mv -f ...` (avoids "Text file busy")

---

## Open Issues

- **Reasoning visible in Zed**: `emitThoughtChunk` always sends verbose model deliberation to the Zed chat. No severity filter or toggle.
- **ACP fresh session UX**: on `session/new` with no history, the model defaults to no context. The default system prompt now addresses this — model is instructed to use tools to reconstruct state.

---

## Architecture

```
tau/
├── src/
│   ├── main.zig          # Entry point, FlagSpec table, printHelpJson
│   ├── args.zig          # CLI argument parser
│   ├── config.zig        # Config struct + key resolution
│   ├── configfile.zig    # ~/.config/tau/config.json loader
│   ├── agent.zig         # Agentic tool loop, buildToolArgs (table-driven)
│   ├── loop.zig          # Author↔Critic loop (AuthorCriticSpec + runAuthorCritic)
│   ├── acp.zig           # ACP server (JSON-RPC over stdio + Unix socket)
│   ├── context.zig       # Context compaction (shouldCompact + compact)
│   ├── session.zig       # Session persistence
│   ├── goal.zig          # /goal parsing, directive, sentinel logic
│   ├── fleet.zig         # Fleet orchestration (run/status/list/logs/cancel)
│   ├── json.zig          # JSON helpers + escape
│   ├── term.zig          # Portable stdout/stderr
│   ├── llm/
│   │   └── provider.zig  # Provider table, complete, completeStreamWithTools
│   └── tools/
│       ├── registry.zig  # Tool registry + getEnabledTools
│       ├── bash.zig
│       ├── read.zig
│       ├── write.zig
│       ├── edit.zig
│       ├── find.zig
│       ├── grep.zig
│       └── ls.zig
├── scripts/
│   ├── smoke.sh          # Smoke test harness (offline + --net)
│   ├── smoke-features.sh # Extended feature tests
│   ├── benchmark-resources.sh
│   └── lib/
│       └── smoke-lib.sh  # Shared test harness library (TAP output, capture, cleanup)
└── docs/
    ├── roadmap.md        # This file
    ├── changelog.html    # Index of monthly changelogs
    ├── changelog-2026-06.html / .md  # June 2026 product changelog
    ├── index.html        # Landing page
    └── harden-stabilize-check.md  # Pre-ship hardening checklist
```

---

## Semantic Exit Codes

| Code | Meaning                 |
|------|-------------------------|
| 0    | success                 |
| 80   | invalid_argument        |
| 82   | missing_required_field  |
| 105  | connection_timeout      |
| 106  | auth_failed             |
| 110  | internal_error          |
| 111  | unimplemented           |

---

## Potential Next Work

- Arena allocator in the tool loop (P2-2): reuse per-iteration allocation instead of GPA for tool result strings
- Reasoning filter in ACP: toggle or severity gate for `emitThoughtChunk`
- Web search tool
- Skills loader (`~/.agents/skills/*.md`) for composable agent behaviors
- `--output-file` flag for writing response JSON to disk
- Fleet: parallel worker execution + persistent `global_status: cancelled` on cancel
- Fleet: worker result collection harness (today workers report `running` until the harness polls)
