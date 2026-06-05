const std = @import("std");
const bashmod = @import("bash.zig");

pub const ToolResult = bashmod.ToolResult;

/// Search for a pattern in files using grep
pub fn grep(io: std.Io, gpa: std.mem.Allocator, pattern: []const u8, path: ?[]const u8, timeout_ms: i64) !ToolResult {
    const cmd = if (path) |p|
        try std.fmt.allocPrint(gpa, "grep -r '{s}' {s}", .{ pattern, p })
    else
        try std.fmt.allocPrint(gpa, "grep -r '{s}'", .{ pattern });

    defer gpa.free(cmd);
    return bashmod.execBash(io, gpa, cmd, timeout_ms);
}