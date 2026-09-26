const std = @import("std");
const bashmod = @import("bash.zig");

pub const ToolResult = bashmod.ToolResult;

/// Edit a file by replacing every occurrence of old_string with new_string.
/// Performs a literal byte-for-byte replacement through the Io filesystem API,
/// so any content (apostrophes, quotes, regex metacharacters, backslashes,
/// newlines) is treated literally and written verbatim.
pub fn editFile(io: std.Io, gpa: std.mem.Allocator, path: []const u8, old_string: []const u8, new_string: []const u8, timeout_ms: i64) !ToolResult {
    _ = timeout_ms;

    if (old_string.len == 0) {
        const m = try std.fmt.allocPrint(gpa, "edit: old_string cannot be empty", .{});
        return ToolResult{ .success = false, .stdout = "", .stderr = m, .exit_code = 1 };
    }

    const data = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch |err| {
        const m = try std.fmt.allocPrint(gpa, "edit failed ({s}): {s}", .{ @errorName(err), path });
        return ToolResult{ .success = false, .stdout = "", .stderr = m, .exit_code = 1 };
    };
    defer gpa.free(data);

    const count = std.mem.count(u8, data, old_string);
    var out_len = data.len;
    if (new_string.len > old_string.len) {
        out_len += count * (new_string.len - old_string.len);
    } else if (old_string.len > new_string.len) {
        out_len -= count * (old_string.len - new_string.len);
    }

    const out = try gpa.alloc(u8, out_len);
    errdefer gpa.free(out);
    _ = std.mem.replace(u8, data, old_string, new_string, out);

    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out }) catch |err| {
        const m = try std.fmt.allocPrint(gpa, "edit failed ({s}): {s}", .{ @errorName(err), path });
        return ToolResult{ .success = false, .stdout = "", .stderr = m, .exit_code = 1 };
    };
    gpa.free(out);

    const ok = try std.fmt.allocPrint(gpa, "replaced {d} occurrence(s) in {s}", .{ count, path });
    return ToolResult{ .success = true, .stdout = ok, .stderr = "", .exit_code = 0 };
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
    // "a.c" must match only the literal dotted token, NOT "abc".
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "a.c and abc\n" });

    const r = try editFile(io, gpa, path, "a.c", "X", 5000);
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);

    try std.testing.expect(r.success);
    const got = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(got);
    try std.testing.expectEqualStrings("X and abc\n", got);
}

test "editFile handles BRE metacharacters and apostrophes literally" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tmpPath(gpa, &tmp.sub_path, "special.txt");
    defer gpa.free(path);
    // Chars that were mis-escaped or shell-broken under sed: | + ? { } ( ) ' \
    const content = "a|b + c? d{e} (f) it's \\ back\n";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = content });

    const r = try editFile(io, gpa, path, "a|b", "X", 5000);
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);

    try std.testing.expect(r.success);
    const got = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(got);
    try std.testing.expectEqualStrings("X + c? d{e} (f) it's \\ back\n", got);

    const r2 = try editFile(io, gpa, path, "it's", "it is", 5000);
    defer gpa.free(r2.stdout);
    defer gpa.free(r2.stderr);

    try std.testing.expect(r2.success);
    const got2 = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(got2);
    try std.testing.expectEqualStrings("X + c? d{e} (f) it is \\ back\n", got2);
}

test "editFile preserves newlines in new_string" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tmpPath(gpa, &tmp.sub_path, "newline.txt");
    defer gpa.free(path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "foo\n" });

    const r = try editFile(io, gpa, path, "foo", "line1\nline2", 5000);
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);

    try std.testing.expect(r.success);
    const got = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(got);
    try std.testing.expectEqualStrings("line1\nline2\n", got);
}

test "editFile works on paths with spaces and apostrophes" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const parent = try tmpPath(gpa, &tmp.sub_path, "my dir's");
    defer gpa.free(parent);
    try std.Io.Dir.cwd().createDirPath(io, parent);

    const path = try std.fmt.allocPrint(gpa, "{s}/file.txt", .{parent});
    defer gpa.free(path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "hello world\n" });

    const r = try editFile(io, gpa, path, "world", "tau", 5000);
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);

    try std.testing.expect(r.success);
    const got = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(got);
    try std.testing.expectEqualStrings("hello tau\n", got);
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

test "editFile fails when old_string is empty" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tmpPath(gpa, &tmp.sub_path, "empty.txt");
    defer gpa.free(path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "x" });

    const r = try editFile(io, gpa, path, "", "bar", 5000);
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);

    try std.testing.expect(!r.success);
    try std.testing.expectEqual(@as(u8, 1), r.exit_code);
}
