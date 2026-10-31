# Wire Cursor to tau

Cursor is VS Code-compatible — the same
[ACP Client](https://open-vsx.org/extension/formulahendry/acp-client)
extension from the Open VSX registry adds ACP support, and the config shape
is identical to VS Code's (`acp.agents`). `tau setup` writes the entry into
Cursor's own user settings:

```
Cursor + ACP Client extension ──ACP(stdio)──> tau acp serve
```

## Prerequisites

- `tau` installed and configured — `tau doctor` reports an ok provider and
  API key (see [docs/configuration.md](../configuration.md)).

## One command

```bash
tau setup --client cursor --yes
```

Setup reports the write in its clients step — `"path"` names the settings
file and `"next"` is the remaining in-editor step:

```json
{"client":"cursor","path":"/home/you/.config/Cursor/User/settings.json","status":"installed","command":"/abs/path/to/tau","next":"install the ACP Client extension (Open VSX), run 'ACP: Connect to Agent', pick tau"}
```

## What gets written

<!-- setup-verify: client-file -->
```json
{
  "acp.agents": {
    "tau": {
      "command": "tau",
      "args": ["acp", "serve"],
      "env": {}
    }
  }
}
```

at `~/.config/Cursor/User/settings.json` (`~/Library/Application
Support/Cursor/User/settings.json` on macOS,
`%APPDATA%\Cursor\User\settings.json` on Windows). When setup writes the
file, `"command"` is the absolute path to the tau binary it ran from — GUI
editors can't resolve a bare `tau` from your interactive shell's PATH.

> The fenced blocks above are verified — the `client-guides` smoke group
> ([scripts/check-client-guides.py](../../scripts/check-client-guides.py))
> diffs them byte-for-byte against real `tau setup --client` output in CI.

## Already have a settings file?

Setup never rewrites an existing settings file — rewriting JSONC would
destroy your comments. When `settings.json` already exists it drops a
paste-ready snippet at `~/.config/tau/snippets/cursor.jsonc` instead and
reports `"status":"manual"`:

<!-- setup-verify: client-snippet -->
```jsonc
// tau ACP agent — merge into your cursor settings file.
// If a top-level "acp.agents" object already exists, add just the inner
// "tau" entry to it; otherwise add the whole block.
"acp.agents": {
  "tau": {
    "command": "tau",
    "args": ["acp", "serve"],
    "env": {}
  }
}
```

Merge the fragment into your settings file by hand and restart Cursor.

## Manual setup

Paste the verified block above into place yourself:

- Cursor's `settings.json` lives under `~/.config/Cursor/User/` (see the
  platform paths above). If the file already has an `"acp.agents"` object,
  add only the inner `"tau"` entry to it.
- Replace `"command": "tau"` with the absolute path to your tau binary
  (`command -v tau`) unless `tau` is on the PATH the extension's spawn
  environment sees.
- If the spawned tau process needs credentials it can't get from
  `~/.config/tau/config.json`, put them in the `"env"` object — e.g.
  `"env": {"XIAOMI_API_KEY": "…"}` or `"env": {"TAU_API_KEY": "…"}`.

The same file ships as
[`examples/clients/cursor.json`](../../examples/clients/cursor.json).

## Finish in Cursor

1. Install the
   [ACP Client](https://open-vsx.org/extension/formulahendry/acp-client)
   extension (Open VSX registry).
2. Run **ACP: Connect to Agent** from the Command Palette and pick `tau`.
3. Run **ACP: New Conversation** — the extension spawns
   `tau acp serve` over stdio and the agent appears in the sidebar.

`tau doctor` reports the wiring as the `client_cursor` check and can repair
a missing or stale entry with `tau doctor --fix`.

## See also

- [docs/acp.md](../acp.md) — the full ACP guide.
- [docs/editors.md](../editors.md) — every `tau setup --client` target.
- [docs/compatibility.md](../compatibility.md) — generated client matrix.
- [VS Code](vscode.md) — the same `acp.agents` shape in VS Code's settings.
