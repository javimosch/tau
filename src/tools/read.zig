const std = @import("std");
const bashmod = @import("bash.zig");

pub const ToolResult = bashmod.ToolResult;

/// Read a file and return its contents
pub fn readFile(io: std.Io, gpa: std.mem.Allocator, path: []const u8, timeout_ms: i64) !ToolResult {
    const cmd = try std.fmt.allocPrint(gpa, "cat {s}", .{path});

    defer gpa.free(cmd);
    return bashmod.execBash(io, gpa, cmd, timeout_ms);
}

// ── Tests ───────────────────────────────────────────────────────────────────

fn tmpPath(gpa: std.mem.Allocator, sub_path: []const u8, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/{s}", .{ sub_path, name });
}

test "readFile returns the file contents on success" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tmpPath(gpa, &tmp.sub_path, "data.txt");
    defer gpa.free(path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "line one\nline two\n" });

    const r = try readFile(io, gpa, path, 5000);
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);

    try std.testing.expect(r.success);
    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expectEqualStrings("line one\nline two\n", r.stdout);
}

test "readFile fails for a nonexistent file" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tmpPath(gpa, &tmp.sub_path, "missing.txt");
    defer gpa.free(path);

    const r = try readFile(io, gpa, path, 5000);
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);

    try std.testing.expect(!r.success);
    try std.testing.expect(r.exit_code != 0);
    try std.testing.expectEqualStrings("", r.stdout);
}
