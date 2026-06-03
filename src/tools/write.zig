const std = @import("std");
const linux = std.os.linux;
const bashmod = @import("bash.zig");

pub const ToolResult = bashmod.ToolResult;

/// Write content to a file (overwrites if exists)
pub fn writeFile(io: std.Io, gpa: std.mem.Allocator, path: []const u8, content: []const u8, timeout_ms: i64) !ToolResult {
    // Use printf to write content to file (safer than shell escaping)
    const cmd = try std.fmt.allocPrint(gpa, "printf '%s' '{s}' > {s}", .{ content, path });

    defer gpa.free(cmd);
    return bashmod.execBash(io, gpa, cmd, timeout_ms);
}