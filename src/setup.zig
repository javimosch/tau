// `tau setup` — one-shot onboarding: scaffold ~/.config/tau/config.json
// (init), install shell completions for the detected shell, configure editor
// ACP clients (--client), then embed the `tau doctor` health report. Emits
// one NDJSON object per step plus a final verdict line on stdout (the
// verdict carries "done":true — the stream's terminal marker); exit 0
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
//
// Removal mode (`--remove`/`--uninstall`): cleanly reverses the clients
// step — the init/completions/doctor steps don't run. The tau (or mcacp)
// entry is spliced out of each client's settings file without touching
// comments or sibling members; files left with no settings at all are
// deleted, and setup-generated snippets under ~/.config/tau/snippets/ go
// too. The shared mcacp bridge config is kept while another MCP client
// outside the removal set still uses it. --client scopes the sweep; without
// it every client is processed (removal only touches files that actually
// carry tau wiring). --dry-run reports "would_remove" and changes nothing.
//
// Import mode (`--import`, env TAU_SETUP_IMPORT): opts into editing MCP-
// bridge client settings files in place — the mcacp entry plus the user's
// existing MCP server entries collected from the other supported clients'
// files are spliced in (JSONC-safe: comments and sibling members survive
// byte-for-byte, existing entries are never overwritten). Per-client
// entries carry "imported" (merged entries, with their source client) and
// "import_skipped" (entries or source files that couldn't be merged, with
// reasons); --dry-run reports "would_install" and changes nothing.
// Mutually exclusive with --remove/--uninstall.

const std = @import("std");
const term = @import("term.zig");
const json = @import("json.zig");
const cfgmod = @import("config.zig");
const configfile = @import("configfile.zig");
const configedit = @import("configedit.zig");
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
pub const ClientKind = enum { zed, nvim, emacs, vscode, cursor, jetbrains, windsurf, gemini, claude_desktop, opencode, cline, goose, continue_, roo, kilo, amazonq };

/// Every ClientKind, in the order `--client all` expands and detection
/// iterates: direct ACP clients first, then the MCP-bridge clients.
pub const all_clients = [_]ClientKind{ .zed, .nvim, .emacs, .vscode, .cursor, .jetbrains, .windsurf, .gemini, .claude_desktop, .opencode, .cline, .goose, .continue_, .roo, .kilo, .amazonq };

pub fn clientName(k: ClientKind) []const u8 {
    return switch (k) {
        .zed => "zed",
        .nvim => "nvim",
        .emacs => "emacs",
        .vscode => "vscode",
        .cursor => "cursor",
        .jetbrains => "jetbrains",
        .windsurf => "windsurf",
        .gemini => "gemini",
        .claude_desktop => "claude-desktop",
        .opencode => "opencode",
        .cline => "cline",
        .goose => "goose",
        .continue_ => "continue",
        .roo => "roo-code",
        .kilo => "kilo-code",
        .amazonq => "amazonq",
    };
}

/// Map a client name (as passed to --client) to a ClientKind. "code" is an
/// alias for vscode, "gemini-cli" for gemini, "claude" for claude-desktop,
/// "roo" for roo-code, "kilo" for kilo-code, "amazon-q" for amazonq.
pub fn parseClientName(name: []const u8) ?ClientKind {
    if (std.mem.eql(u8, name, "zed")) return .zed;
    if (std.mem.eql(u8, name, "nvim")) return .nvim;
    if (std.mem.eql(u8, name, "emacs")) return .emacs;
    if (std.mem.eql(u8, name, "vscode") or std.mem.eql(u8, name, "code")) return .vscode;
    if (std.mem.eql(u8, name, "cursor")) return .cursor;
    if (std.mem.eql(u8, name, "jetbrains")) return .jetbrains;
    if (std.mem.eql(u8, name, "windsurf")) return .windsurf;
    if (std.mem.eql(u8, name, "gemini") or std.mem.eql(u8, name, "gemini-cli")) return .gemini;
    if (std.mem.eql(u8, name, "claude-desktop") or std.mem.eql(u8, name, "claude")) return .claude_desktop;
    if (std.mem.eql(u8, name, "opencode")) return .opencode;
    if (std.mem.eql(u8, name, "cline")) return .cline;
    if (std.mem.eql(u8, name, "goose")) return .goose;
    if (std.mem.eql(u8, name, "continue")) return .continue_;
    if (std.mem.eql(u8, name, "roo-code") or std.mem.eql(u8, name, "roo")) return .roo;
    if (std.mem.eql(u8, name, "kilo-code") or std.mem.eql(u8, name, "kilo")) return .kilo;
    if (std.mem.eql(u8, name, "amazonq") or std.mem.eql(u8, name, "amazon-q")) return .amazonq;
    return null;
}

/// Clients that can't spawn `tau acp serve` directly — they speak MCP, not
/// ACP — so setup wires them to the mcacp MCP→ACP bridge instead. Their
/// settings entry launches the bridge (`npx mcacp`); the bridge's own
/// config (~/.config/mcacp/mcacp.json) carries the real tau agent entry.
/// (OpenCode *serves* ACP via `opencode acp` but consumes MCP servers —
/// same bridge path as the other MCP-only clients. Goose and Continue are
/// MCP clients too but their configs are YAML, not JSON — setup wires the
/// shared bridge file and emits a paste-ready YAML snippet instead of
/// touching the client config.)
pub fn clientUsesBridge(k: ClientKind) bool {
    return switch (k) {
        .windsurf, .gemini, .claude_desktop, .opencode, .cline, .goose, .continue_, .roo, .kilo, .amazonq => true,
        else => false,
    };
}

/// The object key the client's agent section must carry — "tau" for direct
/// ACP clients, "mcacp" (the bridge server name) for MCP-bridge clients.
fn clientEntryName(k: ClientKind) []const u8 {
    return if (clientUsesBridge(k)) "mcacp" else "tau";
}

/// The JSON/JSONC settings file that carries the client config, or null for
/// the snippet-only clients — nvim's ACP plugins are configured in Lua (see
/// renderNvimSnippet) and Emacs agent-shell in elisp (renderEmacsSnippet).
/// Linux paths; docs/acp.md lists equivalents for other platforms.
pub fn clientSettingsPath(arena: std.mem.Allocator, home: []const u8, k: ClientKind) !?[]u8 {
    return switch (k) {
        .zed => try std.fmt.allocPrint(arena, "{s}/.config/zed/settings.json", .{home}),
        .vscode => try std.fmt.allocPrint(arena, "{s}/.config/Code/User/settings.json", .{home}),
        .cursor => try std.fmt.allocPrint(arena, "{s}/.config/Cursor/User/settings.json", .{home}),
        .jetbrains => try std.fmt.allocPrint(arena, "{s}/.jetbrains/acp.json", .{home}),
        .windsurf => try std.fmt.allocPrint(arena, "{s}/.codeium/windsurf/mcp_config.json", .{home}),
        .gemini => try std.fmt.allocPrint(arena, "{s}/.gemini/settings.json", .{home}),
        .claude_desktop => try std.fmt.allocPrint(arena, "{s}/.config/Claude/claude_desktop_config.json", .{home}),
        .opencode => try std.fmt.allocPrint(arena, "{s}/.config/opencode/opencode.json", .{home}),
        .cline => try std.fmt.allocPrint(arena, "{s}/.config/Code/User/globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json", .{home}),
        .roo => try std.fmt.allocPrint(arena, "{s}/.config/Code/User/globalStorage/rooveterinaryinc.roo-cline/settings/mcp_settings.json", .{home}),
        .kilo => try std.fmt.allocPrint(arena, "{s}/.config/kilo/kilo.jsonc", .{home}),
        .amazonq => try std.fmt.allocPrint(arena, "{s}/.aws/amazonq/mcp.json", .{home}),
        .nvim, .emacs, .goose, .continue_ => null,
    };
}

/// The directory that exists once the editor has been installed/run — used
/// for the no-flag detection report (detection alone never writes).
fn clientConfigDir(arena: std.mem.Allocator, home: []const u8, k: ClientKind) ![]u8 {
    return switch (k) {
        .zed => std.fmt.allocPrint(arena, "{s}/.config/zed", .{home}),
        .vscode => std.fmt.allocPrint(arena, "{s}/.config/Code", .{home}),
        .cursor => std.fmt.allocPrint(arena, "{s}/.config/Cursor", .{home}),
        .jetbrains => std.fmt.allocPrint(arena, "{s}/.jetbrains", .{home}),
        .windsurf => std.fmt.allocPrint(arena, "{s}/.codeium/windsurf", .{home}),
        .gemini => std.fmt.allocPrint(arena, "{s}/.gemini", .{home}),
        .claude_desktop => std.fmt.allocPrint(arena, "{s}/.config/Claude", .{home}),
        .nvim => std.fmt.allocPrint(arena, "{s}/.config/nvim", .{home}),
        // The classic init dir — ~/.config/emacs (XDG) also exists but
        // ~/.emacs.d is what an agent-shell user almost always has.
        .emacs => std.fmt.allocPrint(arena, "{s}/.emacs.d", .{home}),
        .opencode => std.fmt.allocPrint(arena, "{s}/.config/opencode", .{home}),
        // Cline is a VS Code extension — its per-extension globalStorage
        // dir is what exists once Cline has run.
        .cline => std.fmt.allocPrint(arena, "{s}/.config/Code/User/globalStorage/saoudrizwan.claude-dev", .{home}),
        // Roo Code is a VS Code extension too — same globalStorage layout
        // as Cline, under its own publisher.extension id.
        .roo => std.fmt.allocPrint(arena, "{s}/.config/Code/User/globalStorage/rooveterinaryinc.roo-cline", .{home}),
        .kilo => std.fmt.allocPrint(arena, "{s}/.config/kilo", .{home}),
        .amazonq => std.fmt.allocPrint(arena, "{s}/.aws/amazonq", .{home}),
        .goose => std.fmt.allocPrint(arena, "{s}/.config/goose", .{home}),
        .continue_ => std.fmt.allocPrint(arena, "{s}/.continue", .{home}),
    };
}

/// The settings key that holds named agent/server entries per client —
/// "mcpServers" for the MCP-bridge clients (the entry launches the bridge,
/// not tau itself).
fn clientSectionKey(k: ClientKind) []const u8 {
    return switch (k) {
        .zed, .jetbrains => "agent_servers",
        .vscode, .cursor => "acp.agents",
        .windsurf, .gemini, .claude_desktop, .cline, .roo, .amazonq => "mcpServers",
        // OpenCode's MCP servers live under the top-level "mcp" object —
        // mcp.<name> entries, not mcpServers.<name>. Kilo Code's current
        // kilo.jsonc config uses the same "mcp" shape.
        .opencode, .kilo => "mcp",
        .nvim, .emacs, .goose, .continue_ => unreachable,
    };
}

/// The in-editor action that finishes the integration — surfaced in the step
/// output so the transcript itself tells the user where to click.
fn clientNextStep(k: ClientKind) []const u8 {
    return switch (k) {
        .zed => "open the Agent Panel, click +, and pick tau",
        .vscode => "install the ACP Client extension, run 'ACP: Connect to Agent', pick tau",
        .cursor => "install the ACP Client extension (Open VSX), run 'ACP: Connect to Agent', pick tau",
        .jetbrains => "open the AI Chat tool window and pick tau in the agent selector",
        .windsurf => "install mcacp (npm i -g mcacp or npx), restart Windsurf, and confirm the mcacp server in Settings > MCP servers",
        .gemini => "install mcacp (npm i -g mcacp or npx), restart Gemini CLI, and run /mcp to see tau's tools",
        .claude_desktop => "install mcacp (npm i -g mcacp or npx), restart Claude Desktop, and find tau's tools under the mcacp server",
        .opencode => "install mcacp (npm i -g mcacp or npx), restart OpenCode, and check the mcacp server with 'opencode mcp list'",
        .cline => "install mcacp (npm i -g mcacp or npx), restart VS Code, and confirm the mcacp server under MCP Servers in the Cline pane",
        .goose => "install mcacp (npm i -g mcacp or npx), merge the snippet into ~/.config/goose/config.yaml, then run 'goose session' and ask about the mcacp tools",
        .continue_ => "install mcacp (npm i -g mcacp or npx), merge the snippet into ~/.continue/config.yaml, restart Continue, and use agent mode to see tau's tools",
        .roo => "install mcacp (npm i -g mcacp or npx), restart VS Code, and confirm the mcacp server under MCP Servers in the Roo Code pane",
        .kilo => "install mcacp (npm i -g mcacp or npx), restart Kilo Code, and confirm the mcacp server under Agent Behaviour > MCP Servers (or run 'kilo mcp list')",
        .amazonq => "install mcacp (npm i -g mcacp or npx), then run 'q chat' (or restart the IDE plugin) and check the mcacp server with /mcp",
        .nvim => "pick the tau provider/adapter in your plugin (e.g. :AvanteSwitchProvider)",
        .emacs => "paste the snippet into your init file, restart Emacs, run M-x agent-shell and pick tau",
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
    const ext: []const u8 = switch (k) {
        .nvim => "lua",
        .emacs => "el",
        .goose => "yaml",
        .continue_ => "yaml",
        else => "jsonc",
    };
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
        // Cursor is VS Code-compatible — the same acp.agents shape, in
        // Cursor's own User settings.json.
        .vscode, .cursor => std.fmt.allocPrint(arena,
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
        .windsurf, .gemini, .claude_desktop, .cline, .roo, .amazonq => std.fmt.allocPrint(arena,
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
        // OpenCode and Kilo Code keep MCP servers under "mcp" (not
        // "mcpServers") and a local entry packs the whole spawn line into
        // a "command" array.
        .opencode, .kilo => std.fmt.allocPrint(arena,
            \\{{
            \\  "mcp": {{
            \\    "mcacp": {{
            \\      "type": "local",
            \\      "command": ["npx", "-y", "mcacp"],
            \\      "enabled": true
            \\    }}
            \\  }}
            \\}}
            \\
        , .{}),
        .nvim, .emacs, .goose, .continue_ => unreachable,
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
        // YAML-configured MCP clients get a YAML fragment — the JSONC
        // splice shapes below don't apply to config.yaml files.
        if (k == .goose or k == .continue_) return renderYamlBridgeSnippet(arena, k);
        if (k == .opencode or k == .kilo) {
            return std.fmt.allocPrint(arena,
                \\// tau via the mcacp MCP->ACP bridge — merge into your {s} settings file.
                \\// If a top-level "mcp" object already exists, add just the inner
                \\// "mcacp" entry to it; otherwise add the whole block. The bridge
                \\// itself is configured separately — see snippets/mcacp.jsonc.
                \\"mcp": {{
                \\  "mcacp": {{
                \\    "type": "local",
                \\    "command": ["npx", "-y", "mcacp"],
                \\    "enabled": true
                \\  }}
                \\}}
                \\
            , .{clientName(k)});
        }
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

/// The ready-to-paste YAML fragment for MCP clients whose config is YAML —
/// Goose's `extensions:` map (~/.config/goose/config.yaml) and Continue's
/// `mcpServers:` list (~/.continue/config.yaml). Written to
/// ~/.config/tau/snippets/<client>.yaml; the bridge half of the wiring is
/// configured separately (see snippets/mcacp.jsonc).
fn renderYamlBridgeSnippet(arena: std.mem.Allocator, k: ClientKind) ![]u8 {
    return switch (k) {
        .goose => std.fmt.allocPrint(arena,
            \\# tau via the mcacp MCP->ACP bridge — merge into ~/.config/goose/config.yaml.
            \\# If an "extensions:" map already exists, add just the inner "mcacp"
            \\# entry to it; otherwise add the whole block. The bridge itself is
            \\# configured separately — see snippets/mcacp.jsonc.
            \\extensions:
            \\  mcacp:
            \\    type: stdio
            \\    name: mcacp
            \\    enabled: true
            \\    cmd: npx
            \\    args: ["-y", "mcacp"]
            \\    envs: {{}}
            \\    timeout: 300
            \\
        , .{}),
        .continue_ => std.fmt.allocPrint(arena,
            \\# tau via the mcacp MCP->ACP bridge — merge into ~/.continue/config.yaml.
            \\# If a top-level "mcpServers:" list already exists, append just the
            \\# list item to it; otherwise add the whole block. The bridge itself
            \\# is configured separately — see snippets/mcacp.jsonc.
            \\mcpServers:
            \\  - name: mcacp
            \\    command: npx
            \\    args:
            \\      - "-y"
            \\      - "mcacp"
            \\    env: {{}}
            \\
        , .{}),
        else => unreachable,
    };
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

/// The ready-to-paste elisp for Emacs agent-shell, written to
/// ~/.config/tau/snippets/emacs.el. agent-shell registers custom ACP agents
/// via agent-shell-make-agent-config; the :client-maker lambda receives the
/// shell buffer (unused — acp-make-client needs no context) and returns an
/// acp.el client that spawns `tau acp serve` over stdio.
fn renderEmacsSnippet(arena: std.mem.Allocator, command: []const u8) ![]u8 {
    return std.fmt.allocPrint(arena,
        \\;; tau ACP agent for agent-shell — generated by `tau setup --client emacs`.
        \\;; Paste into your Emacs init file (~/.emacs.d/init.el or
        \\;; ~/.config/emacs/init.el) and restart Emacs.
        \\;; Requires agent-shell and acp.el from MELPA.
        \\;; Full guide: https://github.com/javimosch/tau/blob/master/docs/clients/emacs.md
        \\
        \\;; Register tau as a custom agent-shell agent.
        \\(defun agent-shell-make-tau-config ()
        \\  "Create a tau agent configuration for `agent-shell'."
        \\  (agent-shell-make-agent-config
        \\   :identifier 'tau
        \\   :mode-line-name "tau"
        \\   :buffer-name "tau"
        \\   :shell-prompt "tau> "
        \\   :shell-prompt-regexp "tau> "
        \\   :needs-authentication nil
        \\   :client-maker
        \\   (lambda (_buffer)
        \\     (acp-make-client
        \\      :command "{s}"
        \\      :command-params '("acp" "serve")))))
        \\
        \\(add-to-list 'agent-shell-agent-configs (agent-shell-make-tau-config))
        \\;; Run M-x agent-shell and pick tau.
        \\
    , .{command});
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

/// How one client's `tau acp serve` wiring looks to `tau doctor`. Snippet-
/// only clients (nvim/emacs — Lua and elisp; goose/continue — YAML) always
/// report .manual_only; the JSON clients classify their settings file.
pub const WiringState = enum {
    /// No editor config dir — the client isn't installed here.
    not_detected,
    /// Snippet-only client (Lua/elisp/YAML config); doctor can only point
    /// at the snippet.
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
    /// Settings-file path for JSON clients (null for manual_only clients
    /// and not_detected).
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
    if (k == .nvim or k == .emacs or k == .goose or k == .continue_) return .{ .state = .manual_only };
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
        if (k == .opencode or k == .kilo) {
            // OpenCode/Kilo local-MCP entries pack the spawn line into a
            // "command" array (["npx","-y","mcacp"]) — there is no "args".
            const bcmd = e.get("command");
            if (bcmd == null or bcmd.? != .array or bcmd.?.array.items.len == 0 or
                bcmd.?.array.items[0] != .string)
                return .{ .state = .stale, .path = path, .reason = "the \"mcacp\" entry has no \"command\" array" };
            return inspectBridgeWiring(io, arena, home, path);
        }
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
            try list.appendSlice(arena, &.{ .zed, .nvim, .emacs, .vscode, .cursor, .jetbrains, .windsurf, .gemini, .claude_desktop, .opencode, .cline, .goose, .continue_, .roo, .kilo, .amazonq });
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
/// written). `imp` is --import: for MCP-bridge clients it opts into editing
/// the settings file in place — the mcacp entry plus the user's servers
/// collected from the other supported clients are spliced in, preserving
/// comments and existing members byte-for-byte.
fn configureClient(io: std.Io, arena: std.mem.Allocator, entries: *std.ArrayList(u8), first: bool, home: []const u8, k: ClientKind, command: []const u8, imp: bool, dry: bool) !ClientOutcome {
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

    if (k == .nvim or k == .emacs or k == .goose or k == .continue_) {
        // Snippet-only clients — Neovim ACP plugins are configured in Lua,
        // Emacs agent-shell in elisp, and Goose/Continue MCP servers in
        // YAML config files; splicing arbitrary user config is unsafe, so
        // always emit a paste-ready snippet. (Goose and Continue still get
        // the shared mcacp bridge file — closeClientEntry handles it.)
        const body = switch (k) {
            .nvim => try renderNvimSnippet(arena, command),
            .emacs => try renderEmacsSnippet(arena, command),
            else => try renderYamlBridgeSnippet(arena, k),
        };
        const snip = try snippetPath(arena, home, k);
        _ = writeIfChanged(io, arena, snip, body, dry) catch |err| {
            try fail(arena, entries, snip, err);
            return .failed;
        };
        try entries.appendSlice(arena, ",\"status\":\"manual\",\"snippet_path\":");
        try js(arena, entries, snip);
        try entries.appendSlice(arena, ",\"editor_detected\":");
        try entries.appendSlice(arena, if (dirExists(io, try clientConfigDir(arena, home, k))) "true" else "false");
        // --import can't splice YAML — a bridge client taking the
        // snippet path reports the same empty import list as any other
        // manual outcome.
        if (imp and clientUsesBridge(k)) try entries.appendSlice(arena, ",\"imported\":[]");
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

    if (imp and clientUsesBridge(k) and !unreadable) {
        // --import opts into editing this file in place: the mcacp entry
        // and the user's servers from the other supported clients are
        // spliced in. A file that can't be scanned falls through to the
        // manual snippet path below.
        if (try wireBridgeClientImport(io, arena, entries, home, k, command, cur, dry)) |oc|
            return closeClientEntry(io, arena, entries, home, k, command, dry, oc);
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
    if (imp and clientUsesBridge(k)) try entries.appendSlice(arena, ",\"imported\":[]");
    try entries.appendSlice(arena, ",\"next\":");
    try js(arena, entries, "merge the snippet into your settings file by hand");
    return closeClientEntry(io, arena, entries, home, k, command, dry, .manual);
}

// --- --import: carry the user's MCP servers into bridge-client files --------

/// One MCP server entry found in a supported client's settings file,
/// normalized to a stdio spawn line. `env` is re-serialized for the
/// target's shape; `enabled` is only meaningful for OpenCode "mcp" entries.
const ImportServer = struct {
    name: []const u8,
    command: []const u8,
    args: []const []const u8 = &.{},
    env: ?std.json.Value = null,
    enabled: ?bool = null,
    from: ClientKind,
};

/// One line of the per-client import report — `name` is null for
/// file-level findings (unreadable/unparseable source settings files).
const ImportSkip = struct { name: ?[]const u8 = null, from: ClientKind, reason: []const u8 };
const ImportDid = struct { name: []const u8, from: ClientKind };

const ImportPlan = struct {
    /// Importable servers, deduplicated by name (first source wins).
    servers: std.ArrayList(ImportServer) = .empty,
    /// Entries/sources skipped, each carrying a reason.
    skipped: std.ArrayList(ImportSkip) = .empty,
};

const Canon = union(enum) { ok: ImportServer, skip: []const u8 };

/// A stdio server entry in the "mcpServers" shape (Windsurf/Gemini/Claude
/// Desktop): "command" string + optional "args" string array + optional
/// "env" object. Remote (URL-keyed) servers are not imported — their shape
/// doesn't translate to a stdio spawn line.
fn canonStdio(arena: std.mem.Allocator, name: []const u8, e: std.json.ObjectMap, from: ClientKind) !Canon {
    if (e.get("url") != null or e.get("serverUrl") != null)
        return .{ .skip = "remote servers are not imported" };
    const cmd = e.get("command") orelse
        return .{ .skip = "not a stdio server entry (no \"command\" string)" };
    if (cmd != .string)
        return .{ .skip = "not a stdio server entry (no \"command\" string)" };
    var args: std.ArrayList([]const u8) = .empty;
    if (e.get("args")) |a| {
        if (a != .array) return .{ .skip = "\"args\" is not a string array" };
        for (a.array.items) |it| {
            if (it != .string) return .{ .skip = "\"args\" is not a string array" };
            try args.append(arena, it.string);
        }
    }
    var env: ?std.json.Value = null;
    if (e.get("env")) |v| {
        if (v == .object) env = v;
    }
    return .{ .ok = .{ .name = name, .command = cmd.string, .args = args.items, .env = env, .from = from } };
}

/// A server entry in the "mcp" shape (OpenCode, Kilo Code): local entries
/// pack the whole spawn line into a "command" string array and may carry
/// "enabled". Remote entries are skipped for the same reason as above.
/// Kilo spells the env map "environment" — both keys are read.
fn canonOpenCode(arena: std.mem.Allocator, name: []const u8, e: std.json.ObjectMap, from: ClientKind) !Canon {
    if (e.get("type")) |t| {
        if (t == .string and std.mem.eql(u8, t.string, "remote"))
            return .{ .skip = "remote servers are not imported" };
    }
    const cmd = e.get("command") orelse
        return .{ .skip = "not a local server entry (no \"command\" array)" };
    if (cmd != .array or cmd.array.items.len == 0)
        return .{ .skip = "not a local server entry (no \"command\" array)" };
    var argv: std.ArrayList([]const u8) = .empty;
    for (cmd.array.items) |it| {
        if (it != .string) return .{ .skip = "\"command\" is not a string array" };
        try argv.append(arena, it.string);
    }
    var enabled: ?bool = null;
    if (e.get("enabled")) |v| {
        if (v == .bool) enabled = v.bool;
    }
    var env: ?std.json.Value = null;
    if (e.get("env") orelse e.get("environment")) |v| {
        if (v == .object) env = v;
    }
    return .{ .ok = .{ .name = name, .command = argv.items[0], .args = argv.items[1..], .env = env, .enabled = enabled, .from = from } };
}

const SectionScan = union(enum) { ok: std.json.ObjectMap, none, invalid };

/// The "mcpServers"/"mcp" object inside a client settings file — `.none`
/// when the document parses but has no such member.
fn mcpSectionObj(arena: std.mem.Allocator, bytes: []const u8, key: []const u8) SectionScan {
    const stripped = configfile.stripComments(arena, bytes) catch return .invalid;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, stripped, .{}) catch return .invalid;
    const section = switch (parsed) {
        .object => |o| o.get(key) orelse return .none,
        else => return .none,
    };
    return switch (section) {
        .object => |o| .{ .ok = o },
        else => .none,
    };
}

/// Scan every MCP-bridge client except `target` for user-defined MCP server
/// entries. Missing files are silent (that client just isn't configured);
/// files that can't be read or parsed land in `skipped` with a file-level
/// reason. Entries are deduplicated by name — the first source wins, in
/// all_clients order; tau's own "mcacp" bridge entry is never imported.
fn collectImportable(io: std.Io, arena: std.mem.Allocator, home: []const u8, target: ClientKind) !ImportPlan {
    var plan: ImportPlan = .{};
    var seen = std.StringHashMap(ClientKind).init(arena);
    for (all_clients) |src| {
        if (src == target or !clientUsesBridge(src)) continue;
        // YAML-configured bridge clients (Goose, Continue) have no
        // settings file to import from.
        const path = (try clientSettingsPath(arena, home, src)) orelse continue;
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited) catch |err| {
            switch (err) {
                error.FileNotFound => continue,
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    const msg = try std.fmt.allocPrint(arena, "could not read settings file {s}", .{path});
                    try plan.skipped.append(arena, .{ .from = src, .reason = msg });
                    continue;
                },
            }
        };
        const section = switch (mcpSectionObj(arena, bytes, clientSectionKey(src))) {
            .invalid => {
                try plan.skipped.append(arena, .{ .from = src, .reason = "settings file did not parse as JSON/JSONC" });
                continue;
            },
            .none => continue,
            .ok => |o| o,
        };
        var it = section.iterator();
        while (it.next()) |e| {
            const name = e.key_ptr.*;
            if (std.mem.eql(u8, name, "mcacp")) continue; // tau's own bridge entry
            if (seen.get(name)) |first| {
                const msg = try std.fmt.allocPrint(arena, "same name already imported from {s}", .{clientName(first)});
                try plan.skipped.append(arena, .{ .name = name, .from = src, .reason = msg });
                continue;
            }
            const entry = switch (e.value_ptr.*) {
                .object => |o| o,
                else => {
                    try plan.skipped.append(arena, .{ .name = name, .from = src, .reason = "entry is not an object" });
                    continue;
                },
            };
            const canon = if (src == .opencode or src == .kilo)
                try canonOpenCode(arena, name, entry, src)
            else
                try canonStdio(arena, name, entry, src);
            switch (canon) {
                .ok => |srv| {
                    try seen.put(name, src);
                    try plan.servers.append(arena, srv);
                },
                .skip => |r| try plan.skipped.append(arena, .{ .name = name, .from = src, .reason = r }),
            }
        }
    }
    return plan;
}

/// The "mcacp" server-entry token for `k`'s settings file — the same shape
/// the renderClientJson templates write (OpenCode packs the spawn line
/// into a "command" array).
fn bridgeEntryToken(k: ClientKind) []const u8 {
    return switch (k) {
        .opencode, .kilo => "{\"type\":\"local\",\"command\":[\"npx\",\"-y\",\"mcacp\"],\"enabled\":true}",
        else => "{\"command\":\"npx\",\"args\":[\"-y\",\"mcacp\"]}",
    };
}

/// The settings-file token for `srv` in `target`'s server-entry shape.
fn renderImportToken(arena: std.mem.Allocator, target: ClientKind, srv: ImportServer) ![]u8 {
    var b: std.ArrayList(u8) = .empty;
    if (target == .opencode or target == .kilo) {
        try b.appendSlice(arena, "{\"type\":\"local\",\"command\":[");
        try js(arena, &b, srv.command);
        for (srv.args) |a| {
            try b.append(arena, ',');
            try js(arena, &b, a);
        }
        try b.appendSlice(arena, "],\"enabled\":");
        try b.appendSlice(arena, if (srv.enabled orelse true) "true" else "false");
        if (srv.env) |v| {
            // Kilo's "mcp" entries spell the env map "environment".
            try b.appendSlice(arena, if (target == .kilo) ",\"environment\":" else ",\"env\":");
            try b.appendSlice(arena, try std.json.Stringify.valueAlloc(arena, v, .{}));
        }
        try b.append(arena, '}');
    } else {
        try b.appendSlice(arena, "{\"command\":");
        try js(arena, &b, srv.command);
        try b.appendSlice(arena, ",\"args\":[");
        for (srv.args, 0..) |a, i| {
            if (i > 0) try b.append(arena, ',');
            try js(arena, &b, a);
        }
        try b.append(arena, ']');
        if (srv.env) |v| {
            try b.appendSlice(arena, ",\"env\":");
            try b.appendSlice(arena, try std.json.Stringify.valueAlloc(arena, v, .{}));
        }
        try b.append(arena, '}');
    }
    return b.items;
}

/// Append the "imported"/"import_skipped" fields to an open client entry.
/// `imported` is always emitted (an empty array records that --import was
/// on and found nothing); `import_skipped` only when non-empty.
fn appendImportReport(arena: std.mem.Allocator, entries: *std.ArrayList(u8), imported: []const ImportDid, skipped: []const ImportSkip) !void {
    try entries.appendSlice(arena, ",\"imported\":[");
    for (imported, 0..) |d, i| {
        if (i > 0) try entries.append(arena, ',');
        try entries.appendSlice(arena, "{\"name\":");
        try js(arena, entries, d.name);
        try entries.appendSlice(arena, ",\"from\":");
        try js(arena, entries, clientName(d.from));
        try entries.append(arena, '}');
    }
    try entries.append(arena, ']');
    if (skipped.len == 0) return;
    try entries.appendSlice(arena, ",\"import_skipped\":[");
    for (skipped, 0..) |s, i| {
        if (i > 0) try entries.append(arena, ',');
        try entries.appendSlice(arena, "{\"from\":");
        try js(arena, entries, clientName(s.from));
        if (s.name) |n| {
            try entries.appendSlice(arena, ",\"name\":");
            try js(arena, entries, n);
        }
        try entries.appendSlice(arena, ",\"reason\":");
        try js(arena, entries, s.reason);
        try entries.append(arena, '}');
    }
    try entries.append(arena, ']');
}

/// The --import wiring for one MCP-bridge client: merge the mcacp entry and
/// the user's MCP servers (collected from the other supported clients'
/// settings files) into the client's settings file. A fresh file is
/// rendered then merged the same way. Splices keep comments and sibling
/// members byte-for-byte and never overwrite an entry the file already
/// carries. Returns null when an existing file can't be scanned — the
/// caller falls back to the manual snippet path. `cur` is the current file
/// bytes, or null when the file is absent (the caller only invokes this
/// for absent-or-readable files).
fn wireBridgeClientImport(io: std.Io, arena: std.mem.Allocator, entries: *std.ArrayList(u8), home: []const u8, k: ClientKind, command: []const u8, cur: ?[]const u8, dry: bool) !?ClientOutcome {
    var body: []const u8 = undefined;
    var changed = false;
    if (cur) |b| {
        body = b;
        switch (try configedit.insertNestedMember(arena, body, clientSectionKey(k), clientEntryName(k), bridgeEntryToken(k))) {
            .invalid => return null,
            .present => {},
            .inserted => |nb| {
                body = nb;
                changed = true;
            },
        }
    } else {
        body = try renderClientJson(arena, k, command);
    }

    var imported: std.ArrayList(ImportDid) = .empty;
    const plan = try collectImportable(io, arena, home, k);
    var skipped = plan.skipped;
    for (plan.servers.items) |srv| {
        switch (try configedit.insertNestedMember(arena, body, clientSectionKey(k), srv.name, try renderImportToken(arena, k, srv))) {
            .inserted => |nb| {
                body = nb;
                changed = true;
                try imported.append(arena, .{ .name = srv.name, .from = srv.from });
            },
            .present => try skipped.append(arena, .{ .name = srv.name, .from = srv.from, .reason = "already present in the target file" }),
            .invalid => try skipped.append(arena, .{ .name = srv.name, .from = srv.from, .reason = "settings file did not parse as JSON/JSONC" }),
        }
    }

    const path = (try clientSettingsPath(arena, home, k)).?;
    if (!changed) {
        try entries.appendSlice(arena, ",\"status\":\"already_installed\"");
        try appendImportReport(arena, entries, imported.items, skipped.items);
        try entries.appendSlice(arena, ",\"next\":");
        try js(arena, entries, clientNextStep(k));
        return .already_installed;
    }

    const wrote = writeIfChanged(io, arena, path, body, dry) catch |err| {
        try entries.appendSlice(arena, ",\"status\":\"failed\",\"message\":");
        const msg = try std.fmt.allocPrint(arena, "could not write {s}: {s}", .{ path, @errorName(err) });
        try js(arena, entries, msg);
        return .failed;
    };
    try entries.appendSlice(arena, ",\"status\":");
    try entries.appendSlice(arena, switch (wrote) {
        .would_write => "\"would_install\"",
        .written => "\"installed\"",
        .unchanged => "\"already_installed\"",
    });
    try appendImportReport(arena, entries, imported.items, skipped.items);
    try entries.appendSlice(arena, ",\"command\":");
    try js(arena, entries, command);
    try entries.appendSlice(arena, ",\"next\":");
    try js(arena, entries, clientNextStep(k));
    return switch (wrote) {
        .would_write => .would_install,
        .written => .installed,
        .unchanged => .already_installed,
    };
}
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
        try js(arena, &buf, "re-run with --client zed|nvim|emacs|vscode|cursor|jetbrains|windsurf|gemini|claude-desktop|opencode|cline|goose|continue|roo-code|kilo-code|amazonq|all to write editor ACP config");
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
        const outcome = try configureClient(io, arena, &entries, i == 0, home, k, command, cfg.setup_import, dry);
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

// --- Step 3b: remove editor ACP clients (`--remove`/`--uninstall`) ----------

/// What unwireClient did (or, in dry-run mode, would do) for one client.
/// `manual` means hand-work remains (init-file wiring, an unreadable or
/// unparseable settings file) — it passes the verdict like the install
/// side's manual outcomes do.
const RemoveOutcome = enum { removed, would_remove, absent, manual, failed };

/// File deletion outcome for the removal path — the counterpart of
/// writeIfChanged for `setup --remove`.
const FileRemove = enum { removed, absent, would_remove };

/// Delete `path` when it exists. In dry-run mode an existing file reports
/// .would_remove and is left alone; a missing one is .absent.
fn removeFile(io: std.Io, path: []const u8, dry: bool) !FileRemove {
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| {
        if (err == error.FileNotFound) return .absent;
        return err;
    };
    if (st.kind == .directory) return error.IsDir;
    if (dry) return .would_remove;
    try std.Io.Dir.cwd().deleteFile(io, path);
    return .removed;
}

/// True when `k` is in the removal set.
fn inSet(set: []const ClientKind, k: ClientKind) bool {
    for (set) |c| if (c == k) return true;
    return false;
}

/// Delete the setup-generated snippet for `k` when it exists and append the
/// snippet_path/snippet_status fields to the open client entry. Snippets
/// under ~/.config/tau/snippets/ are tau-owned artifacts — removing them is
/// part of the clean reversal. A failed delete is reported but never fails
/// the client (the wiring itself is already gone).
fn removeSnippetFields(io: std.Io, arena: std.mem.Allocator, entries: *std.ArrayList(u8), home: []const u8, k: ClientKind, dry: bool) !void {
    const snip = try snippetPath(arena, home, k);
    const fr = removeFile(io, snip, dry) catch |err| {
        try entries.appendSlice(arena, ",\"snippet_path\":");
        try js(arena, entries, snip);
        try entries.appendSlice(arena, ",\"snippet_status\":\"failed\",\"snippet_message\":");
        try js(arena, entries, @errorName(err));
        return;
    };
    if (fr == .absent) return;
    try entries.appendSlice(arena, ",\"snippet_path\":");
    try js(arena, entries, snip);
    try entries.appendSlice(arena, ",\"snippet_status\":");
    try js(arena, entries, if (fr == .would_remove) "would_remove" else "removed");
}

/// Bridge-side detail for a removed client entry — mirrors BridgeDetail on
/// the install path. `status` is the JSON word for bridge_status.
const BridgeRemove = struct {
    status: []const u8, // removed|would_remove|kept|absent|manual
    path: []const u8,
    reason: ?[]const u8 = null,
    file_deleted: bool = false,
    outcome: RemoveOutcome,
};

/// Reverse the bridge half of an MCP client's wiring: drop agent_servers.tau
/// from ~/.config/mcacp/mcacp.json (deleting the file when it holds nothing
/// else). The bridge is shared — when another MCP client outside the removal
/// set still carries an "mcacp" entry the bridge is "kept" untouched. Files
/// that can't be read or parsed report "manual" with the hand-step.
fn removeBridgeWiring(io: std.Io, arena: std.mem.Allocator, home: []const u8, k: ClientKind, set: []const ClientKind, dry: bool) !BridgeRemove {
    const bpath = try mcacpConfigPath(arena, home);

    var others: std.ArrayList(u8) = .empty;
    var first = true;
    for (all_clients) |c| {
        if (c == k or !clientUsesBridge(c) or inSet(set, c)) continue;
        // YAML-configured bridge clients (Goose, Continue) carry no
        // inspectable settings file — they can't vouch for the bridge.
        const cpath = (try clientSettingsPath(arena, home, c)) orelse continue;
        const b = std.Io.Dir.cwd().readFileAlloc(io, cpath, arena, .unlimited) catch continue;
        if (hasTauEntry(arena, c, b) orelse false) {
            if (!first) try others.appendSlice(arena, ", ");
            first = false;
            try others.appendSlice(arena, clientName(c));
        }
    }
    if (others.items.len > 0) {
        return .{
            .status = "kept",
            .path = bpath,
            .reason = try std.fmt.allocPrint(arena, "still used by: {s}", .{others.items}),
            .outcome = .absent,
        };
    }

    const bytes = std.Io.Dir.cwd().readFileAlloc(io, bpath, arena, .unlimited) catch |err| {
        if (err == error.FileNotFound)
            return .{ .status = "absent", .path = bpath, .outcome = .absent };
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{
            .status = "manual",
            .path = bpath,
            .reason = "could not read mcacp bridge config — remove the \"tau\" entry by hand",
            .outcome = .manual,
        };
    };
    switch (try configedit.removeNestedMember(arena, bytes, "agent_servers", "tau")) {
        .invalid => return .{
            .status = "manual",
            .path = bpath,
            .reason = "mcacp bridge config did not parse as JSON/JSONC — remove the \"tau\" entry by hand",
            .outcome = .manual,
        },
        .absent => return .{ .status = "absent", .path = bpath, .outcome = .absent },
        .empty => {
            const fr = try removeFile(io, bpath, dry);
            return .{
                .status = if (fr == .would_remove) "would_remove" else "removed",
                .path = bpath,
                .file_deleted = true,
                .outcome = if (fr == .would_remove) .would_remove else .removed,
            };
        },
        .spliced => |body| {
            const w = try writeIfChanged(io, arena, bpath, body, dry);
            return .{
                .status = if (w == .would_write) "would_remove" else "removed",
                .path = bpath,
                .outcome = if (w == .would_write) .would_remove else .removed,
            };
        },
    }
}

/// Close a removal-mode client entry. Bridge clients append the bridge-side
/// fields first: a "manual"/"failed" bridge outcome downgrades the client
/// outcome (the wiring is only half undone); "kept" does not — the client's
/// own wiring is still cleanly reversed. When the bridge entry actually went
/// away, the mcacp paste-snippet is cleaned up too.
fn closeRemoveEntry(io: std.Io, arena: std.mem.Allocator, entries: *std.ArrayList(u8), home: []const u8, k: ClientKind, set: []const ClientKind, dry: bool, oc: RemoveOutcome) !RemoveOutcome {
    if (!clientUsesBridge(k)) {
        try entries.append(arena, '}');
        return oc;
    }
    const det = removeBridgeWiring(io, arena, home, k, set, dry) catch |err| {
        try entries.appendSlice(arena, ",\"bridge_status\":\"failed\",\"bridge_message\":");
        try js(arena, entries, @errorName(err));
        try entries.append(arena, '}');
        return .failed;
    };
    try entries.appendSlice(arena, ",\"bridge_path\":");
    try js(arena, entries, det.path);
    try entries.appendSlice(arena, ",\"bridge_status\":");
    try js(arena, entries, det.status);
    if (det.file_deleted) try entries.appendSlice(arena, ",\"bridge_file_deleted\":true");
    if (det.reason) |r| {
        try entries.appendSlice(arena, ",\"bridge_reason\":");
        try js(arena, entries, r);
    }
    if (det.outcome == .removed or det.outcome == .would_remove) {
        // The bridge entry is gone — its setup-generated paste snippet is
        // dead weight now. Report it like the per-client snippet fields.
        const snip = try mcacpSnippetPath(arena, home);
        const fr = removeFile(io, snip, dry) catch null;
        if (fr != null and fr.? != .absent) {
            try entries.appendSlice(arena, ",\"bridge_snippet_path\":");
            try js(arena, entries, snip);
            try entries.appendSlice(arena, ",\"bridge_snippet_status\":");
            try js(arena, entries, if (fr.? == .would_remove) "would_remove" else "removed");
        }
    }
    try entries.append(arena, '}');
    if (oc == .failed or det.outcome == .failed) return .failed;
    if (oc == .manual or det.outcome == .manual) return .manual;
    if (det.outcome == .removed or det.outcome == .would_remove) return det.outcome;
    return oc;
}

/// Reverse one client's `tau acp serve` wiring and append its JSON entry to
/// `entries`. The settings file is never re-rendered: the entry is spliced
/// out on the original bytes so comments and sibling settings survive
/// byte-for-byte; a file left holding no settings at all is deleted instead
/// (file_deleted:true). Files that can't be read or parsed are never
/// guessed at — they report "manual" with the hand-step. In dry-run mode
/// every deletion/rewrite is previewed as "would_remove" and nothing
/// changes.
fn unwireClient(io: std.Io, arena: std.mem.Allocator, entries: *std.ArrayList(u8), first: bool, home: []const u8, k: ClientKind, set: []const ClientKind, dry: bool) !RemoveOutcome {
    if (!first) try entries.append(arena, ',');
    try entries.appendSlice(arena, "{\"client\":");
    try js(arena, entries, clientName(k));

    if (k == .nvim or k == .emacs or k == .goose or k == .continue_) {
        // Init-file (Lua/elisp) and YAML wiring can't be introspected or
        // safely spliced — clean the setup-generated snippet and hand the
        // rest off. Goose/Continue still close through closeRemoveEntry so
        // the shared mcacp bridge entry is reverted like any MCP client.
        try removeSnippetFields(io, arena, entries, home, k, dry);
        try entries.appendSlice(arena, ",\"status\":\"manual\",\"reason\":");
        try js(arena, entries, switch (k) {
            .goose, .continue_ => "YAML wiring cannot be inspected — remove the pasted mcacp block by hand",
            else => "init-file wiring cannot be inspected — remove the pasted tau block by hand",
        });
        try entries.appendSlice(arena, ",\"next\":");
        try js(arena, entries, switch (k) {
            .goose => "delete the mcacp extension block from ~/.config/goose/config.yaml and restart Goose",
            .continue_ => "delete the mcacp list item from mcpServers in ~/.continue/config.yaml and restart Continue",
            else => "delete the tau block from your editor init file and restart",
        });
        return closeRemoveEntry(io, arena, entries, home, k, set, dry, .manual);
    }

    const path = (try clientSettingsPath(arena, home, k)).?;
    try entries.appendSlice(arena, ",\"path\":");
    try js(arena, entries, path);

    var oc: RemoveOutcome = .absent;
    const bytes: ?[]const u8 = blk: {
        const b = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited) catch |err| {
            switch (err) {
                error.FileNotFound => {
                    try entries.appendSlice(arena, ",\"status\":\"absent\"");
                    break :blk null;
                },
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    try entries.appendSlice(arena, ",\"status\":\"manual\",\"reason\":");
                    try js(arena, entries, "could not read the existing settings file — remove the entry by hand");
                    oc = .manual;
                    break :blk null;
                },
            }
        };
        break :blk b;
    };

    if (bytes) |b| {
        blk: {
            switch (try configedit.removeNestedMember(arena, b, clientSectionKey(k), clientEntryName(k))) {
                .invalid => {
                    try entries.appendSlice(arena, ",\"status\":\"manual\",\"reason\":");
                    const msg = try std.fmt.allocPrint(arena, "settings file did not parse as JSON/JSONC — remove the \"{s}\" entry by hand", .{clientEntryName(k)});
                    try js(arena, entries, msg);
                    oc = .manual;
                },
                .absent => {
                    try entries.appendSlice(arena, ",\"status\":\"absent\"");
                },
                .empty => {
                    const fr = removeFile(io, path, dry) catch |err| {
                        try entries.appendSlice(arena, ",\"status\":\"failed\",\"message\":");
                        const msg = try std.fmt.allocPrint(arena, "could not delete {s}: {s}", .{ path, @errorName(err) });
                        try js(arena, entries, msg);
                        oc = .failed;
                        break :blk;
                    };
                    try entries.appendSlice(arena, ",\"status\":");
                    try entries.appendSlice(arena, if (fr == .would_remove) "\"would_remove\"" else "\"removed\"");
                    try entries.appendSlice(arena, ",\"file_deleted\":true");
                    oc = if (fr == .would_remove) .would_remove else .removed;
                },
                .spliced => |body| {
                    const w = writeIfChanged(io, arena, path, body, dry) catch |err| {
                        try entries.appendSlice(arena, ",\"status\":\"failed\",\"message\":");
                        const msg = try std.fmt.allocPrint(arena, "could not write {s}: {s}", .{ path, @errorName(err) });
                        try js(arena, entries, msg);
                        oc = .failed;
                        break :blk;
                    };
                    try entries.appendSlice(arena, ",\"status\":");
                    try entries.appendSlice(arena, switch (w) {
                        .would_write => "\"would_remove\"",
                        .written => "\"removed\"",
                        .unchanged => "\"absent\"",
                    });
                    oc = switch (w) {
                        .would_write => .would_remove,
                        .written => .removed,
                        .unchanged => .absent,
                    };
                },
            }
        }
    }

    try removeSnippetFields(io, arena, entries, home, k, dry);
    return closeRemoveEntry(io, arena, entries, home, k, set, dry, oc);
}

/// The `setup --remove` step: reverse per-client editor wiring. --client
/// scopes the sweep; without it every client is processed — removal only
/// touches files that actually carry tau wiring, so the sweep is safe.
/// Returns false only on real failures — "manual" and "absent" outcomes
/// pass the verdict. Step status: failed | would_remove | removed | manual
/// (nothing removed but hand-work remains) | absent (nothing was wired).
fn stepRemoveClients(io: std.Io, arena: std.mem.Allocator, cfg: Config, env: *std.process.Environ.Map) !bool {
    const dry = cfg.setup_dry_run;
    var buf: std.ArrayList(u8) = .empty;
    const home = env.get("HOME") orelse {
        try buf.appendSlice(arena, "{\"step\":\"remove_clients\",\"status\":\"failed\",\"message\":");
        try js(arena, &buf, "HOME is not set — cannot locate editor config directories");
        try buf.appendSlice(arena, "}");
        emit(&buf);
        return false;
    };

    var clients: []const ClientKind = try resolveClients(arena, cfg);
    if (clients.len == 0) clients = &all_clients;

    var entries: std.ArrayList(u8) = .empty;
    try entries.append(arena, '[');
    var ok = true;
    var any_removed = false;
    var any_would = false;
    var any_manual = false;
    for (clients, 0..) |k, i| {
        switch (try unwireClient(io, arena, &entries, i == 0, home, k, clients, dry)) {
            .failed => ok = false,
            .removed => any_removed = true,
            .would_remove => any_would = true,
            .manual => any_manual = true,
            .absent => {},
        }
    }
    try entries.append(arena, ']');

    try buf.appendSlice(arena, "{\"step\":\"remove_clients\",\"status\":");
    if (!ok) {
        try buf.appendSlice(arena, "\"failed\"");
    } else if (any_would) {
        try buf.appendSlice(arena, "\"would_remove\"");
    } else if (any_removed) {
        try buf.appendSlice(arena, "\"removed\"");
    } else if (any_manual) {
        try buf.appendSlice(arena, "\"manual\"");
    } else {
        try buf.appendSlice(arena, "\"absent\"");
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
/// final `{"step":"setup","ok":...,"done":true}` verdict. Exit 0 when all steps pass (a
/// detection skip on completions or clients, and manual client outcomes,
/// still pass); 1 on any failure — including a doctor report with failed
/// checks, since onboarding is not healthy yet. In unattended mode the
/// verdict carries "non_interactive":true (and "yes":true when --yes was
/// given) so scripts can confirm the contract was requested. Under
/// --dry-run the write steps preview their changes (`would_*` statuses) and
/// the verdict carries "dry_run":true.
/// Removal mode (`--remove`/`--uninstall`): the stream is just the
/// remove_clients step + verdict (which carries "remove":true) — the
/// init/completions/doctor steps don't run.
pub fn run(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, cfg: Config, env: *std.process.Environ.Map) !u8 {
    var buf: std.ArrayList(u8) = .empty;
    var ok = true;
    if (cfg.setup_remove) {
        ok = try stepRemoveClients(io, arena, cfg, env);
    } else {
        ok = try stepInit(io, arena, cfg, env);
        if (!try stepCompletions(io, arena, cfg, env)) ok = false;
        if (!try stepClients(io, arena, cfg, env)) ok = false;

        const rep = try doctor.collectReport(io, gpa, arena, cfg, env);
        try buf.appendSlice(arena, "{\"step\":\"doctor\",\"report\":");
        try buf.appendSlice(arena, if (isJsonObject(rep.json)) rep.json else "{}");
        try buf.appendSlice(arena, "}");
        emit(&buf);
        if (!rep.ok) ok = false;
    }

    try buf.appendSlice(arena, "{\"step\":\"setup\",\"ok\":");
    try buf.appendSlice(arena, if (ok) "true" else "false");
    try buf.appendSlice(arena, ",\"version\":");
    try js(arena, &buf, version);
    if (cfg.setup_remove) try buf.appendSlice(arena, ",\"remove\":true");
    if (unattended(cfg)) try buf.appendSlice(arena, ",\"non_interactive\":true");
    if (cfg.setup_yes) try buf.appendSlice(arena, ",\"yes\":true");
    if (cfg.setup_dry_run) try buf.appendSlice(arena, ",\"dry_run\":true");
    // The stream's terminal marker — the same done:true convention
    // `tau doctor --json` and the chat stream use.
    try buf.appendSlice(arena, ",\"done\":true}");
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
    try testing.expectEqual(ClientKind.emacs, parseClientName("emacs").?);
    try testing.expectEqual(ClientKind.vscode, parseClientName("vscode").?);
    try testing.expectEqual(ClientKind.vscode, parseClientName("code").?);
    try testing.expectEqual(ClientKind.cursor, parseClientName("cursor").?);
    try testing.expectEqual(ClientKind.jetbrains, parseClientName("jetbrains").?);
    try testing.expectEqual(ClientKind.windsurf, parseClientName("windsurf").?);
    try testing.expectEqual(ClientKind.gemini, parseClientName("gemini").?);
    try testing.expectEqual(ClientKind.gemini, parseClientName("gemini-cli").?);
    try testing.expectEqual(ClientKind.claude_desktop, parseClientName("claude-desktop").?);
    try testing.expectEqual(ClientKind.claude_desktop, parseClientName("claude").?);
    try testing.expectEqual(ClientKind.opencode, parseClientName("opencode").?);
    try testing.expectEqual(ClientKind.cline, parseClientName("cline").?);
    try testing.expectEqual(ClientKind.goose, parseClientName("goose").?);
    try testing.expectEqual(ClientKind.continue_, parseClientName("continue").?);
    try testing.expectEqual(ClientKind.roo, parseClientName("roo-code").?);
    try testing.expectEqual(ClientKind.roo, parseClientName("roo").?);
    try testing.expectEqual(ClientKind.kilo, parseClientName("kilo-code").?);
    try testing.expectEqual(ClientKind.kilo, parseClientName("kilo").?);
    try testing.expectEqual(ClientKind.amazonq, parseClientName("amazonq").?);
    try testing.expectEqual(ClientKind.amazonq, parseClientName("amazon-q").?);
    try testing.expect(parseClientName("vim") == null);
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
        "/h/.config/Cursor/User/settings.json",
        (try clientSettingsPath(a, "/h", .cursor)).?,
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
    try testing.expectEqualStrings(
        "/h/.config/opencode/opencode.json",
        (try clientSettingsPath(a, "/h", .opencode)).?,
    );
    try testing.expect((try clientSettingsPath(a, "/h", .nvim)) == null);
    try testing.expect((try clientSettingsPath(a, "/h", .emacs)) == null);
    try testing.expectEqualStrings(
        "/h/.config/Code/User/globalStorage/rooveterinaryinc.roo-cline/settings/mcp_settings.json",
        (try clientSettingsPath(a, "/h", .roo)).?,
    );
    try testing.expectEqualStrings(
        "/h/.config/kilo/kilo.jsonc",
        (try clientSettingsPath(a, "/h", .kilo)).?,
    );
    try testing.expectEqualStrings(
        "/h/.aws/amazonq/mcp.json",
        (try clientSettingsPath(a, "/h", .amazonq)).?,
    );
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

    for ([_]ClientKind{ .zed, .vscode, .cursor, .jetbrains }) |k| {
        const body = try renderClientJson(a, k, "/abs/path/tau");
        // Must parse as JSON and already satisfy hasTauEntry.
        try testing.expectEqual(@as(?bool, true), hasTauEntry(a, k, body));
        try testing.expect(std.mem.indexOf(u8, body, "\"/abs/path/tau\"") != null);
        try testing.expect(std.mem.indexOf(u8, body, "[\"acp\", \"serve\"]") != null);
    }

    // MCP-bridge clients write an mcpServers.mcacp entry — the file launches
    // the bridge and never mentions the tau command path.
    for ([_]ClientKind{ .windsurf, .gemini, .claude_desktop, .roo, .amazonq }) |k| {
        const body = try renderClientJson(a, k, "/abs/path/tau");
        try testing.expectEqual(@as(?bool, true), hasTauEntry(a, k, body));
        try testing.expect(std.mem.indexOf(u8, body, "\"mcpServers\"") != null);
        try testing.expect(std.mem.indexOf(u8, body, "\"/abs/path/tau\"") == null);
        try testing.expect(std.mem.indexOf(u8, body, "[\"acp\", \"serve\"]") == null);
    }

    // OpenCode and Kilo Code are bridge clients too, but their entry sits
    // under "mcp" as a local server whose "command" is the whole spawn
    // line (an array).
    for ([_]ClientKind{ .opencode, .kilo }) |k| {
        const body = try renderClientJson(a, k, "/abs/path/tau");
        try testing.expectEqual(@as(?bool, true), hasTauEntry(a, k, body));
        try testing.expect(std.mem.indexOf(u8, body, "\"mcp\"") != null);
        try testing.expect(std.mem.indexOf(u8, body, "\"type\": \"local\"") != null);
        try testing.expect(std.mem.indexOf(u8, body, "[\"npx\", \"-y\", \"mcacp\"]") != null);
        try testing.expect(std.mem.indexOf(u8, body, "\"/abs/path/tau\"") == null);
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
    try testing.expectEqual(@as(?bool, true), hasTauEntry(a, .roo, bridged));
    try testing.expectEqual(@as(?bool, true), hasTauEntry(a, .amazonq, bridged));
    try testing.expectEqual(@as(?bool, false), hasTauEntry(a, .windsurf, with_tau));
    try testing.expectEqual(@as(?bool, false), hasTauEntry(a, .zed, bridged));
    // OpenCode and Kilo Code key on "mcacp" inside "mcp" (their own
    // section shape).
    const oc_bridged =
        \\{
        \\  "mcp": {
        \\    "mcacp": { "type": "local", "command": ["npx", "-y", "mcacp"] }
        \\  }
        \\}
    ;
    try testing.expectEqual(@as(?bool, true), hasTauEntry(a, .opencode, oc_bridged));
    try testing.expectEqual(@as(?bool, true), hasTauEntry(a, .kilo, oc_bridged));
    try testing.expectEqual(@as(?bool, false), hasTauEntry(a, .opencode, bridged));
    try testing.expectEqual(@as(?bool, false), hasTauEntry(a, .kilo, bridged));

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
    const oc = try configureClient(io, a, &entries, true, home, .zed, "/abs/tau", false, false);
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
    const oc2 = try configureClient(io, a, &entries, true, home, .zed, "/abs/tau", false, false);
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
    const oc = try configureClient(io, a, &entries, true, home, .zed, "/abs/tau", false, true);
    try testing.expectEqual(ClientOutcome.would_install, oc);
    try testing.expect(std.mem.indexOf(u8, entries.items, "\"status\":\"would_install\"") != null);

    // Nothing landed — not even the parent .config/zed directory.
    const sp = try std.fmt.allocPrint(a, "{s}/.config/zed/settings.json", .{home});
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().readFileAlloc(io, sp, a, .unlimited));
    try testing.expect(!dirExists(io, try std.fmt.allocPrint(a, "{s}/.config/zed", .{home})));

    // Dry-run on an already-configured client still reports already_installed.
    _ = try configureClient(io, a, &entries, true, home, .zed, "/abs/tau", false, false);
    entries.clearRetainingCapacity();
    const oc2 = try configureClient(io, a, &entries, true, home, .zed, "/abs/tau", false, true);
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
    const oc = try configureClient(io, a, &entries, true, home, .zed, "/abs/tau", false, true);
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
    const oc = try configureClient(io, a, &entries, true, home, .zed, "/abs/tau", false, false);
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
    const oc = try configureClient(io, a, &entries, true, home, .nvim, "/abs/tau", false, false);
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
    const oc = try configureClient(io, a, &entries, true, home, .windsurf, "/abs/tau", false, false);
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
    const oc2 = try configureClient(io, a, &entries, true, home, .windsurf, "/abs/tau", false, false);
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
    const oc = try configureClient(io, a, &entries, true, home, .gemini, "/abs/tau", false, true);
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

test "opencode bridge: mcp.local entry writes and classifies" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(io, ".", a);
    const exe = try std.process.executablePathAlloc(io, a);

    const odir = try std.fmt.allocPrint(a, "{s}/.config/opencode", .{home});
    try std.Io.Dir.cwd().createDirPath(io, odir);
    const sp = try std.fmt.allocPrint(a, "{s}/opencode.json", .{odir});

    var entries: std.ArrayList(u8) = .empty;
    const oc = try configureClient(io, a, &entries, true, home, .opencode, exe, false, false);
    try testing.expectEqual(ClientOutcome.installed, oc);
    try testing.expect(std.mem.indexOf(u8, entries.items, "\"bridge_status\":\"installed\"") != null);

    // The settings file carries the OpenCode-shaped local MCP entry.
    const body = try std.Io.Dir.cwd().readFileAlloc(io, sp, a, .unlimited);
    try testing.expect(std.mem.indexOf(u8, body, "\"type\": \"local\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"command\": [\"npx\", \"-y\", \"mcacp\"]") != null);
    try testing.expectEqual(@as(?bool, true), hasTauEntry(a, .opencode, body));

    // Client entry + real bridge config -> wiring ok.
    try testing.expectEqual(WiringState.ok, (try inspectClientWiring(io, a, home, .opencode)).state);

    // A command string (the mcpServers shape) is stale for opencode.
    _ = try writeIfChanged(io, a, sp, "{\"mcp\": {\"mcacp\": {\"command\":\"npx\",\"args\":[\"-y\",\"mcacp\"]}}}", false);
    const wrong_shape = try inspectClientWiring(io, a, home, .opencode);
    try testing.expectEqual(WiringState.stale, wrong_shape.state);
    try testing.expect(std.mem.indexOf(u8, wrong_shape.reason.?, "command") != null);
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

    // Guide file per client (gemini's file is named gemini-cli.md). Direct
    // ACP clients verify the two client-* slots; MCP-bridge clients verify
    // all four; snippet-only clients (no JSON settings file) verify just
    // their paste-ready snippet.
    const Guide = struct { file: []const u8, kind: ClientKind, direct: bool = false, snippet_only: bool = false, yaml: bool = false };
    const guides = [_]Guide{
        .{ .file = "docs/clients/zed.md", .kind = .zed, .direct = true },
        .{ .file = "docs/clients/vscode.md", .kind = .vscode, .direct = true },
        .{ .file = "docs/clients/cursor.md", .kind = .cursor, .direct = true },
        .{ .file = "docs/clients/jetbrains.md", .kind = .jetbrains, .direct = true },
        .{ .file = "docs/clients/emacs.md", .kind = .emacs, .snippet_only = true },
        .{ .file = "docs/clients/nvim.md", .kind = .nvim, .snippet_only = true },
        .{ .file = "docs/clients/windsurf.md", .kind = .windsurf },
        .{ .file = "docs/clients/gemini-cli.md", .kind = .gemini },
        .{ .file = "docs/clients/claude-desktop.md", .kind = .claude_desktop },
        .{ .file = "docs/clients/opencode.md", .kind = .opencode },
        .{ .file = "docs/clients/cline.md", .kind = .cline },
        .{ .file = "docs/clients/goose.md", .kind = .goose, .yaml = true },
        .{ .file = "docs/clients/continue.md", .kind = .continue_, .yaml = true },
        .{ .file = "docs/clients/roo-code.md", .kind = .roo },
        .{ .file = "docs/clients/kilo-code.md", .kind = .kilo },
        .{ .file = "docs/clients/amazonq.md", .kind = .amazonq },
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
                return switch (k) {
                    .nvim => renderNvimSnippet(al, "tau"),
                    .emacs => renderEmacsSnippet(al, "tau"),
                    .goose, .continue_ => renderYamlBridgeSnippet(al, k),
                    else => renderClientSnippet(al, k, "tau"),
                };
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
            if (g.direct and std.mem.startsWith(u8, s.marker, "bridge")) continue;
            if (g.snippet_only and !std.mem.eql(u8, s.marker, "client-snippet")) continue;
            // YAML bridge clients carry no client-file slot (their config
            // can't be written) but do verify the shared bridge slots.
            if (g.yaml and std.mem.eql(u8, s.marker, "client-file")) continue;
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

test "inSet membership" {
    const set = [_]ClientKind{ .zed, .gemini };
    try testing.expect(inSet(&set, .gemini));
    try testing.expect(!inSet(&set, .windsurf));
    try testing.expect(!inSet(&set, .zed) == false);
}

test "unwireClient deletes a setup-written file and reports absent on re-run" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(io, ".", a);
    const set = [_]ClientKind{.zed};

    var entries: std.ArrayList(u8) = .empty;
    _ = try configureClient(io, a, &entries, true, home, .zed, "/abs/tau", false, false);
    const sp = try std.fmt.allocPrint(a, "{s}/.config/zed/settings.json", .{home});
    _ = try std.Io.Dir.cwd().readFileAlloc(io, sp, a, .unlimited);

    entries.clearRetainingCapacity();
    const oc = try unwireClient(io, a, &entries, true, home, .zed, &set, false);
    try testing.expectEqual(RemoveOutcome.removed, oc);
    try testing.expect(std.mem.indexOf(u8, entries.items, "\"file_deleted\":true") != null);
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().readFileAlloc(io, sp, a, .unlimited));

    entries.clearRetainingCapacity();
    const oc2 = try unwireClient(io, a, &entries, true, home, .zed, &set, false);
    try testing.expectEqual(RemoveOutcome.absent, oc2);
    try testing.expect(std.mem.indexOf(u8, entries.items, "\"status\":\"absent\"") != null);
}

test "unwireClient splices the entry out and preserves user bytes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(io, ".", a);
    const set = [_]ClientKind{.zed};
    const sp = try std.fmt.allocPrint(a, "{s}/.config/zed/settings.json", .{home});
    const orig = "{\n  // user comment must survive\n  \"vim_mode\": true,\n  \"agent_servers\": {\n    \"tau\": { \"type\": \"custom\", \"command\": \"/x/tau\", \"args\": [\"acp\", \"serve\"] }\n  },\n  \"theme\": \"dark\"\n}\n";
    _ = try writeIfChanged(io, a, sp, orig, false);

    var entries: std.ArrayList(u8) = .empty;
    const oc = try unwireClient(io, a, &entries, true, home, .zed, &set, false);
    try testing.expectEqual(RemoveOutcome.removed, oc);
    try testing.expect(std.mem.indexOf(u8, entries.items, "\"file_deleted\"") == null);

    const got = try std.Io.Dir.cwd().readFileAlloc(io, sp, a, .unlimited);
    try testing.expect(std.mem.indexOf(u8, got, "\"tau\"") == null);
    try testing.expect(std.mem.indexOf(u8, got, "\"agent_servers\"") == null);
    try testing.expect(std.mem.indexOf(u8, got, "// user comment must survive") != null);
    try testing.expect(std.mem.indexOf(u8, got, "\"vim_mode\": true") != null);
    try testing.expect(std.mem.indexOf(u8, got, "\"theme\": \"dark\"") != null);
    // The result still parses as JSON.
    try testing.expect(hasTauEntry(a, .zed, got) != null);
}

test "unwireClient dry-run previews and changes nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(io, ".", a);
    const set = [_]ClientKind{.zed};

    var entries: std.ArrayList(u8) = .empty;
    _ = try configureClient(io, a, &entries, true, home, .zed, "/abs/tau", false, false);
    const sp = try std.fmt.allocPrint(a, "{s}/.config/zed/settings.json", .{home});
    const before = try std.Io.Dir.cwd().readFileAlloc(io, sp, a, .unlimited);

    entries.clearRetainingCapacity();
    const oc = try unwireClient(io, a, &entries, true, home, .zed, &set, true);
    try testing.expectEqual(RemoveOutcome.would_remove, oc);
    try testing.expect(std.mem.indexOf(u8, entries.items, "\"status\":\"would_remove\"") != null);
    try testing.expect(std.mem.indexOf(u8, entries.items, "\"file_deleted\":true") != null);

    // Bytes unchanged, file still wired.
    const after = try std.Io.Dir.cwd().readFileAlloc(io, sp, a, .unlimited);
    try testing.expectEqualStrings(before, after);
    try testing.expectEqual(@as(?bool, true), hasTauEntry(a, .zed, after));
}

test "unwireClient bridge: shared mcacp kept while another bridge client is wired" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(io, ".", a);

    var entries: std.ArrayList(u8) = .empty;
    _ = try configureClient(io, a, &entries, true, home, .windsurf, "/abs/tau", false, false);
    _ = try configureClient(io, a, &entries, true, home, .gemini, "/abs/tau", false, false);
    const bpath = try mcacpConfigPath(a, home);

    // Removing only windsurf keeps the shared bridge for gemini.
    const wset = [_]ClientKind{.windsurf};
    entries.clearRetainingCapacity();
    const oc = try unwireClient(io, a, &entries, true, home, .windsurf, &wset, false);
    try testing.expectEqual(RemoveOutcome.removed, oc);
    try testing.expect(std.mem.indexOf(u8, entries.items, "\"bridge_status\":\"kept\"") != null);
    try testing.expect(std.mem.indexOf(u8, entries.items, "gemini") != null);
    const still = try std.Io.Dir.cwd().readFileAlloc(io, bpath, a, .unlimited);
    try testing.expectEqual(@as(?bool, true), bridgeHasTau(a, still));

    // Removing gemini too (both in the set) drops the bridge config.
    const both = [_]ClientKind{ .windsurf, .gemini };
    entries.clearRetainingCapacity();
    const oc2 = try unwireClient(io, a, &entries, true, home, .gemini, &both, false);
    try testing.expectEqual(RemoveOutcome.removed, oc2);
    try testing.expect(std.mem.indexOf(u8, entries.items, "\"bridge_status\":\"removed\"") != null);
    try testing.expect(std.mem.indexOf(u8, entries.items, "\"bridge_file_deleted\":true") != null);
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().readFileAlloc(io, bpath, a, .unlimited));
}

test "unwireClient nvim reports manual and removes the setup snippet" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(io, ".", a);
    const set = [_]ClientKind{.nvim};

    var entries: std.ArrayList(u8) = .empty;
    _ = try configureClient(io, a, &entries, true, home, .nvim, "/abs/tau", false, false);
    const snip = try snippetPath(a, home, .nvim);
    _ = try std.Io.Dir.cwd().readFileAlloc(io, snip, a, .unlimited);

    entries.clearRetainingCapacity();
    const oc = try unwireClient(io, a, &entries, true, home, .nvim, &set, false);
    try testing.expectEqual(RemoveOutcome.manual, oc);
    try testing.expect(std.mem.indexOf(u8, entries.items, "\"snippet_status\":\"removed\"") != null);
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().readFileAlloc(io, snip, a, .unlimited));
}

test "unwireClient unparseable settings reports manual and leaves bytes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(io, ".", a);
    const set = [_]ClientKind{.zed};
    const sp = try std.fmt.allocPrint(a, "{s}/.config/zed/settings.json", .{home});
    const orig = "{ not json at all";
    _ = try writeIfChanged(io, a, sp, orig, false);

    var entries: std.ArrayList(u8) = .empty;
    const oc = try unwireClient(io, a, &entries, true, home, .zed, &set, false);
    try testing.expectEqual(RemoveOutcome.manual, oc);
    try testing.expect(std.mem.indexOf(u8, entries.items, "\"status\":\"manual\"") != null);
    const got = try std.Io.Dir.cwd().readFileAlloc(io, sp, a, .unlimited);
    try testing.expectEqualStrings(orig, got);
}

test "removeFile: absent, removed, and would_remove under dry-run" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    const p = try std.fmt.allocPrint(a, "{s}/f.txt", .{root});

    try testing.expectEqual(FileRemove.absent, try removeFile(io, p, false));
    _ = try writeIfChanged(io, a, p, "x", false);
    try testing.expectEqual(FileRemove.would_remove, try removeFile(io, p, true));
    try testing.expectEqual(FileRemove.removed, try removeFile(io, p, false));
}

test "collectImportable gathers stdio servers, skips mcacp/remote, dedups by name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(io, ".", a);

    // Claude Desktop: two stdio servers + a remote one + tau's own entry.
    _ = try writeIfChanged(io, a, try std.fmt.allocPrint(a, "{s}/.config/Claude/claude_desktop_config.json", .{home}),
        \\{
        \\  // comment survives the scan
        \\  "mcpServers": {
        \\    "filesystem": { "command": "npx", "args": ["-y", "fs-mcp"], "env": {"ROOT": "/x"} },
        \\    "github": { "command": "docker", "args": ["run", "gh"] },
        \\    "remote-svc": { "url": "https://mcp.example.com/sse" },
        \\    "mcacp": { "command": "npx", "args": ["-y", "mcacp"] }
        \\  }
        \\}
        \\
    , false);
    // Gemini: one new server + a name that collides with Claude's.
    _ = try writeIfChanged(io, a, try std.fmt.allocPrint(a, "{s}/.gemini/settings.json", .{home}),
        \\{"mcpServers": {"fs2": {"command": "uvx"}, "github": {"command": "other"}}}
        \\
    , false);

    const plan = try collectImportable(io, a, home, .windsurf);
    try testing.expectEqual(@as(usize, 3), plan.servers.items.len);
    // Sources iterate in all_clients order: gemini before claude_desktop —
    // gemini's "github" wins the dedup.
    try testing.expectEqualStrings("fs2", plan.servers.items[0].name);
    try testing.expectEqual(ClientKind.gemini, plan.servers.items[0].from);
    try testing.expectEqual(@as(usize, 0), plan.servers.items[0].args.len);
    try testing.expectEqualStrings("github", plan.servers.items[1].name);
    try testing.expectEqual(ClientKind.gemini, plan.servers.items[1].from);
    try testing.expectEqualStrings("filesystem", plan.servers.items[2].name);
    try testing.expect(plan.servers.items[2].env != null);

    // Skips: remote entry + the deduped name — and never the mcacp entry.
    var saw_remote = false;
    var saw_dup = false;
    for (plan.skipped.items) |s| {
        if (s.name) |n| {
            if (std.mem.eql(u8, n, "remote-svc")) saw_remote = true;
            if (std.mem.eql(u8, n, "github") and s.from == .claude_desktop) saw_dup = true;
        }
        try testing.expect(!std.mem.eql(u8, s.name orelse "", "mcacp"));
    }
    try testing.expect(saw_remote);
    try testing.expect(saw_dup);
}

test "collectImportable unparseable source reports a file-level skip" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(io, ".", a);

    _ = try writeIfChanged(io, a, try std.fmt.allocPrint(a, "{s}/.gemini/settings.json", .{home}), "{ not json", false);
    const plan = try collectImportable(io, a, home, .windsurf);
    try testing.expectEqual(@as(usize, 0), plan.servers.items.len);
    try testing.expectEqual(@as(usize, 1), plan.skipped.items.len);
    try testing.expect(plan.skipped.items[0].name == null);
    try testing.expectEqual(ClientKind.gemini, plan.skipped.items[0].from);
}

test "canonOpenCode translates local entries, skips remote and bad shapes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"local": {"type":"local","command":["npx","-y","m"],"enabled":false},
        \\ "remote": {"type":"remote","url":"https://x"},
        \\ "bad": {"type":"local"},
        \\ "bare": {"command":["cmd"]}}
        \\
    , .{});
    const obj = parsed.object;

    const ok = try canonOpenCode(a, "local", obj.get("local").?.object, .opencode);
    try testing.expectEqualStrings("npx", ok.ok.command);
    try testing.expectEqual(@as(usize, 2), ok.ok.args.len);
    try testing.expectEqualStrings("-y", ok.ok.args[0]);
    try testing.expectEqual(@as(?bool, false), ok.ok.enabled);

    const rem = try canonOpenCode(a, "remote", obj.get("remote").?.object, .opencode);
    try testing.expectEqualStrings("remote servers are not imported", rem.skip);

    const bad = try canonOpenCode(a, "bad", obj.get("bad").?.object, .opencode);
    try testing.expectEqualStrings("not a local server entry (no \"command\" array)", bad.skip);

    const bare = try canonOpenCode(a, "bare", obj.get("bare").?.object, .opencode);
    try testing.expectEqualStrings("cmd", bare.ok.command);
    try testing.expectEqual(@as(?bool, null), bare.ok.enabled);
}

test "renderImportToken renders both server-entry shapes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const srv = ImportServer{
        .name = "s",
        .command = "npx",
        .args = &.{ "-y", "m" },
        .enabled = false,
        .from = .gemini,
    };
    try testing.expectEqualStrings(
        "{\"command\":\"npx\",\"args\":[\"-y\",\"m\"]}",
        try renderImportToken(a, .windsurf, srv),
    );
    try testing.expectEqualStrings(
        "{\"type\":\"local\",\"command\":[\"npx\",\"-y\",\"m\"],\"enabled\":false}",
        try renderImportToken(a, .opencode, srv),
    );
}

test "configureClient --import splices mcacp + imported servers into an existing file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(io, ".", a);

    // Target file: a user's windsurf config — comment + own server + a
    // sibling setting must all survive byte-for-byte.
    const wpath = try std.fmt.allocPrint(a, "{s}/.codeium/windsurf/mcp_config.json", .{home});
    const before =
        \\{
        \\  // keep me
        \\  "mcpServers": {
        \\    "mine": { "command": "mine", "args": ["x"] }
        \\  },
        \\  "theme": "dark"
        \\}
        \\
    ;
    _ = try writeIfChanged(io, a, wpath, before, false);

    // Source: claude_desktop carries a server to import.
    _ = try writeIfChanged(io, a, try std.fmt.allocPrint(a, "{s}/.config/Claude/claude_desktop_config.json", .{home}),
        \\{"mcpServers": {"fs": {"command": "npx", "args": ["-y", "fs"]}}}
        \\
    , false);

    var entries: std.ArrayList(u8) = .empty;
    const oc = try configureClient(io, a, &entries, true, home, .windsurf, "/abs/tau", true, false);
    try testing.expectEqual(ClientOutcome.installed, oc);
    try testing.expect(std.mem.indexOf(u8, entries.items, "\"imported\":[{\"name\":\"fs\",\"from\":\"claude-desktop\"}]") != null);

    const after = try std.Io.Dir.cwd().readFileAlloc(io, wpath, a, .unlimited);
    // User wiring preserved: the comment, the existing entry, the sibling.
    try testing.expect(std.mem.indexOf(u8, after, "// keep me") != null);
    try testing.expect(std.mem.indexOf(u8, after, "\"command\": \"mine\"") != null);
    try testing.expect(std.mem.indexOf(u8, after, "\"theme\": \"dark\"") != null);
    // mcacp spliced in alongside the imported server.
    try testing.expect(std.mem.indexOf(u8, after, "\"mcacp\"") != null);
    try testing.expect(std.mem.indexOf(u8, after, "\"fs\"") != null);
    // Still valid JSONC.
    try testing.expectEqual(@as(?bool, true), hasTauEntry(a, .windsurf, after));
    try testing.expectEqual(@as(?bool, true), sectionHasEntry(a, "mcpServers", "fs", after));
}

test "configureClient --import dry-run previews the merge, writes nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(io, ".", a);

    const wpath = try std.fmt.allocPrint(a, "{s}/.codeium/windsurf/mcp_config.json", .{home});
    const before = "{\"mcpServers\": {}}\n";
    _ = try writeIfChanged(io, a, wpath, before, false);
    _ = try writeIfChanged(io, a, try std.fmt.allocPrint(a, "{s}/.gemini/settings.json", .{home}),
        \\{"mcpServers": {"fs": {"command": "npx", "args": ["-y", "fs"]}}}
        \\
    , false);

    var entries: std.ArrayList(u8) = .empty;
    const oc = try configureClient(io, a, &entries, true, home, .windsurf, "/abs/tau", true, true);
    try testing.expectEqual(ClientOutcome.would_install, oc);
    try testing.expect(std.mem.indexOf(u8, entries.items, "\"imported\":[{\"name\":\"fs\",\"from\":\"gemini\"}]") != null);

    // The target file is byte-identical — the merge was only previewed.
    const after = try std.Io.Dir.cwd().readFileAlloc(io, wpath, a, .unlimited);
    try testing.expectEqualStrings(before, after);
}

test "configureClient --import on an already-wired file merges only missing servers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(io, ".", a);

    const wpath = try std.fmt.allocPrint(a, "{s}/.codeium/windsurf/mcp_config.json", .{home});
    _ = try writeIfChanged(io, a, wpath,
        \\{"mcpServers": {"mcacp": {"command": "npx", "args": ["-y", "mcacp"]}}}
        \\
    , false);
    const plan_home = home;

    // Nothing to import yet -> already_installed.
    var entries: std.ArrayList(u8) = .empty;
    const oc0 = try configureClient(io, a, &entries, true, plan_home, .windsurf, "/abs/tau", true, false);
    try testing.expectEqual(ClientOutcome.already_installed, oc0);
    try testing.expect(std.mem.indexOf(u8, entries.items, "\"imported\":[]") != null);

    // A source appears -> only the new server merges.
    _ = try writeIfChanged(io, a, try std.fmt.allocPrint(a, "{s}/.gemini/settings.json", .{home}),
        \\{"mcpServers": {"fs": {"command": "npx", "args": ["-y", "fs"]}}}
        \\
    , false);
    entries.clearRetainingCapacity();
    const oc = try configureClient(io, a, &entries, true, home, .windsurf, "/abs/tau", true, false);
    try testing.expectEqual(ClientOutcome.installed, oc);

    const after = try std.Io.Dir.cwd().readFileAlloc(io, wpath, a, .unlimited);
    try testing.expectEqual(@as(?bool, true), sectionHasEntry(a, "mcpServers", "fs", after));
}

test "configureClient --import falls back to manual on an unparseable file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(io, ".", a);

    const wpath = try std.fmt.allocPrint(a, "{s}/.codeium/windsurf/mcp_config.json", .{home});
    const before = "{ not json\n";
    _ = try writeIfChanged(io, a, wpath, before, false);

    var entries: std.ArrayList(u8) = .empty;
    const oc = try configureClient(io, a, &entries, true, home, .windsurf, "/abs/tau", true, false);
    try testing.expectEqual(ClientOutcome.manual, oc);
    try testing.expect(std.mem.indexOf(u8, entries.items, "\"snippet_path\":") != null);
    try testing.expect(std.mem.indexOf(u8, entries.items, "\"imported\":[]") != null);

    const after = try std.Io.Dir.cwd().readFileAlloc(io, wpath, a, .unlimited);
    try testing.expectEqualStrings(before, after);
}

// ---------------------------------------------------------------------------
// --import / --remove round-trip property tests — the byte-fidelity contract:
// splicing tau's entry into a user's settings file and taking it back out
// must leave every byte the user wrote exactly where it was.
// ---------------------------------------------------------------------------

/// Settings-file shapes every JSONC client is round-tripped through. `@SEC@`
/// stands in for the client's section key — "mcpServers" (Windsurf, Gemini,
/// Claude Desktop, Cline, Roo Code, Amazon Q), "mcp" (OpenCode, Kilo Code),
/// "agent_servers" (Zed, JetBrains) or "acp.agents" (VS Code, Cursor).
const round_trip_cases = [_]struct {
    name: []const u8,
    body: []const u8,
}{
    .{ .name = "comments and siblings around the section", .body =
        \\{
        \\  // user's own comment
        \\  "@SEC@": {
        \\    "mine": { "command": "mine", "args": ["x"] }
        \\  },
        \\  "theme": "dark"
        \\}
        \\
    },
    .{ .name = "section absent — appended then removed wholesale", .body =
        \\{
        \\  "other": true,
        \\  "hint": "no @SEC@ yet"
        \\}
        \\
    },
    .{ .name = "single-line compact document", .body = "{\"@SEC@\":{\"a\":{}},\"z\":1}" },
    .{ .name = "comment after the last section member", .body =
        \\{
        \\  "@SEC@": {
        \\    "mine": {}
        \\    // trailing note
        \\  }
        \\}
        \\
    },
    .{ .name = "dangling comma inside the section", .body =
        \\{
        \\  "@SEC@": {
        \\    "a": {},
        \\  },
        \\  "x": 1
        \\}
        \\
    },
};

/// The `{s}`-free render of a round-trip case for one client.
fn rtBody(arena: std.mem.Allocator, tmpl: []const u8, k: ClientKind) ![]u8 {
    return std.mem.replaceOwned(u8, arena, tmpl, "@SEC@", clientSectionKey(k));
}

/// Entry token a direct client's file carries — mirrors the shapes
/// renderClientJson writes (zed requires "type": "custom").
fn rtTauToken(k: ClientKind) []const u8 {
    return switch (k) {
        .zed => "{\"type\":\"custom\",\"command\":\"/abs/tau\",\"args\":[\"acp\",\"serve\"],\"env\":{}}",
        else => "{\"command\":\"/abs/tau\",\"args\":[\"acp\",\"serve\"],\"env\":{}}",
    };
}

test "property: wire then --remove restores user bytes for every JSONC client" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);

    var case_n: usize = 0;
    for (all_clients) |k| {
        // Snippet-only clients (nvim/emacs Lua+elisp, goose/continue YAML)
        // never get their file edited in place — nothing to round-trip.
        if ((try clientSettingsPath(a, root, k)) == null) continue;
        for (round_trip_cases) |c| {
            const home = try std.fmt.allocPrint(a, "{s}/h{d}", .{ root, case_n });
            case_n += 1;
            const cpath = (try clientSettingsPath(a, home, k)).?;
            const orig = try rtBody(a, c.body, k);
            _ = try writeIfChanged(io, a, cpath, orig, false);

            var entries: std.ArrayList(u8) = .empty;
            if (clientUsesBridge(k)) {
                // The real wiring path: --import splices the mcacp entry
                // into the existing file.
                const woc = try configureClient(io, a, &entries, true, home, k, "/abs/tau", true, false);
                try testing.expectEqual(ClientOutcome.installed, woc);
            } else {
                // A direct client's entry lands the way the user pastes it —
                // same insert primitive the --import path uses.
                const wired = switch (try configedit.insertNestedMember(a, orig, clientSectionKey(k), "tau", rtTauToken(k))) {
                    .inserted => |nb| nb,
                    else => return error.TestUnexpectedResult,
                };
                _ = try writeIfChanged(io, a, cpath, wired, false);
            }
            const wired_bytes = try std.Io.Dir.cwd().readFileAlloc(io, cpath, a, .unlimited);
            // hasTauEntry goes through std.json, which can't see JSONC's
            // dangling commas — accept the textual member name there.
            if (hasTauEntry(a, k, wired_bytes)) |v| try testing.expect(v);
            try testing.expect(std.mem.indexOf(u8, wired_bytes, clientEntryName(k)) != null);

            entries.clearRetainingCapacity();
            const set = [_]ClientKind{k};
            const roc = try unwireClient(io, a, &entries, true, home, k, &set, false);
            try testing.expectEqual(RemoveOutcome.removed, roc);
            const after = try std.Io.Dir.cwd().readFileAlloc(io, cpath, a, .unlimited);
            if (std.mem.indexOfDiff(u8, orig, after)) |d| {
                std.debug.print("{s} / {s}: round-trip diverged at byte {d}\n--- want ---\n{s}\n--- got ---\n{s}\n", .{ @tagName(k), c.name, d, orig, after });
                return error.TestUnexpectedResult;
            }
            // The shared bridge file came and went with the wiring (bridge
            // clients) or was never created (direct clients).
            try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().readFileAlloc(io, try mcacpConfigPath(a, home), a, .unlimited));
        }
    }
}

test "wire then --remove edges: emptied-section husk and memberless docs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);

    // The two shapes where byte-exact restore deliberately diverges: the
    // emptied section husk is lifted with the entry (no dead "mcpServers": {}
    // is left behind), and a document gone memberless is deleted outright —
    // it only ever held tau wiring. Both section shapes get a run.
    const cases = [_]struct {
        name: []const u8,
        body: []const u8,
        /// Exact bytes left behind, or null when the file is deleted.
        leaves: ?[]const u8,
    }{
        .{ .name = "empty section husk is lifted with the entry", .body =
            \\{
            \\  "@SEC@": {},
            \\  "x": 1
            \\}
            \\
        , .leaves =
            \\{
            \\  "x": 1
            \\}
            \\
        },
        .{ .name = "file holding only the section is deleted", .body =
            \\{
            \\  "@SEC@": {}
            \\}
            \\
        , .leaves = null },
        .{ .name = "memberless document is deleted", .body = "{}", .leaves = null },
        .{ .name = "comment-only document is deleted", .body = "{ // all comments\n}", .leaves = null },
    };

    var case_n: usize = 0;
    for ([_]ClientKind{ .windsurf, .opencode }) |k| {
        for (cases) |c| {
            const home = try std.fmt.allocPrint(a, "{s}/e{d}", .{ root, case_n });
            case_n += 1;
            const cpath = (try clientSettingsPath(a, home, k)).?;
            _ = try writeIfChanged(io, a, cpath, try rtBody(a, c.body, k), false);

            var entries: std.ArrayList(u8) = .empty;
            const woc = try configureClient(io, a, &entries, true, home, k, "/abs/tau", true, false);
            try testing.expectEqual(ClientOutcome.installed, woc);

            entries.clearRetainingCapacity();
            const set = [_]ClientKind{k};
            const roc = try unwireClient(io, a, &entries, true, home, k, &set, false);
            try testing.expectEqual(RemoveOutcome.removed, roc);
            if (c.leaves) |want| {
                const after = try std.Io.Dir.cwd().readFileAlloc(io, cpath, a, .unlimited);
                try testing.expectEqualStrings(want, after);
            } else {
                try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().readFileAlloc(io, cpath, a, .unlimited));
            }
            try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().readFileAlloc(io, try mcacpConfigPath(a, home), a, .unlimited));
        }
    }
}

test "--import merged servers survive --remove; original bytes return around them" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(io, ".", a);

    // The user's windsurf file — comments, an own server, a sibling setting.
    const wpath = (try clientSettingsPath(a, home, .windsurf)).?;
    const orig =
        \\{
        \\  // keep me
        \\  "mcpServers": {
        \\    "mine": { "command": "mine", "args": ["x"] }
        \\  },
        \\  "theme": "dark"
        \\}
        \\
    ;
    _ = try writeIfChanged(io, a, wpath, orig, false);

    // Two import sources — Claude Desktop wins "fs2" only because gemini's
    // file is missing here; order is all_clients (gemini before claude).
    _ = try writeIfChanged(io, a, try std.fmt.allocPrint(a, "{s}/.config/Claude/claude_desktop_config.json", .{home}),
        \\{"mcpServers": {"fs": {"command": "npx", "args": ["-y", "fs"]}, "gh": {"command": "gh"}}}
        \\
    , false);
    _ = try writeIfChanged(io, a, try std.fmt.allocPrint(a, "{s}/.gemini/settings.json", .{home}),
        \\{"mcpServers": {"fs2": {"command": "uvx"}}}
        \\
    , false);

    var entries: std.ArrayList(u8) = .empty;
    const woc = try configureClient(io, a, &entries, true, home, .windsurf, "/abs/tau", true, false);
    try testing.expectEqual(ClientOutcome.installed, woc);

    // Expected post-remove bytes: the original document plus each merged
    // server appended in collectImportable order — the same inserts the
    // wire path made, minus the mcacp entry --remove takes back out.
    var expected: []const u8 = orig;
    const plan = try collectImportable(io, a, home, .windsurf);
    for (plan.servers.items) |srv| {
        switch (try configedit.insertNestedMember(a, expected, "mcpServers", srv.name, try renderImportToken(a, .windsurf, srv))) {
            .inserted => |nb| expected = nb,
            else => return error.TestUnexpectedResult,
        }
    }

    entries.clearRetainingCapacity();
    const set = [_]ClientKind{.windsurf};
    const roc = try unwireClient(io, a, &entries, true, home, .windsurf, &set, false);
    try testing.expectEqual(RemoveOutcome.removed, roc);

    const after = try std.Io.Dir.cwd().readFileAlloc(io, wpath, a, .unlimited);
    try testing.expectEqualStrings(expected, after);
    // Every user byte survived: comments, the own server, the merged ones.
    try testing.expect(std.mem.indexOf(u8, after, "// keep me") != null);
    try testing.expectEqual(@as(?bool, true), sectionHasEntry(a, "mcpServers", "mine", after));
    try testing.expectEqual(@as(?bool, true), sectionHasEntry(a, "mcpServers", "fs", after));
    try testing.expectEqual(@as(?bool, true), sectionHasEntry(a, "mcpServers", "fs2", after));
    // ...and tau's wiring is fully gone.
    try testing.expectEqual(@as(?bool, false), hasTauEntry(a, .windsurf, after));
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().readFileAlloc(io, try mcacpConfigPath(a, home), a, .unlimited));
}

test "setup-written file round-trips to absent for every JSONC client" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);

    // A file setup itself wrote (fresh, no user content) is deleted on
    // --remove — the HOME returns to "nothing was ever wired".
    for (all_clients, 0..) |k, i| {
        if ((try clientSettingsPath(a, root, k)) == null) continue;
        const home = try std.fmt.allocPrint(a, "{s}/f{d}", .{ root, i });
        var entries: std.ArrayList(u8) = .empty;
        const woc = try configureClient(io, a, &entries, true, home, k, "/abs/tau", false, false);
        try testing.expectEqual(ClientOutcome.installed, woc);
        const cpath = (try clientSettingsPath(a, home, k)).?;

        entries.clearRetainingCapacity();
        const set = [_]ClientKind{k};
        const roc = try unwireClient(io, a, &entries, true, home, k, &set, false);
        try testing.expectEqual(RemoveOutcome.removed, roc);
        try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().readFileAlloc(io, cpath, a, .unlimited));
        try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().readFileAlloc(io, try mcacpConfigPath(a, home), a, .unlimited));
    }
}
