//! `tau explain` — the offline catalog lookup surface (no provider or API
//! key needed). A query resolves against SIX registries:
//!
//!   * the stable error catalog (src/errors.zig — mirrored by docs/errors.md)
//!     addressed by decimal exit code or case-insensitive `type` tag,
//!   * the process exit-code catalog (src/exitcodes.zig — mirrored by the
//!     generated docs/exit-codes.md scripting contract) addressed by
//!     `exit.<code>` or `exit.<name>`,
//!   * the config-key catalog (src/configschema.zig — derived from the same
//!     FileConfig/fieldMeta that generates the schema and docs/config.md)
//!     addressed by exact key name or a `keys.<provider>` member path,
//!   * the doctor-check catalog (src/doctorcatalog.zig — the generated check
//!     table in docs/troubleshooting.md) addressed by `doctor.<check>` or a
//!     bare check id,
//!   * the TAU_* env-var catalog (src/envvars.zig — the generated
//!     docs/env.md table) addressed by the variable's exact name, and
//!   * the client catalog (src/clientcatalog.zig — the ClientKind tables in
//!     src/setup.zig rendered by docs/compatibility.md) addressed by
//!     `client.<name>` or a bare `--client` name/alias.
//!
//! Error entries render as {code,type,recoverable,cause,hint,docs}; exit
//! entries as {exit,name,meaning,scripting,docs}; key entries as
//! {key,type,constraints,description,docs}; check entries as
//! {check,fails_when,remediation,docs}; env entries as
//! {env,section,consumers,summary,docs}; client entries as
//! {client,transport,wiring,prereqs,setup,config_dir,settings_path,
//! snippet_path,bridge_path?,verify,doctor_check,docs}. All six shapes are
//! pinned by schema/tau-explain.schema.json and by the tests/golden/ex-*
//! snapshots.

const std = @import("std");
const errors = @import("errors.zig");
const exitcodes = @import("exitcodes.zig");
const cfgschema = @import("configschema.zig");
const doctorcat = @import("doctorcatalog.zig");
const envvars = @import("envvars.zig");
const clientcat = @import("clientcatalog.zig");
const setup = @import("setup.zig");
const suggest = @import("suggest.zig");

/// A resolved `tau explain` query — a stable error entry, a process
/// exit-code entry, a config-key entry, a doctor-check entry, a TAU_*
/// env-var entry, or a supported editor-client entry.
pub const Entry = union(enum) {
    err: errors.Spec,
    exit: exitcodes.Spec,
    key: cfgschema.KeySpec,
    check: doctorcat.CheckSpec,
    env: envvars.Spec,
    client: setup.ClientKind,
};

/// Resolve a query: error catalog first (decimal exit code, or `type` tag
/// matched case-insensitively — so `tau explain timeout` keeps meaning the
/// Timeout error, not a config key), then the exit-code catalog (only the
/// `exit.<code>`/`exit.<name>` spellings reach it — bare codes already
/// resolved as errors above), then the config-key catalog, then the
/// doctor-check catalog, then the TAU_* env-var catalog, then the client
/// catalog. The `doctor.<id>`, `client.<name>`, and `exit.<code>` prefixes
/// skip the shared namespace: `api_key` resolves the config key while
/// `doctor.api_key` resolves the check of the same name; `client.zed`
/// resolves the editor client while bare `client_zed` keeps resolving the
/// doctor check; `80` resolves the invalid_argument error while `exit.80`
/// resolves the process-status scripting contract. Env-var names are exact
/// (uppercase) — `TAU_*` spellings cannot collide with the other catalogs,
/// so they need no prefix. Returns null when nothing matches.
pub fn resolve(query: []const u8) ?Entry {
    if (errors.findSpec(query)) |s| return .{ .err = s };
    if (exitcodes.findSpec(query)) |s| return .{ .exit = s };
    if (cfgschema.findKey(query)) |ks| return .{ .key = ks };
    if (doctorcat.findCheck(query)) |cs| return .{ .check = cs };
    if (envvars.findSpec(std.mem.trim(u8, query, " \t"))) |s| return .{ .env = s };
    if (clientcat.findClient(query)) |k| return .{ .client = k };
    return null;
}

/// Every query `tau explain` resolves — each catalog `type_name` and decimal
/// code, each `exit.<code>` and `exit.<name>` spelling, each config-key name
/// and `keys.<provider>` member path, each doctor-check id in both
/// `doctor.<id>` and bare spellings, each TAU_* env-var name, and each client
/// name in both `client.<name>` and bare spellings — so a suggestion always
/// resolves on retry.
const candidates = blk: {
    var c: [errors.specs.len * 2 + exitcodes.specs.len * 2 + cfgschema.key_catalog.len + cfgschema.deprecated_key_specs.len + doctorcat.check_catalog.len * 2 + envvars.names.len + setup.all_clients.len * 2][]const u8 = undefined;
    for (errors.specs, 0..) |s, i| {
        c[i * 2] = s.type_name;
        c[i * 2 + 1] = std.fmt.comptimePrint("{d}", .{s.code});
    }
    var n = errors.specs.len * 2;
    for (exitcodes.specs) |s| {
        c[n] = std.fmt.comptimePrint("exit.{d}", .{s.code});
        c[n + 1] = "exit." ++ s.name;
        n += 2;
    }
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
    for (envvars.names) |name| {
        c[n] = name;
        n += 1;
    }
    for (setup.all_clients) |k| {
        const name = setup.clientName(k);
        c[n] = name;
        c[n + 1] = "client." ++ name;
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
/// rejected — <x> is the nearest error code, `type` tag, config key,
/// doctor-check id, TAU_* env var, or client name within two
/// case-insensitive edits (`timout_ms` → `"tau explain timeout_ms"`,
/// `doctor.tls-ca` → `"tau explain doctor.tls_ca"`, `TAU_ENDPONT` → `"tau
/// explain TAU_ENDPOINT"`, `client.zde` → `"tau explain client.zed"`),
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
/// {code,type,recoverable,cause,hint,docs} shape; exit entries are
/// {exit,name,meaning,scripting,docs}; key entries are
/// {key,type,constraints,description,docs}; check entries are
/// {check,fails_when,remediation,docs}; env entries are
/// {env,section,consumers,summary,docs}; client entries are the
/// src/clientcatalog.zig Spec shape. Caller owns the returned slice.
pub fn formatEntryJson(a: std.mem.Allocator, entry: Entry) ![]u8 {
    return switch (entry) {
        .err => |s| errors.formatEntryJson(a, s),
        .exit => |s| exitcodes.formatExitJson(a, s),
        .key => |ks| cfgschema.formatKeyJson(a, ks),
        .check => |cs| doctorcat.formatCheckJson(a, cs),
        .env => |s| envvars.formatEnvJson(a, s),
        .client => |k| clientcat.formatClientJson(a, try clientcat.specFor(a, k)),
    };
}

/// Human-readable `tau explain --human` rendering — each entry kind drawn
/// from its own Spec/KeySpec/CheckSpec so prose and JSON can never drift
/// apart.
pub fn formatEntryHuman(a: std.mem.Allocator, entry: Entry) ![]u8 {
    return switch (entry) {
        .err => |s| errors.formatEntryHuman(a, s),
        .exit => |s| exitcodes.formatExitHuman(a, s),
        .key => |ks| cfgschema.formatKeyHuman(a, ks),
        .check => |cs| doctorcat.formatCheckHuman(a, cs),
        .env => |s| envvars.formatEnvHuman(a, s),
        .client => |k| clientcat.formatClientHuman(a, try clientcat.specFor(a, k)),
    };
}

/// The whole catalog as one JSON object (trailing newline included):
/// {"errors":[<error entry>, ...],"config_keys":[<key entry>, ...],
///  "doctor_checks":[<check entry>, ...],"env_vars":[<env entry>, ...],
///  "clients":[<client entry>, ...],"exit_codes":[<exit entry>, ...]}
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
    try b.appendSlice(a, "],\"env_vars\":[");
    for (envvars.specs, 0..) |s, i| {
        if (i > 0) try b.appendSlice(a, ",");
        try b.appendSlice(a, try envvars.formatEnvJson(a, s));
    }
    try b.appendSlice(a, "],\"clients\":[");
    for (setup.all_clients, 0..) |k, i| {
        if (i > 0) try b.appendSlice(a, ",");
        try b.appendSlice(a, try clientcat.formatClientJson(a, try clientcat.specFor(a, k)));
    }
    try b.appendSlice(a, "],\"exit_codes\":[");
    for (exitcodes.specs, 0..) |s, i| {
        if (i > 0) try b.appendSlice(a, ",");
        try b.appendSlice(a, try exitcodes.formatExitJson(a, s));
    }
    try b.appendSlice(a, "]}\n");
    return b.toOwnedSlice(a);
}

/// The whole catalog as prose — error entries, then config-key entries, then
/// doctor-check entries, then env-var entries, then client entries, then
/// exit-code entries, each separated by a blank line. Caller owns the
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
    for (envvars.specs) |s| {
        try b.appendSlice(a, "\n");
        try b.appendSlice(a, try envvars.formatEnvHuman(a, s));
    }
    for (setup.all_clients) |k| {
        try b.appendSlice(a, "\n");
        try b.appendSlice(a, try clientcat.formatClientHuman(a, try clientcat.specFor(a, k)));
    }
    for (exitcodes.specs) |s| {
        try b.appendSlice(a, "\n");
        try b.appendSlice(a, try exitcodes.formatExitHuman(a, s));
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
    try testing.expect(resolve("TAU_NOPE") == null);
    try testing.expect(resolve("exit.bogus") == null);
}

test "resolve: exit.<code> and exit.<name> resolve to exit entries" {
    const zero = resolve("exit.0").?;
    try testing.expect(zero == .exit);
    try testing.expectEqual(@as(u8, 0), zero.exit.code);
    try testing.expectEqualStrings("success", zero.exit.name);
    const code = resolve("exit.80").?;
    try testing.expect(code == .exit);
    try testing.expectEqual(@as(u8, 80), code.exit.code);
    const name = resolve("exit.connection_timeout").?;
    try testing.expect(name == .exit);
    try testing.expectEqual(@as(u8, 105), name.exit.code);
    // Bare codes keep resolving error entries — the `exit.` prefix is what
    // selects the scripting-contract view.
    const bare = resolve("80").?;
    try testing.expect(bare == .err);
    try testing.expectEqual(@as(u8, 80), bare.err.code);
    // The `exit.` namespace fails closed — no uncataloged-code fallback.
    try testing.expect(resolve("exit.42") == null);
    try testing.expect(resolve("exit.") == null);
    try testing.expect(resolve("success") == null);
}

test "resolve: TAU_* env vars resolve to env entries" {
    const e = resolve("TAU_ENDPOINT").?;
    try testing.expect(e == .env);
    try testing.expectEqualStrings("TAU_ENDPOINT", e.env.name);
    try testing.expect(e.env.section == .tau);
    const inst = resolve("TAU_VERSION").?;
    try testing.expect(inst == .env);
    try testing.expect(inst.env.section == .installer);
    const ext = resolve("TAU_TOOLS").?;
    try testing.expect(ext == .env);
    try testing.expect(ext.env.section == .external);
    // Exact case only — lowercase spellings and near-names do not resolve
    // (the did-you-mean path suggests the canonical name instead).
    try testing.expect(resolve("tau_endpoint") == null);
    try testing.expect(resolve("TAU_ENDPONT") == null);
    try testing.expect(resolve("env.TAU_ENDPOINT") == null);
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

test "resolve: client names resolve prefixed, bare, and aliased" {
    const prefixed = resolve("client.zed").?;
    try testing.expect(prefixed == .client);
    try testing.expectEqual(setup.ClientKind.zed, prefixed.client);
    const bare = resolve("zed").?;
    try testing.expect(bare == .client);
    try testing.expectEqual(setup.ClientKind.zed, bare.client);
    // --client aliases resolve under the prefix and bare too.
    const alias = resolve("client.claude").?;
    try testing.expectEqual(setup.ClientKind.claude_desktop, alias.client);
    const alias_bare = resolve("gemini-cli").?;
    try testing.expectEqual(setup.ClientKind.gemini, alias_bare.client);
    // The underscore check id still belongs to the doctor catalog — the
    // dotted client spelling is the client entry.
    const check = resolve("client_zed").?;
    try testing.expect(check == .check);
    try testing.expectEqualStrings("client_zed", check.check.name);
    // Unknown clients and the `all` fan-out stay unresolvable.
    try testing.expect(resolve("client.nope") == null);
    try testing.expect(resolve("client.") == null);
    try testing.expect(resolve("all") == null);
}

test "suggestQuery covers error codes, types, config keys, env vars, and clients" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try testing.expectEqualStrings(" — did you mean \"tau explain AuthFailed\"?", suggestQuery(a, "authfaild").?);
    try testing.expectEqualStrings(" — did you mean \"tau explain 106\"?", suggestQuery(a, "1066").?);
    try testing.expectEqualStrings(" — did you mean \"tau explain exit.106\"?", suggestQuery(a, "exit.1066").?);
    try testing.expectEqualStrings(" — did you mean \"tau explain exit.success\"?", suggestQuery(a, "exit.succes").?);
    try testing.expectEqualStrings(" — did you mean \"tau explain timeout_ms\"?", suggestQuery(a, "timout_ms").?);
    try testing.expectEqualStrings(" — did you mean \"tau explain keys.openai\"?", suggestQuery(a, "keys.openia").?);
    try testing.expectEqualStrings(" — did you mean \"tau explain provider\"?", suggestQuery(a, "Provider").?);
    try testing.expectEqualStrings(" — did you mean \"tau explain doctor.tls_ca\"?", suggestQuery(a, "doctor.tls-ca").?);
    try testing.expectEqualStrings(" — did you mean \"tau explain tls_ca\"?", suggestQuery(a, "tls-ca").?);
    // TAU_* typos — including lowercase — land on the canonical env var.
    try testing.expectEqualStrings(" — did you mean \"tau explain TAU_ENDPOINT\"?", suggestQuery(a, "TAU_ENDPONT").?);
    try testing.expectEqualStrings(" — did you mean \"tau explain TAU_YES\"?", suggestQuery(a, "tau_yes").?);
    // Client-name typos land on the nearest client spelling.
    try testing.expectEqualStrings(" — did you mean \"tau explain zed\"?", suggestQuery(a, "zedd").?);
    try testing.expectEqualStrings(" — did you mean \"tau explain client.zed\"?", suggestQuery(a, "client.zde").?);
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
    const env = try formatEntryJson(a, .{ .env = envvars.findSpec("TAU_ENDPOINT").? });
    try testing.expect(std.mem.indexOf(u8, env, "\"env\":\"TAU_ENDPOINT\"") != null);
    const client = try formatEntryJson(a, .{ .client = .zed });
    try testing.expect(std.mem.indexOf(u8, client, "\"client\":\"zed\"") != null);
    const exit_entry = try formatEntryJson(a, .{ .exit = exitcodes.findSpec("exit.0").? });
    try testing.expect(std.mem.indexOf(u8, exit_entry, "\"exit\":0") != null);
    try testing.expect(std.mem.indexOf(u8, exit_entry, "\"name\":\"success\"") != null);
}

test "formatCatalogJson emits errors + config_keys + doctor_checks + env_vars + clients + exit_codes arrays" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const cat = try formatCatalogJson(a);
    try testing.expect(std.mem.startsWith(u8, cat, "{\"errors\":["));
    try testing.expect(std.mem.endsWith(u8, cat, "]}\n"));
    try testing.expect(std.mem.indexOf(u8, cat, "\"config_keys\":[") != null);
    try testing.expect(std.mem.indexOf(u8, cat, "\"doctor_checks\":[") != null);
    try testing.expect(std.mem.indexOf(u8, cat, "\"env_vars\":[") != null);
    try testing.expect(std.mem.indexOf(u8, cat, "\"clients\":[") != null);
    try testing.expect(std.mem.indexOf(u8, cat, "\"exit_codes\":[") != null);
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
    for (envvars.specs) |s| {
        var buf: [80]u8 = undefined;
        const needle = std.fmt.bufPrint(&buf, "\"env\":\"{s}\"", .{s.name}) catch unreachable;
        try testing.expect(std.mem.indexOf(u8, cat, needle) != null);
    }
    for (setup.all_clients) |k| {
        var buf: [80]u8 = undefined;
        const needle = std.fmt.bufPrint(&buf, "\"client\":\"{s}\"", .{setup.clientName(k)}) catch unreachable;
        try testing.expect(std.mem.indexOf(u8, cat, needle) != null);
    }
    for (exitcodes.specs) |s| {
        var buf: [80]u8 = undefined;
        const needle = std.fmt.bufPrint(&buf, "\"exit\":{d}", .{s.code}) catch unreachable;
        try testing.expect(std.mem.indexOf(u8, cat, needle) != null);
    }
    // The catalog JSON must parse cleanly.
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, cat, .{});
    try testing.expect(v.object.get("config_keys").?.array.items.len == cfgschema.key_catalog.len);
    try testing.expect(v.object.get("doctor_checks").?.array.items.len == doctorcat.check_catalog.len);
    try testing.expect(v.object.get("env_vars").?.array.items.len == envvars.specs.len);
    try testing.expect(v.object.get("clients").?.array.items.len == setup.all_clients.len);
    try testing.expect(v.object.get("exit_codes").?.array.items.len == exitcodes.specs.len);
}

test "formatCatalogHuman renders all six sections" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const cat = try formatCatalogHuman(a);
    try testing.expect(std.mem.indexOf(u8, cat, "exit 106  AuthFailed") != null);
    try testing.expect(std.mem.indexOf(u8, cat, "config key  timeout_ms (integer)") != null);
    try testing.expect(std.mem.indexOf(u8, cat, "config key  keys.openai (string)") != null);
    try testing.expect(std.mem.indexOf(u8, cat, "doctor check  tls_ca") != null);
    try testing.expect(std.mem.indexOf(u8, cat, "doctor check  client_zed") != null);
    try testing.expect(std.mem.indexOf(u8, cat, "env var  TAU_ENDPOINT (tau)") != null);
    try testing.expect(std.mem.indexOf(u8, cat, "env var  TAU_BIN (external)") != null);
    try testing.expect(std.mem.indexOf(u8, cat, "client  zed (acp · direct)") != null);
    try testing.expect(std.mem.indexOf(u8, cat, "client  claude-desktop (mcacp · direct)") != null);
    try testing.expect(std.mem.indexOf(u8, cat, "client  goose (mcacp · snippet)") != null);
    try testing.expect(std.mem.indexOf(u8, cat, "exit 0  success") != null);
    try testing.expect(std.mem.indexOf(u8, cat, "exit 106  auth_failed") != null);
}
