# tau Troubleshooting FAQ

Every failure tau — or its installer — can hit, what it means, and how to fix
it. Match your symptom in the table below, or jump straight to the exit code.

tau reports failures on **stderr** as a single-line JSON envelope — even in
`--mode text`:

```json
{"err":{"code":106,"type":"AuthFailed","message":"no API key for provider 'openai' — set OPENAI_API_KEY env var, or use --api-key <key>","recoverable":false,"hint":"set OPENAI_API_KEY env var, or use --api-key <key>","docs":"https://github.com/javimosch/tau/blob/master/docs/providers.md","explain":"tau explain 106","catalog":"https://github.com/javimosch/tau/blob/master/docs/errors.md"}}
```

- `code` is also the process exit code — scripts can branch on `$?`.
- `message` is human-readable and usually names the exact fix.
- `hint` is a short remediation nudge for the error class — the fastest fix
  when you don't want to read further.
- `docs` links to the guide for that error class — auth failures (code 106)
  link to [providers.md](providers.md), everything else links back to this
  page (`https://github.com/javimosch/tau/blob/master/docs/troubleshooting.md`).
- `explain` is the ready-to-run `tau explain <code>` command — it prints the
  catalog entry (cause + fix + docs link) offline. Agents can exec it
  verbatim.
- `catalog` links to [errors.md](errors.md), the generated catalog of every
  error code. `explain` and `catalog` are always the last fields in the
  envelope.

## Start here — match your symptom

| You see … | It means | Go to |
|-----------|----------|-------|
| `command not found: tau` after installing | The install dir isn't on `PATH` | [Install & upgrade failures](#install--upgrade-failures) |
| `install.sh: checksum verification failed` / `not listed in SHA256SUMS.txt` / `no sha256sum` | Fail-closed verification aborted the install | [Install & upgrade failures](#install--upgrade-failures) |
| `install.sh: unsupported OS` / `unsupported architecture` | No prebuilt binary for that platform | [Install & upgrade failures](#install--upgrade-failures) |
| `tau doctor` prints `"status":"fail"` rows | Diagnosable setup problem — some auto-fixable | [Setup & config problems](#setup--config-problems--tau-doctor) |
| `{"warn":{"message":"config file has invalid JSON …"}}` | Config doesn't parse; tau runs on defaults | [Setup & config problems](#setup--config-problems--tau-doctor) |
| `{"err":{"code":106,…}}` — or a silent exit 106 | Missing or rejected API key | [Authentication failures](#authentication-failures-exit-106) |
| `{"err":{"code":105,…}}` | Request timed out | [Timeouts](#timeouts-exit-105) |
| `{"err":{"code":110,…}}`, or a run dies mid tool-loop | HTTP/tool/internal failure | [Internal errors](#internal-errors-exit-110) |
| `{"err":{"code":80,…}}` | Bad flag, value, or subcommand | [Invalid arguments](#invalid-arguments-exit-80) |
| `{"err":{"code":82,…}}`, or bare `tau` exits 82 | Required input missing | [Missing required fields](#missing-required-fields-exit-82) |
| `{"err":{"code":1,…}}` / `… not found` | Named resource missing | [Not found](#not-found-exit-1) |
| `… unsupported on this platform` (exit 111) | Feature not implemented here | [Unimplemented](#unimplemented-exit-111) |
| `{"warn":{…}}` line, run continues | Non-fatal problem | [Warnings](#warnings-run-continues) |
| The model calls wrong tools or loops | Tool-loop problem — usually self-corrects | [Tool-loop problems](#tool-loop-problems-model-side-recoverable) |
| Something looks off but nothing failed | Often intended behavior | [Looks broken but isn't](#looks-broken-but-isnt) |

## Stable error catalog

`code` and `type` are **stable**: they never change for a given failure class,
so integrations may switch on them. (New codes may be added; existing ones are
never renumbered or renamed.) `hint` is the canned remediation emitted in the
envelope — dynamic failures (like a missing API key) override it with a
more specific hint.

| Exit code | Envelope `type` | `hint` | `docs` |
|-----------|-----------------|--------|--------|
| `1` | `not_found` | the message names what was not found — check the name/path and retry | this page |
| `80` | `invalid_argument` | run `tau --help` (or `tau --help-json`) for the valid flags and values | this page |
| `82` | `missing_required_field` | the message names the missing input — supply it and retry | this page |
| `105` | `Timeout` | raise --timeout-ms (default 120000) or check the endpoint/network (TAU_ENDPOINT) | this page |
| `106` | `AuthFailed` | provide an API key via --api-key, the provider env var, config.json, or TAU_API_KEY | [providers.md](providers.md) |
| `110` | `internal_error` | re-run with --debug to write a diagnostic log, then file a bug report | this page |
| `111` | `unimplemented` | not supported on this platform — the message names the workaround | this page |

Some emitters override `type` with the underlying Zig error name (e.g.
`HTTPRequestFailed` on exit 110) while keeping `code` stable — branch on
`code` first, `type` second.

[docs/errors.md](errors.md) is a **generated** mirror of this catalog (with
per-code causes and the silent-exit paths) rendered from the registry in
`src/errors.zig` — CI fails if it drifts. The same registry is readable
offline from the CLI: `tau explain <code|type>` prints one entry's cause,
hint, and docs link (JSON by default — `--json` pins the schema-checked
form, `--human` renders prose), and bare `tau explain` lists the whole
catalog.

Non-fatal problems use a separate `{"warn":{"message":"..."}}` envelope and the
run continues.

---

## Quick index by exit code

| Exit code | Envelope `type`        | Meaning                                | First thing to check |
|-----------|------------------------|----------------------------------------|----------------------|
| `0`       | —                      | Success                                | — |
| `1`       | `not_found`            | Named resource missing                 | The `message` names what wasn't found |
| `80`      | `invalid_argument`     | Bad flag, value, or subcommand         | `tau --help` / `tau --help-json` |
| `82`      | `missing_required_field` | Required input missing               | The `message` names what's missing |
| `105`     | `Timeout`              | HTTP request timed out                 | `--timeout-ms`, network, endpoint |
| `106`     | `AuthFailed`           | Missing or rejected API key            | Key resolution order (below) |
| `110`     | `internal_error`, `HTTPRequestFailed`, `Timeout`-adjacent | Request/tool/internal failure | Re-run with `--debug` |
| `111`     | —                      | Not implemented on this platform       | The `message` names the workaround |

---

## Install & upgrade failures

Installer failures print `install.sh: <message>` (or `install.ps1:
<message>`) on **stderr** and exit non-zero — they do *not* use the
`{"err"}` envelope, because tau itself never ran. The same messages surface
when `tau upgrade` fails: it downloads `install.sh` from the release tag and
runs it in place, relaying the installer log to stderr while stdout stays a
single JSON result (`{"status":"failed","detail":…}`, exit 1).

| Installer message | Cause | Fix |
|-------------------|-------|-----|
| `unsupported OS '<os>'` | No prebuilt binary — install.sh ships linux and macos only | Build from source (README "Build & Install"); on Windows use `install.ps1` |
| `unsupported architecture '<arch>'` | No asset for that CPU (x86_64/aarch64 on POSIX; x86_64 only on Windows) | Build from source, or override detection via `TAU_ARCH` only if a matching asset actually exists |
| `invalid --version '<v>'` | Not a dotted triple | Pass e.g. `--version 0.5.0` (or `TAU_VERSION`) |
| `curl not found on PATH` / `tar not found on PATH` | Prerequisite missing | Install curl/tar — both ship with macOS — or build from source |
| `download failed — check that release … ships <asset>` | Asset missing from the release, or network/proxy blocked | Check `TAU_BASE_URL` isn't pointing at an incomplete mirror; retry; pick another `--version` |
| `could not download SHA256SUMS.txt` | The checksum manifest isn't on the release — verification fails closed by design | Don't bypass lightly; on a trusted mirror `TAU_SKIP_CHECKSUM=1` skips verification (a warning is printed) |
| `<asset> is not listed in SHA256SUMS.txt` | Manifest/asset mismatch — partial or tampered mirror | Prefer fixing the mirror over `TAU_SKIP_CHECKSUM=1` |
| `checksum verification failed for <asset>` | Download corrupted or tampered — aborts by design | Re-download; if it persists, distrust the network path |
| `no sha256sum/shasum on PATH` | No checksum tool to verify with | Install coreutils, or `TAU_SKIP_CHECKSUM=1` on a trusted source |
| `cannot create install dir <d>` / `cannot write <d>/tau` | Destination not writable | Pick a writable `--dir`/`TAU_INSTALL_DIR`, or fix ownership |
| `note: <dir> is not on your PATH` (install itself succeeded) | Shell can't find the binary | Add the printed `export PATH="<dir>:$PATH"` line to your shell rc |

`tau upgrade` adds two failure modes of its own: `"installer download
failed"` (the `install.sh` fetched from the release tag — or `TAU_INSTALL_URL`
— didn't arrive) and exit **111** on Windows, where self-update is
unsupported — re-run `install.ps1` instead. A successful `upgrade` prints
`{"status":"upgraded",…}`; `"skipped"` when already current — both exit 0.
The release-notes preview (`changes in tau …` on stderr plus the report's
`"changelog"` field) is advisory only: when the tag's `CHANGELOG.md` can't
be fetched (`TAU_CHANGELOG_URL` overrides the source, e.g. for mirrors)
the summary is silently dropped and the upgrade proceeds.

After install, `tau setup --yes` runs the whole onboarding chain unattended
(init → completions → editor ACP client config → `doctor` health report) as
one NDJSON transcript and exits 1 if any step fails — the verdict names the
failing step.

---

## Setup & config problems — `tau doctor`

`tau doctor` runs the setup health checks and prints one JSON report on
stdout; exit 0 when nothing failed, 1 otherwise. `--json` streams one
NDJSON `{"check":{...}}` event per check plus a terminal `done:true` verdict
for CI/support tooling; `--offline` skips every check that would touch the
network. Rows:

| Check | Fails or warns when |
|-------|---------------------|
| `config_file` | `~/.config/tau/config.json` doesn't parse (**fail**), or names an unregistered provider (**warn**). Missing file is ok — config is optional |
| `config_permissions` | Config dir/file is readable by group/other (POSIX only — the file can hold API keys) |
| `plaintext_secrets` | Credentials sit on disk as plaintext — `api_key`/`keys.*` values in the config file, or `env` blocks inside client settings files. Warn only; reports key names/counts, never values. Not auto-fixable — the hint names `tau config unset` + env vars |
| `shell_completions` | Completion scripts are missing or stale for the detected shells |
| `provider_resolution` | The configured/`--provider` provider isn't registered |
| `api_key` | No key resolves at any level of the precedence chain |
| `curl` | `curl` is missing or `curl --version` fails — all LLM HTTP needs it |
| `endpoint_reachable` | The provider endpoint doesn't answer (skipped under `--offline`) |
| `auth_probe` (`--deep` only) | A one-token authenticated completion fails — the resolved key is rejected |
| `client_permissions` | A detected client settings file (or the mcacp bridge config) grants group/other access — env blocks inside it can hold API keys (POSIX only) |
| `update_available` | A newer release exists (warn only; opt out via `TAU_NO_UPDATE_CHECK=1`) |
| `provider_probes` (`--probe` only) | Per-provider sweep: connectivity + credential pass/fail rows for *every* registered provider — reports key sources, never key material |
| `selftest` (`--selftest` only) | Credential-free end-to-end run against a loopback stub provider fails — proves the installed binary works without real credentials or network |

### `tau doctor --fix` — automatic remediation

Fixable outcomes are remediated by `--fix`, planned in check order (deduped —
several rows can share one fix) and applied each only after confirmation:

- `--yes` approves everything — the script/CI path;
- on an interactive TTY each fix gets a
  `doctor --fix: <description> — apply? [y/N]` prompt on stderr (only `y`/`yes`
  approves);
- piped/non-TTY without `--yes` reports each fix as
  `"status":"skipped","detail":"not confirmed — pass --yes to apply non-interactively"`.

| Fix id | Triggered by | What it does |
|--------|--------------|--------------|
| `scaffold_config` | `config_file` — no config exists | Writes the `tau init` starter config, creating `~/.config/tau` (0700/0600 on POSIX) |
| `restore_config` | `config_file` — invalid JSON | Moves the broken file to `config.json.bak`, then scaffolds a fresh one |
| `chmod_config` | `config_permissions` (or an unreadable `config_file`) | `chmod 0700` on `~/.config/tau`, `0600` on `config.json` |
| `install_completions` | `shell_completions` | Installs/refreshes completion scripts (+ rc hooks where needed) |
| `chmod_client_files` | `client_permissions` | `chmod 0600` on every detected client settings file (and `mcacp.json`) — their `env` blocks can hold API keys |

Each fix reports
`{"fix":{"id":…,"check":…,"status":"applied|declined|skipped|failed","detail":…}}`
— as an NDJSON event under `--json`, in the report's `"fixes"` array, and as
a `## Fixes` table under `--report`. When anything applied, the checks re-run
so the verdict and exit code reflect the post-fix state.

For config *content* problems rather than syntax: `tau config validate`
prints a `{"path","ok","errors":[{key,message}]}` report on stdout and exits
1 on failure (with did-you-mean suggestions for misspelled keys) — usable as
a pre-commit/CI gate. `tau config set|get|unset` make schema-checked,
comment-preserving edits from scripts, and `tau config edit` opens the file
in `$EDITOR` (`TAU_EDITOR` > `VISUAL` > `EDITOR`) and validates on save.

---

## Authentication failures (exit 106)

Envelopes for this class link `docs` to [providers.md](providers.md) — the
per-provider credential setup guide. The short version:

### `no API key for provider '<name>' — set <ENV> env var, or use --api-key <key>`

tau could not find a usable key anywhere in the resolution chain. The message
names the provider's own env var(s). Fix it by providing a key at any level:

| Order | Source | Example |
|-------|--------|---------|
| 1 | `--api-key` flag | `tau --api-key sk-... "hi"` |
| 2 | config `keys["<provider>"]` | `{"keys": {"openai": "sk-..."}}` in `~/.config/tau/config.json` |
| 3 | provider env var | `OPENAI_API_KEY`, `DEEPSEEK_API_KEY`, `XIAOMI_API_KEY`/`PIZIG_API_KEY`, `OPENCODE_API_KEY` |
| 4 | config global `api_key` | `{"api_key": "sk-..."}` in `~/.config/tau/config.json` |
| 5 | `TAU_API_KEY` env var | `export TAU_API_KEY=sk-...` |
| 6 | provider builtin key | only providers that ship one |

Empty values are skipped at every level.

### Exit 106 with **no** error output

`resolveApiKey` found nothing, so the run exits before the first request.
Same fix as above — set any key source.

### 106 even though `TAU_API_KEY` is set

A stale `api_key` or `keys[provider]` in `~/.config/tau/config.json` silently
outranks `TAU_API_KEY` (levels 2 and 4 beat level 5). Inspect the file with
`cat ~/.config/tau/config.json` and remove the stale key, or pass
`--api-key` to override everything.

### Valid key still rejected

The provider returned an auth error (401-class response). Check that the key
isn't expired/revoked, and — if you use `TAU_ENDPOINT` — that the endpoint
expects the same auth scheme (`Authorization: Bearer <key>`).

---

## Timeouts (exit 105)

### `{"err":{"code":105,"type":"Timeout","message":"request failed",...}}`

The `curl` request exceeded `--timeout-ms` (default **120000** ms = 2 min).

- Long generations / big tool loops → raise it: `--timeout-ms 300000`.
- Slow endpoint or proxy → verify `curl -sS <endpoint>` responds at all.
- Streaming (`-N` SSE) uses the same budget; add `--no-stream` for batch-style
  calls that sit on one large request.

---

## Internal errors (exit 110)

### `{"err":{"code":110,"type":"HTTPRequestFailed","message":"request failed",...}}`

The HTTP layer failed after **3 attempts** (transient failures retry with
backoff automatically). Usual causes:

- **`curl` missing** — tau shells out to `curl` for all LLM HTTP. `which curl`.
- **Endpoint unreachable** — DNS/proxy/firewall, or a typo in `TAU_ENDPOINT`.
- **Endpoint keeps returning errors** — rate limits (429) and 5xx retry, then
  give up. Check provider status; try again or switch `--provider`.
- **Malformed response** — the endpoint isn't OpenAI-compatible
  (`/chat/completions` shape). Re-run with `--debug` to see the raw body.

Re-run with `--debug` — it prints perf stats and the raw API response to stderr.

### `fleet failed`, `acp failed`, `skills scan failed`, `agents scan failed`

The `type` field carries the Zig error name (e.g. `OutOfMemory`,
`FileNotFound`). These are environmental or internal faults — file an issue
with the full envelope if it reproduces.

### `InvalidWorkItem at index <n>: missing or non-string field '<field>'`

`tau fleet run --items '<json>'` received an item that doesn't match the work
schema. Every item needs the required string fields — compare your JSON with
the `--items` example in `tau --help`.

### Exit 110 **without** an envelope, after a long tool loop

Not an HTTP failure: the run hit `--max-iterations` (default 100) — the
runaway backstop. tau still emits the last answer, but exits 110 unless the
model had already produced a final turn. Fixes:

- `--max-iterations 200` for genuinely long tool chains
- `--tools <csv>` to narrow the allowlist so the model converges faster
- `--no-tools` if tool use wasn't intended at all

---

## Invalid arguments (exit 80)

All of these carry `"type":"invalid_argument"` and print the offending value.

| Message | Cause | Fix |
|---------|-------|-----|
| `unknown option: --<flag>` | Typo or unsupported flag | `tau --help` lists every flag; `tau --help-json` for machines |
| `missing value for --<flag>` | Flag needs an argument | `--model openai/gpt-4o-mini`, not a bare `--model` |
| `invalid --mode (want text\|json): <v>` | Bad `--mode` | Only `text` or `json` |
| `invalid --role (want author\|critic\|coordinator\|none): <v>` | Bad `--role` | One of the four roles |
| `invalid --<flag>: <v>` (temperature, max-tokens, timeout-ms, context-window, iterations…) | Non-numeric value | Pass a number: `--temperature 0.7` |
| `unknown provider '<name>' — valid providers: … (run 'tau models' for details)` | `--provider` or `--model p/m` used an unregistered provider | `tau models` lists valid names: `xiaomi`, `openai`, `deepseek`, `opencode-go` |
| `skills subcommand required: list \| search \| load` | Bare `tau skills` | Pick a subcommand |
| `invalid skills subcommand (want list\|search\|load): <v>` | Bad subcommand | `list`, `search`, or `load` |
| `fleet subcommand required: run \| status \| list \| logs \| cancel` | Bare `tau fleet` | Pick a subcommand |
| `unknown fleet argument: <v>` / `unknown fleet subcommand` | Flag/subcommand not in the fleet grammar | `tau fleet --help` lists the grammar + runnable examples |
| `unknown acp argument: <v>` | Flag passed after `tau acp` | `tau acp serve\|start\|stop\|status` only |
| `cannot read schema file: <path>` | `--schema @file` unreadable | Check the path; or pass the schema inline |
| `/goal subcommands require --session <name>` | `/goal status\|pause\|resume\|clear\|complete` without a session | Add `--session <name>` |
| `argument parsing failed` (type `internal_error`) | Arg parser itself failed (OOM etc.) | Report it — not user error |

---

## Missing required fields (exit 82)

| Message | Fix |
|---------|-----|
| `fleet <cmd> requires <what>` (e.g. `fleet run requires --goal`) | Supply the named flag: `tau fleet run --goal "…"` |
| `skill name required` | `tau skills load <name>` — find names via `tau skills list` |
| `HOME not set` | tau builds `~/.config/tau` paths from `$HOME`; export it |

Exit 82 **without** a message means tau was invoked with no prompt, no active
goal, and nothing to continue — give it a prompt or resume a goal session.

---

## Not found (exit 1)

| Message | Fix |
|---------|-----|
| `skill not found: <name>` | `tau skills list` — skills live in `~/.agents/skills/` |
| `AGENTS.md not found: <path>` | `--load-agents-md` needs a real file; `--scan-agents` lists what's discoverable |
| `Tool '<name>' not found` (inside the tool loop, not the envelope) | The model called an unregistered tool. Valid names: `bash`, `read`, `write`, `edit`, `ls`, `grep`, `find`, `calculator`. tau feeds the error back to the model and continues — no action needed unless it loops |

---

## Unimplemented (exit 111)

### `acp daemon (start/stop/status) is unsupported on this platform; use 'tau acp serve' over stdio`

`tau acp start|stop|status` needs a Unix socket. On platforms without one, run
`tau acp serve` in the foreground over stdio instead.

---

## Warnings (run continues)

### `{"warn":{"message":"config file has invalid JSON and was ignored: <path> — fix the JSON syntax or delete the file"}}`

`~/.config/tau/config.json` exists but doesn't parse. tau falls back to
defaults — flags and env vars still work. Fix the syntax or delete the file,
or run `tau doctor --fix` — it moves the broken file to `config.json.bak`
and scaffolds a fresh one. `tau config validate` pinpoints the error with a
line/column. The file is JSONC: `//` and `/* */` comments are allowed (the
`tau init` scaffold is commented), but trailing commas are not.

### `failed to save session <name>: <err>` (stderr, non-fatal)

The conversation result was still printed; only persistence to
`~/.config/tau/sessions/<name>.json` failed — usually a permissions or disk
problem. Check the directory is writable.

---

## Tool-loop problems (model-side, recoverable)

These appear as `role:"tool"` messages inside the transcript — the run usually
continues and self-corrects.

| Message | Meaning | Nudge |
|---------|---------|-------|
| `Tool '<name>' not found` | Model hallucinated a tool name | Restrict with `--tools`, or add the real tool name to the prompt |
| `Tool execution failed: MissingArgument` | Model omitted a required arg | Reprompt with the required params spelled out |
| `Tool execution failed: UnsafeArgument` | Path traversal (`..`) or NUL bytes blocked by validation | Working as intended — keep paths inside the project |
| `Error: <stderr>` from `bash` | The command itself failed | Read the embedded stderr; the model sees it too |

Use `--dry-run` to preview which tools the model *would* call without executing
any of them.

---

## Looks broken but isn't

| Symptom | Explanation |
|---------|-------------|
| `tau` with no args prints help and exits | Expected — tau is non-interactive; give it a prompt |
| Output is JSON when you wanted prose | JSON is the default. `--mode text` |
| Errors are JSON even in `--mode text` | By design — stderr always uses the envelope |
| `"content":""` with `done:true` | Legitimate empty reply (often after a tool-call turn) |
| Nothing persisted | Sessions only persist with `--session <name>` |
| `tau acp serve` reads no `TAU_MODEL`-style env var | Model comes from config or `--model` |
| `--no-stream` still shows a "stream" in config | Config `stream` default is `true`; the flag wins at runtime |

---

## Diagnostic toolkit

| Command | Use it to |
|---------|-----------|
| `tau --debug "<prompt>"` | Perf stats, tool-call I/O, raw API response on stderr — plus a redacted log under `~/.config/tau/debug/` |
| `tau --dry-run --tools bash,read "<prompt>"` | See planned tool calls, execute none |
| `tau --thinking "<prompt>"` | Show model reasoning chunks |
| `tau models` | List providers + default models (JSON) |
| `tau doctor` | One-shot setup health report on stdout (config, provider, key, completions, curl, endpoint) — exit 1 on any `fail` row; `--offline` skips network checks |
| `tau doctor --fix` | Auto-remediate fixable rows — scaffold/restore config, tighten permissions, install completions (confirms per fix; `--yes` for unattended) |
| `tau doctor --json` | Same diagnostics as NDJSON check events + `done:true` verdict — for CI/support tooling |
| `tau doctor --report` | Redacted Markdown diagnostics bundle (build metadata, checks, sanitized config) — paste straight into a bug report |
| `tau doctor --fix [--yes]` | Auto-remediate fixable checks: missing/invalid config, loose config and client-file permissions, missing completions, and missing or stale editor client wiring (`client_zed`/`client_vscode`/`client_jetbrains`/`client_windsurf`/`client_gemini`/`client_claude_desktop` rows — a dead `command` path or wrong `args` counts as stale; an existing settings file is never rewritten — you get a paste-ready snippet in `~/.config/tau/snippets/` instead) |
| `tau doctor --probe` | Live-verify every provider: per-provider connectivity + credential pass/fail rows (key sources only, never key material) |
| `tau doctor --selftest` | Credential-free end-to-end check: spawns tau against a loopback stub provider (throwaway HOME, stub key) — verifies the installed binary works without real credentials or network; runs under `--offline` |
| `tau version --check` | Non-blocking update check against the latest release (always exits 0; `TAU_NO_UPDATE_CHECK=1` opts out — also silences the `update_available` doctor warning) |
| `tau upgrade` | Self-update in place via the same fail-closed SHA256-verified install.sh (`--yes` skips the confirmation prompt; POSIX only) |
| `tau setup --yes` | Unattended onboarding: init + completions + ACP client config + doctor as one NDJSON transcript — exit 1 on any failed step |
| `tau config validate [path]` | Offline config-file validation (`{"ok","errors":[…]}` on stdout, exit 1 on failure) — CI/pre-commit gate |
| `tau bug` | Pre-filled GitHub issue URL carrying that same redacted bundle (`--open` launches the browser, `--out <path>` writes the bundle to a file, `--no-report` omits diagnostics) |
| `tau --help-json` | Machine-readable flag catalog |
| `tau <sub> --help` | Per-subcommand usage + runnable examples (`tau fleet --help`, `tau doctor --help`, …) |
| `tau guide` / `tau guide --human` | Embedded operator manual (JSON / markdown) |
| `tau acp status` | Is the ACP daemon running? |
| `echo $?` after a failure | Semantic exit code for scripting |

Still stuck? Re-run with `--debug` — stderr prints a `{"debug_log":"<path>"}`
line pointing at a redacted diagnostic log under `~/.config/tau/debug/`
(`TAU_DEBUG_LOG` overrides the path), and `{"err":...}` envelopes carry the
same path in a `debug_log` field. Credentials are masked
(`***REDACTED***`), but review the file before sharing — it still contains
tool I/O and endpoint details. Attach it to a bug report:
<https://github.com/javimosch/tau/issues>

Or let tau do it: `tau bug --open` builds a pre-filled issue URL carrying the
redacted `tau doctor --report` bundle and opens it in your browser (`--title`
and `--body` fill in the title and description, `--out <path>` also writes
the bundle to a file for manual attaching).
