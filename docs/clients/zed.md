# Wire Zed to tau

Zed hosts external ACP agents natively — no extension needed (Zed created
the [Agent Client Protocol](https://agentclientprotocol.com)). `tau setup`
writes the `agent_servers` entry Zed's
[external agents](https://zed.dev/docs/ai/external-agents) support reads:

```
Zed ──ACP(stdio)──> tau acp serve
```

## Prerequisites

- `tau` installed and configured — `tau doctor` reports an ok provider and
  API key (see [docs/configuration.md](../configuration.md)).

## One command

```bash
tau setup --client zed --yes
```

Setup reports the write in its clients step — `"path"` names the settings
file and `"next"` is the remaining in-editor step:

```json
{"client":"zed","path":"/home/you/.config/zed/settings.json","status":"installed","command":"/abs/path/to/tau","next":"open the Agent Panel, click +, and pick tau"}
```

## What gets written

<!-- setup-verify: client-file -->
```json
{
  "agent_servers": {
    "tau": {
      "type": "custom",
      "command": "tau",
      "args": ["acp", "serve"],
      "env": {}
    }
  }
}
```

at `~/.config/zed/settings.json` (`$XDG_CONFIG_HOME/zed/settings.json` when
`XDG_CONFIG_HOME` is set, `%APPDATA%\Zed\settings.json` on Windows). When
setup writes the file, `"command"` is the absolute path to the tau binary it
ran from — GUI editors can't resolve a bare `tau` from your interactive
shell's PATH.

Zed requires `"type": "custom"` on every `agent_servers` entry — the other
clients' sections don't carry a type field. `tau doctor` flags a wired tau
entry missing it as stale (`zed entries need "type": "custom"`).

> The fenced blocks above are verified — the `client-guides` smoke group
> ([scripts/check-client-guides.py](../../scripts/check-client-guides.py))
> diffs them byte-for-byte against real `tau setup --client` output in CI.

## Already have a settings file?

Setup never rewrites an existing settings file — rewriting JSONC would
destroy your comments. When `settings.json` already exists it drops a
paste-ready snippet at `~/.config/tau/snippets/zed.jsonc` instead and
reports `"status":"manual"`:

<!-- setup-verify: client-snippet -->
```jsonc
// tau ACP agent — merge into your zed settings file.
// If a top-level "agent_servers" object already exists, add just the inner
// "tau" entry to it; otherwise add the whole block.
"agent_servers": {
  "tau": {
    "type": "custom",
    "command": "tau",
    "args": ["acp", "serve"],
    "env": {}
  }
}
```

Merge the fragment into your settings file by hand and restart Zed.

## Manual setup

Paste the verified block above into place yourself:

- Zed's `settings.json` lives under `~/.config/zed/` (see the platform
  paths above). If the file already has an `"agent_servers"` object, add
  only the inner `"tau"` entry to it — and keep `"type": "custom"`, it's
  required.
- Replace `"command": "tau"` with the absolute path to your tau binary
  (`command -v tau`) unless `tau` is on the PATH Zed's spawn environment
  sees.
- If the spawned tau process needs credentials it can't get from
  `~/.config/tau/config.json`, put them in the `"env"` object — e.g.
  `"env": {"XIAOMI_API_KEY": "…"}` or `"env": {"TAU_API_KEY": "…"}`.

The same file ships as
[`examples/clients/zed.json`](../../examples/clients/zed.json).

## Finish in Zed

1. Open the Agent Panel.
2. Click **+** and pick **tau** — Zed spawns `tau acp serve` over stdio and
   the agent becomes available in the panel.

`tau doctor` reports the wiring as the `client_zed` check and can repair a
missing or stale entry with `tau doctor --fix`.

## See also

- [docs/acp.md](../acp.md) — the full ACP guide.
- [docs/editors.md](../editors.md) — every `tau setup --client` target.
- [docs/compatibility.md](../compatibility.md) — generated client matrix.
- [VS Code](vscode.md) · [Cursor](cursor.md) — the other direct-ACP clients.
