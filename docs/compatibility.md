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
[docs/editors.md](editors.md) and [docs/acp.md](acp.md), plus a
dedicated per-client guide for each client with verified snippets:
[Zed](clients/zed.md), [VS Code](clients/vscode.md),
[Cursor](clients/cursor.md), [JetBrains](clients/jetbrains.md),
[Neovim](clients/nvim.md), [Emacs](clients/emacs.md),
[Windsurf](clients/windsurf.md), [Gemini CLI](clients/gemini-cli.md),
[Claude Desktop](clients/claude-desktop.md),
[OpenCode](clients/opencode.md), [Cline](clients/cline.md),
[Goose](clients/goose.md), [Continue](clients/continue.md),
[Roo Code](clients/roo-code.md),
[Kilo Code](clients/kilo-code.md),
[Amazon Q Developer](clients/amazonq.md),
[Codex CLI](clients/codex.md).

Every row below also resolves offline via `tau explain client.<name>`
(or the bare `--client` name/alias) — e.g. `tau explain client.zed`
prints the same paths, prerequisites, and in-editor step as JSON
(`--human` renders prose).

## Supported editor clients

| Client | `tau setup --client` | Config dir (detection) | Settings file | Agent-section key | Extra required field | Snippet fallback | `tau doctor` check / `--fix` |
|--------|----------------------|------------------------|---------------|-------------------|----------------------|------------------|----------------------------|
| `zed` | `zed` | `~/.config/zed` | `~/.config/zed/settings.json` | `agent_servers` | `"type": "custom"` | `~/.config/tau/snippets/zed.jsonc` | `client_zed` / `wire_client_zed` |
| `nvim` | `nvim` | `~/.config/nvim` | — (Lua plugin config) | — | — | `~/.config/tau/snippets/nvim.lua` | `client_nvim` (manual only — Lua plugin config) |
| `emacs` | `emacs` | `~/.emacs.d` | — (elisp config) | — | — | `~/.config/tau/snippets/emacs.el` | `client_emacs` (manual only — elisp config) |
| `vscode` | `vscode` (alias `code`) | `~/.config/Code` | `~/.config/Code/User/settings.json` | `acp.agents` | none | `~/.config/tau/snippets/vscode.jsonc` | `client_vscode` / `wire_client_vscode` |
| `cursor` | `cursor` | `~/.config/Cursor` | `~/.config/Cursor/User/settings.json` | `acp.agents` | none | `~/.config/tau/snippets/cursor.jsonc` | `client_cursor` / `wire_client_cursor` |
| `jetbrains` | `jetbrains` | `~/.jetbrains` | `~/.jetbrains/acp.json` | `agent_servers` | none | `~/.config/tau/snippets/jetbrains.jsonc` | `client_jetbrains` / `wire_client_jetbrains` |
| `windsurf` (mcacp) | `windsurf` | `~/.codeium/windsurf` | `~/.codeium/windsurf/mcp_config.json` | `mcpServers` | none | `~/.config/tau/snippets/windsurf.jsonc` | `client_windsurf` / `wire_client_windsurf` |
| `gemini` (mcacp) | `gemini` (alias `gemini-cli`) | `~/.gemini` | `~/.gemini/settings.json` | `mcpServers` | none | `~/.config/tau/snippets/gemini.jsonc` | `client_gemini` / `wire_client_gemini` |
| `claude-desktop` (mcacp) | `claude-desktop` (alias `claude`) | `~/.config/Claude` | `~/.config/Claude/claude_desktop_config.json` | `mcpServers` | none | `~/.config/tau/snippets/claude-desktop.jsonc` | `client_claude_desktop` / `wire_client_claude_desktop` |
| `opencode` (mcacp) | `opencode` | `~/.config/opencode` | `~/.config/opencode/opencode.json` | `mcp` | none | `~/.config/tau/snippets/opencode.jsonc` | `client_opencode` / `wire_client_opencode` |
| `cline` (mcacp) | `cline` | `~/.config/Code/User/globalStorage/saoudrizwan.claude-dev` | `~/.config/Code/User/globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json` | `mcpServers` | none | `~/.config/tau/snippets/cline.jsonc` | `client_cline` / `wire_client_cline` |
| `goose` (mcacp) | `goose` | `~/.config/goose` | — (YAML config) | — | — | `~/.config/tau/snippets/goose.yaml` | `client_goose` (manual only — YAML config) |
| `continue` (mcacp) | `continue` | `~/.continue` | — (YAML config) | — | — | `~/.config/tau/snippets/continue.yaml` | `client_continue` (manual only — YAML config) |
| `roo-code` (mcacp) | `roo-code` (alias `roo`) | `~/.config/Code/User/globalStorage/rooveterinaryinc.roo-cline` | `~/.config/Code/User/globalStorage/rooveterinaryinc.roo-cline/settings/mcp_settings.json` | `mcpServers` | none | `~/.config/tau/snippets/roo-code.jsonc` | `client_roo_code` / `wire_client_roo` |
| `kilo-code` (mcacp) | `kilo-code` (alias `kilo`) | `~/.config/kilo` | `~/.config/kilo/kilo.jsonc` | `mcp` | none | `~/.config/tau/snippets/kilo-code.jsonc` | `client_kilo_code` / `wire_client_kilo` |
| `amazonq` (mcacp) | `amazonq` (alias `amazon-q`) | `~/.aws/amazonq` | `~/.aws/amazonq/mcp.json` | `mcpServers` | none | `~/.config/tau/snippets/amazonq.jsonc` | `client_amazonq` / `wire_client_amazonq` |
| `codex` (mcacp) | `codex` (alias `codex-cli`) | `~/.codex` | — (TOML config) | — | — | `~/.config/tau/snippets/codex.toml` | `client_codex` (manual only — TOML config) |

`tau setup --client all` expands to every row. Detection (setup with no
`--client`, or `tau doctor`) only *reports* clients whose config dir
exists — it never writes.

## Config formats

Every direct-ACP JSON client's `tau` entry spawns the same process —
the editor runs `command` + `args`, and `args` must be exactly
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

MCP-bridge clients (`windsurf`, `gemini`, `claude-desktop`, `opencode`, `cline`, `goose`, `continue`, `roo-code`, `kilo-code`, `amazonq`, `codex`) speak MCP, not ACP — they can't
spawn `tau acp serve` directly. Their server entry launches
the [mcacp](https://github.com/Oortonaut/mcacp) bridge instead:

```jsonc
"mcpServers": {
  "mcacp": {
    "command": "npx",
    "args": ["-y", "mcacp"]
  }
}
```

The `mcp`-section clients (`opencode`, `kilo-code`) keep MCP servers
under `mcp` (not `mcpServers`) and pack the whole spawn line
into a `command` array — the same bridge, a different entry
shape:

```jsonc
"mcp": {
  "mcacp": {
    "type": "local",
    "command": ["npx", "-y", "mcacp"],
    "enabled": true
  }
}
```

Goose and Continue (`goose`, `continue`) speak MCP too but keep
their config in YAML, not JSON — `tau setup` can't splice a
YAML file, so it wires the shared bridge config and drops a
paste-ready YAML snippet (the `extensions:` / `mcpServers:`
block from each client's guide) for the user to merge.

Codex (`codex`) speaks MCP too but keeps its servers in
TOML `[mcp_servers.<name>]` tables in `~/.codex/config.toml` —
`tau setup` can't splice a TOML file, so it wires the shared
bridge config and drops a paste-ready TOML snippet (the
`[mcp_servers.mcacp]` table from the client's guide).

`tau setup --client` writes the matching bridge config too —
`~/.config/mcacp/mcacp.json` carries the real `agent_servers.tau`
entry in the direct-ACP shape above (one file, shared by every
bridge client; `tau doctor` checks both halves).

| File | Format |
|------|--------|
| Client settings files (matrix above) | JSONC — `//` and `/* */` comments are tolerated and preserved: existing files are never rewritten, setup emits a paste-ready snippet instead |
| `~/.config/mcacp/mcacp.json` | JSONC — the mcacp MCP→ACP bridge's `agent_servers.tau` entry, shared by every bridge client |
| `~/.config/tau/snippets/*` | `.jsonc` fragment for JSON clients; `.lua` for Neovim (plugin adapters — e.g. avante.nvim, CodeCompanion.nvim); `.el` for Emacs agent-shell; `.yaml` for Goose/Continue (YAML MCP config); `.toml` for Codex (TOML MCP config) |
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
| `emacs` | paste the snippet into your init file, restart Emacs, run M-x agent-shell and pick tau |
| `vscode` | install the ACP Client extension, run 'ACP: Connect to Agent', pick tau |
| `cursor` | install the ACP Client extension (Open VSX), run 'ACP: Connect to Agent', pick tau |
| `jetbrains` | open the AI Chat tool window and pick tau in the agent selector |
| `windsurf` | install mcacp (npm i -g mcacp or npx), restart Windsurf, and confirm the mcacp server in Settings > MCP servers |
| `gemini` | install mcacp (npm i -g mcacp or npx), restart Gemini CLI, and run /mcp to see tau's tools |
| `claude-desktop` | install mcacp (npm i -g mcacp or npx), restart Claude Desktop, and find tau's tools under the mcacp server |
| `opencode` | install mcacp (npm i -g mcacp or npx), restart OpenCode, and check the mcacp server with 'opencode mcp list' |
| `cline` | install mcacp (npm i -g mcacp or npx), restart VS Code, and confirm the mcacp server under MCP Servers in the Cline pane |
| `goose` | install mcacp (npm i -g mcacp or npx), merge the snippet into ~/.config/goose/config.yaml, then run 'goose session' and ask about the mcacp tools |
| `continue` | install mcacp (npm i -g mcacp or npx), merge the snippet into ~/.continue/config.yaml, restart Continue, and use agent mode to see tau's tools |
| `roo-code` | install mcacp (npm i -g mcacp or npx), restart VS Code, and confirm the mcacp server under MCP Servers in the Roo Code pane |
| `kilo-code` | install mcacp (npm i -g mcacp or npx), restart Kilo Code, and confirm the mcacp server under Agent Behaviour > MCP Servers (or run 'kilo mcp list') |
| `amazonq` | install mcacp (npm i -g mcacp or npx), then run 'q chat' (or restart the IDE plugin) and check the mcacp server with /mcp |
| `codex` | install mcacp (npm i -g mcacp or npx), merge the snippet into ~/.codex/config.toml, then run 'codex mcp list' to confirm the mcacp server |
