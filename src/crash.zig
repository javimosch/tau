//! Crash/panic diagnostic bundle.
//!
//! main.zig installs `panicHandler` as the process panic handler
//! (`pub const panic = std.debug.FullPanic(crash.panicHandler)`), so any
//! panic — a failed safety check, an `unreachable`, or a segfault routed
//! through the segfault handler — first writes a redacted diagnostic bundle
//! to `<HOME>/.config/tau/crashes/crash-<UTC>-<rand>.log` and prints a
//! stderr note pointing the user at `tau bug` for one-command reporting,
//! then defers to `std.debug.defaultPanic` so the stack trace and abort
//! exit status are unchanged.
//!
//! The bundle carries build metadata, the UTC crash time, the (redacted)
//! argv line, the active --debug log path when one is open, and the panic
//! message. Everything passes through `debuglog.redactRegistered`, so
//! configured keys, Bearer tokens, and `NAME=value` credentials are masked
//! before they hit disk — the file is safe to attach to a bug report.
//!
//! `tau doctor --report` attaches the newest bundle via `latestPath()`,
//! which `tau bug` inherits because it embeds that same report — a crash is
//! one command away from a complete bug report.
//!
//! Everything on the panic path is best-effort: allocation uses the page
//! allocator (the runtime heap may be the thing that crashed), every step
//! degrades silently on failure, and a recursion guard falls straight
//! through to the default handler if bundle writing itself panics. When
//! `init()` never ran — unit tests, or a panic before main's first lines —
//! the handler is a pass-through: no env or argv was stashed, so nothing is
//! written and only the default trace prints.

const std = @import("std");
const term = @import("term.zig");
const debuglog = @import("debuglog.zig");
const version_mod = @import("version.zig");

var g_io: ?std.Io = null;
var g_env: ?*std.process.Environ.Map = null;
var g_argv: []const u8 = "";
var g_panicking = std.atomic.Value(bool).init(false);

/// Record the runtime handles the panic handler needs. Called once, early
/// in main(); skipping it (tests) degrades the handler to a pass-through.
/// `args` is joined into a single argv line, arena-allocated for the life
/// of the process and redacted at bundle-write time.
pub fn init(io: std.Io, arena: std.mem.Allocator, env: *std.process.Environ.Map, args: std.process.Args) void {
    g_io = io;
    g_env = env;
    var buf: std.ArrayList(u8) = .empty;
    var it = std.process.Args.Iterator.initAllocator(args, arena) catch return;
    defer it.deinit();
    while (it.next()) |arg| {
        if (buf.items.len > 0) buf.append(arena, ' ') catch return;
        buf.appendSlice(arena, arg) catch return;
    }
    g_argv = buf.items;
}

/// `<HOME>/.config/tau/crashes` (sibling of sessions/ and debug/). null
/// when HOME is unset.
pub fn dirPath(a: std.mem.Allocator, env: *std.process.Environ.Map) ?[]u8 {
    const home = env.get("HOME") orelse return null;
    return std.fmt.allocPrint(a, "{s}/.config/tau/crashes", .{home}) catch null;
}

/// `YYYY-MM-DDTHH-MM-SSZ` UTC stamp, filename-safe (no colons). Mirrors
/// debuglog.formatIso — kept private here so the crash path stays
/// self-contained.
fn utcStamp(a: std.mem.Allocator, epoch_secs: u64) ?[]u8 {
    const es = std.time.epoch.EpochSeconds{ .secs = epoch_secs };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.allocPrint(a, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}-{d:0>2}-{d:0>2}Z", .{
        yd.year,                md.month.numeric(),       md.day_index + 1,
        ds.getHoursIntoDay(),   ds.getMinutesIntoHour(),  ds.getSecondsIntoMinute(),
    }) catch null;
}

/// `crash-2026-10-28T14-30-00Z-004201337.log` — UTC stamp + zero-padded
/// sub-second nanoseconds so filenames never collide and lexicographic
/// order is chronological (latestPath relies on it).
fn fileName(a: std.mem.Allocator, epoch_secs: u64, subsec_nanos: u64) ?[]u8 {
    const stamp = utcStamp(a, epoch_secs) orelse return null;
    defer a.free(stamp);
    return std.fmt.allocPrint(a, "crash-{s}-{d:0>9}.log", .{ stamp, subsec_nanos }) catch null;
}

/// The newest crash bundle path under dirPath(), or null when the dir is
/// absent/empty/unreadable. Filenames sort chronologically, so the largest
/// `crash-*.log` name wins.
pub fn latestPath(io: std.Io, a: std.mem.Allocator, env: *std.process.Environ.Map) ?[]u8 {
    const dir_path = dirPath(a, env) orelse return null;
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var it = dir.iterate();
    var best: ?[]const u8 = null;
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, "crash-") or !std.mem.endsWith(u8, entry.name, ".log")) continue;
        if (best == null or std.mem.lessThan(u8, best.?, entry.name)) {
            best = a.dupe(u8, entry.name) catch return null;
        }
    }
    const name = best orelse return null;
    return std.fmt.allocPrint(a, "{s}/{s}", .{ dir_path, name }) catch null;
}

fn headerLine(a: std.mem.Allocator, buf: *std.ArrayList(u8), key: []const u8, value: []const u8) void {
    const line = std.fmt.allocPrint(a, "# {s}: {s}\n", .{ key, value }) catch return;
    defer a.free(line);
    buf.appendSlice(a, line) catch {};
}

/// Compose the bundle text: provenance header plus the panic message, then
/// a redaction pass over the whole thing. Caller owns the result.
pub fn formatBundle(a: std.mem.Allocator, msg: []const u8, argv_line: []const u8, epoch_secs: u64) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try buf.appendSlice(a, "# tau crash bundle — credentials are masked; attach to a bug report (`tau bug`)\n");
    headerLine(a, &buf, "version", version_mod.version);
    const build_line: ?[]u8 = version_mod.buildLine(a) catch null;
    defer if (build_line) |s| a.free(s);
    headerLine(a, &buf, "build", build_line orelse "unknown");
    const stamp: ?[]u8 = utcStamp(a, epoch_secs);
    defer if (stamp) |s| a.free(s);
    headerLine(a, &buf, "crashed_utc", stamp orelse "unknown");
    headerLine(a, &buf, "argv", if (argv_line.len > 0) argv_line else "-");
    headerLine(a, &buf, "debug_log", debuglog.path() orelse "-");
    try buf.appendSlice(a, "# ---\npanic: ");
    try buf.appendSlice(a, msg);
    try buf.append(a, '\n');
    return debuglog.redactRegistered(a, buf.items);
}

/// Write the bundle under dirPath() with owner-only permissions. Returns
/// the path on success, null on any failure — the panic path must never
/// throw. `a` should be an allocator the caller trusts post-crash (the
/// handler passes the page allocator, not the runtime heap).
pub fn writeBundle(io: std.Io, a: std.mem.Allocator, env: *std.process.Environ.Map, argv_line: []const u8, msg: []const u8) ?[]u8 {
    const dir = dirPath(a, env) orelse return null;
    const now = std.Io.Timestamp.now(io, .real);
    const secs: u64 = @intCast(@max(now.toSeconds(), 0));
    const subsec: u64 = @intCast(@mod(now.nanoseconds, std.time.ns_per_s));
    const name = fileName(a, secs, subsec) orelse return null;
    const path = std.fmt.allocPrint(a, "{s}/{s}", .{ dir, name }) catch return null;
    const body = formatBundle(a, msg, argv_line, secs) catch return null;

    std.Io.Dir.cwd().createDirPath(io, dir) catch return null;
    // Owner-only: redacted, but still carries argv and endpoint details.
    // Permissions are POSIX-only; elsewhere .default_file applies.
    const opts: std.Io.Dir.CreateFileOptions = if (@hasDecl(std.Io.File.Permissions, "fromMode"))
        .{ .permissions = .fromMode(0o600) }
    else
        .{};
    const f = std.Io.Dir.cwd().createFile(io, path, opts) catch return null;
    defer f.close(io);
    f.writeStreamingAll(io, body) catch return null;
    return path;
}

/// Process panic handler (see module doc). Writes the bundle, prints the
/// `tau bug` pointer to stderr, then hands off to the default handler so
/// the trace + abort are unchanged.
pub fn panicHandler(msg: []const u8, first_trace_addr: ?usize) noreturn {
    @branchHint(.cold);
    // One shot at the bundle: a second panic inside the crash path (or a
    // crash before init()) falls straight through to the default handler.
    if (!g_panicking.swap(true, .seq_cst)) {
        if (g_io) |io| {
            if (g_env) |env| {
                if (writeBundle(io, std.heap.page_allocator, env, g_argv, msg)) |p| {
                    var buf: [1024]u8 = undefined;
                    const note = std.fmt.bufPrint(&buf, "note: tau crashed - redacted diagnostic bundle written to {s}\nnote: run `tau bug` to file a report - the newest bundle is attached automatically\n", .{p}) catch "";
                    term.err(note);
                } else {
                    term.err("note: tau crashed - run `tau bug` to file a report\n");
                }
            }
        }
    }
    std.debug.defaultPanic(msg, first_trace_addr);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
const testing = std.testing;

const TestHome = struct {
    tmp: testing.TmpDir,
    env: std.process.Environ.Map,
    home: []const u8,

    fn init(arena: std.mem.Allocator) !TestHome {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const home = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
        try std.Io.Dir.cwd().createDirPath(testing.io, home);
        var env = std.process.Environ.Map.init(arena);
        try env.put("HOME", home);
        return .{ .tmp = tmp, .env = env, .home = home };
    }

    fn deinit(self: *TestHome) void {
        self.tmp.cleanup();
    }
};

test "dirPath: builds the crashes dir, null without HOME" {
    const a = testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", "/tmp/h");
    const p = dirPath(a, &env).?;
    defer a.free(p);
    try testing.expectEqualStrings("/tmp/h/.config/tau/crashes", p);

    var empty = std.process.Environ.Map.init(a);
    defer empty.deinit();
    try testing.expect(dirPath(a, &empty) == null);
}

test "formatBundle: carries diagnostics and masks registered secrets" {
    const a = testing.allocator;
    debuglog.addSecretsForTest(&.{"k-crashsecret-999"});
    defer debuglog.clearSecretsForTest();

    const body = try formatBundle(a, "index out of bounds: index 5, len 2", "tau --api-key k-crashsecret-999 hi", 1_700_000_000);
    defer a.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "panic: index out of bounds: index 5, len 2") != null);
    try testing.expect(std.mem.indexOf(u8, body, "# version: ") != null);
    try testing.expect(std.mem.indexOf(u8, body, "# crashed_utc: 2023-11-14") != null);
    try testing.expect(std.mem.indexOf(u8, body, "# argv: tau --api-key ") != null);
    try testing.expect(std.mem.indexOf(u8, body, "k-crashsecret-999") == null);
    try testing.expect(std.mem.indexOf(u8, body, debuglog.mask) != null);
}

test "writeBundle + latestPath: writes a redacted bundle picked up as newest" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var home = try TestHome.init(a);
    defer home.deinit();

    debuglog.addSecretsForTest(&.{"k-crashsecret-999"});
    defer debuglog.clearSecretsForTest();

    const p1 = writeBundle(testing.io, a, &home.env, "tau hi", "first crash").?;
    const p2 = writeBundle(testing.io, a, &home.env, "tau --api-key k-crashsecret-999 hi", "second crash").?;

    // latestPath resolves the newest crash-*.log in the same dir.
    const latest = latestPath(testing.io, a, &home.env).?;
    try testing.expectEqualStrings(p2, latest);

    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, p2, a, .unlimited);
    try testing.expect(std.mem.indexOf(u8, bytes, "panic: second crash") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "k-crashsecret-999") == null);
    try testing.expect(std.mem.indexOf(u8, bytes, debuglog.mask) != null);

    // Older bundle still on disk; non-crash files are ignored by latestPath.
    try std.Io.Dir.cwd().writeFile(testing.io, .{
        .sub_path = try std.fmt.allocPrint(a, "{s}/not-a-crash.log", .{dirPath(a, &home.env).?}),
        .data = "x",
    });
    const again = latestPath(testing.io, a, &home.env).?;
    try testing.expectEqualStrings(p2, again);
    _ = p1;
}

test "latestPath: null when the crashes dir does not exist" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var home = try TestHome.init(a);
    defer home.deinit();
    try testing.expect(latestPath(testing.io, a, &home.env) == null);
}
