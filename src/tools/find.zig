const std = @import("std");
const bashmod = @import("bash.zig");

pub const ToolResult = bashmod.ToolResult;

/// Find files by name or pattern
pub fn find(io: std.Io, gpa: std.mem.Allocator, pattern: []const u8, path: ?[]const u8, timeout_ms: i64) !ToolResult {
    const cmd = if (path) |p|
        try std.fmt.allocPrint(gpa, "find {s} -name '*{s}*'", .{ p, pattern })
    else
        try std.fmt.allocPrint(gpa, "find . -name '*{s}*'", .{ pattern });

    defer gpa.free(cmd);
    return bashmod.execBash(io, gpa, cmd, timeout_ms);
}