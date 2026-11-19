# `tau doctor` check catalog

<!-- GENERATED FILE — do not edit by hand.
     Source of truth: the CheckSpec catalog in src/doctorcatalog.zig —
     the same registry `tau explain doctor.<check>` reads; the compact
     form of this catalog is the generated check table in
     docs/troubleshooting.md.
     Regenerate:  python3 scripts/gen-doctor-checks-doc.py
     Drift check: python3 scripts/gen-doctor-checks-doc.py --check
     (the doctor-checks smoke group runs the drift check) -->

`tau doctor` diagnoses a tau install end to end — config file health,
credential resolution, network reachability, shell completions, and
editor-client wiring — and prints one JSON report on stdout: exit 0
when nothing failed, 1 otherwise. Each diagnostic lands as a named
check row; under `--json` every row streams as a `check_event` (the
stream contract is [doctor-json.md](doctor-json.md)).

This page catalogs every check id the report can emit — the symptom
(a non-`ok` row), what causes it, the remediation, and the
`tau explain` query that prints the same entry offline:
`tau explain doctor.<id>` (`--list` indexes every resolvable topic,
`--search <text>` filters it full-text). `client_<name>` rows appear
once per detected editor client; `probe_<provider>` and
`probe_<provider>_auth` rows run under `tau doctor --probe` — or
individually under `tau doctor --check <id>`). A `skip` status means
the check's own gate — `--offline`, missing curl, no detected client,
`--deep`/`--probe`/`--selftest` not passed — kept it from running,
not that it passed or failed.

Bare `tau doctor --fix` remediates every fixable check behind
per-fix confirmation; `tau doctor --fix <check-id>` scopes the
remediation to the single named check. `tau doctor --check <check-id>`
reruns one named check — the report carries just that row and the
verdict/exit code reflects it, the fast verify loop after a fix.
Naming a check implies its opt-in gate (a probe row runs without
`--probe`, `auth_probe` without `--deep`, `selftest` without
`--selftest`); `--offline` still skips the network rows. Check ids
are the catalog below — the `doctor.<id>` spelling resolves too.

## Checks

### `config_file`

- **Symptom:** the `config_file` row reports a non-`ok` status (`warn` or `fail`) in the `tau doctor` report — one `check_event` line under `--json`.
- **Cause:** ~/.config/tau/config.json doesn't parse (fail), or names an unregistered provider (warn) — a missing file is ok, config is optional
- **Fix:** fix the JSON with `tau config edit` or pinpoint it with `tau config validate` (path:line:col plus the offending source line with a caret); `tau doctor --fix` moves a broken config to config.json.bak and writes a starter
- **Explain:** `tau explain doctor.config_file`

### `config_deprecated_keys`

- **Symptom:** the `config_deprecated_keys` row reports a non-`ok` status (`warn` or `fail`) in the `tau doctor` report — one `check_event` line under `--json`.
- **Cause:** the config file still uses a deprecated or renamed key spelling (e.g. compact_keep_recent) — old spellings still load with a warn envelope during the deprecation window but are scheduled for removal (skipped when there is no config file or it doesn't parse)
- **Fix:** run `tau doctor --fix` to rewrite the deprecated spellings in place — `tau config validate` prints the exact line/column and the canonical key name
- **Explain:** `tau explain doctor.config_deprecated_keys`

### `config_permissions`

- **Symptom:** the `config_permissions` row reports a non-`ok` status (`warn` or `fail`) in the `tau doctor` report — one `check_event` line under `--json`.
- **Cause:** the config dir or config.json grants group/other read access (POSIX only — the file can hold API keys)
- **Fix:** run `tau doctor --fix` (chmod 0700 on ~/.config/tau, 0600 on config.json) or chmod them yourself
- **Explain:** `tau explain doctor.config_permissions`

### `plaintext_secrets`

- **Symptom:** the `plaintext_secrets` row reports a non-`ok` status (`warn` or `fail`) in the `tau doctor` report — one `check_event` line under `--json`.
- **Cause:** credentials sit on disk as plaintext — api_key/keys.* values in the config file, or `env` blocks inside client settings files (warn only; reports key names and counts, never values)
- **Fix:** move keys to environment variables — `tau config unset api_key` or `tau config unset keys.<provider>` — the provider env var still resolves; not auto-fixable
- **Explain:** `tau explain doctor.plaintext_secrets`

### `shell_completions`

- **Symptom:** the `shell_completions` row reports a non-`ok` status (`warn` or `fail`) in the `tau doctor` report — one `check_event` line under `--json`.
- **Cause:** completion scripts are missing or stale for the detected shells
- **Fix:** run `tau doctor --fix` or `tau setup --yes` to (re)install them
- **Explain:** `tau explain doctor.shell_completions`

### `provider_resolution`

- **Symptom:** the `provider_resolution` row reports a non-`ok` status (`warn` or `fail`) in the `tau doctor` report — one `check_event` line under `--json`.
- **Cause:** the configured or --provider provider isn't registered
- **Fix:** pick a registered provider — `tau models` lists them; `tau config set provider <name>` persists it
- **Explain:** `tau explain doctor.provider_resolution`

### `api_key`

- **Symptom:** the `api_key` row reports a non-`ok` status (`warn` or `fail`) in the `tau doctor` report — one `check_event` line under `--json`.
- **Cause:** no API key resolves at any level of the precedence chain
- **Fix:** pass --api-key, set the provider env var or TAU_API_KEY, or add api_key/keys.<provider> to config.json — `tau init` scaffolds a starter
- **Explain:** `tau explain doctor.api_key`

### `curl`

- **Symptom:** the `curl` row reports a non-`ok` status (`warn` or `fail`) in the `tau doctor` report — one `check_event` line under `--json`.
- **Cause:** curl is missing or `curl --version` fails — every LLM request goes through curl
- **Fix:** install curl via your package manager and re-run `tau doctor`
- **Explain:** `tau explain doctor.curl`

### `proxy_env`

- **Symptom:** the `proxy_env` row reports a non-`ok` status (`warn` or `fail`) in the `tau doctor` report — one `check_event` line under `--json`.
- **Cause:** a *_proxy/*_PROXY variable looks wrong for the resolved endpoint — unparseable URL, credentials embedded in the URL (always redacted in output), HTTP_PROXY alone for an HTTPS endpoint (silent no-op), or NO_PROXY covering the endpoint host (warn only; runs under --offline)
- **Fix:** export HTTPS_PROXY for https:// endpoints, drop credentials from the proxy URL, and make sure NO_PROXY doesn't cover the provider host — see "Behind a corporate proxy" below
- **Explain:** `tau explain doctor.proxy_env`

### `tls_ca`

- **Symptom:** the `tls_ca` row reports a non-`ok` status (`warn` or `fail`) in the `tau doctor` report — one `check_event` line under `--json`.
- **Cause:** CURL_CA_BUNDLE/SSL_CERT_FILE points at a missing or non-file path, or an SSL_CERT_DIR entry is missing (fail — every HTTPS request would error); a configured proxy with no custom CA bundle warns — the corporate TLS-intercept case (runs under --offline)
- **Fix:** set CURL_CA_BUNDLE (or SSL_CERT_FILE/SSL_CERT_DIR) to your organization's PEM bundle, or fix/remove the missing path
- **Explain:** `tau explain doctor.tls_ca`

### `endpoint_reachable`

- **Symptom:** the `endpoint_reachable` row reports a non-`ok` status (`warn` or `fail`) in the `tau doctor` report — one `check_event` line under `--json`.
- **Cause:** the provider endpoint doesn't answer within the probe timeout (skipped under --offline or without curl)
- **Fix:** check the network, DNS, and the proxy_env/tls_ca rows — TAU_ENDPOINT overrides the endpoint
- **Explain:** `tau explain doctor.endpoint_reachable`

### `auth_probe`

- **Symptom:** the `auth_probe` row reports a non-`ok` status (`warn` or `fail`) in the `tau doctor` report — one `check_event` line under `--json`.
- **Cause:** a one-token authenticated completion fails — the resolved key is rejected (--deep only; skipped under --offline, without curl, or with no key resolved)
- **Fix:** re-issue or rotate the key — the check names which source it resolved from (env var, config, or TAU_API_KEY)
- **Explain:** `tau explain doctor.auth_probe`

### `client_wiring`

- **Symptom:** the `client_wiring` row reports a non-`ok` status (`warn` or `fail`) in the `tau doctor` report — one `check_event` line under `--json`.
- **Cause:** placeholder row — HOME is unset or no editor config dir was detected, so no per-client rows ran
- **Fix:** install the editor you want wired, then run `tau setup --client <name>`
- **Explain:** `tau explain doctor.client_wiring`

### `client_permissions`

- **Symptom:** the `client_permissions` row reports a non-`ok` status (`warn` or `fail`) in the `tau doctor` report — one `check_event` line under `--json`.
- **Cause:** a detected client settings file (or the mcacp bridge config) grants group/other access — `env` blocks inside it can hold API keys (POSIX only)
- **Fix:** run `tau doctor --fix` (chmod 0600 on every detected client settings file and mcacp.json) or chmod them yourself
- **Explain:** `tau explain doctor.client_permissions`

### `provider_probes`

- **Symptom:** the `provider_probes` row reports a non-`ok` status (`warn` or `fail`) in the `tau doctor` report — one `check_event` line under `--json`.
- **Cause:** placeholder row for the opt-in sweep — skipped unless --probe is passed
- **Fix:** run `tau doctor --probe` to live-verify connectivity and credentials for every registered provider
- **Explain:** `tau explain doctor.provider_probes`

### `update_available`

- **Symptom:** the `update_available` row reports a non-`ok` status (`warn` or `fail`) in the `tau doctor` report — one `check_event` line under `--json`.
- **Cause:** a newer release exists upstream (warn only; skipped under --offline, TAU_NO_UPDATE_CHECK=1, or without curl)
- **Fix:** run `tau upgrade` — TAU_NO_UPDATE_CHECK=1 silences the row
- **Explain:** `tau explain doctor.update_available`

### `selftest`

- **Symptom:** the `selftest` row reports a non-`ok` status (`warn` or `fail`) in the `tau doctor` report — one `check_event` line under `--json`.
- **Cause:** the credential-free end-to-end run against a loopback stub provider fails (--selftest only) — the installed binary can't complete a session
- **Fix:** re-run `tau doctor --selftest --debug` and attach the redacted log to `tau bug`
- **Explain:** `tau explain doctor.selftest`

### `client_zed`

- **Symptom:** the `client_zed` row reports a non-`ok` status (`warn` or `fail`) in the `tau doctor` report — one `check_event` line under `--json`.
- **Cause:** tau isn't wired into that client's settings, or the wiring is stale — a dead `command` path or wrong `args` counts as stale; the row is absent entirely when the client isn't installed
- **Fix:** run `tau setup --client zed` to wire or refresh it — `tau doctor --fix` auto-fixes the bridge/ACP clients and writes a paste-ready snippet for the manual ones; guide: docs/clients/zed.md
- **Explain:** `tau explain doctor.client_zed`

### `client_nvim`

- **Symptom:** the `client_nvim` row reports a non-`ok` status (`warn` or `fail`) in the `tau doctor` report — one `check_event` line under `--json`.
- **Cause:** tau isn't wired into that client's settings, or the wiring is stale — a dead `command` path or wrong `args` counts as stale; the row is absent entirely when the client isn't installed
- **Fix:** run `tau setup --client nvim` to wire or refresh it — `tau doctor --fix` auto-fixes the bridge/ACP clients and writes a paste-ready snippet for the manual ones; guide: docs/clients/nvim.md
- **Explain:** `tau explain doctor.client_nvim`

### `client_emacs`

- **Symptom:** the `client_emacs` row reports a non-`ok` status (`warn` or `fail`) in the `tau doctor` report — one `check_event` line under `--json`.
- **Cause:** tau isn't wired into that client's settings, or the wiring is stale — a dead `command` path or wrong `args` counts as stale; the row is absent entirely when the client isn't installed
- **Fix:** run `tau setup --client emacs` to wire or refresh it — `tau doctor --fix` auto-fixes the bridge/ACP clients and writes a paste-ready snippet for the manual ones; guide: docs/clients/emacs.md
- **Explain:** `tau explain doctor.client_emacs`

### `client_vscode`

- **Symptom:** the `client_vscode` row reports a non-`ok` status (`warn` or `fail`) in the `tau doctor` report — one `check_event` line under `--json`.
- **Cause:** tau isn't wired into that client's settings, or the wiring is stale — a dead `command` path or wrong `args` counts as stale; the row is absent entirely when the client isn't installed
- **Fix:** run `tau setup --client vscode` to wire or refresh it — `tau doctor --fix` auto-fixes the bridge/ACP clients and writes a paste-ready snippet for the manual ones; guide: docs/clients/vscode.md
- **Explain:** `tau explain doctor.client_vscode`

### `client_cursor`

- **Symptom:** the `client_cursor` row reports a non-`ok` status (`warn` or `fail`) in the `tau doctor` report — one `check_event` line under `--json`.
- **Cause:** tau isn't wired into that client's settings, or the wiring is stale — a dead `command` path or wrong `args` counts as stale; the row is absent entirely when the client isn't installed
- **Fix:** run `tau setup --client cursor` to wire or refresh it — `tau doctor --fix` auto-fixes the bridge/ACP clients and writes a paste-ready snippet for the manual ones; guide: docs/clients/cursor.md
- **Explain:** `tau explain doctor.client_cursor`

### `client_jetbrains`

- **Symptom:** the `client_jetbrains` row reports a non-`ok` status (`warn` or `fail`) in the `tau doctor` report — one `check_event` line under `--json`.
- **Cause:** tau isn't wired into that client's settings, or the wiring is stale — a dead `command` path or wrong `args` counts as stale; the row is absent entirely when the client isn't installed
- **Fix:** run `tau setup --client jetbrains` to wire or refresh it — `tau doctor --fix` auto-fixes the bridge/ACP clients and writes a paste-ready snippet for the manual ones; guide: docs/clients/jetbrains.md
- **Explain:** `tau explain doctor.client_jetbrains`

### `client_windsurf`

- **Symptom:** the `client_windsurf` row reports a non-`ok` status (`warn` or `fail`) in the `tau doctor` report — one `check_event` line under `--json`.
- **Cause:** tau isn't wired into that client's settings, or the wiring is stale — a dead `command` path or wrong `args` counts as stale; the row is absent entirely when the client isn't installed
- **Fix:** run `tau setup --client windsurf` to wire or refresh it — `tau doctor --fix` auto-fixes the bridge/ACP clients and writes a paste-ready snippet for the manual ones; guide: docs/clients/windsurf.md
- **Explain:** `tau explain doctor.client_windsurf`

### `client_gemini`

- **Symptom:** the `client_gemini` row reports a non-`ok` status (`warn` or `fail`) in the `tau doctor` report — one `check_event` line under `--json`.
- **Cause:** tau isn't wired into that client's settings, or the wiring is stale — a dead `command` path or wrong `args` counts as stale; the row is absent entirely when the client isn't installed
- **Fix:** run `tau setup --client gemini` to wire or refresh it — `tau doctor --fix` auto-fixes the bridge/ACP clients and writes a paste-ready snippet for the manual ones; guide: docs/clients/gemini-cli.md
- **Explain:** `tau explain doctor.client_gemini`

### `client_claude_desktop`

- **Symptom:** the `client_claude_desktop` row reports a non-`ok` status (`warn` or `fail`) in the `tau doctor` report — one `check_event` line under `--json`.
- **Cause:** tau isn't wired into that client's settings, or the wiring is stale — a dead `command` path or wrong `args` counts as stale; the row is absent entirely when the client isn't installed
- **Fix:** run `tau setup --client claude-desktop` to wire or refresh it — `tau doctor --fix` auto-fixes the bridge/ACP clients and writes a paste-ready snippet for the manual ones; guide: docs/clients/claude-desktop.md
- **Explain:** `tau explain doctor.client_claude_desktop`

### `client_opencode`

- **Symptom:** the `client_opencode` row reports a non-`ok` status (`warn` or `fail`) in the `tau doctor` report — one `check_event` line under `--json`.
- **Cause:** tau isn't wired into that client's settings, or the wiring is stale — a dead `command` path or wrong `args` counts as stale; the row is absent entirely when the client isn't installed
- **Fix:** run `tau setup --client opencode` to wire or refresh it — `tau doctor --fix` auto-fixes the bridge/ACP clients and writes a paste-ready snippet for the manual ones; guide: docs/clients/opencode.md
- **Explain:** `tau explain doctor.client_opencode`

### `client_cline`

- **Symptom:** the `client_cline` row reports a non-`ok` status (`warn` or `fail`) in the `tau doctor` report — one `check_event` line under `--json`.
- **Cause:** tau isn't wired into that client's settings, or the wiring is stale — a dead `command` path or wrong `args` counts as stale; the row is absent entirely when the client isn't installed
- **Fix:** run `tau setup --client cline` to wire or refresh it — `tau doctor --fix` auto-fixes the bridge/ACP clients and writes a paste-ready snippet for the manual ones; guide: docs/clients/cline.md
- **Explain:** `tau explain doctor.client_cline`

### `client_goose`

- **Symptom:** the `client_goose` row reports a non-`ok` status (`warn` or `fail`) in the `tau doctor` report — one `check_event` line under `--json`.
- **Cause:** tau isn't wired into that client's settings, or the wiring is stale — a dead `command` path or wrong `args` counts as stale; the row is absent entirely when the client isn't installed
- **Fix:** run `tau setup --client goose` to wire or refresh it — `tau doctor --fix` auto-fixes the bridge/ACP clients and writes a paste-ready snippet for the manual ones; guide: docs/clients/goose.md
- **Explain:** `tau explain doctor.client_goose`

### `client_continue`

- **Symptom:** the `client_continue` row reports a non-`ok` status (`warn` or `fail`) in the `tau doctor` report — one `check_event` line under `--json`.
- **Cause:** tau isn't wired into that client's settings, or the wiring is stale — a dead `command` path or wrong `args` counts as stale; the row is absent entirely when the client isn't installed
- **Fix:** run `tau setup --client continue` to wire or refresh it — `tau doctor --fix` auto-fixes the bridge/ACP clients and writes a paste-ready snippet for the manual ones; guide: docs/clients/continue.md
- **Explain:** `tau explain doctor.client_continue`

### `client_roo_code`

- **Symptom:** the `client_roo_code` row reports a non-`ok` status (`warn` or `fail`) in the `tau doctor` report — one `check_event` line under `--json`.
- **Cause:** tau isn't wired into that client's settings, or the wiring is stale — a dead `command` path or wrong `args` counts as stale; the row is absent entirely when the client isn't installed
- **Fix:** run `tau setup --client roo-code` to wire or refresh it — `tau doctor --fix` auto-fixes the bridge/ACP clients and writes a paste-ready snippet for the manual ones; guide: docs/clients/roo-code.md
- **Explain:** `tau explain doctor.client_roo_code`

### `client_kilo_code`

- **Symptom:** the `client_kilo_code` row reports a non-`ok` status (`warn` or `fail`) in the `tau doctor` report — one `check_event` line under `--json`.
- **Cause:** tau isn't wired into that client's settings, or the wiring is stale — a dead `command` path or wrong `args` counts as stale; the row is absent entirely when the client isn't installed
- **Fix:** run `tau setup --client kilo-code` to wire or refresh it — `tau doctor --fix` auto-fixes the bridge/ACP clients and writes a paste-ready snippet for the manual ones; guide: docs/clients/kilo-code.md
- **Explain:** `tau explain doctor.client_kilo_code`

### `client_amazonq`

- **Symptom:** the `client_amazonq` row reports a non-`ok` status (`warn` or `fail`) in the `tau doctor` report — one `check_event` line under `--json`.
- **Cause:** tau isn't wired into that client's settings, or the wiring is stale — a dead `command` path or wrong `args` counts as stale; the row is absent entirely when the client isn't installed
- **Fix:** run `tau setup --client amazonq` to wire or refresh it — `tau doctor --fix` auto-fixes the bridge/ACP clients and writes a paste-ready snippet for the manual ones; guide: docs/clients/amazonq.md
- **Explain:** `tau explain doctor.client_amazonq`

### `client_codex`

- **Symptom:** the `client_codex` row reports a non-`ok` status (`warn` or `fail`) in the `tau doctor` report — one `check_event` line under `--json`.
- **Cause:** tau isn't wired into that client's settings, or the wiring is stale — a dead `command` path or wrong `args` counts as stale; the row is absent entirely when the client isn't installed
- **Fix:** run `tau setup --client codex` to wire or refresh it — `tau doctor --fix` auto-fixes the bridge/ACP clients and writes a paste-ready snippet for the manual ones; guide: docs/clients/codex.md
- **Explain:** `tau explain doctor.client_codex`

### `probe_xiaomi`

- **Symptom:** the `probe_xiaomi` row reports a non-`ok` status (`warn` or `fail`) in the `tau doctor` report — one `check_event` line under `--json`.
- **Cause:** the `--probe` connectivity check against that provider's endpoint failed or timed out
- **Fix:** verify network reachability — DNS, firewall, and the proxy_env/tls_ca rows; the endpoint is listed by `tau models`
- **Explain:** `tau explain doctor.probe_xiaomi`

### `probe_xiaomi_auth`

- **Symptom:** the `probe_xiaomi_auth` row reports a non-`ok` status (`warn` or `fail`) in the `tau doctor` report — one `check_event` line under `--json`.
- **Cause:** the `--probe` credential check failed — the key resolved for that provider was rejected by a one-token authenticated completion
- **Fix:** re-issue or rotate the key — it resolves from the provider's env var, keys.xiaomi in config.json, TAU_API_KEY, or --api-key
- **Explain:** `tau explain doctor.probe_xiaomi_auth`

### `probe_openai`

- **Symptom:** the `probe_openai` row reports a non-`ok` status (`warn` or `fail`) in the `tau doctor` report — one `check_event` line under `--json`.
- **Cause:** the `--probe` connectivity check against that provider's endpoint failed or timed out
- **Fix:** verify network reachability — DNS, firewall, and the proxy_env/tls_ca rows; the endpoint is listed by `tau models`
- **Explain:** `tau explain doctor.probe_openai`

### `probe_openai_auth`

- **Symptom:** the `probe_openai_auth` row reports a non-`ok` status (`warn` or `fail`) in the `tau doctor` report — one `check_event` line under `--json`.
- **Cause:** the `--probe` credential check failed — the key resolved for that provider was rejected by a one-token authenticated completion
- **Fix:** re-issue or rotate the key — it resolves from the provider's env var, keys.openai in config.json, TAU_API_KEY, or --api-key
- **Explain:** `tau explain doctor.probe_openai_auth`

### `probe_deepseek`

- **Symptom:** the `probe_deepseek` row reports a non-`ok` status (`warn` or `fail`) in the `tau doctor` report — one `check_event` line under `--json`.
- **Cause:** the `--probe` connectivity check against that provider's endpoint failed or timed out
- **Fix:** verify network reachability — DNS, firewall, and the proxy_env/tls_ca rows; the endpoint is listed by `tau models`
- **Explain:** `tau explain doctor.probe_deepseek`

### `probe_deepseek_auth`

- **Symptom:** the `probe_deepseek_auth` row reports a non-`ok` status (`warn` or `fail`) in the `tau doctor` report — one `check_event` line under `--json`.
- **Cause:** the `--probe` credential check failed — the key resolved for that provider was rejected by a one-token authenticated completion
- **Fix:** re-issue or rotate the key — it resolves from the provider's env var, keys.deepseek in config.json, TAU_API_KEY, or --api-key
- **Explain:** `tau explain doctor.probe_deepseek_auth`

### `probe_opencode-go`

- **Symptom:** the `probe_opencode-go` row reports a non-`ok` status (`warn` or `fail`) in the `tau doctor` report — one `check_event` line under `--json`.
- **Cause:** the `--probe` connectivity check against that provider's endpoint failed or timed out
- **Fix:** verify network reachability — DNS, firewall, and the proxy_env/tls_ca rows; the endpoint is listed by `tau models`
- **Explain:** `tau explain doctor.probe_opencode-go`

### `probe_opencode-go_auth`

- **Symptom:** the `probe_opencode-go_auth` row reports a non-`ok` status (`warn` or `fail`) in the `tau doctor` report — one `check_event` line under `--json`.
- **Cause:** the `--probe` credential check failed — the key resolved for that provider was rejected by a one-token authenticated completion
- **Fix:** re-issue or rotate the key — it resolves from the provider's env var, keys.opencode-go in config.json, TAU_API_KEY, or --api-key
- **Explain:** `tau explain doctor.probe_opencode-go_auth`
