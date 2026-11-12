# Wire Continue to tau

[Continue](https://continue.dev) — the VS Code / JetBrains extension — is
an MCP client: its `mcpServers` config speaks MCP, not ACP, so `tau setup`
wires it through the [mcacp](https://github.com/Oortonaut/mcacp) MCP→ACP
bridge:

```
Continue ──MCP(stdio)──> mcacp ──ACP(stdio)──> tau acp serve
```

Continue keeps `mcpServers` in YAML (`~/.continue/config.yaml`), not
JSON — setup can't splice a YAML file safely, so it does the half it can
and hands you the rest: the shared `~/.config/mcacp/mcacp.json` bridge
config is written for you, and a paste-ready YAML snippet lands under
`~/.config/tau/snippets/` for the `mcpServers:` list item. One mcacp.json
serves every MCP client at once.

## Prerequisites

- `tau` installed and configured — `tau doctor` reports an ok provider and
  API key (see [docs/configuration.md](../configuration.md)).
- Node.js with `npx` on the PATH Continue sees — the bridge runs as
  `npx -y mcacp` (or install it once with `npm i -g mcacp`).

## One command

```bash
tau setup --client continue --yes
```

Setup reports a `"manual"` outcome for the Continue side (`"snippet_path"`
is the YAML to merge) and writes the bridge side itself
(`"bridge_path"` / `"bridge_status"`):

```json
{"client":"continue","editor_detected":false,"note":"continue does not look installed (no /home/you/.continue) — the config is pre-staged and activates once continue is installed; run 'tau setup --detect' to list detected clients","status":"manual","snippet_path":"/home/you/.config/tau/snippets/continue.yaml","next":"install mcacp (npm i -g mcacp or npx), merge the snippet into ~/.continue/config.yaml, restart Continue, and use agent mode to see tau's tools","bridge_path":"/home/you/.config/mcacp/mcacp.json","bridge_status":"installed"}
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

and the paste-ready Continue snippet at
`~/.config/tau/snippets/continue.yaml` — a `mcpServers:` list entry
launching the bridge:

<!-- setup-verify: client-snippet -->
```yaml
# tau via the mcacp MCP->ACP bridge — merge into ~/.continue/config.yaml.
# If a top-level "mcpServers:" list already exists, append just the
# list item to it; otherwise add the whole block. The bridge itself
# is configured separately — see snippets/mcacp.jsonc.
mcpServers:
  - name: mcacp
    command: npx
    args:
      - "-y"
      - "mcacp"
    env: {}
```

> The fenced blocks above are verified — the `client-guides` smoke group
> ([scripts/check-client-guides.py](../../scripts/check-client-guides.py))
> diffs them byte-for-byte against real `tau setup --client` output in CI.

Append the list item to `mcpServers:` in your `~/.continue/config.yaml` —
or drop the JSON form (`examples/clients/cline.json`-style
`{"mcpServers": {"mcacp": {...}}}`) into `~/.continue/mcpServers/` and
Continue picks it up — then restart Continue. MCP tools are only
available in agent mode.

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

- The Continue server block above goes in `~/.continue/config.yaml`
  (`%USERPROFILE%\.continue\config.yaml` on Windows).
- The bridge config goes at `~/.config/mcacp/mcacp.json` — replace
  `"command": "tau"` with the absolute path to your tau binary
  (`command -v tau`) unless `tau` is on the PATH the bridge's spawn
  environment sees.
- If the spawned tau process needs credentials it can't get from
  `~/.config/tau/config.json`, put them in the entry's `env:` map — e.g.
  `env: {"XIAOMI_API_KEY": "…"}`.

The bridge file also ships as
[`examples/clients/mcacp.json`](../../examples/clients/mcacp.json).

## Finish in Continue

1. Make mcacp available: `npm i -g mcacp`, or leave it to `npx -y mcacp`.
2. Merge the `mcacp` server into `~/.continue/config.yaml` (or drop a
   `{"mcpServers": {"mcacp": {...}}}` JSON file into
   `~/.continue/mcpServers/`).
3. Restart Continue and switch to agent mode — tau's tools surface
   through the `mcacp` server.

`tau doctor` reports a `client_continue` row as *manual only* — YAML
wiring can't be verified automatically — and points at the snippet path.

## Removing the integration

`tau setup --remove --client continue` deletes the generated snippet and
the shared bridge entry (kept if another MCP client still uses it), then
tells you to delete the `mcacp` list item from `config.yaml` by hand —
YAML wiring is never spliced automatically.

## See also

- [docs/acp.md](../acp.md) — the full ACP guide and the bridge architecture.
- [docs/editors.md](../editors.md) — every `tau setup --client` target.
- [docs/compatibility.md](../compatibility.md) — generated client matrix.
- [Goose](goose.md) — the other YAML bridge client.
- [Windsurf](windsurf.md) · [Gemini CLI](gemini-cli.md) ·
  [Claude Desktop](claude-desktop.md) · [OpenCode](opencode.md) ·
  [Cline](cline.md) — the JSON MCP-bridge clients.
