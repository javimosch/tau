---
name: tau-maintenance
description: Maintain the tau codebase (Zig 0.16, non-interactive agent-first CLI). Use when the user asks to add a feature, harden existing code, write smoke tests, or resume work on recent additions (Author<->Critic loop, tau fleet subcommand, --role flag, fleet.zig orchestration). Covers the project layout, the Config struct, allocator conventions, validation commands, and a checklist of known gaps.
---

# tau-maintenance

A maintenance skill for the **tau** codebase — a Zig 0.16, non-interactive, agent-first reimplementation of `pi`. JSON-first, semantic exit codes, single binary. This skill ships in-repo at `.agents/skills/tau-maintenance/`; paths below are relative to the repo root.

## Project at a glance

- **Language**: Zig 0.16.0
- **Build**: `zig build` (binary -> `zig-out/bin/tau`)
- **Test**: `zig build test` (unit tests embedded in source files)
- **Smoke**: `./scripts/smoke.sh` (offline) or `./scripts/smoke.sh --net` (online)
- **Runtime deps**: `curl` on PATH for LLM HTTP; no other deps
- **Storage**: `~/.config/tau/config.json`, `~/.config/tau/sessions/<name>.json`, `~/.config/tau/fleets/<id>.json` (new), `~/.config/tau/acp.{sock,pid,log}` for the ACP daemon
- **Providers**: `xiaomi` (default), `openai`, `deepseek`, `opencode-go` (endpoint `opencode.ai/zen`, model `deepseek-v4-flash`) — see `src/llm/provider.zig` `providers` table. NOTE: a `config.json` `provider` does **not** auto-set `endpoint` (stays at the struct default = `providers[0]` = xiaomi); the CLI resolves `provider→endpoint` at parse time (see the resolution gotchas below).

## File map (entry points first)

| File | Purpose |
|---|---|
| `src/main.zig` | CLI parse -> dispatch (`.run` | `.acp` | `.fleet` | `.skills` | `.models` | `.guide` | `.help` | `.version` | `.help_json` | `.err`). Owns `help_text` and `flag_specs` (single source of truth — must stay in sync) + the embedded `guide_*` consts. |
| `src/args.zig` | Argv parser. `Action` enum + `Parsed` struct. `acp` and `fleet` are handled before the generic flag loop because they are commands, not prompts. |
| `src/agent.zig` | Single-turn agentic tool loop. `effectiveSentinel(cfg)` chooses between `cfg.exit_sentinel` (A/C), `<GOAL_MET>` (goal mode), or `null` (plain). |
| `src/goal.zig` | Goal directive + `<GOAL_MET>` sentinel + `NUDGE` + `parse` for `/goal status|pause|resume|clear|complete` subcommands. |
| `src/loop.zig` | **NEW** — Author<->Critic primitive. `AuthorCriticSpec`, `READY_FOR_REVIEW` / `APPROVED` / `BLOCKED` sentinels, `authorDirective` / `criticDirective` builders, `runAuthorCritic` orchestrator. |
| `src/fleet.zig` | **NEW** — `FleetSpec` / `WorkItem` / `Manifest` types, `coordinatorDirective`, `extractCoordinatorJson`, `topoSort` (cycle detection), `dispatch` with subcommands `run | status | list | logs | cancel`. |
| `src/config.zig` | `Config` struct + `Role` enum + `AcpSub` enum + `OutputMode` + `resolveApiKey` precedence. New fields for A/C + fleet. |
| `src/acp.zig` | ACP server. `tau acp serve` = JSON-RPC over stdio (or Unix socket); `PROTOCOL_VERSION=1`, `session/new` best-effort chdirs to the workspace `cwd`, streams `session/update` (`tool_call` / `agent_message_chunk`), ends each turn with the `session/prompt` response `{stopReason}` (the contract embedding ACP clients rely on). Daemon mgmt (`start`/`stop`/`status`) is POSIX-only. **`serve()` must resolve `provider→endpoint` + `TAU_ENDPOINT` itself** — see the resolution gotchas below. |
| `src/llm/provider.zig` | `Message` / `ToolCall` / `Response` / `ToolInfo` types. `complete` (blocking) + `completeStreamWithTools` (SSE) + delta extractors (heavily unit-tested). |
| `src/session.zig` | `SessionState` + `GoalState` JSON persistence at `~/.config/tau/sessions/`. |
| `src/context.zig` | Auto-compaction when estimated tokens > `compact_threshold` fraction of `context_window`. |
| `src/tools/{bash,read,write,edit,ls,grep,find}.zig` | Built-in tools. Allowlisted via `--tools <csv>` / denied via `--exclude-tools <csv>`. |
| `src/json.zig` | Hand-rolled escape/unescape + field extraction. |
| `src/term.zig` | Portable stdout/stderr wrapper. |
| `src/configfile.zig` | Loads `~/.config/tau/config.json` as defaults — sets `provider`/`model`/`api_key`/`keys` only, **never `endpoint`** (a config `provider` alone leaves `endpoint` at the xiaomi default until the CLI resolves it). |

## Recent additions (June 2026)

### Author<->Critic loop (`src/loop.zig`)
- `Role` enum added to `src/config.zig`: `none | author | critic | coordinator`
- New `Config` fields: `role`, `exit_sentinel`, `feedback_message`
- `agent.zig` injects role-specific directive when `cfg.role != .none`, uses `cfg.exit_sentinel` for termination, and prepends `cfg.feedback_message` to the user turn
- New CLI flag: `--role author|critic|coordinator|none`
- Sentinels: `READY_FOR_REVIEW` (author exit), `APPROVED` (critic done), `BLOCKED` (critic wants changes)
- `runAuthorCritic` is wired in `loop.zig` and reads the last assistant content from the per-role session JSON to detect sentinels

### Fleet (`src/fleet.zig` + `tau fleet ...`)
- New subcommand: `tau fleet <run|status|list|logs|cancel> ...`
- Manifest persistence at `~/.config/tau/fleets/<id>.json`
- Coordinator is an LLM turn with no tools; it returns a JSON work breakdown matching the schema in `coordinatorDirective`
- `topoSort` enforces execution order from `depends_on` and detects cycles (`error.Cycle`)
- `buildSpec` accepts either pre-supplied `?[]const WorkItem` or a coordinator LLM turn
- `runCmd`: spawns `tau --role author` per work item, checks session files for `<READY_FOR_REVIEW>` sentinel, supports parallel (wave-based) and sequential dispatch
- `cancelCmd`: rewrites `global_status` to `.cancelled`, verifies via reload

### Argv changes (`src/args.zig`)
- New `Action.fleet` variant, parallel to `.acp`
- Fleet subcommand parser runs before the generic flag loop
- New `--role` flag in the generic loop
- `args.zig` adds `_ =` discards as needed for parameter analyzer quirks

### Guide command (`tau guide`)
- Implements **cli-guide-spec** (https://cli-specs.intrane.fr/): `tau guide` emits the embedded operator
  manual as JSON (top-level keys `one_liner`/`model`/`loop`/`concepts`/`commands`/`examples`/`gotchas`/
  `see_also`/`version`); `tau guide --human` renders the same as markdown. **Embedded — no runtime fetch.**
- Wiring mirrors `models`/`skills`: `Action.guide` (`args.zig`), a `guide` subcommand branch parsed before
  the generic flag loop (`--human` → `config.guide_human`), and `printGuideJson`/`printGuideHuman` in
  `main.zig` fed by single-source `guide_*` consts (`GuideItem` = `{a,b}`). Smoke group: `guide`.
- When the CLI surface changes, update the `guide_commands`/`guide_gotchas` consts (they're hand-curated,
  not derived from `flag_specs`).

## Allocator / API conventions

- All public functions that allocate take `gpa: std.mem.Allocator` and `arena: std.mem.Allocator` explicitly (process-level). `gpa` is freed manually; `arena` is the per-process scratch space.
- `Config` is passed by value with `anytype` in some helpers (`provider_mod.complete`, `agent_mod.run`) — use `anytype` not `Config` so the test suite can inject mock configs.
- `[]const u8` strings owned by the arena are sliced out of `argv_list` / `msg_parts` / `sys_parts` and live for the process lifetime.
- LLM HTTP uses `std.process.run` with `curl`; never block on stdin.
- `saveManifest` / `loadManifest` are best-effort: failures are logged to stderr, not propagated.

## Provider / endpoint / key resolution (gotchas)

- **Endpoint resolution happens at CLI parse time, not in config.** `configfile.load` sets only
  `provider`/`model`/`api_key`/`keys`; it never sets `endpoint`, which stays at the struct default
  (`providers[0]` = xiaomi). The non-fleet and fleet arg paths resolve `provider → providers[].endpoint`
  then apply a **`TAU_ENDPOINT`** override — that env var points tau at any OpenAI-compatible endpoint
  (e.g. OpenRouter `https://openrouter.ai/api/v1/chat/completions`).
- **The `acp` subcommand returns from `args.parse` BEFORE that endpoint step**, so historically
  `tau acp serve` always POSTed to the xiaomi endpoint regardless of the configured provider → any
  non-xiaomi key failed with `AuthFailed`. Fixed (`25f7b98`) by resolving `provider→endpoint` + honoring
  `TAU_ENDPOINT` inside `acp.zig serve()`. **Any new early-returning subcommand must resolve its own endpoint.**
- **`resolveApiKey` precedence**: config `api_key` > `keys[provider]` > provider env var > global `api_key`
  > `TAU_API_KEY` > provider builtin. A **stale config-file `api_key` silently outranks `TAU_API_KEY`** —
  to force an env key, use a config with **no** `api_key`. And `tau acp serve` reads **no** model env var
  (model = config file or `--model`), so a per-invocation model override isn't possible via env there.

## Validation commands

```bash
cd <repo-root>   # this repository

# Compile (fast — does not run tests)
zig build

# Full test suite
zig build test

# Smoke (offline — JSON shape, exit codes, help, subcommand parsing)
./scripts/smoke.sh

# Smoke (online — requires TAU_API_KEY / XIAOMI_API_KEY / OPENAI_API_KEY)
./scripts/smoke.sh --net

# Help text must stay in sync with flag_specs (enforced by a unit test in main.zig)
./zig-out/bin/tau --help
./zig-out/bin/tau --help-json
```

## Portable builds (CPU baseline)

`zig build -Doptimize=ReleaseSafe` targets the **host** CPU's instruction set, so a binary built on a
newer machine can crash with **`Illegal instruction` (exit 132)** on an older / different deploy host —
common on VMs and LXC containers where the effective CPU baseline differs from what the guest advertises.
Build with a conservative baseline for a portable binary:
```bash
zig build -Doptimize=ReleaseSafe -Dcpu=x86_64_v2   # ~Sandy Bridge (2011); runs on virtually all x86-64 hosts
```
Trade-off: slightly larger (~+0.1 MB) and a few % slower, but portable. If you hit exit 132, check the
deploy host's CPU (`cat /proc/cpuinfo | grep 'model name' | head -1`) and rebuild with `-Dcpu=x86_64_v2`.

## Known gaps / next steps

### High-priority (harden the work just done)
- [x] **`cancelCmd` real persistence**: Now rewrites `global_status` and verifies via reload.
- [x] **`runCmd` async result collection**: Now checks worker session files for `<READY_FOR_REVIEW>` sentinel after each wave, with `.blocked` status for items whose dependencies failed.
- [x] **Coordinator parsing robustness**: `extractCoordinatorJson` now handles `<think>` / `<thinking>` blocks and prose-before-JSON. Added `sanitizeUtf8` to all parsed string fields.
- [x] **`runAuthorCritic` token tracking**: `agent.run()` accumulates `response.total_tokens` (parsed from `usage.total_tokens` via `extractUsage()`) across loop iterations, with `(content.len + 3) / 4` fallback. `loop.zig` `runAuthorCritic()` accumulates Author + Critic turns into `LoopResult.total_tokens`. Persisted to session as `GoalState.tokens_used`.
- [x] **`parseWorkItem` strictness**: Now logs the offending item index before returning `error.InvalidWorkItem`, and sanitizes all string fields to valid UTF-8.

### Medium-priority (smoke tests for the new code)
- [x] Add to `scripts/smoke.sh`:
  - `tau --role critic --tools read,grep,ls "no-op prompt"` exits 0 (and JSON shape unchanged)
  - `tau --role invalid` exits 80
  - `tau fleet status nonexistent` returns `{"fleet":null}` and exits 0
  - `tau fleet list` returns `{"fleets":[]}` on a fresh machine
  - `tau fleet run` without `--goal` exits 82
  - `tau fleet cancel nonexistent` returns `{"fleet":null}` (current behavior)
  - Help text mentions `--role` and the new fleet subcommands
- [x] Round-trip test for `Manifest` JSON: write a known manifest, read it back, assert equality (mirrors the existing `session.zig` round-trip test).

### Low-priority (polish)
- [x] Document the Author<->Critic + fleet features in `README.md` (the only docs surface that ships with the binary).
- [~] Consider extracting a shared `helpers.zig` for the `term.out("...")` boilerplate in fleet `*Cmd` functions (deferred: low ROI)
- [x] `buildSpec` `env` parameter already removed from signature (no longer takes env)

## Zig 0.16 gotchas (learned the hard way)

1. **`orelse try` requires a block**:
   ```zig
   // WRONG:
   const id = fleet_id orelse try std.fmt.allocPrint(arena, "fleet-{d}", .{ts});
   // RIGHT:
   const id = fleet_id orelse blk: {
       const ts = std.Io.Clock.Timestamp.now(io, .real).raw.toMilliseconds();
       break :blk try std.fmt.allocPrint(arena, "fleet-{d}", .{ts});
   };
   ```

2. **`if (x) |y| defer ...;` is invalid**. `defer` must be at statement level. Refactor to:
   ```zig
   const cr: ?[]u8 = built.coordinator_response;
   defer if (cr) |c| gpa.free(c);
   ```

3. **Empty string literal `""` is `*const [0:0]u8`**, not `[]const u8`. The orelse result type then mismatches the optional slice branch. Use `&.{}` (empty slice literal) or an explicit `const x: []const u8 = ...`:
   ```zig
   const fid: []const u8 = fleet_id orelse &.{};
   ```

4. **`spawn` returns `*const Child`** when used with `catch null`. To call `wait`, use a mutable `var` and dereference with `|*ch|`:
   ```zig
   var child = std.process.spawn(...) catch null;
   if (child) |*ch| { _ = ch.wait(io) catch {}; }
   ```

5. **Zig 0.16 analyzer sometimes flags `*std.process.Environ.Map` parameters as "unused"** when the body uses them only inside an `if (...)` branch (or when the early-return path doesn't reach them). Adding `_ = env;` at the top of the function with a comment is the current workaround. If you see this in a function whose body clearly uses the parameter, add the discard and move on.

6. **`?[]const T` fields cannot be assigned to after struct init** without a temporary. Build with `std.ArrayList` + `toOwnedSlice`:
   ```zig
   var deps_storage = std.ArrayList([]const u8).empty;
   for (...) |x| try deps_storage.append(gpa, x);
   const deps = try deps_storage.toOwnedSlice(gpa);
   ```

7. **In JSON parameter strings, `\\\\\"` decodes to `\\"`** (one backslash, one quote). The Zig file sees `\\"` correctly. If you see `\\\\` in the actual file, you double-escaped.

## When asked to "do remaining"

Default execution order:
1. **Smoke tests** (`scripts/smoke.sh`) — locks in the v0 surface; add coverage for any new features or bug fixes.
2. **README** — the only docs surface that ships; keep the CLI cheatsheet in sync with new flags and subcommands.
3. Run `zig build test` after each cluster of changes; if it passes, do `git add -p` and commit.

If a change is risky (touches the LLM HTTP path or the agentic tool loop), add a unit test first and a smoke test second. Both should pass before the commit.

## Key file locations quick reference

- Manifest persistence: `~/.config/tau/fleets/<id>.json`
- Session persistence: `~/.config/tau/sessions/<name>.json`
- Config: `~/.config/tau/config.json`
- ACP socket/pid/log: `~/.config/tau/acp.{sock,pid,log}`
- Tests live in their own files (last `test "..."` block); run via `zig build test`

## Smoke test caveats (learned from experience)

### 1. Bench guard requires API key

The `test_group_bench_smoke` in `scripts/smoke.sh` recursively invokes `smoke.sh --bench --group=help`. The `--bench` flag triggers `run_benchmarks` which calls `benchmark-resources.sh`, which makes real LLM calls (single-shot, tool-bash, session-create, session-recall). Without a configured API key, the benchmarks exit 106 (auth failed), causing the bench guard test to fail.

**Workaround**: Run offline smoke tests with an explicit group filter that excludes `bench`:
```bash
./scripts/smoke.sh --group=help,flags,role,fleet,issue11,model,acp,goal,dry-run,session-validation,fleet-items,invalid-numeric,fleet-flags
```
Or use `--list-groups` to see all groups and compose a bench-free filter.

### 2. `:slow` marker is not enforced by dispatch

The `bench` entry has a `:slow` marker (`"bench:test_group_bench_smoke:slow"`) but the offline dispatch loop only skips `:network` entries, not `:slow`. So the bench guard always runs in offline mode, adding ~10s to every smoke run.

### 3. `set -e` + `grep -q` can cause spurious exit code 1

The smoke harness uses `set -u` (no `set -e` in smoke.sh), but `capture()` temporarily does `set +e ... set -e`. When a `grep -q` inside `if [ ... ] && printf ... | grep -q` fails to match, the `set -e` can terminate the script. If smoke.sh exits 1 with all tests showing "ok", suspect a grep mismatch in the last test that ran — check that test's expected output pattern.

### 4. PATH requirement for fleet worker spawns

`fleet.zig`'s `runCmd` spawns `tau --role author` as a subprocess. The smoke harness adds `zig-out/bin` to PATH:
```bash
export PATH="$ROOT/zig-out/bin:$PATH"
```
When running tau fleet commands manually, ensure `tau` is on PATH or use the full binary path.

### 5. Session/fleet cleanup patterns

The smoke harness auto-cleans `smoke-*` sessions and fleets via `cleanup_sessions` and `cleanup_fleets`. For manual cleanup after crashed tests:
```bash
rm -f ~/.config/tau/sessions/smoke-*.json
rm -f ~/.config/tau/fleets/smoke-*.json
```
Agents should clean these before re-running smoke tests to avoid stale state interference.

### 6. `--group` flag supports both space and `=` forms
```bash
./scripts/smoke.sh --group=help,fleet     # = form
./scripts/smoke.sh --group help,fleet     # space form
```
Comma-separated group names; use `--list-groups` to see available groups.

### 7. Debug env vars for smoke tests
```bash
SMOKE_DEBUG=1 ./scripts/smoke.sh          # Verbose diag output on stderr
SMOKE_VERBOSE=1 ./scripts/smoke.sh        # Print test names as they run
SMOKE_TRACE=1 ./scripts/smoke.sh          # bash -x tracing
SMOKE_LOG=/tmp/smoke.log ./scripts/smoke.sh  # Append all output to log file
TAU_BIN=/custom/path/tau ./scripts/smoke.sh  # Override binary path
```

### 8. `--net` smoke tests need API key + network

Online tests make real LLM calls. The harness checks `TAU_API_KEY`, `XIAOMI_API_KEY`, `OPENAI_API_KEY`, `DEEPSEEK_API_KEY`, and `~/.config/tau/config.json` for an `api_key` field. If none found, network tests are skipped with a warning.

### 9. Fleet worker sessions are per-role per-iteration

When `tau fleet run` dispatches workers, each worker creates session files named:
```
~/.config/tau/sessions/<fleet-id>-<item-id>-<role>-<iter>.json
```
These accumulate quickly. The smoke harness cleans `smoke-*` patterns; for production fleets, monitor and prune old session files.

### 10. `tau fleet cancel nonexistent` works

Despite `cancelCmd` being an in-memory stub (known gap), `tau fleet cancel <nonexistent-id>` returns `{"fleet":null}` with exit 0. This means cancel-on-missing-id is graceful — no crash, no error exit code.
