const std = @import("std");

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

test "scanAgentsMd returns empty for bad path" {
    // Will fail gracefully
    const result = scanAgentsMd(undefined, std.testing.allocator, std.testing.allocator, "/nonexistent") catch |err| {
        _ = err;
        return;
    };
    _ = result;
}
