//! Portable stdout/stderr byte output.
//!
//! Replaces the Linux-only `std.os.linux.write(fd, ptr, len)` syscalls used
//! throughout tau so the binary builds and runs correctly on Linux, macOS and
//! Windows (the raw linux syscall numbers are wrong on macOS and the namespace
//! does not even compile on Windows). The process-wide `std.Io` is recorded
//! once at startup via `init()`; writes are best-effort (errors ignored), which
//! matches the previous fire-and-forget `write()` behavior.
const std = @import("std");

var g_io: ?std.Io = null;

/// Record the process-wide std.Io used for stdout/stderr writes. Call once,
/// early in main(), before any out()/err().
pub fn init(io: std.Io) void {
    g_io = io;
}

/// Write all of `bytes` to stdout. Best-effort: a null io (init not called) or
/// a write error is silently dropped.
pub fn out(bytes: []const u8) void {
    const io = g_io orelse return;
    std.Io.File.stdout().writeStreamingAll(io, bytes) catch {};
}

/// Write all of `bytes` to stderr. Best-effort.
pub fn err(bytes: []const u8) void {
    const io = g_io orelse return;
    std.Io.File.stderr().writeStreamingAll(io, bytes) catch {};
}

/// ANSI styling policy — the single decision point for whether tau may emit
/// SGR escape sequences on a stream. tau is an agent-first CLI: machine-
/// consumed channels (stdout JSON/NDJSON, --mode text, ACP stdio) are never
/// styled. Interactive, human-facing diagnostics consult this helper before
/// decorating so NO_COLOR, CLICOLOR=0, TERM=dumb and non-TTY streams all
/// stay byte-clean.
///
/// Precedence, first match wins (no-color.org + the CLICOLOR convention):
///   1. CLICOLOR_FORCE present, non-empty, not "0" → styled (even non-TTY)
///   2. NO_COLOR present and non-empty             → plain
///   3. CLICOLOR == "0"                             → plain
///   4. TERM == "dumb"                              → plain
///   5. otherwise                                   → file.isTty(io)
pub fn colorEnabled(io: std.Io, env: *const std.process.Environ.Map, file: std.Io.File) bool {
    return colorPolicy(env, file.isTty(io) catch false);
}

/// Pure core of colorEnabled — the TTY probe is injected so unit tests do
/// not need a real terminal.
pub fn colorPolicy(env: *const std.process.Environ.Map, is_tty: bool) bool {
    if (env.get("CLICOLOR_FORCE")) |v| {
        if (v.len != 0 and !std.mem.eql(u8, v, "0")) return true;
    }
    if (env.get("NO_COLOR")) |v| {
        if (v.len != 0) return false;
    }
    if (env.get("CLICOLOR")) |v| {
        if (std.mem.eql(u8, v, "0")) return false;
    }
    if (env.get("TERM")) |v| {
        if (std.mem.eql(u8, v, "dumb")) return false;
    }
    return is_tty;
}

/// Wrap `bytes` in an SGR `sgr` escape pair (e.g. "1" for bold) when
/// `enabled`; returns `bytes` unchanged otherwise so the plain path never
/// allocates. Callers gate `enabled` through colorEnabled.
pub fn sgrWrap(a: std.mem.Allocator, bytes: []const u8, sgr: []const u8, enabled: bool) ![]const u8 {
    if (!enabled) return bytes;
    return std.fmt.allocPrint(a, "\x1b[{s}m{s}\x1b[0m", .{ sgr, bytes });
}

// ── Tests ─────────────────────────────────────────────────────────────────

test "colorPolicy: precedence of force, NO_COLOR, CLICOLOR, TERM=dumb, TTY" {
    const testing = std.testing;
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();

    // Baseline: styling follows the TTY probe.
    try testing.expect(colorPolicy(&env, true));
    try testing.expect(!colorPolicy(&env, false));

    // TERM=dumb disables on a TTY.
    try env.put("TERM", "dumb");
    try testing.expect(!colorPolicy(&env, true));
    try env.put("TERM", "xterm-256color");
    try testing.expect(colorPolicy(&env, true));

    // CLICOLOR=0 disables on a TTY; other values defer to the probe.
    try env.put("CLICOLOR", "0");
    try testing.expect(!colorPolicy(&env, true));
    try env.put("CLICOLOR", "1");
    try testing.expect(colorPolicy(&env, true));

    // NO_COLOR (non-empty) disables on a TTY.
    try env.put("NO_COLOR", "1");
    try testing.expect(!colorPolicy(&env, true));
    // An empty NO_COLOR does not count (no-color.org).
    try env.put("NO_COLOR", "");
    try testing.expect(colorPolicy(&env, true));
    try env.put("NO_COLOR", "1");

    // CLICOLOR_FORCE forces styling even when piped and overrides NO_COLOR.
    try env.put("CLICOLOR_FORCE", "1");
    try testing.expect(colorPolicy(&env, false));
    try testing.expect(colorPolicy(&env, true));
    // CLICOLOR_FORCE=0 / empty is not a force.
    try env.put("CLICOLOR_FORCE", "0");
    try testing.expect(!colorPolicy(&env, true));
    try env.put("CLICOLOR_FORCE", "");
    try testing.expect(!colorPolicy(&env, true));
}

test "sgrWrap: wraps only when enabled, plain path returns input unchanged" {
    const testing = std.testing;
    const wrapped = try sgrWrap(testing.allocator, "prompt", "1", true);
    defer testing.allocator.free(wrapped);
    try testing.expectEqualStrings("\x1b[1mprompt\x1b[0m", wrapped);
    try testing.expectEqualStrings("prompt", try sgrWrap(testing.allocator, "prompt", "1", false));
}
