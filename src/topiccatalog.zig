//! The curated-topic catalog behind `tau explain <topic>` — free-standing
//! subjects that don't belong to a generated registry (no error code,
//! config key, doctor check, env var, or client row backs them). The first
//! and currently only topic is `privacy` (`tau explain privacy`), which
//! covers what tau stores locally, what leaves the machine, and how the
//! diagnostics surfaces (`--debug` logs, `tau doctor --report`, `tau bug`)
//! redact secrets.
//!
//! Unlike the other catalogs these entries are hand-written rather than
//! derived from a code table, so nothing regenerates them — add a Spec
//! here when a subject deserves a resolvable name. Resolution accepts
//! both the bare name and the `topic.<name>` spelling, matching the
//! doctor.<id>/client.<name> namespacing convention; `topic.<name>` is
//! the canonical form the --list index and the completions advertise.

const std = @import("std");
const json = @import("json.zig");
const version = @import("version.zig");

/// One resolvable topic. `name` is the bare query (`privacy`);
/// `topic.<name>` resolves the same entry. `summary` is the one-line
/// description, `details` the full coverage paragraph (may name several
/// sub-subjects), `see_also` the related commands and explain queries,
/// `docs` the long-form guide link.
pub const Spec = struct {
    name: []const u8,
    summary: []const u8,
    details: []const u8,
    see_also: []const []const u8,
    docs: []const u8,
};

/// The recognized set. Ordering is the catalog/--list row order.
pub const specs = [_]Spec{
    .{
        .name = "privacy",
        .summary = "what tau stores locally, what leaves the machine, and how secrets are redacted in diagnostics",
        .details = "tau transmits to two places only: the configured provider endpoint (prompts, system prompt, tool arguments and results, @file contents — nothing else; TAU_ENDPOINT may point at a local server) and GitHub (the `tau version --check`/`tau upgrade` release lookup — TAU_NO_UPDATE_CHECK=1 opts out — and the `tau bug` pre-filled issue URL, which opens in your browser and sends nothing until you submit). `tau acp serve` and the mcacp bridge are local stdio. Local state lives under ~/.config/tau/: config.json (may hold api_key — `tau explain doctor.config_permissions` and `tau explain doctor.plaintext_secrets` cover tightening it), sessions/<name>.json transcripts (full prompt + reply text, NOT redacted), fleets/ manifests, snippets/ (client wiring fragments, no secrets), and debug/<timestamp>.log written only with --debug (TAU_DEBUG_LOG overrides the path). The diagnostics bundle `tau doctor --report` renders — and `tau bug` carries into the issue body (`--attach-report` reuses a report captured earlier, e.g. at crash time; `--out` writes the bundle to a file; `--no-report` omits it) — contains build metadata, doctor check results, and a sanitized effective config. Redaction: the resolved API key plus every configured/env key, Bearer tokens, \"api_key\"-style JSON fields, and *_KEY=/*_TOKEN= env assignments mask to ***REDACTED*** in the debug-log file, the report bundle, and the `tau bug` issue body and URL — but --debug's live stderr stays raw and session transcripts are unredacted, so review files before sharing.",
        .see_also = &.{ "tau bug", "tau bug --attach-report", "tau doctor --report", "tau explain TAU_DEBUG_LOG", "tau explain TAU_NO_UPDATE_CHECK", "tau explain doctor.plaintext_secrets" },
        .docs = version.troubleshooting_doc_url ++ "#diagnostic-toolkit",
    },
};

const prefix = "topic.";

/// Look up a topic by name — bare `privacy` or the canonical
/// `topic.privacy` spelling both resolve. Unknown names and a bare
/// `topic.` return null (the did-you-mean path suggests the nearest
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

/// Serialize one topic entry for `tau explain` (no trailing newline — the
/// caller owns framing):
/// {"topic":"N","summary":"S","details":"D","see_also":[...],"docs":"U"}
/// Caller owns the returned slice.
pub fn formatTopicJson(a: std.mem.Allocator, s: Spec) ![]u8 {
    var b: std.ArrayList(u8) = .empty;
    try b.appendSlice(a, "{\"topic\":");
    try appendStr(a, &b, s.name);
    try b.appendSlice(a, ",\"summary\":");
    try appendStr(a, &b, s.summary);
    try b.appendSlice(a, ",\"details\":");
    try appendStr(a, &b, s.details);
    try b.appendSlice(a, ",\"see_also\":[");
    for (s.see_also, 0..) |item, i| {
        if (i > 0) try b.appendSlice(a, ",");
        try appendStr(a, &b, item);
    }
    try b.appendSlice(a, "],\"docs\":");
    try appendStr(a, &b, s.docs);
    try b.appendSlice(a, "}");
    return b.toOwnedSlice(a);
}

/// Append `"<escaped s>"` to buf.
fn appendStr(a: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
    try buf.append(a, '"');
    try json.escapeInto(a, buf, s);
    try buf.append(a, '"');
}

/// Human-readable `tau explain --human <topic>` rendering — drawn from the
/// same Spec so the prose and JSON forms can never drift apart.
pub fn formatTopicHuman(a: std.mem.Allocator, s: Spec) ![]u8 {
    var b: std.ArrayList(u8) = .empty;
    try b.appendSlice(a, try std.fmt.allocPrint(a, "topic  {s}\n  summary:  {s}\n  details:  {s}\n  see also: ", .{ s.name, s.summary, s.details }));
    for (s.see_also, 0..) |item, i| {
        if (i > 0) try b.appendSlice(a, " · ");
        try b.appendSlice(a, item);
    }
    try b.appendSlice(a, try std.fmt.allocPrint(a, "\n  docs:     {s}\n", .{s.docs}));
    return b.toOwnedSlice(a);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "findSpec: bare and topic.-prefixed spellings resolve, unknowns do not" {
    const s = findSpec("privacy").?;
    try testing.expectEqualStrings("privacy", s.name);
    const p = findSpec("topic.privacy").?;
    try testing.expectEqualStrings("privacy", p.name);
    try testing.expect(findSpec("privavy") == null);
    try testing.expect(findSpec("topic.") == null);
    try testing.expect(findSpec("topic.bogus") == null);
    try testing.expect(findSpec("") == null);
    // Case-sensitive — the did-you-mean path suggests the canonical name.
    try testing.expect(findSpec("Privacy") == null);
}

test "names list stays parallel to specs" {
    for (specs, 0..) |s, i| try testing.expectEqualStrings(s.name, names[i]);
}

test "privacy entry covers diagnostics, redaction, bundle, and tau bug" {
    const s = findSpec("privacy").?;
    // The task-pinned coverage: diagnostics collection, secret redaction,
    // the diagnostics/crash-time bundle, and `tau bug` cross-links.
    try testing.expect(std.mem.indexOf(u8, s.details, "tau bug") != null);
    try testing.expect(std.mem.indexOf(u8, s.details, "tau doctor --report") != null);
    try testing.expect(std.mem.indexOf(u8, s.details, "--attach-report") != null);
    try testing.expect(std.mem.indexOf(u8, s.details, "***REDACTED***") != null);
    try testing.expect(std.mem.indexOf(u8, s.details, "--debug") != null);
    try testing.expect(std.mem.indexOf(u8, s.details, "sessions/") != null);
    var found_bug = false;
    for (s.see_also) |item| {
        if (std.mem.eql(u8, item, "tau bug")) found_bug = true;
        // Every see_also names a real surface — explain queries keep the
        // `tau explain <name>` spelling so they are directly runnable.
        try testing.expect(std.mem.startsWith(u8, item, "tau "));
    }
    try testing.expect(found_bug);
}

test "formatTopicJson emits the pinned member order" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const out = try formatTopicJson(a, findSpec("privacy").?);
    try testing.expect(std.mem.startsWith(u8, out, "{\"topic\":\"privacy\",\"summary\":\""));
    try testing.expect(std.mem.indexOf(u8, out, ",\"details\":\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, ",\"see_also\":[\"tau bug\"") != null);
    try testing.expect(std.mem.endsWith(u8, out, "\"}"));
    // The JSON must parse cleanly.
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, out, .{});
    try testing.expect(v.object.get("see_also").?.array.items.len > 0);
}

test "formatTopicHuman renders summary, details, see-also, and docs" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const out = try formatTopicHuman(a, findSpec("privacy").?);
    try testing.expect(std.mem.indexOf(u8, out, "topic  privacy\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "summary:") != null);
    try testing.expect(std.mem.indexOf(u8, out, "details:") != null);
    try testing.expect(std.mem.indexOf(u8, out, "see also: tau bug") != null);
    try testing.expect(std.mem.indexOf(u8, out, "docs:     https://") != null);
    try testing.expect(std.mem.endsWith(u8, out, "\n"));
}
