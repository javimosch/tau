# tau — client configs

Ready-to-paste settings files that wire an editor or desktop app to
`tau acp serve`. Every file is a complete minimal document — copy it into the
client's settings path, adjust `"command"` if `tau` is not on the `PATH` the
client sees, and restart the client.

`tau setup --client` writes these same files for you (`zed`, `vscode`,
`jetbrains`, `windsurf`, `gemini`, `claude-desktop`, `all`; `nvim` gets a
paste-ready Lua snippet instead). MCP-only clients also get the shared
bridge config `~/.config/mcacp/mcacp.json` written in the same pass:

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
| `windsurf.json` + `mcacp.json` | [Windsurf](https://windsurf.com) via the [mcacp](https://github.com/Oortonaut/mcacp) MCP↔ACP bridge | `~/.codeium/windsurf/mcp_config.json` + `~/.config/mcacp/mcacp.json` |
| `gemini.json` + `mcacp.json` | [Gemini CLI](https://github.com/google-gemini/gemini-cli) via the same mcacp bridge | `~/.gemini/settings.json` + `~/.config/mcacp/mcacp.json` |
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

## MCP clients are a bridge, not a direct connection

Windsurf, Gemini CLI, and Claude Desktop speak MCP, not ACP — they can't
spawn `tau acp serve` directly.
The [mcacp](https://github.com/Oortonaut/mcacp) bridge sits in the middle:

```
Windsurf / Gemini CLI / Claude Desktop ──MCP(stdio)──> mcacp ──ACP(stdio)──> tau acp serve
```

1. Merge the client's file into its settings path (`windsurf.json`,
   `gemini.json`, or `claude-desktop.json`) — each adds the `mcacp` MCP
   server, launched with `npx`.
2. Copy `mcacp.json` to `~/.config/mcacp/mcacp.json` — this is where the
   bridge learns that `tau` means `tau acp serve`. The `agent_servers` shape
   matches Zed/JetBrains, so the same entry can be copied between them. One
   file serves every MCP client at once.
3. Restart the client: Windsurf lists `mcacp` under Settings > MCP servers,
   Gemini CLI shows its tools under `/mcp`, and Claude Desktop exposes the
   tau agent under the mcacp server's tools.

Other MCP↔ACP bridges (e.g.
[`@theorionic/mcp-acp-bridge`](https://github.com/theorionic/mcp-acp-bridge))
work the same way — only the agent-declaration file differs.

## See also

- [docs/acp.md](../../docs/acp.md) — the full ACP guide: every supported
  client, what the editor sees, troubleshooting.
- [docs/configuration.md](../../docs/configuration.md) — provider, model, and
  API-key resolution for the spawned `tau` process.
