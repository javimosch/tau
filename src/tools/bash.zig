const std = @import("std");
const jsonmod = @import("../json.zig");

pub const ToolResult = struct {
    success: bool,
    stdout: []const u8,
    stderr: []const u8,
    exit_code: u8,
};

/// Execute a bash command and return stdout/stderr
pub fn execBash(io: std.Io, gpa: std.mem.Allocator, command: []const u8, timeout_ms: i64) !ToolResult {
    // Build argv for shell execution
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ "sh", "-c", command });

    const argv_slice = try argv.toOwnedSlice(gpa);
    defer gpa.free(argv_slice);

    const timeout = std.Io.Timeout{ .duration = .{
        .raw = std.Io.Duration.fromMilliseconds(@intCast(timeout_ms)),
        .clock = .awake,
    } };

    const result = std.process.run(gpa, io, .{
        .argv = argv_slice,
        .stdout_limit = .unlimited,
        .stderr_limit = .unlimited,
        .timeout = timeout,
    }) catch |err| {
        if (err == error.Timeout) {
            return ToolResult{
                .success = false,
                .stdout = "",
                .stderr = "Command timed out",
                .exit_code = 124,
            };
        }
        return ToolResult{
            .success = false,
            .stdout = "",
            .stderr = "Failed to execute command",
            .exit_code = 1,
        };
    };
    // NOTE: ownership of result.stdout/stderr transfers to ToolResult — do NOT
    // free them here; doing so returns dangling pointers. The caller owns the
    // buffers for the lifetime of the ToolResult.
    const exit_code: u8 = switch (result.term) {
        .exited => |c| c,
        else => 1,
    };

    return ToolResult{
        .success = exit_code == 0,
        .stdout = result.stdout,
        .stderr = result.stderr,
        .exit_code = exit_code,
    };
}