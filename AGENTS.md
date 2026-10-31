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
| `--debug` | flag | off | Perf stats + tool I/O to stderr; also writes a redacted diagnostic log to `~/.config/tau/debug/` (override: `TAU_DEBUG_LOG`) |
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
tau --debug "test"                          # Stderr: perf stats + tool I/O;
                                            # plus redacted ~/.config/tau/debug/<ts>.log
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

#### 15. Diagnostics
```bash
tau doctor                             # JSON setup report; exit 0 ok/warn, 1 on any fail
tau doctor --offline                   # Skip network checks (reported as "skip")
tau doctor --deep                      # Also run an authenticated probe (max_tokens=1)
tau doctor --probe                     # Live-verify connectivity + credentials for every provider
tau doctor --selftest                  # Credential-free e2e check: self-spawn against a loopback stub
tau doctor --provider openai           # Diagnose an override instead of the configured default
tau doctor --model openai/gpt-4o-mini  # provider/id shorthand works too
tau doctor --report                  # Redacted Markdown bundle for bug reports
tau doctor --json                    # NDJSON: {"check":{...},"done":false} per check, {"fix":{...}} under --fix, terminal {"ok":...,"done":true}
# → {"ok":bool,"version":..,"build":{commit,target,build_date,zig},"checks":[{name,status:ok|warn|fail|skip,message,hint?}],"summary":{...}}
# --json stream contract: schema/tau-doctor.schema.json + docs/doctor-json.md
#   tau doctor --json --offline | python3 scripts/check-doctor-schema.py -

tau bug                              # Pre-filled GitHub issue URL + the redacted bundle
tau bug --title "x" --body "desc"    # Fill the issue title + description
tau bug --open                       # Launch the URL ($BROWSER, else open/xdg-open)
tau bug --out report.md              # Also write the bundle to a file
tau bug --no-report                  # Omit diagnostics (mutex with --out)
# → {"title","labels","url","body","report","url_truncated","out","opened","done":true}
# Exit 0 always; over-long bundles fall back to a short URL body
# (url_truncated:true) — full text stays in body/report.
```

#### 16. Effective Config (`tau config show`)
```bash
tau config show                          # Resolved config (file+env+flags), keys redacted
tau config show --provider openai        # Preview flag overrides without running
tau config show --json                   # Pin the stable JSON form for scripts
# → {"config_file":{...},"provider":"openai","api_key":{"set":true,"value":"***wxyz","source":"env OPENAI_API_KEY"},...}
# api_key.source ∈ --api-key | config keys[<p>] | env <VAR> | config api_key | env TAU_API_KEY | builtin
# Stable shape: schema/tau-config-show.schema.json (CI-validated output).
```

#### 17. Config Validation (`tau config validate`)
```bash
tau config validate                      # Validate ~/.config/tau/config.json
tau config validate ci/prod.json         # Validate an explicit file
tau config validate --json               # Pin the stable JSON report for scripts
tau config validate --mode text          # Human-readable error lines
# → {"path":"…","ok":false,"errors":[{"key":"provider","message":"…"}]}  (stdout)
# Exit 0 = valid, 1 = problems found, 80 = CLI misuse. Fully offline; key
# values are never echoed. For CI/pre-commit gates.
# Stable shape: schema/tau-config-validate.schema.json.
```

#### 18. Config Editing (`tau config set|get|unset`)
```bash
tau config set provider openai           # Schema-checked write (creates file, 0600)
tau config set keys.openai sk-...        # Per-provider key via keys.<provider>
tau config get provider                  # Read a FILE value (JSON mode default)
tau config get api_key --mode text       # → "***last4" (secrets redacted; --raw prints raw)
tau config unset keys.openai             # Remove a key
tau config set mode text ./ci.json       # Optional trailing path
# Edits are comment-preserving text splices (JSONC-safe, atomic temp+rename).
# Exit 0 ok; 1 = key/file not found or invalid file; 80 = bad key/value/args.
```

#### 19. Interactive Config Editing (`tau config edit`)
```bash
tau config edit                        # Open ~/.config/tau/config.json in $EDITOR
TAU_EDITOR="code --wait" tau config edit  # Editor: TAU_EDITOR > VISUAL > EDITOR > vi/notepad
tau config edit ./ci.json              # Explicit path
# Missing file → seeded with the commented `tau init` scaffold first.
# On editor exit the file is validated (same checks/report as `config
# validate`, incl. did-you-mean on misspelled keys); bad saves exit 1 but
# stay on disk. Editor non-zero exit → editor_failed envelope, exit 1.
```

#### 20. Offline Error Catalog
```bash
tau explain                       # List the stable error catalog (JSON)
tau explain 106                   # One entry by exit code: cause + hint + docs
tau explain AuthFailed            # Same, by wire `type` tag
tau explain --json 106            # Pin the schema-checked JSON form (default)
tau explain --human 80            # Prose instead of JSON
```

#### 21. Config Schema (`tau config schema`)
```bash
tau config schema                          # JSON Schema (draft 2020-12) on stdout
tau config schema > tau-config.schema.json # Export for editor wiring
# Generated from FileConfig (can't drift); canonical copy checked in at
# schema/tau-config.schema.json — regenerate after key changes with the
# redirect above. `tau init` writes a "$schema" key pointing at the
# published URL so editors autocomplete out of the box; `config schema`
# also prints a `note:` hint on stderr. The SchemaStore catalog entry
# submitted upstream lives at schema/schemastore-catalog-entry.json.
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

#### 20. Config Scaffolding
```bash
tau init                                 # Write commented starter ~/.config/tau/config.json
tau init --stdout                        # Preview the scaffold without writing
tau init --force                         # Overwrite an existing config
tau init --provider openai               # Scaffold for a specific provider
# Detects set provider env keys (marks them "*"), picks a matching provider,
# and never copies secret values into the file. config.json is JSONC:
# `//` and `/* */` comments are stripped on load.
```

#### 21. One-Shot Onboarding
```bash
tau setup                      # init + install completions ($SHELL-detected) + doctor summary
tau setup --shell fish         # Override detection: bash|zsh|fish|pwsh|all
tau setup --client zed         # Write editor ACP config: zed|nvim|vscode|jetbrains|windsurf|gemini|claude-desktop|all
tau setup --offline            # Skip network checks in the doctor step
tau setup -y --non-interactive # Unattended contract (verdict records non_interactive/yes)
tau setup --dry-run            # Preview all writes (would_* statuses); change nothing
# Env equivalents (flag > env > detect): TAU_YES, TAU_NONINTERACTIVE,
# TAU_SETUP_SHELL, TAU_SETUP_CLIENT. CI is not auto-detected.
# Emits one NDJSON object per step plus a final verdict:
#   {"step":"init","status":"created|exists|failed",...}
#   {"step":"completions","status":"installed|skipped|failed","shells":[...]}
#   {"step":"clients","status":"installed|manual|skipped|failed","clients":[...]}
#   {"step":"doctor","report":{...same shape as `tau doctor`...}}
#   {"step":"setup","ok":bool,"version":..}
# --dry-run previews writes as would_create|would_install|would_append and
# marks the write steps + verdict with "dry_run":true; read-only outcomes
# (exists/already_installed/present/manual) keep their names.
# Idempotent: existing config is kept, rc edits carry a "# tau completions"
# marker so re-runs don't duplicate. Exit 0 when every step is ok/skipped,
# 1 on any failure (including a doctor report with failed checks).
# Completion scripts are embedded in the binary at build time (build.zig
# generates a `completions` module from completions/), so `tau setup`
# works without a source checkout.
# --client writes a minimal settings file (e.g. ~/.config/zed/settings.json
# agent_servers.tau) with the absolute path of the running tau binary; an
# existing settings file is never rewritten — a paste-ready snippet lands in
# ~/.config/tau/snippets/ instead ("manual"). nvim is always "manual" (Lua
# config for avante.nvim/CodeCompanion). Without --client the step is
# "skipped" and only reports detected editor config dirs.
```

#### 18. Version & Build Metadata
```bash
tau version                    # Same as -v/--version: "tau 0.4.0"
tau version --json             # Stable object for scripts: {"name":"tau","version":"0.4.0"}
# Stable shape: schema/tau-version.schema.json (CI-validated output).
tau version --verbose          # Build metadata as JSON
# → {"name":"tau","version":"0.4.0","commit":"abc123","target":"x86_64-linux-gnu",
#    "build_date":"2026-10-14T07:32:16Z","zig":"0.16.0"}
tau version --verbose --mode text   # Same fields as key: value lines
# Commit is the short hash of HEAD ("unknown" for tarball builds, "-dirty" on
# uncommitted changes); build_date honors SOURCE_DATE_EPOCH so release builds
# stay byte-reproducible. The same "build" object rides on `tau doctor`
# (report and --json verdict) and as a `# build:` line in --debug log headers.
tau version --check                # Non-blocking update check vs latest release
# → {"name":"tau","version":"0.4.0","checked":true,"latest":"0.4.0","update_available":false}
# Always exits 0 — checked:false + reason when the lookup can't run (offline,
# no curl). Opt out everywhere (incl. the doctor update_available warning) via
# TAU_NO_UPDATE_CHECK=1; TAU_UPDATE_URL overrides the lookup URL.
```

#### 19. Self-Update (`tau upgrade`)
```bash
tau upgrade                      # Check latest release, [y/N] prompt on a TTY, install
tau upgrade --yes                # Non-interactive (env TAU_YES=1)
tau upgrade --dir /opt/bin       # Override destination (default: the running
                                 # binary's directory; env TAU_INSTALL_DIR)
tau upgrade --dry-run            # Print the resolved plan + release notes; install nothing
# → {"name":"tau","version":"0.4.0","checked":true,"latest":"0.5.0","tag":"v0.5.0",
#    "update_available":true,"status":"upgraded","detail":"installed tau 0.5.0 -> /opt/bin/tau",
#    "release_url":"...","install_dir":"/opt/bin","changelog":[{"version":"0.5.0","notes":"..."}]}
# status: up_to_date|upgraded|declined|skipped|failed|dry_run — exit 0 for
# up_to_date/upgraded/declined/dry_run, 1 for skipped/failed. Downloads and
# execs the release tag's own install.sh, so upgrades get the same fail-closed
# SHA256 verification as fresh installs (TAU_BASE_URL/TAU_SKIP_CHECKSUM/
# TAU_VERIFY_SIGSTORE flow through). TAU_INSTALL_URL overrides the installer
# script URL (file:// stubs in tests). When an update exists the tag's
# CHANGELOG.md is fetched too (TAU_CHANGELOG_URL overrides): sections in
# (installed, latest] render as a pre-upgrade summary on stderr and as the
# report's "changelog" field — best-effort, a fetch miss drops only the
# summary. POSIX-only; Windows exits 111 and points at install.ps1.
```

#### 22. Color Policy
```bash
# Only one surface is styled: the interactive [y/N] prompts of
# `tau upgrade` and `tau doctor --fix` (bold on a TTY stderr). Machine
# channels — stdout JSON/NDJSON, --mode text, stderr error envelopes —
# are never styled.
# First match wins (src/term.zig colorPolicy):
#   CLICOLOR_FORCE (non-empty, !="0") → styled, even non-TTY
#   NO_COLOR (non-empty)              → plain
#   CLICOLOR=0                        → plain
#   TERM=dumb                         → plain
#   otherwise                         → stream.isTty()
# Locked by the golden-color smoke group (pty matrix + byte snapshots).
```

#### 23. Stability Contract
```bash
# docs/stability.md is the public stability + deprecation contract —
# which exit codes, --json schemas, config keys, env vars, and wire
# formats are stable vs informational vs internal, and how deprecations
# are announced/phased out. It is hand-written policy (not generated);
# scripts/check-stability-doc.py keeps it aligned with src/errors.zig,
# schema/, and linked docs. Drift check: the stability-doc smoke group.
```

### Storage Paths

| Path | Purpose |
|------|---------|
| `~/.config/tau/config.json` | Provider, model, mode defaults |
| `~/.config/tau/sessions/<name>.json` | Session conversation + goal state |
| `~/.config/tau/fleets/<id>.json` | Fleet manifests (spec + per-item status) |
| `~/.config/tau/acp.sock` | ACP Unix socket (daemon mode) |
| `~/.config/tau/acp.pid` | ACP daemon PID file |
| `~/.config/tau/acp.log` | ACP daemon log |
| `~/.config/tau/debug/<ts>.log` | Redacted diagnostic log written by `--debug` (override: `TAU_DEBUG_LOG`) |

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
| `src/configedit.zig` | `tau config set|get|unset`/`config edit` JSONC splice editor | Config editing changes |
| `src/doctor.zig` | `tau doctor` setup diagnostics | Adding/changing doctor checks |
| `schema/tau-doctor.schema.json` | `tau doctor --json` NDJSON event schema (+ `scripts/check-doctor-schema.py` validator, `scripts/gen-doctor-doc.py` → docs/doctor-json.md) | Changing doctor event shapes |
| `src/init.zig` | `tau init` config scaffolding | Changing the starter config |
| `src/setup.zig` | `tau setup` onboarding (init + completions + clients + doctor) | Setup steps, install paths, --client |
| `src/bug.zig` | `tau bug` pre-filled GitHub issue (URL + report bundle) | `tau bug` flags/output, issue-URL shape |
| `completions/` | Shell completion scripts (embedded via build.zig) | Adding flags/subcommands to completions |
| `src/session.zig` | Session persistence | Session format changes |
| `src/context.zig` | Auto-compaction logic | Compaction algorithm |
| `src/llm/provider.zig` | LLM providers, HTTP, streaming | Adding providers |
| `src/llm/acp.zig` | ACP JSON-RPC server | ACP protocol changes |
| `src/tools/*.zig` | Built-in tools (bash,read,write,edit,ls,grep,find) | Adding/modifying tools |
| `src/tools/registry.zig` | Tool registry + allowlist/denylist | Registering new tools |
| `src/json.zig` | Hand-rolled JSON escape/unescape | JSON handling fixes |
| `src/errors.zig` | Stable error-code catalog + shared `{"err"}` envelope emitter | Error codes/hints, envelope fields |
| `src/version.zig` | Version const + build metadata (`build.*`, `buildJson`, `buildLine`) | Version bump, build metadata |
| `src/update.zig` | `tau version --check` + doctor `update_available` release lookup (curl, TAU_UPDATE_URL/TAU_NO_UPDATE_CHECK) | Update-check behavior |
| `src/upgrade.zig` | `tau upgrade` self-update — check → confirm → staged `install.sh` exec | Upgrade flow, install-dir resolution |
| `src/debuglog.zig` | `--debug` redacted diagnostic log + secret masking | Debug log path/redaction changes |
| `src/term.zig` | Portable stdout/stderr + color policy (`colorEnabled`/`colorPolicy`/`sgrWrap` — NO_COLOR/CLICOLOR/CLICOLOR_FORCE/TERM=dumb/TTY) | Terminal output changes, styling new surfaces |
| `install.sh` | curl-able installer for prebuilt releases | Installer/flag/env changes |
| `action.yml` | `setup-tau` composite GitHub Action (wraps `install.sh`) | Action inputs/outputs |
| `.github/workflows/release.yml` | Tag-triggered release build + smoke + publish + Homebrew tap update | Release process changes |
| `scripts/generate-homebrew-formula.sh` | Renders `Formula/tau.rb` from a version + `SHA256SUMS.txt` | Formula field/asset changes |

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

The `ci` GitHub Actions workflow runs `zig build test` + `scripts/smoke.sh` +
`scripts/smoke-features.sh --offline` on native runners for every released
platform (ubuntu-latest, ubuntu-24.04-arm, macos-15-intel, macos-latest,
windows-latest) on PRs, pushes to master, and v* tags — so platform
regressions are caught before a release is cut. Its `first-run` job adds a
clean-environment e2e per platform: the built binary is staged as a local
release tree, installed through `install.sh` (POSIX) / `install.ps1`
(Windows) via `TAU_BASE_URL=file://…`, then `scripts/e2e-first-run.{sh,ps1}`
drives `tau setup --yes` + `tau doctor --selftest` in a scratch HOME with all
credentials scrubbed. The same driver runs standalone:

```bash
./scripts/e2e-first-run.sh ./zig-out/bin/tau   # local first-run e2e (offline)
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

`tau explain <code|type>` prints the offline catalog entry (cause + remediation
hint) for any stable error — see docs/errors.md for the generated catalog.

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