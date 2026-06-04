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
