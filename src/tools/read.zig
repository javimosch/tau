const std = @import("std");
const bashmod = @import("bash.zig");

pub const ToolResult = bashmod.ToolResult;

/// Read a file and return its contents
pub fn readFile(io: std.Io, gpa: std.mem.Allocator, path: []const u8, timeout_ms: i64) !ToolResult {
    const cmd = try std.fmt.allocPrint(gpa, "cat {s}", .{path});

    defer gpa.free(cmd);
    return bashmod.execBash(io, gpa, cmd, timeout_ms);
}