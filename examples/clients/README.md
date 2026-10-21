# tau — client configs

Ready-to-paste settings files that wire an editor or desktop app to
`tau acp serve`. Every file is a complete minimal document — copy it into the
client's settings path, adjust `"command"` if `tau` is not on the `PATH` the
client sees, and restart the client.

`tau setup --client` writes these same files for you (`zed`, `vscode`,
`jetbrains`, `all`; `nvim` gets a paste-ready Lua snippet instead):

```bash
tau setup --client zed --yes     # writes ~/.config/zed/settings.json
tau setup --client all --yes     # every supported client at once
```

These examples are verified in CI: the `client-examples` smoke group runs
`tau setup --client <name> --yes` in a scratch HOME and diffs the generated
settings byte-for-byte against the files below (the absolute `command` path is
normalized to `tau`), validates the tau config that setup writes with
`tau config validate`, and JSON-parses every file in this directory.

## The files

| File | Client | Merge into |
|------|--------|------------|
| `zed.json` | [Zed](https://zed.dev) | `~/.config/zed/settings.json` (`%APPDATA%\Zed\settings.json` on Windows) |
| `vscode.json` | VS Code + [ACP Client](https://marketplace.visualstudio.com/items?itemName=formulahendry.acp-client) extension | `~/.config/Code/User/settings.json` (Linux), `~/Library/Application Support/Code/User/settings.json` (macOS), `%APPDATA%\Code\User\settings.json` (Windows) |
| `cursor.json` | [Cursor](https://cursor.com) + the same ACP Client extension from Open VSX | `~/.config/Cursor/User/settings.json` (Linux), `~/Library/Application Support/Cursor/User/settings.json` (macOS), `%APPDATA%\Cursor\User\settings.json` (Windows) |
| `jetbrains.json` | JetBrains IDEs (AI Assistant 2025.1+) | `~/.jetbrains/acp.json` |
| `claude-desktop.json` + `mcacp.json` | Claude Desktop via the [mcacp](https://github.com/Oortonaut/mcacp) MCP↔ACP bridge | `claude_desktop_config.json` (`~/Library/Application Support/Claude/` on macOS, `%APPDATA%\Claude\` on Windows) + `~/.config/mcacp/mcacp.json` |

If the target file already exists, merge the `"tau"` entry into the existing
section instead of replacing the file — `tau setup --client` never rewrites an
existing settings file and drops a paste-ready snippet in
`~/.config/tau/snippets/` instead.

## Three things that matter everywhere

1. **`command` must resolve in the client's spawn environment.** A bare
   `"tau"` only works when the editor inherits your shell `PATH`. GUI apps
   frequently don't — when in doubt use the absolute path
   (`tau setup --client` writes the absolute path automatically).
2. **`args` stays exactly `["acp", "serve"]`.** The `acp` subcommand is parsed
   separately and rejects regular flags like `--provider` or `--model`.
   Provider, model, and keys come from `~/.config/tau/config.json` and the
   environment — put `TAU_API_KEY`, a provider key, or `TAU_ENDPOINT` in the
   `env` block if the spawned process needs them.
3. **tau never needs editing in the client file beyond that.** One entry,
   three fields, done.

## Claude Desktop is a bridge, not a direct connection

Claude Desktop speaks MCP, not ACP — it can't spawn `tau acp serve` directly.
The [mcacp](https://github.com/Oortonaut/mcacp) bridge sits in the middle:

```
Claude Desktop ──MCP(stdio)──> mcacp ──ACP(stdio)──> tau acp serve
```

1. Merge `claude-desktop.json` into `claude_desktop_config.json` (adds the
   `mcacp` MCP server, launched with `npx`).
2. Copy `mcacp.json` to `~/.config/mcacp/mcacp.json` — this is where the
   bridge learns that `tau` means `tau acp serve`. The `agent_servers` shape
   matches Zed/JetBrains, so the same entry can be copied between them.
3. Restart Claude Desktop, then ask it to use the tau agent — mcacp exposes
   session/prompt tools that spawn and drive tau.

Other MCP↔ACP bridges (e.g.
[`@theorionic/mcp-acp-bridge`](https://github.com/theorionic/mcp-acp-bridge))
work the same way — only the agent-declaration file differs.

## See also

- [docs/acp.md](../../docs/acp.md) — the full ACP guide: every supported
  client, what the editor sees, troubleshooting.
- [docs/configuration.md](../../docs/configuration.md) — provider, model, and
  API-key resolution for the spawned `tau` process.
