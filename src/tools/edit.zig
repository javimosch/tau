const std = @import("std");
const linux = std.os.linux;
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