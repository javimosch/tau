# Changelog — June 2026 (Product)

This is the user-facing changelog for tau **v0.3.0**. See `changelog-2026-06.html` for the full product + technical view.

## v0.3.0 — Agent-first multi-agent toolkit

### ⚔️ Author↔Critic Loop

Adversarial self-review via two complementary roles. Each turn runs the same agentic tool loop with a role-specific system directive and exit sentinel:

- `author` — write/update code+tests, declare `<READY_FOR_REVIEW>` when done
- `critic` — read-only audit, emit `<APPROVED>` or `<BLOCKED>` with concrete defects

```bash
tau --role author --tools bash,read,write,edit,ls,grep,find --session proj-1 \
  "Build feature X and run the test suite."

tau --role critic --tools read,grep,find,ls --session proj-1 \
  "Audit the spec against the code in src/."
```

Lives in `src/loop.zig` as `AuthorCriticSpec` + `runAuthorCritic`; it composes two `agent.run()` calls per iteration with different `cfg.role` and tool allowlists.

### 🚁 Fleet Orchestration

A **fleet** is a goal + a work breakdown (set of work items) + a controller. A single coordinator LLM turn decomposes the goal into items with `depends_on` and `acceptance`; the controller then dispatches one `tau` worker per item (currently sequential, re-invoking `tau --role author` per item).

```bash
tau fleet run --goal "add OAuth login, persist sessions, and write tests"
tau fleet run --coordinator-model openai/gpt-4o-mini --goal "ship the redesign"
tau fleet list                      # active fleets
tau fleet status <id>               # full manifest
tau fleet logs <id>                 # per-worker session hint
tau fleet cancel <id>               # mark cancelled
```

Manifests persist to `~/.config/tau/fleets/<id>.json`; workers persist per-role sessions to `~/.config/tau/sessions/<fleet-id>-<item-id>-<role>-<iter>.json`.

### 🎯 Goal Mode + Sessions

Autonomous work with `/goal <objective>` syntax. The agent works in a tool-calling loop until it emits `<GOAL_MET>`, bounded by `--goal-max-iterations` (default: 50). Goal state persists in sessions, so you can `/goal status` later. Subcommands: `/goal status`, `/goal pause`, `/goal resume`, `/goal clear`, `/goal complete`.

```bash
tau --session myproject "/goal add a --version flag and verify it builds"
tau --session myproject "/goal status"
```

### 📊 Token Tracking & API Usage

Real token usage parsed from OpenAI-compatible API responses (`usage.total_tokens`) with a content-length approximation fallback. Wired through `agent.run()`, the Author↔Critic loop, and fleet workers so per-turn and per-fleet totals are visible.

### 🧪 Quality Hardening

- Unit tests for `extractUsage` (happy path, null, overflow, missing)
- Manifest JSON round-trip test
- Smoke suite expanded to **59 tests** covering all 7 tools, goal mode, role flag, fleet subcommands, and limits
- `--dry-run` JSON envelope: `{"dry_run":true,"tool_calls":[…]}` — no side effects

### 📡 Streaming + ACP

- Real SSE token-by-token streaming (text mode = raw deltas; JSON mode = NDJSON)
- Agent Client Protocol (ACP) over stdio: `tau acp start|stop|status|serve`
- Session/load now compacts history instead of clearing it
- ACP default system prompt nudges model to use tools to reconstruct state
- Editor writes route through `fs/write_text_file` (Zed-side diffs) with direct-execution fallback
