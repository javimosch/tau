//! `tau explain` — the offline catalog lookup surface (no provider or API
//! key needed). A query resolves against SEVEN registries:
//!
//!   * the stable error catalog (src/errors.zig — mirrored by docs/errors.md)
//!     addressed by decimal exit code or case-insensitive `type` tag,
//!   * the config-key catalog (src/configschema.zig — derived from the same
//!     FileConfig/fieldMeta that generates the schema and docs/config.md)
//!     addressed by exact key name or a `keys.<provider>` member path,
//!   * the doctor-check catalog (src/doctorcatalog.zig — the generated check
//!     table in docs/troubleshooting.md) addressed by `doctor.<check>` or a
//!     bare check id,
//!   * the TAU_* env-var catalog (src/envvars.zig — the generated
//!     docs/env.md table) addressed by the variable's exact name,
//!   * the client catalog (src/clientcatalog.zig — the ClientKind tables in
//!     src/setup.zig rendered by docs/compatibility.md) addressed by
//!     `client.<name>` or a bare `--client` name/alias,
//!   * the curated-topic catalog (src/topiccatalog.zig — hand-written
//!     subjects like `privacy` that no generated registry backs) addressed
//!     by `topic.<name>` or a bare topic name, and
//!   * the subcommand catalog (src/subcommandcatalog.zig — one entry per
//!     registered subcommand: usage, runnable examples, and links to the
//!     related error `type` tags, config keys, and `doctor.<check>` ids)
//!     addressed by `subcommand.<name>` or a bare subcommand name.
//!
//! Error entries render as {code,type,recoverable,cause,hint,docs}; key
//! entries as {key,type,constraints,description,docs}; check entries as
//! {check,fails_when,remediation,docs}; env entries as
//! {env,section,consumers,summary,docs}; client entries as
//! {client,transport,wiring,prereqs,setup,config_dir,settings_path,
//! snippet_path,bridge_path?,verify,doctor_check,docs}; topic entries as
//! {topic,summary,details,see_also,docs}; subcommand entries as
//! {subcommand,summary,usage,examples,errors,config_keys,doctor_checks,
//! docs}. `--list` renders the topic index
//! (every resolvable name, no entry bodies) and `--search <text>` renders
//! that same index filtered to the entries whose searchable text matches
//! every whitespace-separated term, case-insensitively. All shapes are
//! pinned by schema/tau-explain.schema.json and by the tests/golden/ex-*
//! snapshots.

const std = @import("std");
const errors = @import("errors.zig");
const cfgschema = @import("configschema.zig");
const doctorcat = @import("doctorcatalog.zig");
const envvars = @import("envvars.zig");
const json = @import("json.zig");
const clientcat = @import("clientcatalog.zig");
const topiccat = @import("topiccatalog.zig");
const subcat = @import("subcommandcatalog.zig");
const setup = @import("setup.zig");
const suggest = @import("suggest.zig");

/// A resolved `tau explain` query — a stable error entry, a config-key
/// entry, a doctor-check entry, a TAU_* env-var entry, a supported
/// editor-client entry, a curated-topic entry, or a subcommand entry.
pub const Entry = union(enum) {
    err: errors.Spec,
    key: cfgschema.KeySpec,
    check: doctorcat.CheckSpec,
    env: envvars.Spec,
    client: setup.ClientKind,
    topic: topiccat.Spec,
    subcommand: subcat.Spec,
};

/// Resolve a query: error catalog first (decimal exit code, or `type` tag
/// matched case-insensitively — so `tau explain timeout` keeps meaning the
/// Timeout error, not a config key), then the config-key catalog, then the
/// doctor-check catalog, then the TAU_* env-var catalog, then the client
/// catalog. The `config.<key>`, `doctor.<id>`, and `client.<name>` prefixes
/// skip the shared namespace: `api_key` resolves the config key while
/// `doctor.api_key` resolves the check of the same name; `client.zed`
/// resolves the editor client while bare `client_zed` keeps resolving the
/// doctor check; `config.provider` is the namespaced spelling of `provider`.
/// Env-var
/// names are exact (uppercase) — `TAU_*` spellings cannot collide with the
/// other catalogs, so they need no prefix. Subcommand names resolve last —
/// the earlier registries win on any shared name (`doctor` stays the
/// subcommand because no check id or key claims it; a hypothetical future
/// `setup` config key would need the `subcommand.setup` spelling).
/// Returns null when nothing matches.
pub fn resolve(query: []const u8) ?Entry {
    if (errors.findSpec(query)) |s| return .{ .err = s };
    if (cfgschema.findKey(query)) |ks| return .{ .key = ks };
    if (doctorcat.findCheck(query)) |cs| return .{ .check = cs };
    if (envvars.findSpec(std.mem.trim(u8, query, " \t"))) |s| return .{ .env = s };
    if (clientcat.findClient(query)) |k| return .{ .client = k };
    if (topiccat.findSpec(query)) |s| return .{ .topic = s };
    if (subcat.findSpec(query)) |s| return .{ .subcommand = s };
    return null;
}

/// Every query `tau explain` resolves — each catalog `type_name` and decimal
/// code, each config-key name and `keys.<provider>` member path in both
/// `config.<key>` and bare spellings, each doctor-check id in both
/// `doctor.<id>` and bare spellings, each TAU_* env-var name, each client
/// name in both `client.<name>` and bare spellings, each topic in both
/// `topic.<name>` and bare spellings, and each subcommand in both
/// `subcommand.<name>` and bare spellings —
/// so a suggestion always resolves on retry.
const candidates = blk: {
    var c: [errors.specs.len * 2 + cfgschema.key_catalog.len * 2 + cfgschema.deprecated_key_specs.len * 2 + doctorcat.check_catalog.len * 2 + envvars.names.len + setup.all_clients.len * 2 + topiccat.names.len * 2 + subcat.names.len * 2][]const u8 = undefined;
    for (errors.specs, 0..) |s, i| {
        c[i * 2] = s.type_name;
        c[i * 2 + 1] = std.fmt.comptimePrint("{d}", .{s.code});
    }
    var n = errors.specs.len * 2;
    for (cfgschema.key_catalog) |ks| {
        c[n] = ks.name;
        c[n + 1] = "config." ++ ks.name;
        n += 2;
    }
    for (cfgschema.deprecated_key_specs) |ks| {
        c[n] = ks.name;
        c[n + 1] = "config." ++ ks.name;
        n += 2;
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
    for (topiccat.names) |name| {
        c[n] = name;
        c[n + 1] = "topic." ++ name;
        n += 2;
    }
    for (subcat.names) |name| {
        c[n] = name;
        c[n + 1] = "subcommand." ++ name;
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
/// {code,type,recoverable,cause,hint,docs} shape; key entries are
/// {key,type,constraints,description,docs}; check entries are
/// {check,fails_when,remediation,docs}; env entries are
/// {env,section,consumers,summary,docs}; client entries are the
/// src/clientcatalog.zig Spec shape; topic entries are the
/// src/topiccatalog.zig Spec shape; subcommand entries are the
/// src/subcommandcatalog.zig Spec shape. Caller owns the returned slice.
pub fn formatEntryJson(a: std.mem.Allocator, entry: Entry) ![]u8 {
    return switch (entry) {
        .err => |s| errors.formatEntryJson(a, s),
        .key => |ks| cfgschema.formatKeyJson(a, ks),
        .check => |cs| doctorcat.formatCheckJson(a, cs),
        .env => |s| envvars.formatEnvJson(a, s),
        .client => |k| clientcat.formatClientJson(a, try clientcat.specFor(a, k)),
        .topic => |s| topiccat.formatTopicJson(a, s),
        .subcommand => |s| subcat.formatSubcommandJson(a, s),
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
        .env => |s| envvars.formatEnvHuman(a, s),
        .client => |k| clientcat.formatClientHuman(a, try clientcat.specFor(a, k)),
        .topic => |s| topiccat.formatTopicHuman(a, s),
        .subcommand => |s| subcat.formatSubcommandHuman(a, s),
    };
}

/// The whole catalog as one JSON object (trailing newline included):
/// {"errors":[<error entry>, ...],"config_keys":[<key entry>, ...],
///  "doctor_checks":[<check entry>, ...],"env_vars":[<env entry>, ...],
///  "clients":[<client entry>, ...],"topics":[<topic entry>, ...],
///  "subcommands":[<subcommand entry>, ...]}
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
    try b.appendSlice(a, "],\"topics\":[");
    for (topiccat.specs, 0..) |s, i| {
        if (i > 0) try b.appendSlice(a, ",");
        try b.appendSlice(a, try topiccat.formatTopicJson(a, s));
    }
    try b.appendSlice(a, "],\"subcommands\":[");
    for (subcat.specs, 0..) |s, i| {
        if (i > 0) try b.appendSlice(a, ",");
        try b.appendSlice(a, try subcat.formatSubcommandJson(a, s));
    }
    try b.appendSlice(a, "]}\n");
    return b.toOwnedSlice(a);
}

/// The whole catalog as prose — error entries, then config-key entries, then
/// doctor-check entries, then env-var entries, then client entries, then
/// topic entries, then subcommand entries, each
/// separated by a blank line. Caller owns the returned slice.
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
    for (topiccat.specs) |s| {
        try b.appendSlice(a, "\n");
        try b.appendSlice(a, try topiccat.formatTopicHuman(a, s));
    }
    for (subcat.specs) |s| {
        try b.appendSlice(a, "\n");
        try b.appendSlice(a, try subcat.formatSubcommandHuman(a, s));
    }
    return b.toOwnedSlice(a);
}

/// Append `"<escaped s>"` to buf.
fn jstr(a: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
    try buf.append(a, '"');
    try json.escapeInto(a, buf, s);
    try buf.append(a, '"');
}

/// The filtered-or-full topic lists behind `--list` and `--search` — one
/// slice per registry, in catalog row order. `config_keys` covers both the
/// live keys and the deprecated spellings (the index lists both).
pub const TopicLists = struct {
    errors: []const errors.Spec,
    config_keys: []const cfgschema.KeySpec,
    doctor_checks: []const doctorcat.CheckSpec,
    env_vars: []const envvars.Spec,
    clients: []const setup.ClientKind,
    topics: []const topiccat.Spec,
    subcommands: []const subcat.Spec,
};

/// Every key the index lists — live catalog rows first, deprecated
/// spellings after (the order --list has always emitted).
const all_keys = cfgschema.key_catalog ++ cfgschema.deprecated_key_specs;

/// The unfiltered index — every topic resolve() accepts.
fn indexLists() TopicLists {
    return .{
        .errors = &errors.specs,
        .config_keys = &all_keys,
        .doctor_checks = &doctorcat.check_catalog,
        .env_vars = &envvars.specs,
        .clients = &setup.all_clients,
        .topics = &topiccat.specs,
        .subcommands = &subcat.specs,
    };
}

/// Append the `{"errors":[...],"config_keys":[...],...}` object body (the
/// index/search `topics` member value — no outer braces' siblings) to buf.
fn appendTopicsJson(a: std.mem.Allocator, b: *std.ArrayList(u8), m: TopicLists) !void {
    try b.appendSlice(a, "{\"errors\":[");
    for (m.errors, 0..) |s, i| {
        if (i > 0) try b.appendSlice(a, ",");
        try b.appendSlice(a, try std.fmt.allocPrint(a, "{{\"code\":{d},\"type\":\"{s}\"}}", .{ s.code, s.type_name }));
    }
    try b.appendSlice(a, "],\"config_keys\":[");
    for (m.config_keys, 0..) |ks, i| {
        if (i > 0) try b.appendSlice(a, ",");
        try jstr(a, b, ks.name);
    }
    try b.appendSlice(a, "],\"doctor_checks\":[");
    for (m.doctor_checks, 0..) |cs, i| {
        if (i > 0) try b.appendSlice(a, ",");
        try jstr(a, b, try std.fmt.allocPrint(a, "doctor.{s}", .{cs.name}));
    }
    try b.appendSlice(a, "],\"env_vars\":[");
    for (m.env_vars, 0..) |s, i| {
        if (i > 0) try b.appendSlice(a, ",");
        try jstr(a, b, s.name);
    }
    try b.appendSlice(a, "],\"clients\":[");
    for (m.clients, 0..) |k, i| {
        if (i > 0) try b.appendSlice(a, ",");
        try jstr(a, b, try std.fmt.allocPrint(a, "client.{s}", .{setup.clientName(k)}));
    }
    try b.appendSlice(a, "],\"topics\":[");
    for (m.topics, 0..) |s, i| {
        if (i > 0) try b.appendSlice(a, ",");
        try jstr(a, b, try std.fmt.allocPrint(a, "topic.{s}", .{s.name}));
    }
    try b.appendSlice(a, "],\"subcommands\":[");
    for (m.subcommands, 0..) |s, i| {
        if (i > 0) try b.appendSlice(a, ",");
        try jstr(a, b, try std.fmt.allocPrint(a, "subcommand.{s}", .{s.name}));
    }
    try b.appendSlice(a, "]}");
}

/// The topic index for `tau explain --list` (trailing newline included):
/// {"topics":{"errors":[{"code":N,"type":"T"}, ...],
///  "config_keys":["<key>", ...],"doctor_checks":["doctor.<id>", ...],
///  "env_vars":["TAU_*", ...],"clients":["client.<name>", ...],
///  "topics":["topic.<name>", ...],"subcommands":["subcommand.<name>", ...]}}
/// Where the bare `tau explain` dump carries every full entry, the index
/// carries only what each topic is addressed by — code + type tag for
/// errors, the namespaced spelling for doctor checks and clients — so it
/// doubles as the machine-readable list of valid queries. Every listed
/// name resolves via resolve(). Caller owns the returned slice.
pub fn formatIndexJson(a: std.mem.Allocator) ![]u8 {
    var b: std.ArrayList(u8) = .empty;
    try b.appendSlice(a, "{\"topics\":");
    try appendTopicsJson(a, &b, indexLists());
    try b.appendSlice(a, "}\n");
    return b.toOwnedSlice(a);
}

/// Append the prose sections for m — one section per non-empty registry,
/// blank-line separated, one resolvable name per line (errors carry both
/// addressable forms: code and type tag).
fn appendTopicsHuman(a: std.mem.Allocator, b: *std.ArrayList(u8), m: TopicLists) !void {
    var wrote = false;
    if (m.errors.len > 0) {
        try b.appendSlice(a, "error codes:\n");
        for (m.errors) |s| {
            try b.appendSlice(a, try std.fmt.allocPrint(a, "  {d:>3}  {s}\n", .{ s.code, s.type_name }));
        }
        wrote = true;
    }
    if (m.config_keys.len > 0) {
        if (wrote) try b.appendSlice(a, "\n");
        try b.appendSlice(a, "config keys:\n");
        for (m.config_keys) |ks| {
            try b.appendSlice(a, try std.fmt.allocPrint(a, "  {s}\n", .{ks.name}));
        }
        wrote = true;
    }
    if (m.doctor_checks.len > 0) {
        if (wrote) try b.appendSlice(a, "\n");
        try b.appendSlice(a, "doctor checks:\n");
        for (m.doctor_checks) |cs| {
            try b.appendSlice(a, try std.fmt.allocPrint(a, "  doctor.{s}\n", .{cs.name}));
        }
        wrote = true;
    }
    if (m.env_vars.len > 0) {
        if (wrote) try b.appendSlice(a, "\n");
        try b.appendSlice(a, "env vars:\n");
        for (m.env_vars) |s| {
            try b.appendSlice(a, try std.fmt.allocPrint(a, "  {s}\n", .{s.name}));
        }
        wrote = true;
    }
    if (m.clients.len > 0) {
        if (wrote) try b.appendSlice(a, "\n");
        try b.appendSlice(a, "clients:\n");
        for (m.clients) |k| {
            try b.appendSlice(a, try std.fmt.allocPrint(a, "  client.{s}\n", .{setup.clientName(k)}));
        }
        wrote = true;
    }
    if (m.topics.len > 0) {
        if (wrote) try b.appendSlice(a, "\n");
        try b.appendSlice(a, "topics:\n");
        for (m.topics) |s| {
            try b.appendSlice(a, try std.fmt.allocPrint(a, "  topic.{s}\n", .{s.name}));
        }
        wrote = true;
    }
    if (m.subcommands.len > 0) {
        if (wrote) try b.appendSlice(a, "\n");
        try b.appendSlice(a, "subcommands:\n");
        for (m.subcommands) |s| {
            try b.appendSlice(a, try std.fmt.allocPrint(a, "  subcommand.{s}\n", .{s.name}));
        }
    }
}

/// The topic index as prose — one section per catalog, one resolvable name
/// per line (errors carry both addressable forms: code and type tag).
/// Caller owns the returned slice.
pub fn formatIndexHuman(a: std.mem.Allocator) ![]u8 {
    var b: std.ArrayList(u8) = .empty;
    try b.appendSlice(a, "explain topics (each resolves via `tau explain <name>`):\n\n");
    try appendTopicsHuman(a, &b, indexLists());
    return b.toOwnedSlice(a);
}

/// Split a --search text on ASCII whitespace into lowercased terms — an
/// entry matches when every term is a case-insensitive substring of its
/// search text (AND semantics; `api key` asks for entries mentioning
/// both). Caller owns the returned slice; empty when the query is all
/// whitespace (args.zig rejects that path before it reaches here).
fn searchTerms(a: std.mem.Allocator, query: []const u8) ![]const []const u8 {
    var terms: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, query, " \t");
    while (it.next()) |t| {
        try terms.append(a, try std.ascii.allocLowerString(a, t));
    }
    return terms.toOwnedSlice(a);
}

/// The lowercased concatenation of an entry's searchable text fields.
fn searchHaystack(a: std.mem.Allocator, parts: []const []const u8) ![]const u8 {
    return std.ascii.allocLowerString(a, try std.mem.join(a, " ", parts));
}

/// True when every term appears somewhere in the lowercased haystack.
fn allTermsHit(hay: []const u8, terms: []const []const u8) bool {
    for (terms) |t| {
        if (std.mem.indexOf(u8, hay, t) == null) return false;
    }
    return true;
}

/// The `tau explain --search <text>` result — the same per-registry lists
/// --list renders, filtered to the entries whose searchable text matches
/// every whitespace-separated term (case-insensitive). Searched text: an
/// error's code + type + cause + hint, a config key's name + type +
/// constraints + description, a check's id + fails_when + remediation, an
/// env var's name + consumers + summary, a client's name + transport +
/// wiring + prereqs + verify + doctor check (plus `--client` alias
/// resolution — `roo` and `amazon-q` reach their clients by name), a
/// topic's name + summary + details + see_also, and a subcommand's name +
/// summary + usage + examples + related links. Caller owns the slices.
pub fn searchCatalog(a: std.mem.Allocator, query: []const u8) !TopicLists {
    const terms = try searchTerms(a, query);
    var errs: std.ArrayList(errors.Spec) = .empty;
    var keys: std.ArrayList(cfgschema.KeySpec) = .empty;
    var checks: std.ArrayList(doctorcat.CheckSpec) = .empty;
    var envs: std.ArrayList(envvars.Spec) = .empty;
    var clients: std.ArrayList(setup.ClientKind) = .empty;
    var topics: std.ArrayList(topiccat.Spec) = .empty;
    var subs: std.ArrayList(subcat.Spec) = .empty;
    if (terms.len > 0) {
        for (errors.specs) |s| {
            const hay = try searchHaystack(a, &.{ try std.fmt.allocPrint(a, "{d}", .{s.code}), s.type_name, s.cause, s.hint });
            if (allTermsHit(hay, terms)) try errs.append(a, s);
        }
        for (all_keys) |ks| {
            const hay = try searchHaystack(a, &.{ ks.name, ks.type_name, ks.constraints, ks.desc });
            if (allTermsHit(hay, terms)) try keys.append(a, ks);
        }
        for (doctorcat.check_catalog) |cs| {
            const hay = try searchHaystack(a, &.{ cs.name, try std.fmt.allocPrint(a, "doctor.{s}", .{cs.name}), cs.fails_when, cs.remediation });
            if (allTermsHit(hay, terms)) try checks.append(a, cs);
        }
        for (envvars.specs) |s| {
            const hay = try searchHaystack(a, &.{ s.name, s.consumers, s.summary });
            if (allTermsHit(hay, terms)) try envs.append(a, s);
        }
        for (setup.all_clients) |k| {
            const s = try clientcat.specFor(a, k);
            const hay = try searchHaystack(a, &.{ s.client, try std.fmt.allocPrint(a, "client.{s}", .{s.client}), @tagName(s.transport), @tagName(s.wiring), s.prereqs, s.verify, s.doctor_check });
            const hit = for (terms) |t| {
                // Aliases match by resolution, not substring — `amazon-q`
                // and `codex-cli` aren't substrings of the canonical names.
                if (std.mem.indexOf(u8, hay, t) == null and setup.parseClientName(t) != k) break false;
            } else true;
            if (hit) try clients.append(a, k);
        }
        for (topiccat.specs) |s| {
            const hay = try searchHaystack(a, &.{ s.name, try std.fmt.allocPrint(a, "topic.{s}", .{s.name}), s.summary, s.details, try std.mem.join(a, " ", s.see_also) });
            if (allTermsHit(hay, terms)) try topics.append(a, s);
        }
        for (subcat.specs) |s| {
            const hay = try searchHaystack(a, &.{ s.name, try std.fmt.allocPrint(a, "subcommand.{s}", .{s.name}), s.summary, s.usage, try std.mem.join(a, " ", s.examples), try std.mem.join(a, " ", s.errors), try std.mem.join(a, " ", s.config_keys), try std.mem.join(a, " ", s.doctor_checks) });
            if (allTermsHit(hay, terms)) try subs.append(a, s);
        }
    }
    return .{
        .errors = try errs.toOwnedSlice(a),
        .config_keys = try keys.toOwnedSlice(a),
        .doctor_checks = try checks.toOwnedSlice(a),
        .env_vars = try envs.toOwnedSlice(a),
        .clients = try clients.toOwnedSlice(a),
        .topics = try topics.toOwnedSlice(a),
        .subcommands = try subs.toOwnedSlice(a),
    };
}

/// The `tau explain --search <text>` result as JSON (trailing newline
/// included): {"query":"<text>","topics":{<the --list index shape,
/// filtered>}}. Every listed name resolves via resolve(). Caller owns the
/// returned slice.
pub fn formatSearchJson(a: std.mem.Allocator, query: []const u8) ![]u8 {
    var b: std.ArrayList(u8) = .empty;
    try b.appendSlice(a, "{\"query\":");
    try jstr(a, &b, query);
    try b.appendSlice(a, ",\"topics\":");
    try appendTopicsJson(a, &b, try searchCatalog(a, query));
    try b.appendSlice(a, "}\n");
    return b.toOwnedSlice(a);
}

/// The `tau explain --search <text>` result as prose — the index's
/// sectioned name list, filtered, empty sections omitted. No matches at
/// all renders a single note pointing at the full index. Caller owns the
/// returned slice.
pub fn formatSearchHuman(a: std.mem.Allocator, query: []const u8) ![]u8 {
    const m = try searchCatalog(a, query);
    var b: std.ArrayList(u8) = .empty;
    if (m.errors.len + m.config_keys.len + m.doctor_checks.len + m.env_vars.len + m.clients.len + m.topics.len + m.subcommands.len == 0) {
        try b.appendSlice(a, try std.fmt.allocPrint(a, "no explain topics match \"{s}\" — run `tau explain --list` for the full topic index\n", .{query}));
        return b.toOwnedSlice(a);
    }
    try b.appendSlice(a, try std.fmt.allocPrint(a, "explain topics matching \"{s}\" (each resolves via `tau explain <name>`):\n\n", .{query}));
    try appendTopicsHuman(a, &b, m);
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

test "resolve: topics resolve prefixed and bare" {
    const bare = resolve("privacy").?;
    try testing.expect(bare == .topic);
    try testing.expectEqualStrings("privacy", bare.topic.name);
    const prefixed = resolve("topic.privacy").?;
    try testing.expect(prefixed == .topic);
    try testing.expectEqualStrings("privacy", prefixed.topic.name);
    try testing.expect(resolve("topic.") == null);
    try testing.expect(resolve("topic.bogus") == null);
    try testing.expect(resolve("privavy") == null);
}

test "resolve: subcommand names resolve prefixed and bare" {
    const bare = resolve("doctor").?;
    try testing.expect(bare == .subcommand);
    try testing.expectEqualStrings("doctor", bare.subcommand.name);
    const prefixed = resolve("subcommand.fleet").?;
    try testing.expect(prefixed == .subcommand);
    try testing.expectEqualStrings("fleet", prefixed.subcommand.name);
    // Every registered subcommand resolves both ways.
    for (subcat.names) |name| {
        try testing.expect(resolve(name).? == .subcommand);
        const q = try std.fmt.allocPrint(testing.allocator, "subcommand.{s}", .{name});
        defer testing.allocator.free(q);
        try testing.expect(resolve(q).? == .subcommand);
    }
    try testing.expect(resolve("subcommand.") == null);
    try testing.expect(resolve("subcommand.bogus") == null);
    try testing.expect(resolve("doktor") == null);
}

test "suggestQuery covers error codes, types, config keys, env vars, clients, topics, and subcommands" {
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
    // TAU_* typos — including lowercase — land on the canonical env var.
    try testing.expectEqualStrings(" — did you mean \"tau explain TAU_ENDPOINT\"?", suggestQuery(a, "TAU_ENDPONT").?);
    try testing.expectEqualStrings(" — did you mean \"tau explain TAU_YES\"?", suggestQuery(a, "tau_yes").?);
    // Client-name typos land on the nearest client spelling.
    try testing.expectEqualStrings(" — did you mean \"tau explain zed\"?", suggestQuery(a, "zedd").?);
    try testing.expectEqualStrings(" — did you mean \"tau explain client.zed\"?", suggestQuery(a, "client.zde").?);
    // Topic typos land on the nearest topic spelling.
    try testing.expectEqualStrings(" — did you mean \"tau explain privacy\"?", suggestQuery(a, "privavy").?);
    try testing.expectEqualStrings(" — did you mean \"tau explain topic.privacy\"?", suggestQuery(a, "topic.privavy").?);
    // Subcommand typos land on the nearest subcommand spelling.
    try testing.expectEqualStrings(" — did you mean \"tau explain doctor\"?", suggestQuery(a, "doktor").?);
    try testing.expectEqualStrings(" — did you mean \"tau explain subcommand.fleet\"?", suggestQuery(a, "subcommand.flet").?);
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
    const topic = try formatEntryJson(a, .{ .topic = @import("topiccatalog.zig").findSpec("privacy").? });
    try testing.expect(std.mem.indexOf(u8, topic, "\"topic\":\"privacy\"") != null);
    const sub = try formatEntryJson(a, .{ .subcommand = subcat.findSpec("setup").? });
    try testing.expect(std.mem.indexOf(u8, sub, "\"subcommand\":\"setup\"") != null);
}

test "formatCatalogJson emits errors + config_keys + doctor_checks + env_vars + clients + topics + subcommands arrays" {
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
    try testing.expect(std.mem.indexOf(u8, cat, "\"topics\":[") != null);
    try testing.expect(std.mem.indexOf(u8, cat, "\"subcommands\":[") != null);
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
    for (topiccat.specs) |s| {
        var buf: [80]u8 = undefined;
        const needle = std.fmt.bufPrint(&buf, "\"topic\":\"{s}\"", .{s.name}) catch unreachable;
        try testing.expect(std.mem.indexOf(u8, cat, needle) != null);
    }
    for (subcat.specs) |s| {
        var buf: [80]u8 = undefined;
        const needle = std.fmt.bufPrint(&buf, "\"subcommand\":\"{s}\"", .{s.name}) catch unreachable;
        try testing.expect(std.mem.indexOf(u8, cat, needle) != null);
    }
    // The catalog JSON must parse cleanly.
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, cat, .{});
    try testing.expect(v.object.get("config_keys").?.array.items.len == cfgschema.key_catalog.len);
    try testing.expect(v.object.get("doctor_checks").?.array.items.len == doctorcat.check_catalog.len);
    try testing.expect(v.object.get("env_vars").?.array.items.len == envvars.specs.len);
    try testing.expect(v.object.get("clients").?.array.items.len == setup.all_clients.len);
    try testing.expect(v.object.get("topics").?.array.items.len == topiccat.specs.len);
    try testing.expect(v.object.get("subcommands").?.array.items.len == subcat.specs.len);
}

test "formatCatalogHuman renders all seven sections" {
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
    try testing.expect(std.mem.indexOf(u8, cat, "topic  privacy") != null);
    try testing.expect(std.mem.indexOf(u8, cat, "subcommand  doctor") != null);
    try testing.expect(std.mem.indexOf(u8, cat, "subcommand  setup") != null);
}

test "formatIndexJson emits the topics object and every listed topic resolves" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const idx = try formatIndexJson(a);
    try testing.expect(std.mem.startsWith(u8, idx, "{\"topics\":{\"errors\":["));
    try testing.expect(std.mem.endsWith(u8, idx, "]}}\n"));
    // The index JSON must parse cleanly and carry all six slices.
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, idx, .{});
    const topics = v.object.get("topics").?.object;
    try testing.expect(topics.get("errors").?.array.items.len == errors.specs.len);
    try testing.expect(topics.get("config_keys").?.array.items.len == cfgschema.key_catalog.len + cfgschema.deprecated_key_specs.len);
    try testing.expect(topics.get("doctor_checks").?.array.items.len == doctorcat.check_catalog.len);
    try testing.expect(topics.get("env_vars").?.array.items.len == envvars.names.len);
    try testing.expect(topics.get("clients").?.array.items.len == setup.all_clients.len);
    try testing.expect(topics.get("topics").?.array.items.len == topiccat.names.len);
    try testing.expect(topics.get("subcommands").?.array.items.len == subcat.names.len);
    // Every indexed name resolves — the index is a list of valid queries.
    for (topics.get("errors").?.array.items) |e| {
        const code = e.object.get("code").?.integer;
        const q = try std.fmt.allocPrint(a, "{d}", .{code});
        const entry = resolve(q).?;
        try testing.expect(entry == .err);
        try testing.expectEqual(@as(u8, @intCast(code)), entry.err.code);
    }
    for (topics.get("config_keys").?.array.items) |e| {
        try testing.expect(resolve(e.string).? == .key);
    }
    for (topics.get("doctor_checks").?.array.items) |e| {
        try testing.expect(resolve(e.string).? == .check);
    }
    for (topics.get("env_vars").?.array.items) |e| {
        try testing.expect(resolve(e.string).? == .env);
    }
    for (topics.get("clients").?.array.items) |e| {
        try testing.expect(resolve(e.string).? == .client);
    }
    for (topics.get("topics").?.array.items) |e| {
        try testing.expect(resolve(e.string).? == .topic);
    }
    for (topics.get("subcommands").?.array.items) |e| {
        try testing.expect(resolve(e.string).? == .subcommand);
    }
}

fn hasKey(m: TopicLists, name: []const u8) bool {
    for (m.config_keys) |ks| {
        if (std.mem.eql(u8, ks.name, name)) return true;
    }
    return false;
}

fn hasCheck(m: TopicLists, name: []const u8) bool {
    for (m.doctor_checks) |cs| {
        if (std.mem.eql(u8, cs.name, name)) return true;
    }
    return false;
}

fn hasEnv(m: TopicLists, name: []const u8) bool {
    for (m.env_vars) |s| {
        if (std.mem.eql(u8, s.name, name)) return true;
    }
    return false;
}

fn hasErr(m: TopicLists, code: u8) bool {
    for (m.errors) |s| {
        if (s.code == code) return true;
    }
    return false;
}

fn hasClient(m: TopicLists, k: setup.ClientKind) bool {
    for (m.clients) |c| {
        if (c == k) return true;
    }
    return false;
}

test "searchCatalog: a term matches name and body text across registries" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    // "timeout" hits the error (type tag), the config key (name), and any
    // check/env/client whose text mentions it.
    const t = try searchCatalog(a, "timeout");
    try testing.expect(hasErr(t, 105));
    try testing.expect(hasKey(t, "timeout_ms"));
    // Case-insensitive: an uppercase env-var spelling still matches.
    const e = try searchCatalog(a, "TAU_ENDPOINT");
    try testing.expect(hasEnv(e, "TAU_ENDPOINT"));
    const e2 = try searchCatalog(a, "tau_endpoint");
    try testing.expect(hasEnv(e2, "TAU_ENDPOINT"));
    // Body text (not just names): "bundle" reaches the env var whose
    // summary mentions CURL_CA_BUNDLE-adjacent wording and the checks
    // whose fails_when/remediation say bundle.
    const b = try searchCatalog(a, "proxy");
    try testing.expect(hasCheck(b, "proxy_env"));
    // Subcommand entries search their name + summary + usage + related
    // links — "self-update" lives in upgrade's summary.
    const u = try searchCatalog(a, "self-update");
    try testing.expectEqual(@as(usize, 1), u.subcommands.len);
    try testing.expectEqualStrings("upgrade", u.subcommands[0].name);
    // Unknown text matches nothing at all.
    const n = try searchCatalog(a, "zzzyyqq");
    try testing.expectEqual(@as(usize, 0), n.errors.len);
    try testing.expectEqual(@as(usize, 0), n.config_keys.len);
    try testing.expectEqual(@as(usize, 0), n.doctor_checks.len);
    try testing.expectEqual(@as(usize, 0), n.env_vars.len);
    try testing.expectEqual(@as(usize, 0), n.clients.len);
    try testing.expectEqual(@as(usize, 0), n.topics.len);
    try testing.expectEqual(@as(usize, 0), n.subcommands.len);
}

test "searchCatalog: multi-term queries AND across the search text" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    // "api key" needs both terms — the key, the check, and the env var all
    // carry both words in their searchable text.
    const m = try searchCatalog(a, "api key");
    try testing.expect(hasKey(m, "api_key"));
    try testing.expect(hasCheck(m, "api_key"));
    try testing.expect(hasEnv(m, "TAU_API_KEY"));
    // A second term that nothing shares prunes the result — "key" alone
    // hits far more entries than "key frobnicate".
    const none = try searchCatalog(a, "key frobnicate-zzz");
    try testing.expectEqual(@as(usize, 0), none.config_keys.len);
}

test "searchCatalog: prefixed spellings and client aliases reach their entries" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const d = try searchCatalog(a, "doctor.tls");
    try testing.expect(hasCheck(d, "tls_ca"));
    // --client aliases match by resolution, not substring.
    const am = try searchCatalog(a, "amazon-q");
    try testing.expect(hasClient(am, .amazonq));
    const cc = try searchCatalog(a, "codex-cli");
    try testing.expect(hasClient(cc, .codex));
    // A dotted client spelling hits the canonical name in the haystack.
    const cz = try searchCatalog(a, "client.zed");
    try testing.expect(hasClient(cz, .zed));
    // Topics search their summary/details — "redact" lives in privacy's.
    const p = try searchCatalog(a, "redact");
    try testing.expectEqual(@as(usize, 1), p.topics.len);
    try testing.expectEqualStrings("privacy", p.topics[0].name);
    // A prefixed subcommand spelling hits the canonical name in the
    // haystack too.
    const sd = try searchCatalog(a, "subcommand.doctor");
    try testing.expectEqual(@as(usize, 1), sd.subcommands.len);
    try testing.expectEqualStrings("doctor", sd.subcommands[0].name);
}

test "formatSearchJson emits query + filtered topics and every listed name resolves" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const out = try formatSearchJson(a, "timeout");
    try testing.expect(std.mem.startsWith(u8, out, "{\"query\":\"timeout\",\"topics\":{\"errors\":["));
    try testing.expect(std.mem.endsWith(u8, out, "]}}\n"));
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, out, .{});
    try testing.expectEqualStrings("timeout", v.object.get("query").?.string);
    const topics = v.object.get("topics").?.object;
    // Every listed name resolves — the filtered index is still a list of
    // valid queries.
    for (topics.get("errors").?.array.items) |e| {
        const q = try std.fmt.allocPrint(a, "{d}", .{e.object.get("code").?.integer});
        try testing.expect(resolve(q).? == .err);
    }
    for (topics.get("config_keys").?.array.items) |e| try testing.expect(resolve(e.string).? == .key);
    for (topics.get("doctor_checks").?.array.items) |e| try testing.expect(resolve(e.string).? == .check);
    for (topics.get("env_vars").?.array.items) |e| try testing.expect(resolve(e.string).? == .env);
    for (topics.get("clients").?.array.items) |e| try testing.expect(resolve(e.string).? == .client);
    for (topics.get("topics").?.array.items) |e| try testing.expect(resolve(e.string).? == .topic);
    for (topics.get("subcommands").?.array.items) |e| try testing.expect(resolve(e.string).? == .subcommand);
    // JSON escaping inside the query member.
    const esc = try formatSearchJson(a, "say \"hi\"");
    try testing.expect(std.mem.startsWith(u8, esc, "{\"query\":\"say \\\"hi\\\"\",\"topics\":"));
    // No matches: seven empty arrays, still a valid result object.
    const none = try formatSearchJson(a, "zzzyyqq");
    try testing.expect(std.mem.indexOf(u8, none, "\"errors\":[]") != null);
    try testing.expect(std.mem.indexOf(u8, none, "\"clients\":[]") != null);
}

test "formatSearchHuman renders matching sections, omits empty ones" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const out = try formatSearchHuman(a, "proxy_env");
    try testing.expect(std.mem.indexOf(u8, out, "explain topics matching \"proxy_env\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "doctor checks:\n  doctor.proxy_env\n") != null);
    // A check-only match has no error-code/client sections.
    try testing.expect(std.mem.indexOf(u8, out, "clients:") == null);
    const none = try formatSearchHuman(a, "zzzyyqq");
    try testing.expectEqualStrings("no explain topics match \"zzzyyqq\" — run `tau explain --list` for the full topic index\n", none);
}

test "formatIndexHuman renders all seven sections with resolvable names" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const idx = try formatIndexHuman(a);
    try testing.expect(std.mem.indexOf(u8, idx, "error codes:") != null);
    try testing.expect(std.mem.indexOf(u8, idx, "  106  AuthFailed") != null);
    try testing.expect(std.mem.indexOf(u8, idx, "config keys:") != null);
    try testing.expect(std.mem.indexOf(u8, idx, "  timeout_ms\n") != null);
    try testing.expect(std.mem.indexOf(u8, idx, "doctor checks:") != null);
    try testing.expect(std.mem.indexOf(u8, idx, "  doctor.tls_ca\n") != null);
    try testing.expect(std.mem.indexOf(u8, idx, "env vars:") != null);
    try testing.expect(std.mem.indexOf(u8, idx, "  TAU_ENDPOINT\n") != null);
    try testing.expect(std.mem.indexOf(u8, idx, "clients:") != null);
    try testing.expect(std.mem.indexOf(u8, idx, "  client.zed\n") != null);
    try testing.expect(std.mem.indexOf(u8, idx, "topics:") != null);
    try testing.expect(std.mem.indexOf(u8, idx, "  topic.privacy\n") != null);
    try testing.expect(std.mem.indexOf(u8, idx, "subcommands:") != null);
    try testing.expect(std.mem.indexOf(u8, idx, "  subcommand.doctor\n") != null);
}

// ---------------------------------------------------------------------------
// docs-link anchor drift check — every `docs` URL the registries emit must
// land on a live anchor in its target doc so the deep links never rot.
// ---------------------------------------------------------------------------

/// GitHub's heading-anchor slug rule: lowercase, keep [a-z0-9_-], map each
/// whitespace byte to '-', drop everything else (backticks, '&', and the
/// bytes of multibyte punctuation like the em-dash all drop).
fn githubSlug(a: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (text) |ch| {
        if (ch == ' ' or ch == '\t') {
            try out.append(a, '-');
        } else if (std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-') {
            try out.append(a, std.ascii.toLower(ch));
        }
    }
    return out.toOwnedSlice(a);
}

/// Collect every anchor a markdown doc exposes: explicit `<a name="x">` /
/// `<a id="x">` targets plus the slug of each ATX heading.
fn collectAnchors(a: std.mem.Allocator, doc: []const u8, set: *std.StringHashMap(void)) !void {
    inline for (.{ "name=\"", "id=\"" }) |needle| {
        var it = std.mem.splitSequence(u8, doc, needle);
        _ = it.next();
        while (it.next()) |rest| {
            if (std.mem.indexOfScalar(u8, rest, '"')) |end| {
                try set.put(try a.dupe(u8, rest[0..end]), {});
            }
        }
    }
    var lines = std.mem.splitScalar(u8, doc, '\n');
    while (lines.next()) |line| {
        var hashes: usize = 0;
        while (hashes < line.len and line[hashes] == '#') hashes += 1;
        if (hashes == 0 or hashes > 6 or hashes >= line.len or line[hashes] != ' ') continue;
        const text = std.mem.trim(u8, line[hashes + 1 ..], " \t");
        try set.put(try githubSlug(a, text), {});
    }
}

test "explain: every entry's docs link resolves a live anchor in its target doc" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    // Every `docs` URL a `tau explain` entry can print.
    var urls: std.ArrayList([]const u8) = .empty;
    for (errors.specs) |s| try urls.append(a, s.docs);
    for (cfgschema.key_catalog) |ks| try urls.append(a, ks.docs);
    for (cfgschema.deprecated_key_specs) |ks| try urls.append(a, ks.docs);
    for (doctorcat.check_catalog) |cs| try urls.append(a, cs.docs);
    try urls.append(a, @import("version.zig").env_doc_url);
    for (setup.all_clients) |k| try urls.append(a, (try clientcat.specFor(a, k)).docs);
    for (topiccat.specs) |s| try urls.append(a, s.docs);
    for (subcat.specs) |s| try urls.append(a, s.docs);

    const blob_prefix = "https://github.com/javimosch/tau/blob/master/";
    var files = std.StringHashMap(std.StringHashMap(void)).init(a);
    for (urls.items) |u| {
        const h = std.mem.indexOfScalar(u8, u, '#') orelse continue;
        const base = u[0..h];
        const frag = u[h + 1 ..];
        if (!std.mem.startsWith(u8, base, blob_prefix)) {
            std.debug.print("docs link outside the repo: {s}\n", .{u});
            return error.TestUnexpectedResult;
        }
        const path = base[blob_prefix.len..];
        const gop = try files.getOrPut(path);
        if (!gop.found_existing) {
            gop.value_ptr.* = std.StringHashMap(void).init(a);
            const content = std.Io.Dir.cwd().readFileAlloc(testing.io, path, a, .unlimited) catch {
                std.debug.print("docs link target missing: {s} (from {s})\n", .{ path, u });
                return error.TestUnexpectedResult;
            };
            try collectAnchors(a, content, gop.value_ptr);
        }
        if (!gop.value_ptr.contains(frag)) {
            std.debug.print("dead anchor in {s}#{s} — '{s}' matches no heading or <a name> in {s}\n", .{ base, frag, frag, path });
            return error.TestUnexpectedResult;
        }
    }
}
