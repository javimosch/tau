const std = @import("std");
const bashmod = @import("bash.zig");

pub const ToolResult = bashmod.ToolResult;

/// Write content to a file (overwrites if exists), creating parent directories.
/// Writes via the Io filesystem API directly — NOT through a shell — so any
/// content (apostrophes, quotes, %, backslashes, newlines) is written verbatim.
/// The old `printf '%s' '<content>' > path` form corrupted code (single-quote
/// breakage) and could not create nested directories.
pub fn writeFile(io: std.Io, gpa: std.mem.Allocator, path: []const u8, content: []const u8, timeout_ms: i64) !ToolResult {
    _ = timeout_ms;
    if (std.fs.path.dirname(path)) |dir| {
        if (dir.len > 0) std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    }
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = content }) catch |err| {
        const msg = std.fmt.allocPrint(gpa, "write failed ({s}): {s}", .{ @errorName(err), path }) catch "write failed";
        return ToolResult{ .success = false, .stdout = "", .stderr = msg, .exit_code = 1 };
    };
    const ok = std.fmt.allocPrint(gpa, "wrote {d} bytes to {s}", .{ content.len, path }) catch "ok";
    return ToolResult{ .success = true, .stdout = ok, .stderr = "", .exit_code = 0 };
}

// ── Tests ───────────────────────────────────────────────────────────────────
// Run with `zig build test`. These use the real test event loop (std.testing.io)
// and a unique temp dir so they touch only throwaway files under .zig-cache/tmp.

/// Build a cwd-relative path inside the test's temp dir. Caller frees.
fn tmpPath(gpa: std.mem.Allocator, sub_path: []const u8, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/{s}", .{ sub_path, name });
}

test "writeFile writes content and reports the byte count" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tmpPath(gpa, &tmp.sub_path, "out.txt");
    defer gpa.free(path);

    const r = try writeFile(io, gpa, path, "hello world", 5000);
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);

    try std.testing.expect(r.success);
    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "11 bytes") != null);

    const got = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(got);
    try std.testing.expectEqualStrings("hello world", got);
}

test "writeFile creates missing parent directories" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tmpPath(gpa, &tmp.sub_path, "a/b/c/deep.txt");
    defer gpa.free(path);

    const r = try writeFile(io, gpa, path, "nested", 5000);
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);

    try std.testing.expect(r.success);
    const got = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(got);
    try std.testing.expectEqualStrings("nested", got);
}

test "writeFile preserves shell-special characters verbatim" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tmpPath(gpa, &tmp.sub_path, "verbatim.txt");
    defer gpa.free(path);

    // Apostrophes, quotes, %, backslash and newlines must survive untouched —
    // the whole reason writeFile bypasses the shell.
    const content = "it's a \"test\" with 100% \\backslash\nand a newline";
    const r = try writeFile(io, gpa, path, content, 5000);
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);

    try std.testing.expect(r.success);
    const got = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(got);
    try std.testing.expectEqualStrings(content, got);
}

test "writeFile fails when a path component is an existing file" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const blocker = try tmpPath(gpa, &tmp.sub_path, "blocker");
    defer gpa.free(blocker);
    const ok = try writeFile(io, gpa, blocker, "i am a file", 5000);
    defer gpa.free(ok.stdout);
    defer gpa.free(ok.stderr);
    try std.testing.expect(ok.success);

    // "blocker" is a regular file, so writing "blocker/child.txt" cannot succeed.
    const bad = try tmpPath(gpa, &tmp.sub_path, "blocker/child.txt");
    defer gpa.free(bad);
    const r = try writeFile(io, gpa, bad, "nope", 5000);
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);

    try std.testing.expect(!r.success);
    try std.testing.expectEqual(@as(u8, 1), r.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "write failed") != null);
}
