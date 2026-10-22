//! Seed-corpus encoders for `std.testing.fuzz` harnesses.
//!
//! A `Smith` consumes each corpus entry as a byte stream; the encoders here
//! produce bytes in exactly the layout the fuzz harnesses read them:
//!
//!   smith.eos()          -> 1 byte   (0 = keep producing, nonzero = stop)
//!   smith.slice(buf)     -> u32 little-endian length + that many bytes
//!   smith.index(n)       -> u64 little-endian
//!
//! Seeds run once each under plain `zig build test`; under
//! `zig build test --fuzz=<N>` they anchor coverage-guided mutation.
//! Nothing here is reachable from the shipped binary (only test decls import
//! this file), so the helpers cost nothing at runtime.

const std = @import("std");

/// One `smith.slice(&buf)` draw: u32 LE length prefix followed by the bytes.
/// Returns a comptime array pointer so entries compose with `++`.
pub fn slice(comptime s: []const u8) *const [4 + s.len]u8 {
    return comptime blk: {
        var out: [4 + s.len]u8 = undefined;
        std.mem.writeInt(u32, out[0..4], @intCast(s.len), .little);
        @memcpy(out[4..], s);
        const result = out;
        break :blk &result;
    };
}

/// One `smith.index(_)`/`smith.value(u64)` draw: u64 LE.
pub fn int(comptime v: u64) *const [8]u8 {
    return comptime blk: {
        var out: [8]u8 = undefined;
        std.mem.writeInt(u64, &out, v, .little);
        const result = out;
        break :blk &result;
    };
}

fn argvLen(comptime toks: []const []const u8) usize {
    var n: usize = 1;
    for (toks) |t| n += 1 + 4 + t.len;
    return n;
}

/// An argv token list for a `while (!smith.eos()) smith.slice(&buf)` loop:
/// per token a 0 eos byte then its slice encoding; terminated by a 1 byte.
pub fn argv(comptime toks: []const []const u8) *const [argvLen(toks)]u8 {
    return comptime blk: {
        var out: [argvLen(toks)]u8 = undefined;
        var i: usize = 0;
        for (toks) |t| {
            out[i] = 0;
            i += 1;
            std.mem.writeInt(u32, out[i..][0..4], @intCast(t.len), .little);
            i += 4;
            @memcpy(out[i..][0..t.len], t);
            i += t.len;
        }
        out[i] = 1;
        const result = out;
        break :blk &result;
    };
}
