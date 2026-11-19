# `tau setup --client` catalog

<!-- GENERATED FILE — do not edit by hand.
     Source of truth: the ClientKind tables in src/setup.zig and the
     client catalog in src/clientcatalog.zig — the same registry
     `tau explain client.<id>` reads; doctor check/fix ids from
     src/doctor.zig.
     Regenerate:  python3 scripts/gen-clients-doc.py
     Drift check: python3 scripts/gen-clients-doc.py --check
     (the clients-doc smoke group runs the drift check) -->

`tau setup --client <id>` wires `tau acp serve` into an editor
client's config — the same wiring `tau explain client.<id>` prints
offline as JSON (`--human` renders prose). This page catalogs every
supported `--client` id: accepted spellings, transport and wiring
kind, prerequisites, the paths setup touches, each client's native
per-OS config locations, the `tau doctor` check row that verifies
the wiring, and the per-client guide.

`~` is `$HOME` on Linux/macOS and `%USERPROFILE%` on Windows — setup
writes the `~` form of every path on every OS (clients that honor
`$XDG_CONFIG_HOME` override the Linux/macOS prefix accordingly); the
**Native locations** line lists where each client itself resolves
the file per OS. Detection — `tau doctor`, or `tau setup --detect`
for the read-only inventory — only *reports* clients whose
detection dir exists and never writes. `--client all` expands to
every section below.

The one-table summary of the same registry is
[docs/compatibility.md](compatibility.md); every wiring check's
symptom/cause/fix is [docs/doctor.md](doctor.md); and each linked
guide carries the exact config snippets `tau setup` writes,
verified byte-for-byte.

## Clients

### `zed`

- **`--client`:** `zed` — `tau setup --client zed --yes`
- **Transport / wiring:** `acp` — the editor spawns `tau acp serve` itself · `direct` — setup splices the settings file (an existing file is never rewritten — a paste-ready snippet drops instead)
- **Prerequisites:** tau installed and configured — `tau doctor` reports an ok provider and API key
- **Paths:** settings `~/.config/zed/settings.json` · detection dir `~/.config/zed` · snippet `~/.config/tau/snippets/zed.jsonc`
- **Native locations:** Linux `~/.config/zed/settings.json` · macOS `~/.config/zed/settings.json` · Windows `%APPDATA%\Zed\settings.json`
- **Wiring check:** `client_zed` — reported once `~/.config/zed` exists; `tau doctor --fix` runs `wire_client_zed` (`tau explain doctor.client_zed`)
- **Explain:** `tau explain client.zed`
- **Guide:** [docs/clients/zed.md](clients/zed.md)
- **Finish in the editor:** open the Agent Panel, click +, and pick tau

### `nvim`

- **`--client`:** `nvim` — `tau setup --client nvim --yes`
- **Transport / wiring:** `acp` — the editor spawns `tau acp serve` itself · `snippet` — setup can't splice the Lua plugin config; it always drops a paste-ready snippet to merge by hand
- **Prerequisites:** Neovim with avante.nvim or CodeCompanion.nvim installed; tau installed and configured — `tau doctor` reports an ok provider and API key
- **Paths:** merge target `~/.config/nvim/init.lua` · detection dir `~/.config/nvim` · snippet `~/.config/tau/snippets/nvim.lua`
- **Native locations:** Linux `~/.config/nvim/init.lua` · macOS `~/.config/nvim/init.lua` · Windows `%LOCALAPPDATA%\nvim\init.lua`
- **Wiring check:** `client_nvim` — reported once `~/.config/nvim` exists; manual only — `tau doctor` can't verify the Lua plugin config; `tau setup --client nvim --yes` (re)generates the snippet (`tau explain doctor.client_nvim`)
- **Explain:** `tau explain client.nvim`
- **Guide:** [docs/clients/nvim.md](clients/nvim.md)
- **Finish in the editor:** pick the tau provider/adapter in your plugin (e.g. :AvanteSwitchProvider)

### `emacs`

- **`--client`:** `emacs` — `tau setup --client emacs --yes`
- **Transport / wiring:** `acp` — the editor spawns `tau acp serve` itself · `snippet` — setup can't splice the elisp config; it always drops a paste-ready snippet to merge by hand
- **Prerequisites:** Emacs 29.1+ with agent-shell and acp installed from MELPA; tau installed and configured — `tau doctor` reports an ok provider and API key
- **Paths:** merge target `~/.emacs.d/init.el` · detection dir `~/.emacs.d` · snippet `~/.config/tau/snippets/emacs.el`
- **Native locations:** Linux `~/.emacs.d/init.el` · macOS `~/.emacs.d/init.el` · Windows `%APPDATA%\.emacs.d\init.el`
- **Wiring check:** `client_emacs` — reported once `~/.emacs.d` exists; manual only — `tau doctor` can't verify the elisp config; `tau setup --client emacs --yes` (re)generates the snippet (`tau explain doctor.client_emacs`)
- **Explain:** `tau explain client.emacs`
- **Guide:** [docs/clients/emacs.md](clients/emacs.md)
- **Finish in the editor:** paste the snippet into your init file, restart Emacs, run M-x agent-shell and pick tau

### `vscode`

- **`--client`:** `vscode` (alias `code`) — `tau setup --client vscode --yes`
- **Transport / wiring:** `acp` — the editor spawns `tau acp serve` itself · `direct` — setup splices the settings file (an existing file is never rewritten — a paste-ready snippet drops instead)
- **Prerequisites:** tau installed and configured — `tau doctor` reports an ok provider and API key
- **Paths:** settings `~/.config/Code/User/settings.json` · detection dir `~/.config/Code` · snippet `~/.config/tau/snippets/vscode.jsonc`
- **Native locations:** Linux `~/.config/Code/User/settings.json` · macOS `~/Library/Application Support/Code/User/settings.json` · Windows `%APPDATA%\Code\User\settings.json`
- **Wiring check:** `client_vscode` — reported once `~/.config/Code` exists; `tau doctor --fix` runs `wire_client_vscode` (`tau explain doctor.client_vscode`)
- **Explain:** `tau explain client.vscode`
- **Guide:** [docs/clients/vscode.md](clients/vscode.md)
- **Finish in the editor:** install the ACP Client extension, run 'ACP: Connect to Agent', pick tau

### `cursor`

- **`--client`:** `cursor` — `tau setup --client cursor --yes`
- **Transport / wiring:** `acp` — the editor spawns `tau acp serve` itself · `direct` — setup splices the settings file (an existing file is never rewritten — a paste-ready snippet drops instead)
- **Prerequisites:** tau installed and configured — `tau doctor` reports an ok provider and API key
- **Paths:** settings `~/.config/Cursor/User/settings.json` · detection dir `~/.config/Cursor` · snippet `~/.config/tau/snippets/cursor.jsonc`
- **Native locations:** Linux `~/.config/Cursor/User/settings.json` · macOS `~/Library/Application Support/Cursor/User/settings.json` · Windows `%APPDATA%\Cursor\User\settings.json`
- **Wiring check:** `client_cursor` — reported once `~/.config/Cursor` exists; `tau doctor --fix` runs `wire_client_cursor` (`tau explain doctor.client_cursor`)
- **Explain:** `tau explain client.cursor`
- **Guide:** [docs/clients/cursor.md](clients/cursor.md)
- **Finish in the editor:** install the ACP Client extension (Open VSX), run 'ACP: Connect to Agent', pick tau

### `jetbrains`

- **`--client`:** `jetbrains` — `tau setup --client jetbrains --yes`
- **Transport / wiring:** `acp` — the editor spawns `tau acp serve` itself · `direct` — setup splices the settings file (an existing file is never rewritten — a paste-ready snippet drops instead)
- **Prerequisites:** a JetBrains IDE with AI Assistant 2025.1 or newer (custom agents are not supported under WSL — use a native Windows or Linux/macOS install); tau installed and configured — `tau doctor` reports an ok provider and API key
- **Paths:** settings `~/.jetbrains/acp.json` · detection dir `~/.jetbrains` · snippet `~/.config/tau/snippets/jetbrains.jsonc`
- **Native locations:** Linux `~/.jetbrains/acp.json` · macOS `~/.jetbrains/acp.json` · Windows `~/.jetbrains/acp.json`
- **Wiring check:** `client_jetbrains` — reported once `~/.jetbrains` exists; `tau doctor --fix` runs `wire_client_jetbrains` (`tau explain doctor.client_jetbrains`)
- **Explain:** `tau explain client.jetbrains`
- **Guide:** [docs/clients/jetbrains.md](clients/jetbrains.md)
- **Finish in the editor:** open the AI Chat tool window and pick tau in the agent selector

### `windsurf`

- **`--client`:** `windsurf` — `tau setup --client windsurf --yes`
- **Transport / wiring:** `mcacp` — the editor speaks MCP, not ACP; its server entry launches the `npx -y mcacp` bridge · `direct` — setup splices the settings file (an existing file is never rewritten — a paste-ready snippet drops instead)
- **Prerequisites:** tau installed and configured — `tau doctor` reports an ok provider and API key; Node.js with `npx` on the PATH Windsurf sees — the bridge runs as `npx -y mcacp` (or install it once with `npm i -g mcacp`)
- **Paths:** settings `~/.codeium/windsurf/mcp_config.json` · detection dir `~/.codeium/windsurf` · snippet `~/.config/tau/snippets/windsurf.jsonc` · bridge `~/.config/mcacp/mcacp.json`
- **Native locations:** Linux `~/.codeium/windsurf/mcp_config.json` · macOS `~/.codeium/windsurf/mcp_config.json` · Windows `%USERPROFILE%\.codeium\windsurf\mcp_config.json`
- **Wiring check:** `client_windsurf` — reported once `~/.codeium/windsurf` exists; `tau doctor --fix` runs `wire_client_windsurf` (`tau explain doctor.client_windsurf`)
- **Explain:** `tau explain client.windsurf`
- **Guide:** [docs/clients/windsurf.md](clients/windsurf.md)
- **Finish in the editor:** install mcacp (npm i -g mcacp or npx), restart Windsurf, and confirm the mcacp server in Settings > MCP servers

### `gemini`

- **`--client`:** `gemini` (alias `gemini-cli`) — `tau setup --client gemini --yes`
- **Transport / wiring:** `mcacp` — the editor speaks MCP, not ACP; its server entry launches the `npx -y mcacp` bridge · `direct` — setup splices the settings file (an existing file is never rewritten — a paste-ready snippet drops instead)
- **Prerequisites:** tau installed and configured — `tau doctor` reports an ok provider and API key; Node.js with `npx` on the PATH Gemini CLI sees — the bridge runs as `npx -y mcacp` (or install it once with `npm i -g mcacp`)
- **Paths:** settings `~/.gemini/settings.json` · detection dir `~/.gemini` · snippet `~/.config/tau/snippets/gemini.jsonc` · bridge `~/.config/mcacp/mcacp.json`
- **Native locations:** Linux `~/.gemini/settings.json` · macOS `~/.gemini/settings.json` · Windows `%USERPROFILE%\.gemini\settings.json`
- **Wiring check:** `client_gemini` — reported once `~/.gemini` exists; `tau doctor --fix` runs `wire_client_gemini` (`tau explain doctor.client_gemini`)
- **Explain:** `tau explain client.gemini`
- **Guide:** [docs/clients/gemini-cli.md](clients/gemini-cli.md)
- **Finish in the editor:** install mcacp (npm i -g mcacp or npx), restart Gemini CLI, and run /mcp to see tau's tools

### `claude-desktop`

- **`--client`:** `claude-desktop` (alias `claude`) — `tau setup --client claude-desktop --yes`
- **Transport / wiring:** `mcacp` — the editor speaks MCP, not ACP; its server entry launches the `npx -y mcacp` bridge · `direct` — setup splices the settings file (an existing file is never rewritten — a paste-ready snippet drops instead)
- **Prerequisites:** tau installed and configured — `tau doctor` reports an ok provider and API key; Node.js with `npx` on the PATH Claude Desktop sees — the bridge runs as `npx -y mcacp` (or install it once with `npm i -g mcacp`)
- **Paths:** settings `~/.config/Claude/claude_desktop_config.json` · detection dir `~/.config/Claude` · snippet `~/.config/tau/snippets/claude-desktop.jsonc` · bridge `~/.config/mcacp/mcacp.json`
- **Native locations:** Linux `~/.config/Claude/claude_desktop_config.json` · macOS `~/Library/Application Support/Claude/claude_desktop_config.json` · Windows `%APPDATA%\Claude\claude_desktop_config.json`
- **Wiring check:** `client_claude_desktop` — reported once `~/.config/Claude` exists; `tau doctor --fix` runs `wire_client_claude_desktop` (`tau explain doctor.client_claude_desktop`)
- **Explain:** `tau explain client.claude-desktop`
- **Guide:** [docs/clients/claude-desktop.md](clients/claude-desktop.md)
- **Finish in the editor:** install mcacp (npm i -g mcacp or npx), restart Claude Desktop, and find tau's tools under the mcacp server

### `opencode`

- **`--client`:** `opencode` — `tau setup --client opencode --yes`
- **Transport / wiring:** `mcacp` — the editor speaks MCP, not ACP; its server entry launches the `npx -y mcacp` bridge · `direct` — setup splices the settings file (an existing file is never rewritten — a paste-ready snippet drops instead)
- **Prerequisites:** tau installed and configured — `tau doctor` reports an ok provider and API key; Node.js with `npx` on the PATH OpenCode sees — the bridge runs as `npx -y mcacp` (or install it once with `npm i -g mcacp`)
- **Paths:** settings `~/.config/opencode/opencode.json` · detection dir `~/.config/opencode` · snippet `~/.config/tau/snippets/opencode.jsonc` · bridge `~/.config/mcacp/mcacp.json`
- **Native locations:** Linux `~/.config/opencode/opencode.json` · macOS `~/.config/opencode/opencode.json` · Windows `~/.config/opencode/opencode.json`
- **Wiring check:** `client_opencode` — reported once `~/.config/opencode` exists; `tau doctor --fix` runs `wire_client_opencode` (`tau explain doctor.client_opencode`)
- **Explain:** `tau explain client.opencode`
- **Guide:** [docs/clients/opencode.md](clients/opencode.md)
- **Finish in the editor:** install mcacp (npm i -g mcacp or npx), restart OpenCode, and check the mcacp server with 'opencode mcp list'

### `cline`

- **`--client`:** `cline` — `tau setup --client cline --yes`
- **Transport / wiring:** `mcacp` — the editor speaks MCP, not ACP; its server entry launches the `npx -y mcacp` bridge · `direct` — setup splices the settings file (an existing file is never rewritten — a paste-ready snippet drops instead)
- **Prerequisites:** tau installed and configured — `tau doctor` reports an ok provider and API key; Node.js with `npx` on the PATH VS Code sees — the bridge runs as `npx -y mcacp` (or install it once with `npm i -g mcacp`)
- **Paths:** settings `~/.config/Code/User/globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json` · detection dir `~/.config/Code/User/globalStorage/saoudrizwan.claude-dev` · snippet `~/.config/tau/snippets/cline.jsonc` · bridge `~/.config/mcacp/mcacp.json`
- **Native locations:** Linux `~/.config/Code/User/globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json` · macOS `~/Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json` · Windows `%APPDATA%\Code\User\globalStorage\saoudrizwan.claude-dev\settings\cline_mcp_settings.json`
- **Wiring check:** `client_cline` — reported once `~/.config/Code/User/globalStorage/saoudrizwan.claude-dev` exists; `tau doctor --fix` runs `wire_client_cline` (`tau explain doctor.client_cline`)
- **Explain:** `tau explain client.cline`
- **Guide:** [docs/clients/cline.md](clients/cline.md)
- **Finish in the editor:** install mcacp (npm i -g mcacp or npx), restart VS Code, and confirm the mcacp server under MCP Servers in the Cline pane

### `goose`

- **`--client`:** `goose` — `tau setup --client goose --yes`
- **Transport / wiring:** `mcacp` — the editor speaks MCP, not ACP; its server entry launches the `npx -y mcacp` bridge · `snippet` — setup can't splice the YAML config; it always drops a paste-ready snippet to merge by hand
- **Prerequisites:** tau installed and configured — `tau doctor` reports an ok provider and API key; Node.js with `npx` on the PATH Goose sees — the bridge runs as `npx -y mcacp` (or install it once with `npm i -g mcacp`)
- **Paths:** merge target `~/.config/goose/config.yaml` · detection dir `~/.config/goose` · snippet `~/.config/tau/snippets/goose.yaml` · bridge `~/.config/mcacp/mcacp.json`
- **Native locations:** Linux `~/.config/goose/config.yaml` · macOS `~/.config/goose/config.yaml` · Windows `%APPDATA%\Block\goose\config\config.yaml`
- **Wiring check:** `client_goose` — reported once `~/.config/goose` exists; manual only — `tau doctor` can't verify the YAML config; `tau setup --client goose --yes` (re)generates the snippet (`tau explain doctor.client_goose`)
- **Explain:** `tau explain client.goose`
- **Guide:** [docs/clients/goose.md](clients/goose.md)
- **Finish in the editor:** install mcacp (npm i -g mcacp or npx), merge the snippet into ~/.config/goose/config.yaml, then run 'goose session' and ask about the mcacp tools

### `continue`

- **`--client`:** `continue` — `tau setup --client continue --yes`
- **Transport / wiring:** `mcacp` — the editor speaks MCP, not ACP; its server entry launches the `npx -y mcacp` bridge · `snippet` — setup can't splice the YAML config; it always drops a paste-ready snippet to merge by hand
- **Prerequisites:** tau installed and configured — `tau doctor` reports an ok provider and API key; Node.js with `npx` on the PATH Continue sees — the bridge runs as `npx -y mcacp` (or install it once with `npm i -g mcacp`)
- **Paths:** merge target `~/.continue/config.yaml` · detection dir `~/.continue` · snippet `~/.config/tau/snippets/continue.yaml` · bridge `~/.config/mcacp/mcacp.json`
- **Native locations:** Linux `~/.continue/config.yaml` · macOS `~/.continue/config.yaml` · Windows `%USERPROFILE%\.continue\config.yaml`
- **Wiring check:** `client_continue` — reported once `~/.continue` exists; manual only — `tau doctor` can't verify the YAML config; `tau setup --client continue --yes` (re)generates the snippet (`tau explain doctor.client_continue`)
- **Explain:** `tau explain client.continue`
- **Guide:** [docs/clients/continue.md](clients/continue.md)
- **Finish in the editor:** install mcacp (npm i -g mcacp or npx), merge the snippet into ~/.continue/config.yaml, restart Continue, and use agent mode to see tau's tools

### `roo-code`

- **`--client`:** `roo-code` (alias `roo`) — `tau setup --client roo-code --yes`
- **Transport / wiring:** `mcacp` — the editor speaks MCP, not ACP; its server entry launches the `npx -y mcacp` bridge · `direct` — setup splices the settings file (an existing file is never rewritten — a paste-ready snippet drops instead)
- **Prerequisites:** tau installed and configured — `tau doctor` reports an ok provider and API key; Node.js with `npx` on the PATH VS Code sees — the bridge runs as `npx -y mcacp` (or install it once with `npm i -g mcacp`)
- **Paths:** settings `~/.config/Code/User/globalStorage/rooveterinaryinc.roo-cline/settings/mcp_settings.json` · detection dir `~/.config/Code/User/globalStorage/rooveterinaryinc.roo-cline` · snippet `~/.config/tau/snippets/roo-code.jsonc` · bridge `~/.config/mcacp/mcacp.json`
- **Native locations:** Linux `~/.config/Code/User/globalStorage/rooveterinaryinc.roo-cline/settings/mcp_settings.json` · macOS `~/Library/Application Support/Code/User/globalStorage/rooveterinaryinc.roo-cline/settings/mcp_settings.json` · Windows `%APPDATA%\Code\User\globalStorage\rooveterinaryinc.roo-cline\settings\mcp_settings.json`
- **Wiring check:** `client_roo_code` — reported once `~/.config/Code/User/globalStorage/rooveterinaryinc.roo-cline` exists; `tau doctor --fix` runs `wire_client_roo` (`tau explain doctor.client_roo_code`)
- **Explain:** `tau explain client.roo-code`
- **Guide:** [docs/clients/roo-code.md](clients/roo-code.md)
- **Finish in the editor:** install mcacp (npm i -g mcacp or npx), restart VS Code, and confirm the mcacp server under MCP Servers in the Roo Code pane

### `kilo-code`

- **`--client`:** `kilo-code` (alias `kilo`) — `tau setup --client kilo-code --yes`
- **Transport / wiring:** `mcacp` — the editor speaks MCP, not ACP; its server entry launches the `npx -y mcacp` bridge · `direct` — setup splices the settings file (an existing file is never rewritten — a paste-ready snippet drops instead)
- **Prerequisites:** tau installed and configured — `tau doctor` reports an ok provider and API key; Node.js with `npx` on the PATH the Kilo Code process sees — the bridge runs as `npx -y mcacp` (or install it once with `npm i -g mcacp`)
- **Paths:** settings `~/.config/kilo/kilo.jsonc` · detection dir `~/.config/kilo` · snippet `~/.config/tau/snippets/kilo-code.jsonc` · bridge `~/.config/mcacp/mcacp.json`
- **Native locations:** Linux `~/.config/kilo/kilo.jsonc` · macOS `~/.config/kilo/kilo.jsonc` · Windows `~/.config/kilo/kilo.jsonc`
- **Wiring check:** `client_kilo_code` — reported once `~/.config/kilo` exists; `tau doctor --fix` runs `wire_client_kilo` (`tau explain doctor.client_kilo_code`)
- **Explain:** `tau explain client.kilo-code`
- **Guide:** [docs/clients/kilo-code.md](clients/kilo-code.md)
- **Finish in the editor:** install mcacp (npm i -g mcacp or npx), restart Kilo Code, and confirm the mcacp server under Agent Behaviour > MCP Servers (or run 'kilo mcp list')

### `amazonq`

- **`--client`:** `amazonq` (alias `amazon-q`) — `tau setup --client amazonq --yes`
- **Transport / wiring:** `mcacp` — the editor speaks MCP, not ACP; its server entry launches the `npx -y mcacp` bridge · `direct` — setup splices the settings file (an existing file is never rewritten — a paste-ready snippet drops instead)
- **Prerequisites:** tau installed and configured — `tau doctor` reports an ok provider and API key; Node.js with `npx` on the PATH the `q` process sees — the bridge runs as `npx -y mcacp` (or install it once with `npm i -g mcacp`)
- **Paths:** settings `~/.aws/amazonq/mcp.json` · detection dir `~/.aws/amazonq` · snippet `~/.config/tau/snippets/amazonq.jsonc` · bridge `~/.config/mcacp/mcacp.json`
- **Native locations:** Linux `~/.aws/amazonq/mcp.json` · macOS `~/.aws/amazonq/mcp.json` · Windows `~/.aws/amazonq/mcp.json`
- **Wiring check:** `client_amazonq` — reported once `~/.aws/amazonq` exists; `tau doctor --fix` runs `wire_client_amazonq` (`tau explain doctor.client_amazonq`)
- **Explain:** `tau explain client.amazonq`
- **Guide:** [docs/clients/amazonq.md](clients/amazonq.md)
- **Finish in the editor:** install mcacp (npm i -g mcacp or npx), then run 'q chat' (or restart the IDE plugin) and check the mcacp server with /mcp

### `codex`

- **`--client`:** `codex` (alias `codex-cli`) — `tau setup --client codex --yes`
- **Transport / wiring:** `mcacp` — the editor speaks MCP, not ACP; its server entry launches the `npx -y mcacp` bridge · `snippet` — setup can't splice the TOML config; it always drops a paste-ready snippet to merge by hand
- **Prerequisites:** tau installed and configured — `tau doctor` reports an ok provider and API key; Node.js with `npx` on the PATH Codex sees — the bridge runs as `npx -y mcacp` (or install it once with `npm i -g mcacp`)
- **Paths:** merge target `~/.codex/config.toml` · detection dir `~/.codex` · snippet `~/.config/tau/snippets/codex.toml` · bridge `~/.config/mcacp/mcacp.json`
- **Native locations:** Linux `~/.codex/config.toml` · macOS `~/.codex/config.toml` · Windows `~/.codex/config.toml`
- **Wiring check:** `client_codex` — reported once `~/.codex` exists; manual only — `tau doctor` can't verify the TOML config; `tau setup --client codex --yes` (re)generates the snippet (`tau explain doctor.client_codex`)
- **Explain:** `tau explain client.codex`
- **Guide:** [docs/clients/codex.md](clients/codex.md)
- **Finish in the editor:** install mcacp (npm i -g mcacp or npx), merge the snippet into ~/.codex/config.toml, then run 'codex mcp list' to confirm the mcacp server
