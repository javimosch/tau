// `tau setup` — one-shot onboarding: scaffold ~/.config/tau/config.json
// (init), install shell completions for the detected shell, configure editor
// ACP clients (--client), then embed the `tau doctor` health report. Emits
// one NDJSON object per step plus a final verdict line on stdout; exit 0
// when every step is ok/skipped, 1 otherwise. Idempotent: an existing config
// is kept, already-installed completions and configured clients are
// detected, and doctor is read-only. Key material is never printed.

const std = @import("std");
const term = @import("term.zig");
const json = @import("json.zig");
const cfgmod = @import("config.zig");
const configfile = @import("configfile.zig");
const initmod = @import("init.zig");
const doctor = @import("doctor.zig");
const completions = @import("completions");
const version = @import("version.zig").version;
const Config = cfgmod.Config;

/// Shells setup can install completions for.
pub const ShellKind = enum { bash, zsh, fish, pwsh };

/// Marker written next to every line setup appends to an rc/profile file so
/// re-runs stay idempotent and users can find (and remove) what was added.
pub const rc_marker = "# tau completions";

fn shellName(k: ShellKind) []const u8 {
    return switch (k) {
        .bash => "bash",
        .zsh => "zsh",
        .fish => "fish",
        .pwsh => "pwsh",
    };
}

/// Detect the login shell from $SHELL (basename match). Returns null when the
/// variable is unset or names a shell tau has no completions for.
pub fn detectShell(env: *std.process.Environ.Map) ?ShellKind {
    const raw = env.get("SHELL") orelse return null;
    const base = if (std.mem.lastIndexOfScalar(u8, raw, '/')) |i| raw[i + 1 ..] else raw;
    return parseShellName(base);
}

/// Map a shell name (as passed to --shell or found in $SHELL) to a ShellKind.
/// Accepts "powershell" as an alias for pwsh and tolerates ".exe" suffixes.
pub fn parseShellName(name: []const u8) ?ShellKind {
    var n = name;
    if (std.mem.endsWith(u8, n, ".exe")) n = n[0 .. n.len - 4];
    if (std.mem.eql(u8, n, "bash")) return .bash;
    if (std.mem.eql(u8, n, "zsh")) return .zsh;
    if (std.mem.eql(u8, n, "fish")) return .fish;
    if (std.mem.eql(u8, n, "pwsh") or std.mem.eql(u8, n, "powershell")) return .pwsh;
    return null;
}

/// The script content embedded for each shell (see build.zig).
fn shellContent(k: ShellKind) []const u8 {
    return switch (k) {
        .bash => completions.bash,
        .zsh => completions.zsh,
        .fish => completions.fish,
        .pwsh => completions.pwsh,
    };
}

/// Where the completion script is installed, per shell — mirrors
/// completions/README.md so manual and `tau setup` installs agree.
pub fn installPath(arena: std.mem.Allocator, home: []const u8, k: ShellKind) ![]u8 {
    return switch (k) {
        // bash-completion v2 autoloads per-user files from this directory.
        .bash => std.fmt.allocPrint(arena, "{s}/.local/share/bash-completion/completions/tau", .{home}),
        // _tau naming is required for compinit autoloading.
        .zsh => std.fmt.allocPrint(arena, "{s}/.zsh/completions/_tau", .{home}),
        // fish autoloads completions named after the command.
        .fish => std.fmt.allocPrint(arena, "{s}/.config/fish/completions/tau.fish", .{home}),
        // pwsh has no autoload dir — keep the script under tau's config dir
        // and dot-source it from the profile (see rcBlock).
        .pwsh => std.fmt.allocPrint(arena, "{s}/.config/tau/completions/tau.ps1", .{home}),
    };
}

/// The rc/profile file that needs a line appended for this shell, or null
/// when the shell autoloads the installed file on its own.
fn rcPath(arena: std.mem.Allocator, home: []const u8, k: ShellKind) !?[]u8 {
    return switch (k) {
        .bash, .fish => null,
        .zsh => try std.fmt.allocPrint(arena, "{s}/.zshrc", .{home}),
        // pwsh profile location on Linux/macOS. Windows users can copy the
        // same line into the profile shown by `pwsh -NoProfile -c '$PROFILE'`.
        .pwsh => try std.fmt.allocPrint(arena, "{s}/.config/powershell/Microsoft.PowerShell_profile.ps1", .{home}),
    };
}

/// The block appended to rcPath when rc_marker is not already present.
fn rcBlock(arena: std.mem.Allocator, k: ShellKind) ![]u8 {
    return switch (k) {
        .zsh => std.fmt.allocPrint(arena,
            \\{s}
            \\fpath=(~/.zsh/completions $fpath)
            \\autoload -Uz compinit && compinit
            \\
        , .{rc_marker}),
        .pwsh => std.fmt.allocPrint(arena, ". \"$HOME/.config/tau/completions/tau.ps1\"  {s}\n", .{rc_marker}),
        .bash, .fish => "",
    };
}

/// Write `data` to `path` (creating parent dirs) only when the content
/// differs. Returns whether the file was actually written.
const WriteResult = enum { written, unchanged };

fn writeIfChanged(io: std.Io, arena: std.mem.Allocator, path: []const u8, data: []const u8) !WriteResult {
    if (std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited)) |cur| {
        if (std.mem.eql(u8, cur, data)) return .unchanged;
    } else |_| {}
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| {
        std.Io.Dir.cwd().createDirPath(io, path[0..idx]) catch {};
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
    return .written;
}

/// Append `block` to the rc file unless it already carries rc_marker.
const RcResult = enum { appended, present };

fn ensureRcBlock(io: std.Io, arena: std.mem.Allocator, path: []const u8, block: []const u8) !RcResult {
    const cur = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited) catch "";
    if (std.mem.indexOf(u8, cur, rc_marker) != null) return .present;
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, cur);
    if (cur.len > 0 and !std.mem.endsWith(u8, cur, "\n")) try out.append(arena, '\n');
    try out.appendSlice(arena, block);
    _ = try writeIfChanged(io, arena, path, out.items);
    return .appended;
}

/// True when `s` parses as a whole JSON value (only whitespace allowed
/// around it) — used to sanity-check nothing before emitting raw report JSON.
fn isJsonObject(s: []const u8) bool {
    return s.len >= 2 and s[0] == '{' and s[s.len - 1] == '}';
}

fn js(arena: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
    try buf.append(arena, '"');
    try json.escapeInto(arena, buf, s);
    try buf.append(arena, '"');
}

fn emit(buf: *std.ArrayList(u8)) void {
    term.out(buf.items);
    term.out("\n");
    buf.clearRetainingCapacity();
}

// --- Step 1: init ---------------------------------------------------------

/// Scaffold the config file unless one already exists. Returns false when the
/// step failed (e.g. HOME unset or the write failed).
fn stepInit(io: std.Io, arena: std.mem.Allocator, cfg: Config, env: *std.process.Environ.Map) !bool {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(arena, "{\"step\":\"init\",\"status\":");

    const path = configfile.path(arena, env) orelse {
        try buf.appendSlice(arena, "\"failed\",\"message\":");
        try js(arena, &buf, "HOME is not set — cannot locate ~/.config/tau/config.json");
        try buf.append(arena, '}');
        emit(&buf);
        return false;
    };

    const det = try initmod.detectKeys(arena, env);
    const p = initmod.pickProvider(det, cfg.init_provider);

    const exists = blk: {
        _ = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited) catch |err| {
            if (err == error.FileNotFound) break :blk false;
            break :blk true; // exists but unreadable — still refuse to clobber
        };
        break :blk true;
    };

    if (!exists) {
        const body = try initmod.renderConfig(arena, det, p);
        _ = writeIfChanged(io, arena, path, body) catch |err| {
            try buf.appendSlice(arena, "\"failed\",\"message\":");
            const msg = try std.fmt.allocPrint(arena, "could not write {s}: {s}", .{ path, @errorName(err) });
            try js(arena, &buf, msg);
            try buf.append(arena, '}');
            emit(&buf);
            return false;
        };
        try buf.appendSlice(arena, "\"created\"");
    } else {
        try buf.appendSlice(arena, "\"exists\"");
    }
    try buf.appendSlice(arena, ",\"config_path\":");
    try js(arena, &buf, path);
    try buf.appendSlice(arena, ",\"provider\":");
    try js(arena, &buf, p.name);
    try buf.appendSlice(arena, ",\"detected_env_keys\":[");
    var first = true;
    for (det.keys) |k| {
        if (!first) try buf.append(arena, ',');
        first = false;
        try js(arena, &buf, k.env_key);
    }
    if (det.tau_fallback) {
        if (!first) try buf.append(arena, ',');
        try js(arena, &buf, "TAU_API_KEY");
    }
    try buf.appendSlice(arena, "]}");
    emit(&buf);
    return true;
}

// --- Step 2: shell completions ---------------------------------------------

/// The shells setup should install for: explicit --shell (validated upstream),
/// or the $SHELL-detected one. Empty when detection fails.
fn resolveShells(arena: std.mem.Allocator, cfg: Config, env: *std.process.Environ.Map) ![]ShellKind {
    var list: std.ArrayList(ShellKind) = .empty;
    if (cfg.setup_shell) |s| {
        if (std.mem.eql(u8, s, "all")) {
            try list.appendSlice(arena, &.{ .bash, .zsh, .fish, .pwsh });
        } else if (parseShellName(s)) |k| {
            try list.append(arena, k);
        }
    } else if (detectShell(env)) |k| {
        try list.append(arena, k);
    }
    return list.toOwnedSlice(arena);
}

/// Install one shell's completion script (+ rc hook when the shell needs it)
/// and append its JSON entry to `shells` — a `[`-opened list where `first`
/// says no comma is needed yet. Returns false on write failure.
fn installOne(io: std.Io, arena: std.mem.Allocator, shells: *std.ArrayList(u8), first: bool, home: []const u8, k: ShellKind) !bool {
    if (!first) try shells.append(arena, ',');

    try shells.appendSlice(arena, "{\"shell\":");
    try js(arena, shells, shellName(k));

    const path = try installPath(arena, home, k);
    const wrote = writeIfChanged(io, arena, path, shellContent(k)) catch |err| {
        try shells.appendSlice(arena, ",\"status\":\"failed\",\"message\":");
        const msg = try std.fmt.allocPrint(arena, "could not write {s}: {s}", .{ path, @errorName(err) });
        try js(arena, shells, msg);
        try shells.append(arena, '}');
        return false;
    };
    var ok = true;

    if (try rcPath(arena, home, k)) |rp| {
        var rr: ?RcResult = null;
        if (ensureRcBlock(io, arena, rp, try rcBlock(arena, k))) |r| {
            rr = r;
        } else |_| {
            ok = false;
        }
        try shells.appendSlice(arena, ",\"rc\":");
        try js(arena, shells, rp);
        try shells.appendSlice(arena, ",\"rc_status\":");
        try js(arena, shells, if (rr) |r| @tagName(r) else "failed");
    }

    try shells.appendSlice(arena, ",\"status\":");
    if (!ok) {
        try shells.appendSlice(arena, "\"failed\"");
    } else {
        try shells.appendSlice(arena, if (wrote == .written) "\"installed\"" else "\"already_installed\"");
    }
    try shells.appendSlice(arena, ",\"path\":");
    try js(arena, shells, path);
    switch (k) {
        .zsh => {
            // Drop the cached completion dump so the new _tau is picked up.
            const dump = try std.fmt.allocPrint(arena, "{s}/.zcompdump", .{home});
            std.Io.Dir.cwd().deleteFile(io, dump) catch {};
        },
        .bash => {
            try shells.appendSlice(arena, ",\"note\":");
            try js(arena, shells, "requires bash-completion; otherwise source this file from ~/.bashrc");
        },
        else => {},
    }
    try shells.append(arena, '}');
    return ok;
}

/// Install completions for every resolved shell. Returns false when any
/// install failed; a detection skip is reported but not a failure.
fn stepCompletions(io: std.Io, arena: std.mem.Allocator, cfg: Config, env: *std.process.Environ.Map) !bool {
    var buf: std.ArrayList(u8) = .empty;
    const home = env.get("HOME") orelse {
        try buf.appendSlice(arena, "{\"step\":\"completions\",\"status\":\"failed\",\"message\":");
        try js(arena, &buf, "HOME is not set — cannot locate shell config directories");
        try buf.appendSlice(arena, "}}");
        emit(&buf);
        return false;
    };

    const shells = try resolveShells(arena, cfg, env);
    if (shells.len == 0) {
        try buf.appendSlice(arena, "{\"step\":\"completions\",\"status\":\"skipped\",\"reason\":");
        try js(arena, &buf, "could not detect shell from $SHELL");
        try buf.appendSlice(arena, ",\"hint\":");
        try js(arena, &buf, "re-run with --shell bash|zsh|fish|pwsh|all");
        try buf.appendSlice(arena, "}");
        emit(&buf);
        return true;
    }

    var entries: std.ArrayList(u8) = .empty;
    try entries.append(arena, '[');
    var ok = true;
    for (shells, 0..) |k, i| {
        if (!try installOne(io, arena, &entries, i == 0, home, k)) ok = false;
    }
    try entries.append(arena, ']');

    try buf.appendSlice(arena, "{\"step\":\"completions\",\"status\":");
    try buf.appendSlice(arena, if (ok) "\"installed\"" else "\"failed\"");
    try buf.appendSlice(arena, ",\"shells\":");
    try buf.appendSlice(arena, entries.items);
    try buf.appendSlice(arena, "}");
    emit(&buf);
    return ok;
}

// --- Step 3: editor ACP clients --------------------------------------------

/// Editor clients setup can configure to spawn `tau acp serve`.
pub const ClientKind = enum { zed, nvim, vscode, jetbrains };

fn clientName(k: ClientKind) []const u8 {
    return switch (k) {
        .zed => "zed",
        .nvim => "nvim",
        .vscode => "vscode",
        .jetbrains => "jetbrains",
    };
}

/// Map a client name (as passed to --client) to a ClientKind. "code" is an
/// alias for vscode.
pub fn parseClientName(name: []const u8) ?ClientKind {
    if (std.mem.eql(u8, name, "zed")) return .zed;
    if (std.mem.eql(u8, name, "nvim")) return .nvim;
    if (std.mem.eql(u8, name, "vscode") or std.mem.eql(u8, name, "code")) return .vscode;
    if (std.mem.eql(u8, name, "jetbrains")) return .jetbrains;
    return null;
}

/// The JSON/JSONC settings file that carries the client config, or null for
/// nvim (its ACP plugins are configured in Lua — see renderNvimSnippet).
/// Linux paths; docs/acp.md lists equivalents for other platforms.
pub fn clientSettingsPath(arena: std.mem.Allocator, home: []const u8, k: ClientKind) !?[]u8 {
    return switch (k) {
        .zed => try std.fmt.allocPrint(arena, "{s}/.config/zed/settings.json", .{home}),
        .vscode => try std.fmt.allocPrint(arena, "{s}/.config/Code/User/settings.json", .{home}),
        .jetbrains => try std.fmt.allocPrint(arena, "{s}/.jetbrains/acp.json", .{home}),
        .nvim => null,
    };
}

/// The directory that exists once the editor has been installed/run — used
/// for the no-flag detection report (detection alone never writes).
fn clientConfigDir(arena: std.mem.Allocator, home: []const u8, k: ClientKind) ![]u8 {
    return switch (k) {
        .zed => std.fmt.allocPrint(arena, "{s}/.config/zed", .{home}),
        .vscode => std.fmt.allocPrint(arena, "{s}/.config/Code", .{home}),
        .jetbrains => std.fmt.allocPrint(arena, "{s}/.jetbrains", .{home}),
        .nvim => std.fmt.allocPrint(arena, "{s}/.config/nvim", .{home}),
    };
}

/// The settings key that holds named ACP agent entries per client.
fn clientSectionKey(k: ClientKind) []const u8 {
    return switch (k) {
        .zed, .jetbrains => "agent_servers",
        .vscode => "acp.agents",
        .nvim => unreachable,
    };
}

/// The in-editor action that finishes the integration — surfaced in the step
/// output so the transcript itself tells the user where to click.
fn clientNextStep(k: ClientKind) []const u8 {
    return switch (k) {
        .zed => "open the Agent Panel, click +, and pick tau",
        .vscode => "install the ACP Client extension, run 'ACP: Connect to Agent', pick tau",
        .jetbrains => "open the AI Chat tool window and pick tau in the agent selector",
        .nvim => "pick the tau provider/adapter in your plugin (e.g. :AvanteSwitchProvider)",
    };
}

/// Where a paste-ready snippet goes when setup can't (or must not) edit the
/// real settings file: ~/.config/tau/snippets/.
fn snippetPath(arena: std.mem.Allocator, home: []const u8, k: ClientKind) ![]u8 {
    const ext: []const u8 = if (k == .nvim) "lua" else "jsonc";
    return std.fmt.allocPrint(arena, "{s}/.config/tau/snippets/{s}.{s}", .{ home, clientName(k), ext });
}

fn dirExists(io: std.Io, path: []const u8) bool {
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return st.kind == .directory;
}

/// Full settings-file content for a client whose file doesn't exist yet —
/// a minimal document containing just the tau entry.
fn renderClientJson(arena: std.mem.Allocator, k: ClientKind, command: []const u8) ![]u8 {
    var esc: std.ArrayList(u8) = .empty;
    try json.escapeInto(arena, &esc, command);
    const cmd = esc.items;
    return switch (k) {
        .zed => std.fmt.allocPrint(arena,
            \\{{
            \\  "agent_servers": {{
            \\    "tau": {{
            \\      "type": "custom",
            \\      "command": "{s}",
            \\      "args": ["acp", "serve"],
            \\      "env": {{}}
            \\    }}
            \\  }}
            \\}}
            \\
        , .{cmd}),
        .vscode => std.fmt.allocPrint(arena,
            \\{{
            \\  "acp.agents": {{
            \\    "tau": {{
            \\      "command": "{s}",
            \\      "args": ["acp", "serve"],
            \\      "env": {{}}
            \\    }}
            \\  }}
            \\}}
            \\
        , .{cmd}),
        .jetbrains => std.fmt.allocPrint(arena,
            \\{{
            \\  "agent_servers": {{
            \\    "tau": {{
            \\      "command": "{s}",
            \\      "args": ["acp", "serve"],
            \\      "env": {{}}
            \\    }}
            \\  }}
            \\}}
            \\
        , .{cmd}),
        .nvim => unreachable,
    };
}

/// The JSONC fragment a user pastes into an existing settings file. Not a
/// whole document — it splices into the top-level object by hand.
fn renderClientSnippet(arena: std.mem.Allocator, k: ClientKind, command: []const u8) ![]u8 {
    var esc: std.ArrayList(u8) = .empty;
    try json.escapeInto(arena, &esc, command);
    // Zed's agent_servers entries require "type": "custom"; the other
    // clients' entries don't carry a type field.
    const type_line: []const u8 = if (k == .zed) "    \"type\": \"custom\",\n" else "";
    const section = clientSectionKey(k);
    return std.fmt.allocPrint(arena,
        \\// tau ACP agent — merge into your {s} settings file.
        \\// If a top-level "{s}" object already exists, add just the inner
        \\// "tau" entry to it; otherwise add the whole block.
        \\"{s}": {{
        \\  "tau": {{
        \\{s}    "command": "{s}",
        \\    "args": ["acp", "serve"],
        \\    "env": {{}}
        \\  }}
        \\}}
        \\
    , .{ clientName(k), section, section, type_line, esc.items });
}

/// The ready-to-paste Lua for Neovim ACP plugins (avante.nvim and
/// CodeCompanion.nvim), written to ~/.config/tau/snippets/nvim.lua.
fn renderNvimSnippet(arena: std.mem.Allocator, command: []const u8) ![]u8 {
    return std.fmt.allocPrint(arena,
        \\-- tau ACP agent snippets for Neovim — generated by `tau setup --client nvim`.
        \\-- Paste the block for your plugin into your Neovim config and restart.
        \\-- Full guide: https://github.com/javimosch/tau/blob/master/docs/acp.md
        \\
        \\-- avante.nvim ---------------------------------------------------------------
        \\require("avante").setup({{
        \\  provider = "tau",
        \\  acp_providers = {{
        \\    ["tau"] = {{
        \\      command = "{s}",
        \\      args = {{ "acp", "serve" }},
        \\      env = {{}},
        \\    }},
        \\  }},
        \\}})
        \\-- If "tau" isn't the default provider, pick it with :AvanteSwitchProvider.
        \\
        \\-- CodeCompanion.nvim --------------------------------------------------------
        \\require("codecompanion").setup({{
        \\  adapters = {{
        \\    acp = {{
        \\      tau = function()
        \\        local helpers = require("codecompanion.adapters.acp.helpers")
        \\        return {{
        \\          name = "tau",
        \\          formatted_name = "tau",
        \\          type = "acp",
        \\          roles = {{ llm = "assistant", user = "user" }},
        \\          commands = {{
        \\            default = {{ "{s}", "acp", "serve" }},
        \\          }},
        \\          defaults = {{ timeout = 20000 }},
        \\          parameters = {{
        \\            protocolVersion = 1,
        \\            clientCapabilities = {{
        \\              fs = {{ readTextFile = true, writeTextFile = true }},
        \\            }},
        \\            clientInfo = {{ name = "CodeCompanion.nvim", version = "1.0.0" }},
        \\          }},
        \\          handlers = {{
        \\            setup = function(self) return true end,
        \\            auth = function(self) return true end,
        \\            form_messages = function(self, messages, capabilities)
        \\              return helpers.form_messages(self, messages, capabilities)
        \\            end,
        \\            on_exit = function(self, code) end,
        \\          }},
        \\        }}
        \\      end,
        \\    }},
        \\  }},
        \\}})
        \\-- Then pick the "tau" adapter in a chat buffer.
        \\
    , .{ command, command });
}

/// Whether existing settings text already carries a "tau" entry in the
/// client's agent section. Returns null when the file can't be parsed —
/// setup then reports the client as "manual" instead of guessing. JSONC
/// comments are stripped first; trailing commas still fail the parse.
fn hasTauEntry(arena: std.mem.Allocator, k: ClientKind, bytes: []const u8) ?bool {
    const stripped = configfile.stripComments(arena, bytes) catch return null;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, stripped, .{}) catch return null;
    const section = switch (parsed) {
        .object => |o| o.get(clientSectionKey(k)) orelse return false,
        else => return false,
    };
    const agents = switch (section) {
        .object => |o| o,
        else => return false,
    };
    return agents.get("tau") != null;
}

/// The clients setup should configure: explicit --client (validated
/// upstream; "all" expands). Empty when the flag wasn't given — detection is
/// only reported, never acted on.
fn resolveClients(arena: std.mem.Allocator, cfg: Config) ![]ClientKind {
    var list: std.ArrayList(ClientKind) = .empty;
    if (cfg.setup_client) |s| {
        if (std.mem.eql(u8, s, "all")) {
            try list.appendSlice(arena, &.{ .zed, .nvim, .vscode, .jetbrains });
        } else if (parseClientName(s)) |k| {
            try list.append(arena, k);
        }
    }
    return list.toOwnedSlice(arena);
}

/// How one client's configuration ended.
const ClientOutcome = enum { installed, already_installed, manual, failed };

/// Configure one client and append its JSON entry to `entries` — a
/// `[`-opened list where `first` suppresses the comma. Never touches an
/// existing settings file: when the file is absent a minimal one is written,
/// when it's present without a "tau" entry a paste-ready snippet lands in
/// ~/.config/tau/snippets/ instead (existing files are JSONC — rewriting
/// them would destroy user comments).
fn configureClient(io: std.Io, arena: std.mem.Allocator, entries: *std.ArrayList(u8), first: bool, home: []const u8, k: ClientKind, command: []const u8) !ClientOutcome {
    if (!first) try entries.append(arena, ',');
    try entries.appendSlice(arena, "{\"client\":");
    try js(arena, entries, clientName(k));

    const fail = struct {
        fn f(a: std.mem.Allocator, e: *std.ArrayList(u8), path: []const u8, err: anyerror) !void {
            try e.appendSlice(a, ",\"status\":\"failed\",\"message\":");
            const msg = try std.fmt.allocPrint(a, "could not write {s}: {s}", .{ path, @errorName(err) });
            try js(a, e, msg);
            try e.append(a, '}');
        }
    }.f;

    if (k == .nvim) {
        // Neovim ACP plugins are configured in Lua — splicing arbitrary user
        // config is unsafe, so always emit a paste-ready snippet.
        const snip = try snippetPath(arena, home, k);
        _ = writeIfChanged(io, arena, snip, try renderNvimSnippet(arena, command)) catch |err| {
            try fail(arena, entries, snip, err);
            return .failed;
        };
        try entries.appendSlice(arena, ",\"status\":\"manual\",\"snippet_path\":");
        try js(arena, entries, snip);
        try entries.appendSlice(arena, ",\"editor_detected\":");
        try entries.appendSlice(arena, if (dirExists(io, try clientConfigDir(arena, home, k))) "true" else "false");
        try entries.appendSlice(arena, ",\"next\":");
        try js(arena, entries, clientNextStep(k));
        try entries.append(arena, '}');
        return .manual;
    }

    const path = (try clientSettingsPath(arena, home, k)).?;
    try entries.appendSlice(arena, ",\"path\":");
    try js(arena, entries, path);

    var cur: ?[]const u8 = null;
    var unreadable = false;
    if (std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited)) |b| {
        cur = b;
    } else |err| {
        unreadable = err != error.FileNotFound;
    }

    if (cur == null and !unreadable) {
        // No settings file — write a fresh minimal one.
        const wrote = writeIfChanged(io, arena, path, try renderClientJson(arena, k, command)) catch |err| {
            try fail(arena, entries, path, err);
            return .failed;
        };
        try entries.appendSlice(arena, ",\"status\":");
        try entries.appendSlice(arena, if (wrote == .written) "\"installed\"" else "\"already_installed\"");
        try entries.appendSlice(arena, ",\"command\":");
        try js(arena, entries, command);
        try entries.appendSlice(arena, ",\"next\":");
        try js(arena, entries, clientNextStep(k));
        try entries.append(arena, '}');
        return if (wrote == .written) .installed else .already_installed;
    }

    if (cur) |b| {
        if (hasTauEntry(arena, k, b) orelse false) {
            try entries.appendSlice(arena, ",\"status\":\"already_installed\",\"next\":");
            try js(arena, entries, clientNextStep(k));
            try entries.append(arena, '}');
            return .already_installed;
        }
    }

    // File exists but has no tau entry (or can't be read/parsed): emit a
    // snippet rather than rewriting a file that may carry user comments.
    const reason: []const u8 = if (unreadable)
        "could not read the existing settings file"
    else if (hasTauEntry(arena, k, cur.?) == null)
        "existing settings file did not parse as JSON/JSONC"
    else
        "existing settings file has no \"tau\" entry";

    const snip = try snippetPath(arena, home, k);
    _ = writeIfChanged(io, arena, snip, try renderClientSnippet(arena, k, command)) catch |err| {
        try fail(arena, entries, snip, err);
        return .failed;
    };
    try entries.appendSlice(arena, ",\"status\":\"manual\",\"snippet_path\":");
    try js(arena, entries, snip);
    try entries.appendSlice(arena, ",\"reason\":");
    try js(arena, entries, reason);
    try entries.appendSlice(arena, ",\"next\":");
    try js(arena, entries, "merge the snippet into your settings file by hand");
    try entries.append(arena, '}');
    return .manual;
}

/// Configure editor ACP clients for `tau acp serve`. Without --client the
/// step reports which supported editors appear installed and is skipped.
/// Returns false only on IO failures — "manual" outcomes pass the verdict
/// but carry a `next` field telling the user what to do.
fn stepClients(io: std.Io, arena: std.mem.Allocator, cfg: Config, env: *std.process.Environ.Map) !bool {
    var buf: std.ArrayList(u8) = .empty;
    const home = env.get("HOME") orelse {
        try buf.appendSlice(arena, "{\"step\":\"clients\",\"status\":\"failed\",\"message\":");
        try js(arena, &buf, "HOME is not set — cannot locate editor config directories");
        try buf.appendSlice(arena, "}");
        emit(&buf);
        return false;
    };

    const clients = try resolveClients(arena, cfg);
    if (clients.len == 0) {
        try buf.appendSlice(arena, "{\"step\":\"clients\",\"status\":\"skipped\",\"detected\":[");
        var first = true;
        for ([_]ClientKind{ .zed, .nvim, .vscode, .jetbrains }) |k| {
            if (dirExists(io, try clientConfigDir(arena, home, k))) {
                if (!first) try buf.append(arena, ',');
                first = false;
                try js(arena, &buf, clientName(k));
            }
        }
        try buf.appendSlice(arena, "],\"hint\":");
        try js(arena, &buf, "re-run with --client zed|nvim|vscode|jetbrains|all to write editor ACP config");
        try buf.appendSlice(arena, "}");
        emit(&buf);
        return true;
    }

    // GUI editors often can't resolve a bare "tau" from PATH — pin the
    // absolute path of this binary so the editor's spawn env can't miss it.
    const command: []const u8 = std.process.executablePathAlloc(io, arena) catch "tau";

    var entries: std.ArrayList(u8) = .empty;
    try entries.append(arena, '[');
    var ok = true;
    var all_manual = true;
    for (clients, 0..) |k, i| {
        const outcome = try configureClient(io, arena, &entries, i == 0, home, k, command);
        if (outcome == .failed) ok = false;
        if (outcome != .manual) all_manual = false;
    }
    try entries.append(arena, ']');

    try buf.appendSlice(arena, "{\"step\":\"clients\",\"status\":");
    try buf.appendSlice(arena, if (!ok) "\"failed\"" else if (all_manual) "\"manual\"" else "\"installed\"");
    try buf.appendSlice(arena, ",\"clients\":");
    try buf.appendSlice(arena, entries.items);
    try buf.appendSlice(arena, "}");
    emit(&buf);
    return ok;
}

// --- Driver ---------------------------------------------------------------

/// Run init + completions + clients + doctor, emitting one NDJSON object per step and a
/// final `{"step":"setup","ok":...}` verdict. Exit 0 when all steps pass (a
/// detection skip on completions or clients, and manual client outcomes,
/// still pass); 1 on any failure — including a doctor report with failed
/// checks, since onboarding is not healthy yet.
pub fn run(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, cfg: Config, env: *std.process.Environ.Map) !u8 {
    var ok = try stepInit(io, arena, cfg, env);
    if (!try stepCompletions(io, arena, cfg, env)) ok = false;
    if (!try stepClients(io, arena, cfg, env)) ok = false;

    var buf: std.ArrayList(u8) = .empty;
    const rep = try doctor.collectReport(io, gpa, arena, cfg, env);
    try buf.appendSlice(arena, "{\"step\":\"doctor\",\"report\":");
    try buf.appendSlice(arena, if (isJsonObject(rep.json)) rep.json else "{}");
    try buf.appendSlice(arena, "}");
    emit(&buf);
    if (!rep.ok) ok = false;

    try buf.appendSlice(arena, "{\"step\":\"setup\",\"ok\":");
    try buf.appendSlice(arena, if (ok) "true" else "false");
    try buf.appendSlice(arena, ",\"version\":");
    try js(arena, &buf, version);
    try buf.appendSlice(arena, "}");
    emit(&buf);
    return if (ok) 0 else 1;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
const testing = std.testing;

fn envWith(arena: std.mem.Allocator, pairs: []const [2][]const u8) !std.process.Environ.Map {
    var env = std.process.Environ.Map.init(arena);
    for (pairs) |kv| try env.put(kv[0], kv[1]);
    return env;
}

test "parseShellName accepts supported shells, powershell alias, .exe suffix" {
    try testing.expectEqual(ShellKind.bash, parseShellName("bash").?);
    try testing.expectEqual(ShellKind.zsh, parseShellName("zsh").?);
    try testing.expectEqual(ShellKind.fish, parseShellName("fish").?);
    try testing.expectEqual(ShellKind.pwsh, parseShellName("pwsh").?);
    try testing.expectEqual(ShellKind.pwsh, parseShellName("powershell").?);
    try testing.expectEqual(ShellKind.bash, parseShellName("bash.exe").?);
    try testing.expect(parseShellName("tcsh") == null);
    try testing.expect(parseShellName("") == null);
}

test "detectShell uses the $SHELL basename and ignores unknown shells" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var env1 = try envWith(a, &.{.{ "SHELL", "/bin/zsh" }});
    try testing.expectEqual(ShellKind.zsh, detectShell(&env1).?);

    var env2 = try envWith(a, &.{.{ "SHELL", "fish" }});
    try testing.expectEqual(ShellKind.fish, detectShell(&env2).?);

    var env3 = try envWith(a, &.{.{ "SHELL", "/usr/bin/tcsh" }});
    try testing.expect(detectShell(&env3) == null);

    var env4 = try envWith(a, &.{.{ "HOME", "/x" }});
    try testing.expect(detectShell(&env4) == null);
}

test "installPath mirrors completions/README.md destinations" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqualStrings(
        "/h/.local/share/bash-completion/completions/tau",
        try installPath(a, "/h", .bash),
    );
    try testing.expectEqualStrings("/h/.zsh/completions/_tau", try installPath(a, "/h", .zsh));
    try testing.expectEqualStrings("/h/.config/fish/completions/tau.fish", try installPath(a, "/h", .fish));
    try testing.expectEqualStrings("/h/.config/tau/completions/tau.ps1", try installPath(a, "/h", .pwsh));
}

test "resolveShells: --shell beats $SHELL, 'all' expands to every shell" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var env = try envWith(a, &.{.{ "SHELL", "/bin/bash" }});

    const detected = try resolveShells(a, .{}, &env);
    try testing.expectEqual(@as(usize, 1), detected.len);
    try testing.expectEqual(ShellKind.bash, detected[0]);

    const explicit = try resolveShells(a, .{ .setup_shell = "fish" }, &env);
    try testing.expectEqual(@as(usize, 1), explicit.len);
    try testing.expectEqual(ShellKind.fish, explicit[0]);

    const all = try resolveShells(a, .{ .setup_shell = "all" }, &env);
    try testing.expectEqual(@as(usize, 4), all.len);

    var env2 = try envWith(a, &.{.{ "HOME", "/x" }});
    const none = try resolveShells(a, .{}, &env2);
    try testing.expectEqual(@as(usize, 0), none.len);
}

test "writeIfChanged writes once then reports unchanged" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    const p = try std.fmt.allocPrint(a, "{s}/sub/dir/f.txt", .{root});

    try testing.expectEqual(WriteResult.written, try writeIfChanged(io, a, p, "abc"));
    try testing.expectEqual(WriteResult.unchanged, try writeIfChanged(io, a, p, "abc"));
    try testing.expectEqual(WriteResult.written, try writeIfChanged(io, a, p, "abd"));
}

test "ensureRcBlock appends the marker once and is idempotent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    const rc = try std.fmt.allocPrint(a, "{s}/.zshrc", .{root});

    // Missing file -> created with the block.
    try testing.expectEqual(RcResult.appended, try ensureRcBlock(io, a, rc, "# tau completions\nfpath=(x $fpath)\n"));
    // Second run detects the marker -> no duplicate.
    try testing.expectEqual(RcResult.present, try ensureRcBlock(io, a, rc, "# tau completions\nfpath=(x $fpath)\n"));

    const got = try std.Io.Dir.cwd().readFileAlloc(io, rc, a, .unlimited);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, got, rc_marker));

    // Existing content without a trailing newline still gets a clean join.
    _ = try writeIfChanged(io, a, rc, "export A=1");
    try testing.expectEqual(RcResult.appended, try ensureRcBlock(io, a, rc, "# tau completions\nfpath=(x $fpath)\n"));
    const got2 = try std.Io.Dir.cwd().readFileAlloc(io, rc, a, .unlimited);
    try testing.expect(std.mem.indexOf(u8, got2, "export A=1\n# tau completions\n") != null);
}

test "parseClientName accepts supported clients and the code alias" {
    try testing.expectEqual(ClientKind.zed, parseClientName("zed").?);
    try testing.expectEqual(ClientKind.nvim, parseClientName("nvim").?);
    try testing.expectEqual(ClientKind.vscode, parseClientName("vscode").?);
    try testing.expectEqual(ClientKind.vscode, parseClientName("code").?);
    try testing.expectEqual(ClientKind.jetbrains, parseClientName("jetbrains").?);
    try testing.expect(parseClientName("emacs") == null);
    try testing.expect(parseClientName("") == null);
}

test "clientSettingsPath matches the docs/acp.md targets (nvim has none)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqualStrings(
        "/h/.config/zed/settings.json",
        (try clientSettingsPath(a, "/h", .zed)).?,
    );
    try testing.expectEqualStrings(
        "/h/.config/Code/User/settings.json",
        (try clientSettingsPath(a, "/h", .vscode)).?,
    );
    try testing.expectEqualStrings(
        "/h/.jetbrains/acp.json",
        (try clientSettingsPath(a, "/h", .jetbrains)).?,
    );
    try testing.expect((try clientSettingsPath(a, "/h", .nvim)) == null);
}

test "resolveClients: --client picks one, 'all' expands, null is empty" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqual(@as(usize, 0), (try resolveClients(a, .{})).len);

    const one = try resolveClients(a, .{ .setup_client = "zed" });
    try testing.expectEqual(@as(usize, 1), one.len);
    try testing.expectEqual(ClientKind.zed, one[0]);

    const all = try resolveClients(a, .{ .setup_client = "all" });
    try testing.expectEqual(@as(usize, 4), all.len);
}

test "renderClientJson emits a parseable minimal file with the tau entry" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    for ([_]ClientKind{ .zed, .vscode, .jetbrains }) |k| {
        const body = try renderClientJson(a, k, "/abs/path/tau");
        // Must parse as JSON and already satisfy hasTauEntry.
        try testing.expectEqual(@as(?bool, true), hasTauEntry(a, k, body));
        try testing.expect(std.mem.indexOf(u8, body, "\"/abs/path/tau\"") != null);
        try testing.expect(std.mem.indexOf(u8, body, "[\"acp\", \"serve\"]") != null);
    }

    const zed = try renderClientJson(a, .zed, "tau");
    try testing.expect(std.mem.indexOf(u8, zed, "\"type\": \"custom\"") != null);
    const jb = try renderClientJson(a, .jetbrains, "tau");
    try testing.expect(std.mem.indexOf(u8, jb, "\"type\"") == null);
}

test "hasTauEntry finds the tau key through JSONC comments" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const with_tau =
        \\{
        \\  // my zed settings
        \\  "theme": "dark",
        \\  "agent_servers": {
        \\    "tau": { "type": "custom", "command": "tau" }
        \\  }
        \\}
    ;
    try testing.expectEqual(@as(?bool, true), hasTauEntry(a, .zed, with_tau));
    // Same file, but the vscode section doesn't see zed's key.
    try testing.expectEqual(@as(?bool, false), hasTauEntry(a, .vscode, with_tau));

    const without_tau = "{ \"agent_servers\": { \"other\": {} } }";
    try testing.expectEqual(@as(?bool, false), hasTauEntry(a, .zed, without_tau));

    try testing.expect(hasTauEntry(a, .zed, "not json at all") == null);
    try testing.expectEqual(@as(?bool, false), hasTauEntry(a, .zed, "[1,2]"));
}

test "configureClient installs a fresh zed settings file, then detects it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(io, ".", a);

    var entries: std.ArrayList(u8) = .empty;
    const oc = try configureClient(io, a, &entries, true, home, .zed, "/abs/tau");
    try testing.expectEqual(ClientOutcome.installed, oc);
    try testing.expect(std.mem.indexOf(u8, entries.items, "\"status\":\"installed\"") != null);

    const got = try std.Io.Dir.cwd().readFileAlloc(
        io,
        try std.fmt.allocPrint(a, "{s}/.config/zed/settings.json", .{home}),
        a,
        .unlimited,
    );
    try testing.expectEqual(@as(?bool, true), hasTauEntry(a, .zed, got));

    // Second run: the tau entry is detected, nothing is rewritten.
    entries.clearRetainingCapacity();
    const oc2 = try configureClient(io, a, &entries, true, home, .zed, "/abs/tau");
    try testing.expectEqual(ClientOutcome.already_installed, oc2);
}

test "configureClient leaves an existing settings file alone and emits a snippet" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(io, ".", a);

    const sp = try std.fmt.allocPrint(a, "{s}/.config/zed/settings.json", .{home});
    const orig = "{\n  // user comment must survive\n  \"vim_mode\": true\n}\n";
    _ = try writeIfChanged(io, a, sp, orig);

    var entries: std.ArrayList(u8) = .empty;
    const oc = try configureClient(io, a, &entries, true, home, .zed, "/abs/tau");
    try testing.expectEqual(ClientOutcome.manual, oc);
    try testing.expect(std.mem.indexOf(u8, entries.items, "\"status\":\"manual\"") != null);
    try testing.expect(std.mem.indexOf(u8, entries.items, "\"snippet_path\":") != null);

    // The user's file is byte-identical — no splice, comments intact.
    const got = try std.Io.Dir.cwd().readFileAlloc(io, sp, a, .unlimited);
    try testing.expectEqualStrings(orig, got);

    const snip = try std.Io.Dir.cwd().readFileAlloc(
        io,
        try std.fmt.allocPrint(a, "{s}/.config/tau/snippets/zed.jsonc", .{home}),
        a,
        .unlimited,
    );
    try testing.expect(std.mem.indexOf(u8, snip, "\"agent_servers\"") != null);
    try testing.expect(std.mem.indexOf(u8, snip, "/abs/tau") != null);
}

test "configureClient nvim always writes a lua snippet and reports manual" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(io, ".", a);

    var entries: std.ArrayList(u8) = .empty;
    const oc = try configureClient(io, a, &entries, true, home, .nvim, "/abs/tau");
    try testing.expectEqual(ClientOutcome.manual, oc);
    try testing.expect(std.mem.indexOf(u8, entries.items, "\"editor_detected\":false") != null);

    const snip = try std.Io.Dir.cwd().readFileAlloc(
        io,
        try std.fmt.allocPrint(a, "{s}/.config/tau/snippets/nvim.lua", .{home}),
        a,
        .unlimited,
    );
    try testing.expect(std.mem.indexOf(u8, snip, "acp_providers") != null);
    try testing.expect(std.mem.indexOf(u8, snip, "codecompanion") != null);
    try testing.expect(std.mem.indexOf(u8, snip, "/abs/tau") != null);
}
