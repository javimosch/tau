const std = @import("std");
const term = @import("term.zig");
const errs = @import("errors.zig");

/// Emit a standard "fleet <cmd> requires <what>" error and return the exit code.
/// Uses page_allocator (short-lived, called once per invocation).
pub fn fleetRequires(cmd: []const u8, what: []const u8, code: u8) u8 {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "fleet {s} requires {s}", .{ cmd, what }) catch "missing required field";
    errs.printOut(std.heap.page_allocator, errs.specFor(code), msg, .{});
    return code;
}

/// Emit "{\"<key>\":null}\n" or "{\"<key>\":[]}\n" and return 0.
pub fn fleetEmpty(key: []const u8, array: bool) u8 {
    if (array) {
        term.out("{\"");
        term.out(key);
        term.out("\":[]}\n");
    } else {
        term.out("{\"");
        term.out(key);
        term.out("\":null}\n");
    }
    return 0;
}

/// Serialize a value to JSON and write it to stdout + newline.
/// Caller owns `value`; the serialized bytes are freed by the defer.
pub fn fleetPrintJson(gpa: std.mem.Allocator, value: anytype) !void {
    const out = try std.json.Stringify.valueAlloc(gpa, value, .{ .whitespace = .indent_2 });
    defer gpa.free(out);
    term.out(out);
    term.out("\n");
}

/// Emit a code-110 err envelope with message "<prefix>: <err>" to stdout
/// (fleet's envelope channel) and return 110.
pub fn fleetErr(arena: std.mem.Allocator, prefix: []const u8, err: anyerror) u8 {
    const msg = std.fmt.allocPrint(arena, "{s}: {s}", .{ prefix, @errorName(err) }) catch "fleet error (OOM)";
    errs.printOut(arena, errs.internal_error, msg, .{});
    return 110;
}
