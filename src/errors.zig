//! Canonical user-facing error surface: stable codes, wire `type` tags,
//! remediation hints, and the single `{"err":{...}}` envelope every emitter
//! shares.
//!
//! The codes (which double as process exit codes) and `type` strings are a
//! stable contract documented in docs/troubleshooting.md — scripts and
//! agents branch on them. Never renumber a code or rename a `type_name`;
//! add a new entry instead. Keep hints actionable: one line naming the flag,
//! env var, or command that fixes it.

const std = @import("std");
const json = @import("json.zig");
const term = @import("term.zig");
const debuglog = @import("debuglog.zig");

const doc_url = @import("version.zig").troubleshooting_doc_url;
const providers_doc_url = @import("version.zig").providers_doc_url;

/// One entry in the stable error catalog (docs/troubleshooting.md mirrors
/// it). `code` doubles as the process exit code; `type_name` is the wire tag
/// in err.type — it keeps legacy spellings like "AuthFailed"/"Timeout" since
/// the string itself is the contract. `docs` is the envelope's guide link —
/// it defaults to the troubleshooting page; auth failures point at the
/// per-provider credential guide instead.
pub const Spec = struct {
    code: u8,
    type_name: []const u8,
    hint: []const u8,
    recoverable: bool = false,
    docs: []const u8 = doc_url,
};

pub const not_found = Spec{
    .code = 1,
    .type_name = "not_found",
    .hint = "the message names what was not found — check the name/path and retry",
};
pub const invalid_argument = Spec{
    .code = 80,
    .type_name = "invalid_argument",
    .hint = "run `tau --help` (or `tau --help-json`) for the valid flags and values",
};
pub const missing_required_field = Spec{
    .code = 82,
    .type_name = "missing_required_field",
    .hint = "the message names the missing input — supply it and retry",
};
pub const timeout = Spec{
    .code = 105,
    .type_name = "Timeout",
    .hint = "raise --timeout-ms (default 120000) or check the endpoint/network (TAU_ENDPOINT)",
};
pub const auth_failed = Spec{
    .code = 106,
    .type_name = "AuthFailed",
    .hint = "provide an API key via --api-key, the provider env var, config.json, or TAU_API_KEY",
    .docs = providers_doc_url,
};
pub const internal_error = Spec{
    .code = 110,
    .type_name = "internal_error",
    .hint = "re-run with --debug to write a diagnostic log, then file a bug report",
};
pub const unimplemented = Spec{
    .code = 111,
    .type_name = "unimplemented",
    .hint = "not supported on this platform — the message names the workaround",
};

/// The stable catalog, ordered by code. Snapshot-tested byte-for-byte and
/// cross-checked against docs/troubleshooting.md and --help-json.
pub const specs = [_]Spec{
    not_found,           invalid_argument, missing_required_field, timeout,
    auth_failed,         internal_error,   unimplemented,
};

/// Look up the catalog entry for an exit code. Unknown codes get a generic
/// internal-error spec (their code is preserved) so every envelope still
/// carries a type and a hint.
pub fn specFor(code: u8) Spec {
    for (specs) |s| {
        if (s.code == code) return s;
    }
    return .{
        .code = code,
        .type_name = internal_error.type_name,
        .hint = internal_error.hint,
    };
}

/// Per-emission field overrides: each field defaults to the spec's value.
/// `type_name` override keeps a stable code while naming the cause (callers
/// pass @errorName(err)); `hint` override points at a dynamic fix (e.g. the
/// env var a provider wants).
pub const Opts = struct {
    type_name: ?[]const u8 = null,
    hint: ?[]const u8 = null,
    recoverable: ?bool = null,
    docs: ?[]const u8 = null,
};

/// Serialize the canonical envelope:
/// {"err":{"code":N,"type":"T","message":"M","recoverable":B,"hint":"H","docs":"U"[,"debug_log":"P"]}}
/// debug_log is spliced in only when --debug opened a diagnostic log.
/// Caller owns the returned slice.
pub fn format(a: std.mem.Allocator, spec: Spec, message: []const u8, opts: Opts) ![]u8 {
    const te = try json.escapeAlloc(a, opts.type_name orelse spec.type_name);
    defer a.free(te);
    const me = try json.escapeAlloc(a, message);
    defer a.free(me);
    const he = try json.escapeAlloc(a, opts.hint orelse spec.hint);
    defer a.free(he);
    const de = try json.escapeAlloc(a, opts.docs orelse spec.docs);
    defer a.free(de);
    // When --debug opened a diagnostic log, link it so bug reports can attach it.
    const suf = debuglog.envelopeSuffix(a) orelse "";
    defer if (suf.len > 0) a.free(suf);
    return std.fmt.allocPrint(a, "{{\"err\":{{\"code\":{d},\"type\":\"{s}\",\"message\":\"{s}\",\"recoverable\":{},\"hint\":\"{s}\",\"docs\":\"{s}\"{s}}}}}\n", .{ spec.code, te, me, opts.recoverable orelse spec.recoverable, he, de, suf });
}

/// Print the envelope to stderr. Best-effort: on OOM a stack-formatted
/// fallback is emitted so the failure is never silent.
pub fn printErr(a: std.mem.Allocator, spec: Spec, message: []const u8, opts: Opts) void {
    const j = format(a, spec, message, opts) catch {
        emitFallback(term.err, spec);
        return;
    };
    defer a.free(j);
    term.err(j);
}

/// Print the envelope to stdout — fleet's envelope channel (the integration
/// contract has fleet write errors to stdout, not stderr).
pub fn printOut(a: std.mem.Allocator, spec: Spec, message: []const u8, opts: Opts) void {
    const j = format(a, spec, message, opts) catch {
        emitFallback(term.out, spec);
        return;
    };
    defer a.free(j);
    term.out(j);
}

/// OOM path: spec fields and doc_url are comptime-trusted literals (no
/// escaping needed), formatted into a stack buffer.
fn emitFallback(write: *const fn ([]const u8) void, spec: Spec) void {
    var buf: [768]u8 = undefined;
    const j = std.fmt.bufPrint(&buf, "{{\"err\":{{\"code\":{d},\"type\":\"{s}\",\"message\":\"internal error\",\"recoverable\":{},\"hint\":\"{s}\",\"docs\":\"{s}\"}}}}\n", .{ spec.code, spec.type_name, spec.recoverable, spec.hint, spec.docs }) catch
        "{\"err\":{\"code\":110,\"type\":\"internal_error\",\"message\":\"internal error\",\"recoverable\":false,\"hint\":\"re-run with --debug to write a diagnostic log, then file a bug report\",\"docs\":\"" ++ doc_url ++ "\"}}\n";
    write(j);
}

// ---------------------------------------------------------------------------
// Snapshot tests — the envelope bytes are a user-visible contract.
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Expected golden envelope line for each catalog spec (same order as `specs`).
/// Deliberate changes must update this table and docs/troubleshooting.md.
const golden = [_][]const u8{
    "{\"err\":{\"code\":1,\"type\":\"not_found\",\"message\":\"<msg>\",\"recoverable\":false,\"hint\":\"the message names what was not found — check the name/path and retry\",\"docs\":\"" ++ doc_url ++ "\"}}\n",
    "{\"err\":{\"code\":80,\"type\":\"invalid_argument\",\"message\":\"<msg>\",\"recoverable\":false,\"hint\":\"run `tau --help` (or `tau --help-json`) for the valid flags and values\",\"docs\":\"" ++ doc_url ++ "\"}}\n",
    "{\"err\":{\"code\":82,\"type\":\"missing_required_field\",\"message\":\"<msg>\",\"recoverable\":false,\"hint\":\"the message names the missing input — supply it and retry\",\"docs\":\"" ++ doc_url ++ "\"}}\n",
    "{\"err\":{\"code\":105,\"type\":\"Timeout\",\"message\":\"<msg>\",\"recoverable\":false,\"hint\":\"raise --timeout-ms (default 120000) or check the endpoint/network (TAU_ENDPOINT)\",\"docs\":\"" ++ doc_url ++ "\"}}\n",
    "{\"err\":{\"code\":106,\"type\":\"AuthFailed\",\"message\":\"<msg>\",\"recoverable\":false,\"hint\":\"provide an API key via --api-key, the provider env var, config.json, or TAU_API_KEY\",\"docs\":\"" ++ providers_doc_url ++ "\"}}\n",
    "{\"err\":{\"code\":110,\"type\":\"internal_error\",\"message\":\"<msg>\",\"recoverable\":false,\"hint\":\"re-run with --debug to write a diagnostic log, then file a bug report\",\"docs\":\"" ++ doc_url ++ "\"}}\n",
    "{\"err\":{\"code\":111,\"type\":\"unimplemented\",\"message\":\"<msg>\",\"recoverable\":false,\"hint\":\"not supported on this platform — the message names the workaround\",\"docs\":\"" ++ doc_url ++ "\"}}\n",
};

test "golden envelope bytes for every catalog spec" {
    const gpa = testing.allocator;
    try testing.expectEqual(specs.len, golden.len);
    for (specs, golden) |spec, want| {
        const got = try format(gpa, spec, "<msg>", .{});
        defer gpa.free(got);
        try testing.expectEqualStrings(want, got);
    }
}

test "catalog codes are unique and in ascending order" {
    for (specs, 0..) |s, i| {
        if (i > 0) try testing.expect(s.code > specs[i - 1].code);
    }
}

test "format honors type/hint/recoverable/docs overrides" {
    const gpa = testing.allocator;
    const got = try format(gpa, internal_error, "boom", .{
        .type_name = "HTTPRequestFailed",
        .hint = "check TAU_ENDPOINT",
        .recoverable = true,
        .docs = "https://example.com/fix",
    });
    defer gpa.free(got);
    try testing.expectEqualStrings(
        "{\"err\":{\"code\":110,\"type\":\"HTTPRequestFailed\",\"message\":\"boom\",\"recoverable\":true,\"hint\":\"check TAU_ENDPOINT\",\"docs\":\"https://example.com/fix\"}}\n",
        got,
    );
}

test "auth envelopes link docs/providers.md" {
    const gpa = testing.allocator;
    const got = try format(gpa, auth_failed, "no API key", .{});
    defer gpa.free(got);
    try testing.expect(std.mem.indexOf(u8, got, "\"docs\":\"" ++ providers_doc_url ++ "\"") != null);
    try testing.expect(std.mem.indexOf(u8, got, "troubleshooting.md") == null);
}

test "format escapes quotes, backslashes, and control characters" {
    const gpa = testing.allocator;
    const got = try format(gpa, invalid_argument, "bad --flag \"x\"\nnext", .{});
    defer gpa.free(got);
    try testing.expect(std.mem.indexOf(u8, got, "\\\"x\\\"\\nnext") != null);
    try testing.expect(std.mem.indexOf(u8, got, "\n") == null or std.mem.indexOf(u8, got, "\n").? == got.len - 1);
}

test "specFor preserves unknown codes with a generic spec" {
    const s = specFor(42);
    try testing.expectEqual(@as(u8, 42), s.code);
    try testing.expectEqualStrings(internal_error.type_name, s.type_name);
    for (specs) |spec| {
        try testing.expectEqual(spec.code, specFor(spec.code).code);
        try testing.expectEqualStrings(spec.type_name, specFor(spec.code).type_name);
    }
}

test "no debug_log field when no diagnostic log is open" {
    const gpa = testing.allocator;
    const got = try format(gpa, invalid_argument, "x", .{});
    defer gpa.free(got);
    try testing.expect(std.mem.indexOf(u8, got, "debug_log") == null);
}

test "docs/troubleshooting.md documents the whole catalog" {
    const gpa = testing.allocator;
    const doc = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "docs/troubleshooting.md", gpa, .unlimited);
    defer gpa.free(doc);
    try testing.expect(std.mem.indexOf(u8, doc, "\"hint\"") != null);
    for (specs) |s| {
        var buf: [128]u8 = undefined;
        // Every code appears as a catalog row: | `80` | `invalid_argument` | ...
        const row = std.fmt.bufPrint(&buf, "| `{d}` | `{s}` |", .{ s.code, s.type_name }) catch unreachable;
        if (std.mem.indexOf(u8, doc, row) == null) {
            std.debug.print("troubleshooting.md catalog missing row '{s}'\n", .{row});
            return error.TestUnexpectedResult;
        }
        // ...and its hint is quoted verbatim in the doc.
        if (std.mem.indexOf(u8, doc, s.hint) == null) {
            std.debug.print("troubleshooting.md missing hint for code {d}\n", .{s.code});
            return error.TestUnexpectedResult;
        }
    }
}
