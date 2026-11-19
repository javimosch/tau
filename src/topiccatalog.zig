//! The curated-topic catalog behind `tau explain <topic>` — free-standing
//! subjects that don't belong to a generated registry (no error code,
//! config key, doctor check, env var, or client row backs them). `privacy`
//! (`tau explain privacy`) covers what tau stores locally, what leaves the
//! machine, and how the diagnostics surfaces (`--debug` logs,
//! `tau doctor --report`, `tau bug`) redact secrets; `trust`
//! (`tau explain trust`) covers the release trust story — checksums,
//! cosign/Sigstore signatures, SLSA provenance attestations, and CycloneDX
//! SBOMs.
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
    .{
        .name = "trust",
        .summary = "how to verify a tau release is authentic — checksums, cosign/Sigstore signatures, SLSA provenance attestations, and CycloneDX SBOMs",
        .details = "Releases produced by the signing pipeline ship a layered trust story — pick the level you need; each layer is independent and strictly stronger than the last. Layer 1, checksum: every release publishes SHA256SUMS.txt covering all archives, and install.sh/install.ps1 verify it fail-closed before writing the binary (TAU_SKIP_CHECKSUM=1 opts out — only with another trust path; manual check: grep ' <asset>$' SHA256SUMS.txt | sha256sum -c -). Layer 2, signature: opt-in cosign/Sigstore verification of the <asset>.sigstore.json bundle — `tau upgrade --verify-signature` or `TAU_VERIFY_SIGSTORE=1` for install.sh/install.ps1; it requires cosign on PATH and fails closed when cosign or the bundle is missing. Manual check: cosign verify-blob --bundle <asset>.sigstore.json --certificate-identity-regexp '^https://github\\.com/javimosch/tau/\\.github/workflows/release\\.yml@refs/tags/v' --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' <asset>. All signing is keyless — the release job mints a short-lived Fulcio certificate from its GitHub OIDC identity and records every signature in the Rekor transparency log, so there is no private key to lose or rotate. Layer 3, provenance: SLSA v1 build-provenance attestations for every asset live in the repo's GitHub attestation store — gh attestation verify <asset> --repo javimosch/tau proves which repo, workflow, ref, and runner produced the bytes (no bundle download needed). Layer 4, contents: <asset>.sbom.json is a CycloneDX SBOM — the first component carries the archive's own SHA-256 and the rest hash every file inside the archive; SBOMs are signed and attested like the archives. Caveats: signature bundles, attestations, and SBOMs only exist on releases produced after the signing pipeline shipped — v0.4.0 predates it, so opt-in verification fails closed there (a missing bundle is the intended signal, not an error to bypass); a failed cosign verify-blob or gh attestation verify means the asset was not produced by the release workflow — do not run it.",
        .see_also = &.{ "tau upgrade --verify-signature", "tau version --check", "tau explain TAU_VERIFY_SIGSTORE", "tau explain TAU_SKIP_CHECKSUM", "tau explain TAU_BASE_URL", "tau explain privacy" },
        .docs = version.troubleshooting_doc_url ++ "#install--upgrade-failures",
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

test "trust entry covers checksums, signatures, provenance, and SBOMs" {
    const s = findSpec("trust").?;
    // The task-pinned coverage: the checksum layer, opt-in cosign/Sigstore
    // signatures, SLSA provenance attestations, and CycloneDX SBOMs — plus
    // the upgrade/installer flags that drive them.
    try testing.expect(std.mem.indexOf(u8, s.details, "SHA256SUMS.txt") != null);
    try testing.expect(std.mem.indexOf(u8, s.details, "--verify-signature") != null);
    try testing.expect(std.mem.indexOf(u8, s.details, "TAU_VERIFY_SIGSTORE") != null);
    try testing.expect(std.mem.indexOf(u8, s.details, "cosign verify-blob") != null);
    try testing.expect(std.mem.indexOf(u8, s.details, "SLSA") != null);
    try testing.expect(std.mem.indexOf(u8, s.details, "gh attestation verify") != null);
    try testing.expect(std.mem.indexOf(u8, s.details, "sbom.json") != null);
    var found_upgrade = false;
    for (s.see_also) |item| {
        if (std.mem.eql(u8, item, "tau upgrade --verify-signature")) found_upgrade = true;
        try testing.expect(std.mem.startsWith(u8, item, "tau "));
    }
    try testing.expect(found_upgrade);
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
