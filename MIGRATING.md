# Migrating to tau from hand-managed MCP configs

Already running Claude Desktop, Windsurf, Gemini CLI, or OpenCode with MCP
servers you configured by hand? `tau setup --import` wires tau in
*alongside* them — your existing entries are never overwritten, and the
splice is JSONC-safe so comments and key order survive byte-for-byte.

## How it works

MCP-only clients can't spawn `tau acp serve` directly, so `tau setup` wires
them through the [mcacp](https://github.com/Oortonaut/mcacp) MCP→ACP bridge:

```
Your client ──MCP(stdio)──> mcacp ──ACP(stdio)──> tau acp serve
```

Plain `tau setup --client <name>` only writes a fresh settings file when
none exists — a file you already maintain is left alone, and a paste-ready
snippet lands in `~/.config/tau/snippets/` instead. `--import` opts into
editing that existing file in place:

- the `mcacp` bridge entry is spliced into the client's server section, and
- every MCP server entry found in your *other* supported clients' settings
  files is collected, deduplicated by name, and spliced in next to it —
  carried over in the target's own shape, `env` blocks included.

A client with no settings file yet isn't special-cased: it gets the `mcacp`
entry plus your imported servers in one fresh write.

## Which clients participate

`--import` reads from and writes to the eight file-backed MCP-bridge clients:

| `--client` | Settings file | Server section |
|---|---|---|
| `windsurf` | `~/.codeium/windsurf/mcp_config.json` | `"mcpServers"` |
| `gemini` | `~/.gemini/settings.json` | `"mcpServers"` |
| `claude-desktop` | `~/.config/Claude/claude_desktop_config.json` | `"mcpServers"` |
| `opencode` | `~/.config/opencode/opencode.json` | `"mcp"` |
| `cline` | `~/.config/Code/User/globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json` | `"mcpServers"` |
| `roo-code` | `~/.config/Code/User/globalStorage/rooveterinaryinc.roo-cline/settings/mcp_settings.json` | `"mcpServers"` |
| `kilo-code` | `~/.config/kilo/kilo.jsonc` | `"mcp"` |
| `amazonq` | `~/.aws/amazonq/mcp.json` | `"mcpServers"` |

Goose and Continue are MCP-bridge clients too, but their config is YAML —
setup never splices it, so they are neither sources nor targets for
`--import` (paste the `mcacp` block from their per-client guides instead).

The direct-ACP clients — `zed`, `nvim`, `emacs`, `vscode`, `cursor`,
`jetbrains` — spawn `tau acp serve` themselves, so they aren't sources or
targets for `--import`. Their wiring is covered by the per-client guides in
[docs/clients/](docs/clients/zed.md).

## Step 1 — preview the merge

`--dry-run` reports `would_install` plus the exact `imported` list without
touching the filesystem:

```bash
tau setup --client windsurf --import --dry-run
```

The clients step prints one NDJSON entry per client — `imported` names each
server and where it came from, `import_skipped` names what couldn't be
carried over and why:

```json
{"client":"windsurf","path":"/home/you/.codeium/windsurf/mcp_config.json","status":"would_install","imported":[{"name":"filesystem","from":"claude-desktop"}],"import_skipped":[{"name":"github","from":"claude-desktop","reason":"remote servers are not imported"}]}
```

## Step 2 — apply

```bash
tau setup --client windsurf --import --yes
```

Or merge your servers into every MCP client in one pass:

```bash
tau setup --client all --import --yes
```

`TAU_SETUP_IMPORT=1` is the env equivalent of the flag. `--import` and
`--remove`/`--uninstall` are mutually exclusive — passing both exits 80.

## What gets imported — and what gets skipped

Carried over:

- `mcpServers`-shape entries — a `"command"` string plus optional `"args"`
  string array and `"env"` object.
- OpenCode `mcp` local entries — the whole spawn line packed into a
  `"command"` array plus optional `"enabled"` — normalized to a spawn line,
  then re-rendered in the target's own shape (and vice versa: a `mcpServers`
  entry imported into OpenCode becomes a `"type":"local"` entry).

Skipped entries are never dropped silently — each lands in
`"import_skipped"` with a `reason`:

| Skipped | Reason |
|---|---|
| Remote servers (`"url"`/`"serverUrl"`-keyed entries, OpenCode `"type":"remote"`) | `remote servers are not imported` — no stdio spawn line to translate to |
| Entries with no `"command"` string/array | not a stdio/local server entry |
| `"args"` or `"command"` that isn't a string array | malformed entry shape |
| A name already imported from another client | `same name already imported from <client>` — first source wins, in windsurf → gemini → claude-desktop → opencode → cline order |
| Unreadable or unparseable source files | file-level `import_skipped` entry naming the path |

And by design:

- tau's own `"mcacp"` entry is never imported.
- entries the target file already has are never overwritten.
- missing client settings files are silent — that client just isn't
  configured.
- an unparseable *target* file falls back to the manual-snippet path — your
  file is never half-edited.

## Step 3 — verify

```bash
tau doctor --offline
```

The `client_<name>` rows report the wiring state, then restart the client
and confirm the servers appear.

## Rolling back

`--remove` unwires a client — it splices the `mcacp` entry back out while
leaving your servers (imported or hand-written) untouched:

```bash
tau setup --client windsurf --remove --dry-run
```

```bash
tau setup --client windsurf --remove
```

A settings file left with no entries at all is deleted; one that still
holds your servers stays, comments intact.

## Safety recap

- `--dry-run` previews every write — nothing changes until you re-run
  without it.
- comments, key order, and unrelated settings survive byte-for-byte.
- existing entries are never overwritten — first writer wins.
- setup never prompts and never reads stdin, so every step here is safe to
  script (`--yes`, `TAU_YES=1`, `--non-interactive`).

Related: per-client wiring guides in [docs/clients/](docs/clients/zed.md),
the full client matrix in [docs/acp.md](docs/acp.md), and
[docs/troubleshooting.md](docs/troubleshooting.md) for anything that goes
wrong.
