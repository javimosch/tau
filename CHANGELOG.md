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
- `docs/acp.md` — ACP editor-integration guide (Zed `agent_servers` config) (#114);
  expanded with copy-pasteable configs for JetBrains, VS Code, Neovim
  (avante.nvim, CodeCompanion.nvim), Emacs (agent-shell), and Toad (#158)
- `tau models` subcommand — list providers and their default models
- `tau doctor` — JSON setup diagnostics (config file parse, provider
  resolution, API key provenance, curl on PATH, endpoint reachability, and an
  optional `--deep` authenticated probe); `--offline` skips network checks
- `tau doctor --fix` — auto-remediates fixable outcomes behind confirmation:
  scaffolds a missing config (init semantics), moves an unparseable config to
  `config.json.bak` and re-scaffolds, tightens POSIX permissions to
  `0700`/`0600`, and installs/refreshes shell completions. Each fix needs an
  interactive y/N prompt (TTY) or `--yes` for non-interactive use; the report
  gains a `fixes` array and reflects the post-fix state. Also adds two
  diagnostics: `config_permissions` (loose dir/file bits warn — the file can
  hold API keys) and `shell_completions` (missing/outdated scripts warn)
- `tau doctor --json` — stream diagnostics as NDJSON for CI and support
  tooling: one `{"check":{...},"done":false}` event per check as it finishes,
  one `{"fix":{...},"done":false}` event per remediation under `--fix`, and a
  terminal `{"ok":...,"summary":{...},"done":true}` verdict. The default
  single-object report is unchanged
- `tau doctor --probe` — live-verify connectivity and credentials for every
  provider in the registry, not just the configured one: a `probe_<name>`
  reachability row plus a `probe_<name>_auth` row that resolves the provider's
  key (reporting its source only) and POSTs a one-token completion when one
  is found. Emits NDJSON check events under `--json`; skipped under
  `--offline`
- `tau doctor --selftest` — credential-free end-to-end verification that the
  installed binary actually works: spawns tau itself with a scrubbed
  environment (throwaway `HOME`, every provider key + `TAU_API_KEY`/
  `TAU_ENDPOINT`/`TAU_DEBUG_LOG` stripped, stub `TAU_API_KEY` injected) against
  a built-in loopback HTTP stub, and requires the canned reply to come back
  end-to-end. Loopback-only, so it runs under `--offline` — `tau doctor
  --offline --selftest` is a fully hermetic install check. Emits an NDJSON
  check event under `--json`; skips only when curl is unavailable
- `tau version --check` — non-blocking update check against the latest GitHub
  release: prints `checked`/`latest`/`update_available` (+ `update_url` when
  newer) and always exits 0, reporting `checked:false` with a `reason` when
  the lookup cannot run. `tau doctor` gained a matching `update_available`
  check that warns when a newer release exists. Opt out everywhere via
  `TAU_NO_UPDATE_CHECK=1`; `TAU_UPDATE_URL` overrides the lookup URL (for
  proxies/mirrors and `file://` stubs in tests); `doctor --offline` skips it
- `tau init` — write a commented starter `~/.config/tau/config.json` seeded
  from detected provider env keys (`--force`, `--stdout`, `--provider`)
- `tau setup` — one-shot onboarding: scaffolds the config (init), installs
  shell completions for the detected shell (`--shell bash|zsh|fish|pwsh|all`
  to override; scripts are embedded in the binary), configures editor ACP
  clients (`--client zed|nvim|vscode|jetbrains|all` — writes a minimal
  settings file or a paste-ready snippet under `~/.config/tau/snippets/`;
  without the flag it reports detected editors), and embeds the `doctor`
  health report; emits one NDJSON object per step plus a final verdict and
  exits non-zero when any step fails; idempotent on re-run
- `tau setup --yes`/`-y` and `--non-interactive` — explicit unattended
  contract for devcontainers, dotfiles, and CI (setup never prompts or reads
  stdin either way; the verdict records `"non_interactive":true`/`"yes":true`
  so scripts can assert it). Env equivalents honored at parse time (flag >
  env > detect): `TAU_YES`, `TAU_NONINTERACTIVE`, `TAU_SETUP_SHELL`,
  `TAU_SETUP_CLIENT`
- Shell completions for fish and PowerShell (`completions/tau.fish`,
  `completions/tau.ps1`); all four scripts now complete `init`, `setup`,
  `doctor`, and `guide`
- `tau config show` — print the resolved effective config (config file + env +
  CLI flags merged) as JSON with API keys redacted and their source reported
  (#140)
- `tau config validate [path]` — offline config-file validation for CI and
  pre-commit hooks; JSON report on stdout, exit 1 listing every problem
  (unknown keys, type mismatches, bad provider/mode, range violations) (#177)
- `tau config set|get|unset` — schema-validated, comment-preserving edits to
  the config file (git-config model) for CI and agent-driven setup; `set`
  creates the file atomically (`0600`), keys are `<field>` or `keys.<provider>`,
  secrets are redacted in output unless `get --raw` (#202)
- `tau config edit [path]` — open the config in `$EDITOR` (`TAU_EDITOR` >
  `VISUAL` > `EDITOR` > `vi`/`notepad`), validated on save with the same
  checks as `config validate`; a missing file is seeded with the `tau init`
  scaffold and misspelled keys get `did you mean "…"?` hints (#212)
- Fleet parser accepts `--provider`, `--model`, and `--api-key` overrides
- `--debug` now writes a redacted diagnostic log to
  `~/.config/tau/debug/<timestamp>.log` (override with `TAU_DEBUG_LOG`) and
  `{"err":...}` envelopes carry a `debug_log` link when a log is active (#167)
- Stable error catalog (`src/errors.zig`): every `{"err":...}` envelope now
  carries `code`, `type`, `message`, `recoverable`, a remediation `hint`, and
  the `docs` link — emitted from one shared formatter across main/agent/acp/
  fleet/helpers. Codes and `type` tags are documented as stable in
  docs/troubleshooting.md (#171)
- `tau version` subcommand — same `tau 0.4.0` output as `-v/--version`, plus
  `--verbose` for build metadata (git commit with `-dirty` marker, target
  triple, UTC build date, zig version) as a JSON object (or `key: value`
  lines under `--mode text`). The same `"build"` object now rides on the
  `tau doctor` report and `--json` verdict, and the `--debug` log header
  gains a `# build:` line — the triage trio for bug reports (#204). The
  build date honors `SOURCE_DATE_EPOCH` so release binaries stay
  byte-reproducible
- CI release workflow (`.github/workflows/release.yml`) publishing prebuilt
  `tau-<os>-<arch>.tar.gz` binaries for Linux and macOS on `v*` tags, plus a
  curl-able `install.sh` so adopters don't need a Zig toolchain (#143)
- Release smoke gate: every built tarball is installed through `install.sh`
  on its matching OS/arch runner and verified with `--version`/`--help`
  before the release is published (#147)
- `install.sh` `TAU_BASE_URL` env override — point the installer at a staging
  dir (`file://…`) or mirror instead of GitHub releases (#147)
- Fail-closed SHA256 verification in `install.sh`: installs now abort when the
  `SHA256SUMS.txt` manifest is unreachable, the asset isn't listed in it, or no
  checksum tool is available — previously these only warned and continued
  (#161). `TAU_SKIP_CHECKSUM=1` opts out. The release workflow also emits
  per-asset `.sha256` files verified by the smoke jobs, and re-checks
  `SHA256SUMS.txt` before publishing
- `setup-tau` composite GitHub Action (repo-root `action.yml`) — install tau
  in CI with a single `uses: javimosch/tau@<ref>` line; wraps `install.sh`,
  puts `tau` on `PATH`, and exposes `tau-path`/`version` outputs (#151)
- Homebrew tap — `brew install javimosch/tap/tau` on macOS and Linux. A
  `homebrew` job in the release workflow regenerates `Formula/tau.rb`
  (`scripts/generate-homebrew-formula.sh` + the published `SHA256SUMS.txt`)
  and pushes it to `javimosch/homebrew-tap` on every stable tag, so
  `brew upgrade` tracks releases (#175). Requires a `HOMEBREW_TAP_TOKEN`
  repository secret to publish; releases proceed without it
- Windows support: the release workflow cross-compiles
  `x86_64-windows-gnu` and ships `tau-windows-x86_64.zip` in
  `SHA256SUMS.txt`; `install.ps1` (PowerShell) mirrors the `install.sh`
  contract — `-Version`/`-Dir`/`-DryRun`, `TAU_*` env overrides, and
  fail-closed `Get-FileHash` verification — installing to
  `%LOCALAPPDATA%\Programs\tau`; a `smoke-windows` job installs the zip
  end-to-end on a native `windows-latest` runner before publish (#182)
- Scoop + winget manifests: `scripts/generate-scoop-manifest.sh` and
  `scripts/generate-winget-manifest.sh` render the package manifests from the
  published checksums on every stable tag; the `scoop` job pushes
  `bucket/tau.json` to `javimosch/scoop-bucket` (behind `SCOOP_BUCKET_TOKEN`,
  warn-and-skip until the repo and secret exist), and the `winget` job
  validates + uploads the three-file manifest for microsoft/winget-pkgs
  submission (auto-submits via `wingetcreate` when `WINGET_PKGS_TOKEN` is
  configured) (#182)
- `ci` workflow — unit tests + offline smoke groups run on a native
  Linux/macOS/Windows runner matrix for every released platform on each PR,
  push to `master`, and `v*` tag (#193)
- Clean-environment first-run e2e: a `first-run` job in the `ci` workflow
  builds tau on every released platform, stages it as a local release tree,
  installs it through `install.sh` (POSIX) / `install.ps1` (Windows) against a
  `file://` `TAU_BASE_URL`, then drives `tau setup --yes` and
  `tau doctor --selftest` in a scratch HOME with every credential scrubbed —
  `scripts/e2e-first-run.sh` / `scripts/e2e-first-run.ps1`. The release
  workflow's install-smoke jobs assert the shipped artifact self-verifies
  the same way (#233)

### Fixed

- `tau doctor` no longer false-fails a commented (JSONC) config file — the
  `config_file` check strips `//` and `/* */` comments before parsing, same
  as the runtime loader, so a `tau init` scaffold reports `ok`
- `install.sh` checksum matching now tolerates `./`-prefixed filenames in
  `SHA256SUMS.txt`, and the release workflow emits clean filenames — a
  mismatch that would have made every real install abort (#147)
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
  streaming frames (#117), context compaction boundaries (#121), `tau doctor`
  diagnostics incl. live-probe stub coverage (#165)
- Golden/snapshot smoke groups: `golden-errors` byte-locks error envelopes and
  exit codes (#208); `golden-onboarding` byte-locks the first-run surface —
  `tau init`, `tau setup` (incl. `--client`), and `tau config edit` —
  including generated file contents, with volatile paths normalized (#223)
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
