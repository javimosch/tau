const std = @import("std");
const bashmod = @import("bash.zig");

pub const ToolResult = bashmod.ToolResult;

/// Search for a pattern in files using grep
pub fn grep(io: std.Io, gpa: std.mem.Allocator, pattern: []const u8, path: ?[]const u8, timeout_ms: i64) !ToolResult {
    const qpattern = try bashmod.shQuote(gpa, pattern);
    defer gpa.free(qpattern);

    const qpath = if (path) |p| try bashmod.shQuote(gpa, p) else null;
    defer if (qpath) |q| gpa.free(q);

    const cmd = if (qpath) |q|
        try std.fmt.allocPrint(gpa, "grep -r -e {s} -- {s}", .{ qpattern, q })
    else
        try std.fmt.allocPrint(gpa, "grep -r -e {s}", .{qpattern});
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

test "grep finds a matching line and reports it" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmpPath(gpa, &tmp.sub_path, "haystack.txt");
    defer gpa.free(file);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = "alpha\nbeta needle gamma\ndelta\n" });

    const dir = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(dir);

    const r = try grep(io, gpa, "needle", dir, 5000);
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);

    try std.testing.expect(r.success);
    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "beta needle gamma") != null);
}

test "grep reports no match with a nonzero exit code" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmpPath(gpa, &tmp.sub_path, "haystack.txt");
    defer gpa.free(file);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = "alpha\nbeta\n" });

    const dir = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(dir);

    // grep exits 1 when no line matches.
    const r = try grep(io, gpa, "no-such-token-xyzzy", dir, 5000);
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);

    try std.testing.expect(!r.success);
    try std.testing.expectEqual(@as(u8, 1), r.exit_code);
    try std.testing.expectEqualStrings("", r.stdout);
}

test "grep fails on a nonexistent search path" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir = try tmpPath(gpa, &tmp.sub_path, "does-not-exist");
    defer gpa.free(dir);

    const r = try grep(io, gpa, "x", dir, 5000);
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);

    try std.testing.expect(!r.success);
    try std.testing.expect(r.exit_code != 0);
}

test "grep handles patterns and paths with apostrophes and spaces" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir = try tmpPath(gpa, &tmp.sub_path, "my dir's");
    defer gpa.free(dir);
    try std.Io.Dir.cwd().createDirPath(io, dir);

    const file = try std.fmt.allocPrint(gpa, "{s}/haystack.txt", .{dir});
    defer gpa.free(file);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = "it's a needle\n" });

    const r = try grep(io, gpa, "it's", dir, 5000);
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);

    try std.testing.expect(r.success);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "it's a needle") != null);
}
