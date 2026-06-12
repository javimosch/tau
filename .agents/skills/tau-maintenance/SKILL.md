---
name: tau-maintenance
description: Maintain the tau codebase (Zig 0.16, non-interactive agent-first CLI). Use when maintaining, extending, or debugging tau.
---

# tau-maintenance (local — tau project)

A maintenance guide for the **tau** codebase — a Zig 0.16, non-interactive, agent-first CLI. Lives at this project root.

## Build & Test

```bash
zig build                    # Compile (binary → zig-out/bin/tau)
zig build test               # Full test suite
./scripts/smoke.sh           # Offline smoke tests
./scripts/smoke.sh --net     # Online smoke tests
```

## Project at a glance

| File | Purpose |
|---|---|
| `src/main.zig` | CLI parse → dispatch. Owns `help_text` and `flag_specs` (must stay in sync). |
| `src/args.zig` | Argv parser. `Action` enum + `Parsed` struct. |
| `src/agent.zig` | Single-turn agentic tool loop. |
| `src/goal.zig` | Goal directive + `<GOAL_MET>` sentinel. |
| `src/loop.zig` | Author↔Critic primitive. |
| `src/fleet.zig` | Fleet orchestration (run/status/list/logs/cancel). |
| `src/config.zig` | `Config` struct + `Provider` / `Role` / `AcpSub` enums. |
| `src/acp.zig` | Agent Client Protocol server. |
| `src/llm/provider.zig` | `Message` / `ToolCall` / `Response` / `complete` / `completeStreamWithTools`. |
| `src/session.zig` | Session persistence at `~/.config/tau/sessions/`. |
| `src/context.zig` | Auto-compaction at threshold fraction of context_window. |
| `src/skills.zig` | Skills autodiscovery (`tau skills list\|search\|load`). |
| `src/agents_md.zig` | AGENTS.md scanner (`--scan-agents`). |
| `src/tools/{bash,read,write,edit,ls,grep,find}.zig` | Built-in tools. |

## Known issues (v0.4)

- **Skills JSON escape**: descriptions with `"` produce malformed JSON. Fix: escape before `{s}` insertion.
- **Fleet cancel**: `global_status: cancelled` is in-memory only (not persisted across tau restarts).
- **Fleet worker results**: workers report `status: running` until the harness polls.
- **topoSort cycles**: surface as `{"code":110,"message":"toposort failed: Cycle"}`.
- **`--schema` + `--dry-run`**: schema flag is set but not applied to dry-run planning turn.

## Allocator conventions

- All public functions that allocate take `gpa: std.mem.Allocator` and `arena: std.mem.Allocator` explicitly.
- `gpa` is freed manually; `arena` is per-process scratch space.
- `Config` is passed by value with `anytype` in some helpers.
- `[]const u8` strings owned by the arena are sliced out of `argv_list` / `msg_parts` / `sys_parts`.

## Zig 0.16 gotchas

1. **`orelse try` requires a block** — use `orelse blk: { ... break :blk value; }`
2. **`if (x) \|y\| defer ...;` is invalid** — `defer` must be at statement level
3. **Empty string literal `""` is `*const [0:0]u8`** — use `&.{}` for empty slice
4. **`spawn` returns `*const Child`** — use `\|*ch\|` to call `wait`
