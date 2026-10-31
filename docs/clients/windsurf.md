# Wire Windsurf to tau

Windsurf speaks MCP, not ACP — it can't spawn `tau acp serve` directly.
`tau setup` wires it through the
[mcacp](https://github.com/Oortonaut/mcacp) MCP→ACP bridge:

```
Windsurf ──MCP(stdio)──> mcacp ──ACP(stdio)──> tau acp serve
```

Two files do the wiring: Windsurf's `mcpServers` entry launches the bridge,
and the shared `~/.config/mcacp/mcacp.json` tells the bridge how to spawn
tau. One mcacp.json serves every MCP client (Windsurf, Gemini CLI, Claude
Desktop) at once.

## Prerequisites

- `tau` installed and configured — `tau doctor` reports an ok provider and
  API key (see [docs/configuration.md](../configuration.md)).
- Node.js with `npx` on the PATH Windsurf sees — the bridge runs as
  `npx -y mcacp` (or install it once with `npm i -g mcacp`).

## One command

```bash
tau setup --client windsurf --yes
```

Setup reports both halves of the wiring in its clients step — `"path"` /
`"status"` for the Windsurf file and `"bridge_path"` / `"bridge_status"`
for mcacp.json:

```json
{"client":"windsurf","path":"/home/you/.codeium/windsurf/mcp_config.json","status":"installed","command":"/abs/path/to/tau","next":"install mcacp (npm i -g mcacp or npx), restart Windsurf, and confirm the mcacp server in Settings > MCP servers","bridge_path":"/home/you/.config/mcacp/mcacp.json","bridge_status":"installed"}
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

at `~/.codeium/windsurf/mcp_config.json`, and the shared bridge config at
`~/.config/mcacp/mcacp.json` (`"command"` is the absolute path to the tau
binary setup ran from):

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
destroy your comments. When `mcp_config.json` already exists it drops a
paste-ready snippet at `~/.config/tau/snippets/windsurf.jsonc` instead and
reports `"status":"manual"`:

<!-- setup-verify: client-snippet -->
```jsonc
// tau via the mcacp MCP->ACP bridge — merge into your windsurf settings file.
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

Merge each fragment into the named file by hand and restart Windsurf.

## Manual setup

Paste the two verified blocks above into place yourself:

- Windsurf's `mcp_config.json` lives at `~/.codeium/windsurf/`
  (`%USERPROFILE%\.codeium\windsurf\` on Windows). If the file already has
  a `"mcpServers"` object, add only the inner `"mcacp"` entry to it.
- The bridge config goes at `~/.config/mcacp/mcacp.json` — replace
  `"command": "tau"` with the absolute path to your tau binary
  (`command -v tau`) unless `tau` is on the PATH the bridge's spawn
  environment sees.
- If the spawned tau process needs credentials it can't get from
  `~/.config/tau/config.json`, put them in the `"env"` object — e.g.
  `"env": {"XIAOMI_API_KEY": "…"}` or `"env": {"TAU_API_KEY": "…"}`.

Both files also ship as
[`examples/clients/windsurf.json`](../../examples/clients/windsurf.json) and
[`examples/clients/mcacp.json`](../../examples/clients/mcacp.json).

## Finish in Windsurf

1. Make mcacp available: `npm i -g mcacp`, or leave it to `npx -y mcacp`.
2. Restart Windsurf and confirm the `mcacp` server under
   **Settings → MCP servers**.
3. Ask Cascade to use the tau agent — mcacp's session/prompt tools spawn
   `tau acp serve` and stream the exchange.

`tau doctor` reports the wiring as the `client_windsurf` check and can
repair a missing or stale entry with `tau doctor --fix`
(`wire_client_windsurf`).

## Removing the integration

Setup is additive and never deletes. To undo it: remove the `"mcacp"`
entry from `mcp_config.json`'s `mcpServers`, and delete
`~/.config/mcacp/mcacp.json` once no other MCP client still uses it.
Snippets under `~/.config/tau/snippets/` are inert leftovers — delete them
freely.

## See also

- [docs/acp.md](../acp.md) — the full ACP guide and the bridge architecture.
- [docs/editors.md](../editors.md) — every `tau setup --client` target.
- [docs/compatibility.md](../compatibility.md) — generated client matrix.
- [Gemini CLI](gemini-cli.md) · [Claude Desktop](claude-desktop.md) — the
  other MCP-bridge clients.
