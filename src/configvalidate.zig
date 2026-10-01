//! `tau config validate` — offline validation of a tau config file for CI and
//! pre-commit hooks. Checks are derived at comptime from `configfile.FileConfig`
//! (the same struct the loader parses into), so the validator can't drift from
//! the real schema. It is intentionally *stricter* than the loader: the loader
//! ignores unknown keys and `null` values, while the validator reports them —
//! they are almost always typos or dead config.
//!
//! Validation is fully offline: no network, no env var reads, no key probing.

const std = @import("std");
const cfgmod = @import("config.zig");
const configfile = @import("configfile.zig");
const json = @import("json.zig");

/// One validation problem. `key` is the offending config key when the issue is
/// tied to one (`"provider"`, `"keys.openai"`); null for file-level problems
/// (unreadable file, invalid JSON, non-object top level).
pub const Issue = struct {
    key: ?[]const u8 = null,
    message: []const u8,
};

pub const Report = struct {
    path: []const u8,
    issues: []const Issue,

    pub fn ok(self: Report) bool {
        return self.issues.len == 0;
    }
};

// Comptime view of the file schema.
const file_fields = @typeInfo(configfile.FileConfig).@"struct".fields;

/// Expected JSON value kind for a FileConfig field type.
const Kind = enum { string, boolean, integer, number, any_json };

fn fieldKind(comptime T: type) Kind {
    return switch (innerType(T)) {
        []const u8 => .string,
        bool => .boolean,
        u32, u64, usize, i32, i64 => .integer,
        f32, f64 => .number,
        else => .any_json,
    };
}

fn innerType(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .optional => |o| o.child,
        else => T,
    };
}

/// Human name for a JSON value's kind, used in "expected X, got Y" messages.
fn kindName(v: std.json.Value) []const u8 {
    return switch (v) {
        .null => "null",
        .bool => "a boolean",
        .integer, .float, .number_string => "a number",
        .string => "a string",
        .array => "an array",
        .object => "an object",
    };
}

fn asNumber(v: std.json.Value) ?f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => null,
    };
}

fn addIssue(arena: std.mem.Allocator, issues: *std.ArrayList(Issue), key: ?[]const u8, comptime fmt: []const u8, args: anytype) !void {
    try issues.append(arena, .{ .key = key, .message = try std.fmt.allocPrint(arena, fmt, args) });
}

/// Comma-separated provider names for "valid providers: ..." hints.
fn providerNames(arena: std.mem.Allocator) ![]const u8 {
    var b: std.ArrayList(u8) = .empty;
    for (cfgmod.providers, 0..) |p, i| {
        if (i != 0) try b.appendSlice(arena, ", ");
        try b.appendSlice(arena, p.name);
    }
    return b.toOwnedSlice(arena);
}

/// Validate one known key's value against its FileConfig field type, then run
/// the value-level checks the type alone can't express. `field` is comptime —
/// the checks below compile down to only what each field needs.
fn checkKnownField(
    arena: std.mem.Allocator,
    issues: *std.ArrayList(Issue),
    comptime field: std.builtin.Type.StructField,
    val: std.json.Value,
) !void {
    const name = field.name;
    switch (comptime fieldKind(field.type)) {
        .string => {
            if (val != .string) {
                try addIssue(arena, issues, name, "\"{s}\" must be a string, got {s}", .{ name, kindName(val) });
                return;
            }
            if (comptime std.mem.eql(u8, name, "provider")) {
                if (cfgmod.findProvider(val.string) == null) {
                    try addIssue(arena, issues, name, "\"provider\" is not a known provider: \"{s}\" — valid providers: {s}", .{ val.string, try providerNames(arena) });
                }
            } else if (comptime std.mem.eql(u8, name, "mode")) {
                if (!std.mem.eql(u8, val.string, "text") and !std.mem.eql(u8, val.string, "json")) {
                    try addIssue(arena, issues, name, "\"mode\" must be \"text\" or \"json\", got \"{s}\"", .{val.string});
                }
            } else if (comptime std.mem.eql(u8, name, "api_key")) {
                if (val.string.len == 0) {
                    try addIssue(arena, issues, name, "\"api_key\" is an empty string — remove it or set a key (empty keys are ignored)", .{});
                }
            }
        },
        .boolean => {
            if (val != .bool) {
                try addIssue(arena, issues, name, "\"{s}\" must be a boolean (true/false), got {s}", .{ name, kindName(val) });
            }
        },
        .integer => {
            const v: i64 = switch (val) {
                .integer => |i| i,
                .number_string => |ns| std.fmt.parseInt(i64, ns, 10) catch {
                    try addIssue(arena, issues, name, "\"{s}\" is out of range for an integer", .{name});
                    return;
                },
                else => {
                    try addIssue(arena, issues, name, "\"{s}\" must be an integer, got {s}", .{ name, kindName(val) });
                    return;
                },
            };
            // Every current integer config key is a size/count/limit — negative
            // values are always invalid.
            if (v < 0) {
                try addIssue(arena, issues, name, "\"{s}\" must be >= 0, got {d}", .{ name, v });
                return;
            }
            const inner = innerType(field.type);
            if (comptime @typeInfo(inner).int.bits < 64) {
                if (v > std.math.maxInt(inner)) {
                    try addIssue(arena, issues, name, "\"{s}\" must be <= {d}, got {d}", .{ name, std.math.maxInt(inner), v });
                }
            }
        },
        .number => {
            const n = asNumber(val) orelse {
                if (val == .number_string) {
                    try addIssue(arena, issues, name, "\"{s}\" is out of range for a finite number", .{name});
                } else {
                    try addIssue(arena, issues, name, "\"{s}\" must be a number, got {s}", .{ name, kindName(val) });
                }
                return;
            };
            if (comptime std.mem.eql(u8, name, "temperature")) {
                if (n < 0) try addIssue(arena, issues, name, "\"temperature\" must be >= 0, got {d}", .{n});
            } else if (comptime std.mem.eql(u8, name, "compact_threshold")) {
                if (n < 0 or n > 1) try addIssue(arena, issues, name, "\"compact_threshold\" must be between 0 and 1, got {d}", .{n});
            }
        },
        .any_json => {
            // `keys` is the only free-form field: object of provider → api key.
            if (comptime std.mem.eql(u8, name, "keys")) {
                if (val != .object) {
                    try addIssue(arena, issues, name, "\"keys\" must be an object mapping provider names to API keys, got {s}", .{kindName(val)});
                    return;
                }
                var kit = val.object.iterator();
                while (kit.next()) |e| {
                    const pname = e.key_ptr.*;
                    const kkey = try std.fmt.allocPrint(arena, "keys.{s}", .{pname});
                    if (e.value_ptr.* != .string) {
                        try addIssue(arena, issues, kkey, "\"keys.{s}\" must be a string (an API key), got {s}", .{ pname, kindName(e.value_ptr.*) });
                    } else if (e.value_ptr.*.string.len == 0) {
                        try addIssue(arena, issues, kkey, "\"keys.{s}\" is an empty string — remove it or set a key", .{pname});
                    } else if (cfgmod.findProvider(pname) == null) {
                        try addIssue(arena, issues, kkey, "\"keys.{s}\" is not a known provider — valid providers: {s}", .{ pname, try providerNames(arena) });
                    }
                }
            }
        },
    }
}

/// Validate the config file at `path`. Never fails for *content* problems —
/// they are collected into `report.issues`. Only allocation failure propagates
/// as an error.
pub fn validate(io: std.Io, arena: std.mem.Allocator, path: []const u8) !Report {
    var issues: std.ArrayList(Issue) = .empty;

    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited) catch |err| {
        const why: []const u8 = switch (err) {
            error.FileNotFound => "file not found — run `tau init` to create one, or pass a path: tau config validate <path>",
            error.AccessDenied => "permission denied",
            else => @errorName(err),
        };
        try addIssue(arena, &issues, null, "cannot read config file {s}: {s}", .{ path, why });
        return .{ .path = path, .issues = issues.items };
    };

    // Parse with diagnostics so syntax errors get a line/column.
    var scanner = std.json.Scanner.initCompleteInput(arena, bytes);
    defer scanner.deinit();
    var diag: std.json.Diagnostics = .{};
    scanner.enableDiagnostics(&diag);
    const value = std.json.parseFromTokenSourceLeaky(std.json.Value, arena, &scanner, .{}) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        try addIssue(arena, &issues, null, "invalid JSON at line {d}, column {d}: {s} — fix the syntax or regenerate with `tau init`", .{ diag.getLine(), diag.getColumn(), @errorName(err) });
        return .{ .path = path, .issues = issues.items };
    };

    if (value != .object) {
        try addIssue(arena, &issues, null, "top level must be a JSON object, got {s}", .{kindName(value)});
        return .{ .path = path, .issues = issues.items };
    }

    var it = value.object.iterator();
    outer: while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const val = entry.value_ptr.*;
        inline for (file_fields) |f| {
            if (std.mem.eql(u8, key, f.name)) {
                try checkKnownField(arena, &issues, f, val);
                continue :outer;
            }
        }
        try addIssue(arena, &issues, key, "\"{s}\" is not a tau config key — check the spelling or remove it (see docs/configuration.md)", .{key});
    }

    return .{ .path = path, .issues = issues.items };
}

// ── Report rendering ────────────────────────────────────────────────────────

fn appendJsonStr(alloc: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
    try buf.append(alloc, '"');
    try json.escapeInto(alloc, buf, s);
    try buf.append(alloc, '"');
}

/// Machine-readable report: {"path":...,"ok":bool,"errors":[{key,message}]}.
/// Goes to stdout — this is the command's *result*, not an operational error.
pub fn formatJson(arena: std.mem.Allocator, report: Report) ![]u8 {
    var b: std.ArrayList(u8) = .empty;
    try b.appendSlice(arena, "{\"path\":");
    try appendJsonStr(arena, &b, report.path);
    try b.appendSlice(arena, if (report.ok()) ",\"ok\":true,\"errors\":[" else ",\"ok\":false,\"errors\":[");
    for (report.issues, 0..) |iss, i| {
        if (i != 0) try b.append(arena, ',');
        try b.appendSlice(arena, "{\"key\":");
        if (iss.key) |k| try appendJsonStr(arena, &b, k) else try b.appendSlice(arena, "null");
        try b.appendSlice(arena, ",\"message\":");
        try appendJsonStr(arena, &b, iss.message);
        try b.append(arena, '}');
    }
    try b.appendSlice(arena, "]}\n");
    return b.toOwnedSlice(arena);
}

/// Human-readable report (`--mode text`): one line per issue.
pub fn formatText(arena: std.mem.Allocator, report: Report) ![]u8 {
    var b: std.ArrayList(u8) = .empty;
    if (report.ok()) {
        try b.appendSlice(arena, report.path);
        try b.appendSlice(arena, ": ok\n");
        return b.toOwnedSlice(arena);
    }
    for (report.issues) |iss| {
        try b.appendSlice(arena, report.path);
        try b.appendSlice(arena, ": error");
        if (iss.key) |k| {
            try b.appendSlice(arena, " in \"");
            try b.appendSlice(arena, k);
            try b.append(arena, '"');
        }
        try b.appendSlice(arena, ": ");
        try b.appendSlice(arena, iss.message);
        try b.append(arena, '\n');
    }
    return b.toOwnedSlice(arena);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
const testing = std.testing;

/// Write `content` to a fresh tmp file and validate it. Caller keeps the TmpDir
/// alive via `deinit`.
const TmpConfig = struct {
    tmp: testing.TmpDir,
    path: []const u8,

    fn init(arena: std.mem.Allocator, content: []const u8) !TmpConfig {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const path = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/config.json", .{tmp.sub_path[0..]});
        try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = content });
        return .{ .tmp = tmp, .path = path };
    }

    fn deinit(self: *TmpConfig) void {
        self.tmp.cleanup();
    }
};

test "validate: valid full config passes" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var tc = try TmpConfig.init(arena,
        \\{
        \\  "provider": "openai",
        \\  "model": "gpt-4o-mini",
        \\  "api_key": "sk-secret",
        \\  "keys": { "deepseek": "sk-other" },
        \\  "mode": "text",
        \\  "stream": false,
        \\  "thinking": true,
        \\  "debug": false,
        \\  "temperature": 0.5,
        \\  "max_tokens": 4096,
        \\  "timeout_ms": 60000,
        \\  "context_window": 128000,
        \\  "auto_compact": true,
        \\  "compact_threshold": 0.8,
        \\  "compact_keep_recent_tokens": 4000,
        \\  "goal_max_iterations": 40,
        \\  "goal_max_continues": 3
        \\}
    );
    defer tc.deinit();

    const rep = try validate(testing.io, arena, tc.path);
    try testing.expect(rep.ok());
    try testing.expectEqual(@as(usize, 0), rep.issues.len);
}

test "validate: empty object passes (all keys optional)" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var tc = try TmpConfig.init(arena, "{}");
    defer tc.deinit();

    const rep = try validate(testing.io, arena, tc.path);
    try testing.expect(rep.ok());
}

test "validate: missing file reports file not found" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const rep = try validate(testing.io, arena, ".zig-cache/tmp/definitely-not-here/config.json");
    try testing.expect(!rep.ok());
    try testing.expectEqual(@as(usize, 1), rep.issues.len);
    try testing.expect(std.mem.indexOf(u8, rep.issues[0].message, "file not found") != null);
}

test "validate: malformed JSON reports line and column" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var tc = try TmpConfig.init(arena, "{\n  \"provider\": \"openai\",\n  bad\n}");
    defer tc.deinit();

    const rep = try validate(testing.io, arena, tc.path);
    try testing.expect(!rep.ok());
    try testing.expect(std.mem.indexOf(u8, rep.issues[0].message, "invalid JSON at line 3") != null);
}

test "validate: non-object top level is an error" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var tc = try TmpConfig.init(arena, "[\"provider\", \"openai\"]");
    defer tc.deinit();

    const rep = try validate(testing.io, arena, tc.path);
    try testing.expect(!rep.ok());
    try testing.expect(std.mem.indexOf(u8, rep.issues[0].message, "must be a JSON object") != null);
}

test "validate: unknown key is flagged (typo catching)" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var tc = try TmpConfig.init(arena, "{ \"proivder\": \"openai\" }");
    defer tc.deinit();

    const rep = try validate(testing.io, arena, tc.path);
    try testing.expect(!rep.ok());
    try testing.expectEqualStrings("proivder", rep.issues[0].key.?);
    try testing.expect(std.mem.indexOf(u8, rep.issues[0].message, "not a tau config key") != null);
}

test "validate: wrong value types are flagged" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var tc = try TmpConfig.init(arena, "{ \"stream\": \"yes\", \"max_tokens\": \"many\" }");
    defer tc.deinit();

    const rep = try validate(testing.io, arena, tc.path);
    try testing.expect(!rep.ok());
    try testing.expectEqual(@as(usize, 2), rep.issues.len);
    try testing.expect(std.mem.indexOf(u8, rep.issues[0].message, "must be a boolean") != null);
    try testing.expect(std.mem.indexOf(u8, rep.issues[1].message, "must be an integer") != null);
}

test "validate: semantic checks catch bad provider, mode, ranges, keys" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var tc = try TmpConfig.init(arena,
        \\{
        \\  "provider": "nope",
        \\  "mode": "yaml",
        \\  "temperature": -1,
        \\  "compact_threshold": 1.5,
        \\  "timeout_ms": -50,
        \\  "max_tokens": 1.5,
        \\  "keys": { "notaprovider": "sk-x", "openai": 42, "deepseek": "" }
        \\}
    );
    defer tc.deinit();

    const rep = try validate(testing.io, arena, tc.path);
    try testing.expect(!rep.ok());
    // provider + mode + temperature + compact_threshold + timeout_ms +
    // max_tokens + keys.notaprovider + keys.openai + keys.deepseek
    try testing.expectEqual(@as(usize, 9), rep.issues.len);
    try testing.expect(std.mem.indexOf(u8, rep.issues[0].message, "not a known provider") != null);
    try testing.expect(std.mem.indexOf(u8, rep.issues[1].message, "\"text\" or \"json\"") != null);
    try testing.expect(std.mem.indexOf(u8, rep.issues[2].message, "must be >= 0") != null);
    try testing.expect(std.mem.indexOf(u8, rep.issues[3].message, "between 0 and 1") != null);
    try testing.expect(std.mem.indexOf(u8, rep.issues[4].message, "must be >= 0") != null);
    try testing.expect(std.mem.indexOf(u8, rep.issues[5].message, "must be an integer") != null);
    try testing.expect(std.mem.indexOf(u8, rep.issues[6].message, "not a known provider") != null);
    try testing.expect(std.mem.indexOf(u8, rep.issues[7].message, "must be a string") != null);
    try testing.expect(std.mem.indexOf(u8, rep.issues[8].message, "empty string") != null);
}

test "validate: u32 fields reject values above maxInt(u32)" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var tc = try TmpConfig.init(arena, "{ \"max_tokens\": 5000000000 }");
    defer tc.deinit();

    const rep = try validate(testing.io, arena, tc.path);
    try testing.expect(!rep.ok());
    try testing.expect(std.mem.indexOf(u8, rep.issues[0].message, "must be <=") != null);
}

test "validate: never echoes API key values in messages" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var tc = try TmpConfig.init(arena, "{ \"api_key\": 123, \"keys\": { \"nope\": \"sk-do-not-leak-me\" } }");
    defer tc.deinit();

    const rep = try validate(testing.io, arena, tc.path);
    try testing.expect(!rep.ok());
    const out = try formatJson(arena, rep);
    try testing.expect(std.mem.indexOf(u8, out, "sk-do-not-leak-me") == null);
    try testing.expect(std.mem.indexOf(u8, out, "123") == null);
}

test "formatJson: ok report and error report shapes" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const ok_rep = Report{ .path = "/x/config.json", .issues = &.{} };
    const ok_json = try formatJson(arena, ok_rep);
    try testing.expectEqualStrings("{\"path\":\"/x/config.json\",\"ok\":true,\"errors\":[]}\n", ok_json);

    const bad_rep = Report{ .path = "/x/c.json", .issues = &.{ .{ .key = "mode", .message = "\"mode\" is bad" } } };
    const bad_json = try formatJson(arena, bad_rep);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, bad_json, .{});
    try testing.expect(parsed == .object);
    try testing.expect(std.mem.indexOf(u8, bad_json, "\"ok\":false") != null);
    try testing.expect(std.mem.indexOf(u8, bad_json, "\\\"mode\\\" is bad") != null);
}

test "formatText: ok line and per-issue lines" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const ok_rep = Report{ .path = "/x/config.json", .issues = &.{} };
    try testing.expectEqualStrings("/x/config.json: ok\n", try formatText(arena, ok_rep));

    const bad_rep = Report{ .path = "/x/c.json", .issues = &.{
        .{ .key = "mode", .message = "bad mode" },
        .{ .message = "file-level problem" },
    } };
    const out = try formatText(arena, bad_rep);
    try testing.expectEqualStrings("/x/c.json: error in \"mode\": bad mode\n/x/c.json: error: file-level problem\n", out);
}
