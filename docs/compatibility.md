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
[VS Code](clients/vscode.md), [Cursor](clients/cursor.md),
[Windsurf](clients/windsurf.md), [Gemini CLI](clients/gemini-cli.md),
[Claude Desktop](clients/claude-desktop.md).

## Supported editor clients

| Client | `tau setup --client` | Config dir (detection) | Settings file | Agent-section key | Extra required field | Snippet fallback | `tau doctor` check / `--fix` |
|--------|----------------------|------------------------|---------------|-------------------|----------------------|------------------|----------------------------|
| `zed` | `zed` | `~/.config/zed` | `~/.config/zed/settings.json` | `agent_servers` | `"type": "custom"` | `~/.config/tau/snippets/zed.jsonc` | `client_zed` / `wire_client_zed` |
| `nvim` | `nvim` | `~/.config/nvim` | — (Lua plugin config) | — | — | `~/.config/tau/snippets/nvim.lua` | `client_nvim` (manual only — Lua config) |
| `vscode` | `vscode` (alias `code`) | `~/.config/Code` | `~/.config/Code/User/settings.json` | `acp.agents` | none | `~/.config/tau/snippets/vscode.jsonc` | `client_vscode` / `wire_client_vscode` |
| `cursor` | `cursor` | `~/.config/Cursor` | `~/.config/Cursor/User/settings.json` | `acp.agents` | none | `~/.config/tau/snippets/cursor.jsonc` | `client_cursor` / `wire_client_cursor` |
| `jetbrains` | `jetbrains` | `~/.jetbrains` | `~/.jetbrains/acp.json` | `agent_servers` | none | `~/.config/tau/snippets/jetbrains.jsonc` | `client_jetbrains` / `wire_client_jetbrains` |
| `windsurf` (mcacp) | `windsurf` | `~/.codeium/windsurf` | `~/.codeium/windsurf/mcp_config.json` | `mcpServers` | none | `~/.config/tau/snippets/windsurf.jsonc` | `client_windsurf` / `wire_client_windsurf` |
| `gemini` (mcacp) | `gemini` (alias `gemini-cli`) | `~/.gemini` | `~/.gemini/settings.json` | `mcpServers` | none | `~/.config/tau/snippets/gemini.jsonc` | `client_gemini` / `wire_client_gemini` |
| `claude_desktop` (mcacp) | `claude-desktop` (alias `claude`) | `~/.config/Claude` | `~/.config/Claude/claude_desktop_config.json` | `mcpServers` | none | `~/.config/tau/snippets/claude-desktop.jsonc` | `client_claude_desktop` / `wire_client_claude_desktop` |

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

MCP-bridge clients (`windsurf`, `gemini`, `claude_desktop`) speak MCP, not ACP — they can't
spawn `tau acp serve` directly. Their `mcpServers` entry launches
the [mcacp](https://github.com/Oortonaut/mcacp) bridge instead:

```jsonc
"mcpServers": {
  "mcacp": {
    "command": "npx",
    "args": ["-y", "mcacp"]
  }
}
```

`tau setup --client` writes the matching bridge config too —
`~/.config/mcacp/mcacp.json` carries the real `agent_servers.tau`
entry in the direct-ACP shape above (one file, shared by every
bridge client; `tau doctor` checks both halves).

| File | Format |
|------|--------|
| Client settings files (matrix above) | JSONC — `//` and `/* */` comments are tolerated and preserved: existing files are never rewritten, setup emits a paste-ready snippet instead |
| `~/.config/mcacp/mcacp.json` | JSONC — the mcacp MCP→ACP bridge's `agent_servers.tau` entry, shared by every bridge client |
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
| `cursor` | install the ACP Client extension (Open VSX), run 'ACP: Connect to Agent', pick tau |
| `jetbrains` | open the AI Chat tool window and pick tau in the agent selector |
| `windsurf` | install mcacp (npm i -g mcacp or npx), restart Windsurf, and confirm the mcacp server in Settings > MCP servers |
| `gemini` | install mcacp (npm i -g mcacp or npx), restart Gemini CLI, and run /mcp to see tau's tools |
| `claude_desktop` | install mcacp (npm i -g mcacp or npx), restart Claude Desktop, and find tau's tools under the mcacp server |
