//! Portable stdout/stderr byte output.
//!
//! Replaces the Linux-only `std.os.linux.write(fd, ptr, len)` syscalls used
//! throughout tau so the binary builds and runs correctly on Linux, macOS and
//! Windows (the raw linux syscall numbers are wrong on macOS and the namespace
//! does not even compile on Windows). The process-wide `std.Io` is recorded
//! once at startup via `init()`; writes are best-effort (errors ignored), which
//! matches the previous fire-and-forget `write()` behavior.
const std = @import("std");

var g_io: ?std.Io = null;

/// Record the process-wide std.Io used for stdout/stderr writes. Call once,
/// early in main(), before any out()/err().
pub fn init(io: std.Io) void {
    g_io = io;
}

/// Write all of `bytes` to stdout. Best-effort: a null io (init not called) or
/// a write error is silently dropped.
pub fn out(bytes: []const u8) void {
    const io = g_io orelse return;
    std.Io.File.stdout().writeStreamingAll(io, bytes) catch {};
}

/// Write all of `bytes` to stderr. Best-effort.
pub fn err(bytes: []const u8) void {
    const io = g_io orelse return;
    std.Io.File.stderr().writeStreamingAll(io, bytes) catch {};
}
