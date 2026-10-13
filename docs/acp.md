# Using tau as an ACP agent

tau can run as an [Agent Client Protocol](https://agentclientprotocol.com) (ACP)
server, which lets ACP-compatible editors — [Zed](https://zed.dev) being the most
common — drive tau as a coding agent inside the editor UI.

Under the hood it is newline-delimited JSON-RPC 2.0. tau speaks protocol version
`1` and implements `initialize`, `authenticate`, `session/new`, `session/load`,
`session/prompt`, and the `session/cancel` notification. Each prompt runs tau's
full agentic tool loop and streams back `session/update` notifications
(`tool_call` → `tool_call_update` → `agent_message_chunk`), ending with a
`session/prompt` response carrying a `stopReason`.

## Quick start: tau in Zed

1. Build or install tau so the binary is on your `PATH` (or note its absolute
   path — e.g. `./zig-out/bin/tau` from a source checkout).
2. Make sure tau can authenticate: set the env var for your provider
   (`XIAOMI_API_KEY`, `OPENAI_API_KEY`, `DEEPSEEK_API_KEY`, `OPENCODE_API_KEY`,
   or the `TAU_API_KEY` fallback) — either in your shell environment or in the
   `env` block below — or configure `~/.config/tau/config.json`. See
   [configuration.md](configuration.md).
3. Open Zed settings (`zed: open settings file`, or **Agent Settings → External
   Agents → Add Agent → Add Custom Agent**) and add:

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

If `tau` is not on `PATH` inside Zed's spawn environment, use the absolute path:

```json
{
  "agent_servers": {
    "tau": {
      "type": "custom",
      "command": "/home/you/tau/zig-out/bin/tau",
      "args": ["acp", "serve"],
      "env": {
        "OPENAI_API_KEY": "sk-..."
      }
    }
  }
}
```

4. Open the Agent Panel, click **+**, and pick **tau** from the agent list.

> **Note on `args`:** the `acp` subcommand is parsed separately and only accepts
> `start|stop|status|serve`, `--acp-socket <path>`, and `--max-iterations <n>`.
> Regular flags like `--provider` or `--model` are rejected
> (`unknown acp argument`). Provider, model, and keys come from
> `~/.config/tau/config.json` and environment variables; `TAU_ENDPOINT` overrides
> the endpoint. The `env` map in `agent_servers` is the right place to inject
> `TAU_API_KEY`, `TAU_ENDPOINT`, or a provider key for the spawned process.

## Editor integrations

Every client below does the same thing under the hood: spawn `tau acp serve`
and speak JSON-RPC over stdio. Only the config file format differs. In all
cases provider, model, and API keys come from `~/.config/tau/config.json` and
the spawned process's environment — the `args` list must only contain
`["acp", "serve"]` (see the note above for why).

### JetBrains IDEs

AI Assistant ships with ACP support (no JetBrains AI subscription required).
Open the AI Chat tool window, click the options button, and choose **Add
Custom Agent** — this creates `~/.jetbrains/acp.json`. Fill it in:

```json
{
  "agent_servers": {
    "tau": {
      "command": "tau",
      "args": ["acp", "serve"],
      "env": {
        "OPENAI_API_KEY": "sk-..."
      }
    }
  }
}
```

The key (`"tau"`) is the display name in the AI Chat agent selector. Note the
differences from Zed's file: no `"type"` field, and an optional top-level
`"default_mcp_settings"` object controls MCP passthrough. Custom agents are
not supported under WSL — use a native Windows or Linux/macOS install.

### VS Code

Install the [ACP Client](https://marketplace.visualstudio.com/items?itemName=formulahendry.acp-client)
extension, then add to `settings.json`:

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

Run **ACP: Connect to Agent** from the Command Palette, pick `tau`, then
**ACP: New Conversation**. `tau` must be on the `PATH` the extension sees —
launch VS Code from a shell where it resolves, or use the absolute path.

### Neovim — avante.nvim

[avante.nvim](https://github.com/yetone/avante.nvim) drives ACP agents via
`acp_providers`:

```lua
require("avante").setup({
  provider = "tau",
  acp_providers = {
    ["tau"] = {
      command = "tau",
      args = { "acp", "serve" },
      env = {
        OPENAI_API_KEY = os.getenv("OPENAI_API_KEY"),
      },
    },
  },
})
```

If `tau` isn't the default `provider`, select it with `:AvanteSwitchProvider`.

### Neovim — CodeCompanion.nvim

[CodeCompanion](https://github.com/olimorris/codecompanion.nvim) has no preset
tau adapter, but custom ACP adapters are supported directly in the config:

```lua
require("codecompanion").setup({
  adapters = {
    acp = {
      tau = function()
        local helpers = require("codecompanion.adapters.acp.helpers")
        return {
          name = "tau",
          formatted_name = "tau",
          type = "acp",
          roles = {
            llm = "assistant",
            user = "user",
          },
          commands = {
            default = { "tau", "acp", "serve" },
          },
          defaults = {
            timeout = 20000, -- 20 seconds
          },
          parameters = {
            protocolVersion = 1,
            clientCapabilities = {
              fs = { readTextFile = true, writeTextFile = true },
            },
            clientInfo = {
              name = "CodeCompanion.nvim",
              version = "1.0.0",
            },
          },
          handlers = {
            setup = function(self) return true end,
            auth = function(self) return true end,
            form_messages = function(self, messages, capabilities)
              return helpers.form_messages(self, messages, capabilities)
            end,
            on_exit = function(self, code) end,
          },
        }
      end,
    },
  },
})
```

Then select the `tau` adapter in a chat buffer, or set
`interactions.chat.adapter = "tau"` to make it the default.

### Emacs — agent-shell

[agent-shell](https://github.com/xenodium/agent-shell) (on MELPA, with its
dependency [acp.el](https://github.com/xenodium/acp.el)) is a native Emacs
client for ACP agents. Register tau as a custom agent:

```elisp
(defun agent-shell-make-tau-config ()
  "Create a tau agent configuration for `agent-shell'."
  (agent-shell-make-agent-config
   :identifier 'tau
   :mode-line-name "tau"
   :buffer-name "tau"
   :shell-prompt "tau> "
   :shell-prompt-regexp "tau> "
   :needs-authentication nil
   :client-maker
   (lambda ()
     (acp-make-client
      :command "tau"
      :command-params '("acp" "serve")
      :environment-variables '("OPENAI_API_KEY=sk-...")))))

(add-to-list 'agent-shell-agent-configs (agent-shell-make-tau-config))
```

`:environment-variables` takes `"VAR=value"` strings; omit it entirely if tau
authenticates via `~/.config/tau/config.json`. Run `M-x agent-shell` and pick
`tau`.

### Terminal — Toad

[Toad](https://www.batrachian.ai/) is a terminal UI that can host any ACP
agent in place — no config file needed:

```bash
toad acp "tau acp serve" .
```

The trailing `.` sets the agent's working directory to the project root.

## Other ACP clients

Any client that can spawn a subprocess and speak ACP over **stdio** can use tau —
point it at `tau acp serve` as the command. For clients that connect to an
already-running server instead of spawning one, tau can listen on a Unix socket:

```bash
tau acp serve --acp-socket /tmp/tau.sock
```

The daemon commands manage exactly this socket mode in the background:

```bash
tau acp start      # serve on ~/.config/tau/acp.sock, detached (POSIX only)
tau acp status     # {"acp":{"running":true,"pid":...,"socket":"..."}}
tau acp stop       # SIGTERM + cleanup
```

Daemon logs go to `~/.config/tau/acp.log`. On Windows only the stdio `serve`
path is available — `start`/`stop`/`status` exit `111` (unimplemented).

## What the editor sees

- **Tools stream live.** Each built-in tool call is reported as an ACP
  `tool_call` with a kind (`read`, `edit`, `execute`, `search`, `other`) and
  updated to completion as it runs.
- **Edits become diffs.** If the client advertises `fs.readTextFile` /
  `fs.writeTextFile` capabilities at `initialize`, tau routes file writes
  through the editor's `fs/write_text_file` so changes appear as reviewable
  diffs; if the client rejects or lacks the capability, tau writes directly.
- **Working directory follows the project.** `session/new` / `session/load`
  honor the `cwd` the client sends (best-effort `chdir`, Linux only — other
  platforms rely on the inherited spawn cwd), so relative-path tools act on the
  open workspace.
- **Sessions persist.** Every ACP session is saved to
  `~/.config/tau/sessions/acp-<timestamp>-<n>.json`, so `session/load` can resume
  with compacted context across editor restarts.
- **Reasoning is streamed** as `agent_thought_chunk` notifications.

## Troubleshooting

| Symptom | Likely cause / fix |
|---------|--------------------|
| Agent fails to start in the editor | `command` not found — use an absolute path to the tau binary, and make sure it's on the `PATH` the editor's spawn environment sees (GUI apps often don't inherit shell init files). |
| tau doesn't appear in JetBrains AI Chat | `~/.jetbrains/acp.json` has a syntax error — validate the JSON and restart the IDE. Custom agents are not supported under WSL. |
| `unknown acp argument: --provider` | Only `serve`, `--acp-socket`, `--max-iterations` are valid in `args`. Set provider/model in `~/.config/tau/config.json` instead. |
| Auth error (exit 106) in daemon/socket mode | The daemon inherits only its spawn environment — export the key before `tau acp start`, or put it in `config.json` / the Zed `env` block. |
| Edits don't show as diffs | Client didn't advertise `fs.writeTextFile` capability, or rejected the write — tau falls back to direct file writes. |
| Daemon state looks wrong | `tau acp status` is authoritative; it ignores stale pid files. `tau acp stop` cleans up stale socket + pid. |
