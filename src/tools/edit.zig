const std = @import("std");
const bashmod = @import("bash.zig");

pub const ToolResult = bashmod.ToolResult;

/// Edit a file by replacing old_string with new_string (sed-based)
pub fn editFile(io: std.Io, gpa: std.mem.Allocator, path: []const u8, old_string: []const u8, new_string: []const u8, timeout_ms: i64) !ToolResult {
    // Escape special characters for sed
    const old_escaped = try escapeForSed(gpa, old_string);
    defer gpa.free(old_escaped);

    const new_escaped = try escapeForSed(gpa, new_string);
    defer gpa.free(new_escaped);

    const cmd = try std.fmt.allocPrint(gpa, "sed -i 's/{s}/{s}/g' {s}", .{ old_escaped, new_escaped, path });

    defer gpa.free(cmd);
    return bashmod.execBash(io, gpa, cmd, timeout_ms);
}

/// Escape special characters for sed pattern
fn escapeForSed(gpa: std.mem.Allocator, input: []const u8) ![]const u8 {
    var result = std.ArrayList(u8).empty;
    defer result.deinit(gpa);

    for (input) |c| {
        switch (c) {
            '\\', '/', '[', ']', '.', '*', '^', '$', '&', '|', '{', '}', '?', '+', '(', ')' => {
                try result.append(gpa, '\\');
                try result.append(gpa, c);
            },
            '\n' => {
                try result.appendSlice(gpa, "\\n");
            },
            else => {
                try result.append(gpa, c);
            },
        }
    }

    return result.toOwnedSlice(gpa);
}

// ── Tests ───────────────────────────────────────────────────────────────────
// Run with `zig build test`. These use the real test event loop (std.testing.io)
// and a unique temp dir so they touch only throwaway files under .zig-cache/tmp.

/// Build a cwd-relative path inside the test's temp dir. Caller frees.
fn tmpPath(gpa: std.mem.Allocator, sub_path: []const u8, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/{s}", .{ sub_path, name });
}

test "editFile replaces every occurrence of old_string" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tmpPath(gpa, &tmp.sub_path, "edit.txt");
    defer gpa.free(path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "foo bar foo\n" });

    const r = try editFile(io, gpa, path, "foo", "baz", 5000);
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);

    try std.testing.expect(r.success);
    try std.testing.expectEqual(@as(u8, 0), r.exit_code);

    const got = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(got);
    try std.testing.expectEqualStrings("baz bar baz\n", got);
}

test "editFile treats regex metacharacters in old_string literally" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tmpPath(gpa, &tmp.sub_path, "regex.txt");
    defer gpa.free(path);
    // "a.c" must match only the literal dotted token, NOT "abc" — this exercises
    // escapeForSed. Without escaping, sed's '.' would match the 'b' too.
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "a.c and abc\n" });

    const r = try editFile(io, gpa, path, "a.c", "X", 5000);
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);

    try std.testing.expect(r.success);
    const got = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(got);
    try std.testing.expectEqualStrings("X and abc\n", got);
}

test "editFile fails on a nonexistent file" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tmpPath(gpa, &tmp.sub_path, "missing.txt");
    defer gpa.free(path);

    const r = try editFile(io, gpa, path, "foo", "bar", 5000);
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);

    try std.testing.expect(!r.success);
    try std.testing.expect(r.exit_code != 0);
}

test "escapeForSed escapes special characters and newlines" {
    const gpa = std.testing.allocator;

    const out = try escapeForSed(gpa, "a.b/[c]\n");
    defer gpa.free(out);
    try std.testing.expectEqualStrings("a\\.b\\/\\[c\\]\\n", out);
}
