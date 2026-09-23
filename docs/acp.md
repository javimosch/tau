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
| Agent fails to start in Zed | `command` not found — use an absolute path to the tau binary. |
| `unknown acp argument: --provider` | Only `serve`, `--acp-socket`, `--max-iterations` are valid in `args`. Set provider/model in `~/.config/tau/config.json` instead. |
| Auth error (exit 106) in daemon/socket mode | The daemon inherits only its spawn environment — export the key before `tau acp start`, or put it in `config.json` / the Zed `env` block. |
| Edits don't show as diffs | Client didn't advertise `fs.writeTextFile` capability, or rejected the write — tau falls back to direct file writes. |
| Daemon state looks wrong | `tau acp status` is authoritative; it ignores stale pid files. `tau acp stop` cleans up stale socket + pid. |
