const std = @import("std");
const linux = std.os.linux;
const bashmod = @import("bash.zig");

pub const ToolResult = bashmod.ToolResult;

/// List files in a directory (or current directory if path is null)
pub fn ls(io: std.Io, gpa: std.mem.Allocator, path: ?[]const u8, timeout_ms: i64) !ToolResult {
    const cmd = if (path) |p|
        try std.fmt.allocPrint(gpa, "ls -la {s}", .{p})
    else
        try std.fmt.allocPrint(gpa, "ls -la", .{});

    defer gpa.free(cmd);
    return bashmod.execBash(io, gpa, cmd, timeout_ms);
}