# Wire OpenCode to tau

OpenCode speaks ACP in the *server* direction (`opencode acp` makes it an
agent for editors) — but it can't consume other ACP agents. What it *can*
consume natively are MCP servers, so `tau setup` wires it through the
[mcacp](https://github.com/Oortonaut/mcacp) MCP→ACP bridge:

```
OpenCode ──MCP(stdio)──> mcacp ──ACP(stdio)──> tau acp serve
```

Two files do the wiring: OpenCode's `mcp` entry launches the bridge, and
the shared `~/.config/mcacp/mcacp.json` tells the bridge how to spawn tau.
One mcacp.json serves every MCP client (OpenCode, Windsurf, Gemini CLI,
Claude Desktop) at once.

## Prerequisites

- `tau` installed and configured — `tau doctor` reports an ok provider and
  API key (see [docs/configuration.md](../configuration.md)).
- Node.js with `npx` on the PATH OpenCode sees — the bridge runs as
  `npx -y mcacp` (or install it once with `npm i -g mcacp`).

## One command

```bash
tau setup --client opencode --yes
```

Setup reports both halves of the wiring in its clients step — `"path"` /
`"status"` for the OpenCode file and `"bridge_path"` / `"bridge_status"`
for mcacp.json:

```json
{"client":"opencode","editor_detected":true,"path":"/home/you/.config/opencode/opencode.json","status":"installed","command":"/abs/path/to/tau","next":"install mcacp (npm i -g mcacp or npx), restart OpenCode, and check the mcacp server with 'opencode mcp list'","bridge_path":"/home/you/.config/mcacp/mcacp.json","bridge_status":"installed"}
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

at `~/.config/opencode/opencode.json`, and the shared bridge config at
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

The flat `"mcp"` section is the shape OpenCode's own docs show; OpenCode
v2 also accepts the nested `"mcp": {"servers": { ... }}` layout, which is
what `opencode mcp add mcacp -- npx -y mcacp` writes on v2. Either form
wires the same bridge — pick one, don't mix them.

## Already have an `mcp` section?

Setup never rewrites an existing settings file — rewriting JSONC would
destroy your comments. When `opencode.json` already exists it drops a
paste-ready snippet at `~/.config/tau/snippets/opencode.jsonc` instead and
reports `"status":"manual"`:

<!-- setup-verify: client-snippet -->
```jsonc
// tau via the mcacp MCP->ACP bridge — merge into your opencode settings file.
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

Merge each fragment into the named file by hand and restart OpenCode.

## Manual setup

Paste the two verified blocks above into place yourself:

- OpenCode's global config lives at `~/.config/opencode/opencode.json`.
  A project-local `opencode.json` in the repo root works too — handy if
  only one project should see tau's tools. If the file already has an
  `"mcp"` object, add only the inner `"mcacp"` entry to it.
- The bridge config goes at `~/.config/mcacp/mcacp.json` — replace
  `"command": "tau"` with the absolute path to your tau binary
  (`command -v tau`) unless `tau` is on the PATH the bridge's spawn
  environment sees.
- If the spawned tau process needs credentials it can't get from
  `~/.config/tau/config.json`, put them in the entry's `"environment"`
  object — e.g. `"environment": {"XIAOMI_API_KEY": "…"}`.
- On OpenCode v2 prefer the `"mcp": {"servers": {"mcacp": {…}}}` layout
  (the flat form still works, and v2 spells the toggle `"disabled"`
  instead of `"enabled"`).

Both files also ship as
[`examples/clients/opencode.json`](../../examples/clients/opencode.json)
and [`examples/clients/mcacp.json`](../../examples/clients/mcacp.json).

## Finish in OpenCode

1. Make mcacp available: `npm i -g mcacp`, or leave it to `npx -y mcacp`.
2. Restart OpenCode and run `opencode mcp list` — the `mcacp` server
   should show as connected.
3. tau's tools surface as `mcacp_<tool>` — ask the agent to use them and
   mcacp spawns `tau acp serve` and relays the exchange.

`tau doctor` reports the wiring as the `client_opencode` check and can
repair a missing or stale entry with `tau doctor --fix`
(`wire_client_opencode`).

## Removing the integration

Setup is additive and never deletes. To undo it: remove the `"mcacp"`
entry from `opencode.json`'s `mcp`, and delete
`~/.config/mcacp/mcacp.json` once no other MCP client still uses it.
Snippets under `~/.config/tau/snippets/` are inert leftovers — delete them
freely.

## See also

- [docs/acp.md](../acp.md) — the full ACP guide and the bridge architecture.
- [docs/editors.md](../editors.md) — every `tau setup --client` target.
- [docs/compatibility.md](../compatibility.md) — generated client matrix.
- [Windsurf](windsurf.md) · [Gemini CLI](gemini-cli.md) ·
  [Claude Desktop](claude-desktop.md) — the other MCP-bridge clients.
