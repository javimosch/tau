// `tau upgrade` — self-update in place. Reuses the release lookup from
// update.zig (the `tau version --check` path — same TAU_UPDATE_URL /
// TAU_NO_UPDATE_CHECK contract) to decide whether a newer release exists,
// asks for confirmation (a [y/N] prompt on a TTY stdin; --yes or TAU_YES=1
// approves non-interactively), then downloads the release tag's own
// install.sh and execs it — the same fail-closed, SHA256-verified install
// path documented for fresh installs, so upgrade inherits the installer's
// checksum gating for free (plus its TAU_BASE_URL/TAU_SKIP_CHECKSUM/
// TAU_VERIFY_SIGSTORE env contract, which flows through the child env).
// TAU_INSTALL_URL overrides the installer script URL (file:// stubs in
// tests, mirrors behind proxies). The install destination resolves as
// --dir > TAU_INSTALL_DIR > the running binary's directory > the
// installer's own default. POSIX-only — Windows is told to re-run
// install.ps1 (exit 111, unimplemented).

const std = @import("std");
const builtin = @import("builtin");
const term = @import("term.zig");
const errs = @import("errors.zig");
const json = @import("json.zig");
const ver = @import("version.zig");
const update = @import("update.zig");
const cfgmod = @import("config.zig");
const Config = cfgmod.Config;

/// Outcome of a `tau upgrade` run — serialized as the "status" field.
/// Exit-code mapping: up_to_date/upgraded/declined/dry_run -> 0,
/// skipped/failed -> 1 (a script can tell "nothing was installed" apart
/// from a user decline).
pub const Status = enum {
    /// checked, already on the latest release.
    up_to_date,
    /// the installer ran and exited 0.
    upgraded,
    /// the user answered no at the TTY prompt.
    declined,
    /// the check was disabled, or a non-interactive run lacked --yes.
    skipped,
    /// the lookup, the installer download, or the install itself failed.
    failed,
    /// --dry-run: the resolved plan was reported, nothing was touched.
    dry_run,
};

/// One upgrade result — serialized as a single JSON object on stdout.
pub const Report = struct {
    checked: bool,
    latest: ?[]const u8 = null,
    tag: ?[]const u8 = null,
    update_available: bool = false,
    status: Status,
    detail: []const u8,
    release_url: ?[]const u8 = null,
    install_dir: ?[]const u8 = null,
};

/// Format the report as one JSON object. Dynamic strings (detail, paths)
/// go through json.escapeInto so the line stays valid no matter what the
/// environment holds.
pub fn formatReport(arena: std.mem.Allocator, r: Report) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(arena, "{\"name\":\"tau\",\"version\":\"");
    try buf.appendSlice(arena, ver.version);
    try buf.appendSlice(arena, "\",\"checked\":");
    try buf.appendSlice(arena, if (r.checked) "true" else "false");
    if (r.latest) |l| {
        try buf.appendSlice(arena, ",\"latest\":\"");
        try buf.appendSlice(arena, l);
        try buf.appendSlice(arena, "\"");
    }
    if (r.tag) |t| {
        try buf.appendSlice(arena, ",\"tag\":\"");
        try buf.appendSlice(arena, t);
        try buf.appendSlice(arena, "\"");
    }
    if (r.checked) {
        try buf.appendSlice(arena, ",\"update_available\":");
        try buf.appendSlice(arena, if (r.update_available) "true" else "false");
    }
    try buf.appendSlice(arena, ",\"status\":\"");
    try buf.appendSlice(arena, @tagName(r.status));
    try buf.appendSlice(arena, "\",\"detail\":\"");
    try json.escapeInto(arena, &buf, r.detail);
    try buf.appendSlice(arena, "\"");
    if (r.release_url) |u| {
        try buf.appendSlice(arena, ",\"release_url\":\"");
        try json.escapeInto(arena, &buf, u);
        try buf.appendSlice(arena, "\"");
    }
    if (r.install_dir) |d| {
        try buf.appendSlice(arena, ",\"install_dir\":\"");
        try json.escapeInto(arena, &buf, d);
        try buf.appendSlice(arena, "\"");
    }
    try buf.appendSlice(arena, "}");
    return buf.items;
}

fn emit(arena: std.mem.Allocator, r: Report) void {
    const line = formatReport(arena, r) catch return;
    term.out(line);
    term.out("\n");
}

/// Installer script URL: TAU_INSTALL_URL override, else the install.sh
/// shipped at the release tag being installed.
pub fn installerUrl(arena: std.mem.Allocator, env: *std.process.Environ.Map, tag: []const u8) ![]u8 {
    if (env.get("TAU_INSTALL_URL")) |u| {
        if (u.len > 0) return arena.dupe(u8, u);
    }
    return std.fmt.allocPrint(arena, "https://raw.githubusercontent.com/javimosch/tau/{s}/install.sh", .{tag});
}

/// Install destination: --dir flag > TAU_INSTALL_DIR env > the running
/// binary's own directory ("in place") > null, which lets the installer
/// fall back to its own default (~/.local/bin).
pub fn resolveInstallDir(io: std.Io, arena: std.mem.Allocator, cfg: Config, env: *std.process.Environ.Map) ?[]const u8 {
    if (cfg.upgrade_dir) |d| {
        if (d.len > 0) return d;
    }
    if (env.get("TAU_INSTALL_DIR")) |d| {
        if (d.len > 0) return d;
    }
    const exe = std.process.executablePathAlloc(io, arena) catch return null;
    return std.fs.path.dirname(exe);
}

/// Create a fresh $TMPDIR/tau-upgrade-<ts> staging dir; the caller removes
/// it with deleteTree. Null when no candidate name can be created.
fn stageDir(io: std.Io, arena: std.mem.Allocator, env: *std.process.Environ.Map) ?[]u8 {
    const base = env.get("TMPDIR") orelse "/tmp";
    const uniq: u64 = @intCast(@max(0, std.Io.Timestamp.now(io, .real).toNanoseconds()));
    var attempt: u64 = 0;
    while (attempt < 8) : (attempt += 1) {
        const path = std.fmt.allocPrint(arena, "{s}/tau-upgrade-{d}-{d}", .{ base, uniq, attempt }) catch return null;
        std.Io.Dir.cwd().createDirPath(io, path) catch |e| switch (e) {
            error.PathAlreadyExists => continue,
            else => return null,
        };
        return path;
    }
    return null;
}

/// Print the prompt on stderr and read one line from the (TTY) stdin
/// reader. Only an explicit y/yes approves; blank lines, EOF and read
/// errors decline — the same contract as `tau doctor --fix`.
fn confirm(r: *std.Io.Reader, prompt: []const u8) bool {
    term.err(prompt);
    const line = (r.takeDelimiter('\n') catch return false) orelse return false;
    const t = std.mem.trim(u8, line, " \t\r");
    return std.ascii.eqlIgnoreCase(t, "y") or std.ascii.eqlIgnoreCase(t, "yes");
}

/// Download the installer, stage it, run `sh install.sh --version <latest>
/// [--dir <d>]` and relay its progress to stderr so stdout stays a pure
/// JSON result. Returns the post-install Report (caller fills the release
/// fields and maps status to an exit code).
fn runInstaller(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, env: *std.process.Environ.Map, url: []const u8, latest: []const u8, dir: ?[]const u8) Report {
    const fail = struct {
        fn f(status: Status, detail: []const u8, d: ?[]const u8) Report {
            return .{ .checked = true, .status = status, .detail = detail, .install_dir = d };
        }
    }.f;

    const body = update.fetchLatest(io, gpa, arena, url) orelse
        return fail(.failed, std.fmt.allocPrint(arena, "installer download failed ({s})", .{url}) catch "installer download failed", dir);
    defer gpa.free(body);

    const tmp = stageDir(io, arena, env) orelse
        return fail(.failed, "could not create a staging dir under TMPDIR", dir);
    defer std.Io.Dir.cwd().deleteTree(io, tmp) catch {};
    const script = std.fmt.allocPrint(arena, "{s}/install.sh", .{tmp}) catch
        return fail(.failed, "out of memory staging the installer", dir);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = script, .data = body }) catch
        return fail(.failed, "could not write the staged installer", dir);

    var argv: std.ArrayList([]const u8) = .empty;
    argv.appendSlice(arena, &.{ "sh", script, "--version", latest }) catch
        return fail(.failed, "out of memory building the installer command", dir);
    if (dir) |d| argv.appendSlice(arena, &.{ "--dir", d }) catch {};

    const res = std.process.run(gpa, io, .{
        .argv = argv.items,
        .stdout_limit = .unlimited,
        .stderr_limit = .unlimited,
    }) catch return fail(.failed, "could not launch the installer (sh not on PATH?)", dir);
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);
    // The installer narrates on both streams; relay to stderr so our
    // stdout remains the single JSON result line.
    if (res.stdout.len > 0) term.err(res.stdout);
    if (res.stderr.len > 0) term.err(res.stderr);

    switch (res.term) {
        .exited => |code| {
            if (code == 0) {
                const dest = dir orelse "~/.local/bin";
                return .{
                    .checked = true,
                    .status = .upgraded,
                    .detail = std.fmt.allocPrint(arena, "installed tau {s} -> {s}/tau", .{ latest, dest }) catch "installed",
                    .install_dir = dir,
                };
            }
            return fail(.failed, std.fmt.allocPrint(arena, "installer exited {d} — see stderr for its log", .{code}) catch "installer failed", dir);
        },
        else => return fail(.failed, "installer terminated abnormally", dir),
    }
}

/// Entry point. Prints one JSON report on stdout; returns the exit code.
pub fn run(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, cfg: Config, env: *std.process.Environ.Map) !u8 {
    if (builtin.os.tag == .windows) {
        errs.printErr(arena, errs.unimplemented, "tau upgrade is unsupported on this platform; re-run install.ps1 to update", .{});
        return 111;
    }

    const res = update.check(io, gpa, arena, env);
    if (!res.checked) {
        const disabled = res.reason != null and std.mem.startsWith(u8, res.reason.?, "disabled");
        emit(arena, .{
            .checked = false,
            .status = if (disabled) .skipped else .failed,
            .detail = res.reason orelse "release lookup unavailable",
        });
        return 1;
    }
    // checked but the tag could not be compared — there is nothing safe to
    // install, so this is a failure, not "up to date".
    const latest = res.latest orelse {
        emit(arena, .{
            .checked = true,
            .status = .failed,
            .detail = res.reason orelse "release tag not comparable",
        });
        return 1;
    };
    const tag = res.tag orelse latest;
    const release_url = if (res.update_available)
        update.releaseUrl(arena, tag) catch null
    else
        null;

    if (!res.update_available) {
        emit(arena, .{
            .checked = true,
            .latest = latest,
            .tag = tag,
            .status = .up_to_date,
            .detail = std.fmt.allocPrint(arena, "tau {s} is the latest release", .{ver.version}) catch "already up to date",
        });
        return 0;
    }

    const dir = resolveInstallDir(io, arena, cfg, env);
    const url = try installerUrl(arena, env, tag);

    if (cfg.upgrade_dry_run) {
        emit(arena, .{
            .checked = true,
            .latest = latest,
            .tag = tag,
            .update_available = true,
            .status = .dry_run,
            .detail = std.fmt.allocPrint(arena, "would install tau {s} via {s} into {s}", .{ latest, url, dir orelse "the installer default (~/.local/bin)" }) catch "would install",
            .release_url = release_url,
            .install_dir = dir,
        });
        return 0;
    }

    const interactive = !cfg.upgrade_yes and (std.Io.File.stdin().isTty(io) catch false);
    var rbuf: [512]u8 = undefined;
    var fr = std.Io.File.stdin().reader(io, &rbuf);
    const approved = cfg.upgrade_yes or
        (interactive and confirm(&fr.interface, std.fmt.allocPrint(arena, "upgrade: tau {s} -> {s} — install the update? [y/N] ", .{ ver.version, latest }) catch "upgrade? [y/N] "));
    if (!approved) {
        emit(arena, .{
            .checked = true,
            .latest = latest,
            .tag = tag,
            .update_available = true,
            .status = if (interactive) .declined else .skipped,
            .detail = if (interactive) "declined at prompt" else "not confirmed — pass --yes to upgrade non-interactively",
            .release_url = release_url,
            .install_dir = dir,
        });
        return if (interactive) 0 else 1;
    }

    var rep = runInstaller(io, gpa, arena, env, url, latest, dir);
    rep.latest = latest;
    rep.tag = tag;
    rep.update_available = true;
    rep.release_url = release_url;
    emit(arena, rep);
    return switch (rep.status) {
        .upgraded => 0,
        else => 1,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
const testing = std.testing;

test "confirm: only y/yes approves; blank, other text and EOF decline" {
    var r_yes = std.Io.Reader.fixed("y\n");
    try testing.expect(confirm(&r_yes, "prompt"));
    var r_yes2 = std.Io.Reader.fixed(" YES \r\n");
    try testing.expect(confirm(&r_yes2, "prompt"));
    var r_no = std.Io.Reader.fixed("n\n");
    try testing.expect(!confirm(&r_no, "prompt"));
    var r_blank = std.Io.Reader.fixed("\n");
    try testing.expect(!confirm(&r_blank, "prompt"));
    var r_eof = std.Io.Reader.fixed("");
    try testing.expect(!confirm(&r_eof, "prompt"));
}

test "installerUrl: TAU_INSTALL_URL overrides; default tracks the tag" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();

    const def = try installerUrl(a, &env, "v9.9.9");
    try testing.expectEqualStrings("https://raw.githubusercontent.com/javimosch/tau/v9.9.9/install.sh", def);

    try env.put("TAU_INSTALL_URL", "file:///tmp/install.sh");
    try testing.expectEqualStrings("file:///tmp/install.sh", try installerUrl(a, &env, "v9.9.9"));

    try env.put("TAU_INSTALL_URL", "");
    try testing.expectEqualStrings(def, try installerUrl(a, &env, "v9.9.9"));
}

test "resolveInstallDir: flag > TAU_INSTALL_DIR > self-exe dir" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();

    var cfg = Config{};
    cfg.upgrade_dir = "/opt/bin";
    try env.put("TAU_INSTALL_DIR", "/env/bin");
    try testing.expectEqualStrings("/opt/bin", resolveInstallDir(testing.io, a, cfg, &env).?);

    cfg.upgrade_dir = null;
    try testing.expectEqualStrings("/env/bin", resolveInstallDir(testing.io, a, cfg, &env).?);

    _ = env.swapRemove("TAU_INSTALL_DIR");
    const d = resolveInstallDir(testing.io, a, cfg, &env);
    // The test runner has a real exe path with a dirname; we only pin that
    // the fallback resolves to a non-empty dir.
    try testing.expect(d != null and d.?.len > 0);
}

test "formatReport: pinned JSON shape for each outcome" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const up = try formatReport(a, .{
        .checked = true,
        .latest = "0.5.0",
        .tag = "v0.5.0",
        .update_available = true,
        .status = .upgraded,
        .detail = "installed tau 0.5.0 -> /home/u/.local/bin/tau",
        .release_url = "https://github.com/javimosch/tau/releases/tag/v0.5.0",
        .install_dir = "/home/u/.local/bin",
    });
    try testing.expectEqualStrings("{\"name\":\"tau\",\"version\":\"0.4.0\",\"checked\":true,\"latest\":\"0.5.0\",\"tag\":\"v0.5.0\",\"update_available\":true,\"status\":\"upgraded\",\"detail\":\"installed tau 0.5.0 -> /home/u/.local/bin/tau\",\"release_url\":\"https://github.com/javimosch/tau/releases/tag/v0.5.0\",\"install_dir\":\"/home/u/.local/bin\"}", up);

    const cur = try formatReport(a, .{
        .checked = true,
        .latest = "0.4.0",
        .tag = "v0.4.0",
        .status = .up_to_date,
        .detail = "tau 0.4.0 is the latest release",
    });
    try testing.expectEqualStrings("{\"name\":\"tau\",\"version\":\"0.4.0\",\"checked\":true,\"latest\":\"0.4.0\",\"tag\":\"v0.4.0\",\"update_available\":false,\"status\":\"up_to_date\",\"detail\":\"tau 0.4.0 is the latest release\"}", cur);

    const off = try formatReport(a, .{
        .checked = false,
        .status = .skipped,
        .detail = "disabled (TAU_NO_UPDATE_CHECK)",
    });
    try testing.expectEqualStrings("{\"name\":\"tau\",\"version\":\"0.4.0\",\"checked\":false,\"status\":\"skipped\",\"detail\":\"disabled (TAU_NO_UPDATE_CHECK)\"}", off);

    // detail strings with quotes/backslashes/newlines stay valid JSON.
    const esc = try formatReport(a, .{
        .checked = false,
        .status = .failed,
        .detail = "path \"c:\\dir\" not found\n",
    });
    try testing.expect(std.mem.indexOf(u8, esc, "\\\"c:\\\\dir\\\"") != null);
    try testing.expect(std.mem.indexOf(u8, esc, "not found\\n") != null);
}
