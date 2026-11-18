# tau environment variables

<!-- GENERATED FILE — do not edit by hand.
     Source of truth: the Spec registry in src/envvars.zig.
     Regenerate:  python3 scripts/gen-env-doc.py
     Drift check: python3 scripts/gen-env-doc.py --check
     (the env-doc smoke group runs the drift check) -->

Every `TAU_*` environment variable tau — or its companion tooling —
recognizes, what consumes it, and what it does. Precedence is stable:
**CLI flags > environment > config file > in-code defaults**.

## Typo warnings

At startup tau scans the environment for `TAU_*` names that are not in
this catalog — a misspelled variable is silently ignored by every
consumer otherwise. Unrecognized names emit a
`{"warn":{"message":"..."}}` envelope on stderr (the run continues),
sorted by name; each within two case-insensitive edits of a recognized
name gets a ` — did you mean "<name>"?` hint pointing back here:

```console
$ TAU_ENDPONT=https://example.com tau --version
{"warn":{"message":"environment has unrecognized TAU_* variable (ignored): \"TAU_ENDPONT\" — did you mean \"TAU_ENDPOINT\"? — the recognized set is documented at https://github.com/javimosch/tau/blob/master/docs/env.md"}}
```

Only the exact `TAU_` prefix is scanned — provider keys
(`XIAOMI_API_KEY`, `OPENAI_API_KEY`, `DEEPSEEK_API_KEY`,
`OPENCODE_API_KEY`, `PIZIG_API_KEY`), generic variables (`HOME`,
`NO_COLOR`, `SHELL`, `VISUAL`, `EDITOR`), and proxy/TLS variables are
documented in [docs/configuration.md](configuration.md) and never warn.

Every row below also resolves offline via `tau explain TAU_<VAR>` —
e.g. `tau explain TAU_ENDPOINT` prints the same consumers + summary as
JSON, `--human` renders prose, and a misspelled name gets a
`did you mean` suggestion from this catalog.

## Read by the tau binary

| Variable | Consumed by | Purpose |
|----------|-------------|---------|
| `TAU_API_KEY` | tau | Fallback API key, used after provider-specific env vars and config keys. |
| `TAU_ENDPOINT` | tau | Overrides the provider's endpoint URL (works for chat and `tau acp`). Useful for proxies, gateways, and local OpenAI-compatible servers. |
| `TAU_DEBUG_LOG` | tau | Overrides the `--debug` diagnostic log destination (default `~/.config/tau/debug/<timestamp>.log`). |
| `TAU_EDITOR` | tau | Editor for `tau config edit`, tried before VISUAL and EDITOR (fallback `vi`/`notepad`). May include arguments, e.g. `code --wait`. |
| `TAU_YES` | tau | `1`/`true`/`yes`/`on` enables `tau setup --yes` and `tau upgrade --yes` (approve write steps without prompting). Any other value is off. |
| `TAU_NONINTERACTIVE` | tau | Same truthiness rules as TAU_YES; enables `tau setup --non-interactive` (unattended contract for scripts/CI). |
| `TAU_SETUP_SHELL` | tau | `tau setup` shell override when `--shell` is absent (`bash`, `zsh`, `fish`, `pwsh`, or `all`); invalid values fail with exit 80. |
| `TAU_SETUP_CLIENT` | tau | `tau setup` editor client when `--client` is absent (any `--client` value or `all`); invalid values fail with exit 80. |
| `TAU_SETUP_IMPORT` | tau | Same truthiness rules as TAU_YES; enables `tau setup --import` (merge existing MCP servers into wired clients). |
| `TAU_NO_UPDATE_CHECK` | tau | Any non-empty, non-`0` value disables the update check everywhere — `tau version --check`, `tau upgrade`, and the `tau doctor` update_available warning. |
| `TAU_UPDATE_URL` | tau | Overrides the release lookup URL used by the update check (default: the GitHub latest-release API). Useful for mirrors/proxies and `file://` stubs in tests. |
| `TAU_INSTALL_URL` | tau | Overrides the installer script `tau upgrade` downloads and runs (default: the install.sh shipped at the release tag). Useful for mirrors and `file://` stubs in tests. |
| `TAU_CHANGELOG_URL` | tau | Overrides the changelog `tau upgrade` fetches for its pre-upgrade summary (default: the CHANGELOG.md shipped at the release tag). A fetch miss drops the summary, never the upgrade. |
| `TAU_INSTALL_DIR` | tau upgrade · install.sh · install.ps1 | Install destination when `tau upgrade --dir` is absent (default: the running binary's own directory, else the installer's `~/.local/bin`). Also honored by the installers. |
| `TAU_VERIFY_SIGSTORE` | tau upgrade · install.sh | Opt-in cosign/Sigstore verification of the downloaded binary before swap (requires cosign on PATH). Truthiness follows TAU_YES. |

## Read by the installers

| Variable | Consumed by | Purpose |
|----------|-------------|---------|
| `TAU_VERSION` | install.sh · install.ps1 | Pins the version to install (default: the latest release). Same role as `--version`/`-Version`. |
| `TAU_BASE_URL` | install.sh · install.ps1 | Overrides the release-download base URL. `file://` mirrors are supported for air-gapped installs. |
| `TAU_OS` | install.sh | Overrides platform detection — the raw `uname` value (`linux` or `darwin`). |
| `TAU_ARCH` | install.sh · install.ps1 | Overrides architecture detection — the raw `uname -m` value (e.g. `x86_64`, `arm64`, `aarch64`). |
| `TAU_SKIP_CHECKSUM` | install.sh · install.ps1 | Skips SHA256 verification of the downloaded archive — weakens the fail-closed default; prefer TAU_VERIFY_SIGSTORE. |

## Read by companion tooling

| Variable | Consumed by | Purpose |
|----------|-------------|---------|
| `TAU_BIN` | a2a-spawn · scripts/smoke.sh | Path to the tau binary, skipping PATH resolution. |
| `TAU_TOOLS` | a2a-spawn | Translated to `--tools` when launching tau (e.g. `TAU_TOOLS="bash,read"`). tau itself ignores it. |
| `TAU_THINKING` | a2a-spawn | `1` adds `--thinking` when launching tau. tau itself ignores it. |
| `TAU_DEBUG` | a2a-spawn | `1` adds `--debug` when launching tau. tau itself ignores it. |

Variables under "companion tooling" are documented surface — external
launchers translate them into CLI flags — so they never trigger the
typo warning even though `tau` itself ignores them.

## Regenerating

After editing the Spec registry in `src/envvars.zig`:

```sh
python3 scripts/gen-env-doc.py
```

`--check` regenerates in memory and exits non-zero if this file is
stale; the `env-doc` smoke group (`scripts/smoke.sh --group env-doc`)
runs it, and `zig build test` asserts every registry row and summary
appears here verbatim.
