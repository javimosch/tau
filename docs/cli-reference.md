# `tau` CLI reference

<!-- GENERATED FILE — do not edit by hand.
     Source of truth: flag_specs + help_text in src/main.zig (the
     same tables `tau --help` and `tau --help-json` emit), the
     per-subcommand help pages in src/subhelp.zig, and the Spec
     registry in src/subcommandcatalog.zig — the same catalog
     `tau explain subcommand.<name>` reads.
     Regenerate:  python3 scripts/gen-cli-reference-doc.py
     Drift check: python3 scripts/gen-cli-reference-doc.py --check
     (the cli-reference-doc smoke group runs the drift check) -->

Everything `tau --help` and every `tau <subcommand> --help` prints,
on one browsable page: the global flag table, goal-mode directives,
exit codes, and a section per subcommand with its full help text —
usage, options, and runnable examples — plus the offline explain
catalog's related links. Each help page is byte-locked by the
golden-help goldens and every `tau ...` example is proven to parse
by the subhelp.zig unit tests, so this reference cannot drift from
the real CLI surface.

## `tau` — prompt mode

`tau [options] [@files...] [prompt...]` — `@path` positionals inline a file's contents as
a user message (one message per file, in order); the remaining
positionals join into the prompt, and `/goal ...` directives enter
goal mode. Output is JSON by default (`--mode text` for prose);
errors are always `{"err":{...}}` envelopes on stderr.

### Global flags

Every flag the top-level parser accepts — the `flag_specs` table in
`src/main.zig`, also emitted machine-readably by `tau --help-json`.

| Flag | Short | Argument | Description |
|------|-------|----------|-------------|
| `--print` | `-p` | — | Non-interactive: process prompt and exit (default) |
| `--provider` | — | `name` | Provider: xiaomi (default), openai, deepseek, opencode-go |
| `--model` | — | `pattern` | Model id, or provider/id (e.g. openai/gpt-4o-mini) |
| `--api-key` | — | `key` | API key (else provider env var, else builtin) |
| `--system-prompt` | — | `text` | Set the system prompt |
| `--append-system-prompt` | — | `text` | Append to the system prompt (repeatable) |
| `--mode` | — | `text\|json` | Output mode (default: json) |
| `--no-stream` | — | — | Disable streaming (streaming is default) |
| `--stream` | — | — | Enable streaming (overrides a no-stream config default) |
| `--tools` | `-t` | `csv` | Allowlist of tool names |
| `--exclude-tools` | `-xt` | `csv` | Denylist of tool names |
| `--no-tools` | `-nt` | — | Disable all tools |
| `--thinking` | — | — | Enable thinking chunks (show model reasoning) |
| `--debug` | — | — | Show perf stats and tool calls (input+output) on stderr, and write a redacted diagnostic log to ~/.config/tau/debug/ for bug reports (override the path with TAU_DEBUG_LOG) |
| `--dry-run` | — | — | Report the tools that would be called; execute none |
| `--temperature` | — | `f` | Sampling temperature (default: 0.7) |
| `--max-tokens` | — | `n` | Max output tokens |
| `--timeout-ms` | — | `n` | Request timeout in ms (default: 120000) |
| `--session` | — | `name` | Persist conversation + goal to ~/.config/tau/sessions/<name>.json |
| `--context-window` | — | `n` | Model context window in tokens (default: per-provider) |
| `--compact-threshold` | — | `f` | Auto-compact above this fraction of the window (default: 0.5) |
| `--compact-keep-recent` | — | `n` | Tokens of recent history kept verbatim (default: 20000) |
| `--no-compact` | — | — | Disable automatic context compaction |
| `--role` | — | `author\|critic\|coordinator\|none` | Set the agent role (default: none) |
| `--schema` | — | `json\|@file` | JSON Schema for structured output. Model must produce valid JSON matching this schema. Inline: --schema '{\"type\":\"object\",...}' File:   --schema @path/to/schema.json |
| `--scan-agents` | — | — | Scan CWD for AGENTS.md files and list them |
| `--load-agents-md` | — | `path` | Load an AGENTS.md file into system context |
| `--auto-agents-md` | — | — | Auto-load cwd/AGENTS.md on startup |
| `--max-iterations` | — | `n` | Tool-loop runaway backstop (default: 100; forces a final answer) |
| `--goal-max-iterations` | — | `n` | Per-run loop cap in goal mode (default: 50) |
| `--help-json` | — | — | Machine-readable help as JSON |
| `--help` | `-h` | — | Show this help (per-subcommand: tau <sub> --help) |
| `--version` | `-v` | — | Show version |

### Goal-mode directives

`/goal` commands run inside a prompt — the management verbs need
`--session`:

| Directive | Effect |
|-----------|--------|
| `/goal <objective>` | Work autonomously until the objective is audited-complete |
| `/goal [--tokens N] <obj>` | ...with a soft output-token budget (e.g. 250K) |
| `/goal status\|pause\|resume\|clear\|complete` | Manage the session's goal (needs --session) |

### Exit codes

The stable process-status contract — cause, remediation, and
recoverability per code/type in [docs/errors.md](errors.md), or
offline via `tau explain <code>`:

| Code | Type |
|------|------|
| `0` | `success` |
| `80` | `invalid_argument` |
| `82` | `missing_required_field` |
| `105` | `connection_timeout` |
| `106` | `auth_failed` |
| `110` | `internal_error` |
| `111` | `unimplemented` |

### Examples

```text
tau "List the files in src/"
tau --model openai/gpt-4o-mini "Explain this error" @log.txt
tau --session work1 "Remember: the build uses zig 0.16"
tau --session work1 "/goal add a --version flag and verify it builds"
tau --session work1 "/goal status"
tau --role author --tools bash,write "add version flag"
tau fleet run --goal "add OAuth and write tests"
```

## Subcommands

Every registered subcommand, in catalog order — the same order
`tau explain --list` indexes them under `subcommand.<name>`. Each
section embeds the exact `tau <name> --help` page followed by the
catalog's related links.

| Subcommand | Summary |
|------------|---------|
| [`tau acp`](#tau-acp) | Agent Client Protocol server — JSON-RPC for editor clients |
| [`tau models`](#tau-models) | List available providers and their default models |
| [`tau version`](#tau-version) | Print the version; --verbose adds build metadata, --check looks for a newer release |
| [`tau upgrade`](#tau-upgrade) | Self-update in place from the latest GitHub release (POSIX only) |
| [`tau doctor`](#tau-doctor) | Validate your setup — config file, credentials, client wiring, connectivity |
| [`tau bug`](#tau-bug) | File a pre-filled GitHub issue carrying a secret-redacted diagnostics bundle |
| [`tau guide`](#tau-guide) | Embedded operator manual — drive tau with no external docs |
| [`tau explain`](#tau-explain) | Offline catalog lookup — errors, config keys, doctor checks, env vars, clients, topics, and subcommands |
| [`tau skills`](#tau-skills) | Autodiscover and load agent skills from ~/.agents/skills |
| [`tau init`](#tau-init) | Write a commented starter ~/.config/tau/config.json |
| [`tau setup`](#tau-setup) | One-shot onboarding — init + completions + editor-client wiring + doctor verdict |
| [`tau completions`](#tau-completions) | Install the generated shell completions — the setup step standalone |
| [`tau fleet`](#tau-fleet) | Orchestrate parallel tau workers toward a goal |
| [`tau config`](#tau-config) | Inspect and edit ~/.config/tau/config.json (git-config style) |

### `tau acp`

Agent Client Protocol server — JSON-RPC for editor clients

```text
tau acp - Agent Client Protocol server (JSON-RPC for editor clients)

Usage:
  tau acp serve [--acp-socket <path>] [--max-iterations <n>]
  tau acp start [--acp-socket <path>]
  tau acp stop
  tau acp status

Commands:
  serve                    Run the JSON-RPC agent server on stdio
                           (default when no command is given), or on
                           a Unix socket with --acp-socket
  start                    Launch the server as a background daemon
  stop                     Stop the background daemon
  status                   Report daemon status as JSON

Options:
      --acp-socket <path>  Unix socket path
                           (default ~/.config/tau/acp.sock)
      --max-iterations <n> Tool-loop runaway backstop (default: 100)

Examples:
  tau acp serve
  tau acp serve --acp-socket /tmp/tau.sock
  tau acp start
  tau acp status
  tau acp stop
```

- **Related:** errors `invalid_argument`, `unimplemented` · config keys `provider`, `model`, `timeout_ms` · checks `doctor.client_wiring`, `doctor.client_permissions`
- **Explain:** `tau explain subcommand.acp` (bare `tau explain acp` resolves too)
- **Docs:** [docs/acp.md](acp.md)

### `tau models`

List available providers and their default models

```text
tau models - list available providers and their default models

Usage:
  tau models

Examples:
  tau models
```

- **Related:** errors `invalid_argument` · config keys `provider`, `model` · checks `doctor.provider_resolution`, `doctor.provider_probes`
- **Explain:** `tau explain subcommand.models` (bare `tau explain models` resolves too)
- **Docs:** [docs/providers.md](providers.md)

### `tau version`

Print the version; --verbose adds build metadata, --check looks for a newer release

```text
tau version - print the version (command form of -v/--version)

Usage:
  tau version [--verbose] [--check] [--json] [--mode text|json]

Options:
      --verbose        Include build metadata (git commit, target
                       triple, build date, zig version)
      --check          Non-blocking check for a newer release; always
                       exits 0 (opt out: TAU_NO_UPDATE_CHECK=1)
      --json           Stable {"name","version",...} object for
                       scripts (schema/tau-version.schema.json);
                       mutually exclusive with --mode text
      --mode text|json Output mode

Examples:
  tau version
  tau version --verbose
  tau version --check
  tau version --json
```

- **Related:** errors `invalid_argument` · checks `doctor.update_available`
- **Explain:** `tau explain subcommand.version` (bare `tau explain version` resolves too)
- **Docs:** [docs/stability.md](stability.md)

### `tau upgrade`

Self-update in place from the latest GitHub release (POSIX only)

```text
tau upgrade - self-update in place from the latest release

Usage:
  tau upgrade [--yes|-y] [--dir <path>] [--dry-run]
              [--verify-signature] [--json]

Options:
  -y, --yes        Upgrade without prompting (env TAU_YES=1); a TTY
                   gets a [y/N] prompt instead
      --dir <path> Install destination (default: the running binary's
                   directory; env TAU_INSTALL_DIR)
      --dry-run    Print the resolved plan + release notes; install
                   nothing
      --verify-signature
                   Verify the asset's cosign/Sigstore signature
                   before the swap (env TAU_VERIFY_SIGSTORE=1;
                   requires cosign on PATH, fails closed)
      --json       Pin the stable schema-checked report object
                   (schema/tau-upgrade.schema.json; output is
                   already JSON)

The release notes between your version and the target print before
any install. POSIX-only; on Windows re-run install.ps1.

Failed runs exit 1 with "status":"failed" plus a "hint" field
naming the fix (checksum mismatch, download failed, offline ...).

Examples:
  tau upgrade --dry-run
  tau upgrade --yes
  tau upgrade --yes --verify-signature
  tau upgrade --dir ~/.local/bin
```

- **Related:** errors `invalid_argument`, `unimplemented` · checks `doctor.update_available`
- **Explain:** `tau explain subcommand.upgrade` (bare `tau explain upgrade` resolves too)
- **Docs:** [docs/troubleshooting.md#install--upgrade-failures](troubleshooting.md#install--upgrade-failures)

### `tau doctor`

Validate your setup — config file, credentials, client wiring, connectivity

```text
tau doctor - validate your setup (config, credentials, client wiring)

Usage:
  tau doctor [options]

Options:
      --provider <name>  Diagnose an override provider
      --model <id>       Diagnose an override model
      --api-key <key>    Diagnose an override API key
      --offline          Skip network checks
      --deep             Also run an authenticated probe (~1 token)
      --probe            Live-verify connectivity + credentials for
                         every provider (~1 token per keyed provider)
      --selftest         Credential-free end-to-end check against a
                         loopback stub provider (no keys, no network)
      --fix [<check>]    Propose remediations — every fixable check,
                         or just the named check; prompts per fix on
                         a TTY (see `tau explain doctor.<check>`)
  -y, --yes              Apply --fix remediations without prompting
      --json             Stream NDJSON check/fix events + verdict
                         (schema/tau-doctor.schema.json)
      --report           Print a redacted Markdown diagnostics bundle
                         for bug reports (mutex with --json)
      --shell <name>     Completions shell: bash|zsh|fish|pwsh|all
                         (default: detect from $SHELL)

Examples:
  tau doctor
  tau doctor --offline
  tau doctor --selftest
  tau doctor --fix --yes
  tau doctor --fix shell_completions --yes
  tau doctor --probe
  tau doctor --report
```

- **Related:** errors `invalid_argument` · config keys `provider`, `api_key`, `timeout_ms` · checks `doctor.config_file`, `doctor.provider_resolution`, `doctor.api_key`, `doctor.tls_ca`, `doctor.update_available`
- **Explain:** `tau explain subcommand.doctor` (bare `tau explain doctor` resolves too)
- **Docs:** [docs/doctor.md](doctor.md)

### `tau bug`

File a pre-filled GitHub issue carrying a secret-redacted diagnostics bundle

```text
tau bug - file a pre-filled GitHub issue with redacted diagnostics

Usage:
  tau bug [options]

Options:
      --title <text>     Issue title (default "Bug report")
      --body <text>      Description placed above the bundle
      --labels <csv>     Issue labels (default "bug"; "" = none)
      --open             Open the issue URL in the system browser
      --out <path>       Also write the diagnostics bundle to a file
      --no-report        Omit the diagnostics bundle
      --attach-report <path>
                         Bundle an existing `tau doctor --report` file
                         (secret-redacted) instead of running the live
                         sweep — mutually exclusive with --no-report
      --dry-run          Preview the exact issue envelope — bundle
                         contents plus a "redactions" mask count —
                         without writing --out or opening a browser
      --offline/--deep   Passed through to the diagnostic sweep
      --provider <name>  Diagnose an override provider
      --model <id>       Diagnose an override model
      --api-key <key>    Diagnose an override API key
      --shell <name>     Completions shell: bash|zsh|fish|pwsh|all
      --json             Pin the stable schema-checked JSON form
                         (schema/tau-bug.schema.json; output is
                         already JSON)

Examples:
  tau bug
  tau bug --title "crash on startup" --open
  tau bug --no-report --labels bug,crash
  tau bug --out report.md
  tau bug --dry-run
```

- **Related:** errors `invalid_argument` · checks `doctor.plaintext_secrets`
- **Explain:** `tau explain subcommand.bug` (bare `tau explain bug` resolves too)
- **Docs:** [docs/troubleshooting.md#diagnostic-toolkit](troubleshooting.md#diagnostic-toolkit)

### `tau guide`

Embedded operator manual — drive tau with no external docs

```text
tau guide - embedded operator manual (drive tau with no external docs)

Usage:
  tau guide [--human]

Options:
      --human   Render the guide as markdown (default: JSON for agents)

Examples:
  tau guide
  tau guide --human
```

- **Related:** errors `invalid_argument`
- **Explain:** `tau explain subcommand.guide` (bare `tau explain guide` resolves too)
- **Docs:** [README.md](../README.md)

### `tau explain`

Offline catalog lookup — errors, config keys, doctor checks, env vars, clients, topics, and subcommands

```text
tau explain - offline error + config-key + doctor-check + env-var
+ client + topic + subcommand catalog lookup (no API key needed)

Usage:
  tau explain [<code|type|key|doctor.<check>|TAU_*|client.<name>|topic.<name>|subcommand.<name>>] [--json|--human]
  tau explain --list [--json|--human]
  tau explain --search <text> [--json|--human]

Arguments:
  <code|type|key>   Exit code (e.g. 106), error type (e.g. authfailed),
                    or config key (e.g. timeout_ms, keys.openai);
                    omit to list the whole catalog
  doctor.<check>    A `tau doctor` check id (e.g. doctor.tls_ca,
                    doctor.client_zed, doctor.probe_openai) — prints
                    when it fails and how to remediate. Bare check ids
                    also resolve unless they collide with a key
                    (`api_key` is the config key; `doctor.api_key`
                    is the check)
  TAU_<VAR>         A TAU_* environment variable (e.g. TAU_ENDPOINT,
                    TAU_YES, TAU_VERSION) — prints who consumes it and
                    what it does, from the generated docs/env.md catalog
  client.<name>     A `tau setup --client` editor client (e.g.
                    client.zed, client.claude-desktop) — prints setup
                    prerequisites, config paths, and the restart +
                    verify step. Bare names and --client aliases
                    resolve too (`zed`, `code`, `claude`)
  topic.<name>      A curated topic — `privacy` covers what tau
                    stores locally, what leaves the machine, and how
                    diagnostics redact secrets. Bare names resolve too
                    (`tau explain privacy`)
  subcommand.<name> A registered subcommand (e.g. subcommand.doctor,
                    subcommand.setup) — prints the summary, a
                    condensed usage line, runnable example
                    invocations, and links to the related error type
                    tags, config keys, and doctor checks. Bare names
                    resolve too (`tau explain doctor`)

Options:
      --json   Stable schema-checked JSON form (default;
               schema/tau-explain.schema.json)
      --human  Render as prose
      --list   Print the topic index — every resolvable name
               (error codes + types, config keys, doctor checks,
               TAU_* env vars, client ids, topics, subcommands)
               instead of full entries; takes no query
      --search <text>
               Print the topic index filtered to entries whose
               name or body text (cause/hint, description,
               fails-when/remediation, consumers/summary, prereqs)
               matches every whitespace-separated term,
               case-insensitively; takes no query

Examples:
  tau explain
  tau explain --list
  tau explain --search proxy
  tau explain --search "api key"
  tau explain 106
  tau explain authfailed
  tau explain timeout_ms
  tau explain keys.openai
  tau explain doctor.tls_ca
  tau explain TAU_ENDPOINT
  tau explain client.zed
  tau explain privacy
  tau explain doctor
  tau explain subcommand.setup
  tau explain --human 105
```

- **Related:** errors `invalid_argument`, `not_found`
- **Explain:** `tau explain subcommand.explain` (bare `tau explain explain` resolves too)
- **Docs:** [docs/errors.md](errors.md)

### `tau skills`

Autodiscover and load agent skills from ~/.agents/skills

```text
tau skills - autodiscover and load agent skills (~/.agents/skills/)

Usage:
  tau skills list
  tau skills search <query>
  tau skills load <name>

Commands:
  list             List all discoverable skills (JSON)
  search <query>   Search skills by keyword
  load <name>      Load a skill into system context

Examples:
  tau skills list
  tau skills search memory
  tau skills load agent-memory-toolbox
```

- **Related:** errors `invalid_argument`, `not_found`
- **Explain:** `tau explain subcommand.skills` (bare `tau explain skills` resolves too)
- **Docs:** [AGENTS.md](../AGENTS.md)

### `tau init`

Write a commented starter ~/.config/tau/config.json

```text
tau init - write a commented starter ~/.config/tau/config.json

Usage:
  tau init [--force] [--stdout] [--provider <name>] [--json]

Options:
      --force            Overwrite an existing config file
      --stdout           Print the starter config without writing it
                         (mutex with --json)
      --provider <name>  Scaffold for a specific provider
      --json             Pin the stable schema-checked result object
                         (schema/tau-init.schema.json)

On success a getting-started checklist (next steps: `tau setup --client`,
`tau doctor`, `tau explain --list`) is printed to stderr; stdout stays a
pure JSON result object or the JSONC scaffold under --stdout.

Examples:
  tau init
  tau init --provider openai
  tau init --stdout
  tau init --force
```

- **Related:** errors `invalid_argument` · config keys `provider`, `model`, `api_key` · checks `doctor.config_file`, `doctor.config_permissions`
- **Explain:** `tau explain subcommand.init` (bare `tau explain init` resolves too)
- **Docs:** [docs/config.md](config.md)

### `tau setup`

One-shot onboarding — init + completions + editor-client wiring + doctor verdict

```text
tau setup - one-shot onboarding (init + completions + clients + doctor)

Usage:
  tau setup [options]

Options:
      --shell <name>     Shell completions to install:
                         bash|zsh|fish|pwsh|all
                         (default: detect $SHELL; env TAU_SETUP_SHELL)
      --client <name>    Editor/ACP client config to write:
                         zed|nvim|emacs|vscode|cursor|jetbrains|
                         windsurf|gemini|claude-desktop|opencode|
                         cline|goose|continue|roo-code|kilo-code|
                         amazonq|codex|all
                         (env TAU_SETUP_CLIENT)
      --provider <name>  Seed the config scaffold for a provider
      --model <id>       Passed through to the doctor step
      --api-key <key>    Passed through to the doctor step
      --offline          Passed to the doctor step (skip network)
      --deep             Passed to the doctor step (auth'd probe)
  -y, --yes              Approve all write steps (env TAU_YES=1)
      --non-interactive  Unattended contract for scripts/CI: never
                         prompts, never reads stdin
                         (env TAU_NONINTERACTIVE=1)
      --dry-run          Preview every write step; change nothing
      --import           Merge your existing MCP server entries from
                         the other supported clients' settings files
                         into each wired MCP client (windsurf|gemini|
                         claude-desktop|opencode|cline|roo-code|
                         kilo-code|amazonq): the mcacp entry
                         and your servers are spliced into existing
                         files
                         — comments and current entries survive
                         byte-for-byte, nothing is overwritten.
                         (env TAU_SETUP_IMPORT; not with --remove)
      --remove           Reverse per-client editor wiring: splice the
      --uninstall        tau (or mcacp) entry out of each client's
                         settings file (comments and other settings
                         survive byte-for-byte), delete files left
                         with no settings, clean setup-generated
                         snippets, and drop the shared mcacp bridge
                         entry once no remaining client uses it.
                         --client scopes the sweep; without it every
                         wired client is unwired.
      --detect           Read-only client inventory: list every
                         supported client's config dir, detection
                         status, and wiring state (settings path and
                         stale reason included) — writes nothing.
                         --client scopes the sweep.
      --json             Pin the stable schema-checked NDJSON stream
                         (schema/tau-setup.schema.json; output is
                         already NDJSON)

Examples:
  tau setup
  tau setup --dry-run
  tau setup --yes --client zed
  tau setup --shell bash --client claude-desktop --yes
  tau setup --remove --client zed
  tau setup --uninstall --dry-run
  tau setup --client windsurf --import --dry-run
  tau setup --detect
```

- **Related:** errors `invalid_argument` · config keys `provider` · checks `doctor.client_wiring`, `doctor.shell_completions`, `doctor.config_file`
- **Explain:** `tau explain subcommand.setup` (bare `tau explain setup` resolves too)
- **Docs:** [docs/editors.md](editors.md)

### `tau completions`

Install the generated shell completions — the setup step standalone

```text
tau completions - install the generated shell completions

Usage:
  tau completions install [--shell <name>] [--dry-run] [--json]
  tau completions candidates <group>

Commands:
  install          Write the completion script for the detected
                   shell (or --shell) into its completions dir and
                   wire the rc/profile autoload hook — the same
                   machinery `tau setup` runs as its completions
                   step. Idempotent: re-runs report
                   "already_installed"/"present" and never
                   duplicate the rc hook.
  candidates       Emit dynamic completion candidates (one per
                   line) for a group — the shipped scripts call
                   this at completion time: config-set lists
                   every key `tau config set` accepts;
                   config-get|config-unset list the keys present
                   in the config file

Options:
      --shell <name>  Shell to install for:
                    bash|zsh|fish|pwsh|all
                    (default: detect $SHELL)
      --dry-run       Preview the install — "would_install"/
                    "would_append" statuses plus "dry_run":true;
                    nothing is written
      --json          Pin the stable schema-checked result object
                    (schema/tau-completions.schema.json; output is
                    already JSON)

The result object is {"ok","status","shells":[...],"version",
 "done":true}; the exit code mirrors ok (0 success/skip, 1 failure).

Examples:
  tau completions install
  tau completions install --shell zsh
  tau completions install --shell all --dry-run
  tau completions candidates config-set
```

- **Related:** errors `invalid_argument` · checks `doctor.shell_completions`
- **Explain:** `tau explain subcommand.completions` (bare `tau explain completions` resolves too)
- **Docs:** [completions/README.md](../completions/README.md)

### `tau fleet`

Orchestrate parallel tau workers toward a goal

```text
tau fleet - orchestrate parallel tau workers toward a goal

Usage:
  tau fleet run --goal <text> [options]
  tau fleet status <id>
  tau fleet list
  tau fleet logs <id>
  tau fleet cancel <id>

Commands:
  run            Decompose the goal and dispatch workers
  status <id>    Show the fleet manifest (spec + per-item status)
  list           List active fleet ids
  logs <id>      Show per-worker session hints
  cancel <id>    Cancel a running fleet

Options (run):
      --goal <text>              Objective to decompose (required)
      --items <json>             Pre-supplied items (skip coordinator)
      --schema <json|@file>      JSON Schema for the coordinator reply
      --coordinator-model <id>   Override the coordinator's model
      --worker-model <id>        Override the workers' model
      --provider <name>          Provider override
      --model <id>               Model override
      --api-key <key>            API key override
      --sequential               Run workers one at a time
      --parallel                 Run workers in parallel (default)

Examples:
  tau fleet run --goal "ship the redesign"
  tau fleet run --goal "add tests" --sequential
  tau fleet run --goal "x" --items '{"items":[{"title":"t","prompt":"p"}]}'
  tau fleet list
  tau fleet status fleet-2026-10-31
  tau fleet cancel fleet-2026-10-31
```

- **Related:** errors `missing_required_field`, `invalid_argument` · config keys `provider`, `model`, `timeout_ms`
- **Explain:** `tau explain subcommand.fleet` (bare `tau explain fleet` resolves too)
- **Docs:** [AGENTS.md](../AGENTS.md)

### `tau config`

Inspect and edit ~/.config/tau/config.json (git-config style)

```text
tau config - inspect and edit ~/.config/tau/config.json

Usage:
  tau config show [global flags]       Merged effective config as JSON
                                       (file + env + flags; redacted)
  tau config validate [path]           Validate a config file
                                       (CI/pre-commit friendly)
  tau config set <key> <value> [path]  Schema-checked edit to the FILE
                                       (<field> or keys.<provider>)
  tau config get <key> [path]          Print a value (secrets redacted)
  tau config unset <key> [path]        Remove a key from the file
  tau config edit [path]               Open in $EDITOR; validates on save
  tau config schema                    Print the config file's JSON
                                       Schema (draft 2020-12)

Options:
      --json             Stable schema-checked JSON (show, validate)
      --mode text|json   Output mode
      --raw              (get only) Print the value unredacted
      --dry-run          (set|unset) Preview the exact write — unified
                         diff + .bak backup path — change nothing

Examples:
  tau config show
  tau config show --provider openai
  tau config validate
  tau config set provider openai
  tau config set keys.openai sk-your-key
  tau config set mode text --dry-run
  tau config get provider
  tau config unset model
  tau config edit
  tau config schema
```

- **Related:** errors `invalid_argument`, `not_found` · config keys `provider`, `api_key`, `mode` · checks `doctor.config_file`, `doctor.config_permissions`, `doctor.config_deprecated_keys`
- **Explain:** `tau explain subcommand.config` (bare `tau explain config` resolves too)
- **Docs:** [docs/config.md](config.md)
