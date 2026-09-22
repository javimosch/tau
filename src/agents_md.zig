const std = @import("std");
const jsonmod = @import("json.zig");

/// Metadata for a discovered AGENTS.md file.
pub const AgentsMdFile = struct {
    path: []const u8,
    first_line: []const u8,
    size: u64,
};

/// Walk a directory tree and collect all AGENTS.md files (lazy: stat + first line only).
/// Uses `find` command for directory walking (Zig 0.16 compat).
pub fn scanAgentsMd(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, cwd: []const u8) ![]AgentsMdFile {
    const result = std.process.run(gpa, io, .{
        .argv = &[_][]const u8{
            "find", cwd,
            "-name", "AGENTS.md",
            "-not", "-path", "*/.*",
            "-not", "-path", "*/node_modules/*",
            "-not", "-path", "*/target/*",
            "-not", "-path", "*/zig-cache/*",
            "-not", "-path", "*/.git/*",
        },
        .stdout_limit = .unlimited,
    }) catch return &.{};
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    var files = std.ArrayList(AgentsMdFile).empty;

    var lines = std.mem.splitScalar(u8, std.mem.trim(u8, result.stdout, " \t\r\n"), '\n');
    while (lines.next()) |path| {
        if (path.len == 0) continue;
        // Read first line
        const content = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited) catch continue;
        const nl = std.mem.indexOfScalar(u8, content, '\n') orelse content.len;
        const first_line = std.mem.trim(u8, content[0..nl], " \t\r\n#");
        files.append(arena, .{
            .path = arena.dupe(u8, path) catch continue,
            .first_line = arena.dupe(u8, first_line) catch continue,
            .size = content.len,
        }) catch {};
    }

    return files.toOwnedSlice(arena) catch &.{};
}

/// Read an entire AGENTS.md file into an arena-allocated slice.
pub fn loadAgentsMd(io: std.Io, arena: std.mem.Allocator, path: []const u8) ?[]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited) catch return null;
}

/// Serialize one AGENTS.md scan entry as JSON with escaped path and first_line.
pub fn formatEntryJson(gpa: std.mem.Allocator, path: []const u8, first_line: []const u8, size: u64) ![]u8 {
    const pe = try jsonmod.escapeAlloc(gpa, path);
    defer gpa.free(pe);
    const fe = try jsonmod.escapeAlloc(gpa, first_line);
    defer gpa.free(fe);
    return std.fmt.allocPrint(gpa, "{{\"path\":\"{s}\",\"first_line\":\"{s}\",\"size\":{d}}}", .{ pe, fe, size });
}

test "scanAgentsMd returns empty for bad path" {
    const result = scanAgentsMd(std.testing.io, std.testing.allocator, std.testing.allocator, "/nonexistent") catch return;
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "formatEntryJson escapes quotes and backslashes in first_line" {
    const gpa = std.testing.allocator;
    const got = try formatEntryJson(gpa, "./AGENTS.md", "Use \"quotes\" and \\ backslash", 42);
    defer gpa.free(got);
    try std.testing.expectEqualStrings(
        "{\"path\":\"./AGENTS.md\",\"first_line\":\"Use \\\"quotes\\\" and \\\\ backslash\",\"size\":42}",
        got,
    );
}

test "formatEntryJson escapes control characters in path and first_line" {
    const gpa = std.testing.allocator;
    const got = try formatEntryJson(gpa, "dir/AGENTS.md", "line1\nline2", 100);
    defer gpa.free(got);
    try std.testing.expectEqualStrings(
        "{\"path\":\"dir/AGENTS.md\",\"first_line\":\"line1\\nline2\",\"size\":100}",
        got,
    );
}

// ── Filesystem-backed tests ─────────────────────────────────────────────────
// tmpDir roots at .zig-cache/tmp/<sub>, which is NOT excluded by the scan's
// "*/.*" or "*/zig-cache/*" find filters (no "/." or "/zig-cache/" substring),
// so AGENTS.md files written there are discoverable.

fn tmpRoot(arena: std.mem.Allocator, tmp: *const std.testing.TmpDir) ![]u8 {
    return std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
}

/// Write `data` to `<root>/<rel>`, creating intermediate directories.
fn writeTmp(io: std.Io, arena: std.mem.Allocator, root: []const u8, rel: []const u8, data: []const u8) !void {
    const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ root, rel });
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| {
        try std.Io.Dir.cwd().createDirPath(io, path[0..idx]);
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
}

/// Scan a directory expected to contain exactly one AGENTS.md entry.
fn scanOne(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, dir: []const u8) !AgentsMdFile {
    const files = try scanAgentsMd(io, gpa, arena, dir);
    try std.testing.expectEqual(@as(usize, 1), files.len);
    return files[0];
}

test "loadAgentsMd returns contents for an existing file" {
    const io = std.testing.io;
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmpRoot(arena, &tmp);
    const path = try std.fmt.allocPrint(arena, "{s}/AGENTS.md", .{root});
    const content = "# Rules\n\nDo the thing.\n";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = content });

    const got = loadAgentsMd(io, arena, path) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(content, got);
}

test "loadAgentsMd returns null for a missing file and for a directory" {
    const io = std.testing.io;
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmpRoot(arena, &tmp);
    const missing = try std.fmt.allocPrint(arena, "{s}/nope/AGENTS.md", .{root});
    try std.testing.expect(loadAgentsMd(io, arena, missing) == null);
    // A directory is not readable as a file.
    try std.testing.expect(loadAgentsMd(io, arena, root) == null);
}

test "scanAgentsMd returns empty when no AGENTS.md exists" {
    const io = std.testing.io;
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmpRoot(arena, &tmp);
    try writeTmp(io, arena, root, "README.md", "# not an agents file\n");
    try writeTmp(io, arena, root, "sub/notes.txt", "nothing here\n");

    const files = try scanAgentsMd(io, std.testing.allocator, arena, root);
    try std.testing.expectEqual(@as(usize, 0), files.len);
}

test "scanAgentsMd discovers AGENTS.md files in nested directories" {
    const io = std.testing.io;
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmpRoot(arena, &tmp);
    try writeTmp(io, arena, root, "AGENTS.md", "# root rules\n\nbody\n");
    try writeTmp(io, arena, root, "docs/AGENTS.md", "# docs rules\n");
    try writeTmp(io, arena, root, "src/deep/nested/AGENTS.md", "# deep rules\n");

    const files = try scanAgentsMd(io, std.testing.allocator, arena, root);
    try std.testing.expectEqual(@as(usize, 3), files.len);

    // find output order is unspecified; match on each file's first line.
    var saw = [_]bool{false} ** 3;
    for (files) |f| {
        if (std.mem.eql(u8, f.first_line, "root rules")) saw[0] = true;
        if (std.mem.eql(u8, f.first_line, "docs rules")) saw[1] = true;
        if (std.mem.eql(u8, f.first_line, "deep rules")) {
            saw[2] = true;
            try std.testing.expect(std.mem.endsWith(u8, f.path, "src/deep/nested/AGENTS.md"));
        }
    }
    try std.testing.expect(saw[0] and saw[1] and saw[2]);
}

test "scanAgentsMd skips hidden, node_modules, target, and .git directories" {
    const io = std.testing.io;
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmpRoot(arena, &tmp);
    try writeTmp(io, arena, root, "keep/AGENTS.md", "# keep me\n");
    try writeTmp(io, arena, root, ".hidden/AGENTS.md", "# hidden\n");
    try writeTmp(io, arena, root, "node_modules/AGENTS.md", "# deps\n");
    try writeTmp(io, arena, root, "target/AGENTS.md", "# build\n");
    try writeTmp(io, arena, root, ".git/AGENTS.md", "# vcs\n");

    const f = try scanOne(io, std.testing.allocator, arena, root);
    try std.testing.expectEqualStrings("keep me", f.first_line);
    try std.testing.expect(std.mem.endsWith(u8, f.path, "keep/AGENTS.md"));
}

test "scanAgentsMd skips a directory named AGENTS.md" {
    const io = std.testing.io;
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmpRoot(arena, &tmp);
    // find -name AGENTS.md has no -type f filter, so this directory is listed
    // and then skipped when readFileAlloc fails on it.
    try writeTmp(io, arena, root, "fake/AGENTS.md/dummy.txt", "x\n");
    try writeTmp(io, arena, root, "real/AGENTS.md", "# real\n");

    const f = try scanOne(io, std.testing.allocator, arena, root);
    try std.testing.expectEqualStrings("real", f.first_line);
    try std.testing.expect(std.mem.endsWith(u8, f.path, "real/AGENTS.md"));
}

test "scanAgentsMd handles empty, heading-only, and newline-less content" {
    const io = std.testing.io;
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmpRoot(arena, &tmp);
    try writeTmp(io, arena, root, "empty/AGENTS.md", "");
    try writeTmp(io, arena, root, "hashes/AGENTS.md", "###\nbody text\n");
    try writeTmp(io, arena, root, "nonl/AGENTS.md", "no trailing newline");
    try writeTmp(io, arena, root, "crlf/AGENTS.md", "# Title\r\nbody\r\n");

    // Scan each single-file subdirectory so results are deterministic.
    const empty = try scanOne(io, std.testing.allocator, arena, try std.fmt.allocPrint(arena, "{s}/empty", .{root}));
    try std.testing.expectEqualStrings("", empty.first_line);
    try std.testing.expectEqual(@as(u64, 0), empty.size);

    const hashes = try scanOne(io, std.testing.allocator, arena, try std.fmt.allocPrint(arena, "{s}/hashes", .{root}));
    try std.testing.expectEqualStrings("", hashes.first_line);

    const nonl = try scanOne(io, std.testing.allocator, arena, try std.fmt.allocPrint(arena, "{s}/nonl", .{root}));
    try std.testing.expectEqualStrings("no trailing newline", nonl.first_line);
    try std.testing.expectEqual(@as(u64, 19), nonl.size);

    const crlf = try scanOne(io, std.testing.allocator, arena, try std.fmt.allocPrint(arena, "{s}/crlf", .{root}));
    try std.testing.expectEqualStrings("Title", crlf.first_line);
}
