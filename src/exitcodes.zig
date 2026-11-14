//! The process exit-status catalog behind `tau explain exit.<code>` — one
//! entry per exit status tau can return, viewed as a scripting contract:
//! what the status means and where a script reads the detail. This is a
//! different surface from the error catalog in src/errors.zig: the error
//! catalog documents `{"err":...}` envelope classes (wire `type` tags);
//! this registry documents process statuses (the `ExitCode` enum names in
//! src/main.zig, the same names `--help-json` advertises).
//!
//! The code set is a stable contract — scripts and agents branch on `$?` /
//! `$LASTEXITCODE`. Never renumber a code; add a new entry instead. Keep
//! `name` spelled exactly like the `ExitCode` enum member in src/main.zig
//! (the parity test below pins it) and keep `meaning`/`scripting` to one
//! line each. After changing this file run
//! `python3 scripts/gen-exit-codes-doc.py` — `zig build test` and the
//! exit-codes-doc smoke group fail on drift.

const std = @import("std");
const json = @import("json.zig");
const errors = @import("errors.zig");

const doc_url = @import("version.zig").exit_codes_doc_url;

/// One entry in the stable exit-code catalog (mirrored by the generated
/// docs/exit-codes.md). `code` is the process exit status; `name` is the
/// `ExitCode` enum member spelling `--help-json` advertises — kept
/// distinct from the error catalog's wire `type` tags because the
/// namespaces genuinely differ (exit 105 is `connection_timeout` while its
/// envelope type is `Timeout`; exit 1 is `generic_failure` while its
/// envelope type is `not_found`). `meaning` names when the status is
/// returned; `scripting` tells a script where the detail lives and whether
/// a retry makes sense.
pub const Spec = struct {
    code: u8,
    name: []const u8,
    meaning: []const u8,
    scripting: []const u8,
    docs: []const u8 = doc_url,
};

pub const success = Spec{
    .code = 0,
    .name = "success",
    .meaning = "the command completed — stdout carries the result",
    .scripting = "no {\"err\"} envelope is emitted — parse stdout per the command's documented shape (docs/stability.md)",
};
pub const generic_failure = Spec{
    .code = 1,
    .name = "generic_failure",
    .meaning = "a named resource was not found, a check-style command reported failures (`tau doctor`, `tau setup`, `tau config validate`), or a `tau explain` query matched nothing",
    .scripting = "detail is never on the status alone — read the {\"err\"} envelope on stderr (type not_found) or the stdout report's \"ok\":false",
};
pub const invalid_argument = Spec{
    .code = 80,
    .name = "invalid_argument",
    .meaning = "an unknown flag, bad flag value, invalid subcommand, or malformed argument was passed",
    .scripting = "read the {\"err\"} envelope's message on stderr, fix argv, and retry — `tau explain 80` prints the error entry offline",
};
pub const missing_required_field = Spec{
    .code = 82,
    .name = "missing_required_field",
    .meaning = "a required input is missing (e.g. `tau fleet run` without --goal) — bare `tau` with no prompt also exits 82 silently",
    .scripting = "the stderr envelope's message names the missing input when an envelope is emitted — supply it and retry",
};
pub const connection_timeout = Spec{
    .code = 105,
    .name = "connection_timeout",
    .meaning = "an HTTP request to the provider endpoint exceeded --timeout-ms",
    .scripting = "retry-safe — raise --timeout-ms (default 120000) or check the endpoint/network (TAU_ENDPOINT); the stderr envelope's type tag is Timeout",
};
pub const auth_failed = Spec{
    .code = 106,
    .name = "auth_failed",
    .meaning = "the provider rejected the API key, or no key was found anywhere in the resolution chain",
    .scripting = "missing-key exits are silent; rejections emit a stderr envelope (type AuthFailed) — provide a key via --api-key, the provider env var, config.json, or TAU_API_KEY",
};
pub const internal_error = Spec{
    .code = 110,
    .name = "internal_error",
    .meaning = "an HTTP failure, JSON parse error, tool crash, or the --max-iterations tool-loop cap was hit",
    .scripting = "treat stdout as best-effort — the tool-loop cap exits 110 after emitting the last answer; re-run with --debug and file a bug report",
};
pub const unimplemented = Spec{
    .code = 111,
    .name = "unimplemented",
    .meaning = "the operation is not supported on this platform (e.g. `tau acp` daemon commands and `tau upgrade` are POSIX-only)",
    .scripting = "permanent for this platform — retrying changes nothing; the stderr envelope's message names the workaround",
};

/// The stable catalog, ordered by code. Snapshot-tested byte-for-byte and
/// mirrored by the generated docs/exit-codes.md — every nonzero entry must
/// pair with an errors.Spec of the same code (the two registries share the
/// status space; the parity tests below pin that).
pub const specs = [_]Spec{
    success,             generic_failure, invalid_argument, missing_required_field,
    connection_timeout,  auth_failed,     internal_error,   unimplemented,
};

/// Resolve an `exit.<code>` or `exit.<name>` query to a catalog entry. The
/// `exit.` prefix is required — bare decimal codes belong to the error
/// catalog (`tau explain 80` is the invalid_argument error entry;
/// `tau explain exit.80` is this scripting contract). Names match
/// case-insensitively like the error `type` tags. Returns null when
/// nothing matches — `exit.` alone, an out-of-table code, or an unknown
/// name all stay unresolvable rather than borrowing the error catalog's
/// uncataloged-code fallback.
pub fn findSpec(query: []const u8) ?Spec {
    const q = std.mem.trim(u8, query, " \t");
    if (!std.mem.startsWith(u8, q, "exit.")) return null;
    const id = q["exit.".len..];
    if (id.len == 0) return null;
    if (std.fmt.parseInt(u8, id, 10)) |code| {
        for (specs) |s| {
            if (s.code == code) return s;
        }
        return null;
    } else |_| {}
    for (specs) |s| {
        if (std.ascii.eqlIgnoreCase(id, s.name)) return s;
    }
    return null;
}

/// Serialize one catalog entry for `tau explain` (no trailing newline —
/// the caller owns framing, like errors.formatEntryJson):
/// {"exit":N,"name":"N","meaning":"M","scripting":"S","docs":"U"}
/// Caller owns the returned slice.
pub fn formatExitJson(a: std.mem.Allocator, spec: Spec) ![]u8 {
    const ne = try json.escapeAlloc(a, spec.name);
    defer a.free(ne);
    const me = try json.escapeAlloc(a, spec.meaning);
    defer a.free(me);
    const se = try json.escapeAlloc(a, spec.scripting);
    defer a.free(se);
    const de = try json.escapeAlloc(a, spec.docs);
    defer a.free(de);
    return std.fmt.allocPrint(a, "{{\"exit\":{d},\"name\":\"{s}\",\"meaning\":\"{s}\",\"scripting\":\"{s}\",\"docs\":\"{s}\"}}", .{ spec.code, ne, me, se, de });
}

/// Human-readable `tau explain --human exit.<code>` rendering — drawn from
/// the same Spec so the prose and JSON forms can never drift apart.
pub fn formatExitHuman(a: std.mem.Allocator, spec: Spec) ![]u8 {
    return std.fmt.allocPrint(a, "exit {d}  {s}\n  meaning:   {s}\n  scripting: {s}\n  docs:      {s}\n", .{ spec.code, spec.name, spec.meaning, spec.scripting, spec.docs });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "catalog codes are unique and in ascending order" {
    for (specs, 0..) |s, i| {
        if (i > 0) try testing.expect(s.code > specs[i - 1].code);
    }
}

test "every error-catalog code has an exit entry and vice versa" {
    // The two registries share the process-status space: an errors.Spec
    // without an exit entry would leave a documented status unexplainable
    // via `exit.<code>`, and an exit entry without an errors.Spec would
    // claim a status no emitter can produce (except 0 — success is never
    // an error).
    for (errors.specs) |e| {
        var found = false;
        for (specs) |s| {
            if (s.code == e.code) found = true;
        }
        if (!found) {
            std.debug.print("errors catalog code {d} ({s}) has no exitcodes.Spec\n", .{ e.code, e.type_name });
            return error.TestUnexpectedResult;
        }
    }
    for (specs) |s| {
        if (s.code == 0) continue;
        try testing.expectEqual(s.code, errors.specFor(s.code).code);
    }
}

test "findSpec resolves exit.<code> and exit.<name>, nothing else" {
    try testing.expectEqual(@as(u8, 0), findSpec("exit.0").?.code);
    try testing.expectEqual(@as(u8, 80), findSpec("exit.80").?.code);
    try testing.expectEqualStrings("connection_timeout", findSpec("exit.105").?.name);
    try testing.expectEqual(@as(u8, 106), findSpec("exit.auth_failed").?.code);
    try testing.expectEqual(@as(u8, 0), findSpec("exit.Success").?.code);
    // The prefix is required — bare codes and names belong to the other
    // registries (80 is the invalid_argument error entry; `success` alone
    // is not a query).
    try testing.expect(findSpec("80") == null);
    try testing.expect(findSpec("0") == null);
    try testing.expect(findSpec("success") == null);
    try testing.expect(findSpec("exit") == null);
    try testing.expect(findSpec("exit.") == null);
    try testing.expect(findSpec("exit.42") == null);
    try testing.expect(findSpec("exit.256") == null);
    try testing.expect(findSpec("exit.bogus") == null);
    try testing.expect(findSpec(" exit.1 ") != null);
}

test "formatExitJson emits the exit entry shape" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const got = try formatExitJson(a, auth_failed);
    try testing.expect(std.mem.startsWith(u8, got, "{\"exit\":106,\"name\":\"auth_failed\""));
    try testing.expect(std.mem.indexOf(u8, got, "\"meaning\":\"") != null);
    try testing.expect(std.mem.indexOf(u8, got, "\"scripting\":\"") != null);
    try testing.expect(std.mem.indexOf(u8, got, "\"docs\":\"") != null);
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, got, .{});
    try testing.expectEqual(@as(i64, 106), v.object.get("exit").?.integer);
}

test "formatExitHuman renders code, name, meaning, scripting, docs" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const got = try formatExitHuman(a, success);
    try testing.expect(std.mem.indexOf(u8, got, "exit 0  success") != null);
    try testing.expect(std.mem.indexOf(u8, got, "meaning:") != null);
    try testing.expect(std.mem.indexOf(u8, got, "scripting:") != null);
    try testing.expect(std.mem.indexOf(u8, got, "docs:") != null);
}

test "docs/exit-codes.md generated catalog mirrors the registry" {
    const gpa = testing.allocator;
    const doc = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "docs/exit-codes.md", gpa, .unlimited);
    defer gpa.free(doc);
    // The file must declare itself generated so nobody hand-edits it.
    try testing.expect(std.mem.indexOf(u8, doc, "GENERATED FILE") != null);
    try testing.expect(std.mem.indexOf(u8, doc, "scripts/gen-exit-codes-doc.py") != null);
    for (specs) |s| {
        try testing.expect(s.meaning.len > 0);
        try testing.expect(s.scripting.len > 0);
        var buf: [160]u8 = undefined;
        // Catalog rows: | `0` | `success` | ... — and the meaning/scripting
        // text is quoted verbatim so a prose tweak regenerates the doc.
        const row = std.fmt.bufPrint(&buf, "| `{d}` | `{s}` |", .{ s.code, s.name }) catch unreachable;
        if (std.mem.indexOf(u8, doc, row) == null) {
            std.debug.print("exit-codes.md catalog missing row '{s}'\n", .{row});
            return error.TestUnexpectedResult;
        }
        if (std.mem.indexOf(u8, doc, s.meaning) == null) {
            std.debug.print("exit-codes.md missing meaning for code {d}\n", .{s.code});
            return error.TestUnexpectedResult;
        }
        if (std.mem.indexOf(u8, doc, s.scripting) == null) {
            std.debug.print("exit-codes.md missing scripting for code {d}\n", .{s.code});
            return error.TestUnexpectedResult;
        }
    }
}
