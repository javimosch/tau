# tau error catalog

<!-- GENERATED FILE — do not edit by hand.
     Source of truth: the Spec catalog in src/errors.zig.
     Regenerate:  python3 scripts/gen-errors-doc.py
     Drift check: python3 scripts/gen-errors-doc.py --check
     (the errors-doc smoke group runs the drift check) -->

Every `{"err":{...}}` envelope tau can emit, what triggers it, and how to
fix it. `code` doubles as the process exit code; `code` and `type` are a
**stable contract** — integrations may switch on them. New codes may be
added; existing ones are never renumbered or renamed.

## Envelope shape

Failures are reported on **stderr** as a single-line JSON envelope — even
in `--mode text` (fleet subcommands are the exception: they report on
stdout):

```json
{"err":{"code":106,"type":"AuthFailed","message":"no API key for provider 'openai'","recoverable":false,"hint":"provide an API key via --api-key, the provider env var, config.json, or TAU_API_KEY","docs":"https://github.com/javimosch/tau/blob/master/docs/providers.md","explain":"tau explain 106","catalog":"https://github.com/javimosch/tau/blob/master/docs/errors.md"}}
```

| Field | Meaning |
|-------|---------|
| `code` | Stable exit code — also the process exit status. Branch on this first. |
| `type` | Stable wire tag for the error class. Emitters may override it with the underlying Zig error name (e.g. `HTTPRequestFailed`) while keeping `code` stable — branch on `code`, use `type` for detail. |
| `message` | Human-readable detail; usually names the exact fix. |
| `recoverable` | `true` when retrying the same call may succeed. |
| `hint` | Canned remediation for the error class; dynamic failures override it with a more specific fix. |
| `docs` | Guide link for that error class (see the table below). |
| `debug_log` | Present only when `--debug` opened a diagnostic log — attach it to bug reports. |
| `explain` | Ready-to-run `tau explain <code>` command — prints this entry's cause and fix offline. Always the penultimate field; agents can exec it verbatim. |
| `catalog` | Link back to this catalog. Always the last field — `explain`/`catalog` together form the envelope footer. |

## Catalog

| Exit code | `type` | Recoverable | Cause | Remediation `hint` | Guide |
|-----------|--------|-------------|-------|--------------------|-------|
| `1` | `not_found` | `false` | a named resource is missing — the message identifies the file, skill, or session | the message names what was not found — check the name/path and retry | [troubleshooting.md](https://github.com/javimosch/tau/blob/master/docs/troubleshooting.md) |
| `80` | `invalid_argument` | `false` | an unknown flag, bad flag value, invalid subcommand, or malformed argument was passed | run `tau --help` (or `tau --help-json`) for the valid flags and values | [troubleshooting.md](https://github.com/javimosch/tau/blob/master/docs/troubleshooting.md) |
| `82` | `missing_required_field` | `false` | a required input is missing (e.g. `tau fleet run` without --goal, `tau skills load` without a name) | the message names the missing input — supply it and retry | [troubleshooting.md](https://github.com/javimosch/tau/blob/master/docs/troubleshooting.md) |
| `105` | `Timeout` | `false` | an HTTP request to the provider endpoint exceeded --timeout-ms | raise --timeout-ms (default 120000) or check the endpoint/network (TAU_ENDPOINT) | [troubleshooting.md](https://github.com/javimosch/tau/blob/master/docs/troubleshooting.md) |
| `106` | `AuthFailed` | `false` | the provider rejected the API key, or no key was found anywhere in the resolution chain | provide an API key via --api-key, the provider env var, config.json, or TAU_API_KEY | [providers.md](https://github.com/javimosch/tau/blob/master/docs/providers.md) |
| `110` | `internal_error` | `false` | an HTTP failure, JSON parse error, tool crash, or the --max-iterations cap was hit | re-run with --debug to write a diagnostic log, then file a bug report | [troubleshooting.md](https://github.com/javimosch/tau/blob/master/docs/troubleshooting.md) |
| `111` | `unimplemented` | `false` | the operation is not supported on this platform (e.g. `tau acp` daemon commands are POSIX-only) | not supported on this platform — the message names the workaround | [troubleshooting.md](https://github.com/javimosch/tau/blob/master/docs/troubleshooting.md) |

Exit codes outside this table still produce a well-formed envelope: they
inherit the `internal_error` type and hint while keeping their own `code`.

Non-fatal problems use a separate `{"warn":{"message":"..."}}` envelope
and the run continues.

## Reading this catalog offline

`tau explain` renders the same registry from the CLI — no network or
API key needed:

```sh
tau explain              # every catalog entry (JSON)
tau explain 106          # one entry by exit code
tau explain AuthFailed   # one entry by `type` tag
tau explain --human 80   # prose instead of JSON
```

Numeric codes outside the table still resolve to the generic
`internal_error` entry (code preserved), mirroring the envelope rule
above; `0` and unrecognized names exit `1` with a `not_found` envelope.

## Silent exit paths

Not every failure prints an envelope. These paths exit with a bare status
and no `{"err":...}` line:

| Exit code | When |
|-----------|------|
| `82` | `tau` ran with no prompt and no active goal — nothing to do. |
| `106` | No API key resolved for the provider (checked before the request). |
| `110` | The `--max-iterations` tool-loop cap was hit mid-turn — partial output may already be on stdout. |

Exit `0` means success and is never an error.

## Regenerating

After editing the Spec catalog in `src/errors.zig`:

```sh
python3 scripts/gen-errors-doc.py
```

`--check` regenerates in memory and exits non-zero if this file is stale;
the `errors-doc` smoke group (`scripts/smoke.sh --group errors-doc`) runs
it, and `zig build test` asserts every catalog row and hint appears here
verbatim.
