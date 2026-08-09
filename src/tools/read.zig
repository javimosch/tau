const std = @import("std");
const bashmod = @import("bash.zig");

pub const ToolResult = bashmod.ToolResult;

/// Read a file and return its contents.
/// Uses the Io filesystem API directly (not a shell) so paths containing
/// spaces, quotes, or other shell-special characters are read correctly.
pub fn readFile(io: std.Io, gpa: std.mem.Allocator, path: []const u8, timeout_ms: i64) !ToolResult {
    _ = timeout_ms;
    const content = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch |err| {
        const msg = std.fmt.allocPrint(gpa, "read failed ({s}): {s}", .{ @errorName(err), path }) catch "read failed";
        return ToolResult{ .success = false, .stdout = "", .stderr = msg, .exit_code = 1 };
    };
    return ToolResult{ .success = true, .stdout = content, .stderr = "", .exit_code = 0 };
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

test "readFile handles paths with shell-special characters" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const name = "file \"with\" spaces.txt";
    const path = try tmpPath(gpa, &tmp.sub_path, name);
    defer gpa.free(path);
    const content = "it's a \"test\" with 100% \\backslash\n";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = content });

    const r = try readFile(io, gpa, path, 5000);
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);

    try std.testing.expect(r.success);
    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expectEqualStrings(content, r.stdout);
}
