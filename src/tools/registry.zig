const std = @import("std");
const bashmod = @import("bash.zig");

pub const ToolResult = bashmod.ToolResult;

pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    execute: *const fn (io: std.Io, gpa: std.mem.Allocator, args: []const []const u8, timeout_ms: i64) error{ MissingArgument, HTTPRequestFailed, Timeout, OutOfMemory }!ToolResult,
};

// Tool registry
const tools = [_]Tool{
    .{ .name = "bash", .description = "Execute a bash shell command", .execute = &executeBash },
    .{ .name = "ls", .description = "List files in a directory", .execute = &executeLs },
    .{ .name = "read", .description = "Read the contents of a file", .execute = &executeRead },
    .{ .name = "write", .description = "Write content to a file (overwrites if exists)", .execute = &executeWrite },
    .{ .name = "edit", .description = "Edit a file by replacing text (sed-based)", .execute = &executeEdit },
    .{ .name = "grep", .description = "Search for a pattern in files", .execute = &executeGrep },
    .{ .name = "find", .description = "Find files by name or pattern", .execute = &executeFind },
};

/// Get tool by name
pub fn getTool(name: []const u8) ?*const Tool {
    for (&tools) |*tool| {
        if (std.mem.eql(u8, tool.name, name)) return tool;
    }
    return null;
}

/// Get all enabled tools based on config
pub fn getEnabledTools(gpa: std.mem.Allocator, allowlist: ?[]const []const u8, denylist: ?[]const []const u8) ![]const Tool {
    var result = std.ArrayList(Tool).empty;
    defer result.deinit(gpa);

    if (allowlist) |allow| {
        for (allow) |name| {
            if (getTool(name)) |tool| {
                try result.append(gpa, tool.*);
            }
        }
        return result.toOwnedSlice(gpa);
    }

    for (&tools) |*tool| {
        if (denylist) |deny| {
            var denied = false;
            for (deny) |denied_name| {
                if (std.mem.eql(u8, tool.name, denied_name)) {
                    denied = true;
                    break;
                }
            }
            if (!denied) {
                try result.append(gpa, tool.*);
            }
        } else {
            try result.append(gpa, tool.*);
        }
    }
    return result.toOwnedSlice(gpa);
}

// Tool execution wrappers
fn executeBash(io: std.Io, gpa: std.mem.Allocator, args: []const []const u8, timeout_ms: i64) error{ MissingArgument, HTTPRequestFailed, Timeout, OutOfMemory }!ToolResult {
    const bash_mod = @import("bash.zig");
    if (args.len < 1) return error.MissingArgument;
    return bash_mod.execBash(io, gpa, args[0], timeout_ms);
}

fn executeLs(io: std.Io, gpa: std.mem.Allocator, args: []const []const u8, timeout_ms: i64) error{ MissingArgument, HTTPRequestFailed, Timeout, OutOfMemory }!ToolResult {
    const ls_mod = @import("ls.zig");
    const path = if (args.len > 0) args[0] else null;
    return ls_mod.ls(io, gpa, path, timeout_ms);
}

fn executeRead(io: std.Io, gpa: std.mem.Allocator, args: []const []const u8, timeout_ms: i64) error{ MissingArgument, HTTPRequestFailed, Timeout, OutOfMemory }!ToolResult {
    const read_mod = @import("read.zig");
    if (args.len < 1) return error.MissingArgument;
    return read_mod.readFile(io, gpa, args[0], timeout_ms);
}

fn executeWrite(io: std.Io, gpa: std.mem.Allocator, args: []const []const u8, timeout_ms: i64) error{ MissingArgument, HTTPRequestFailed, Timeout, OutOfMemory }!ToolResult {
    const write_mod = @import("write.zig");
    if (args.len < 2) return error.MissingArgument;
    return write_mod.writeFile(io, gpa, args[0], args[1], timeout_ms);
}

fn executeEdit(io: std.Io, gpa: std.mem.Allocator, args: []const []const u8, timeout_ms: i64) error{ MissingArgument, HTTPRequestFailed, Timeout, OutOfMemory }!ToolResult {
    const edit_mod = @import("edit.zig");
    if (args.len < 3) return error.MissingArgument;
    return edit_mod.editFile(io, gpa, args[0], args[1], args[2], timeout_ms);
}

fn executeGrep(io: std.Io, gpa: std.mem.Allocator, args: []const []const u8, timeout_ms: i64) error{ MissingArgument, HTTPRequestFailed, Timeout, OutOfMemory }!ToolResult {
    const grep_mod = @import("grep.zig");
    if (args.len < 1) return error.MissingArgument;
    const path = if (args.len > 1) args[1] else null;
    return grep_mod.grep(io, gpa, args[0], path, timeout_ms);
}

fn executeFind(io: std.Io, gpa: std.mem.Allocator, args: []const []const u8, timeout_ms: i64) error{ MissingArgument, HTTPRequestFailed, Timeout, OutOfMemory }!ToolResult {
    const find_mod = @import("find.zig");
    if (args.len < 1) return error.MissingArgument;
    const path = if (args.len > 1) args[1] else null;
    return find_mod.find(io, gpa, args[0], path, timeout_ms);
}

// ── Tests ───────────────────────────────────────────────────────────────────

test "getTool hit: 'bash' returns a non-null pointer with name bash" {
    const tool = getTool("bash");
    try std.testing.expect(tool != null);
    try std.testing.expectEqualStrings("bash", tool.?.name);
}

test "getTool miss: unknown name returns null" {
    const tool = getTool("nonexistent_tool");
    try std.testing.expect(tool == null);
}

test "getEnabledTools no-filter: null allowlist and null denylist returns all 7 tools" {
    const gpa = std.testing.allocator;
    const result = try getEnabledTools(gpa, null, null);
    defer gpa.free(result);
    try std.testing.expectEqual(@as(usize, 7), result.len);
}

test "getEnabledTools allowlist: only requested tools are returned in order" {
    const gpa = std.testing.allocator;
    const allow = [_][]const u8{ "bash", "read" };
    const result = try getEnabledTools(gpa, &allow, null);
    defer gpa.free(result);
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("bash", result[0].name);
    try std.testing.expectEqualStrings("read", result[1].name);
}

test "getEnabledTools denylist: denied tool is excluded from results" {
    const gpa = std.testing.allocator;
    const deny = [_][]const u8{"bash"};
    const result = try getEnabledTools(gpa, null, &deny);
    defer gpa.free(result);
    try std.testing.expectEqual(@as(usize, 6), result.len);
    for (result) |tool| {
        try std.testing.expect(!std.mem.eql(u8, tool.name, "bash"));
    }
}

test "getEnabledTools allowlist with unknown name: unknown names are silently skipped" {
    const gpa = std.testing.allocator;
    const allow = [_][]const u8{ "bash", "no_such_tool" };
    const result = try getEnabledTools(gpa, &allow, null);
    defer gpa.free(result);
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("bash", result[0].name);
}