# `tau doctor --json` output reference

<!-- GENERATED FILE — do not edit by hand.
     Source of truth: schema/tau-doctor.schema.json (validated against
     real `tau doctor --json` output by scripts/check-doctor-schema.py).
     Regenerate:  python3 scripts/gen-doctor-doc.py
     Drift check: python3 scripts/gen-doctor-doc.py --check
     (the doctor-schema smoke group runs both checks) -->

Schema for one line of `tau doctor --json` output. With --json, doctor streams newline-delimited JSON: one check_event per diagnostic as it finishes, fix_event records interleaved when --fix runs, and exactly one terminal verdict_event (always the last line, always "done":true). The three event types are mutually exclusive — validate each NDJSON line against this schema individually. The single-object report printed without --json shares the check, fix, summary, and build object shapes below.

## Stream contract

- One JSON object per line (NDJSON), UTF-8, on stdout.
- `done:false` on every non-terminal line; the last line is always the
  verdict with `done:true`. A truncated stream is detectable by the
  missing verdict.
- The process exit code is unchanged by `--json`: 0 when `ok:true`,
  1 when `ok:false` — a consumer can wait for the verdict or just check
  the exit status.
- `--json` is mutually exclusive with `--report` (Markdown bundle).
  Without `--json`, doctor prints a single JSON report that reuses the
  [check](#check), [fix](#fix), [summary](#summary), and
  [build](#build) object shapes below.

## Event types

### check_event

One diagnostic check result, emitted as the check finishes. Order is fixed by the check pipeline; every check appears exactly once per diagnosis pass (checks re-diagnosed after an applied --fix emit a second event with the post-fix outcome).

| Field | Type | Values | Description |
|-------|------|--------|-------------|
| `check` | [`check`](#check) | — | See [check](#check). |
| `done` | const `false` | always `false` | Stream-continuation marker — false on every non-terminal event. |

### fix_event

One remediation outcome, emitted only under `--fix` as each planned fix is approved, declined, skipped, or applied. Fix events appear between the first-pass check events and the verdict.

| Field | Type | Values | Description |
|-------|------|--------|-------------|
| `fix` | [`fix`](#fix) | — | See [fix](#fix). |
| `done` | const `false` | always `false` | Stream-continuation marker — false on every non-terminal event. |

### verdict_event

Terminal verdict — always the last NDJSON line, always "done":true. Carries the whole-run outcome so a consumer reading only the last line gets the full verdict; the process exit code mirrors ok (0 when true, 1 when false).

| Field | Type | Values | Description |
|-------|------|--------|-------------|
| `ok` | `boolean` | — | true when no check ended in fail status (warn/skip still count as passing). |
| `version` | `string` | — | tau version that produced the report, e.g. "0.4.0". |
| `build` | [`build`](#build) | — | See [build](#build). |
| `summary` | [`summary`](#summary) | — | See [summary](#summary). |
| `fixes` (optional) | [`fix`](#fix)[] | — | Present only when --fix ran — every remediation outcome in decision order. |
| `done` | const `true` | always `true` | End-of-stream marker — true on the verdict line only. |

## Objects

### check

A single diagnostic outcome — the same object shape the single-object report carries in its "checks" array.

| Field | Type | Values | Description |
|-------|------|--------|-------------|
| `name` | `string` | non-empty | Stable machine name of the check, e.g. "config_file", "api_key", "endpoint_reachable". |
| `status` | `string` | one of `ok` \| `warn` \| `fail` \| `skip` | Outcome of the check. warn counts toward ok:true; fail flips the verdict and the exit code to 1; skip means the check did not run (offline mode, missing prerequisite, or platform gating). |
| `message` | `string` | — | Human-readable result — what was found, never secret material. |
| `hint` (optional) | `string` | — | Optional remediation hint shown on non-ok outcomes. |

### fix

A remediation outcome — the same object shape the report and verdict carry in their "fixes" arrays.

| Field | Type | Values | Description |
|-------|------|--------|-------------|
| `id` | `string` | non-empty | Stable machine name of the remediation, e.g. "scaffold_config", "chmod_config", "install_completions". |
| `check` | `string` | non-empty | Name of the check whose outcome triggered this fix. |
| `status` | `string` | one of `applied` \| `declined` \| `skipped` \| `failed` | What happened to the remediation. declined: the user answered no at the confirmation prompt; skipped: no approval channel (non-interactive run without --yes); failed: the fix was attempted and errored. |
| `detail` | `string` | — | Human-readable detail — what was done or why nothing was. |

### summary

Per-status tally over every check in the run.

| Field | Type | Values | Description |
|-------|------|--------|-------------|
| `ok` | `integer` | `>= 0` | Checks that passed. |
| `warn` | `integer` | `>= 0` | Checks that passed with a warning. |
| `fail` | `integer` | `>= 0` | Checks that failed — nonzero here forces ok:false and exit 1. |
| `skip` | `integer` | `>= 0` | Checks that did not run. |

### build

Build metadata identifying the exact binary — the same object `tau version --verbose` emits.

| Field | Type | Values | Description |
|-------|------|--------|-------------|
| `commit` | `string` | — | Short git hash of HEAD at build time ("unknown" for tarball builds, "-dirty" suffix for uncommitted changes). |
| `target` | `string` | — | arch-os-abi target triple, e.g. "x86_64-linux-gnu". |
| `build_date` | `string` | — | UTC build stamp YYYY-MM-DDTHH:MM:SSZ (SOURCE_DATE_EPOCH honored for reproducible builds). |
| `zig` | `string` | — | Zig compiler version that produced the binary, e.g. "0.16.0". |

## Example stream

A `--fix --yes` run emits all three event types (check events, fix
events, then the verdict carrying the fixes array):

```json
{"check":{"name":"api_key","status":"fail","message":"no API key resolved","hint":"set XIAOMI_API_KEY or add keys.<provider> to config.json"},"done":false}
{"fix":{"id":"scaffold_config","check":"config_file","status":"applied","detail":"wrote starter config to ~/.config/tau/config.json"},"done":false}
{"ok":false,"version":"0.4.0","build":{"commit":"abc1234","target":"x86_64-linux-gnu","build_date":"2026-10-27T12:00:00Z","zig":"0.16.0"},"summary":{"ok":5,"warn":1,"fail":1,"skip":3},"fixes":[{"id":"scaffold_config","check":"config_file","status":"applied","detail":"wrote starter config to ~/.config/tau/config.json"}],"done":true}
```

## Consuming and validating

- Canonical schema copy:
  [schema/tau-doctor.schema.json](../schema/tau-doctor.schema.json)
  (stable raw URL for `$schema` references).
- `scripts/check-doctor-schema.py` validates a captured stream against
  it — including the stream invariants a per-line schema cannot express
  (exactly one terminal `done:true` verdict, all prior lines `done:false`):

  ```sh
  tau doctor --json --offline | python3 scripts/check-doctor-schema.py -
  ```

## Regenerating

After changing the event shapes in `src/doctor.zig` or the schema:

```sh
python3 scripts/gen-doctor-doc.py
```

`--check` regenerates in memory and exits non-zero when this file is
stale; the `doctor-schema` smoke group
(`scripts/smoke.sh --group doctor-schema`) runs it, and `zig build test`
pins the schema's object shapes to the serialized structs.
