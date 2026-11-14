# tau exit codes — the scripting contract

<!-- GENERATED FILE — do not edit by hand.
     Source of truth: the Spec catalog in src/exitcodes.zig.
     Regenerate:  python3 scripts/gen-exit-codes-doc.py
     Drift check: python3 scripts/gen-exit-codes-doc.py --check
     (the exit-codes-doc smoke group runs the drift check) -->

Every process exit status tau can return, what it means, and where a
script reads the detail. These codes are a **stable contract** —
integrations may branch on `$?` / `$LASTEXITCODE`. New codes may be
added; existing ones are never renumbered or renamed.

`name` is the semantic identifier — the same spelling the `ExitCode`
enum and `--help-json`'s `exit_codes` map use. It deliberately differs
from the error catalog's wire `type` tags in [docs/errors.md](errors.md)
(exit `105` is `connection_timeout`; its envelope type is `Timeout`).

## Catalog

| Exit code | `name` | Meaning | Scripting guidance |
|-----------|--------|---------|--------------------|
| `0` | `success` | the command completed — stdout carries the result | no {"err"} envelope is emitted — parse stdout per the command's documented shape (docs/stability.md) |
| `1` | `generic_failure` | a named resource was not found, a check-style command reported failures (`tau doctor`, `tau setup`, `tau config validate`), or a `tau explain` query matched nothing | detail is never on the status alone — read the {"err"} envelope on stderr (type not_found) or the stdout report's "ok":false |
| `80` | `invalid_argument` | an unknown flag, bad flag value, invalid subcommand, or malformed argument was passed | read the {"err"} envelope's message on stderr, fix argv, and retry — `tau explain 80` prints the error entry offline |
| `82` | `missing_required_field` | a required input is missing (e.g. `tau fleet run` without --goal) — bare `tau` with no prompt also exits 82 silently | the stderr envelope's message names the missing input when an envelope is emitted — supply it and retry |
| `105` | `connection_timeout` | an HTTP request to the provider endpoint exceeded --timeout-ms | retry-safe — raise --timeout-ms (default 120000) or check the endpoint/network (TAU_ENDPOINT); the stderr envelope's type tag is Timeout |
| `106` | `auth_failed` | the provider rejected the API key, or no key was found anywhere in the resolution chain | missing-key exits are silent; rejections emit a stderr envelope (type AuthFailed) — provide a key via --api-key, the provider env var, config.json, or TAU_API_KEY |
| `110` | `internal_error` | an HTTP failure, JSON parse error, tool crash, or the --max-iterations tool-loop cap was hit | treat stdout as best-effort — the tool-loop cap exits 110 after emitting the last answer; re-run with --debug and file a bug report |
| `111` | `unimplemented` | the operation is not supported on this platform (e.g. `tau acp` daemon commands and `tau upgrade` are POSIX-only) | permanent for this platform — retrying changes nothing; the stderr envelope's message names the workaround |

Exit statuses outside this table are not part of the contract — an
uncataloged nonzero status still produces a well-formed `{"err"}`
envelope (inheriting the `internal_error` type) when one is emitted,
but only the codes above are guaranteed stable.

## Reading this catalog offline

`tau explain` renders the same registry from the CLI — no network or
API key needed. The `exit.` prefix selects this contract view: a bare
decimal stays an error-catalog lookup (`tau explain 80` prints the
`invalid_argument` error entry), while `tau explain exit.80` prints
the process-status contract:

```sh
tau explain                 # every catalog entry (JSON)
tau explain exit.0          # what exit 0 guarantees on stdout
tau explain exit.80         # the invalid_argument status contract
tau explain exit.auth_failed  # name spellings resolve too
tau explain --human exit.1  # prose instead of JSON
```

The bare `tau explain` catalog lists these entries under `exit_codes`;
`exit.` queries that don't resolve — `exit.42`, `exit.bogus` — exit `1`
with a `not_found` envelope (the `exit.` namespace fails closed rather
than borrowing the error catalog's uncataloged-code fallback).

For envelope-level detail — the `{"err":{code,type,...}}` object a
failure prints on stderr — see the generated error catalog in
[docs/errors.md](errors.md); `tau explain <code>` renders those entries.
For the broader stability policy (what is contract vs. informational),
see [docs/stability.md](stability.md).

## Regenerating

After editing the Spec catalog in `src/exitcodes.zig`:

```sh
python3 scripts/gen-exit-codes-doc.py
```

`--check` regenerates in memory and exits non-zero if this file is
stale; the `exit-codes-doc` smoke group
(`scripts/smoke.sh --group exit-codes-doc`) runs it, `zig build test`
asserts every catalog row and meaning/scripting cell appears here
verbatim, and the `explain-coverage` gate checks every row resolves
via `tau explain exit.<code>`.
