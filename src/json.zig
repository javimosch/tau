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

// === Tool-argument accessors ===============================================
// Helpers for pulling typed values out of an LLM tool_call.arguments object
// (a flat JSON object string like {"command":"echo hi","timeout_ms":5000}).
// Naive flat-object scan: a key is matched anywhere it appears as `"key":`, so
// these assume tool argument objects are flat (which they are in practice).

/// Index just past `"key":` and any following whitespace, or null if absent.
fn valueStart(json: []const u8, key: []const u8) ?usize {
    var i: usize = 0;
    while (i < json.len) : (i += 1) {
        if (json[i] != '"') continue;
        const ks = i + 1;
        if (ks + key.len > json.len) return null;
        if (!std.mem.eql(u8, json[ks .. ks + key.len], key)) continue;
        var j = ks + key.len;
        if (j >= json.len or json[j] != '"') continue;
        j += 1;
        while (j < json.len and (json[j] == ' ' or json[j] == '\t')) : (j += 1) {}
        if (j >= json.len or json[j] != ':') continue;
        j += 1;
        while (j < json.len and (json[j] == ' ' or json[j] == '\t')) : (j += 1) {}
        return j;
    }
    return null;
}

/// Get a string tool argument (unescaped). Caller owns the result.
pub fn getStringArg(gpa: std.mem.Allocator, json: []const u8, key: []const u8) !?[]u8 {
    const vs = valueStart(json, key) orelse return null;
    if (vs >= json.len or json[vs] != '"') return null;
    const start = vs + 1;
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

/// Get an integer tool argument. Accepts bare (`"n":5`) or quoted (`"n":"5"`)
/// numbers, with optional sign. Returns null if absent or unparseable.
pub fn getIntArg(json: []const u8, key: []const u8) ?i64 {
    var vs = valueStart(json, key) orelse return null;
    const quoted = vs < json.len and json[vs] == '"';
    if (quoted) vs += 1;
    var end = vs;
    if (end < json.len and (json[end] == '-' or json[end] == '+')) end += 1;
    while (end < json.len and json[end] >= '0' and json[end] <= '9') : (end += 1) {}
    if (end == vs or (vs < json.len and (json[vs] == '-' or json[vs] == '+') and end == vs + 1)) return null;
    return std.fmt.parseInt(i64, json[vs..end], 10) catch null;
}

/// Get a boolean tool argument. Accepts bare or quoted `true`/`false`.
pub fn getBoolArg(json: []const u8, key: []const u8) ?bool {
    const vs = valueStart(json, key) orelse return null;
    const rest = json[vs..];
    if (std.mem.startsWith(u8, rest, "true") or std.mem.startsWith(u8, rest, "\"true\"")) return true;
    if (std.mem.startsWith(u8, rest, "false") or std.mem.startsWith(u8, rest, "\"false\"")) return false;
    return null;
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

test "tool arg accessors" {
    const gpa = std.testing.allocator;
    const args = "{\"command\":\"echo \\\"hi\\\"\", \"timeout_ms\": 5000, \"n\":\"-3\", \"force\":true}";

    const cmd = (try getStringArg(gpa, args, "command")).?;
    defer gpa.free(cmd);
    try std.testing.expectEqualStrings("echo \"hi\"", cmd);

    try std.testing.expectEqual(@as(i64, 5000), getIntArg(args, "timeout_ms").?);
    try std.testing.expectEqual(@as(i64, -3), getIntArg(args, "n").?); // quoted int
    try std.testing.expectEqual(true, getBoolArg(args, "force").?);

    try std.testing.expect((try getStringArg(gpa, args, "missing")) == null);
    try std.testing.expect(getIntArg(args, "missing") == null);
    try std.testing.expect(getBoolArg(args, "missing") == null);
}

test "adversarial json: escapes, unicode, malformed, no crash" {
    const gpa = std.testing.allocator;

    // escaped quotes + backslashes + newlines round-trip via unescape
    {
        const v = (try extractString(gpa, "{\"content\":\"a \\\"q\\\" b\\\\c\\nd\"}", "content")).?;
        defer gpa.free(v);
        try std.testing.expectEqualStrings("a \"q\" b\\c\nd", v);
    }
    // \uXXXX (BMP) decodes to UTF-8
    {
        const v = (try extractString(gpa, "{\"content\":\"caf\\u00e9\"}", "content")).?;
        defer gpa.free(v);
        try std.testing.expectEqualStrings("caf\u{00e9}", v);
    }
    // a backslash-escaped quote must NOT prematurely terminate the value
    {
        const v = (try getStringArg(gpa, "{\"command\":\"echo \\\"x\\\" && ls\"}", "command")).?;
        defer gpa.free(v);
        try std.testing.expectEqualStrings("echo \"x\" && ls", v);
    }
    // malformed / hostile inputs must return null/empty, never crash or loop
    try std.testing.expect((try extractString(gpa, "{\"content\":\"unterminated", "content")) == null);
    try std.testing.expect((try extractString(gpa, "not json at all", "content")) == null);
    try std.testing.expect((try extractString(gpa, "", "content")) == null);
    try std.testing.expect((try extractString(gpa, "{\"content\":", "content")) == null);
    try std.testing.expect(getIntArg("{\"n\":\"notanumber\"}", "n") == null);
    try std.testing.expect(getIntArg("{\"n\":}", "n") == null);
    // trailing dangling backslash at end of input is handled
    {
        const v = (try extractString(gpa, "{\"content\":\"ends with backslash\\", "content"));
        if (v) |vv| gpa.free(vv); // either null or a value, just must not crash
    }
}
