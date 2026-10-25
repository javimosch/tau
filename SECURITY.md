# Security Policy & Trust Guide

How to report vulnerabilities, verify that the `tau` binary you run is the
binary this repository built, and how tau handles credentials and data at
runtime.

## Reporting a Vulnerability

Please report suspected vulnerabilities **privately** through the repository's
GitHub Security tab (`Security` → `Report a vulnerability`):

<https://github.com/javimosch/tau/security/advisories/new>

Do **not** open a public issue for sensitive reports (credential leaks,
escapes from the tool-execution model, request/response tampering).

Include in your report:

- tau version (`tau --version`) and OS/platform
- A minimal reproduction command or scenario
- What data or privilege boundary you believe is crossed
- Relevant output — **redact your own API keys before attaching logs or
  `--debug` output** (see [Secret & data handling](#secret--data-handling);
  `--debug` writes verbatim tool results and raw API responses to stderr)

For non-sensitive bugs and hardening suggestions, a regular
[GitHub issue](https://github.com/javimosch/tau/issues) is fine.

## Supported Versions

Security fixes are applied to the latest release line only.

| Version | Supported |
|---------|-----------|
| 0.4.x   | ✅        |
| < 0.4   | ❌        |

## Verifying Your Install

Trust should be anchored to this repository — `github.com/javimosch/tau` —
and its `v*` git tags, never to a re-uploaded binary elsewhere. Pick the
strongest level your release supports; each layer is independent.

### Level 0 — build from source (strongest)

The most auditable install is the one you build yourself from a tagged
commit:

```bash
git clone https://github.com/javimosch/tau.git
cd tau
git checkout v0.4.0        # or the tag you intend to run
git rev-parse v0.4.0^{commit}   # confirm the tag ↔ commit correspondence
zig build                  # requires Zig 0.16.0 — see build.zig
# Binary: zig-out/bin/tau
```

The toolchain version is pinned (`Zig 0.16.0`), the dependency surface is
minimal (`curl` on PATH is the only runtime requirement), and there is no
build-time download step — what you audit is what you run.

### Level 1 — checksum

For every prebuilt asset, GitHub records a SHA-256 digest at upload time.
Compare the recorded digest with a locally computed one:

```bash
# What GitHub recorded for the release asset:
gh release view v0.4.0 --repo javimosch/tau \
  --json assets -q '.assets[] | .name + "  " + .digest'
# → tau  sha256:6c2329da…

# What you actually downloaded:
sha256sum ./tau
```

The two values must match exactly. If a release also ships a
`SHA256SUMS.txt` manifest listing its archives, verify directly against it:

```bash
grep ' <asset-name>$' SHA256SUMS.txt | sha256sum -c -
```

Do not run a binary whose digest you cannot confirm, and do not bypass a
failed checksum — a mismatch means corrupted or tampered bytes.

### Level 2 — signature and provenance (when present)

Releases that ship `<asset>.sigstore.json` bundles carry **keyless** cosign
signatures: the release job mints a short-lived Fulcio certificate from its
GitHub OIDC identity and records every signature in the Rekor transparency
log. Verify such an asset with:

```bash
cosign verify-blob \
  --bundle <asset>.sigstore.json \
  --certificate-identity-regexp '^https://github\.com/javimosch/tau/\.github/workflows/release\.yml@refs/tags/v' \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
  <asset>
```

The identity regexp pins the signature to *this* repo's release workflow on a
`v*` tag — do not widen or omit it. Releases carrying SLSA build-provenance
attestations can be checked against the repo's attestation store:

```bash
gh attestation verify <asset> --repo javimosch/tau
```

If a release predates signing (no bundles, no attestations — as with
`v0.4.0`), fall back to Level 1, or build from source.

## Provenance & Supply Chain

- **Source of truth:** releases are published at
  `github.com/javimosch/tau/releases` from `v*` git tags. Every tag maps to a
  commit in this repository's public history — audit `git log v0.4.0` before
  trusting a binary, or reproduce it with `zig build` (Level 0).
- **No update channel:** tau never phones home, self-updates, or downloads
  code at runtime. The only outbound connection it makes is the HTTPS POST to
  your configured chat-completions endpoint (via `curl` on PATH) — there is
  no telemetry, analytics, or crash reporting.
- **Runtime deps:** `curl` on PATH. Nothing else is downloaded or executed
  implicitly; completions and skills are static files you opt into loading.

## Secret & Data Handling

### Threat model

- **tau runs with your privileges.** There is no sandbox around tool
  execution: a `bash` or `write` tool call runs as the invoking user and can
  touch anything that user can.
- **The model drives tools by default.** Unless you pass `--no-tools`, a
  `--tools` allowlist, or `--exclude-tools`, the LLM decides which tools run
  and with what arguments. Content the model reads (files, command output)
  can prompt-inject it — treat tool calls as untrusted.
- **Everything tools touch can leave the machine.** Tool results are appended
  to the conversation and sent to the provider on the next request.

### Credential handling

API-key resolution order (`src/config.zig`, `resolveApiKey`):

1. `--api-key <key>` flag
2. Config file `keys[<provider>]`
3. Provider env var(s) — e.g. `OPENAI_API_KEY`, `XIAOMI_API_KEY`/`PIZIG_API_KEY`
4. Config file global `api_key`
5. `TAU_API_KEY`
6. Provider `builtin_key` (no shipped provider sets one)

The resolved key is used for exactly one thing: the `Authorization: Bearer`
header on provider requests. Hardening recommendations:

- **Prefer env vars over the config file.** Keys in
  `~/.config/tau/config.json` are stored in plaintext — if you use it,
  `chmod 600` it and never commit it.
- **Avoid `--api-key` on the command line** — it lands in shell history and
  the process list.
- **curl argv exposure:** tau delegates HTTP to a `curl` subprocess whose
  command line carries `-H "Authorization: Bearer <key>"` and
  `--data-raw <request body>`. Process arguments are visible to other local
  users via `ps`/`/proc` for the duration of the request — treat tau as a
  single-user tool on shared machines.
- **Environment inheritance:** tool subprocesses (including `bash` commands
  the model runs) inherit tau's environment, so provider API keys are
  readable by any command the model executes — and that command's output goes
  back to the provider. This is the largest realistic leak path. Mitigate
  with `--tools` allowlists that exclude `bash`, or inject keys
  per-invocation rather than exporting them globally.
- **`TAU_ENDPOINT` is trusted verbatim.** It overrides the POST URL for all
  provider traffic. A plain-`http://` endpoint sends prompts, tool results,
  and your API key in cleartext — only point it at endpoints you trust.

### What is stored locally

All state lives under `~/.config/tau/`:

| Path | Contents |
|------|----------|
| `config.json` | Provider/model/mode defaults; may contain `api_key`/`keys` in plaintext |
| `sessions/<name>.json` | Full conversation history including tool results, plus goal state |
| `fleets/<id>.json` | Fleet goal, work breakdown, per-item status |
| `acp.sock`, `acp.pid`, `acp.log` | ACP daemon socket, pid file, and daemon stdout/stderr |

Session and fleet files contain whatever the model saw — including file
contents and command output from tool calls — and files are created with
process-default (umask) permissions. tau never expires or scrubs them: delete
sessions you no longer need, and treat the directory as sensitive.

Session names and fleet ids are validated before becoming paths
(`[a-zA-Z0-9._-]` only, `.`/`..` rejected), so a hostile name cannot write
outside these directories.

### `--debug` is verbatim

`--debug` writes `[DEBUG]` lines — tool arguments, tool results, and raw API
responses — to **stderr, unredacted**. Do not pipe `--debug` output into bug
reports, CI logs, or shared terminals without scrubbing it first.

### Constraining tool access

| Flag | Effect |
|------|--------|
| `-t, --tools <csv>` | Allowlist — only the named tools may run |
| `-xt, --exclude-tools <csv>` | Denylist — named tools removed from the set |
| `-nt, --no-tools` | Disable all tools |
| `--dry-run` | Plan tool calls, execute none |
| `--max-iterations <n>` | Cap the tool-call loop |

For untrusted content (web pages, foreign repos, pasted logs), prefer
`--no-tools` or an allowlist that excludes `bash`.

## Security-Relevant Code Map

Particularly security-sensitive areas in this codebase:

- **Credential handling** — API-key resolution, config-file storage, and the
  `Authorization: Bearer` header construction (`src/config.zig`,
  `src/llm/provider.zig`, `src/configfile.zig`).
- **Tool execution** — model-invoked `bash`, `read`, `write`, `edit`, `ls`,
  `grep`, `find` and their input validation (`src/tools/`, `src/agent.zig`).
- **Session/fleet persistence** — path validation for user-controlled names
  written under `~/.config/tau/` (`src/session.zig`, `src/fleet.zig`).
- **ACP server** — the JSON-RPC surface and socket/pid handling
  (`src/acp.zig`).
- **JSON parsing** — hand-rolled escape/unescape applied to model and tool
  output (`src/json.zig`).
