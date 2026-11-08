# Wire Claude Code to tau

Claude Code speaks MCP, not ACP — it can't spawn `tau acp serve`
directly. `tau setup` wires it through the
[mcacp](https://github.com/Oortonaut/mcacp) MCP→ACP bridge:

```
Claude Code ──MCP(stdio)──> mcacp ──ACP(stdio)──> tau acp serve
```

Two files do the wiring: Claude Code's `mcpServers` entry launches the
bridge, and the shared `~/.config/mcacp/mcacp.json` tells the bridge how
to spawn tau. One mcacp.json serves every MCP client (Claude Code,
Claude Desktop, Windsurf, Gemini CLI, …) at once.

## Prerequisites

- `tau` installed and configured — `tau doctor` reports an ok provider and
  API key (see [docs/configuration.md](../configuration.md)).
- Node.js with `npx` on the PATH Claude Code sees — the bridge runs as
  `npx -y mcacp` (or install it once with `npm i -g mcacp`).

## One command

```bash
tau setup --client claude-code --yes
```

Setup reports both halves of the wiring in its clients step — `"path"` /
`"status"` for the Claude Code file and `"bridge_path"` /
`"bridge_status"` for mcacp.json:

```json
{"client":"claude-code","path":"/home/you/.claude.json","status":"installed","command":"/abs/path/to/tau","next":"install mcacp (npm i -g mcacp or npx), restart Claude Code, and run /mcp to see the mcacp server","bridge_path":"/home/you/.config/mcacp/mcacp.json","bridge_status":"installed","project_path":"/your/project/.mcp.json","project_status":"skipped"}
```

## User scope vs project scope

Claude Code reads MCP servers at three scopes. Setup covers the two that
matter for wiring:

- **User scope — `~/.claude.json`.** The file setup writes (or points a
  snippet at). The `mcacp` server lands in its top-level `"mcpServers"`
  object, so tau is available in every project you open.
- **Project scope — `.mcp.json` at the project root.** When the
  directory you run setup in already carries a `.mcp.json`, setup merges
  the same `"mcacp"` entry into its `"mcpServers"` map in place —
  comments and your existing servers survive byte-for-byte
  (`"project_status":"installed"`). The file is meant to be committed,
  so teammates get the same wiring; Claude Code asks before running
  project-scoped servers it hasn't seen. A directory with no `.mcp.json`
  is left alone (`"project_status":"skipped"`) — setup never creates
  one. `tau setup --remove --client claude-code` splices the entry back
  out of `.mcp.json` too.

(Local scope — `~/.claude.json`'s per-project `projects.<path>` map — is
managed by `claude mcp add` itself; setup doesn't touch it.)

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

at `~/.claude.json`, and the shared bridge config at
`~/.config/mcacp/mcacp.json` (`"command"` is the absolute path to the
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

## Already have an `mcpServers` section?

Setup never rewrites an existing `~/.claude.json` — it's a large file
that also carries your per-project history, and rewriting JSON would
risk it. When `~/.claude.json` already exists without the entry, setup
drops a paste-ready snippet at
`~/.config/tau/snippets/claude-code.jsonc` instead and reports
`"status":"manual"`:

<!-- setup-verify: client-snippet -->
```jsonc
// tau via the mcacp MCP->ACP bridge — merge into your claude-code settings file.
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

Merge each fragment into the named file by hand and restart Claude Code.
Prefer `claude mcp add-json mcacp --scope user '{"command":"npx","args":["-y","mcacp"]}'`
if you'd rather let the CLI own the user-scope edit.

## Manual setup

Paste the two verified blocks above into place yourself:

- The user-scope file is `~/.claude.json` (same on every platform —
  `%USERPROFILE%\.claude.json` on Windows). If it already has a
  `"mcpServers"` object, add only the inner `"mcacp"` entry to it. For a
  project-shared setup, put the same block in `<project>/.mcp.json` and
  commit it.
- The bridge config goes at `~/.config/mcacp/mcacp.json` — replace
  `"command": "tau"` with the absolute path to your tau binary
  (`command -v tau`) unless `tau` is on the PATH the bridge's spawn
  environment sees. GUI apps frequently don't inherit your shell PATH, so
  the absolute path is the robust choice.
- If the spawned tau process needs credentials it can't get from
  `~/.config/tau/config.json`, put them in the `"env"` object — e.g.
  `"env": {"XIAOMI_API_KEY": "…"}` or `"env": {"TAU_API_KEY": "…"}`.

Both files also ship as
[`examples/clients/claude-code.json`](../../examples/clients/claude-code.json)
and [`examples/clients/mcacp.json`](../../examples/clients/mcacp.json).

## Finish in Claude Code

1. Make mcacp available: `npm i -g mcacp`, or leave it to `npx -y mcacp`.
2. Restart Claude Code — or open a new session — and run `/mcp`: the
   `mcacp` server (which drives the tau agent) should list as connected.
3. Ask Claude to use the tau agent — mcacp's session/prompt tools spawn
   `tau acp serve` and stream the exchange.

`tau doctor` reports the wiring as the `client_claude_code` check and
can repair a missing or stale user-scope entry with `tau doctor --fix`
(`wire_client_claude_code`).

## Removing the integration

`tau setup --remove --client claude-code` reverses all three pieces: the
`"mcacp"` entry is spliced out of `~/.claude.json` *and* the cwd's
`.mcp.json` (comments and sibling settings survive byte-for-byte; a file
left empty is deleted), and the shared `~/.config/mcacp/mcacp.json` entry
is dropped once no other MCP client still uses it. Setup-generated
snippets under `~/.config/tau/snippets/` are cleaned up too.

## See also

- [docs/acp.md](../acp.md) — the full ACP guide and the bridge architecture.
- [docs/editors.md](../editors.md) — every `tau setup --client` target.
- [docs/compatibility.md](../compatibility.md) — generated client matrix.
- [Claude Desktop](claude-desktop.md) · [Windsurf](windsurf.md) ·
  [Gemini CLI](gemini-cli.md) · [OpenCode](opencode.md) — the other
  MCP-bridge clients.
