//! The subcommand catalog behind `tau explain <subcommand>` — one entry per
//! registered subcommand, so `tau explain doctor` prints offline what the
//! command does, how to invoke it (usage + runnable examples), and which
//! other explain entries relate to it (stable error `type` tags, config
//! keys, and `doctor.<check>` ids).
//!
//! The Spec table is hand-written but pinned against the real surface: the
//! tests below scan args.zig for `eq(argv[0], "<sub>")` literals — the same
//! source-scan contract subhelp.zig and main.zig use — so a subcommand
//! added or removed without updating this registry fails the suite.
//! `subcommand.<name>` is the canonical prefixed spelling the --list index
//! and the completions advertise; bare names resolve too unless an earlier
//! registry owns the name (no subcommand name currently collides).

const std = @import("std");
const json = @import("json.zig");
const subhelp = @import("subhelp.zig");
const version = @import("version.zig");

/// Repo-rooted doc links — sibling catalogs carry narrower constants for
/// the generated docs; subcommand entries also link README/AGENTS/docs
/// pages that have no constant yet.
const repo_doc_base = "https://github.com/javimosch/tau/blob/master/";

/// One resolvable subcommand entry — the fields `tau explain <subcommand>`
/// emits. `name` is the registered word (`doctor`); `subcommand.<name>`
/// resolves the same entry. `summary`/`usage` mirror the `tau <name>
/// --help` banner; `examples` are runnable invocations (every one starts
/// `tau <name>` and parses — the tests prove it). `errors` names stable
/// error `type` tags, `config_keys` config-file keys, and `doctor_checks`
/// check ids in the canonical `doctor.<id>` spelling — every one resolves
/// as a `tau explain` query of its own kind.
pub const Spec = struct {
    name: []const u8,
    summary: []const u8,
    usage: []const u8,
    examples: []const []const u8,
    errors: []const []const u8,
    config_keys: []const []const u8,
    doctor_checks: []const []const u8,
    docs: []const u8,
};

/// The recognized set — one Spec per registered subcommand, in args.zig
/// registration order (the same order subhelp.zig's entries table uses).
/// Ordering is the catalog/--list row order.
pub const specs = [_]Spec{
    .{
        .name = "acp",
        .summary = "Agent Client Protocol server — JSON-RPC for editor clients",
        .usage = "tau acp <serve|start|stop|status> [--acp-socket <path>] [--max-iterations <n>]",
        .examples = &.{ "tau acp serve", "tau acp status" },
        .errors = &.{ "invalid_argument", "unimplemented" },
        .config_keys = &.{ "provider", "model", "timeout_ms" },
        .doctor_checks = &.{ "doctor.client_wiring", "doctor.client_permissions" },
        .docs = repo_doc_base ++ "docs/acp.md",
    },
    .{
        .name = "models",
        .summary = "List available providers and their default models",
        .usage = "tau models",
        .examples = &.{"tau models"},
        .errors = &.{"invalid_argument"},
        .config_keys = &.{ "provider", "model" },
        .doctor_checks = &.{ "doctor.provider_resolution", "doctor.provider_probes" },
        .docs = version.providers_doc_url,
    },
    .{
        .name = "version",
        .summary = "Print the version; --verbose adds build metadata, --check looks for a newer release",
        .usage = "tau version [--verbose] [--check] [--json] [--mode text|json]",
        .examples = &.{ "tau version", "tau version --check" },
        .errors = &.{"invalid_argument"},
        .config_keys = &.{},
        .doctor_checks = &.{"doctor.update_available"},
        .docs = repo_doc_base ++ "docs/stability.md",
    },
    .{
        .name = "upgrade",
        .summary = "Self-update in place from the latest GitHub release (POSIX only)",
        .usage = "tau upgrade [--yes|-y] [--dir <path>] [--dry-run] [--verify-signature] [--json]",
        .examples = &.{ "tau upgrade --dry-run", "tau upgrade --yes" },
        .errors = &.{ "invalid_argument", "unimplemented" },
        .config_keys = &.{},
        .doctor_checks = &.{"doctor.update_available"},
        .docs = version.troubleshooting_doc_url ++ "#install--upgrade-failures",
    },
    .{
        .name = "doctor",
        .summary = "Validate your setup — config file, credentials, client wiring, connectivity",
        .usage = "tau doctor [--offline|--deep|--probe|--selftest] [--fix [-y|--yes]] [--client <name>] [--json|--report]",
        .examples = &.{ "tau doctor", "tau doctor --offline", "tau doctor --fix --yes", "tau doctor --json" },
        .errors = &.{"invalid_argument"},
        .config_keys = &.{ "provider", "api_key", "timeout_ms" },
        .doctor_checks = &.{ "doctor.config_file", "doctor.provider_resolution", "doctor.api_key", "doctor.tls_ca", "doctor.update_available" },
        .docs = repo_doc_base ++ "docs/doctor.md",
    },
    .{
        .name = "bug",
        .summary = "File a pre-filled GitHub issue carrying a secret-redacted diagnostics bundle",
        .usage = "tau bug [--title <t>] [--body <text>] [--open] [--out <path>] [--no-report|--attach-report <path>] [--dry-run]",
        .examples = &.{ "tau bug", "tau bug --dry-run", "tau bug --no-report" },
        .errors = &.{"invalid_argument"},
        .config_keys = &.{},
        .doctor_checks = &.{"doctor.plaintext_secrets"},
        .docs = version.troubleshooting_doc_url ++ "#diagnostic-toolkit",
    },
    .{
        .name = "guide",
        .summary = "Embedded operator manual — drive tau with no external docs",
        .usage = "tau guide [--human]",
        .examples = &.{ "tau guide", "tau guide --human" },
        .errors = &.{"invalid_argument"},
        .config_keys = &.{},
        .doctor_checks = &.{},
        .docs = repo_doc_base ++ "README.md",
    },
    .{
        .name = "explain",
        .summary = "Offline catalog lookup — errors, config keys, doctor checks, env vars, clients, topics, and subcommands",
        .usage = "tau explain [<query>] [--json|--human] | tau explain --list | tau explain --search <text>",
        .examples = &.{ "tau explain 106", "tau explain --list", "tau explain doctor" },
        .errors = &.{ "invalid_argument", "not_found" },
        .config_keys = &.{},
        .doctor_checks = &.{},
        .docs = version.errors_doc_url,
    },
    .{
        .name = "skills",
        .summary = "Autodiscover and load agent skills from ~/.agents/skills",
        .usage = "tau skills <list|search <query>|load <name>>",
        .examples = &.{ "tau skills list", "tau skills search memory", "tau skills load agent-memory-toolbox" },
        .errors = &.{ "invalid_argument", "not_found" },
        .config_keys = &.{},
        .doctor_checks = &.{},
        .docs = repo_doc_base ++ "AGENTS.md",
    },
    .{
        .name = "init",
        .summary = "Write a commented starter ~/.config/tau/config.json",
        .usage = "tau init [--force] [--stdout] [--provider <name>] [--json]",
        .examples = &.{ "tau init", "tau init --provider openai", "tau init --stdout" },
        .errors = &.{"invalid_argument"},
        .config_keys = &.{ "provider", "model", "api_key" },
        .doctor_checks = &.{ "doctor.config_file", "doctor.config_permissions" },
        .docs = version.config_doc_url,
    },
    .{
        .name = "setup",
        .summary = "One-shot onboarding — init + completions + editor-client wiring + doctor verdict",
        .usage = "tau setup [--shell <name>] [--client <name>] [--yes|--non-interactive] [--dry-run|--import|--remove|--detect] [--json]",
        .examples = &.{ "tau setup", "tau setup --dry-run", "tau setup --yes --client zed", "tau setup --detect" },
        .errors = &.{"invalid_argument"},
        .config_keys = &.{"provider"},
        .doctor_checks = &.{ "doctor.client_wiring", "doctor.shell_completions", "doctor.config_file" },
        .docs = repo_doc_base ++ "docs/editors.md",
    },
    .{
        .name = "completions",
        .summary = "Install the generated shell completions — the setup step standalone",
        .usage = "tau completions install [--shell <name>] [--dry-run] [--json]",
        .examples = &.{ "tau completions install", "tau completions install --shell zsh" },
        .errors = &.{"invalid_argument"},
        .config_keys = &.{},
        .doctor_checks = &.{"doctor.shell_completions"},
        .docs = repo_doc_base ++ "completions/README.md",
    },
    .{
        .name = "fleet",
        .summary = "Orchestrate parallel tau workers toward a goal",
        .usage = "tau fleet <run|status|list|logs|cancel> [<id>] [--goal <text>] [--sequential|--parallel]",
        .examples = &.{ "tau fleet run --goal \"ship the redesign\"", "tau fleet list", "tau fleet status fleet-2026-10-31" },
        .errors = &.{ "missing_required_field", "invalid_argument" },
        .config_keys = &.{ "provider", "model", "timeout_ms" },
        .doctor_checks = &.{},
        .docs = repo_doc_base ++ "AGENTS.md",
    },
    .{
        .name = "config",
        .summary = "Inspect and edit ~/.config/tau/config.json (git-config style)",
        .usage = "tau config <show|validate|set|get|unset|edit|schema> [<key> [<value>]] [path] [--json]",
        .examples = &.{ "tau config show", "tau config validate", "tau config set provider openai", "tau config get provider" },
        .errors = &.{ "invalid_argument", "not_found" },
        .config_keys = &.{ "provider", "api_key", "mode" },
        .doctor_checks = &.{ "doctor.config_file", "doctor.config_permissions", "doctor.config_deprecated_keys" },
        .docs = version.config_doc_url,
    },
};

const prefix = "subcommand.";

/// Look up a subcommand by name — bare `doctor` or the canonical
/// `subcommand.doctor` spelling both resolve. Unknown names and a bare
/// `subcommand.` return null (the did-you-mean path suggests the nearest
/// candidate instead).
pub fn findSpec(query: []const u8) ?Spec {
    const name = if (std.mem.startsWith(u8, query, prefix)) query[prefix.len..] else query;
    if (name.len == 0) return null;
    for (specs) |s| {
        if (std.mem.eql(u8, s.name, name)) return s;
    }
    return null;
}

/// Comptime name list parallel to `specs` — bare spellings.
pub const names = blk: {
    var c: [specs.len][]const u8 = undefined;
    for (specs, 0..) |s, i| c[i] = s.name;
    break :blk c;
};

/// Append `"<escaped s>"` to buf.
fn jstr(a: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
    try buf.append(a, '"');
    try json.escapeInto(a, buf, s);
    try buf.append(a, '"');
}

/// Append `["<s>", ...]` to buf.
fn jlist(a: std.mem.Allocator, buf: *std.ArrayList(u8), items: []const []const u8) !void {
    try buf.append(a, '[');
    for (items, 0..) |s, i| {
        if (i > 0) try buf.append(a, ',');
        try jstr(a, buf, s);
    }
    try buf.append(a, ']');
}

/// Serialize one subcommand entry for `tau explain` (no trailing newline —
/// the caller owns framing):
/// {"subcommand":"N","summary":"S","usage":"U","examples":[...],
///  "errors":[<type tag>, ...],"config_keys":[<key>, ...],
///  "doctor_checks":["doctor.<id>", ...],"docs":"U"}
/// Caller owns the returned slice.
pub fn formatSubcommandJson(a: std.mem.Allocator, s: Spec) ![]u8 {
    var b: std.ArrayList(u8) = .empty;
    try b.appendSlice(a, "{\"subcommand\":");
    try jstr(a, &b, s.name);
    try b.appendSlice(a, ",\"summary\":");
    try jstr(a, &b, s.summary);
    try b.appendSlice(a, ",\"usage\":");
    try jstr(a, &b, s.usage);
    try b.appendSlice(a, ",\"examples\":");
    try jlist(a, &b, s.examples);
    try b.appendSlice(a, ",\"errors\":");
    try jlist(a, &b, s.errors);
    try b.appendSlice(a, ",\"config_keys\":");
    try jlist(a, &b, s.config_keys);
    try b.appendSlice(a, ",\"doctor_checks\":");
    try jlist(a, &b, s.doctor_checks);
    try b.appendSlice(a, ",\"docs\":");
    try jstr(a, &b, s.docs);
    try b.appendSlice(a, "}");
    return b.toOwnedSlice(a);
}

/// Append the `label  item · item · ...` line for a list (or `-` when
/// empty) — keeps the human rendering aligned across the three link
/// groups.
fn appendHumanList(a: std.mem.Allocator, b: *std.ArrayList(u8), label: []const u8, items: []const []const u8) !void {
    try b.appendSlice(a, label);
    if (items.len == 0) {
        try b.appendSlice(a, "-\n");
        return;
    }
    for (items, 0..) |s, i| {
        if (i > 0) try b.appendSlice(a, " · ");
        try b.appendSlice(a, s);
    }
    try b.appendSlice(a, "\n");
}

/// Human-readable `tau explain --human <subcommand>` rendering — drawn from
/// the same Spec so the prose and JSON forms can never drift apart.
pub fn formatSubcommandHuman(a: std.mem.Allocator, s: Spec) ![]u8 {
    var b: std.ArrayList(u8) = .empty;
    try b.appendSlice(a, try std.fmt.allocPrint(a, "subcommand  {s}\n  summary:      {s}\n  usage:        {s}\n", .{ s.name, s.summary, s.usage }));
    try appendHumanList(a, &b, "  examples:     ", s.examples);
    try appendHumanList(a, &b, "  errors:       ", s.errors);
    try appendHumanList(a, &b, "  config keys:  ", s.config_keys);
    try appendHumanList(a, &b, "  doctor checks:", s.doctor_checks);
    try b.appendSlice(a, try std.fmt.allocPrint(a, "  docs:         {s}\n", .{s.docs}));
    return b.toOwnedSlice(a);
}

/// One `label \`a\`, \`b\`` group in the Related line — groups join with
/// ` · ` separators (skipped entirely when the list is empty).
fn appendRelGroup(a: std.mem.Allocator, b: *std.ArrayList(u8), first: *bool, label: []const u8, items: []const []const u8) !void {
    if (!first.*) try b.appendSlice(a, " · ");
    first.* = false;
    try b.appendSlice(a, label);
    for (items, 0..) |s, i| {
        try b.appendSlice(a, if (i == 0) " `" else ", `");
        try b.appendSlice(a, s);
        try b.append(a, '`');
    }
}

/// The docs/cli-reference.md section for one subcommand — the exact bytes
/// scripts/gen-cli-reference-doc.py emits; the doc-mirror test pins it
/// verbatim so the page can never drift from the help text or catalog.
fn subcommandSectionMarkdown(a: std.mem.Allocator, s: Spec) ![]u8 {
    const help = subhelp.lookup(s.name) orelse "";
    var b: std.ArrayList(u8) = .empty;
    try b.appendSlice(a, try std.fmt.allocPrint(a, "### `tau {s}`\n\n{s}\n\n```text\n{s}```\n\n- **Related:** ", .{ s.name, s.summary, help }));
    var first = true;
    if (s.errors.len > 0) try appendRelGroup(a, &b, &first, "errors", s.errors);
    if (s.config_keys.len > 0) try appendRelGroup(a, &b, &first, "config keys", s.config_keys);
    if (s.doctor_checks.len > 0) try appendRelGroup(a, &b, &first, "checks", s.doctor_checks);
    if (first) try b.appendSlice(a, "—");
    try b.appendSlice(a, try std.fmt.allocPrint(a, "\n- **Explain:** `tau explain subcommand.{s}` (bare `tau explain {s}` resolves too)\n", .{ s.name, s.name }));
    // Repo-relative display path; href relative to docs/ (repo-root pages
    // climb one level, docs/* pages drop the docs/ prefix).
    if (std.mem.startsWith(u8, s.docs, repo_doc_base)) {
        const rel = s.docs[repo_doc_base.len..];
        const href = if (std.mem.startsWith(u8, rel, "docs/")) rel[5..] else try std.fmt.allocPrint(a, "../{s}", .{rel});
        try b.appendSlice(a, try std.fmt.allocPrint(a, "- **Docs:** [{s}]({s})\n", .{ rel, href }));
    } else {
        try b.appendSlice(a, try std.fmt.allocPrint(a, "- **Docs:** [{s}]({s})\n", .{ s.docs, s.docs }));
    }
    return b.toOwnedSlice(a);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const argsmod = @import("args.zig");
const errors = @import("errors.zig");
const cfgschema = @import("configschema.zig");
const doctorcat = @import("doctorcatalog.zig");
const args_source = @embedFile("args.zig");

/// Iterate `eq(argv[0], "<sub>")` literals — the registered subcommands.
/// Same source-scan contract as subhelp.zig and the surface tests in
/// main.zig, so this registry cannot drift from the real surface.
fn nextSubcommand(pos: *usize) ?[]const u8 {
    const needle = "eq(argv[0], \"";
    const i = std.mem.indexOfPos(u8, args_source, pos.*, needle) orelse return null;
    const start = i + needle.len;
    const end = std.mem.indexOfPos(u8, args_source, start, "\"") orelse return null;
    pos.* = end + 1;
    return args_source[start..end];
}

/// Split an example command line on spaces, honoring '...' and "..."
/// quoting the way a shell would (quotes are stripped, not kept). Same
/// shape as subhelp.zig's tokenizer.
fn tokenize(arena: std.mem.Allocator, line: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < line.len) {
        while (i < line.len and line[i] == ' ') i += 1;
        if (i >= line.len) break;
        var tok: std.ArrayList(u8) = .empty;
        while (i < line.len and line[i] != ' ') {
            const c = line[i];
            if (c == '\'' or c == '"') {
                i += 1;
                while (i < line.len and line[i] != c) : (i += 1)
                    try tok.append(arena, line[i]);
                if (i < line.len) i += 1; // closing quote
            } else {
                try tok.append(arena, c);
                i += 1;
            }
        }
        try out.append(arena, try tok.toOwnedSlice(arena));
    }
    return out.toOwnedSlice(arena);
}

test "every registered subcommand has a Spec (and vice versa)" {
    var pos: usize = 0;
    while (nextSubcommand(&pos)) |sub| {
        if (findSpec(sub) == null)
            std.debug.print("subcommandcatalog.zig has no Spec for registered subcommand '{s}'\n", .{sub});
        try testing.expect(findSpec(sub) != null);
    }
    for (specs) |s| {
        var sp: usize = 0;
        var found = false;
        while (nextSubcommand(&sp)) |sub| {
            if (std.mem.eql(u8, sub, s.name)) found = true;
        }
        if (!found)
            std.debug.print("subcommandcatalog.zig Spec '{s}' is not a registered subcommand\n", .{s.name});
        try testing.expect(found);
    }
}

test "findSpec: bare and subcommand.-prefixed spellings resolve, unknowns do not" {
    const s = findSpec("doctor").?;
    try testing.expectEqualStrings("doctor", s.name);
    const p = findSpec("subcommand.doctor").?;
    try testing.expectEqualStrings("doctor", p.name);
    try testing.expect(findSpec("subcommand.") == null);
    try testing.expect(findSpec("subcommand.bogus") == null);
    try testing.expect(findSpec("doktor") == null);
    try testing.expect(findSpec("") == null);
    // Case-sensitive — the did-you-mean path suggests the canonical name.
    try testing.expect(findSpec("Doctor") == null);
}

test "names list stays parallel to specs" {
    for (specs, 0..) |s, i| try testing.expectEqualStrings(s.name, names[i]);
}

test "every Spec example is a runnable invocation of its own subcommand" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var env = std.process.Environ.Map.init(a);
    for (specs) |s| {
        try testing.expect(s.examples.len > 0);
        for (s.examples) |line| {
            const toks = try tokenize(a, line);
            try testing.expect(toks.len >= 2);
            try testing.expectEqualStrings("tau", toks[0]);
            try testing.expectEqualStrings(s.name, toks[1]);
            const p = try argsmod.parse(testing.io, a, toks, &env, .{});
            if (p.action == .err)
                std.debug.print("{s} catalog example does not parse: {s} ({s})\n", .{ s.name, line, p.err_msg orelse "?" });
            try testing.expect(p.action != .err);
        }
    }
}

test "every Spec link resolves in its own registry" {
    for (specs) |s| {
        for (s.errors) |tag| {
            try testing.expect(errors.findSpec(tag) != null);
        }
        for (s.config_keys) |k| {
            try testing.expect(cfgschema.findKey(k) != null);
        }
        for (s.doctor_checks) |q| {
            try testing.expect(doctorcat.findCheck(q) != null);
        }
    }
}

test "formatSubcommandJson emits the pinned member order and parses" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const out = try formatSubcommandJson(a, findSpec("doctor").?);
    try testing.expect(std.mem.startsWith(u8, out, "{\"subcommand\":\"doctor\",\"summary\":\""));
    try testing.expect(std.mem.indexOf(u8, out, ",\"usage\":\"tau doctor") != null);
    try testing.expect(std.mem.indexOf(u8, out, ",\"examples\":[\"tau doctor\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, ",\"errors\":[\"invalid_argument\"]") != null);
    try testing.expect(std.mem.indexOf(u8, out, ",\"doctor_checks\":[\"doctor.config_file\"") != null);
    try testing.expect(std.mem.endsWith(u8, out, "\"}"));
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, out, .{});
    try testing.expect(v.object.get("examples").?.array.items.len > 0);
    // Empty link lists still serialize (shape stability).
    const empty = try formatSubcommandJson(a, findSpec("guide").?);
    try testing.expect(std.mem.indexOf(u8, empty, ",\"errors\":[\"invalid_argument\"]") != null);
    try testing.expect(std.mem.indexOf(u8, empty, ",\"config_keys\":[]") != null);
    try testing.expect(std.mem.indexOf(u8, empty, ",\"doctor_checks\":[]") != null);
}

test "formatSubcommandHuman renders summary, usage, examples, links, and docs" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const out = try formatSubcommandHuman(a, findSpec("setup").?);
    try testing.expect(std.mem.indexOf(u8, out, "subcommand  setup\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "summary:") != null);
    try testing.expect(std.mem.indexOf(u8, out, "usage:        tau setup") != null);
    try testing.expect(std.mem.indexOf(u8, out, "examples:     tau setup · tau setup --dry-run") != null);
    try testing.expect(std.mem.indexOf(u8, out, "config keys:  provider") != null);
    try testing.expect(std.mem.indexOf(u8, out, "doctor checks:doctor.client_wiring") != null);
    try testing.expect(std.mem.indexOf(u8, out, "docs:         https://") != null);
    try testing.expect(std.mem.endsWith(u8, out, "\n"));
}

test "subcommandSectionMarkdown mirrors docs/cli-reference.md verbatim" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const doc = std.Io.Dir.cwd().readFileAlloc(testing.io, "docs/cli-reference.md", a, .unlimited) catch {
        std.debug.print("docs/cli-reference.md missing — run scripts/gen-cli-reference-doc.py\n", .{});
        return error.TestUnexpectedResult;
    };
    for (specs) |s| {
        const section = try subcommandSectionMarkdown(a, s);
        if (std.mem.indexOf(u8, doc, section) == null) {
            std.debug.print("docs/cli-reference.md missing subcommand section '{s}'\n", .{s.name});
            return error.TestUnexpectedResult;
        }
    }
}
