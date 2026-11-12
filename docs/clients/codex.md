# Wire Codex CLI to tau

[OpenAI's Codex CLI](https://github.com/openai/codex) is an MCP client —
its servers speak MCP, not ACP — so `tau setup` wires it through the
[mcacp](https://github.com/Oortonaut/mcacp) MCP→ACP bridge:

```
Codex ──MCP(stdio)──> mcacp ──ACP(stdio)──> tau acp serve
```

Codex keeps MCP servers in TOML — one `[mcp_servers.<name>]` table each in
`~/.codex/config.toml` — not JSON, so setup can't splice the file safely.
It does the half it can and hands you the rest: the shared
`~/.config/mcacp/mcacp.json` bridge config is written for you, and a
paste-ready TOML snippet lands under `~/.config/tau/snippets/`. One
mcacp.json serves every MCP client at once.

## Prerequisites

- `tau` installed and configured — `tau doctor` reports an ok provider and
  API key (see [docs/configuration.md](../configuration.md)).
- Node.js with `npx` on the PATH Codex sees — the bridge runs as
  `npx -y mcacp` (or install it once with `npm i -g mcacp`).

## One command

```bash
tau setup --client codex --yes
```

Setup reports a `"manual"` outcome for the Codex side (`"snippet_path"`
is the TOML to merge) and writes the bridge side itself
(`"bridge_path"` / `"bridge_status"`):

```json
{"client":"codex","editor_detected":false,"note":"codex does not look installed (no /home/you/.codex) — the config is pre-staged and activates once codex is installed; run 'tau setup --detect' to list detected clients","status":"manual","snippet_path":"/home/you/.config/tau/snippets/codex.toml","next":"install mcacp (npm i -g mcacp or npx), merge the snippet into ~/.codex/config.toml, then run 'codex mcp list' to confirm the mcacp server","bridge_path":"/home/you/.config/mcacp/mcacp.json","bridge_status":"installed"}
```

## What gets written

The shared bridge config at `~/.config/mcacp/mcacp.json` (`"command"` is
the absolute path to the tau binary setup ran from):

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

and the paste-ready Codex snippet at
`~/.config/tau/snippets/codex.toml` — one `[mcp_servers.mcacp]` table
launching the bridge:

<!-- setup-verify: client-snippet -->
```toml
# tau via the mcacp MCP->ACP bridge — merge into ~/.codex/config.toml.
# Each MCP server is its own [mcp_servers.<name>] table — paste this
# one alongside your other servers (or run 'codex mcp add mcacp --
# npx -y mcacp'). The bridge itself is configured separately — see
# snippets/mcacp.jsonc.
[mcp_servers.mcacp]
command = "npx"
args = ["-y", "mcacp"]
```

> The fenced blocks above are verified — the `client-guides` smoke group
> ([scripts/check-client-guides.py](../../scripts/check-client-guides.py))
> diffs them byte-for-byte against real `tau setup --client` output in CI.

Merge the `[mcp_servers.mcacp]` table into your `~/.codex/config.toml` by
hand — each MCP server is its own table, so it sits alongside any
`[mcp_servers.*]` tables you already have — and restart Codex.

An existing `mcacp.json` that lacks the tau entry gets
`~/.config/tau/snippets/mcacp.jsonc` instead of a rewritten file:

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

## Manual setup

- The `[mcp_servers.mcacp]` table above goes in `~/.codex/config.toml`
  (a project-scoped `.codex/config.toml` works too, but Codex only reads
  it in trusted projects; `codex mcp add` always writes the global file).
- The bridge config goes at `~/.config/mcacp/mcacp.json` — replace
  `"command": "tau"` with the absolute path to your tau binary
  (`command -v tau`) unless `tau` is on the PATH the bridge's spawn
  environment sees.
- If the spawned tau process needs credentials it can't get from
  `~/.config/tau/config.json`, put them in the table's `env` map — e.g.
  `env = { "XIAOMI_API_KEY" = "…" }`.

The bridge file also ships as
[`examples/clients/mcacp.json`](../../examples/clients/mcacp.json).

## Finish in Codex

1. Make mcacp available: `npm i -g mcacp`, or leave it to `npx -y mcacp`.
2. Merge the `[mcp_servers.mcacp]` table into `~/.codex/config.toml` (or
   run `codex mcp add mcacp -- npx -y mcacp` to have Codex write it).
3. Run `codex mcp list` — the `mcacp` server should appear; tau's tools
   surface through it in `codex` sessions.

`tau doctor` reports a `client_codex` row as *manual only* — TOML wiring
can't be verified automatically — and points at the snippet path.

## Removing the integration

`tau setup --remove --client codex` deletes the generated snippet and the
shared bridge entry (kept if another MCP client still uses it), then
tells you to delete the `[mcp_servers.mcacp]` table from `config.toml` by
hand — TOML wiring is never spliced automatically.

## See also

- [docs/acp.md](../acp.md) — the full ACP guide and the bridge architecture.
- [docs/editors.md](../editors.md) — every `tau setup --client` target.
- [docs/compatibility.md](../compatibility.md) — generated client matrix.
- [Goose](goose.md) · [Continue](continue.md) — the other paste-snippet
  bridge clients.
- [Windsurf](windsurf.md) · [Gemini CLI](gemini-cli.md) ·
  [Claude Desktop](claude-desktop.md) · [OpenCode](opencode.md) ·
  [Cline](cline.md) — the JSON MCP-bridge clients.
