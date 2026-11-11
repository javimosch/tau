# Wire Roo Code to tau

[Roo Code](https://roocode.com) — the `rooveterinaryinc.roo-cline` VS Code
extension — speaks MCP, not ACP. `tau setup` wires it through the
[mcacp](https://github.com/Oortonaut/mcacp) MCP→ACP bridge:

```
Roo Code ──MCP(stdio)──> mcacp ──ACP(stdio)──> tau acp serve
```

Two files do the wiring: Roo Code's `mcpServers` entry launches the
bridge, and the shared `~/.config/mcacp/mcacp.json` tells the bridge how
to spawn tau. One mcacp.json serves every MCP client (Roo Code, Cline,
Kilo Code, Windsurf, Gemini CLI, Claude Desktop, OpenCode, Goose,
Continue, Amazon Q Developer) at once.

## Prerequisites

- `tau` installed and configured — `tau doctor` reports an ok provider and
  API key (see [docs/configuration.md](../configuration.md)).
- Node.js with `npx` on the PATH VS Code sees — the bridge runs as
  `npx -y mcacp` (or install it once with `npm i -g mcacp`).

## One command

```bash
tau setup --client roo-code --yes
```

Setup reports both halves of the wiring in its clients step — `"path"` /
`"status"` for the Roo Code file and `"bridge_path"` / `"bridge_status"`
for mcacp.json:

```json
{"client":"roo-code","path":"/home/you/.config/Code/User/globalStorage/rooveterinaryinc.roo-cline/settings/mcp_settings.json","status":"installed","command":"/abs/path/to/tau","next":"install mcacp (npm i -g mcacp or npx), restart VS Code, and confirm the mcacp server under MCP Servers in the Roo Code pane","bridge_path":"/home/you/.config/mcacp/mcacp.json","bridge_status":"installed"}
```

## What gets written

<!-- setup-verify: client-file -->
```json
{
  "mcpServers": {
    "mcacp": {
      "command": "npx",
      "args": ["-y", "mcacp"]
    }
  }
}
```

at
`~/.config/Code/User/globalStorage/rooveterinaryinc.roo-cline/settings/mcp_settings.json`,
and the shared bridge config at `~/.config/mcacp/mcacp.json` (`"command"`
is the absolute path to the tau binary setup ran from):

<!-- setup-verify: bridge-file -->
```json
{
  "agent_servers": {
    "tau": {
      "command": "tau",
      "args": ["acp", "serve"],
      "env": {}
    }
  }
}
```

> The fenced blocks above are verified — the `client-guides` smoke group
> ([scripts/check-client-guides.py](../../scripts/check-client-guides.py))
> diffs them byte-for-byte against real `tau setup --client` output in CI.

## Already have an `mcpServers` section?

Setup never rewrites an existing settings file — rewriting JSONC would
destroy your comments. When `mcp_settings.json` already exists it
drops a paste-ready snippet at `~/.config/tau/snippets/roo-code.jsonc`
instead and reports `"status":"manual"`:

<!-- setup-verify: client-snippet -->
```jsonc
// tau via the mcacp MCP->ACP bridge — merge into your roo-code settings file.
// If a top-level "mcpServers" object already exists, add just the
// inner "mcacp" entry to it; otherwise add the whole block. The
// bridge itself is configured separately — see snippets/mcacp.jsonc.
"mcpServers": {
  "mcacp": {
    "command": "npx",
    "args": ["-y", "mcacp"]
  }
}
```

The same rule covers the bridge side: an existing `mcacp.json` that lacks
the tau entry gets `~/.config/tau/snippets/mcacp.jsonc`:

<!-- setup-verify: bridge-snippet -->
```jsonc
// tau ACP agent for the mcacp bridge — merge into mcacp.json.
// If a top-level "agent_servers" object already exists, add just the
// inner "tau" entry to it; otherwise add the whole block.
"agent_servers": {
  "tau": {
    "command": "tau",
    "args": ["acp", "serve"],
    "env": {}
  }
}
```

Merge each fragment into the named file by hand and restart VS Code.

## Manual setup

Paste the two verified blocks above into place yourself:

- Roo Code's MCP settings file lives at
  `~/.config/Code/User/globalStorage/rooveterinaryinc.roo-cline/settings/mcp_settings.json`
  (`~/Library/Application Support/Code/User/globalStorage/…` on macOS,
  `%APPDATA%\Code\User\globalStorage\…` on Windows; swap `Code` for
  `Cursor`/`VSCodium` under a Code fork). Roo Code also reads a
  project-scoped `.roo/mcp.json` — prefer the global file for tau so every
  workspace gets it. If the file already has a `"mcpServers"` object, add
  only the inner `"mcacp"` entry to it. (Roo Code's own UI can open the
  file for you: Command Palette → "Roo Code: Open MCP Settings".)
- The bridge config goes at `~/.config/mcacp/mcacp.json` — replace
  `"command": "tau"` with the absolute path to your tau binary
  (`command -v tau`) unless `tau` is on the PATH the bridge's spawn
  environment sees.
- If the spawned tau process needs credentials it can't get from
  `~/.config/tau/config.json`, put them in the `"env"` object — e.g.
  `"env": {"XIAOMI_API_KEY": "…"}` or `"env": {"TAU_API_KEY": "…"}`.

The same files ship as
[`examples/clients/roo-code.json`](../../examples/clients/roo-code.json)
and [`examples/clients/mcacp.json`](../../examples/clients/mcacp.json).

## Finish in Roo Code

1. Make mcacp available: `npm i -g mcacp`, or leave it to `npx -y mcacp`.
2. Restart VS Code, open the Roo Code pane, and confirm the `mcacp`
   server under **MCP Servers** (the server icon in the Roo Code
   toolbar).
3. Ask Roo Code to use tau's tools — mcacp spawns `tau acp serve` and
   relays the exchange.

`tau doctor` reports the wiring as the `client_roo_code` check and can
repair a missing or stale entry with `tau doctor --fix`
(`wire_client_roo`).

## Removing the integration

Setup is additive and never deletes. To undo it: remove the `"mcacp"`
entry from `mcp_settings.json`'s `mcpServers` (or run
`tau setup --remove --client roo-code`), and delete
`~/.config/mcacp/mcacp.json` once no other MCP client still uses it.
Snippets under `~/.config/tau/snippets/` are inert leftovers — delete
them freely.

## See also

- [docs/acp.md](../acp.md) — the full ACP guide and the bridge architecture.
- [docs/editors.md](../editors.md) — every `tau setup --client` target.
- [docs/compatibility.md](../compatibility.md) — generated client matrix.
- [Cline](cline.md) · [Kilo Code](kilo-code.md) ·
  [Windsurf](windsurf.md) · [Gemini CLI](gemini-cli.md) ·
  [Claude Desktop](claude-desktop.md) · [OpenCode](opencode.md) ·
  [Goose](goose.md) · [Continue](continue.md) ·
  [Amazon Q Developer](amazonq.md) — the other MCP-bridge clients.
