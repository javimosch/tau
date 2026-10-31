// `tau setup` — one-shot onboarding: scaffold ~/.config/tau/config.json
// (init), install shell completions for the detected shell, configure editor
// ACP clients (--client), then embed the `tau doctor` health report. Emits
// one NDJSON object per step plus a final verdict line on stdout; exit 0
// when every step is ok/skipped, 1 otherwise. Idempotent: an existing config
// is kept, already-installed completions and configured clients are
// detected, and doctor is read-only. Key material is never printed.
//
// Unattended contract (`--yes`/`--non-interactive`, or TAU_YES /
// TAU_NONINTERACTIVE env): setup never prompts and never reads stdin — the
// flags don't relax a gate, they declare intent so scripts can assert on the
// verdict's "non_interactive"/"yes" fields. --shell/--client env equivalents
// (TAU_SETUP_SHELL, TAU_SETUP_CLIENT) are resolved at parse time (flag >
// env > detect). CI is deliberately not auto-detected.
//
// Preview contract (`--dry-run`): every step still resolves and reads the
// real filesystem, but no file is created or modified — write outcomes are
// reported as "would_create"/"would_install"/"would_append" and each
// write-capable step object plus the verdict carry "dry_run":true. Read-only
// outcomes (exists/already_installed/present/manual/skipped/failed) keep
// their normal names so a dry run reports the plan in the same vocabulary.

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

pub fn shellName(k: ShellKind) []const u8 {
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
pub fn shellContent(k: ShellKind) []const u8 {
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
pub fn rcPath(arena: std.mem.Allocator, home: []const u8, k: ShellKind) !?[]u8 {
    return switch (k) {
        .bash, .fish => null,
        .zsh => try std.fmt.allocPrint(arena, "{s}/.zshrc", .{home}),
        // pwsh profile location on Linux/macOS. Windows users can copy the
        // same line into the profile shown by `pwsh -NoProfile -c '$PROFILE'`.
        .pwsh => try std.fmt.allocPrint(arena, "{s}/.config/powershell/Microsoft.PowerShell_profile.ps1", .{home}),
    };
}

/// The block appended to rcPath when rc_marker is not already present.
pub fn rcBlock(arena: std.mem.Allocator, k: ShellKind) ![]u8 {
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
/// differs. Returns whether the file was actually written. When `dry` is
/// set nothing is written: a differing (or missing) file reports
/// `.would_write` so callers can preview the change.
pub const WriteResult = enum { written, unchanged, would_write };

pub fn writeIfChanged(io: std.Io, arena: std.mem.Allocator, path: []const u8, data: []const u8, dry: bool) !WriteResult {
    if (std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited)) |cur| {
        if (std.mem.eql(u8, cur, data)) return .unchanged;
    } else |_| {}
    if (dry) return .would_write;
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| {
        std.Io.Dir.cwd().createDirPath(io, path[0..idx]) catch {};
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
    return .written;
}

/// Append `block` to the rc file unless it already carries rc_marker.
/// `would_append` is returned in dry-run mode when the marker is absent.
pub const RcResult = enum { appended, present, would_append };

pub fn ensureRcBlock(io: std.Io, arena: std.mem.Allocator, path: []const u8, block: []const u8, dry: bool) !RcResult {
    const cur = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited) catch "";
    if (std.mem.indexOf(u8, cur, rc_marker) != null) return .present;
    if (dry) return .would_append;
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, cur);
    if (cur.len > 0 and !std.mem.endsWith(u8, cur, "\n")) try out.append(arena, '\n');
    try out.appendSlice(arena, block);
    _ = try writeIfChanged(io, arena, path, out.items, false);
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
/// step failed (e.g. HOME unset or the write failed). In dry-run mode the
/// scaffold is rendered and compared but never written — the step reports
/// "would_create".
fn stepInit(io: std.Io, arena: std.mem.Allocator, cfg: Config, env: *std.process.Environ.Map) !bool {
    const dry = cfg.setup_dry_run;
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
        _ = writeIfChanged(io, arena, path, body, dry) catch |err| {
            try buf.appendSlice(arena, "\"failed\",\"message\":");
            const msg = try std.fmt.allocPrint(arena, "could not write {s}: {s}", .{ path, @errorName(err) });
            try js(arena, &buf, msg);
            try buf.append(arena, '}');
            emit(&buf);
            return false;
        };
        try buf.appendSlice(arena, if (dry) "\"would_create\"" else "\"created\"");
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
    try buf.appendSlice(arena, "]");
    if (dry) try buf.appendSlice(arena, ",\"dry_run\":true");
    try buf.appendSlice(arena, "}");
    emit(&buf);
    return true;
}

// --- Step 2: shell completions ---------------------------------------------

/// The install state of one shell's completion script — reported by `tau
/// doctor` (shell_completions check) and remediated by `tau doctor --fix`.
pub const CompletionState = enum { installed, missing, outdated, rc_missing };

/// Inspect shell `k`'s completion under `home`: absent-or-unreadable script
/// -> missing; present but differing from the embedded script -> outdated
/// (upgrade needed); script current but the rc hook absent -> rc_missing.
pub fn completionState(io: std.Io, arena: std.mem.Allocator, home: []const u8, k: ShellKind) !CompletionState {
    const path = try installPath(arena, home, k);
    const cur = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited) catch return .missing;
    if (!std.mem.eql(u8, cur, shellContent(k))) return .outdated;
    if (try rcPath(arena, home, k)) |rp| {
        const rc = std.Io.Dir.cwd().readFileAlloc(io, rp, arena, .unlimited) catch "";
        if (std.mem.indexOf(u8, rc, rc_marker) == null) return .rc_missing;
    }
    return .installed;
}

/// Result of installing (or repairing) one shell's completions.
pub const CompletionInstall = struct {
    path: []const u8,
    wrote: WriteResult,
    /// Shells that need an rc hook set rc_path; rc_status is null when the rc
    /// write failed (rc_failed mirrors that as a bool for callers).
    rc_path: ?[]const u8 = null,
    rc_status: ?RcResult = null,
    rc_failed: bool = false,
};

/// Write the completion script for shell `k` (creating parent dirs) and, for
/// shells that need one, append the rc hook unless the marker is present.
/// Shared by `tau setup` and `tau doctor --fix`. When `dry` is set nothing
/// is written — `wrote`/`rc_status` report `.would_write`/`.would_append`.
pub fn installCompletion(io: std.Io, arena: std.mem.Allocator, home: []const u8, k: ShellKind, dry: bool) !CompletionInstall {
    const path = try installPath(arena, home, k);
    const wrote = try writeIfChanged(io, arena, path, shellContent(k), dry);
    var out: CompletionInstall = .{ .path = path, .wrote = wrote };
    if (try rcPath(arena, home, k)) |rp| {
        out.rc_path = rp;
        if (ensureRcBlock(io, arena, rp, try rcBlock(arena, k), dry)) |r| {
            out.rc_status = r;
        } else |_| {
            out.rc_failed = true;
        }
    }
    if (k == .zsh and !dry) {
        // Drop the cached completion dump so the new _tau is picked up.
        const dump = try std.fmt.allocPrint(arena, "{s}/.zcompdump", .{home});
        std.Io.Dir.cwd().deleteFile(io, dump) catch {};
    }
    return out;
}

/// The shells setup should install for: explicit --shell (validated upstream),
/// or the $SHELL-detected one. Empty when detection fails.
pub fn resolveShells(arena: std.mem.Allocator, cfg: Config, env: *std.process.Environ.Map) ![]ShellKind {
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

/// What installOne did (or, in dry-run mode, would do) for one shell.
const InstallOneOutcome = enum { failed, no_change, changed, would_change };

/// Install one shell's completion script (+ rc hook when the shell needs it)
/// and append its JSON entry to `shells` — a `[`-opened list where `first`
/// says no comma is needed yet. In dry-run mode a pending change reports
/// "would_install"/"would_append" and nothing is written.
fn installOne(io: std.Io, arena: std.mem.Allocator, shells: *std.ArrayList(u8), first: bool, home: []const u8, k: ShellKind, dry: bool) !InstallOneOutcome {
    if (!first) try shells.append(arena, ',');

    try shells.appendSlice(arena, "{\"shell\":");
    try js(arena, shells, shellName(k));

    const inst = installCompletion(io, arena, home, k, dry) catch |err| {
        const path = installPath(arena, home, k) catch "?";
        try shells.appendSlice(arena, ",\"status\":\"failed\",\"message\":");
        const msg = try std.fmt.allocPrint(arena, "could not write {s}: {s}", .{ path, @errorName(err) });
        try js(arena, shells, msg);
        try shells.append(arena, '}');
        return .failed;
    };
    const ok = !inst.rc_failed;

    if (inst.rc_path) |rp| {
        try shells.appendSlice(arena, ",\"rc\":");
        try js(arena, shells, rp);
        try shells.appendSlice(arena, ",\"rc_status\":");
        try js(arena, shells, if (inst.rc_status) |r| @tagName(r) else "failed");
    }

    try shells.appendSlice(arena, ",\"status\":");
    if (!ok) {
        try shells.appendSlice(arena, "\"failed\"");
    } else {
        try shells.appendSlice(arena, switch (inst.wrote) {
            .would_write => "\"would_install\"",
            .written => "\"installed\"",
            .unchanged => "\"already_installed\"",
        });
    }
    try shells.appendSlice(arena, ",\"path\":");
    try js(arena, shells, inst.path);
    switch (k) {
        .bash => {
            try shells.appendSlice(arena, ",\"note\":");
            try js(arena, shells, "requires bash-completion; otherwise source this file from ~/.bashrc");
        },
        else => {},
    }
    try shells.append(arena, '}');
    if (!ok) return .failed;
    if (inst.wrote == .would_write or inst.rc_status == .would_append) return .would_change;
    if (inst.wrote == .written or inst.rc_status == .appended) return .changed;
    return .no_change;
}

/// Install completions for every resolved shell. Returns false when any
/// install failed; a detection skip is reported but not a failure. In
/// dry-run mode nothing is written: the step status is "would_install" when
/// any shell has a pending change, "installed" when everything is already
/// current.
fn stepCompletions(io: std.Io, arena: std.mem.Allocator, cfg: Config, env: *std.process.Environ.Map) !bool {
    const dry = cfg.setup_dry_run;
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
    var any_would = false;
    for (shells, 0..) |k, i| {
        switch (try installOne(io, arena, &entries, i == 0, home, k, dry)) {
            .failed => ok = false,
            .would_change => any_would = true,
            else => {},
        }
    }
    try entries.append(arena, ']');

    try buf.appendSlice(arena, "{\"step\":\"completions\",\"status\":");
    if (!ok) {
        try buf.appendSlice(arena, "\"failed\"");
    } else if (any_would) {
        try buf.appendSlice(arena, "\"would_install\"");
    } else {
        try buf.appendSlice(arena, "\"installed\"");
    }
    try buf.appendSlice(arena, ",\"shells\":");
    try buf.appendSlice(arena, entries.items);
    if (dry) try buf.appendSlice(arena, ",\"dry_run\":true");
    try buf.appendSlice(arena, "}");
    emit(&buf);
    return ok;
}

// --- Step 3: editor ACP clients --------------------------------------------

/// Editor clients setup can configure to spawn `tau acp serve`.
pub const ClientKind = enum { zed, nvim, vscode, jetbrains, windsurf, gemini, claude_desktop };

/// Every ClientKind, in the order `--client all` expands and detection
/// iterates: direct ACP clients first, then the MCP-bridge clients.
pub const all_clients = [_]ClientKind{ .zed, .nvim, .vscode, .jetbrains, .windsurf, .gemini, .claude_desktop };

pub fn clientName(k: ClientKind) []const u8 {
    return switch (k) {
        .zed => "zed",
        .nvim => "nvim",
        .vscode => "vscode",
        .jetbrains => "jetbrains",
        .windsurf => "windsurf",
        .gemini => "gemini",
        .claude_desktop => "claude-desktop",
    };
}

/// Map a client name (as passed to --client) to a ClientKind. "code" is an
/// alias for vscode, "gemini-cli" for gemini, "claude" for claude-desktop.
pub fn parseClientName(name: []const u8) ?ClientKind {
    if (std.mem.eql(u8, name, "zed")) return .zed;
    if (std.mem.eql(u8, name, "nvim")) return .nvim;
    if (std.mem.eql(u8, name, "vscode") or std.mem.eql(u8, name, "code")) return .vscode;
    if (std.mem.eql(u8, name, "jetbrains")) return .jetbrains;
    if (std.mem.eql(u8, name, "windsurf")) return .windsurf;
    if (std.mem.eql(u8, name, "gemini") or std.mem.eql(u8, name, "gemini-cli")) return .gemini;
    if (std.mem.eql(u8, name, "claude-desktop") or std.mem.eql(u8, name, "claude")) return .claude_desktop;
    return null;
}

/// Clients that can't spawn `tau acp serve` directly — they speak MCP, not
/// ACP — so setup wires them to the mcacp MCP→ACP bridge instead. Their
/// settings entry launches the bridge (`npx mcacp`); the bridge's own
/// config (~/.config/mcacp/mcacp.json) carries the real tau agent entry.
pub fn clientUsesBridge(k: ClientKind) bool {
    return switch (k) {
        .windsurf, .gemini, .claude_desktop => true,
        else => false,
    };
}

/// The object key the client's agent section must carry — "tau" for direct
/// ACP clients, "mcacp" (the bridge server name) for MCP-bridge clients.
fn clientEntryName(k: ClientKind) []const u8 {
    return if (clientUsesBridge(k)) "mcacp" else "tau";
}

/// The JSON/JSONC settings file that carries the client config, or null for
/// nvim (its ACP plugins are configured in Lua — see renderNvimSnippet).
/// Linux paths; docs/acp.md lists equivalents for other platforms.
pub fn clientSettingsPath(arena: std.mem.Allocator, home: []const u8, k: ClientKind) !?[]u8 {
    return switch (k) {
        .zed => try std.fmt.allocPrint(arena, "{s}/.config/zed/settings.json", .{home}),
        .vscode => try std.fmt.allocPrint(arena, "{s}/.config/Code/User/settings.json", .{home}),
        .jetbrains => try std.fmt.allocPrint(arena, "{s}/.jetbrains/acp.json", .{home}),
        .windsurf => try std.fmt.allocPrint(arena, "{s}/.codeium/windsurf/mcp_config.json", .{home}),
        .gemini => try std.fmt.allocPrint(arena, "{s}/.gemini/settings.json", .{home}),
        .claude_desktop => try std.fmt.allocPrint(arena, "{s}/.config/Claude/claude_desktop_config.json", .{home}),
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
        .windsurf => std.fmt.allocPrint(arena, "{s}/.codeium/windsurf", .{home}),
        .gemini => std.fmt.allocPrint(arena, "{s}/.gemini", .{home}),
        .claude_desktop => std.fmt.allocPrint(arena, "{s}/.config/Claude", .{home}),
        .nvim => std.fmt.allocPrint(arena, "{s}/.config/nvim", .{home}),
    };
}

/// The settings key that holds named agent/server entries per client —
/// "mcpServers" for the MCP-bridge clients (the entry launches the bridge,
/// not tau itself).
fn clientSectionKey(k: ClientKind) []const u8 {
    return switch (k) {
        .zed, .jetbrains => "agent_servers",
        .vscode => "acp.agents",
        .windsurf, .gemini, .claude_desktop => "mcpServers",
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
        .windsurf => "install mcacp (npm i -g mcacp or npx), restart Windsurf, and confirm the mcacp server in Settings > MCP servers",
        .gemini => "install mcacp (npm i -g mcacp or npx), restart Gemini CLI, and run /mcp to see tau's tools",
        .claude_desktop => "install mcacp (npm i -g mcacp or npx), restart Claude Desktop, and find tau's tools under the mcacp server",
        .nvim => "pick the tau provider/adapter in your plugin (e.g. :AvanteSwitchProvider)",
    };
}

/// The mcacp bridge's own config — shared by every MCP-bridge client. One
/// file, one `agent_servers.tau` entry pointing at `tau acp serve`.
pub fn mcacpConfigPath(arena: std.mem.Allocator, home: []const u8) ![]u8 {
    return std.fmt.allocPrint(arena, "{s}/.config/mcacp/mcacp.json", .{home});
}

/// Where a paste-ready snippet goes when setup can't (or must not) edit the
/// real settings file: ~/.config/tau/snippets/.
fn snippetPath(arena: std.mem.Allocator, home: []const u8, k: ClientKind) ![]u8 {
    const ext: []const u8 = if (k == .nvim) "lua" else "jsonc";
    return std.fmt.allocPrint(arena, "{s}/.config/tau/snippets/{s}.{s}", .{ home, clientName(k), ext });
}

/// Where the mcacp bridge-side snippet lands when the existing mcacp.json
/// can't be touched: ~/.config/tau/snippets/mcacp.jsonc.
fn mcacpSnippetPath(arena: std.mem.Allocator, home: []const u8) ![]u8 {
    return std.fmt.allocPrint(arena, "{s}/.config/tau/snippets/mcacp.jsonc", .{home});
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
        // MCP-bridge clients launch the mcacp bridge, never tau directly —
        // their file carries no tau command path at all.
        .windsurf, .gemini, .claude_desktop => std.fmt.allocPrint(arena,
            \\{{
            \\  "mcpServers": {{
            \\    "mcacp": {{
            \\      "command": "npx",
            \\      "args": ["-y", "mcacp"]
            \\    }}
            \\  }}
            \\}}
            \\
        , .{}),
        .nvim => unreachable,
    };
}

/// Full ~/.config/mcacp/mcacp.json when absent — the bridge's agent_servers
/// section carries the real tau entry (same shape as JetBrains: no type).
fn renderMcacpJson(arena: std.mem.Allocator, command: []const u8) ![]u8 {
    var esc: std.ArrayList(u8) = .empty;
    try json.escapeInto(arena, &esc, command);
    return std.fmt.allocPrint(arena,
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
    , .{esc.items});
}

/// The JSONC fragment a user pastes into an existing settings file. Not a
/// whole document — it splices into the top-level object by hand.
fn renderClientSnippet(arena: std.mem.Allocator, k: ClientKind, command: []const u8) ![]u8 {
    if (clientUsesBridge(k)) {
        return std.fmt.allocPrint(arena,
            \\// tau via the mcacp MCP->ACP bridge — merge into your {s} settings file.
            \\// If a top-level "mcpServers" object already exists, add just the
            \\// inner "mcacp" entry to it; otherwise add the whole block. The
            \\// bridge itself is configured separately — see snippets/mcacp.jsonc.
            \\"mcpServers": {{
            \\  "mcacp": {{
            \\    "command": "npx",
            \\    "args": ["-y", "mcacp"]
            \\  }}
            \\}}
            \\
        , .{clientName(k)});
    }
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

/// The paste-ready fragment for an existing ~/.config/mcacp/mcacp.json that
/// lacks the tau entry — the bridge half of every MCP-client wiring.
fn renderMcacpSnippet(arena: std.mem.Allocator, command: []const u8) ![]u8 {
    var esc: std.ArrayList(u8) = .empty;
    try json.escapeInto(arena, &esc, command);
    return std.fmt.allocPrint(arena,
        \\// tau ACP agent for the mcacp bridge — merge into mcacp.json.
        \\// If a top-level "agent_servers" object already exists, add just the
        \\// inner "tau" entry to it; otherwise add the whole block.
        \\"agent_servers": {{
        \\  "tau": {{
        \\    "command": "{s}",
        \\    "args": ["acp", "serve"],
        \\    "env": {{}}
        \\  }}
        \\}}
        \\
    , .{esc.items});
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

/// Whether existing settings text carries `entry` inside the object at
/// `section_key`. Returns null when the file can't be parsed — callers then
/// report "manual" instead of guessing. JSONC comments are stripped first;
/// trailing commas still fail the parse.
fn sectionHasEntry(arena: std.mem.Allocator, section_key: []const u8, entry: []const u8, bytes: []const u8) ?bool {
    const stripped = configfile.stripComments(arena, bytes) catch return null;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, stripped, .{}) catch return null;
    const section = switch (parsed) {
        .object => |o| o.get(section_key) orelse return false,
        else => return false,
    };
    const agents = switch (section) {
        .object => |o| o,
        else => return false,
    };
    return agents.get(entry) != null;
}

/// Whether existing settings text already carries a "tau" entry in the
/// client's agent section ("mcacp" in mcpServers for bridge clients).
fn hasTauEntry(arena: std.mem.Allocator, k: ClientKind, bytes: []const u8) ?bool {
    return sectionHasEntry(arena, clientSectionKey(k), clientEntryName(k), bytes);
}

/// Whether existing mcacp.json text already wires tau into the bridge.
fn bridgeHasTau(arena: std.mem.Allocator, bytes: []const u8) ?bool {
    return sectionHasEntry(arena, "agent_servers", "tau", bytes);
}

/// How one client's `tau acp serve` wiring looks to `tau doctor`. nvim
/// always reports .manual_only — its plugin config is Lua and can't be
/// introspected safely; the JSON clients classify their settings file.
pub const WiringState = enum {
    /// No editor config dir — the client isn't installed here.
    not_detected,
    /// nvim: wiring lives in Lua; doctor can only point at the snippet.
    manual_only,
    /// Settings file absent — the fix writes a fresh minimal one.
    missing_file,
    /// Settings file exists but can't be read.
    unreadable,
    /// Settings file exists but isn't valid JSON/JSONC.
    unparseable,
    /// Parseable settings file with no "tau" entry in the agent section.
    no_entry,
    /// A "tau" entry exists but is broken (dead command path, wrong args,
    /// or — zed only — a missing "type":"custom").
    stale,
    /// Wired — the entry looks sane.
    ok,
};

pub const ClientWiring = struct {
    state: WiringState,
    /// Settings-file path for JSON clients (null for nvim/not_detected).
    path: ?[]const u8 = null,
    /// What makes a .stale entry broken.
    reason: ?[]const u8 = null,
};

/// The args every JSON-client tau entry must carry: ["acp", "serve"] —
/// anything else spawns the wrong command (or no agent at all).
fn acpServeArgs(e: std.json.ObjectMap) bool {
    const a = e.get("args") orelse return false;
    if (a != .array or a.array.items.len != 2) return false;
    const items = a.array.items;
    return items[0] == .string and std.mem.eql(u8, items[0].string, "acp") and
        items[1] == .string and std.mem.eql(u8, items[1].string, "serve");
}

/// Classify one client's wiring for `tau doctor`. Detection mirrors the
/// setup clients step: the editor's config dir must exist before its
/// settings file is even consulted, so doctor only reports editors that are
/// actually installed. Staleness is checked deliberately narrow — a wired
/// command that names a filesystem path must exist on disk, args must be
/// ["acp","serve"], and Zed entries need "type":"custom". A bare "tau"
/// command can't be disproved offline and stays ok.
pub fn inspectClientWiring(io: std.Io, arena: std.mem.Allocator, home: []const u8, k: ClientKind) !ClientWiring {
    if (!dirExists(io, try clientConfigDir(arena, home, k))) return .{ .state = .not_detected };
    if (k == .nvim) return .{ .state = .manual_only };
    const path = (try clientSettingsPath(arena, home, k)).?;
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited) catch |err| {
        if (err == error.FileNotFound) return .{ .state = .missing_file, .path = path };
        return .{ .state = .unreadable, .path = path };
    };
    const stripped = configfile.stripComments(arena, bytes) catch
        return .{ .state = .unparseable, .path = path };
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, stripped, .{}) catch
        return .{ .state = .unparseable, .path = path };
    const entry: ?std.json.ObjectMap = blk: {
        if (parsed != .object) break :blk null;
        const section = parsed.object.get(clientSectionKey(k)) orelse break :blk null;
        if (section != .object) break :blk null;
        const e = section.object.get(clientEntryName(k)) orelse break :blk null;
        break :blk switch (e) {
            .object => |o| o,
            else => null,
        };
    };
    const e = entry orelse return .{ .state = .no_entry, .path = path };

    if (clientUsesBridge(k)) {
        // The client-side entry launches the bridge, not tau — a command
        // string plus an args array is the whole contract. Keep it loose:
        // `npx`, a global `mcacp` binary, and containerized runs all work.
        const bcmd = e.get("command");
        if (bcmd == null or bcmd.? != .string)
            return .{ .state = .stale, .path = path, .reason = "the \"mcacp\" entry has no \"command\" string" };
        const barg = e.get("args");
        if (barg == null or barg.? != .array)
            return .{ .state = .stale, .path = path, .reason = "the \"mcacp\" entry has no \"args\" array" };
        return inspectBridgeWiring(io, arena, home, path);
    }

    if (try tauEntryStaleReason(io, arena, e)) |reason|
        return .{ .state = .stale, .path = path, .reason = reason };
    if (k == .zed) {
        const t = e.get("type");
        if (t == null or t.? != .string or !std.mem.eql(u8, t.?.string, "custom"))
            return .{ .state = .stale, .path = path, .reason = "zed entries need \"type\": \"custom\"" };
    }
    return .{ .state = .ok, .path = path };
}

/// Staleness checks every wired tau entry must pass — shared by direct
/// client settings entries and the mcacp bridge's agent_servers.tau. A wired
/// command that names a filesystem path must resolve (a moved or reinstalled
/// binary is the classic stale wiring; other stat failures are
/// undeterminable offline so they don't warn), and args must be exactly
/// ["acp","serve"]. A bare "tau" command can't be disproved offline. Returns
/// the stale reason, or null when the entry looks sane.
fn tauEntryStaleReason(io: std.Io, arena: std.mem.Allocator, e: std.json.ObjectMap) !?[]const u8 {
    const cmd = e.get("command");
    if (cmd == null or cmd.? != .string)
        return "the \"tau\" entry has no \"command\" string";
    const command = cmd.?.string;
    if (std.mem.indexOfScalar(u8, command, '/') != null) {
        if (std.Io.Dir.cwd().statFile(io, command, .{})) |st| {
            if (st.kind == .directory)
                return try std.fmt.allocPrint(arena, "wired command is a directory: {s}", .{command});
        } else |err| switch (err) {
            error.FileNotFound => return try std.fmt.allocPrint(arena, "wired command does not exist: {s}", .{command}),
            else => {},
        }
    }
    if (!acpServeArgs(e))
        return "the \"tau\" entry args are not [\"acp\", \"serve\"]";
    return null;
}

/// The bridge half of an MCP client's wiring: ~/.config/mcacp/mcacp.json
/// must exist, parse, and carry a sane agent_servers.tau entry. The client
/// file was already classified — any bridge-side defect reports .stale
/// against the client's settings path, and the reason names the bridge file.
fn inspectBridgeWiring(io: std.Io, arena: std.mem.Allocator, home: []const u8, path: []const u8) !ClientWiring {
    const bpath = try mcacpConfigPath(arena, home);
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, bpath, arena, .unlimited) catch |err| {
        const detail = if (err == error.FileNotFound)
            try std.fmt.allocPrint(arena, "mcacp bridge config missing: {s}", .{bpath})
        else
            try std.fmt.allocPrint(arena, "could not read mcacp bridge config {s}: {s}", .{ bpath, @errorName(err) });
        return .{ .state = .stale, .path = path, .reason = detail };
    };
    const stripped = configfile.stripComments(arena, bytes) catch
        return .{ .state = .stale, .path = path, .reason = try std.fmt.allocPrint(arena, "mcacp bridge config is not valid JSON/JSONC: {s}", .{bpath}) };
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, stripped, .{}) catch
        return .{ .state = .stale, .path = path, .reason = try std.fmt.allocPrint(arena, "mcacp bridge config is not valid JSON/JSONC: {s}", .{bpath}) };
    const entry: ?std.json.ObjectMap = blk: {
        if (parsed != .object) break :blk null;
        const section = parsed.object.get("agent_servers") orelse break :blk null;
        if (section != .object) break :blk null;
        const e = section.object.get("tau") orelse break :blk null;
        break :blk switch (e) {
            .object => |o| o,
            else => null,
        };
    };
    const e = entry orelse
        return .{ .state = .stale, .path = path, .reason = try std.fmt.allocPrint(arena, "mcacp bridge config has no \"tau\" entry: {s}", .{bpath}) };
    if (try tauEntryStaleReason(io, arena, e)) |reason|
        return .{ .state = .stale, .path = path, .reason = try std.fmt.allocPrint(arena, "mcacp bridge config: {s}", .{reason}) };
    return .{ .state = .ok, .path = path };
}

/// The `tau doctor --fix` remediation for one client. Mirrors `tau setup
/// --client`: a missing settings file gets a fresh minimal one (the wiring
/// is actually repaired); anything else gets the paste-ready snippet under
/// ~/.config/tau/snippets/ — existing settings files are never rewritten.
/// Bridge clients also repair the mcacp side in the same pass. Returns the
/// report detail; errors surface as a failed fix outcome.
pub fn remedyClientWiring(io: std.Io, arena: std.mem.Allocator, home: []const u8, k: ClientKind, command: []const u8) ![]const u8 {
    const w = try inspectClientWiring(io, arena, home, k);
    switch (w.state) {
        .missing_file => {
            const path = w.path.?;
            _ = try writeIfChanged(io, arena, path, try renderClientJson(arena, k, command), false);
            if (clientUsesBridge(k)) {
                const det = try ensureBridgeWiring(io, arena, home, command, false);
                return std.fmt.allocPrint(arena, "wrote minimal settings file: {s}; {s}", .{ path, det.detail });
            }
            return std.fmt.allocPrint(arena, "wrote minimal settings file: {s}", .{path});
        },
        .unreadable, .unparseable, .no_entry, .stale => {
            const snip = try snippetPath(arena, home, k);
            const wrote = try writeIfChanged(io, arena, snip, try renderClientSnippet(arena, k, command), false);
            const base: []const u8 = switch (wrote) {
                .unchanged => try std.fmt.allocPrint(arena, "snippet already up to date: {s} — merge the \"{s}\" block into {s} by hand", .{ snip, clientEntryName(k), w.path.? }),
                else => try std.fmt.allocPrint(arena, "wrote paste-ready snippet: {s} — merge the \"{s}\" block into {s} by hand", .{ snip, clientEntryName(k), w.path.? }),
            };
            if (clientUsesBridge(k)) {
                const det = try ensureBridgeWiring(io, arena, home, command, false);
                return std.fmt.allocPrint(arena, "{s}; {s}", .{ base, det.detail });
            }
            return base;
        },
        .ok => return "already wired — nothing to do",
        .not_detected, .manual_only => return error.NothingToFix,
    }
}

const BridgeDetail = struct {
    /// Short human detail for the step/fix report.
    detail: []const u8,
    /// JSON status word for the step entry ("installed", "would_install",
    /// "already_installed", "manual").
    status: []const u8,
    /// The bridge config path (always ~/.config/mcacp/mcacp.json).
    path: []const u8,
    /// Set when a snippet was (or would be) written instead of the real file.
    snippet_path: ?[]const u8 = null,
    /// How the bridge write ended — drives the client outcome.
    outcome: ClientOutcome,
};

/// Write the bridge half of an MCP-client wiring — ~/.config/mcacp/mcacp.json
/// gets a fresh agent_servers.tau file when absent (the bridge's own config
/// lives under our config dir, so writing it is safe), a paste-ready snippet
/// when it exists but can't be touched or lacks the tau entry.
fn ensureBridgeWiring(io: std.Io, arena: std.mem.Allocator, home: []const u8, command: []const u8, dry: bool) !BridgeDetail {
    const bpath = try mcacpConfigPath(arena, home);
    var cur: ?[]const u8 = null;
    var unreadable = false;
    if (std.Io.Dir.cwd().readFileAlloc(io, bpath, arena, .unlimited)) |b| {
        cur = b;
    } else |err| {
        unreadable = err != error.FileNotFound;
    }

    if (cur == null and !unreadable) {
        const wrote = try writeIfChanged(io, arena, bpath, try renderMcacpJson(arena, command), dry);
        return .{
            .detail = try std.fmt.allocPrint(arena, "wrote mcacp bridge config: {s}", .{bpath}),
            .status = if (dry) "would_install" else "installed",
            .path = bpath,
            .outcome = switch (wrote) {
                .would_write => .would_install,
                .unchanged => .already_installed,
                else => .installed,
            },
        };
    }

    if (cur != null and (bridgeHasTau(arena, cur.?) orelse false)) {
        return .{
            .detail = "mcacp bridge config already wired",
            .status = "already_installed",
            .path = bpath,
            .outcome = .already_installed,
        };
    }

    // Exists but unreadable, unparseable, or missing the tau entry — never
    // rewrite; drop a paste-ready snippet instead.
    const snip = try mcacpSnippetPath(arena, home);
    _ = try writeIfChanged(io, arena, snip, try renderMcacpSnippet(arena, command), dry);
    return .{
        .detail = try std.fmt.allocPrint(arena, "wrote mcacp paste-ready snippet: {s} — merge the \"tau\" block into {s} by hand", .{ snip, bpath }),
        .status = "manual",
        .path = bpath,
        .snippet_path = snip,
        .outcome = .manual,
    };
}

/// Close a client entry in the step's JSON array. Bridge clients append
/// bridge_path/bridge_status fields for the mcacp side first; a bridge-side
/// "manual" or "failed" downgrades the client outcome (the wiring is only
/// half done). Every other client just closes the object.
fn closeClientEntry(io: std.Io, arena: std.mem.Allocator, entries: *std.ArrayList(u8), home: []const u8, k: ClientKind, command: []const u8, dry: bool, oc: ClientOutcome) !ClientOutcome {
    if (!clientUsesBridge(k)) {
        try entries.append(arena, '}');
        return oc;
    }
    const det = ensureBridgeWiring(io, arena, home, command, dry) catch |err| {
        try entries.appendSlice(arena, ",\"bridge_status\":\"failed\",\"bridge_message\":");
        try js(arena, entries, @errorName(err));
        try entries.append(arena, '}');
        return .failed;
    };
    try entries.appendSlice(arena, ",\"bridge_path\":");
    try js(arena, entries, det.path);
    try entries.appendSlice(arena, ",\"bridge_status\":");
    try js(arena, entries, det.status);
    if (det.snippet_path) |s| {
        try entries.appendSlice(arena, ",\"bridge_snippet_path\":");
        try js(arena, entries, s);
    }
    try entries.append(arena, '}');
    return switch (det.outcome) {
        .failed => .failed,
        .manual => .manual,
        .would_install => if (oc == .failed) .failed else .would_install,
        else => oc,
    };
}

/// The clients setup should configure: explicit --client (validated
/// upstream; "all" expands). Empty when the flag wasn't given — detection is
/// only reported, never acted on.
fn resolveClients(arena: std.mem.Allocator, cfg: Config) ![]ClientKind {
    var list: std.ArrayList(ClientKind) = .empty;
    if (cfg.setup_client) |s| {
        if (std.mem.eql(u8, s, "all")) {
            try list.appendSlice(arena, &.{ .zed, .nvim, .vscode, .jetbrains, .windsurf, .gemini, .claude_desktop });
        } else if (parseClientName(s)) |k| {
            try list.append(arena, k);
        }
    }
    return list.toOwnedSlice(arena);
}

/// How one client's configuration ended. `would_install` is the dry-run
/// counterpart of `installed`: the write was previewed, not performed.
const ClientOutcome = enum { installed, already_installed, manual, failed, would_install };

/// Configure one client and append its JSON entry to `entries` — a
/// `[`-opened list where `first` suppresses the comma. Never touches an
/// existing settings file: when the file is absent a minimal one is written,
/// when it's present without a "tau" entry a paste-ready snippet lands in
/// ~/.config/tau/snippets/ instead (existing files are JSONC — rewriting
/// them would destroy user comments). In dry-run mode every write is
/// previewed: a fresh settings file reports "would_install", snippet
/// outcomes stay "manual" (snippet_path names the file that would be
/// written).
fn configureClient(io: std.Io, arena: std.mem.Allocator, entries: *std.ArrayList(u8), first: bool, home: []const u8, k: ClientKind, command: []const u8, dry: bool) !ClientOutcome {
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
        _ = writeIfChanged(io, arena, snip, try renderNvimSnippet(arena, command), dry) catch |err| {
            try fail(arena, entries, snip, err);
            return .failed;
        };
        try entries.appendSlice(arena, ",\"status\":\"manual\",\"snippet_path\":");
        try js(arena, entries, snip);
        try entries.appendSlice(arena, ",\"editor_detected\":");
        try entries.appendSlice(arena, if (dirExists(io, try clientConfigDir(arena, home, k))) "true" else "false");
        try entries.appendSlice(arena, ",\"next\":");
        try js(arena, entries, clientNextStep(k));
        return closeClientEntry(io, arena, entries, home, k, command, dry, .manual);
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
        const wrote = writeIfChanged(io, arena, path, try renderClientJson(arena, k, command), dry) catch |err| {
            try fail(arena, entries, path, err);
            return .failed;
        };
        try entries.appendSlice(arena, ",\"status\":");
        try entries.appendSlice(arena, switch (wrote) {
            .would_write => "\"would_install\"",
            .written => "\"installed\"",
            .unchanged => "\"already_installed\"",
        });
        try entries.appendSlice(arena, ",\"command\":");
        try js(arena, entries, command);
        try entries.appendSlice(arena, ",\"next\":");
        try js(arena, entries, clientNextStep(k));
        return closeClientEntry(io, arena, entries, home, k, command, dry, switch (wrote) {
            .would_write => .would_install,
            .written => .installed,
            .unchanged => .already_installed,
        });
    }

    if (cur) |b| {
        if (hasTauEntry(arena, k, b) orelse false) {
            try entries.appendSlice(arena, ",\"status\":\"already_installed\",\"next\":");
            try js(arena, entries, clientNextStep(k));
            return closeClientEntry(io, arena, entries, home, k, command, dry, .already_installed);
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
    _ = writeIfChanged(io, arena, snip, try renderClientSnippet(arena, k, command), dry) catch |err| {
        try fail(arena, entries, snip, err);
        return .failed;
    };
    try entries.appendSlice(arena, ",\"status\":\"manual\",\"snippet_path\":");
    try js(arena, entries, snip);
    try entries.appendSlice(arena, ",\"reason\":");
    try js(arena, entries, reason);
    try entries.appendSlice(arena, ",\"next\":");
    try js(arena, entries, "merge the snippet into your settings file by hand");
    return closeClientEntry(io, arena, entries, home, k, command, dry, .manual);
}

/// Configure editor ACP clients for `tau acp serve`. Without --client the
/// step reports which supported editors appear installed and is skipped.
/// Returns false only on IO failures — "manual" outcomes pass the verdict
/// but carry a `next` field telling the user what to do. In dry-run mode
/// nothing is written: the step status is "would_install" when any client
/// has a pending fresh-file write, "installed" when everything is already
/// configured.
fn stepClients(io: std.Io, arena: std.mem.Allocator, cfg: Config, env: *std.process.Environ.Map) !bool {
    const dry = cfg.setup_dry_run;
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
        for (all_clients) |k| {
            if (dirExists(io, try clientConfigDir(arena, home, k))) {
                if (!first) try buf.append(arena, ',');
                first = false;
                try js(arena, &buf, clientName(k));
            }
        }
        try buf.appendSlice(arena, "],\"hint\":");
        try js(arena, &buf, "re-run with --client zed|nvim|vscode|jetbrains|windsurf|gemini|claude-desktop|all to write editor ACP config");
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
    var any_would = false;
    for (clients, 0..) |k, i| {
        const outcome = try configureClient(io, arena, &entries, i == 0, home, k, command, dry);
        if (outcome == .failed) ok = false;
        if (outcome != .manual) all_manual = false;
        if (outcome == .would_install) any_would = true;
    }
    try entries.append(arena, ']');

    try buf.appendSlice(arena, "{\"step\":\"clients\",\"status\":");
    if (!ok) {
        try buf.appendSlice(arena, "\"failed\"");
    } else if (all_manual) {
        try buf.appendSlice(arena, "\"manual\"");
    } else if (any_would) {
        try buf.appendSlice(arena, "\"would_install\"");
    } else {
        try buf.appendSlice(arena, "\"installed\"");
    }
    try buf.appendSlice(arena, ",\"clients\":");
    try buf.appendSlice(arena, entries.items);
    if (dry) try buf.appendSlice(arena, ",\"dry_run\":true");
    try buf.appendSlice(arena, "}");
    emit(&buf);
    return ok;
}

// --- Driver ---------------------------------------------------------------

/// True when setup was explicitly declared unattended — `--yes`,
/// `--non-interactive`, or their env equivalents. Approving every write
/// (--yes) implies no human is present, so it counts too.
pub fn unattended(cfg: Config) bool {
    return cfg.setup_yes or cfg.setup_non_interactive;
}

/// Run init + completions + clients + doctor, emitting one NDJSON object per step and a
/// final `{"step":"setup","ok":...}` verdict. Exit 0 when all steps pass (a
/// detection skip on completions or clients, and manual client outcomes,
/// still pass); 1 on any failure — including a doctor report with failed
/// checks, since onboarding is not healthy yet. In unattended mode the
/// verdict carries "non_interactive":true (and "yes":true when --yes was
/// given) so scripts can confirm the contract was requested. Under
/// --dry-run the write steps preview their changes (`would_*` statuses) and
/// the verdict carries "dry_run":true.
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
    if (unattended(cfg)) try buf.appendSlice(arena, ",\"non_interactive\":true");
    if (cfg.setup_yes) try buf.appendSlice(arena, ",\"yes\":true");
    if (cfg.setup_dry_run) try buf.appendSlice(arena, ",\"dry_run\":true");
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

test "unattended is true for --yes or --non-interactive" {
    try testing.expect(!unattended(.{}));
    try testing.expect(unattended(.{ .setup_yes = true }));
    try testing.expect(unattended(.{ .setup_non_interactive = true }));
    try testing.expect(unattended(.{ .setup_yes = true, .setup_non_interactive = true }));
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

    try testing.expectEqual(WriteResult.written, try writeIfChanged(io, a, p, "abc", false));
    try testing.expectEqual(WriteResult.unchanged, try writeIfChanged(io, a, p, "abc", false));
    try testing.expectEqual(WriteResult.written, try writeIfChanged(io, a, p, "abd", false));
}

test "writeIfChanged in dry-run previews the write without touching the file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);

    // Missing file: reports would_write, creates nothing — parent dirs too.
    const p = try std.fmt.allocPrint(a, "{s}/sub/dir/f.txt", .{root});
    try testing.expectEqual(WriteResult.would_write, try writeIfChanged(io, a, p, "abc", true));
    try testing.expect(!dirExists(io, try std.fmt.allocPrint(a, "{s}/sub", .{root})));

    // Identical content is still a no-op (unchanged, not would_write).
    _ = try writeIfChanged(io, a, p, "abc", false);
    try testing.expectEqual(WriteResult.unchanged, try writeIfChanged(io, a, p, "abc", true));

    // Differing content previews, and the real bytes survive.
    try testing.expectEqual(WriteResult.would_write, try writeIfChanged(io, a, p, "abd", true));
    const got = try std.Io.Dir.cwd().readFileAlloc(io, p, a, .unlimited);
    try testing.expectEqualStrings("abc", got);
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
    try testing.expectEqual(RcResult.appended, try ensureRcBlock(io, a, rc, "# tau completions\nfpath=(x $fpath)\n", false));
    // Second run detects the marker -> no duplicate.
    try testing.expectEqual(RcResult.present, try ensureRcBlock(io, a, rc, "# tau completions\nfpath=(x $fpath)\n", false));

    const got = try std.Io.Dir.cwd().readFileAlloc(io, rc, a, .unlimited);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, got, rc_marker));

    // Existing content without a trailing newline still gets a clean join.
    _ = try writeIfChanged(io, a, rc, "export A=1", false);
    try testing.expectEqual(RcResult.appended, try ensureRcBlock(io, a, rc, "# tau completions\nfpath=(x $fpath)\n", false));
    const got2 = try std.Io.Dir.cwd().readFileAlloc(io, rc, a, .unlimited);
    try testing.expect(std.mem.indexOf(u8, got2, "export A=1\n# tau completions\n") != null);
}

test "parseClientName accepts supported clients and the code alias" {
    try testing.expectEqual(ClientKind.zed, parseClientName("zed").?);
    try testing.expectEqual(ClientKind.nvim, parseClientName("nvim").?);
    try testing.expectEqual(ClientKind.vscode, parseClientName("vscode").?);
    try testing.expectEqual(ClientKind.vscode, parseClientName("code").?);
    try testing.expectEqual(ClientKind.jetbrains, parseClientName("jetbrains").?);
    try testing.expectEqual(ClientKind.windsurf, parseClientName("windsurf").?);
    try testing.expectEqual(ClientKind.gemini, parseClientName("gemini").?);
    try testing.expectEqual(ClientKind.gemini, parseClientName("gemini-cli").?);
    try testing.expectEqual(ClientKind.claude_desktop, parseClientName("claude-desktop").?);
    try testing.expectEqual(ClientKind.claude_desktop, parseClientName("claude").?);
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
    try testing.expectEqualStrings(
        "/h/.codeium/windsurf/mcp_config.json",
        (try clientSettingsPath(a, "/h", .windsurf)).?,
    );
    try testing.expectEqualStrings(
        "/h/.gemini/settings.json",
        (try clientSettingsPath(a, "/h", .gemini)).?,
    );
    try testing.expectEqualStrings(
        "/h/.config/Claude/claude_desktop_config.json",
        (try clientSettingsPath(a, "/h", .claude_desktop)).?,
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
    try testing.expectEqual(@as(usize, all_clients.len), all.len);
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

    // MCP-bridge clients write an mcpServers.mcacp entry — the file launches
    // the bridge and never mentions the tau command path.
    for ([_]ClientKind{ .windsurf, .gemini, .claude_desktop }) |k| {
        const body = try renderClientJson(a, k, "/abs/path/tau");
        try testing.expectEqual(@as(?bool, true), hasTauEntry(a, k, body));
        try testing.expect(std.mem.indexOf(u8, body, "\"mcpServers\"") != null);
        try testing.expect(std.mem.indexOf(u8, body, "\"/abs/path/tau\"") == null);
        try testing.expect(std.mem.indexOf(u8, body, "[\"acp\", \"serve\"]") == null);
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

    // Bridge clients key on "mcacp" inside mcpServers, not "tau".
    const bridged =
        \\{
        \\  "mcpServers": {
        \\    "mcacp": { "command": "npx", "args": ["-y", "mcacp"] }
        \\  }
        \\}
    ;
    try testing.expectEqual(@as(?bool, true), hasTauEntry(a, .windsurf, bridged));
    try testing.expectEqual(@as(?bool, true), hasTauEntry(a, .gemini, bridged));
    try testing.expectEqual(@as(?bool, true), hasTauEntry(a, .claude_desktop, bridged));
    try testing.expectEqual(@as(?bool, false), hasTauEntry(a, .windsurf, with_tau));
    try testing.expectEqual(@as(?bool, false), hasTauEntry(a, .zed, bridged));

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
    const oc = try configureClient(io, a, &entries, true, home, .zed, "/abs/tau", false);
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
    const oc2 = try configureClient(io, a, &entries, true, home, .zed, "/abs/tau", false);
    try testing.expectEqual(ClientOutcome.already_installed, oc2);
}

test "configureClient in dry-run previews a fresh settings file without writing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(io, ".", a);

    var entries: std.ArrayList(u8) = .empty;
    const oc = try configureClient(io, a, &entries, true, home, .zed, "/abs/tau", true);
    try testing.expectEqual(ClientOutcome.would_install, oc);
    try testing.expect(std.mem.indexOf(u8, entries.items, "\"status\":\"would_install\"") != null);

    // Nothing landed — not even the parent .config/zed directory.
    const sp = try std.fmt.allocPrint(a, "{s}/.config/zed/settings.json", .{home});
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().readFileAlloc(io, sp, a, .unlimited));
    try testing.expect(!dirExists(io, try std.fmt.allocPrint(a, "{s}/.config/zed", .{home})));

    // Dry-run on an already-configured client still reports already_installed.
    _ = try configureClient(io, a, &entries, true, home, .zed, "/abs/tau", false);
    entries.clearRetainingCapacity();
    const oc2 = try configureClient(io, a, &entries, true, home, .zed, "/abs/tau", true);
    try testing.expectEqual(ClientOutcome.already_installed, oc2);
}

test "configureClient dry-run keeps manual outcome and writes no snippet" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(io, ".", a);

    const sp = try std.fmt.allocPrint(a, "{s}/.config/zed/settings.json", .{home});
    const orig = "{\n  // keep me\n  \"vim_mode\": true\n}\n";
    _ = try writeIfChanged(io, a, sp, orig, false);

    var entries: std.ArrayList(u8) = .empty;
    const oc = try configureClient(io, a, &entries, true, home, .zed, "/abs/tau", true);
    try testing.expectEqual(ClientOutcome.manual, oc);
    try testing.expect(std.mem.indexOf(u8, entries.items, "\"snippet_path\":") != null);

    // Neither the settings file nor the snippet file was touched.
    const got = try std.Io.Dir.cwd().readFileAlloc(io, sp, a, .unlimited);
    try testing.expectEqualStrings(orig, got);
    const snip = try std.fmt.allocPrint(a, "{s}/.config/tau/snippets/zed.jsonc", .{home});
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().readFileAlloc(io, snip, a, .unlimited));
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
    _ = try writeIfChanged(io, a, sp, orig, false);

    var entries: std.ArrayList(u8) = .empty;
    const oc = try configureClient(io, a, &entries, true, home, .zed, "/abs/tau", false);
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
    const oc = try configureClient(io, a, &entries, true, home, .nvim, "/abs/tau", false);
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

test "inspectClientWiring: detection, missing/unparseable/no-entry, staleness signals" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(io, ".", a);

    // Editor not installed -> not_detected (doctor emits no row).
    try testing.expectEqual(WiringState.not_detected, (try inspectClientWiring(io, a, home, .zed)).state);

    const zed_dir = try std.fmt.allocPrint(a, "{s}/.config/zed", .{home});
    try std.Io.Dir.cwd().createDirPath(io, zed_dir);
    const sp = try std.fmt.allocPrint(a, "{s}/settings.json", .{zed_dir});

    try testing.expectEqual(WiringState.missing_file, (try inspectClientWiring(io, a, home, .zed)).state);

    _ = try writeIfChanged(io, a, sp, "{ not json", false);
    try testing.expectEqual(WiringState.unparseable, (try inspectClientWiring(io, a, home, .zed)).state);

    _ = try writeIfChanged(io, a, sp, "{\"agent_servers\": {}}", false);
    try testing.expectEqual(WiringState.no_entry, (try inspectClientWiring(io, a, home, .zed)).state);

    // Entry whose command names a dead path -> stale.
    _ = try writeIfChanged(io, a, sp, "{\"agent_servers\": {\"tau\": {\"type\":\"custom\",\"command\":\"/missing/tau\",\"args\":[\"acp\",\"serve\"]}}}", false);
    const dead = try inspectClientWiring(io, a, home, .zed);
    try testing.expectEqual(WiringState.stale, dead.state);
    try testing.expect(std.mem.indexOf(u8, dead.reason.?, "/missing/tau") != null);

    // Live command but wrong args -> stale. The test exe is a real path.
    const exe = try std.process.executablePathAlloc(io, a);
    var esc: std.ArrayList(u8) = .empty;
    try json.escapeInto(a, &esc, exe);
    const bad_args = try std.fmt.allocPrint(a, "{{\"agent_servers\": {{\"tau\": {{\"type\":\"custom\",\"command\":\"{s}\",\"args\":[\"serve\"]}}}}}}", .{esc.items});
    _ = try writeIfChanged(io, a, sp, bad_args, false);
    const st_args = try inspectClientWiring(io, a, home, .zed);
    try testing.expectEqual(WiringState.stale, st_args.state);
    try testing.expect(std.mem.indexOf(u8, st_args.reason.?, "args") != null);

    // Zed without "type":"custom" -> stale; the same entry is fine for
    // jetbrains (no type requirement).
    const no_type = try std.fmt.allocPrint(a, "{{\"agent_servers\": {{\"tau\": {{\"command\":\"{s}\",\"args\":[\"acp\",\"serve\"]}}}}}}", .{esc.items});
    _ = try writeIfChanged(io, a, sp, no_type, false);
    try testing.expectEqual(WiringState.stale, (try inspectClientWiring(io, a, home, .zed)).state);

    const jb_dir = try std.fmt.allocPrint(a, "{s}/.jetbrains", .{home});
    try std.Io.Dir.cwd().createDirPath(io, jb_dir);
    _ = try writeIfChanged(io, a, try std.fmt.allocPrint(a, "{s}/acp.json", .{jb_dir}), no_type, false);
    try testing.expectEqual(WiringState.ok, (try inspectClientWiring(io, a, home, .jetbrains)).state);

    // Fully correct zed entry -> ok.
    const good = try std.fmt.allocPrint(a, "{{\"agent_servers\": {{\"tau\": {{\"type\":\"custom\",\"command\":\"{s}\",\"args\":[\"acp\",\"serve\"]}}}}}}", .{esc.items});
    _ = try writeIfChanged(io, a, sp, good, false);
    try testing.expectEqual(WiringState.ok, (try inspectClientWiring(io, a, home, .zed)).state);
}

test "remedyClientWiring: missing file gets a minimal one; no-entry gets a snippet" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(io, ".", a);
    const exe = try std.process.executablePathAlloc(io, a);

    const zed_dir = try std.fmt.allocPrint(a, "{s}/.config/zed", .{home});
    try std.Io.Dir.cwd().createDirPath(io, zed_dir);

    const d1 = try remedyClientWiring(io, a, home, .zed, exe);
    try testing.expect(std.mem.indexOf(u8, d1, "minimal settings file") != null);
    try testing.expectEqual(WiringState.ok, (try inspectClientWiring(io, a, home, .zed)).state);

    // An existing settings file without a tau entry is never rewritten — the
    // remedy is the same paste-ready snippet `tau setup --client` emits.
    const code_dir = try std.fmt.allocPrint(a, "{s}/.config/Code/User", .{home});
    try std.Io.Dir.cwd().createDirPath(io, code_dir);
    const sp = try std.fmt.allocPrint(a, "{s}/settings.json", .{code_dir});
    const orig = "{\n  // keep me\n  \"vim\": true\n}\n";
    _ = try writeIfChanged(io, a, sp, orig, false);

    const d2 = try remedyClientWiring(io, a, home, .vscode, exe);
    try testing.expect(std.mem.indexOf(u8, d2, "snippet") != null);
    try testing.expect(std.mem.indexOf(u8, d2, "by hand") != null);
    const snip = try std.Io.Dir.cwd().readFileAlloc(io, try std.fmt.allocPrint(a, "{s}/.config/tau/snippets/vscode.jsonc", .{home}), a, .unlimited);
    try testing.expect(std.mem.indexOf(u8, snip, "\"acp.agents\"") != null);
    try testing.expect(std.mem.indexOf(u8, snip, exe) != null);
    const after = try std.Io.Dir.cwd().readFileAlloc(io, sp, a, .unlimited);
    try testing.expectEqualStrings(orig, after);

    // Re-running the remedy on the unchanged file reports the snippet is
    // already up to date.
    const d3 = try remedyClientWiring(io, a, home, .vscode, exe);
    try testing.expect(std.mem.indexOf(u8, d3, "already up to date") != null);
}

test "configureClient windsurf writes the mcp entry and the mcacp bridge config" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(io, ".", a);

    var entries: std.ArrayList(u8) = .empty;
    const oc = try configureClient(io, a, &entries, true, home, .windsurf, "/abs/tau", false);
    try testing.expectEqual(ClientOutcome.installed, oc);
    try testing.expect(std.mem.indexOf(u8, entries.items, "\"bridge_status\":\"installed\"") != null);
    try testing.expect(std.mem.indexOf(u8, entries.items, "\"bridge_path\":") != null);

    // The client file launches the bridge, not tau.
    const mcp = try std.Io.Dir.cwd().readFileAlloc(
        io,
        try std.fmt.allocPrint(a, "{s}/.codeium/windsurf/mcp_config.json", .{home}),
        a,
        .unlimited,
    );
    try testing.expectEqual(@as(?bool, true), hasTauEntry(a, .windsurf, mcp));

    // The bridge config carries the real tau agent entry.
    const mcacp = try std.Io.Dir.cwd().readFileAlloc(
        io,
        try std.fmt.allocPrint(a, "{s}/.config/mcacp/mcacp.json", .{home}),
        a,
        .unlimited,
    );
    try testing.expectEqual(@as(?bool, true), bridgeHasTau(a, mcacp));
    try testing.expect(std.mem.indexOf(u8, mcacp, "/abs/tau") != null);

    // Second run is fully idempotent.
    entries.clearRetainingCapacity();
    const oc2 = try configureClient(io, a, &entries, true, home, .windsurf, "/abs/tau", false);
    try testing.expectEqual(ClientOutcome.already_installed, oc2);
    try testing.expect(std.mem.indexOf(u8, entries.items, "\"bridge_status\":\"already_installed\"") != null);
}

test "configureClient bridge in dry-run previews both files without writing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(io, ".", a);

    var entries: std.ArrayList(u8) = .empty;
    const oc = try configureClient(io, a, &entries, true, home, .gemini, "/abs/tau", true);
    try testing.expectEqual(ClientOutcome.would_install, oc);
    try testing.expect(std.mem.indexOf(u8, entries.items, "\"bridge_status\":\"would_install\"") != null);
    try testing.expect(!dirExists(io, try std.fmt.allocPrint(a, "{s}/.gemini", .{home})));
    try testing.expect(!dirExists(io, try std.fmt.allocPrint(a, "{s}/.config/mcacp", .{home})));
}

test "inspectClientWiring bridge: client entry plus mcacp.json both classify" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(io, ".", a);
    const exe = try std.process.executablePathAlloc(io, a);

    const gdir = try std.fmt.allocPrint(a, "{s}/.gemini", .{home});
    try std.Io.Dir.cwd().createDirPath(io, gdir);
    const sp = try std.fmt.allocPrint(a, "{s}/settings.json", .{gdir});

    // Client entry present but the bridge config is missing -> stale.
    _ = try writeIfChanged(io, a, sp, "{\"mcpServers\": {\"mcacp\": {\"command\":\"npx\",\"args\":[\"-y\",\"mcacp\"]}}}", false);
    const half = try inspectClientWiring(io, a, home, .gemini);
    try testing.expectEqual(WiringState.stale, half.state);
    try testing.expect(std.mem.indexOf(u8, half.reason.?, "mcacp") != null);

    // Bridge config present and sane -> ok.
    const bpath = try mcacpConfigPath(a, home);
    var esc: std.ArrayList(u8) = .empty;
    try json.escapeInto(a, &esc, exe);
    _ = try writeIfChanged(io, a, bpath, try std.fmt.allocPrint(a, "{{\"agent_servers\": {{\"tau\": {{\"command\":\"{s}\",\"args\":[\"acp\",\"serve\"]}}}}}}", .{esc.items}), false);
    try testing.expectEqual(WiringState.ok, (try inspectClientWiring(io, a, home, .gemini)).state);

    // A bridge config without the tau entry -> stale naming the bridge file.
    _ = try writeIfChanged(io, a, bpath, "{\"agent_servers\": {}}", false);
    const no_tau = try inspectClientWiring(io, a, home, .gemini);
    try testing.expectEqual(WiringState.stale, no_tau.state);
    try testing.expect(std.mem.indexOf(u8, no_tau.reason.?, "no \"tau\" entry") != null);
}

test "remedyClientWiring bridge repairs both halves" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(io, ".", a);
    const exe = try std.process.executablePathAlloc(io, a);

    const cdir = try std.fmt.allocPrint(a, "{s}/.config/Claude", .{home});
    try std.Io.Dir.cwd().createDirPath(io, cdir);

    const d = try remedyClientWiring(io, a, home, .claude_desktop, exe);
    try testing.expect(std.mem.indexOf(u8, d, "minimal settings file") != null);
    try testing.expect(std.mem.indexOf(u8, d, "mcacp bridge config") != null);
    try testing.expectEqual(WiringState.ok, (try inspectClientWiring(io, a, home, .claude_desktop)).state);
}

test "docs/compatibility.md generated matrix mirrors the client registry" {
    const gpa = testing.allocator;
    const doc = try std.Io.Dir.cwd().readFileAlloc(testing.io, "docs/compatibility.md", gpa, .unlimited);
    defer gpa.free(doc);
    // The file must declare itself generated so nobody hand-edits it.
    try testing.expect(std.mem.indexOf(u8, doc, "GENERATED FILE") != null);
    try testing.expect(std.mem.indexOf(u8, doc, "scripts/gen-compat-doc.py") != null);
    // The "code" alias must be listed.
    try testing.expect(std.mem.indexOf(u8, doc, "alias `code`") != null);
    inline for (all_clients) |k| {
        var buf: [160]u8 = undefined;
        const row = std.fmt.bufPrint(&buf, "| `{s}`", .{clientName(k)}) catch unreachable;
        if (std.mem.indexOf(u8, doc, row) == null) {
            std.debug.print("docs/compatibility.md missing client row '{s}'\n", .{row});
            return error.TestUnexpectedResult;
        }
        if (try clientSettingsPath(gpa, "~", k)) |p| {
            defer gpa.free(p);
            if (std.mem.indexOf(u8, doc, p) == null) {
                std.debug.print("docs/compatibility.md missing settings path '{s}'\n", .{p});
                return error.TestUnexpectedResult;
            }
            const sec = clientSectionKey(k);
            if (std.mem.indexOf(u8, doc, sec) == null) {
                std.debug.print("docs/compatibility.md missing section key '{s}'\n", .{sec});
                return error.TestUnexpectedResult;
            }
        }
    }
}

test "docs/clients per-client guides mirror the client renderers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;

    // Guide file per MCP-bridge client (gemini's file is named gemini-cli.md).
    const Guide = struct { file: []const u8, kind: ClientKind };
    const guides = [_]Guide{
        .{ .file = "docs/clients/windsurf.md", .kind = .windsurf },
        .{ .file = "docs/clients/gemini-cli.md", .kind = .gemini },
        .{ .file = "docs/clients/claude-desktop.md", .kind = .claude_desktop },
    };
    // Marker -> renderer output it must equal ("tau" stands in for the
    // absolute command path, like the smoke group's normalization).
    const Slot = struct {
        marker: []const u8,
        want: *const fn (std.mem.Allocator, ClientKind) anyerror![]u8,
    };
    const slots = [_]Slot{
        .{ .marker = "client-file", .want = struct {
            fn f(al: std.mem.Allocator, k: ClientKind) ![]u8 {
                return renderClientJson(al, k, "tau");
            }
        }.f },
        .{ .marker = "bridge-file", .want = struct {
            fn f(al: std.mem.Allocator, k: ClientKind) ![]u8 {
                _ = k;
                return renderMcacpJson(al, "tau");
            }
        }.f },
        .{ .marker = "client-snippet", .want = struct {
            fn f(al: std.mem.Allocator, k: ClientKind) ![]u8 {
                return renderClientSnippet(al, k, "tau");
            }
        }.f },
        .{ .marker = "bridge-snippet", .want = struct {
            fn f(al: std.mem.Allocator, k: ClientKind) ![]u8 {
                _ = k;
                return renderMcacpSnippet(al, "tau");
            }
        }.f },
    };

    for (guides) |g| {
        const doc = try std.Io.Dir.cwd().readFileAlloc(io, g.file, a, .unlimited);
        for (slots) |s| {
            const marker = try std.fmt.allocPrint(a, "<!-- setup-verify: {s} -->", .{s.marker});
            const mpos = std.mem.indexOf(u8, doc, marker) orelse {
                std.debug.print("{s} missing marker '{s}'\n", .{ g.file, marker });
                return error.TestUnexpectedResult;
            };
            const fence = std.mem.indexOfPos(u8, doc, mpos, "```") orelse
                return error.TestUnexpectedResult;
            const body_start = (std.mem.indexOfPos(u8, doc, fence, "\n") orelse
                return error.TestUnexpectedResult) + 1;
            const body_end = std.mem.indexOfPos(u8, doc, body_start, "```") orelse
                return error.TestUnexpectedResult;
            const body = doc[body_start..body_end];
            const want = try s.want(a, g.kind);
            if (!std.mem.eql(u8, body, want)) {
                std.debug.print("{s}: '{s}' block drifted from the renderer —\n--- guide ---\n{s}--- want ---\n{s}", .{ g.file, s.marker, body, want });
                return error.TestUnexpectedResult;
            }
        }
    }
}
