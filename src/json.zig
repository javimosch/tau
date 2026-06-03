const std = @import("std");

/// Append `s` to `out` as a JSON-escaped string body (no surrounding quotes).
pub fn escapeInto(gpa: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| switch (c) {
        '"' => try out.appendSlice(gpa, "\\\""),
        '\\' => try out.appendSlice(gpa, "\\\\"),
        '\n' => try out.appendSlice(gpa, "\\n"),
        '\r' => try out.appendSlice(gpa, "\\r"),
        '\t' => try out.appendSlice(gpa, "\\t"),
        0x08 => try out.appendSlice(gpa, "\\b"),
        0x0C => try out.appendSlice(gpa, "\\f"),
        else => {
            if (c < 0x20) {
                var buf: [8]u8 = undefined;
                const hex = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{@as(u16, c)}) catch unreachable;
                try out.appendSlice(gpa, hex);
            } else try out.append(gpa, c);
        },
    };
}

/// Return a newly-allocated JSON-escaped copy of `s` (no surrounding quotes).
pub fn escapeAlloc(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try escapeInto(gpa, &out, s);
    return out.toOwnedSlice(gpa);
}

/// Unescape a JSON string body (the characters between the surrounding quotes).
/// Handles the standard short escapes and `\uXXXX` (BMP only; surrogate pairs
/// are passed through best-effort).
pub fn unescapeAlloc(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c != '\\') {
            try out.append(gpa, c);
            continue;
        }
        i += 1;
        if (i >= s.len) break;
        switch (s[i]) {
            'n' => try out.append(gpa, '\n'),
            'r' => try out.append(gpa, '\r'),
            't' => try out.append(gpa, '\t'),
            'b' => try out.append(gpa, 0x08),
            'f' => try out.append(gpa, 0x0C),
            '"' => try out.append(gpa, '"'),
            '\\' => try out.append(gpa, '\\'),
            '/' => try out.append(gpa, '/'),
            'u' => {
                if (i + 4 < s.len) {
                    const cp = std.fmt.parseInt(u21, s[i + 1 .. i + 5], 16) catch {
                        try out.append(gpa, 'u');
                        continue;
                    };
                    var ub: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(cp, &ub) catch {
                        i += 4;
                        continue;
                    };
                    try out.appendSlice(gpa, ub[0..n]);
                    i += 4;
                }
            },
            else => try out.append(gpa, s[i]),
        }
    }
    return out.toOwnedSlice(gpa);
}

/// Extract the unescaped value of the first `"field":"..."` occurrence in
/// `json`. Returns null if the field is absent. Caller owns the result.
pub fn extractString(gpa: std.mem.Allocator, json: []const u8, field: []const u8) !?[]u8 {
    const needle = try std.fmt.allocPrint(gpa, "\"{s}\":\"", .{field});
    defer gpa.free(needle);
    const at = std.mem.indexOf(u8, json, needle) orelse return null;
    const start = at + needle.len;
    var end = start;
    while (end < json.len) : (end += 1) {
        if (json[end] == '\\') {
            end += 1;
            continue;
        }
        if (json[end] == '"') break;
    } else return null;
    return try unescapeAlloc(gpa, json[start..end]);
}

test "escape roundtrip" {
    const gpa = std.testing.allocator;
    const raw = "he said \"hi\"\n\tand left\\";
    const esc = try escapeAlloc(gpa, raw);
    defer gpa.free(esc);
    const back = try unescapeAlloc(gpa, esc);
    defer gpa.free(back);
    try std.testing.expectEqualStrings(raw, back);
}

test "extractString" {
    const gpa = std.testing.allocator;
    const body = "{\"choices\":[{\"message\":{\"content\":\"line1\\nline2 \\\"q\\\"\",\"role\":\"assistant\"}}]}";
    const got = (try extractString(gpa, body, "content")).?;
    defer gpa.free(got);
    try std.testing.expectEqualStrings("line1\nline2 \"q\"", got);
}
