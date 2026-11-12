# Wire JetBrains IDEs to tau

JetBrains AI Assistant ships with ACP support — no JetBrains AI
subscription required. `tau setup` writes the `agent_servers` entry its
custom-agent support reads:

```
JetBrains IDE ──ACP(stdio)──> tau acp serve
```

## Prerequisites

- A JetBrains IDE with AI Assistant 2025.1 or newer (IntelliJ IDEA,
  PyCharm, WebStorm, GoLand, CLion, …). Custom agents are not supported
  under WSL — use a native Windows or Linux/macOS install.
- `tau` installed and configured — `tau doctor` reports an ok provider and
  API key (see [docs/configuration.md](../configuration.md)).

## One command

```bash
tau setup --client jetbrains --yes
```

Setup reports the write in its clients step — `"path"` names the settings
file and `"next"` is the remaining in-editor step:

```json
{"client":"jetbrains","editor_detected":true,"path":"/home/you/.jetbrains/acp.json","status":"installed","command":"/abs/path/to/tau","next":"open the AI Chat tool window and pick tau in the agent selector"}
```

## What gets written

<!-- setup-verify: client-file -->
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

at `~/.jetbrains/acp.json` — the file AI Assistant's **Add Custom Agent**
action creates. When setup writes the file, `"command"` is the absolute
path to the tau binary it ran from — GUI apps can't resolve a bare `tau`
from your interactive shell's PATH.

Unlike Zed's `agent_servers`, JetBrains entries carry **no** `"type"`
field, and the file may hold an optional top-level
`"default_mcp_settings"` object that controls MCP passthrough.

> The fenced blocks above are verified — the `client-guides` smoke group
> ([scripts/check-client-guides.py](../../scripts/check-client-guides.py))
> diffs them byte-for-byte against real `tau setup --client` output in CI.

## Already have an acp.json?

Setup never rewrites an existing settings file — rewriting JSONC would
destroy your comments. When `acp.json` already exists it drops a
paste-ready snippet at `~/.config/tau/snippets/jetbrains.jsonc` instead
and reports `"status":"manual"`:

<!-- setup-verify: client-snippet -->
```jsonc
// tau ACP agent — merge into your jetbrains settings file.
// If a top-level "agent_servers" object already exists, add just the inner
// "tau" entry to it; otherwise add the whole block.
"agent_servers": {
  "tau": {
    "command": "tau",
    "args": ["acp", "serve"],
    "env": {}
  }
}
```

Merge the fragment into your `acp.json` by hand and restart the IDE.

## Manual setup

Paste the verified block above into place yourself:

- `~/.jetbrains/acp.json` is created by AI Chat's options button → **Add
  Custom Agent**, or just write it directly. If the file already has an
  `"agent_servers"` object, add only the inner `"tau"` entry to it.
- Replace `"command": "tau"` with the absolute path to your tau binary
  (`command -v tau`) unless `tau` is on the PATH the IDE's spawn
  environment sees.
- If the spawned tau process needs credentials it can't get from
  `~/.config/tau/config.json`, put them in the `"env"` object — e.g.
  `"env": {"XIAOMI_API_KEY": "…"}` or `"env": {"TAU_API_KEY": "…"}`.

The same file ships as
[`examples/clients/jetbrains.json`](../../examples/clients/jetbrains.json).

## Finish in the IDE

1. Open the **AI Chat** tool window.
2. Pick **tau** in the agent selector — the IDE spawns `tau acp serve`
   over stdio and the agent becomes available in the chat.

`tau doctor` reports the wiring as the `client_jetbrains` check and can
repair a missing or stale entry with `tau doctor --fix`.

## See also

- [docs/acp.md](../acp.md) — the full ACP guide.
- [docs/editors.md](../editors.md) — every `tau setup --client` target.
- [docs/compatibility.md](../compatibility.md) — generated client matrix.
- [Zed](zed.md) · [VS Code](vscode.md) · [Cursor](cursor.md) — the other
  direct-ACP clients.
