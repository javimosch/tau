# Wire Amazon Q Developer to tau

[Amazon Q Developer](https://aws.amazon.com/q/developer/) — the `q` CLI
and the IDE plugin — speaks MCP, not ACP. `tau setup` wires it through
the [mcacp](https://github.com/Oortonaut/mcacp) MCP→ACP bridge:

```
Amazon Q Developer ──MCP(stdio)──> mcacp ──ACP(stdio)──> tau acp serve
```

Two files do the wiring: Amazon Q's `mcpServers` entry launches the
bridge, and the shared `~/.config/mcacp/mcacp.json` tells the bridge how
to spawn tau. One mcacp.json serves every MCP client (Amazon Q
Developer, Cline, Roo Code, Kilo Code, Windsurf, Gemini CLI, Claude
Desktop, OpenCode, Goose, Continue) at once.

## Prerequisites

- `tau` installed and configured — `tau doctor` reports an ok provider and
  API key (see [docs/configuration.md](../configuration.md)).
- Node.js with `npx` on the PATH the `q` process sees — the bridge runs
  as `npx -y mcacp` (or install it once with `npm i -g mcacp`).

## One command

```bash
tau setup --client amazonq --yes
```

Setup reports both halves of the wiring in its clients step — `"path"` /
`"status"` for the Amazon Q file and `"bridge_path"` / `"bridge_status"`
for mcacp.json:

```json
{"client":"amazonq","path":"/home/you/.aws/amazonq/mcp.json","status":"installed","command":"/abs/path/to/tau","next":"install mcacp (npm i -g mcacp or npx), then run 'q chat' (or restart the IDE plugin) and check the mcacp server with /mcp","bridge_path":"/home/you/.config/mcacp/mcacp.json","bridge_status":"installed"}
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

at `~/.aws/amazonq/mcp.json` — the global-scope config every workspace
inherits — and the shared bridge config at
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
destroy your comments. When `~/.aws/amazonq/mcp.json` already exists it
drops a paste-ready snippet at `~/.config/tau/snippets/amazonq.jsonc`
instead and reports `"status":"manual"`:

<!-- setup-verify: client-snippet -->
```jsonc
// tau via the mcacp MCP->ACP bridge — merge into your amazonq settings file.
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

Merge each fragment into the named file by hand and restart `q` (or the
IDE plugin).

## Manual setup

Paste the two verified blocks above into place yourself:

- Amazon Q Developer's global MCP config lives at
  `~/.aws/amazonq/mcp.json`; a workspace-scoped `.amazonq/mcp.json` in the
  project root overrides it — prefer the global file so every workspace
  gets tau. (Newer `q` versions can also manage servers via
  `q mcp add`/`q mcp import`, and agent files under
  `~/.aws/amazonq/cli-agents/` can carry their own `mcpServers` — the
  legacy `mcp.json` is still read when `useLegacyMcpJson` is on, which is
  the default.) If the file already has a `"mcpServers"` object, add only
  the inner `"mcacp"` entry to it.
- The bridge config goes at `~/.config/mcacp/mcacp.json` — replace
  `"command": "tau"` with the absolute path to your tau binary
  (`command -v tau`) unless `tau` is on the PATH the bridge's spawn
  environment sees.
- If the spawned tau process needs credentials it can't get from
  `~/.config/tau/config.json`, put them in the `"env"` object — e.g.
  `"env": {"XIAOMI_API_KEY": "…"}` or `"env": {"TAU_API_KEY": "…"}`.

The same files ship as
[`examples/clients/amazonq.json`](../../examples/clients/amazonq.json)
and [`examples/clients/mcacp.json`](../../examples/clients/mcacp.json).

## Finish in Amazon Q Developer

1. Make mcacp available: `npm i -g mcacp`, or leave it to `npx -y mcacp`.
2. Start a chat — `q chat` in a terminal, or restart the IDE plugin —
   and confirm the `mcacp` server with `/mcp` (or `/tools` to see tau's
   tools; trust them with `/tools trust …` if you don't want per-call
   prompts).
3. Ask Amazon Q to use tau's tools — mcacp spawns `tau acp serve` and
   relays the exchange.

`tau doctor` reports the wiring as the `client_amazonq` check and can
repair a missing or stale entry with `tau doctor --fix`
(`wire_client_amazonq`).

## Removing the integration

Setup is additive and never deletes. To undo it: remove the `"mcacp"`
entry from `~/.aws/amazonq/mcp.json`'s `mcpServers` (or run
`tau setup --remove --client amazonq`), and delete
`~/.config/mcacp/mcacp.json` once no other MCP client still uses it.
Snippets under `~/.config/tau/snippets/` are inert leftovers — delete
them freely.

## See also

- [docs/acp.md](../acp.md) — the full ACP guide and the bridge architecture.
- [docs/editors.md](../editors.md) — every `tau setup --client` target.
- [docs/compatibility.md](../compatibility.md) — generated client matrix.
- [Cline](cline.md) · [Roo Code](roo-code.md) ·
  [Kilo Code](kilo-code.md) · [Windsurf](windsurf.md) ·
  [Gemini CLI](gemini-cli.md) · [Claude Desktop](claude-desktop.md) ·
  [OpenCode](opencode.md) · [Goose](goose.md) ·
  [Continue](continue.md) — the other MCP-bridge clients.
