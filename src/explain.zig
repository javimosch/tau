//! `tau explain` — the offline catalog lookup surface (no provider or API
//! key needed). A query resolves against THREE registries:
//!
//!   * the stable error catalog (src/errors.zig — mirrored by docs/errors.md)
//!     addressed by decimal exit code or case-insensitive `type` tag,
//!   * the config-key catalog (src/configschema.zig — derived from the same
//!     FileConfig/fieldMeta that generates the schema and docs/config.md)
//!     addressed by exact key name or a `keys.<provider>` member path, and
//!   * the doctor-check catalog (src/doctorcatalog.zig — the generated check
//!     table in docs/troubleshooting.md) addressed by `doctor.<check>` or a
//!     bare check id.
//!
//! Error entries render as {code,type,recoverable,cause,hint,docs}; key
//! entries as {key,type,constraints,description,docs}; check entries as
//! {check,fails_when,remediation,docs}. All three shapes are pinned by
//! schema/tau-explain.schema.json and by the tests/golden/ex-* snapshots.

const std = @import("std");
const errors = @import("errors.zig");
const cfgschema = @import("configschema.zig");
const doctorcat = @import("doctorcatalog.zig");
const suggest = @import("suggest.zig");

/// A resolved `tau explain` query — a stable error entry, a config-key
/// entry, or a doctor-check entry.
pub const Entry = union(enum) {
    err: errors.Spec,
    key: cfgschema.KeySpec,
    check: doctorcat.CheckSpec,
};

/// Resolve a query: error catalog first (decimal exit code, or `type` tag
/// matched case-insensitively — so `tau explain timeout` keeps meaning the
/// Timeout error, not a config key), then the config-key catalog, then the
/// doctor-check catalog. The `doctor.<id>` prefix skips the shared
/// namespace: `api_key` resolves the config key while `doctor.api_key`
/// resolves the check of the same name. Returns null when nothing matches.
pub fn resolve(query: []const u8) ?Entry {
    if (errors.findSpec(query)) |s| return .{ .err = s };
    if (cfgschema.findKey(query)) |ks| return .{ .key = ks };
    if (doctorcat.findCheck(query)) |cs| return .{ .check = cs };
    return null;
}

/// Every query `tau explain` resolves — each catalog `type_name` and decimal
/// code, each config-key name and `keys.<provider>` member path, and each
/// doctor-check id in both `doctor.<id>` and bare spellings — so a
/// suggestion always resolves on retry.
const candidates = blk: {
    var c: [errors.specs.len * 2 + cfgschema.key_catalog.len + cfgschema.deprecated_key_specs.len + doctorcat.check_catalog.len * 2][]const u8 = undefined;
    for (errors.specs, 0..) |s, i| {
        c[i * 2] = s.type_name;
        c[i * 2 + 1] = std.fmt.comptimePrint("{d}", .{s.code});
    }
    var n = errors.specs.len * 2;
    for (cfgschema.key_catalog) |ks| {
        c[n] = ks.name;
        n += 1;
    }
    for (cfgschema.deprecated_key_specs) |ks| {
        c[n] = ks.name;
        n += 1;
    }
    for (doctorcat.check_catalog) |cs| {
        c[n] = cs.name;
        c[n + 1] = "doctor." ++ cs.name;
        n += 2;
    }
    break :blk c;
};

/// Lowercase mirrors of candidates — error `type` tags match
/// case-insensitively, so the typo distance ignores case too and the index
/// maps back to the canonical spelling (or the code/key).
const candidates_lower = blk: {
    @setEvalBranchQuota(100_000);
    var c: [candidates.len][]const u8 = undefined;
    for (candidates, 0..) |cand, i| {
        c[i] = lower: {
            var out: [cand.len]u8 = undefined;
            for (cand, 0..) |ch, j| out[j] = std.ascii.toLower(ch);
            const s = out;
            break :lower &s;
        };
    }
    break :blk c;
};

/// A ` — did you mean "tau explain <x>"?` fragment for a query resolve()
/// rejected — <x> is the nearest error code, `type` tag, config key, or
/// doctor-check id within two case-insensitive edits (`timout_ms` → `"tau
/// explain timeout_ms"`, `doctor.tls-ca` → `"tau explain doctor.tls_ca"`),
/// phrased as a ready-to-run command like the envelope's `explain` footer.
/// Queries that parse as decimal get no guess (uncataloged codes resolve
/// via specFor before this runs and `0` is success — never an error — so
/// only numeric overflow reaches the suggestion path). Caller owns the
/// returned slice; null on OOM or when nothing is close.
pub fn suggestQuery(a: std.mem.Allocator, query: []const u8) ?[]const u8 {
    const q = std.mem.trim(u8, query, " \t");
    if (q.len == 0) return null;
    if (std.fmt.parseInt(u8, q, 10)) |_| return null else |_| {}
    const q_lower = std.ascii.allocLowerString(a, q) catch return null;
    var best: ?usize = null;
    var best_d: usize = std.math.maxInt(usize);
    for (candidates_lower, 0..) |cand, i| {
        const d = suggest.editDistance(a, q_lower, cand) orelse continue;
        if (d <= 2 and d < best_d) {
            best = i;
            best_d = d;
        }
    }
    const i = best orelse return null;
    return std.fmt.allocPrint(a, " — did you mean \"tau explain {s}\"?", .{candidates[i]}) catch null;
}

/// Serialize one resolved entry for `tau explain` (no trailing newline — the
/// caller owns framing). Error entries keep the pinned
/// {code,type,recoverable,cause,hint,docs} shape; key entries are
/// {key,type,constraints,description,docs}; check entries are
/// {check,fails_when,remediation,docs}. Caller owns the returned slice.
pub fn formatEntryJson(a: std.mem.Allocator, entry: Entry) ![]u8 {
    return switch (entry) {
        .err => |s| errors.formatEntryJson(a, s),
        .key => |ks| cfgschema.formatKeyJson(a, ks),
        .check => |cs| doctorcat.formatCheckJson(a, cs),
    };
}

/// Human-readable `tau explain --human` rendering — each entry kind drawn
/// from its own Spec/KeySpec/CheckSpec so prose and JSON can never drift
/// apart.
pub fn formatEntryHuman(a: std.mem.Allocator, entry: Entry) ![]u8 {
    return switch (entry) {
        .err => |s| errors.formatEntryHuman(a, s),
        .key => |ks| cfgschema.formatKeyHuman(a, ks),
        .check => |cs| doctorcat.formatCheckHuman(a, cs),
    };
}

/// The whole catalog as one JSON object (trailing newline included):
/// {"errors":[<error entry>, ...],"config_keys":[<key entry>, ...],
///  "doctor_checks":[<check entry>, ...]}
/// Caller owns the returned slice.
pub fn formatCatalogJson(a: std.mem.Allocator) ![]u8 {
    var b: std.ArrayList(u8) = .empty;
    try b.appendSlice(a, "{\"errors\":[");
    for (errors.specs, 0..) |s, i| {
        if (i > 0) try b.appendSlice(a, ",");
        try b.appendSlice(a, try errors.formatEntryJson(a, s));
    }
    try b.appendSlice(a, "],\"config_keys\":[");
    for (cfgschema.key_catalog, 0..) |ks, i| {
        if (i > 0) try b.appendSlice(a, ",");
        try b.appendSlice(a, try cfgschema.formatKeyJson(a, ks));
    }
    try b.appendSlice(a, "],\"doctor_checks\":[");
    for (doctorcat.check_catalog, 0..) |cs, i| {
        if (i > 0) try b.appendSlice(a, ",");
        try b.appendSlice(a, try doctorcat.formatCheckJson(a, cs));
    }
    try b.appendSlice(a, "]}\n");
    return b.toOwnedSlice(a);
}

/// The whole catalog as prose — error entries, then config-key entries, then
/// doctor-check entries, each separated by a blank line. Caller owns the
/// returned slice.
pub fn formatCatalogHuman(a: std.mem.Allocator) ![]u8 {
    var b: std.ArrayList(u8) = .empty;
    for (errors.specs, 0..) |s, i| {
        if (i > 0) try b.appendSlice(a, "\n");
        try b.appendSlice(a, try errors.formatEntryHuman(a, s));
    }
    for (cfgschema.key_catalog) |ks| {
        try b.appendSlice(a, "\n");
        try b.appendSlice(a, try cfgschema.formatKeyHuman(a, ks));
    }
    for (doctorcat.check_catalog) |cs| {
        try b.appendSlice(a, "\n");
        try b.appendSlice(a, try doctorcat.formatCheckHuman(a, cs));
    }
    return b.toOwnedSlice(a);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "resolve: error codes and type tags stay error entries" {
    const code = resolve("106").?;
    try testing.expect(code == .err);
    try testing.expectEqual(@as(u8, 106), code.err.code);
    const tag = resolve("authfailed").?;
    try testing.expect(tag == .err);
    try testing.expectEqualStrings("AuthFailed", tag.err.type_name);
    // Uncataloged decimal codes still resolve to the generic spec.
    const unc = resolve("42").?;
    try testing.expect(unc == .err);
    try testing.expectEqual(@as(u8, 42), unc.err.code);
}

test "resolve: config keys resolve to key entries" {
    const flat = resolve("timeout_ms").?;
    try testing.expect(flat == .key);
    try testing.expectEqualStrings("timeout_ms", flat.key.name);
    const dotted = resolve("keys.openai").?;
    try testing.expect(dotted == .key);
    try testing.expectEqualStrings("keys.openai", dotted.key.name);
    const editor = resolve("$schema").?;
    try testing.expect(editor == .key);
}

test "resolve: error catalog wins over keys and nothing bogus resolves" {
    // `timeout` is the Timeout error (case-insensitive tag), never a key.
    const t = resolve("timeout").?;
    try testing.expect(t == .err);
    try testing.expectEqual(@as(u8, 105), t.err.code);
    try testing.expect(resolve("bogus") == null);
    try testing.expect(resolve("agent.timeout") == null);
    try testing.expect(resolve("0") == null);
    try testing.expect(resolve("Provider") == null);
}

test "resolve: doctor checks resolve prefixed and bare" {
    const prefixed = resolve("doctor.tls_ca").?;
    try testing.expect(prefixed == .check);
    try testing.expectEqualStrings("tls_ca", prefixed.check.name);
    const bare = resolve("tls_ca").?;
    try testing.expect(bare == .check);
    const client = resolve("doctor.client_zed").?;
    try testing.expectEqualStrings("client_zed", client.check.name);
    const probe = resolve("doctor.probe_openai_auth").?;
    try testing.expectEqualStrings("probe_openai_auth", probe.check.name);
    // A shared name keeps its earlier registry — the config key wins on the
    // bare spelling, the check needs the `doctor.` prefix.
    const key = resolve("api_key").?;
    try testing.expect(key == .key);
    const check = resolve("doctor.api_key").?;
    try testing.expect(check == .check);
    try testing.expect(resolve("doctor.nope") == null);
}

test "suggestQuery covers error codes, types, and config keys" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try testing.expectEqualStrings(" — did you mean \"tau explain AuthFailed\"?", suggestQuery(a, "authfaild").?);
    try testing.expectEqualStrings(" — did you mean \"tau explain 106\"?", suggestQuery(a, "1066").?);
    try testing.expectEqualStrings(" — did you mean \"tau explain timeout_ms\"?", suggestQuery(a, "timout_ms").?);
    try testing.expectEqualStrings(" — did you mean \"tau explain keys.openai\"?", suggestQuery(a, "keys.openia").?);
    try testing.expectEqualStrings(" — did you mean \"tau explain provider\"?", suggestQuery(a, "Provider").?);
    try testing.expectEqualStrings(" — did you mean \"tau explain doctor.tls_ca\"?", suggestQuery(a, "doctor.tls-ca").?);
    try testing.expectEqualStrings(" — did you mean \"tau explain tls_ca\"?", suggestQuery(a, "tls-ca").?);
    // Unrelated queries and decimal-parseable input get no guess.
    try testing.expect(suggestQuery(a, "bogus") == null);
    try testing.expect(suggestQuery(a, "0") == null);
}

test "every suggestion candidate resolves via resolve" {
    // A suggestion that didn't resolve would point users at a dead end.
    for (candidates) |c| {
        try testing.expect(resolve(c) != null);
    }
}

test "formatEntryJson dispatches per entry kind" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const err = try formatEntryJson(a, .{ .err = errors.specFor(106) });
    try testing.expect(std.mem.indexOf(u8, err, "\"code\":106") != null);
    const key = try formatEntryJson(a, .{ .key = cfgschema.findKey("timeout_ms").? });
    try testing.expect(std.mem.indexOf(u8, key, "\"key\":\"timeout_ms\"") != null);
    const check = try formatEntryJson(a, .{ .check = doctorcat.findCheck("doctor.tls_ca").? });
    try testing.expect(std.mem.indexOf(u8, check, "\"check\":\"tls_ca\"") != null);
}

test "formatCatalogJson emits errors + config_keys + doctor_checks arrays" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const cat = try formatCatalogJson(a);
    try testing.expect(std.mem.startsWith(u8, cat, "{\"errors\":["));
    try testing.expect(std.mem.endsWith(u8, cat, "]}\n"));
    try testing.expect(std.mem.indexOf(u8, cat, "\"config_keys\":[") != null);
    try testing.expect(std.mem.indexOf(u8, cat, "\"doctor_checks\":[") != null);
    // Every catalog member appears exactly once — flat keys and members.
    for (cfgschema.key_catalog) |ks| {
        var buf: [80]u8 = undefined;
        const needle = std.fmt.bufPrint(&buf, "\"key\":\"{s}\"", .{ks.name}) catch unreachable;
        try testing.expect(std.mem.indexOf(u8, cat, needle) != null);
    }
    for (doctorcat.check_catalog) |cs| {
        var buf: [80]u8 = undefined;
        const needle = std.fmt.bufPrint(&buf, "\"check\":\"{s}\"", .{cs.name}) catch unreachable;
        try testing.expect(std.mem.indexOf(u8, cat, needle) != null);
    }
    // The catalog JSON must parse cleanly.
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, cat, .{});
    try testing.expect(v.object.get("config_keys").?.array.items.len == cfgschema.key_catalog.len);
    try testing.expect(v.object.get("doctor_checks").?.array.items.len == doctorcat.check_catalog.len);
}

test "formatCatalogHuman renders all three sections" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const cat = try formatCatalogHuman(a);
    try testing.expect(std.mem.indexOf(u8, cat, "exit 106  AuthFailed") != null);
    try testing.expect(std.mem.indexOf(u8, cat, "config key  timeout_ms (integer)") != null);
    try testing.expect(std.mem.indexOf(u8, cat, "config key  keys.openai (string)") != null);
    try testing.expect(std.mem.indexOf(u8, cat, "doctor check  tls_ca") != null);
    try testing.expect(std.mem.indexOf(u8, cat, "doctor check  client_zed") != null);
}
