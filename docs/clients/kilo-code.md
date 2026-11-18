# Wire Kilo Code to tau

[Kilo Code](https://kilo.ai) — the `kilocode.kilo-code` VS Code
extension and its `kilo` CLI — speaks MCP, not ACP. `tau setup` wires it
through the [mcacp](https://github.com/Oortonaut/mcacp) MCP→ACP bridge:

```
Kilo Code ──MCP(stdio)──> mcacp ──ACP(stdio)──> tau acp serve
```

Two files do the wiring: Kilo's `mcp` entry launches the bridge, and the
shared `~/.config/mcacp/mcacp.json` tells the bridge how to spawn tau.
One mcacp.json serves every MCP client (Kilo Code, Cline, Roo Code,
Windsurf, Gemini CLI, Claude Desktop, OpenCode, Goose, Continue, Amazon
Q Developer) at once.

## Prerequisites

- `tau` installed and configured — `tau doctor` reports an ok provider and
  API key (see [docs/configuration.md](../configuration.md)).
- Node.js with `npx` on the PATH the Kilo Code process sees — the bridge
  runs as `npx -y mcacp` (or install it once with `npm i -g mcacp`).

## One command

```bash
tau setup --client kilo-code --yes
```

Setup reports both halves of the wiring in its clients step — `"path"` /
`"status"` for the Kilo file and `"bridge_path"` / `"bridge_status"`
for mcacp.json:

```json
{"client":"kilo-code","path":"/home/you/.config/kilo/kilo.jsonc","status":"installed","command":"/abs/path/to/tau","next":"install mcacp (npm i -g mcacp or npx), restart Kilo Code, and confirm the mcacp server under Agent Behaviour > MCP Servers (or run 'kilo mcp list')","bridge_path":"/home/you/.config/mcacp/mcacp.json","bridge_status":"installed"}
```

## What gets written

<!-- setup-verify: client-file -->
```json
{
  "mcp": {
    "mcacp": {
      "type": "local",
      "command": ["npx", "-y", "mcacp"],
      "enabled": true
    }
  }
}
```

at `~/.config/kilo/kilo.jsonc` — Kilo keeps its MCP servers under the
top-level `mcp` object (not `mcpServers`), and a local entry packs the
whole spawn line into a `command` array — and the shared bridge config
at `~/.config/mcacp/mcacp.json` (`"command"` is the absolute path to the
tau binary setup ran from):

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

## Already have an `mcp` section?

Setup never rewrites an existing settings file — rewriting JSONC would
destroy your comments. When `kilo.jsonc` already exists it drops a
paste-ready snippet at `~/.config/tau/snippets/kilo-code.jsonc` instead
and reports `"status":"manual"`:

<!-- setup-verify: client-snippet -->
```jsonc
// tau via the mcacp MCP->ACP bridge — merge into your kilo-code settings file.
// If a top-level "mcp" object already exists, add just the inner
// "mcacp" entry to it; otherwise add the whole block. The bridge
// itself is configured separately — see snippets/mcacp.jsonc.
"mcp": {
  "mcacp": {
    "type": "local",
    "command": ["npx", "-y", "mcacp"],
    "enabled": true
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

Merge each fragment into the named file by hand and restart Kilo Code.

## Manual setup

Paste the two verified blocks above into place yourself:

- Kilo Code's global config lives at `~/.config/kilo/kilo.jsonc` — the
  same file both the VS Code extension and the `kilo` CLI read
  (project-level overrides live in `./kilo.jsonc` or `./.kilo/kilo.jsonc`;
  prefer the global file so every workspace gets tau). If the file
  already has a `"mcp"` object, add only the inner `"mcacp"` entry to it.
  Local entries take `"type": "local"`, a `"command"` array, and an
  optional `"environment"` map for server env vars.
  - Older Kilo versions (pre-v7) stored MCP servers in the VS Code
    extension's `globalStorage/kilocode.kilo-code/settings/mcp_settings.json`
    under `"mcpServers"` — current versions ignore that file; migrate to
    `kilo.jsonc`.
- The bridge config goes at `~/.config/mcacp/mcacp.json` — replace
  `"command": "tau"` with the absolute path to your tau binary
  (`command -v tau`) unless `tau` is on the PATH the bridge's spawn
  environment sees.
- If the spawned tau process needs credentials it can't get from
  `~/.config/tau/config.json`, put them in the bridge entry's `"env"`
  object — e.g. `"env": {"XIAOMI_API_KEY": "…"}` or
  `"env": {"TAU_API_KEY": "…"}`.

The same files ship as
[`examples/clients/kilo-code.json`](../../examples/clients/kilo-code.json)
and [`examples/clients/mcacp.json`](../../examples/clients/mcacp.json).

## Finish in Kilo Code

1. Make mcacp available: `npm i -g mcacp`, or leave it to `npx -y mcacp`.
2. Restart Kilo Code and confirm the `mcacp` server under
   **Agent Behaviour → MCP Servers** in the extension settings — or run
   `kilo mcp list` from the CLI.
3. Ask Kilo Code to use tau's tools — mcacp spawns `tau acp serve` and
   relays the exchange.

`tau doctor` reports the wiring as the `client_kilo_code` check and can
repair a missing or stale entry with `tau doctor --fix`
(`wire_client_kilo`).

## Removing the integration

Setup is additive and never deletes. To undo it: remove the `"mcacp"`
entry from `kilo.jsonc`'s `mcp` object (or run
`tau setup --remove --client kilo-code`), and delete
`~/.config/mcacp/mcacp.json` once no other MCP client still uses it.
Snippets under `~/.config/tau/snippets/` are inert leftovers — delete
them freely.

## See also

- [docs/acp.md](../acp.md) — the full ACP guide and the bridge architecture.
- [docs/editors.md](../editors.md) — every `tau setup --client` target.
- [docs/compatibility.md](../compatibility.md) — generated client matrix.
- [OpenCode](opencode.md) — the other `mcp`-shape client.
- [Cline](cline.md) · [Roo Code](roo-code.md) ·
  [Windsurf](windsurf.md) · [Gemini CLI](gemini-cli.md) ·
  [Claude Desktop](claude-desktop.md) · [Goose](goose.md) ·
  [Continue](continue.md) · [Amazon Q Developer](amazonq.md) — the other
  MCP-bridge clients.
