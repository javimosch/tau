# Security Policy

## Supported Versions

Security fixes are applied to the latest release line only.

| Version | Supported |
|---------|-----------|
| 0.4.x   | ✅        |
| < 0.4   | ❌        |

## Reporting a Vulnerability

Please report suspected vulnerabilities **privately** through the repository's
GitHub Security tab (`Security` → `Report a vulnerability`):

<https://github.com/javimosch/tau/security/advisories/new>

Do **not** open a public issue for sensitive reports (credential leaks,
escapes from the tool-execution model, redaction bypasses in `--debug` logs).

Include in your report:

- tau version (`tau --version`) and OS/platform
- A minimal reproduction command or scenario
- What data or privilege boundary you believe is crossed
- Any relevant output — redact your own API keys before attaching logs

For non-sensitive bugs and hardening suggestions, a regular
[GitHub issue](https://github.com/javimosch/tau/issues) is fine.

## Scope

Particularly security-relevant areas in this codebase:

- **Credential handling** — API key resolution, config-file storage, and the
  `Authorization: Bearer` header construction (`src/config.zig`,
  `src/llm/provider.zig`).
- **Debug-log redaction** — the masking pipeline that makes
  `~/.config/tau/debug/` logs safe to share (`src/debuglog.zig`).
- **Tool execution** — model-invoked `bash`, `read`, `write`, `edit`, `grep`,
  `find` and their input validation (`src/tools/`, `src/agent.zig`).
- **Session/fleet persistence** — path validation for user-controlled names
  written under `~/.config/tau/` (`src/session.zig`, `src/fleet.zig`).

The full threat model — what tau sends over the network, where it writes data,
what the debug-log redaction does and does *not* cover, and how to restrict
tool access — is documented in
[docs/security-and-privacy.md](docs/security-and-privacy.md).
