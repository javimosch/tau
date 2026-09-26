const std = @import("std");
const bashmod = @import("bash.zig");

pub const ToolResult = bashmod.ToolResult;

/// List files in a directory (or current directory if path is null)
pub fn ls(io: std.Io, gpa: std.mem.Allocator, path: ?[]const u8, timeout_ms: i64) !ToolResult {
    const quoted = if (path) |p| try bashmod.shQuote(gpa, p) else null;
    defer if (quoted) |q| gpa.free(q);

    const cmd = if (quoted) |q|
        try std.fmt.allocPrint(gpa, "ls -la -- {s}", .{q})
    else
        try std.fmt.allocPrint(gpa, "ls -la", .{});
    defer gpa.free(cmd);

    return bashmod.execBash(io, gpa, cmd, timeout_ms);
}

// ── Tests ───────────────────────────────────────────────────────────────────

fn tmpPath(gpa: std.mem.Allocator, sub_path: []const u8, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/{s}", .{ sub_path, name });
}

test "ls lists the contents of a directory" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmpPath(gpa, &tmp.sub_path, "marker.txt");
    defer gpa.free(file);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = "x" });

    const dir = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(dir);

    const r = try ls(io, gpa, dir, 5000);
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);

    try std.testing.expect(r.success);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "marker.txt") != null);
}

test "ls with a null path lists the current directory" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    const r = try ls(io, gpa, null, 5000);
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);

    try std.testing.expect(r.success);
    try std.testing.expect(r.stdout.len > 0);
}

test "ls fails on a nonexistent path" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir = try tmpPath(gpa, &tmp.sub_path, "does-not-exist");
    defer gpa.free(dir);

    const r = try ls(io, gpa, dir, 5000);
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);

    try std.testing.expect(!r.success);
    try std.testing.expect(r.exit_code != 0);
}

test "ls handles paths with spaces and apostrophes" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir = try tmpPath(gpa, &tmp.sub_path, "my dir's");
    defer gpa.free(dir);
    try std.Io.Dir.cwd().createDirPath(io, dir);

    const file = try std.fmt.allocPrint(gpa, "{s}/marker.txt", .{dir});
    defer gpa.free(file);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = "x" });

    const r = try ls(io, gpa, dir, 5000);
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);

    try std.testing.expect(r.success);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "marker.txt") != null);
}
