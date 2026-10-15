//! `tau config set|get|unset` — schema-validated, comment-preserving edits to
//! a JSONC config file. Mutations are surgical text splices: a string/comment-
//! aware scanner locates the target key's tokens and only that span is
//! rewritten, so the commented `tau init` scaffold and hand-written comments
//! survive a `config set` round-trip.
//!
//! Type coercion and semantic checks mirror `config validate` (derived at
//! comptime from configfile.FileConfig), so a value `config set` accepts is
//! always one `config validate` reports clean. Secrets are never echoed:
//! `api_key`/`keys.*` values are redacted in output unless `get --raw` is
//! passed.

const std = @import("std");
const builtin = @import("builtin");
const cfgmod = @import("config.zig");
const configfile = @import("configfile.zig");
const jsonmod = @import("json.zig");

pub const Sub = enum { set, get, unset };

/// Caller-facing failure: rendered as an {"err"} envelope on stderr, exit code.
pub const Fail = struct {
    code: u8,
    type_name: []const u8,
    message: []const u8,
};

/// Outcome of a set/get/unset: stdout payload on success, or an envelope to
/// emit on stderr with its exit code.
pub const Outcome = union(enum) {
    ok: []const u8,
    fail: Fail,
};

// Comptime view of the persisted file schema (same struct the loader and the
// validator derive from — single source of truth).
const file_fields = @typeInfo(configfile.FileConfig).@"struct".fields;

const Kind = enum { string, boolean, integer, number, any_json };

fn innerType(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .optional => |o| o.child,
        else => T,
    };
}

fn fieldKind(comptime T: type) Kind {
    return switch (innerType(T)) {
        []const u8 => .string,
        bool => .boolean,
        u32, u64, usize, i32, i64 => .integer,
        f32, f64 => .number,
        else => .any_json,
    };
}

/// A parsed key address: top-level FileConfig field, or a `keys.<provider>`
/// entry inside the per-provider key map.
const KeyPath = union(enum) {
    field: []const u8,
    keys_entry: []const u8,
};

fn isKnownField(key: []const u8) bool {
    inline for (file_fields) |f| {
        if (std.mem.eql(u8, key, f.name)) return true;
    }
    return false;
}

fn knownFieldNames(arena: std.mem.Allocator) ![]const u8 {
    var b: std.ArrayList(u8) = .empty;
    inline for (file_fields, 0..) |f, i| {
        if (i != 0) try b.appendSlice(arena, ", ");
        try b.appendSlice(arena, f.name);
    }
    return b.toOwnedSlice(arena);
}

fn providerNames(arena: std.mem.Allocator) ![]const u8 {
    var b: std.ArrayList(u8) = .empty;
    for (cfgmod.providers, 0..) |p, i| {
        if (i != 0) try b.appendSlice(arena, ", ");
        try b.appendSlice(arena, p.name);
    }
    return b.toOwnedSlice(arena);
}

/// Parse a user-supplied key path. `keys.<name>` addresses a per-provider API
/// key; any other dotted path is rejected (the schema has no other objects).
/// `strict_field` (set) additionally requires a known FileConfig key — for
/// get/unset any syntactically valid path is accepted so unknown keys present
/// in the file can still be inspected or removed.
fn parseKeyPath(arena: std.mem.Allocator, key: []const u8, strict_field: bool) union(enum) { ok: KeyPath, fail: Fail } {
    if (key.len == 0) return .{ .fail = .{ .code = 80, .type_name = "invalid_argument", .message = "empty config key" } };
    const dot = std.mem.indexOfScalar(u8, key, '.');
    if (dot == null) {
        if (strict_field and !isKnownField(key)) {
            const names = knownFieldNames(arena) catch "see docs/configuration.md";
            const msg = std.fmt.allocPrint(arena, "\"{s}\" is not a tau config key — valid keys: {s} (or keys.<provider>)", .{ key, names }) catch "unknown config key";
            return .{ .fail = .{ .code = 80, .type_name = "invalid_argument", .message = msg } };
        }
        return .{ .ok = .{ .field = key } };
    }
    const parent = key[0..dot.?];
    const child = key[dot.? + 1 ..];
    if (!std.mem.eql(u8, parent, "keys") or child.len == 0 or std.mem.indexOfScalar(u8, child, '.') != null) {
        const msg = std.fmt.allocPrint(arena, "unsupported config key path \"{s}\" — use a top-level key or keys.<provider>", .{key}) catch "unsupported config key path";
        return .{ .fail = .{ .code = 80, .type_name = "invalid_argument", .message = msg } };
    }
    return .{ .ok = .{ .keys_entry = child } };
}

/// Secret-bearing key paths: their values are masked in all output unless
/// `get --raw` is passed.
fn isSecretPath(kp: KeyPath) bool {
    return switch (kp) {
        .field => |k| std.mem.eql(u8, k, "api_key") or std.mem.eql(u8, k, "keys"),
        .keys_entry => true,
    };
}

// ---------------------------------------------------------------------------
// JSONC scanner — locates object members on the ORIGINAL bytes (comments and
// string contents respected), so splices preserve everything around them.
// ---------------------------------------------------------------------------

const Member = struct {
    key: []const u8, // decoded key name
    key_start: usize, // index of the opening quote
    value_start: usize,
    value_end: usize, // one past the last value char
    leading_comma: ?usize, // the ',' separating this member from the previous
    trailing_comma: ?usize, // the ',' separating this member from the next
};

const Obj = struct {
    open: usize, // index of '{'
    close: usize, // index of '}'
    members: []Member,
};

const ScanError = error{ InvalidJson, OutOfMemory };

/// Advance past whitespace and JSONC comments.
fn skipTrivia(bytes: []const u8, start: usize) usize {
    var i = start;
    while (i < bytes.len) {
        const c = bytes[i];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            i += 1;
            continue;
        }
        if (c == '/' and i + 1 < bytes.len) {
            if (bytes[i + 1] == '/') {
                i += 2;
                while (i < bytes.len and bytes[i] != '\n') i += 1;
                continue;
            }
            if (bytes[i + 1] == '*') {
                i += 2;
                while (i + 1 < bytes.len and !(bytes[i] == '*' and bytes[i + 1] == '/')) i += 1;
                i = if (i + 1 < bytes.len) i + 2 else bytes.len;
                continue;
            }
        }
        break;
    }
    return i;
}

/// Index one past the closing quote of the string literal at `i` (`bytes[i]`
/// must be `"`). Escaped chars are skipped pairwise.
fn stringEnd(bytes: []const u8, start: usize) ScanError!usize {
    var i = start + 1;
    while (i < bytes.len) {
        const c = bytes[i];
        if (c == '\\') {
            i += 2;
            continue;
        }
        if (c == '"') return i + 1;
        i += 1;
    }
    return error.InvalidJson;
}

/// Index one past the JSON value starting at `i`. Objects/arrays are matched
/// with a depth counter; scalars run to the next delimiter.
fn valueEnd(bytes: []const u8, start: usize) ScanError!usize {
    if (start >= bytes.len) return error.InvalidJson;
    const c = bytes[start];
    if (c == '"') return stringEnd(bytes, start);
    if (c == '{' or c == '[') {
        var depth: usize = 1;
        var i = start + 1;
        while (i < bytes.len) {
            const ch = bytes[i];
            if (ch == '"') {
                i = try stringEnd(bytes, i);
                continue;
            }
            if (ch == '/' and i + 1 < bytes.len and (bytes[i + 1] == '/' or bytes[i + 1] == '*')) {
                i = skipTrivia(bytes, i);
                continue;
            }
            if (ch == '{' or ch == '[') depth += 1;
            if (ch == '}' or ch == ']') {
                depth -= 1;
                if (depth == 0) return i + 1;
            }
            i += 1;
        }
        return error.InvalidJson;
    }
    // Scalar: number/true/false/null — ends at a delimiter or comment start.
    var i = start;
    while (i < bytes.len) {
        const ch = bytes[i];
        if (ch == ',' or ch == '}' or ch == ']' or ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r' or ch == '/') break;
        i += 1;
    }
    if (i == start) return error.InvalidJson;
    return i;
}

/// Parse the member list of the object whose `{` is at `open`. All offsets are
/// into the original `bytes`, comments included.
fn scanObj(arena: std.mem.Allocator, bytes: []const u8, open: usize) ScanError!Obj {
    var members: std.ArrayList(Member) = .empty;
    var i = skipTrivia(bytes, open + 1);
    var leading_comma: ?usize = null;
    while (true) {
        if (i >= bytes.len) return error.InvalidJson;
        if (bytes[i] == '}') return .{ .open = open, .close = i, .members = members.items };
        if (bytes[i] != '"') return error.InvalidJson;
        const ks = i;
        const ke = try stringEnd(bytes, i);
        const decoded = jsonmod.unescapeAlloc(arena, bytes[ks + 1 .. ke - 1]) catch return error.InvalidJson;
        i = skipTrivia(bytes, ke);
        if (i >= bytes.len or bytes[i] != ':') return error.InvalidJson;
        const vs = skipTrivia(bytes, i + 1);
        const ve = try valueEnd(bytes, vs);
        i = skipTrivia(bytes, ve);
        var trailing_comma: ?usize = null;
        if (i < bytes.len and bytes[i] == ',') {
            trailing_comma = i;
            i = skipTrivia(bytes, i + 1);
        }
        try members.append(arena, .{
            .key = decoded,
            .key_start = ks,
            .value_start = vs,
            .value_end = ve,
            .leading_comma = leading_comma,
            .trailing_comma = trailing_comma,
        });
        leading_comma = trailing_comma;
        if (i >= bytes.len) return error.InvalidJson;
        if (bytes[i] == '}') return .{ .open = open, .close = i, .members = members.items };
        if (bytes[i] != '"') return error.InvalidJson;
    }
}

/// Scan the top-level object of a whole config file. Rejects trailing garbage
/// after the closing brace.
fn scanDoc(arena: std.mem.Allocator, bytes: []const u8) ScanError!Obj {
    const open = skipTrivia(bytes, 0);
    if (open >= bytes.len or bytes[open] != '{') return error.InvalidJson;
    const obj = try scanObj(arena, bytes, open);
    if (skipTrivia(bytes, obj.close + 1) != bytes.len) return error.InvalidJson;
    return obj;
}

/// Last member matching `key` (matches what the loader sees — a duplicate key
/// later in the file shadows earlier ones).
fn findMember(obj: Obj, key: []const u8) ?usize {
    var found: ?usize = null;
    for (obj.members, 0..) |m, i| {
        if (std.mem.eql(u8, m.key, key)) found = i;
    }
    return found;
}

// ---------------------------------------------------------------------------
// Splices
// ---------------------------------------------------------------------------

fn splice(arena: std.mem.Allocator, bytes: []const u8, start: usize, end: usize, with: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, bytes[0..start]);
    try out.appendSlice(arena, with);
    try out.appendSlice(arena, bytes[end..]);
    return out.toOwnedSlice(arena);
}

/// Start of the line containing `pos` when everything before `pos` on that
/// line is whitespace (member owns its line) — else `pos` itself.
fn lineStart(bytes: []const u8, pos: usize) usize {
    var i = pos;
    while (i > 0 and (bytes[i - 1] == ' ' or bytes[i - 1] == '\t')) i -= 1;
    if (i > 0 and bytes[i - 1] == '\n') return i;
    return pos;
}

/// Indentation of the member's line (the ws run before it), or null when the
/// member shares a line with preceding content.
fn memberIndent(bytes: []const u8, m: Member) ?[]const u8 {
    var i = m.key_start;
    while (i > 0 and (bytes[i - 1] == ' ' or bytes[i - 1] == '\t')) i -= 1;
    if (i > 0 and bytes[i - 1] == '\n') return bytes[i..m.key_start];
    return null;
}

/// Build `"key": token` with the file's existing member indentation.
fn renderMember(arena: std.mem.Allocator, bytes: []const u8, obj: Obj, key: []const u8, token: []const u8) !struct { text: []u8, pos: usize } {
    var out: std.ArrayList(u8) = .empty;
    if (obj.members.len == 0) {
        // Empty (or comment-only) object: drop the inner region, write fresh.
        try out.appendSlice(arena, "\n  \"");
        try jsonmod.escapeInto(arena, &out, key);
        try out.appendSlice(arena, "\": ");
        try out.appendSlice(arena, token);
        try out.append(arena, '\n');
        return .{ .text = out.items, .pos = obj.open + 1 };
    }
    const last = obj.members[obj.members.len - 1];
    const indent = memberIndent(bytes, last);
    try out.append(arena, ',');
    if (indent) |ind| {
        try out.append(arena, '\n');
        try out.appendSlice(arena, ind);
    } else {
        try out.append(arena, ' ');
    }
    try out.append(arena, '"');
    try jsonmod.escapeInto(arena, &out, key);
    try out.appendSlice(arena, "\": ");
    try out.appendSlice(arena, token);
    return .{ .text = out.items, .pos = last.value_end };
}

/// Insert `"key": token` into `obj`. For an empty object the region between
/// the braces is replaced; otherwise the member is appended after the last one.
fn insertMember(arena: std.mem.Allocator, bytes: []const u8, obj: Obj, key: []const u8, token: []const u8) ![]u8 {
    const r = try renderMember(arena, bytes, obj, key, token);
    const end = if (obj.members.len == 0) obj.close else r.pos;
    return splice(arena, bytes, r.pos, end, r.text);
}

/// Removal span for one member, chosen so the result stays valid JSON and
/// doesn't leave a dangling comma or a whitespace-only line.
fn removalSpan(bytes: []const u8, m: Member) struct { start: usize, end: usize } {
    if (m.trailing_comma) |c| {
        // Member + its separator; eat the rest of the line if now empty.
        var end = c + 1;
        while (end < bytes.len and (bytes[end] == ' ' or bytes[end] == '\t')) end += 1;
        if (end < bytes.len and bytes[end] == '\n') end += 1;
        return .{ .start = lineStart(bytes, m.key_start), .end = end };
    }
    if (m.leading_comma) |c| {
        // Last member: remove the preceding separator too; the '\n' before
        // '}' survives so the file keeps its shape.
        return .{ .start = c, .end = m.value_end };
    }
    // Only member: take its whole line.
    var end = m.value_end;
    while (end < bytes.len and (bytes[end] == ' ' or bytes[end] == '\t')) end += 1;
    if (end < bytes.len and bytes[end] == '\n') end += 1;
    return .{ .start = lineStart(bytes, m.key_start), .end = end };
}

// ---------------------------------------------------------------------------
// Value coercion (set) — same rules `config validate` enforces.
// ---------------------------------------------------------------------------

const Coerced = union(enum) { ok: []const u8, fail: Fail };

fn badValue(arena: std.mem.Allocator, comptime fmt: []const u8, args: anytype) Coerced {
    return .{ .fail = .{ .code = 80, .type_name = "invalid_argument", .message = std.fmt.allocPrint(arena, fmt, args) catch "invalid value" } };
}

/// Quote `raw` as a JSON string token.
fn quoteString(arena: std.mem.Allocator, raw: []const u8) ![]u8 {
    var b: std.ArrayList(u8) = .empty;
    try b.append(arena, '"');
    try jsonmod.escapeInto(arena, &b, raw);
    try b.append(arena, '"');
    return b.toOwnedSlice(arena);
}

/// Validate a `keys` whole-map JSON literal: object of provider-name →
/// non-empty string. Returns the raw literal (it is already valid JSON).
fn coerceKeysMap(arena: std.mem.Allocator, raw: []const u8) !Coerced {
    const val = std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{}) catch {
        return badValue(arena, "\"keys\" expects a JSON object of provider→key pairs, e.g. '{{\"openai\":\"sk-...\"}}'", .{});
    };
    if (val != .object) {
        return badValue(arena, "\"keys\" must be a JSON object of provider→key pairs", .{});
    }
    var it = val.object.iterator();
    while (it.next()) |e| {
        if (cfgmod.findProvider(e.key_ptr.*) == null) {
            return badValue(arena, "\"keys.{s}\" is not a known provider — valid providers: {s}", .{ e.key_ptr.*, try providerNames(arena) });
        }
        if (e.value_ptr.* != .string) {
            return badValue(arena, "\"keys.{s}\" must be a string", .{e.key_ptr.*});
        }
        if (e.value_ptr.*.string.len == 0) {
            return badValue(arena, "\"keys.{s}\" is an empty string — use `tau config unset keys.{s}` to remove it", .{ e.key_ptr.*, e.key_ptr.* });
        }
    }
    return .{ .ok = raw };
}

/// Coerce the raw `set` value for `kp` into a JSON token, enforcing the same
/// per-field rules `config validate` reports (type, provider, mode, ranges).
fn coerceValue(arena: std.mem.Allocator, kp: KeyPath, raw: []const u8) !Coerced {
    switch (kp) {
        .keys_entry => |pname| {
            if (cfgmod.findProvider(pname) == null) {
                return badValue(arena, "\"keys.{s}\" is not a known provider — valid providers: {s}", .{ pname, try providerNames(arena) });
            }
            if (raw.len == 0) {
                return badValue(arena, "empty API key — use `tau config unset keys.{s}` to remove it", .{pname});
            }
            return .{ .ok = try quoteString(arena, raw) };
        },
        .field => |name| {
            if (std.mem.eql(u8, name, "keys")) return coerceKeysMap(arena, raw);
            inline for (file_fields) |f| {
                if (std.mem.eql(u8, name, f.name)) {
                    switch (comptime fieldKind(f.type)) {
                        .string => {
                            if (comptime std.mem.eql(u8, f.name, "provider")) {
                                if (cfgmod.findProvider(raw) == null) {
                                    return badValue(arena, "\"provider\" is not a known provider: \"{s}\" — valid providers: {s}", .{ raw, try providerNames(arena) });
                                }
                            } else if (comptime std.mem.eql(u8, f.name, "mode")) {
                                if (!std.mem.eql(u8, raw, "text") and !std.mem.eql(u8, raw, "json")) {
                                    return badValue(arena, "\"mode\" must be \"text\" or \"json\", got \"{s}\"", .{raw});
                                }
                            } else if (comptime std.mem.eql(u8, f.name, "api_key")) {
                                if (raw.len == 0) {
                                    return badValue(arena, "empty API key — use `tau config unset api_key` to remove it", .{});
                                }
                            }
                            return .{ .ok = try quoteString(arena, raw) };
                        },
                        .boolean => {
                            if (std.mem.eql(u8, raw, "true")) return .{ .ok = "true" };
                            if (std.mem.eql(u8, raw, "false")) return .{ .ok = "false" };
                            return badValue(arena, "\"{s}\" must be a boolean (true/false), got \"{s}\"", .{ f.name, raw });
                        },
                        .integer => {
                            const v = std.fmt.parseInt(i64, raw, 10) catch {
                                return badValue(arena, "\"{s}\" must be an integer, got \"{s}\"", .{ f.name, raw });
                            };
                            if (v < 0) {
                                return badValue(arena, "\"{s}\" must be >= 0, got {d}", .{ f.name, v });
                            }
                            const inner = innerType(f.type);
                            if (comptime @typeInfo(inner).int.bits < 64) {
                                if (v > std.math.maxInt(inner)) {
                                    return badValue(arena, "\"{s}\" must be <= {d}, got {d}", .{ f.name, std.math.maxInt(inner), v });
                                }
                            }
                            return .{ .ok = try std.fmt.allocPrint(arena, "{d}", .{v}) };
                        },
                        .number => {
                            const v = std.fmt.parseFloat(f64, raw) catch {
                                return badValue(arena, "\"{s}\" must be a number, got \"{s}\"", .{ f.name, raw });
                            };
                            if (!std.math.isFinite(v)) {
                                return badValue(arena, "\"{s}\" must be a finite number, got \"{s}\"", .{ f.name, raw });
                            }
                            if (v < 0) {
                                return badValue(arena, "\"{s}\" must be >= 0, got \"{s}\"", .{ f.name, raw });
                            }
                            if (comptime std.mem.eql(u8, f.name, "compact_threshold")) {
                                if (v > 1) {
                                    return badValue(arena, "\"compact_threshold\" must be between 0 and 1, got \"{s}\"", .{raw});
                                }
                            }
                            return .{ .ok = try std.fmt.allocPrint(arena, "{d}", .{v}) };
                        },
                        .any_json => return .{ .ok = raw },
                    }
                }
            }
            unreachable; // set path validated the field name earlier
        },
    }
}

// ---------------------------------------------------------------------------
// File access
// ---------------------------------------------------------------------------

/// Read + structurally scan the config file. `.missing` means the file does
/// not exist; `.blank` carries a file with only whitespace/comments (set keeps
/// them and appends a fresh object).
const Doc = union(enum) {
    missing,
    blank: []const u8,
    invalid: []const u8, // reason for the {"err"} message
    parsed: struct { bytes: []const u8, obj: Obj },
};

fn readDoc(io: std.Io, arena: std.mem.Allocator, path: []const u8) !Doc {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited) catch |err| {
        switch (err) {
            error.FileNotFound => return .missing,
            error.AccessDenied => return .{ .invalid = "permission denied" },
            error.IsDir => return .{ .invalid = "path is a directory" },
            else => return err,
        }
    };
    if (skipTrivia(bytes, 0) == bytes.len) return .{ .blank = bytes };
    const obj = scanDoc(arena, bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidJson => return .{ .invalid = "invalid JSON — fix the syntax (see `tau config validate`), delete the file, or regenerate with `tau init`" },
    };
    // The scanner is structural only — confirm the document also parses as
    // strict JSON (comments stripped) so we never splice into a file that
    // `config validate` or configfile.load would reject.
    const stripped = configfile.stripComments(arena, bytes) catch bytes;
    _ = std.json.parseFromSliceLeaky(std.json.Value, arena, stripped, .{}) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .invalid = "invalid JSON — fix the syntax (see `tau config validate`), delete the file, or regenerate with `tau init`" };
    };
    return .{ .parsed = .{ .bytes = bytes, .obj = obj } };
}

/// Write `content` to `path` atomically (temp file + rename). Existing file
/// permissions are preserved; a new file is created owner-only (0600) since it
/// may hold API keys.
fn writeAtomic(io: std.Io, arena: std.mem.Allocator, path: []const u8, content: []const u8) !void {
    const perms: std.Io.File.Permissions = if (std.Io.Dir.cwd().statFile(io, path, .{})) |st|
        st.permissions
    else |_| if (builtin.os.tag == .windows)
        .default_file
    else
        .fromMode(0o600);

    const stamp: u64 = @intCast(std.Io.Clock.Timestamp.now(io, .real).raw.toNanoseconds());
    const tmp = try std.fmt.allocPrint(arena, "{s}.tmp-{d}", .{ path, stamp });
    errdefer std.Io.Dir.cwd().deleteFile(io, tmp) catch {};

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = content, .flags = .{ .permissions = perms } });
    try std.Io.Dir.cwd().rename(tmp, std.Io.Dir.cwd(), path, io);
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

fn appendJsonStr(arena: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
    try buf.append(arena, '"');
    try jsonmod.escapeInto(arena, buf, s);
    try buf.append(arena, '"');
}

/// Serialize a JSON value compactly. `redact` masks string values (used for
/// secret key paths).
fn appendValueJson(arena: std.mem.Allocator, buf: *std.ArrayList(u8), v: std.json.Value, redact: bool) std.mem.Allocator.Error!void {
    switch (v) {
        .null => try buf.appendSlice(arena, "null"),
        .bool => |b| try buf.appendSlice(arena, if (b) "true" else "false"),
        .integer => |i| try buf.appendSlice(arena, try std.fmt.allocPrint(arena, "{d}", .{i})),
        .float => |f| try buf.appendSlice(arena, try std.fmt.allocPrint(arena, "{d}", .{f})),
        .number_string => |ns| try buf.appendSlice(arena, ns),
        .string => |s| try appendJsonStr(arena, buf, if (redact) cfgmod.redactApiKey(arena, s) else s),
        .array => |arr| {
            try buf.append(arena, '[');
            for (arr.items, 0..) |item, i| {
                if (i != 0) try buf.append(arena, ',');
                try appendValueJson(arena, buf, item, redact);
            }
            try buf.append(arena, ']');
        },
        .object => |obj| {
            try buf.append(arena, '{');
            var it = obj.iterator();
            var first = true;
            while (it.next()) |e| {
                if (!first) try buf.append(arena, ',');
                first = false;
                try appendJsonStr(arena, buf, e.key_ptr.*);
                try buf.append(arena, ':');
                try appendValueJson(arena, buf, e.value_ptr.*, redact);
            }
            try buf.append(arena, '}');
        },
    }
}

/// Text-mode scalar form: strings bare, everything else as JSON.
fn appendValueText(arena: std.mem.Allocator, buf: *std.ArrayList(u8), v: std.json.Value, redact: bool) !void {
    switch (v) {
        .string => |s| try buf.appendSlice(arena, if (redact) cfgmod.redactApiKey(arena, s) else s),
        else => try appendValueJson(arena, buf, v, redact),
    }
}

// ---------------------------------------------------------------------------
// Command entry point
// ---------------------------------------------------------------------------

/// Run `tau config <set|get|unset>`. Never emits output itself — returns the
/// stdout payload or the error envelope fields for main.zig to print.
pub fn run(
    io: std.Io,
    arena: std.mem.Allocator,
    sub: Sub,
    key: []const u8,
    value_opt: ?[]const u8,
    path_opt: ?[]const u8,
    env: *std.process.Environ.Map,
    raw: bool,
    mode: cfgmod.OutputMode,
) !Outcome {
    const path = path_opt orelse (configfile.path(arena, env) orelse {
        const msg = std.fmt.allocPrint(arena, "no config path given and HOME is unset — pass a path: tau config {s} <key> <path>", .{@tagName(sub)}) catch "no config path and HOME is unset";
        return .{ .fail = .{ .code = 80, .type_name = "invalid_argument", .message = msg } };
    });

    const kp = switch (parseKeyPath(arena, key, sub == .set)) {
        .ok => |k| k,
        .fail => |f| return .{ .fail = f },
    };
    const redact = isSecretPath(kp) and !raw;

    const doc = try readDoc(io, arena, path);

    switch (sub) {
        .get => {
            const parsed = switch (doc) {
                .missing => return .{ .fail = .{ .code = 1, .type_name = "not_found", .message = try std.fmt.allocPrint(arena, "config file not found: {s} — run `tau init` or `tau config set` to create one", .{path}) } },
                .blank => return .{ .fail = .{ .code = 1, .type_name = "not_found", .message = try std.fmt.allocPrint(arena, "key \"{s}\" is not set in {s}", .{ key, path }) } },
                .invalid => |why| return .{ .fail = .{ .code = 1, .type_name = "invalid_config", .message = try std.fmt.allocPrint(arena, "config file {s}: {s}", .{ path, why }) } },
                .parsed => |p| p,
            };
            const slice = try lookupValue(arena, parsed, kp) orelse {
                return .{ .fail = .{ .code = 1, .type_name = "not_found", .message = try std.fmt.allocPrint(arena, "key \"{s}\" is not set in {s}", .{ key, path }) } };
            };
            const val = std.json.parseFromSliceLeaky(std.json.Value, arena, configfile.stripComments(arena, slice) catch slice, .{}) catch {
                return .{ .fail = .{ .code = 1, .type_name = "invalid_config", .message = try std.fmt.allocPrint(arena, "value of \"{s}\" in {s} is not valid JSON", .{ key, path }) } };
            };
            return .{ .ok = try renderGet(arena, path, key, val, redact, mode) };
        },
        .set => {
            const token = switch (try coerceValue(arena, kp, value_opt.?)) {
                .ok => |t| t,
                .fail => |f| return .{ .fail = f },
            };
            const src: []const u8 = switch (doc) {
                .invalid => |why| return .{ .fail = .{ .code = 1, .type_name = "invalid_config", .message = try std.fmt.allocPrint(arena, "config file {s}: {s}", .{ path, why }) } },
                .missing => "{}\n",
                // Blank (whitespace/comments only): append an empty object so
                // the existing comment header survives.
                .blank => |b| if (b.len == 0)
                    "{}\n"
                else if (b[b.len - 1] == '\n')
                    try std.fmt.allocPrint(arena, "{s}{{\n}}\n", .{b})
                else
                    try std.fmt.allocPrint(arena, "{s}\n{{\n}}\n", .{b}),
                .parsed => |p| p.bytes,
            };
            const created = doc != .parsed;
            const obj = try scanDoc(arena, src);
            const new_bytes = applySet(arena, src, obj, kp, token) catch |err| {
                if (err == error.KeysNotObject) {
                    return .{ .fail = .{ .code = 1, .type_name = "invalid_config", .message = try std.fmt.allocPrint(arena, "\"keys\" is not a JSON object in {s} — fix or remove it first", .{path}) } };
                }
                return err;
            };
            if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| {
                std.Io.Dir.cwd().createDirPath(io, path[0..idx]) catch {};
            }
            try writeAtomic(io, arena, path, new_bytes);
            return .{ .ok = try renderSet(arena, path, key, token, redact, created, mode) };
        },
        .unset => {
            const parsed = switch (doc) {
                .missing => return .{ .fail = .{ .code = 1, .type_name = "not_found", .message = try std.fmt.allocPrint(arena, "config file not found: {s} — run `tau init` or `tau config set` to create one", .{path}) } },
                .blank => return .{ .fail = .{ .code = 1, .type_name = "not_found", .message = try std.fmt.allocPrint(arena, "key \"{s}\" is not set in {s}", .{ key, path }) } },
                .invalid => |why| return .{ .fail = .{ .code = 1, .type_name = "invalid_config", .message = try std.fmt.allocPrint(arena, "config file {s}: {s}", .{ path, why }) } },
                .parsed => |p| p,
            };
            const new_bytes = (applyUnset(arena, parsed, kp) catch |err| {
                if (err == error.KeysNotObject) {
                    return .{ .fail = .{ .code = 1, .type_name = "invalid_config", .message = try std.fmt.allocPrint(arena, "\"keys\" is not a JSON object in {s} — fix or remove it first", .{path}) } };
                }
                return err;
            }) orelse {
                return .{ .fail = .{ .code = 1, .type_name = "not_found", .message = try std.fmt.allocPrint(arena, "key \"{s}\" is not set in {s}", .{ key, path }) } };
            };
            try writeAtomic(io, arena, path, new_bytes);
            return .{ .ok = try renderUnset(arena, path, key, mode) };
        },
    }
}

/// Locate the raw value slice for `kp` inside a scanned document (comments
/// intact). Follows `keys.<name>` into the `keys` object.
fn lookupValue(arena: std.mem.Allocator, parsed: anytype, kp: KeyPath) !?[]const u8 {
    switch (kp) {
        .field => |name| {
            const i = findMember(parsed.obj, name) orelse return null;
            return parsed.bytes[parsed.obj.members[i].value_start..parsed.obj.members[i].value_end];
        },
        .keys_entry => |pname| {
            const i = findMember(parsed.obj, "keys") orelse return null;
            const m = parsed.obj.members[i];
            if (parsed.bytes[m.value_start] != '{') return null;
            const inner = try scanObj(arena, parsed.bytes, m.value_start);
            const j = findMember(inner, pname) orelse return null;
            return parsed.bytes[inner.members[j].value_start..inner.members[j].value_end];
        },
    }
}

fn applySet(arena: std.mem.Allocator, bytes: []const u8, obj: Obj, kp: KeyPath, token: []const u8) ![]u8 {
    switch (kp) {
        .field => |name| {
            if (findMember(obj, name)) |i| {
                const m = obj.members[i];
                return splice(arena, bytes, m.value_start, m.value_end, token);
            }
            return insertMember(arena, bytes, obj, name, token);
        },
        .keys_entry => |pname| {
            if (findMember(obj, "keys")) |i| {
                const m = obj.members[i];
                if (bytes[m.value_start] != '{') {
                    return error.KeysNotObject;
                }
                const inner = try scanObj(arena, bytes, m.value_start);
                if (findMember(inner, pname)) |j| {
                    const im = inner.members[j];
                    return splice(arena, bytes, im.value_start, im.value_end, token);
                }
                // Insert inside the existing keys object (inner offsets are
                // absolute positions in `bytes`).
                return insertMember(arena, bytes, inner, pname, token);
            }
            // No keys object yet: add `"keys": { "<p>": token }`.
            var tok: std.ArrayList(u8) = .empty;
            try tok.appendSlice(arena, "{ \"");
            try jsonmod.escapeInto(arena, &tok, pname);
            try tok.appendSlice(arena, "\": ");
            try tok.appendSlice(arena, token);
            try tok.appendSlice(arena, " }");
            return insertMember(arena, bytes, obj, "keys", tok.items);
        },
    }
}

/// Remove every occurrence of `kp` (duplicates included). Returns null when
/// the key is absent.
fn applyUnset(arena: std.mem.Allocator, parsed: anytype, kp: KeyPath) !?[]const u8 {
    switch (kp) {
        .field => |name| {
            var bytes = parsed.bytes;
            var removed = false;
            while (true) {
                const obj = try scanDoc(arena, bytes);
                const i = findMember(obj, name) orelse break;
                const span = removalSpan(bytes, obj.members[i]);
                bytes = try splice(arena, bytes, span.start, span.end, "");
                removed = true;
            }
            return if (removed) bytes else null;
        },
        .keys_entry => |pname| {
            var bytes = parsed.bytes;
            var removed = false;
            while (true) {
                const obj = try scanDoc(arena, bytes);
                const i = findMember(obj, "keys") orelse break;
                const m = obj.members[i];
                if (bytes[m.value_start] != '{') return error.KeysNotObject;
                const inner = try scanObj(arena, bytes, m.value_start);
                const j = findMember(inner, pname) orelse break;
                const span = removalSpan(bytes, inner.members[j]);
                bytes = try splice(arena, bytes, span.start, span.end, "");
                removed = true;
            }
            return if (removed) bytes else null;
        },
    }
}

// ---------------------------------------------------------------------------
// Output envelopes
// ---------------------------------------------------------------------------

fn renderGet(arena: std.mem.Allocator, path: []const u8, key: []const u8, val: std.json.Value, redact: bool, mode: cfgmod.OutputMode) ![]u8 {
    var b: std.ArrayList(u8) = .empty;
    if (mode == .text) {
        try appendValueText(arena, &b, val, redact);
        try b.append(arena, '\n');
        return b.toOwnedSlice(arena);
    }
    try b.appendSlice(arena, "{\"path\":");
    try appendJsonStr(arena, &b, path);
    try b.appendSlice(arena, ",\"key\":");
    try appendJsonStr(arena, &b, key);
    try b.appendSlice(arena, ",\"set\":true,\"value\":");
    try appendValueJson(arena, &b, val, redact);
    if (redact) try b.appendSlice(arena, ",\"redacted\":true");
    try b.appendSlice(arena, "}\n");
    return b.toOwnedSlice(arena);
}

fn renderSet(arena: std.mem.Allocator, path: []const u8, key: []const u8, token: []const u8, redact: bool, created: bool, mode: cfgmod.OutputMode) ![]u8 {
    var b: std.ArrayList(u8) = .empty;
    const val = std.json.parseFromSliceLeaky(std.json.Value, arena, token, .{}) catch std.json.Value{ .string = token };
    if (mode == .text) {
        try b.appendSlice(arena, path);
        try b.appendSlice(arena, ": \"");
        try b.appendSlice(arena, key);
        try b.appendSlice(arena, "\" = ");
        try appendValueText(arena, &b, val, redact);
        try b.append(arena, '\n');
        return b.toOwnedSlice(arena);
    }
    try b.appendSlice(arena, "{\"ok\":true,\"path\":");
    try appendJsonStr(arena, &b, path);
    try b.appendSlice(arena, ",\"key\":");
    try appendJsonStr(arena, &b, key);
    try b.appendSlice(arena, ",\"value\":");
    try appendValueJson(arena, &b, val, redact);
    try b.appendSlice(arena, ",\"created\":");
    try b.appendSlice(arena, if (created) "true" else "false");
    if (redact) try b.appendSlice(arena, ",\"redacted\":true");
    try b.appendSlice(arena, "}\n");
    return b.toOwnedSlice(arena);
}

fn renderUnset(arena: std.mem.Allocator, path: []const u8, key: []const u8, mode: cfgmod.OutputMode) ![]u8 {
    var b: std.ArrayList(u8) = .empty;
    if (mode == .text) {
        try b.appendSlice(arena, path);
        try b.appendSlice(arena, ": \"");
        try b.appendSlice(arena, key);
        try b.appendSlice(arena, "\" removed\n");
        return b.toOwnedSlice(arena);
    }
    try b.appendSlice(arena, "{\"ok\":true,\"path\":");
    try appendJsonStr(arena, &b, path);
    try b.appendSlice(arena, ",\"key\":");
    try appendJsonStr(arena, &b, key);
    try b.appendSlice(arena, ",\"removed\":true}\n");
    return b.toOwnedSlice(arena);
}

// ---------------------------------------------------------------------------
// `tau config edit` — interactive edit via $EDITOR, schema-checked on save
// ---------------------------------------------------------------------------

/// Outcome of `config edit`: `ok`/`invalid` carry a stdout payload (success
/// object or validation report — the command's result, like
/// `config validate`); `fail` carries an {"err"} envelope for stderr.
pub const EditOutcome = union(enum) {
    ok: []const u8,
    invalid: []const u8,
    fail: Fail,
};

/// Resolve the editor command: $TAU_EDITOR > $VISUAL > $EDITOR > platform
/// fallback (vi / notepad) — git's editor-precedence model. Empty env values
/// are skipped. The command may carry args (`EDITOR="code --wait"`); it runs
/// through the system shell.
fn editorCommand(env: *std.process.Environ.Map) []const u8 {
    for ([_][]const u8{ "TAU_EDITOR", "VISUAL", "EDITOR" }) |name| {
        if (env.get(name)) |v| {
            if (v.len > 0) return v;
        }
    }
    return if (builtin.os.tag == .windows) "notepad" else "vi";
}

/// Spawn `editor` on `path` through the system shell so commands with args
/// work (`sh -c '<editor> "$@"'` — git's trick). stdio is inherited so
/// full-screen editors get the tty.
fn launchEditor(io: std.Io, arena: std.mem.Allocator, editor: []const u8, path: []const u8) !std.process.Child.Term {
    const argv: []const []const u8 = if (builtin.os.tag == .windows)
        &.{ "cmd", "/C", try std.fmt.allocPrint(arena, "{s} \"{s}\"", .{ editor, path }) }
    else
        &.{ "sh", "-c", try std.fmt.allocPrint(arena, "{s} \"$@\"", .{editor}), editor, path };
    var child = try std.process.spawn(io, .{ .argv = argv });
    return child.wait(io);
}

/// `tau config edit [path]` — open the config file in the user's editor, then
/// validate the result with the same checks `config validate` runs (including
/// did-you-mean hints on misspelled keys). A missing file is seeded with the
/// commented `tau init` scaffold first.
pub fn runEditor(
    io: std.Io,
    arena: std.mem.Allocator,
    path_opt: ?[]const u8,
    env: *std.process.Environ.Map,
    mode: cfgmod.OutputMode,
) !EditOutcome {
    const path = path_opt orelse (configfile.path(arena, env) orelse {
        return .{ .fail = .{ .code = 80, .type_name = "invalid_argument", .message = "no config path given and HOME is unset — pass a path: tau config edit <path>" } };
    });

    var created = false;
    const missing = blk: {
        _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| break :blk err == error.FileNotFound;
        break :blk false;
    };
    if (missing) {
        const initmod = @import("init.zig");
        const det = try initmod.detectKeys(arena, env);
        const body = try initmod.renderConfig(arena, det, initmod.pickProvider(det, null));
        if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| {
            std.Io.Dir.cwd().createDirPath(io, path[0..idx]) catch {};
        }
        try writeAtomic(io, arena, path, body);
        created = true;
    }

    const editor = editorCommand(env);
    const editor_term = launchEditor(io, arena, editor, path) catch |err| {
        const msg = std.fmt.allocPrint(arena, "could not launch editor \"{s}\" ({s}) — set TAU_EDITOR, VISUAL, or EDITOR to an installed editor", .{ editor, @errorName(err) }) catch "could not launch editor";
        return .{ .fail = .{ .code = 1, .type_name = "editor_failed", .message = msg } };
    };
    switch (editor_term) {
        .exited => |code| {
            if (code != 0) {
                const msg = std.fmt.allocPrint(arena, "editor \"{s}\" exited with status {d}", .{ editor, code }) catch "editor exited non-zero";
                return .{ .fail = .{ .code = 1, .type_name = "editor_failed", .message = msg } };
            }
        },
        .signal, .stopped => |sig| {
            const msg = std.fmt.allocPrint(arena, "editor \"{s}\" was killed by signal {s}", .{ editor, @tagName(sig) }) catch "editor killed by signal";
            return .{ .fail = .{ .code = 1, .type_name = "editor_failed", .message = msg } };
        },
        .unknown => |code| {
            const msg = std.fmt.allocPrint(arena, "editor \"{s}\" exited abnormally ({d})", .{ editor, code }) catch "editor exited abnormally";
            return .{ .fail = .{ .code = 1, .type_name = "editor_failed", .message = msg } };
        },
    }

    // Validate whatever the editor left behind. The report shape (and the
    // stdout channel) matches `config validate`; on failure the file stays on
    // disk so the user can rerun `tau config edit` and fix the listed issues.
    const cval = @import("configvalidate.zig");
    const report = cval.validate(io, arena, path) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .fail = .{ .code = 110, .type_name = "internal_error", .message = "config validation failed" } };
    };
    if (!report.ok()) {
        const out = if (mode == .text)
            try cval.formatText(arena, report)
        else
            try cval.formatJson(arena, report);
        return .{ .invalid = out };
    }
    return .{ .ok = try renderEditOk(arena, path, editor, created, mode) };
}

fn renderEditOk(arena: std.mem.Allocator, path: []const u8, editor: []const u8, created: bool, mode: cfgmod.OutputMode) ![]u8 {
    var b: std.ArrayList(u8) = .empty;
    if (mode == .text) {
        try b.appendSlice(arena, path);
        try b.appendSlice(arena, ": ok\n");
        return b.toOwnedSlice(arena);
    }
    try b.appendSlice(arena, "{\"ok\":true,\"path\":");
    try appendJsonStr(arena, &b, path);
    try b.appendSlice(arena, ",\"editor\":");
    try appendJsonStr(arena, &b, editor);
    try b.appendSlice(arena, ",\"created\":");
    try b.appendSlice(arena, if (created) "true" else "false");
    try b.appendSlice(arena, ",\"valid\":true}\n");
    return b.toOwnedSlice(arena);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
const testing = std.testing;

fn testArena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(testing.allocator);
}

/// Apply set/unset against an in-memory doc; return the new bytes.
fn setOn(arena: std.mem.Allocator, bytes: []const u8, key: []const u8, token: []const u8) ![]u8 {
    const kp = (parseKeyPath(arena, key, true)).ok;
    const obj = try scanDoc(arena, bytes);
    return applySet(arena, bytes, obj, kp, token);
}

fn unsetOn(arena: std.mem.Allocator, bytes: []const u8, key: []const u8) !?[]const u8 {
    const kp = (parseKeyPath(arena, key, false)).ok;
    return applyUnset(arena, .{ .bytes = bytes, .obj = try scanDoc(arena, bytes) }, kp);
}

test "scanDoc: parses members with comments and finds value spans" {
    var ar = testArena();
    defer ar.deinit();
    const arena = ar.allocator();
    const src =
        \\{
        \\  // leading comment
        \\  "provider": "openai", /* inline */
        \\  "stream": true,
        \\  "keys": { "openai": "sk-x // not a comment" }
        \\}
    ;
    const obj = try scanDoc(arena, src);
    try testing.expectEqual(@as(usize, 3), obj.members.len);
    const i = findMember(obj, "provider").?;
    try testing.expectEqualStrings("\"openai\"", src[obj.members[i].value_start..obj.members[i].value_end]);
    const j = findMember(obj, "stream").?;
    try testing.expectEqualStrings("true", src[obj.members[j].value_start..obj.members[j].value_end]);
}

test "scanDoc: rejects non-object and trailing garbage" {
    var ar = testArena();
    defer ar.deinit();
    const arena = ar.allocator();
    try testing.expectError(error.InvalidJson, scanDoc(arena, "[1,2]"));
    try testing.expectError(error.InvalidJson, scanDoc(arena, "{} extra"));
    try testing.expectError(error.InvalidJson, scanDoc(arena, "{\"a\":}"));
}

test "set: replaces an existing value and preserves comments" {
    var ar = testArena();
    defer ar.deinit();
    const arena = ar.allocator();
    const src = "{\n  // keep me\n  \"provider\": \"xiaomi\",\n  \"mode\": \"json\"\n}\n";
    const out = try setOn(arena, src, "provider", "\"openai\"");
    try testing.expectEqualStrings("{\n  // keep me\n  \"provider\": \"openai\",\n  \"mode\": \"json\"\n}\n", out);
}

test "set: inserts a new member with matching indentation" {
    var ar = testArena();
    defer ar.deinit();
    const arena = ar.allocator();
    const out = try setOn(arena, "{\n  \"provider\": \"xiaomi\"\n}\n", "mode", "\"text\"");
    try testing.expectEqualStrings("{\n  \"provider\": \"xiaomi\",\n  \"mode\": \"text\"\n}\n", out);
    // Single-line object stays single-line.
    const out2 = try setOn(arena, "{\"a\":1}", "mode", "\"json\"");
    try testing.expectEqualStrings("{\"a\":1, \"mode\": \"json\"}", out2);
}

test "set: fills an empty object and an empty file" {
    var ar = testArena();
    defer ar.deinit();
    const arena = ar.allocator();
    const out = try setOn(arena, "{}", "provider", "\"openai\"");
    try testing.expectEqualStrings("{\n  \"provider\": \"openai\"\n}", out);
}

test "set: writes into keys.<provider>, creating or extending the map" {
    var ar = testArena();
    defer ar.deinit();
    const arena = ar.allocator();
    // No keys object yet.
    const out = try setOn(arena, "{\n  \"provider\": \"xiaomi\"\n}", "keys.openai", "\"sk-1\"");
    try testing.expectEqualStrings("{\n  \"provider\": \"xiaomi\",\n  \"keys\": { \"openai\": \"sk-1\" }\n}", out);
    // Extends an existing keys object.
    const out2 = try setOn(arena, "{\n  \"keys\": {\n    \"openai\": \"sk-1\"\n  }\n}", "keys.deepseek", "\"sk-2\"");
    try testing.expectEqualStrings("{\n  \"keys\": {\n    \"openai\": \"sk-1\",\n    \"deepseek\": \"sk-2\"\n  }\n}", out2);
    // Replaces an existing entry.
    const out3 = try setOn(arena, out2, "keys.openai", "\"sk-new\"");
    try testing.expect(std.mem.indexOf(u8, out3, "\"openai\": \"sk-new\"") != null);
    try testing.expect(std.mem.indexOf(u8, out3, "sk-2") != null);
    // keys present but not an object.
    try testing.expectError(error.KeysNotObject, setOn(arena, "{\"keys\": 5}", "keys.openai", "\"sk\""));
}

test "unset: removes members and commas correctly" {
    var ar = testArena();
    defer ar.deinit();
    const arena = ar.allocator();
    const src = "{\n  \"a\": 1,\n  \"b\": 2,\n  \"c\": 3\n}\n";
    // First member (trailing comma).
    try testing.expectEqualStrings("{\n  \"b\": 2,\n  \"c\": 3\n}\n", (try unsetOn(arena, src, "a")).?);
    // Middle member.
    try testing.expectEqualStrings("{\n  \"a\": 1,\n  \"c\": 3\n}\n", (try unsetOn(arena, src, "b")).?);
    // Last member (leading comma).
    try testing.expectEqualStrings("{\n  \"a\": 1,\n  \"b\": 2\n}\n", (try unsetOn(arena, src, "c")).?);
    // Only member -> empty object.
    try testing.expectEqualStrings("{\n}\n", (try unsetOn(arena, "{\n  \"a\": 1\n}\n", "a")).?);
    try testing.expectEqualStrings("{}", (try unsetOn(arena, "{\"a\":1}", "a")).?);
    // Single line, first of two.
    try testing.expectEqualStrings("{\"b\":2}", (try unsetOn(arena, "{\"a\":1,\"b\":2}", "a")).?);
    // Single line, last of two.
    try testing.expectEqualStrings("{\"a\":1}", (try unsetOn(arena, "{\"a\":1,\"b\":2}", "b")).?);
    // Missing key -> null.
    try testing.expectEqual(@as(?[]u8, null), try unsetOn(arena, src, "zzz"));
}

test "unset: removes every duplicate occurrence" {
    var ar = testArena();
    defer ar.deinit();
    const arena = ar.allocator();
    const out = (try unsetOn(arena, "{\"a\":1,\"a\":2,\"b\":3}", "a")).?;
    try testing.expectEqualStrings("{\"b\":3}", out);
}

test "unset: keys.<provider> leaves a valid object" {
    var ar = testArena();
    defer ar.deinit();
    const arena = ar.allocator();
    const src = "{\n  \"keys\": {\n    \"openai\": \"sk-1\",\n    \"deepseek\": \"sk-2\"\n  }\n}";
    const out = (try unsetOn(arena, src, "keys.openai")).?;
    try testing.expectEqualStrings("{\n  \"keys\": {\n    \"deepseek\": \"sk-2\"\n  }\n}", out);
    // Last entry -> empty keys object (still valid config).
    const out2 = (try unsetOn(arena, src, "keys.deepseek")).?;
    const out3 = (try unsetOn(arena, out2, "keys.openai")).?;
    try testing.expectEqualStrings("{\n  \"keys\": {\n  }\n}", out3);
}

test "parseKeyPath: dotted addressing rules" {
    var ar = testArena();
    defer ar.deinit();
    const arena = ar.allocator();
    try testing.expect((parseKeyPath(arena, "provider", true)) == .ok);
    try testing.expectEqualStrings("openai", (parseKeyPath(arena, "keys.openai", false)).ok.keys_entry);
    try testing.expect((parseKeyPath(arena, "bogus", false)) == .ok); // get/unset allow unknown keys
    try testing.expect((parseKeyPath(arena, "bogus", true)) == .fail); // set is schema-checked
    try testing.expect((parseKeyPath(arena, "a.b.c", false)) == .fail);
    try testing.expect((parseKeyPath(arena, "other.x", false)) == .fail);
    try testing.expect((parseKeyPath(arena, "keys.", false)) == .fail);
}

test "coerceValue: type coercion mirrors config validate" {
    var ar = testArena();
    defer ar.deinit();
    const arena = ar.allocator();
    const ok = struct {
        fn get(r: Coerced) []const u8 {
            return switch (r) {
                .ok => |t| t,
                .fail => |f| @panic(f.message),
            };
        }
    }.get;
    try testing.expectEqualStrings("\"text\"", ok(try coerceValue(arena, .{ .field = "mode" }, "text")));
    try testing.expectEqualStrings("true", ok(try coerceValue(arena, .{ .field = "stream" }, "true")));
    try testing.expectEqualStrings("4096", ok(try coerceValue(arena, .{ .field = "max_tokens" }, "4096")));
    try testing.expectEqualStrings("0.5", ok(try coerceValue(arena, .{ .field = "temperature" }, "0.5")));
    try testing.expectEqualStrings("\"sk-1\"", ok(try coerceValue(arena, .{ .keys_entry = "openai" }, "sk-1")));

    const fails = struct {
        fn is(r: Coerced) bool {
            return r == .fail;
        }
    }.is;
    try testing.expect(fails(try coerceValue(arena, .{ .field = "provider" }, "nope")));
    try testing.expect(fails(try coerceValue(arena, .{ .field = "mode" }, "yaml")));
    try testing.expect(fails(try coerceValue(arena, .{ .field = "stream" }, "yes")));
    try testing.expect(fails(try coerceValue(arena, .{ .field = "max_tokens" }, "-1")));
    try testing.expect(fails(try coerceValue(arena, .{ .field = "max_tokens" }, "9999999999")));
    try testing.expect(fails(try coerceValue(arena, .{ .field = "compact_threshold" }, "1.5")));
    try testing.expect(fails(try coerceValue(arena, .{ .field = "temperature" }, "nan")));
    try testing.expect(fails(try coerceValue(arena, .{ .field = "api_key" }, "")));
    try testing.expect(fails(try coerceValue(arena, .{ .keys_entry = "notaprovider" }, "sk")));
    try testing.expect(fails(try coerceValue(arena, .{ .field = "keys" }, "{\"bogus\":\"x\"}")));
    try testing.expect((try coerceValue(arena, .{ .field = "keys" }, "{\"openai\":\"x\"}")) == .ok);
}

test "lookupValue: finds values incl. inside keys (comments tolerated)" {
    var ar = testArena();
    defer ar.deinit();
    const arena = ar.allocator();
    const src = "{\n  \"keys\": { // per-provider\n    \"openai\": \"sk-x\"\n  }\n}";
    const obj = try scanDoc(arena, src);
    const P = struct { bytes: []const u8, obj: Obj };
    const slice = (try lookupValue(arena, P{ .bytes = src, .obj = obj }, .{ .keys_entry = "openai" })).?;
    try testing.expectEqualStrings("\"sk-x\"", slice);
}

test "writeAtomic: writes a file and preserves content" {
    var ar = testArena();
    defer ar.deinit();
    const arena = ar.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/config.json", .{tmp.sub_path[0..]});
    try writeAtomic(testing.io, arena, path, "{\n  \"a\": 1\n}\n");
    const back = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, arena, .unlimited);
    try testing.expectEqualStrings("{\n  \"a\": 1\n}\n", back);
}

test "editorCommand: TAU_EDITOR > VISUAL > EDITOR > platform default" {
    var ar = testArena();
    defer ar.deinit();
    const arena = ar.allocator();

    var env = std.process.Environ.Map.init(arena);
    try testing.expectEqualStrings(if (builtin.os.tag == .windows) "notepad" else "vi", editorCommand(&env));

    try env.put("EDITOR", "ed");
    try env.put("VISUAL", "vis");
    try testing.expectEqualStrings("vis", editorCommand(&env));
    try env.put("TAU_EDITOR", "tau-ed");
    try testing.expectEqualStrings("tau-ed", editorCommand(&env));
    // Empty values are skipped.
    try env.put("TAU_EDITOR", "");
    try testing.expectEqualStrings("vis", editorCommand(&env));
}

test "runEditor: seeds the init scaffold, runs the editor, reports ok" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // sh -c is POSIX
    var ar = testArena();
    defer ar.deinit();
    const arena = ar.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/nested/config.json", .{tmp.sub_path[0..]});

    var env = std.process.Environ.Map.init(arena);
    try env.put("TAU_EDITOR", "true"); // exits 0, leaves the scaffold untouched
    const outcome = try runEditor(testing.io, arena, path, &env, .json);
    const out = switch (outcome) {
        .ok => |s| s,
        .invalid => |s| @panic(s),
        .fail => |f| @panic(f.message),
    };
    try testing.expect(std.mem.indexOf(u8, out, "\"created\":true") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"valid\":true") != null);
    // The scaffold on disk is the commented JSONC starter.
    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, arena, .unlimited);
    try testing.expect(std.mem.indexOf(u8, bytes, "//") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"provider\"") != null);
}

test "runEditor: invalid save reports issues on stdout payload with did-you-mean" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var ar = testArena();
    defer ar.deinit();
    const arena = ar.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/config.json", .{tmp.sub_path[0..]});
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = "{}\n" });

    var env = std.process.Environ.Map.init(arena);
    // "Editor" that overwrites the config with a misspelled key.
    try env.put("TAU_EDITOR", "printf '{\"proivder\":\"openai\"}' >");
    const outcome = try runEditor(testing.io, arena, path, &env, .json);
    const out = switch (outcome) {
        .invalid => |s| s,
        .ok => |s| @panic(s),
        .fail => |f| @panic(f.message),
    };
    try testing.expect(std.mem.indexOf(u8, out, "\"ok\":false") != null);
    try testing.expect(std.mem.indexOf(u8, out, "not a tau config key") != null);
    try testing.expect(std.mem.indexOf(u8, out, "did you mean \\\"provider\\\"?") != null);
    // The bad edit stays on disk — the user reruns edit/validate to fix it.
    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, arena, .unlimited);
    try testing.expectEqualStrings("{\"proivder\":\"openai\"}", bytes);
}

test "runEditor: editor exit non-zero is an editor_failed envelope" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var ar = testArena();
    defer ar.deinit();
    const arena = ar.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/config.json", .{tmp.sub_path[0..]});
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = "{}\n" });

    var env = std.process.Environ.Map.init(arena);
    try env.put("TAU_EDITOR", "false");
    const outcome = try runEditor(testing.io, arena, path, &env, .json);
    switch (outcome) {
        .fail => |f| {
            try testing.expectEqual(@as(u8, 1), f.code);
            try testing.expectEqualStrings("editor_failed", f.type_name);
            try testing.expect(std.mem.indexOf(u8, f.message, "status 1") != null);
        },
        else => @panic("expected editor_failed"),
    }
}

test "runEditor: no path and no HOME is an argument error" {
    var ar = testArena();
    defer ar.deinit();
    const arena = ar.allocator();
    var env = std.process.Environ.Map.init(arena);
    const outcome = try runEditor(testing.io, arena, null, &env, .json);
    switch (outcome) {
        .fail => |f| try testing.expectEqual(@as(u8, 80), f.code),
        else => @panic("expected invalid_argument"),
    }
}
