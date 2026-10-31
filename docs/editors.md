# Editor setup: tau as an ACP agent, step by step

`tau acp serve` speaks the [Agent Client Protocol](https://agentclientprotocol.com)
over stdio, so ACP-compatible editors can drive tau as a coding agent. The
fastest way to wire one up is `tau setup --client <editor>`; this guide walks
through exactly what that command does for **Zed**, **VS Code**, **Cursor**,
**Neovim**, and the MCP clients (**Windsurf**, **Gemini CLI**, **Claude Desktop**),
what its output means, and how to finish or undo each step by hand.

For JetBrains IDEs, Emacs (agent-shell), Toad, socket mode, and a description of
what the editor sees once connected, see [docs/acp.md](acp.md).

## How `tau setup --client` works

```bash
tau setup                      # detect editors, write nothing
tau setup --client zed         # configure one editor
tau setup --client vscode      # (or the alias: --client code)
tau setup --client cursor      # same acp.agents shape, Cursor's settings dir
tau setup --client nvim        # writes a paste-ready Lua snippet
tau setup --client windsurf    # MCP client — also writes mcacp.json
tau setup --client all         # every supported client at once
tau setup --client all --dry-run  # preview every write, change nothing
```

`--dry-run` composes with all of the above: the same NDJSON plan is emitted
with `would_install` statuses and `"dry_run":true` markers, and no file is
created or modified — useful to check which editor config files setup would
touch before letting it.

Anything else is rejected before setup runs:

```json
{"err":{"code":80,"type":"invalid_argument","message":"invalid --client: bogus (want zed|nvim|vscode|cursor|jetbrains|windsurf|gemini|claude-desktop|all)","recoverable":false}}
```

Setup emits one NDJSON object per step. The `clients` step is the one this
guide covers:

- **Without `--client`** the step only *reports* which supported editors appear
  installed (their config directories exist) — detection alone never writes:

```json
{"step":"clients","status":"skipped","detected":["zed","nvim","vscode"],"hint":"re-run with --client zed|nvim|vscode|cursor|jetbrains|windsurf|gemini|claude-desktop|all to write editor ACP config"}
```

- **With `--client`** each requested editor gets a `clients[]` entry carrying
  one of four statuses:

| `status` | Meaning |
|---|---|
| `installed` | A minimal settings file was written (none existed). |
| `already_installed` | Your settings file already has a `tau` entry — untouched. |
| `manual` | Setup couldn't safely edit in place; it wrote a paste-ready snippet under `~/.config/tau/snippets/` instead. The entry's `reason` field says why. |
| `failed` | A write failed (see the `message` field). |

The step status is `installed`, `manual`, `skipped`, or `failed`. A `manual`
outcome still passes the overall setup verdict — it means "your turn to
paste", not "broken" — while `failed` fails the run (exit 1).

Two rules hold for every editor:

- **`command` is an absolute path.** GUI editors often can't resolve a bare
  `tau` from `PATH`, so setup pins the full path of the running binary
  (e.g. `/home/you/tau/zig-out/bin/tau`).
- **`args` is exactly `["acp", "serve"]`.** The `acp` subcommand rejects
  regular flags — provider, model, and API keys come from
  `~/.config/tau/config.json` and the environment. Put secrets in the client
  config's `env` map or in the config file, never in `args`. See
  [docs/configuration.md](configuration.md).

## Zed

```bash
tau setup --client zed
```

**Fresh settings (no `~/.config/zed/settings.json`):** setup writes a minimal
file —

```json
{
  "agent_servers": {
    "tau": {
      "type": "custom",
      "command": "/abs/path/to/tau",
      "args": ["acp", "serve"],
      "env": {}
    }
  }
}
```

— and reports:

```json
{"client":"zed","path":"/home/you/.config/zed/settings.json","status":"installed","command":"/abs/path/to/tau","next":"open the Agent Panel, click +, and pick tau"}
```

**Existing settings:** if your `settings.json` already exists, setup never
rewrites it (it's JSONC — rewriting would destroy your comments). Instead it
writes `~/.config/tau/snippets/zed.jsonc`:

```jsonc
// tau ACP agent — merge into your zed settings file.
// If a top-level "agent_servers" object already exists, add just the inner
// "tau" entry to it; otherwise add the whole block.
"agent_servers": {
  "tau": {
    "type": "custom",
    "command": "/abs/path/to/tau",
    "args": ["acp", "serve"],
    "env": {}
  }
}
```

and reports `status:"manual"` with a `reason` (`existing settings file has no
"tau" entry`, `existing settings file did not parse as JSON/JSONC`, or
`could not read the existing settings file`). Merge the block into
`~/.config/zed/settings.json` by hand — note the `"type": "custom"` line,
which Zed requires and the other clients don't.

**Finish in Zed:** open the Agent Panel, click **+**, and pick **tau**. That is
the `next` hint in the transcript.

Re-running `tau setup --client zed` is safe — once a `tau` entry exists it
reports `already_installed` and changes nothing.

## VS Code

```bash
tau setup --client vscode    # `--client code` works too
```

**Fresh settings (no `~/.config/Code/User/settings.json`):** setup writes:

```json
{
  "acp.agents": {
    "tau": {
      "command": "/abs/path/to/tau",
      "args": ["acp", "serve"],
      "env": {}
    }
  }
}
```

and reports `status:"installed"` with `next:"install the ACP Client extension,
run 'ACP: Connect to Agent', pick tau"`.

**Existing settings:** as with Zed, setup won't touch a file that already
exists — it drops `~/.config/tau/snippets/vscode.jsonc` for you to merge:

```jsonc
// tau ACP agent — merge into your vscode settings file.
// If a top-level "acp.agents" object already exists, add just the inner
// "tau" entry to it; otherwise add the whole block.
"acp.agents": {
  "tau": {
    "command": "/abs/path/to/tau",
    "args": ["acp", "serve"],
    "env": {}
  }
}
```

**Finish in VS Code:**

1. Install the [ACP Client](https://marketplace.visualstudio.com/items?itemName=formulahendry.acp-client)
   extension.
2. Run **ACP: Connect to Agent** from the Command Palette and pick `tau`.
3. Run **ACP: New Conversation**.

The extension spawns tau itself, so the absolute `command` path matters more
than your interactive shell's `PATH`. If you launch VS Code from a shell where
`tau` resolves, a bare `"command": "tau"` also works.

## Cursor

```bash
tau setup --client cursor
```

Cursor is VS Code-compatible — the same `acp.agents` shape, in Cursor's own
settings file at `~/.config/Cursor/User/settings.json` (`~/Library/Application
Support/Cursor/User/settings.json` on macOS,
`%APPDATA%\Cursor\User\settings.json` on Windows). Everything from the VS Code
section applies; the only differences are the file path and the extension
source — Cursor pulls the ACP Client extension from the
[Open VSX](https://open-vsx.org/extension/formulahendry/acp-client) registry.
The step-by-step guide is [docs/clients/cursor.md](clients/cursor.md).

## Neovim

```bash
tau setup --client nvim
```

Neovim is always a `manual` outcome — ACP plugins are configured in Lua and
splicing arbitrary user config isn't safe, so setup writes
`~/.config/tau/snippets/nvim.lua` and reports:

```json
{"client":"nvim","status":"manual","snippet_path":"/home/you/.config/tau/snippets/nvim.lua","editor_detected":true,"next":"pick the tau provider/adapter in your plugin (e.g. :AvanteSwitchProvider)"}
```

`editor_detected` tells you whether `~/.config/nvim` exists. The generated
snippet covers both popular plugins — paste the block for yours into your
Neovim config and restart:

- **avante.nvim** — an `acp_providers` entry (`provider = "tau"`, `command`,
  `args = { "acp", "serve" }`, `env`). If tau isn't the default provider, pick
  it with `:AvanteSwitchProvider`.
- **CodeCompanion.nvim** — a complete custom ACP adapter table
  (`type = "acp"`, `commands.default`, `protocolVersion = 1`, `form_messages`
  handler). Select the `tau` adapter in a chat buffer, or set it as the
  default chat adapter.

The full snippet and per-plugin notes live in [docs/acp.md](acp.md).

## MCP clients: Windsurf, Gemini CLI, Claude Desktop

These clients speak MCP, not ACP — they can't spawn `tau acp serve`
directly. Setup wires them through the
[mcacp](https://github.com/Oortonaut/mcacp) MCP→ACP bridge and writes **two**
files in one pass:

```bash
tau setup --client windsurf        # or gemini, claude-desktop
```

1. The client's `mcpServers` entry launches the bridge — at
   `~/.codeium/windsurf/mcp_config.json`, `~/.gemini/settings.json`, or
   `~/.config/Claude/claude_desktop_config.json`:

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

2. The shared bridge config `~/.config/mcacp/mcacp.json` carries the real
   `agent_servers.tau` entry (the direct-ACP shape with the absolute
   `command` path). One file serves every MCP client at once.

The step entry reports both halves — `"path"`/`"status"` for the client file
and `"bridge_path"`/`"bridge_status"` for mcacp.json (with
`"bridge_snippet_path"` when the existing bridge config needed a manual
merge):

```json
{"client":"gemini","path":"/home/you/.gemini/settings.json","status":"installed","command":"/abs/path/to/tau","next":"install mcacp (npm i -g mcacp or npx), restart Gemini CLI, and run /mcp to see tau's tools","bridge_path":"/home/you/.config/mcacp/mcacp.json","bridge_status":"installed"}
```

`--client all` writes the client entry for each bridge client but only
creates `mcacp.json` once — the later clients report
`"bridge_status":"already_installed"`.

Dedicated per-client guides — each with the exact file contents
`tau setup --client` writes (drift-checked in CI against the real output):

- [VS Code](clients/vscode.md)
- [Cursor](clients/cursor.md)
- [Windsurf](clients/windsurf.md)
- [Gemini CLI](clients/gemini-cli.md)
- [Claude Desktop](clients/claude-desktop.md)

## Removing the integration

Setup is additive and never deletes:

- **Zed / VS Code / Cursor:** delete the `"tau"` entry from your settings
  file (or the whole file if setup created a minimal one just for tau).
- **Windsurf / Gemini CLI / Claude Desktop:** delete the `"mcacp"` entry from
  the client's `mcpServers` section; delete `~/.config/mcacp/mcacp.json` when
  no other MCP client still uses it.
- **Neovim:** remove the pasted block from your config.
- Generated snippets under `~/.config/tau/snippets/` are inert leftovers —
  delete them freely.

## Config file autocomplete

The same JSON language server your editor already uses for `settings.json`
can autocomplete and validate `~/.config/tau/config.json` — the file is JSONC
(comments allowed) and has a published JSON Schema.

`tau init` writes a `"$schema"` key into the scaffold, so a fresh config gets
key suggestions, hover docs, and squiggles out of the box — no editor setting
needed, in Zed and VS Code alike:

```jsonc
{
  // Resolved by the editor's JSON language server; ignored by tau.
  "$schema": "https://raw.githubusercontent.com/javimosch/tau/master/schema/tau-config.schema.json",
  "provider": "xiaomi"
}
```

For a config that predates `tau init`, add the same `"$schema"` line by hand —
`tau config validate` accepts it (string only; a non-string value is
flagged). If you'd rather not touch the file, bind the schema by path
instead:

- **VS Code** — in `settings.json`:

  ```json
  "json.schemas": [
    {
      "fileMatch": ["**/.config/tau/config.json"],
      "url": "https://raw.githubusercontent.com/javimosch/tau/master/schema/tau-config.schema.json"
    }
  ]
  ```

- **Zed** — same idea, routed through the JSON language server settings:

  ```jsonc
  "lsp": {
    "json-language-server": {
      "settings": {
        "json": {
          "schemas": [
            {
              "fileMatch": ["*/.config/tau/config.json"],
              "url": "https://raw.githubusercontent.com/javimosch/tau/master/schema/tau-config.schema.json"
            }
          ]
        }
      }
    }
  }
  ```

- **Neovim (jsonls)** — pass a schema association in the server settings:

  ```lua
  require("lspconfig").jsonls.setup({
    settings = {
      json = {
        schemas = {
          { fileMatch = { "*/.config/tau/config.json" },
            url = "https://raw.githubusercontent.com/javimosch/tau/master/schema/tau-config.schema.json" },
        },
      },
    },
  })
  ```

- **Offline / pinned** — `tau config schema` prints the document itself;
  save it (`tau config schema > tau-config.schema.json`) and point
  `$schema`/`url` at the local file. It also prints a one-line `note:`
  hint on stderr reminding you to wire the `$schema` key — stdout stays a
  pure JSON Schema for piping.

- **SchemaStore (path-matched, zero-config)** — the catalog entry
  submitted to [schemastore.org](https://www.schemastore.org/) is checked
  in at
  [schema/schemastore-catalog-entry.json](../schema/schemastore-catalog-entry.json).
  Once it lands upstream, SchemaStore-backed editors match
  `~/.config/tau/config.json` by path, so autocomplete works with no
  `$schema` key or `json.schemas` setting at all.

The schema is generated from the same `FileConfig` struct the loader and
`tau config validate` use, so it cannot drift from the keys tau accepts —
adding a `FileConfig` field without schema metadata is a compile error, and
CI diffs the checked-in `schema/tau-config.schema.json` against the binary's
output on every platform leg. Details and per-key semantics live in
[docs/configuration.md](configuration.md#json-schema-and-editor-autocomplete).

## See also

- [docs/compatibility.md](compatibility.md) — generated matrix of every
  supported client: config location, entry shape, doctor check/fix ids, and
  the minimum tau version each path needs.
- [docs/acp.md](acp.md) — JetBrains, Emacs, Toad, generic stdio clients,
  `tau acp start|stop|status` socket mode, and what the editor sees.
- [docs/configuration.md](configuration.md) — provider, model, and API-key
  resolution for the spawned `tau acp serve` process.
