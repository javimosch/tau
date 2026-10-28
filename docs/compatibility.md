# tau client compatibility matrix

<!-- GENERATED FILE — do not edit by hand.
     Source of truth: the ClientKind registry and per-client tables in
     src/setup.zig (doctor check/fix ids from src/doctor.zig; version
     rows from src/version.zig + CHANGELOG.md).
     Regenerate:  python3 scripts/gen-compat-doc.py
     Drift check: python3 scripts/gen-compat-doc.py --check
     (the compat-doc smoke group runs the drift check) -->

Which editors can drive `tau` as an ACP agent, where each one's config
lives, what shape the config takes, and which tau version each
integration path needs. Step-by-step guides:
[docs/editors.md](editors.md) and [docs/acp.md](acp.md).

## Supported editor clients

| Client | `tau setup --client` | Config dir (detection) | Settings file | Agent-section key | Extra required field | Snippet fallback | `tau doctor` check / `--fix` |
|--------|----------------------|------------------------|---------------|-------------------|----------------------|------------------|----------------------------|
| `zed` | `zed` | `~/.config/zed` | `~/.config/zed/settings.json` | `agent_servers` | `"type": "custom"` | `~/.config/tau/snippets/zed.jsonc` | `client_zed` / `wire_client_zed` |
| `nvim` | `nvim` | `~/.config/nvim` | — (Lua plugin config) | — | — | `~/.config/tau/snippets/nvim.lua` | `client_nvim` (manual only — Lua config) |
| `vscode` | `vscode` (alias `code`) | `~/.config/Code` | `~/.config/Code/User/settings.json` | `acp.agents` | none | `~/.config/tau/snippets/vscode.jsonc` | `client_vscode` / `wire_client_vscode` |
| `jetbrains` | `jetbrains` | `~/.jetbrains` | `~/.jetbrains/acp.json` | `agent_servers` | none | `~/.config/tau/snippets/jetbrains.jsonc` | `client_jetbrains` / `wire_client_jetbrains` |

`tau setup --client all` expands to every row. Detection (setup with no
`--client`, or `tau doctor`) only *reports* clients whose config dir
exists — it never writes.

## Config formats

Every JSON client's `tau` entry spawns the same process — the editor
runs `command` + `args`, and `args` must be exactly
`["acp", "serve"]` (anything else is flagged stale by `tau doctor`):

```jsonc
"<agent-section key>": {
  "tau": {
    "command": "<path-to-tau>",
    "args": ["acp", "serve"],
    "env": {}
  }
}
```

| File | Format |
|------|--------|
| Client settings files (matrix above) | JSONC — `//` and `/* */` comments are tolerated and preserved: existing files are never rewritten, setup emits a paste-ready snippet instead |
| `~/.config/tau/snippets/*` | `.jsonc` fragment for JSON clients; `.lua` for Neovim (plugin adapters — e.g. avante.nvim, CodeCompanion.nvim) |
| `~/.config/tau/config.json` | JSONC — see [docs/config.md](config.md) and `schema/tau-config.schema.json` |

## Required tau versions

| Capability | Minimum tau |
|------------|-------------|
| `tau acp serve` — every client wiring spawns it | ≥ 0.2.0 |
| `tau setup --client <name>` / `--client all` | unreleased (lands after 0.4.0) |
| `tau setup --dry-run` | unreleased (lands after 0.4.0) |
| `tau doctor` `client_*` wiring checks + `--fix` remediation | unreleased (lands after 0.4.0) |

Hand-editing a settings file only needs `tau acp serve`, so every client
in the matrix works on tau ≥ 0.2.0. The version-gated rows are the
automation: `setup --client` writes the entries for you, and `doctor`
verifies or repairs them.

## In-editor finish

After tau writes (or previews) the config, one in-editor step remains:

| Client | Last step |
|--------|-----------|
| `zed` | open the Agent Panel, click +, and pick tau |
| `nvim` | pick the tau provider/adapter in your plugin (e.g. :AvanteSwitchProvider) |
| `vscode` | install the ACP Client extension, run 'ACP: Connect to Agent', pick tau |
| `jetbrains` | open the AI Chat tool window and pick tau in the agent selector |
