//! Canonical registry of every `TAU_*` environment variable tau (or its
//! companion tooling) recognizes — the source of truth for the generated
//! docs/env.md catalog (scripts/gen-env-doc.py) and for the startup typo
//! warning: main() scans the process environment for `TAU_*` names missing
//! from this table and emits a {"warn"} envelope with a did-you-mean hint,
//! so a misspelling like TAU_ENDPONT is surfaced instead of silently
//! ignored.
//!
//! When a new TAU_* variable is introduced add a Spec here — the
//! doc-mirror test, the env-doc smoke group, and the generated env.md
//! drift check fail until the doc is regenerated. Variables consumed only
//! by the installers or by external launchers (a2a-spawn) belong in the
//! registry too: they are part of the documented TAU_* surface and must
//! not warn.

const std = @import("std");
const suggest = @import("suggest.zig");

/// Doc-table grouping — controls which docs/env.md section a variable is
/// rendered under.
pub const Section = enum { tau, installer, external };

/// One recognized `TAU_*` environment variable. `consumers` is the
/// doc-table cell naming what reads it; `summary` is the one-line
/// description rendered into docs/env.md.
pub const Spec = struct {
    name: []const u8,
    section: Section,
    consumers: []const u8,
    summary: []const u8,
};

/// The recognized set. Ordering is the generated doc's row order.
pub const specs = [_]Spec{
    // ── Read by the tau binary ──────────────────────────────────────────
    .{ .name = "TAU_API_KEY", .section = .tau, .consumers = "tau", .summary = "Fallback API key, used after provider-specific env vars and config keys." },
    .{ .name = "TAU_ENDPOINT", .section = .tau, .consumers = "tau", .summary = "Overrides the provider's endpoint URL (works for chat and `tau acp`). Useful for proxies, gateways, and local OpenAI-compatible servers." },
    .{ .name = "TAU_DEBUG_LOG", .section = .tau, .consumers = "tau", .summary = "Overrides the `--debug` diagnostic log destination (default `~/.config/tau/debug/<timestamp>.log`)." },
    .{ .name = "TAU_EDITOR", .section = .tau, .consumers = "tau", .summary = "Editor for `tau config edit`, tried before VISUAL and EDITOR (fallback `vi`/`notepad`). May include arguments, e.g. `code --wait`." },
    .{ .name = "TAU_YES", .section = .tau, .consumers = "tau", .summary = "`1`/`true`/`yes`/`on` enables `tau setup --yes` and `tau upgrade --yes` (approve write steps without prompting). Any other value is off." },
    .{ .name = "TAU_NONINTERACTIVE", .section = .tau, .consumers = "tau", .summary = "Same truthiness rules as TAU_YES; enables `tau setup --non-interactive` (unattended contract for scripts/CI)." },
    .{ .name = "TAU_SETUP_SHELL", .section = .tau, .consumers = "tau", .summary = "`tau setup` shell override when `--shell` is absent (`bash`, `zsh`, `fish`, `pwsh`, or `all`); invalid values fail with exit 80." },
    .{ .name = "TAU_SETUP_CLIENT", .section = .tau, .consumers = "tau", .summary = "`tau setup` editor client when `--client` is absent (any `--client` value or `all`); invalid values fail with exit 80." },
    .{ .name = "TAU_SETUP_IMPORT", .section = .tau, .consumers = "tau", .summary = "Same truthiness rules as TAU_YES; enables `tau setup --import` (merge existing MCP servers into wired clients)." },
    .{ .name = "TAU_NO_UPDATE_CHECK", .section = .tau, .consumers = "tau", .summary = "Any non-empty, non-`0` value disables the update check everywhere — `tau version --check`, `tau upgrade`, and the `tau doctor` update_available warning." },
    .{ .name = "TAU_UPDATE_URL", .section = .tau, .consumers = "tau", .summary = "Overrides the release lookup URL used by the update check (default: the GitHub latest-release API). Useful for mirrors/proxies and `file://` stubs in tests." },
    .{ .name = "TAU_INSTALL_URL", .section = .tau, .consumers = "tau", .summary = "Overrides the installer script `tau upgrade` downloads and runs (default: the install.sh shipped at the release tag). Useful for mirrors and `file://` stubs in tests." },
    .{ .name = "TAU_CHANGELOG_URL", .section = .tau, .consumers = "tau", .summary = "Overrides the changelog `tau upgrade` fetches for its pre-upgrade summary (default: the CHANGELOG.md shipped at the release tag). A fetch miss drops the summary, never the upgrade." },
    .{ .name = "TAU_INSTALL_DIR", .section = .tau, .consumers = "tau upgrade · install.sh · install.ps1", .summary = "Install destination when `tau upgrade --dir` is absent (default: the running binary's own directory, else the installer's `~/.local/bin`). Also honored by the installers." },
    .{ .name = "TAU_VERIFY_SIGSTORE", .section = .tau, .consumers = "tau upgrade · install.sh", .summary = "Opt-in cosign/Sigstore verification of the downloaded binary before swap (requires cosign on PATH). Truthiness follows TAU_YES." },
    // ── Read by the installers only ─────────────────────────────────────
    .{ .name = "TAU_VERSION", .section = .installer, .consumers = "install.sh · install.ps1", .summary = "Pins the version to install (default: the latest release). Same role as `--version`/`-Version`." },
    .{ .name = "TAU_BASE_URL", .section = .installer, .consumers = "install.sh · install.ps1", .summary = "Overrides the release-download base URL. `file://` mirrors are supported for air-gapped installs." },
    .{ .name = "TAU_OS", .section = .installer, .consumers = "install.sh", .summary = "Overrides platform detection — the raw `uname` value (`linux` or `darwin`)." },
    .{ .name = "TAU_ARCH", .section = .installer, .consumers = "install.sh · install.ps1", .summary = "Overrides architecture detection — the raw `uname -m` value (e.g. `x86_64`, `arm64`, `aarch64`)." },
    .{ .name = "TAU_SKIP_CHECKSUM", .section = .installer, .consumers = "install.sh · install.ps1", .summary = "Skips SHA256 verification of the downloaded archive — weakens the fail-closed default; prefer TAU_VERIFY_SIGSTORE." },
    // ── Read by companion tooling (documented surface — never warn) ─────
    .{ .name = "TAU_BIN", .section = .external, .consumers = "a2a-spawn · scripts/smoke.sh", .summary = "Path to the tau binary, skipping PATH resolution." },
    .{ .name = "TAU_TOOLS", .section = .external, .consumers = "a2a-spawn", .summary = "Translated to `--tools` when launching tau (e.g. `TAU_TOOLS=\"bash,read\"`). tau itself ignores it." },
    .{ .name = "TAU_THINKING", .section = .external, .consumers = "a2a-spawn", .summary = "`1` adds `--thinking` when launching tau. tau itself ignores it." },
    .{ .name = "TAU_DEBUG", .section = .external, .consumers = "a2a-spawn", .summary = "`1` adds `--debug` when launching tau. tau itself ignores it." },
};

/// Look up a variable by exact name. Unknown `TAU_*` names warn at startup.
pub fn findSpec(name: []const u8) ?Spec {
    for (specs) |s| {
        if (std.mem.eql(u8, s.name, name)) return s;
    }
    return null;
}

/// Comptime name list parallel to `specs` — the suggestion candidate pool.
pub const names = blk: {
    var c: [specs.len][]const u8 = undefined;
    for (specs, 0..) |s, i| c[i] = s.name;
    break :blk c;
};

/// Lowercase mirror of `names` — the did-you-mean distance ignores case so
/// `TAU_endpont` still resolves to `TAU_ENDPOINT`.
const names_lower = blk: {
    var c: [specs.len][]const u8 = undefined;
    for (names, 0..) |n, i| {
        c[i] = lower: {
            var out: [n.len]u8 = undefined;
            for (n, 0..) |ch, j| out[j] = std.ascii.toLower(ch);
            const s = out;
            break :lower &s;
        };
    }
    break :blk c;
};

/// Nearest recognized name within two case-insensitive edits, or null.
fn suggestName(a: std.mem.Allocator, name: []const u8) ?[]const u8 {
    const q = std.ascii.allocLowerString(a, name) catch return null;
    var best: ?usize = null;
    var best_d: usize = std.math.maxInt(usize);
    for (names_lower, 0..) |cand, i| {
        const d = suggest.editDistance(a, q, cand) orelse continue;
        if (d <= 2 and d < best_d) {
            best = i;
            best_d = d;
        }
    }
    const i = best orelse return null;
    return names[i];
}

const env_doc_url = @import("version.zig").env_doc_url;

/// Build the startup warning for `TAU_*` environment variables tau does
/// not recognize — misspelled names are silently ignored otherwise, which
/// is exactly the failure mode this surfaces. Scans the process
/// environment once at startup (main.zig prints the result as a {"warn"}
/// envelope on stderr). Unknown names are sorted for deterministic output;
/// each within two case-insensitive edits of a recognized name gets a
/// ` — did you mean "<name>"?` hint. Returns null when every TAU_* name
/// is recognized (or none is set). Caller owns the returned slice.
pub fn unknownVarWarning(arena: std.mem.Allocator, env: *const std.process.Environ.Map) ?[]u8 {
    var unknown: std.ArrayList([]const u8) = .empty;
    for (env.keys()) |k| {
        if (!std.mem.startsWith(u8, k, "TAU_")) continue;
        if (findSpec(k) == null) unknown.append(arena, k) catch return null;
    }
    if (unknown.items.len == 0) return null;
    std.mem.sort([]const u8, unknown.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    var list: std.ArrayList(u8) = .empty;
    for (unknown.items) |k| {
        if (list.items.len > 0) list.appendSlice(arena, ", ") catch return null;
        list.appendSlice(arena, std.fmt.allocPrint(arena, "\"{s}\"", .{k}) catch return null) catch return null;
        if (suggestName(arena, k)) |s| {
            list.appendSlice(arena, std.fmt.allocPrint(arena, " — did you mean \"{s}\"?", .{s}) catch return null) catch return null;
        }
    }
    return std.fmt.allocPrint(arena, "environment has unrecognized TAU_* variable{s} (ignored): {s} — the recognized set is documented at {s}", .{ if (unknown.items.len > 1) "s" else "", list.items, env_doc_url }) catch null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn envWith(arena: std.mem.Allocator, pairs: []const [2][]const u8) !std.process.Environ.Map {
    var env = std.process.Environ.Map.init(arena);
    for (pairs) |p| try env.put(p[0], p[1]);
    return env;
}

test "findSpec: every registry name resolves, unknown names do not" {
    try testing.expectEqual(@as(usize, 24), specs.len);
    for (specs) |s| {
        try testing.expectEqualStrings(s.name, findSpec(s.name).?.name);
    }
    try testing.expect(findSpec("TAU_ENDPONT") == null);
    try testing.expect(findSpec("TAU") == null); // bare TAU has no _ suffix
    try testing.expect(findSpec("tau_api_key") == null); // case-sensitive
}

test "names list stays parallel to specs" {
    for (specs, 0..) |s, i| try testing.expectEqualStrings(s.name, names[i]);
}

test "unknownVarWarning: clean env stays silent" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const arena = ar.allocator();
    var env = try envWith(arena, &.{ .{ "HOME", "/tmp" }, .{ "TAU_API_KEY", "k" }, .{ "TAU_YES", "1" }, .{ "PATH", "/bin" } });
    try testing.expect(unknownVarWarning(arena, &env) == null);
}

test "unknownVarWarning: typo names the var and suggests the fix" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const arena = ar.allocator();
    var env = try envWith(arena, &.{.{ "TAU_ENDPONT", "http://x" }});
    const w = unknownVarWarning(arena, &env).?;
    try testing.expect(std.mem.indexOf(u8, w, "\"TAU_ENDPONT\"") != null);
    try testing.expect(std.mem.indexOf(u8, w, "did you mean \"TAU_ENDPOINT\"") != null);
    try testing.expect(std.mem.indexOf(u8, w, "variable ") != null or std.mem.indexOf(u8, w, "variable(") == null);
    try testing.expect(std.mem.indexOf(u8, w, "(ignored)") != null);
    try testing.expect(std.mem.indexOf(u8, w, env_doc_url) != null);
}

test "unknownVarWarning: multiple unknowns sort and each gets its own hint" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const arena = ar.allocator();
    var env = try envWith(arena, &.{
        .{ "TAU_ZZZ_NOPE", "1" }, // far from everything — no hint
        .{ "TAU_YESS", "1" }, // d=1 -> TAU_YES
        .{ "TAU_API_KEY", "k" }, // recognized — filtered out
    });
    const w = unknownVarWarning(arena, &env).?;
    try testing.expect(std.mem.indexOf(u8, w, "variables") != null);
    const yes_i = std.mem.indexOf(u8, w, "\"TAU_YESS\"").?;
    const zzz_i = std.mem.indexOf(u8, w, "\"TAU_ZZZ_NOPE\"").?;
    try testing.expect(yes_i < zzz_i); // sorted
    try testing.expect(std.mem.indexOf(u8, w, "did you mean \"TAU_YES\"") != null);
    try testing.expect(std.mem.indexOf(u8, w, "TAU_API_KEY\"") == null);
}

test "unknownVarWarning: suggestion is case-insensitive" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const arena = ar.allocator();
    var env = try envWith(arena, &.{.{ "TAU_yes", "1" }});
    const w = unknownVarWarning(arena, &env).?;
    try testing.expect(std.mem.indexOf(u8, w, "did you mean \"TAU_YES\"") != null);
}

test "docs/env.md generated catalog mirrors the registry" {
    const gpa = testing.allocator;
    const doc = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "docs/env.md", gpa, .unlimited);
    defer gpa.free(doc);
    // The file must declare itself generated so nobody hand-edits it.
    try testing.expect(std.mem.indexOf(u8, doc, "GENERATED FILE") != null);
    try testing.expect(std.mem.indexOf(u8, doc, "scripts/gen-env-doc.py") != null);
    for (specs) |s| {
        try testing.expect(s.summary.len > 0);
        try testing.expect(s.consumers.len > 0);
        var buf: [128]u8 = undefined;
        const row = std.fmt.bufPrint(&buf, "| `{s}` |", .{s.name}) catch unreachable;
        if (std.mem.indexOf(u8, doc, row) == null) {
            std.debug.print("env.md catalog missing row '{s}'\n", .{row});
            return error.TestUnexpectedResult;
        }
        if (std.mem.indexOf(u8, doc, s.summary) == null) {
            std.debug.print("env.md missing summary for {s}\n", .{s.name});
            return error.TestUnexpectedResult;
        }
    }
}
