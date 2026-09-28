const std = @import("std");
const bashmod = @import("bash.zig");

pub const ToolResult = bashmod.ToolResult;

/// Find files by name or pattern
pub fn find(io: std.Io, gpa: std.mem.Allocator, pattern: []const u8, path: ?[]const u8, timeout_ms: i64) !ToolResult {
    const qpath = try bashmod.shQuote(gpa, if (path) |p| p else ".");
    defer gpa.free(qpath);

    const star_pattern = try std.fmt.allocPrint(gpa, "*{s}*", .{pattern});
    defer gpa.free(star_pattern);
    const qpattern = try bashmod.shQuote(gpa, star_pattern);
    defer gpa.free(qpattern);

    const cmd = try std.fmt.allocPrint(gpa, "find -- {s} -name {s}", .{ qpath, qpattern });
    defer gpa.free(cmd);

    return bashmod.execBash(io, gpa, cmd, timeout_ms);
}

// ── Tests ───────────────────────────────────────────────────────────────────
// Run with `zig build test`. These use the real test event loop (std.testing.io)
// and a unique temp dir so they touch only throwaway files under .zig-cache/tmp.

/// Build a cwd-relative path inside the test's temp dir. Caller frees.
fn tmpPath(gpa: std.mem.Allocator, sub_path: []const u8, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/{s}", .{ sub_path, name });
}

test "find locates a file by name substring under a path" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmpPath(gpa, &tmp.sub_path, "needle-report.log");
    defer gpa.free(file);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = "x" });

    const dir = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(dir);

    const r = try find(io, gpa, "needle", dir, 5000);
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);

    try std.testing.expect(r.success);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "needle-report.log") != null);
}

test "find returns success with empty output when nothing matches" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(dir);

    // find exits 0 even with no matches; stdout is empty.
    const r = try find(io, gpa, "no-such-token-xyzzy", dir, 5000);
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);

    try std.testing.expect(r.success);
    try std.testing.expectEqualStrings("", r.stdout);
}

test "find fails on a nonexistent search path" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir = try tmpPath(gpa, &tmp.sub_path, "does-not-exist");
    defer gpa.free(dir);

    const r = try find(io, gpa, "x", dir, 5000);
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);

    try std.testing.expect(!r.success);
    try std.testing.expect(r.exit_code != 0);
}

test "find handles patterns and paths with apostrophes and spaces" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir = try tmpPath(gpa, &tmp.sub_path, "my dir's");
    defer gpa.free(dir);
    try std.Io.Dir.cwd().createDirPath(io, dir);

    const file = try std.fmt.allocPrint(gpa, "{s}/needle's log.txt", .{dir});
    defer gpa.free(file);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = "x" });

    const r = try find(io, gpa, "needle's", dir, 5000);
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);

    try std.testing.expect(r.success);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "needle's log.txt") != null);
}
