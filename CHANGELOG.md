# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

> **Note:** Only `v0.4.0` has a git tag and GitHub release (with a prebuilt
> binary asset). Earlier versions were bumped in source but never tagged, so
> their entries below are reconstructed from the commit history.

## [Unreleased]

Changes merged since `v0.4.0`. No breaking changes — all fixes and additions
are backward compatible.

### Added

- `TAU_ENDPOINT` env var — point tau at any OpenAI-compatible server (#64)
- Per-provider API keys in the config file via the `keys` object (#31)
- Shell completions for bash and zsh (`completions/`) (#46)
- `examples/` — runnable end-to-end tau session scripts (#42)
- Actionable error messages with recovery hints for missing API key, unknown
  provider, and malformed config (#43)
- `CONTRIBUTING.md` — build, test, and PR workflow guide (#62)
- GitHub issue and PR templates (#63)
- `docs/configuration.md` — configuration reference covering config keys, env
  vars, and precedence, including per-provider setup examples (#109, #120)
- `docs/acp.md` — ACP editor-integration guide (Zed `agent_servers` config) (#114)
- `tau models` subcommand — list providers and their default models
- Fleet parser accepts `--provider`, `--model`, and `--api-key` overrides

### Fixed

- Streaming: honor `--timeout-ms` on SSE requests (#76); tolerate whitespace in
  SSE tool-call and reasoning parsers (#68)
- Provider response parsing: whitespace after JSON colons (#66) and before
  `usage.total_tokens` (#106); only top-level non-null `error` fields are
  treated as failures (#99); tool-argument accessors tolerate all JSON
  whitespace around colons (#101)
- JSON output escaping: skills list/search (#70), `--scan-agents` (#75), model
  id (#78), provider and skill names/content (#91), error and warn stderr
  envelopes (#77)
- `--no-tools` is now honored in the main agent loop (#71)
- `--temperature` / `--max-tokens` are serialized into the API request body (#72)
- `--schema` is respected during `--dry-run` planning turns, with and without
  tools (#95, #97)
- `--help-json` lists the text output mode (#96); help text and `--help-json`
  kept in sync with actual CLI capabilities (#98)
- Switching providers no longer leaks a stale provider-specific model (#93)
- Fleet: brace-balanced `{"items":[...]}` extraction from coordinator
  responses (#73, #81); forward worker/coordinator model overrides to worker
  subprocesses (#74); persist per-worker status incrementally in parallel
  waves (#86); resolve `--provider`/`--model` to endpoint and default model (#103)
- API key resolution skips empty values at every precedence level (#104);
  config-file `model` and `context_window` matching in-code defaults are
  preserved (#102)
- ACP: `initialize` reports the correct package version (#100); socket path
  escaped in daemon status JSON (#105)
- `read` tool hardened against shell/special characters in paths (#94)
- Skill search is case-insensitive (#90)
- Session save failure warns instead of failing silently (#78)

### Tests

- New unit-test suites: CLI arg parser (#36), file tools (#37), configfile
  (#39), ACP (#47), JSON helpers (#50), bash tool (#51), tool registry (#53),
  provider module (#58), `resolveApiKey` precedence (#59), goal + session
  (#63), AGENTS.md scanning (#110), agent loop tool dispatch (#112), SSE
  streaming frames (#117), context compaction boundaries (#121)
- Smoke suite: `--role critic` network check (#88), `--api-key` parsing (#89)
- Fixed SIGABRT in `scanAgentsMd` bad-path test (#55); restored truncated
  `extractToolCalls` test (#69)

## [0.4.0] - 2026-06-12

### Added

- `--schema <json|@file>` — constrain model output to a JSON Schema via the
  OpenAI-compatible `response_format` parameter; the fleet coordinator uses it
  automatically when set (#28)
- AGENTS.md scanning: `--scan-agents` walks the CWD, `--load-agents-md <path>`
  injects a file into the system prompt, `--auto-agents-md` loads
  `cwd/AGENTS.md` on startup (#29)
- Skills autodiscovery from `~/.agents/skills/` — `tau skills list`,
  `tau skills search <query>`, `tau skills load <name>` (#29)

No breaking changes — all additions are opt-in flags and subcommands.

## [0.3.0] - 2026-06-10

### Added

- Author↔Critic loop — `--role author|critic|coordinator|none` with
  sentinel-based termination (`<READY_FOR_REVIEW>`, `<APPROVED>`, `<BLOCKED>`)
- Fleet orchestration — `tau fleet run|status|list|logs|cancel`; a coordinator
  LLM decomposes a goal into work items and workers re-invoke tau per item;
  manifests persist to `~/.config/tau/fleets/`; coordinator retry and
  `--items` wiring for pre-supplied work items
- Real API usage tracking — `usage.total_tokens` parsed from provider
  responses and wired through the agent loop, Author↔Critic, and fleet
- `docs/harden-stabilize-check.md` — end-to-end verification checklist;
  smoke suite gained `--group`/`--list-groups`/`--bench` filtering

### Fixed

- Fleet: dangling `depends_on` pointers, endpoint/API-key resolution, UTF-8
  segfault, and hardened `cancel` persistence with better `parseWorkItem`
  error context (#10)
- Deterministic `APPENDED_99` smoke test

## [0.2.0] - 2026-06-05

Major feature build-out: rebrand to **tau**, tool calling, streaming, sessions,
goal mode, compaction, ACP, and cross-platform support.

### Added

- Rebrand `piz` → `pizig` → `tau`; non-interactive, agent-first CLI plumbing
- Provider abstraction, tool registry, and multi-turn agentic tool loop
- Seven built-in tools working end-to-end: `bash`, `read`, `write`, `edit`,
  `ls`, `grep`, `find`
- Real SSE streaming (`--stream` default) and JSON-default output
- `--thinking` (reasoning chunks), `--debug` (perf stats + tool I/O),
  `--dry-run` (plan tool calls without executing), `--max-iterations` backstop
- Config file (`~/.config/tau/config.json`), session persistence
  (`--session`), goal mode (`/goal` with sentinels), and automatic context
  compaction (`--compact-*` flags)
- ACP server — `tau acp serve|start|stop|status`, JSON-RPC 2.0 over stdio for
  Zed integration; per-session persistence, history compaction, and
  editor-routed writes (`fs/write_text_file` for diff-visible edits)
- Cross-platform support (macOS + Windows)
- `scripts/smoke.sh` end-to-end test harness and resource benchmarks

### Security

- Removed the hardcoded API key — keys now come only from `--api-key`, env
  vars, or the config file
- Tool-argument validation: reject `..` path traversal, null bytes, and empty
  bash commands

### Fixed

- `write` tool uses the Io API instead of shell — handles quotes and creates
  parent directories
- ACP: `session/load` protocol gap (Zed "not supported" error), context
  overflow via compaction + message cap, editor-write fallback to direct
  execution
- Transient HTTP errors retried with backoff; HTTP 401 surfaces as
  `auth_failed` (exit 106)
- Table-driven `buildToolArgs`; `--help-json` generated from the `flag_specs`
  table so it can't drift from the parser

## [0.1.0] - 2026-06-03

### Added

- Initial implementation as `piz` — an agent-first AI CLI written in Zig
- JSON-first output with `--stream` streaming flag
- `--help-json` machine-readable help and semantic exit codes
  (0, 80, 82, 105, 110)
- Xiaomi provider (`mimo-v2.5`) as the default backend

[Unreleased]: https://github.com/javimosch/tau/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/javimosch/tau/releases/tag/v0.4.0
[0.3.0]: https://github.com/javimosch/tau/commit/57ecad25
[0.2.0]: https://github.com/javimosch/tau/commit/a31ed23e
[0.1.0]: https://github.com/javimosch/tau/commit/ae04b1bb
