# tau stability & deprecation contract

What scripts, CI pipelines, and editor integrations may rely on — and what
may change without notice. tau is built for agents, so machine-readable
surfaces are treated as a public API: this document pins which ones are
**stable**, which are **informational**, and how a stable surface is
deprecated and removed.

Drift check: `python3 scripts/check-stability-doc.py` verifies this file
stays aligned with the shipped contract (every catalog exit code, every
checked-in schema, every linked doc). The `stability-doc` smoke group runs
it in CI.

## Versioning

tau follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
(see [CHANGELOG.md](../CHANGELOG.md)). While the major version is `0.x`:

- Breaking changes to a **stable** surface below ship only in a **minor**
  release, are marked **Breaking** in the changelog, and follow the
  [deprecation policy](#deprecation-policy) below.
- New flags, subcommands, JSON fields, config keys, error codes, and
  environment variables are **additive** and may land in any release —
  consumers must tolerate keys and fields they do not recognize.
- Capabilities not yet in a tagged release are **not** covered by this
  contract. [docs/compatibility.md](compatibility.md) marks which
  integration paths are released versus pending.

## Tiers

| Tier | Promise |
|------|---------|
| **stable** | Covered by this contract. Changes follow the deprecation policy; additive extensions may land anytime. |
| **informational** | For humans and debugging. Wording, layout, and formatting may change in any release. Never parse it. |
| **internal** | tau's own bookkeeping. Not a public surface — structure may change without notice. |

## Stable contract

### Exit codes and the `{"err"}` envelope

Every failure is a single-line JSON envelope on **stderr** — even in
`--mode text` (fleet subcommands are the exception: they report on
stdout):

```json
{"err":{"code":106,"type":"AuthFailed","message":"...","recoverable":false,"hint":"...","docs":"...","explain":"tau explain 106","catalog":"..."}}
```

- `code` equals the process exit status. It is the primary integration
  key: branch on `code` first.
- `code` and `type` are **never renumbered or renamed** for a failure
  class. New codes may be added; exit `0` always means success.
- The envelope field set (`code`, `type`, `message`, `recoverable`,
  `hint`, `docs`, `explain`, `catalog`) is stable; emitters may append
  fields (e.g. `debug_log`). Treat objects as unordered — the only
  ordering guarantee is the documented footer convention: `explain`
  penultimate, `catalog` last.
- `message` and `hint` are informational text: they may be reworded to
  improve remediation. Never match on their contents.
- An exit code outside the catalog still produces a well-formed envelope
  (`internal_error` type, its own `code`); a small number of paths exit
  silently with no envelope. The full catalog and the silent-exit table:
  [docs/errors.md](errors.md) — readable offline via `tau explain <code>`.

The stable codes today:

| Code | Meaning |
|------|---------|
| `0` | success |
| `1` | `not_found` — a named resource is missing |
| `80` | `invalid_argument` — unknown flag, bad value, invalid subcommand |
| `82` | `missing_required_field` — required input absent |
| `105` | `Timeout` — provider request exceeded `--timeout-ms` |
| `106` | `AuthFailed` — provider rejected or no API key resolved |
| `110` | `internal_error` — HTTP/parse/tool failure, iteration cap |
| `111` | `unimplemented` — not supported on this platform |
- Non-fatal problems emit `{"warn":{"message":"..."}}` on stderr and the
  run continues.

### Structured stdout (`--mode json`, `--json`)

The default output mode is JSON. These shapes are stable (fields may be
added; existing fields keep their names, types, and meaning):

| Surface | Shape | Contract doc / schema |
|---------|-------|----------------------|
| chat result (non-streaming) | `{"version","model","content","done":true}` | this file |
| chat streaming | NDJSON `{"chunk":..,"done":false}` and `{"reasoning":..,"done":false}` (`--thinking`) intermediates, terminal `done:true` line | this file |
| `tau doctor` report | single-object `{"ok","version","build","checks","summary"}` | [docs/doctor-json.md](doctor-json.md) |
| `tau doctor --json` | NDJSON check/fix events + terminal `{"ok",...,"done":true}` verdict | [docs/doctor-json.md](doctor-json.md) + [schema/tau-doctor.schema.json](../schema/tau-doctor.schema.json) |
| `tau config schema` | JSON Schema (draft 2020-12) | [schema/tau-config.schema.json](../schema/tau-config.schema.json) + [docs/config.md](config.md) |
| `tau config show [--json]` | resolved effective config, secrets masked | [schema/tau-config-show.schema.json](../schema/tau-config-show.schema.json) + [docs/configuration.md](configuration.md) |
| `tau config validate [--json]` | `{"path","ok","errors":[{key,message}]}` on stdout; exit 0/1/80 | [schema/tau-config-validate.schema.json](../schema/tau-config-validate.schema.json) |
| `tau explain` | `{"errors":[{code,type,recoverable,cause,hint,docs}]}` or one entry | [docs/errors.md](errors.md) |
| `--help-json` | `{"version","name","description","flags","goal_commands","output_modes","defaults","exit_codes"}` | this file |
| `tau models` | `{"providers":[{name,default_model,...}]}` | this file |
| `tau skills list` / `search` | `{"skills":[{name,description}]}` | this file |
| `tau version [--json]` / `--verbose` / `--check` | `{"name","version"}` (+ build fields under `--verbose`, check fields under `--check`) | [schema/tau-version.schema.json](../schema/tau-version.schema.json) |
| `tau setup` | one NDJSON object per step + terminal verdict (`"dry_run":true` under `--dry-run`, `"yes"`/`"non_interactive"` markers) | this file |
| `tau bug` | `{"title","labels","url","body","report","url_truncated","out","opened","done":true}`; always exit 0 | this file |
| `tau upgrade` | JSON step/verdict output; POSIX-only (exit 111 elsewhere) | this file |
| `tau fleet` | manifests + status as pretty-printed JSON on stdout | this file |

Two cross-cutting conventions are part of the contract:

- **`done` marker**: every NDJSON stream ends with exactly one
  `done:true` line; a missing terminal line means the stream was
  truncated.
- **stdout purity**: JSON/NDJSON on stdout is never colorized and never
  interleaved with diagnostics — diagnostics always go to stderr (see
  the color policy in [docs/configuration.md](configuration.md)).

### Config file keys

`~/.config/tau/config.json` is a JSONC file whose key set is pinned by
[schema/tau-config.schema.json](../schema/tau-config.schema.json)
(checked in, drift-checked against `tau config schema`):

- Key names, value types, and semantics are stable. New keys are
  additive; removing or retyping a key follows the deprecation policy.
- Unknown keys produce a `{"warn":...}` envelope, never a hard failure —
  configs written for newer tau versions keep loading on older ones.
- Precedence is stable: **CLI flags > environment > config file >
  defaults** (full chain in [docs/configuration.md](configuration.md),
  including the `api_key` resolution order).
- `tau config set|get|unset|validate|schema` are the supported way to
  edit and verify the file programmatically.

### Environment variables

`TAU_*` variable names and meanings are stable
([docs/configuration.md](configuration.md) lists them all — e.g.
`TAU_API_KEY`, `TAU_ENDPOINT`, `TAU_YES`, `TAU_NONINTERACTIVE`,
`TAU_NO_UPDATE_CHECK`, `TAU_DEBUG_LOG`, `TAU_EDITOR`, installer knobs
like `TAU_BASE_URL`/`TAU_INSTALL_DIR`/`TAU_VERIFY_SIGSTORE`). The
`NO_COLOR`/`CLICOLOR`/`CLICOLOR_FORCE`/`TERM` color policy is also
stable: machine channels never emit ANSI escapes.

### ACP wire protocol

`tau acp serve` speaks JSON-RPC 2.0 over stdio (or a Unix socket) as an
[ACP](https://agentclientprotocol.com) agent: `initialize`,
`authenticate`, `session/new`, `session/load`, `session/prompt`,
`session/cancel`, outbound `session/update` notifications. The wire
shapes are stable — editor client wiring that `tau setup --client`
writes (args exactly `["acp","serve"]`) and `tau doctor` `client_*`
checks validate against it ([docs/acp.md](acp.md),
[docs/compatibility.md](compatibility.md)).

### Installer & release contract

- `install.sh` / `install.ps1` fail closed: no `SHA256SUMS.txt`
  manifest, no checksum tool, or a checksum mismatch means no install.
  Asset naming (`tau-<os>-<arch>.tar.gz`) keeps the version out of the
  filename so `latest/download/` URLs are permanent.
- `tau upgrade` reuses the same verified installer path (env contract:
  `TAU_BASE_URL`, `TAU_INSTALL_DIR`, `TAU_INSTALL_URL`,
  `TAU_SKIP_CHECKSUM`, `TAU_VERIFY_SIGSTORE` flow through to it).

## Informational surfaces

Provided for humans; may change in any release without deprecation:

- `--mode text` output, `--help` text layout, man page wording, `tau
  guide` prose
- `message`/`hint`/`reason`/`cause` strings in envelopes and reports
- `[DEBUG]` stderr lines and the `~/.config/tau/debug/` log contents
- `tau doctor --report` Markdown layout, `tau bug` issue-body prose
- interactive prompts (`tau upgrade`, `tau doctor --fix` confirmations)

## Internal surfaces

Not a public API — shape may change without notice:

- `~/.config/tau/sessions/<name>.json` (session history + goal state)
- `~/.config/tau/fleets/<id>.json` on-disk manifest format
- `~/.config/tau/snippets/*` paste-ready client fragments
- `.zig-cache`, ACP pid/log files

## Deprecation policy

When a stable surface must change in a non-additive way:

1. **Announce** in the release's CHANGELOG entry (marked **Deprecated**)
   and in the relevant doc; where feasible the binary emits a
   `{"warn":...}` envelope naming the replacement.
2. **Overlap**: the old and new forms both work for at least **one full
   release cycle** after the deprecation ships. During the window the
   old form keeps functioning and the docs name the replacement.
3. **Remove** only in a later release, listed under **Breaking** with
   migration notes.

Special rules:

- **Exit codes are never reused.** A retired code stays reserved and is
  marked as such in [docs/errors.md](errors.md).
- **JSON fields are additive.** A field is renamed/retyped by emitting
  the replacement alongside the old field during the window; consumers
  must ignore unknown fields.
- **Config keys** follow the same overlap: the old key loads with a
  warning during the window.
- **Env vars** follow the same overlap: the old name is honored during
  the window.
- The `{"err"}` envelope shape, the `done` stream marker, and stdout
  purity are **invariants** — they are never deprecated, only extended
  additively.

## Rules for building automation

- **DO** branch on `code`, not `type` or `message`.
- **DO** wait for the `done:true` terminal line (or check the exit code)
  when consuming NDJSON.
- **DO** validate streams against the checked-in schemas under
  `schema/` — and prefer `tau config schema`/`tau config validate` for
  config files.
- **DO** tolerate unknown fields, flags, config keys, and env vars.
- **DO** pin installs through the SHA256-verified installer; check
  minimum tau versions in [docs/compatibility.md](compatibility.md).
- **DON'T** parse `--mode text`, help text, `[DEBUG]` lines, or prompt
  strings.
- **DON'T** rely on JSON field order (the `explain`/`catalog` envelope
  footer is the only documented exception).
- **DON'T** read internal files (sessions, fleet manifests, debug logs)
  as a stable format.

## How the contract is enforced

- `src/errors.zig` is the single error registry — every catalog row is
  asserted byte-for-byte in `zig build test` and rendered into
  [docs/errors.md](errors.md) (drift-checked by
  `scripts/gen-errors-doc.py --check`).
- Golden tests byte-lock the `--help`/completions surface, error
  envelopes, onboarding flows, and color policy under `tests/golden/`.
- `schema/tau-config.schema.json` is byte-compared against
  `tau config schema` output in CI; `schema/tau-doctor.schema.json` is
  validated against real NDJSON streams by
  `scripts/check-doctor-schema.py`; the single-object stdout contracts
  (`tau-config-show`, `tau-config-validate`, `tau-version`) are validated
  against real binary output by `scripts/check-cli-schema.py`.
- `scripts/check-stability-doc.py` keeps this document aligned with the
  shipped catalog, schemas, and docs; the `stability-doc` smoke group
  runs it in CI.
