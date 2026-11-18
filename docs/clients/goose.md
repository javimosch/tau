# Wire Goose to tau

[Block's Goose](https://block.github.io/goose/) is an MCP client — its
extensions speak MCP, not ACP — so `tau setup` wires it through the
[mcacp](https://github.com/Oortonaut/mcacp) MCP→ACP bridge:

```
Goose ──MCP(stdio)──> mcacp ──ACP(stdio)──> tau acp serve
```

Goose keeps extensions in YAML (`~/.config/goose/config.yaml`), not JSON —
setup can't splice a YAML file safely, so it does the half it can and
hands you the rest: the shared `~/.config/mcacp/mcacp.json` bridge config
is written for you, and a paste-ready YAML snippet lands under
`~/.config/tau/snippets/` for the `extensions:` block. One mcacp.json
serves every MCP client at once.

## Prerequisites

- `tau` installed and configured — `tau doctor` reports an ok provider and
  API key (see [docs/configuration.md](../configuration.md)).
- Node.js with `npx` on the PATH Goose sees — the bridge runs as
  `npx -y mcacp` (or install it once with `npm i -g mcacp`).

## One command

```bash
tau setup --client goose --yes
```

Setup reports a `"manual"` outcome for the Goose side (`"snippet_path"`
is the YAML to merge) and writes the bridge side itself
(`"bridge_path"` / `"bridge_status"`):

```json
{"client":"goose","status":"manual","snippet_path":"/home/you/.config/tau/snippets/goose.yaml","editor_detected":false,"next":"install mcacp (npm i -g mcacp or npx), merge the snippet into ~/.config/goose/config.yaml, then run 'goose session' and ask about the mcacp tools","bridge_path":"/home/you/.config/mcacp/mcacp.json","bridge_status":"installed"}
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

and the paste-ready Goose snippet at
`~/.config/tau/snippets/goose.yaml` — a Goose stdio `extensions:` entry
launching the bridge (`cmd`/`args`/`envs` are Goose's field names, not the
JSON MCP convention's `command`/`args`/`env`):

<!-- setup-verify: client-snippet -->
```yaml
# tau via the mcacp MCP->ACP bridge — merge into ~/.config/goose/config.yaml.
# If an "extensions:" map already exists, add just the inner "mcacp"
# entry to it; otherwise add the whole block. The bridge itself is
# configured separately — see snippets/mcacp.jsonc.
extensions:
  mcacp:
    type: stdio
    name: mcacp
    enabled: true
    cmd: npx
    args: ["-y", "mcacp"]
    envs: {}
    timeout: 300
```

> The fenced blocks above are verified — the `client-guides` smoke group
> ([scripts/check-client-guides.py](../../scripts/check-client-guides.py))
> diffs them byte-for-byte against real `tau setup --client` output in CI.

Merge the `mcacp` entry under `extensions:` in your
`~/.config/goose/config.yaml` by hand — if the file already has an
`extensions:` map, add only the inner entry to it — and restart Goose.

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

- The Goose extension block above goes in `~/.config/goose/config.yaml`
  (`%APPDATA%\Block\goose\config\config.yaml` on Windows; `$GOOSE_PATH_ROOT`
  or `$XDG_CONFIG_HOME` may move it).
- The bridge config goes at `~/.config/mcacp/mcacp.json` — replace
  `"command": "tau"` with the absolute path to your tau binary
  (`command -v tau`) unless `tau` is on the PATH the bridge's spawn
  environment sees.
- If the spawned tau process needs credentials it can't get from
  `~/.config/tau/config.json`, put them in the entry's `envs:` map — e.g.
  `envs: {"XIAOMI_API_KEY": "…"}`.

The bridge file also ships as
[`examples/clients/mcacp.json`](../../examples/clients/mcacp.json).

## Finish in Goose

1. Make mcacp available: `npm i -g mcacp`, or leave it to `npx -y mcacp`.
2. Merge the `mcacp` extension into `~/.config/goose/config.yaml` (or run
   `goose configure` and add a `stdio` extension with command
   `npx -y mcacp`).
3. Run `goose session` — tau's tools surface through the `mcacp`
   extension.

`tau doctor` reports a `client_goose` row as *manual only* — YAML wiring
can't be verified automatically — and points at the snippet path.

## Removing the integration

`tau setup --remove --client goose` deletes the generated snippet and the
shared bridge entry (kept if another MCP client still uses it), then
tells you to delete the `mcacp` extension block from `config.yaml` by
hand — YAML wiring is never spliced automatically.

## See also

- [docs/acp.md](../acp.md) — the full ACP guide and the bridge architecture.
- [docs/editors.md](../editors.md) — every `tau setup --client` target.
- [docs/compatibility.md](../compatibility.md) — generated client matrix.
- [Continue](continue.md) — the other YAML bridge client.
- [Windsurf](windsurf.md) · [Gemini CLI](gemini-cli.md) ·
  [Claude Desktop](claude-desktop.md) · [OpenCode](opencode.md) ·
  [Cline](cline.md) — the JSON MCP-bridge clients.
