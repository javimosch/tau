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

/// Quote a string as a single POSIX shell word using single quotes.
/// Every embedded apostrophe is escaped as `'\''`, so the result can be
/// safely spliced into a command string passed to `sh -c`.
pub fn shQuote(gpa: std.mem.Allocator, s: []const u8) ![]const u8 {
    var result = std.ArrayList(u8).empty;
    defer result.deinit(gpa);
    try result.append(gpa, '\'');
    for (s) |c| {
        if (c == '\'') {
            try result.appendSlice(gpa, "'\\''");
        } else {
            try result.append(gpa, c);
        }
    }
    try result.append(gpa, '\'');
    return result.toOwnedSlice(gpa);
}

// ── Tests ───────────────────────────────────────────────────────────────────

test "execBash success: echo hello returns exit_code 0 and stdout contains hello" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    const r = try execBash(io, gpa, "echo hello", 5000);
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);

    try std.testing.expect(r.success);
    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "hello") != null);
}

test "execBash non-zero exit: exit 42 returns exit_code 42" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    const r = try execBash(io, gpa, "exit 42", 5000);
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);

    try std.testing.expect(!r.success);
    try std.testing.expectEqual(@as(u8, 42), r.exit_code);
}

test "execBash stderr capture: echo to stderr produces stderr output and empty stdout" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    const r = try execBash(io, gpa, "echo err >&2", 5000);
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);

    try std.testing.expect(r.success);
    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expectEqualStrings("", r.stdout);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "err") != null);
}

test "execBash timeout: sleep 10 with 1ms timeout returns exit_code 124 and stderr contains timed out" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    const r = try execBash(io, gpa, "sleep 10", 1);

    // stdout/stderr may be literals (not heap-allocated) on timeout path;
    // only free them when they are heap-allocated (non-empty dynamic buffers
    // are returned by std.process.run on the happy path). The timeout branch
    // returns string literals so we must not free them.
    try std.testing.expect(!r.success);
    try std.testing.expectEqual(@as(u8, 124), r.exit_code);

    // case-insensitive search for "timed out"
    var lower_buf: [64]u8 = undefined;
    const stderr_lower = std.ascii.lowerString(lower_buf[0..@min(r.stderr.len, lower_buf.len)], r.stderr[0..@min(r.stderr.len, lower_buf.len)]);
    try std.testing.expect(std.mem.indexOf(u8, stderr_lower, "timed out") != null);
}

test "shQuote wraps words and escapes apostrophes" {
    const gpa = std.testing.allocator;

    const plain = try shQuote(gpa, "hello world");
    defer gpa.free(plain);
    try std.testing.expectEqualStrings("'hello world'", plain);

    const quote = try shQuote(gpa, "it's");
    defer gpa.free(quote);
    try std.testing.expectEqualStrings("'it'\\''s'", quote);
}