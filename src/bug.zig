// `tau bug` — build a pre-filled GitHub issue carrying the redacted
// `tau doctor --report` diagnostics bundle so reports arrive with build
// metadata, check results, and the sanitized config attached. The command
// runs the same diagnostic sweep as `tau doctor` (--offline/--deep and the
// --provider/--model/--api-key overrides apply), renders the Markdown bundle,
// and emits one JSON object on stdout:
//
//   {"title","labels","url","body","url_truncated","out","opened","done":true}
//
// `url` is a github.com/javimosch/tau/issues/new link with title, labels, and
// body pre-filled — open it in a browser (or pass --open) to file the issue.
// `body` always carries the full issue text including the diagnostics bundle,
// so an agent can also file via the API even when the URL had to drop the
// bundle for length (`url_truncated`: GitHub rejects over-long GET URLs, so
// past max_url_chars the link falls back to a short body that asks for the
// bundle to be attached manually). --out writes the bundle to a file for
// attaching; --no-report omits diagnostics entirely (mutually exclusive with
// --out). Exit code is 0 on success — the diagnostics verdict lives inside
// the report, not in the exit status, so `tau bug` works fine on a healthy
// install too (feature requests welcome).

const std = @import("std");
const builtin = @import("builtin");
const term = @import("term.zig");
const json = @import("json.zig");
const cfgmod = @import("config.zig");
const doctor = @import("doctor.zig");
const version_mod = @import("version.zig");
const Config = cfgmod.Config;

pub const default_title = "Bug report";
pub const default_labels = "bug";

/// Size cap for the generated issues/new URL. GitHub sits behind proxies
/// that 414 on request lines past ~8KB; keep headroom for title + labels.
const max_url_chars = 7000;

/// Percent-encode a string for a URL query parameter. Unreserved characters
/// (RFC 3986: A-Z a-z 0-9 - . _ ~) pass through; everything else becomes
/// %XX — spaces stay %20 (GitHub decodes both, %20 avoids '+' ambiguity).
fn urlEncodeQuery(arena: std.mem.Allocator, s: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    const hex = "0123456789ABCDEF";
    for (s) |ch| {
        const unreserved = (ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z') or
            (ch >= '0' and ch <= '9') or ch == '-' or ch == '.' or ch == '_' or ch == '~';
        if (unreserved) {
            try buf.append(arena, ch);
        } else {
            try buf.append(arena, '%');
            try buf.append(arena, hex[ch >> 4]);
            try buf.append(arena, hex[ch & 0xF]);
        }
    }
    return buf.toOwnedSlice(arena);
}

/// Compose the issue body: an optional user description above the
/// diagnostics bundle (or an "omitted" note telling maintainers how to get
/// it). `report_note` is the reason line used when no bundle follows.
fn issueBody(arena: std.mem.Allocator, desc: ?[]const u8, report: ?[]const u8, report_note: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    if (desc) |d| {
        try buf.appendSlice(arena, d);
        try buf.appendSlice(arena, "\n\n---\n\n");
    }
    if (report) |r| {
        try buf.appendSlice(arena, r);
    } else {
        if (desc == null) try buf.appendSlice(arena, "_Describe the bug here._\n\n");
        try buf.appendSlice(arena, report_note);
        try buf.append(arena, '\n');
    }
    return buf.toOwnedSlice(arena);
}

/// Build the issues/new URL with title, body, and (when non-empty) labels.
fn buildIssueUrl(arena: std.mem.Allocator, title: []const u8, body: []const u8, labels: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(arena, version_mod.issues_new_url);
    try buf.appendSlice(arena, "?title=");
    try buf.appendSlice(arena, try urlEncodeQuery(arena, title));
    try buf.appendSlice(arena, "&body=");
    try buf.appendSlice(arena, try urlEncodeQuery(arena, body));
    if (labels.len > 0) {
        try buf.appendSlice(arena, "&labels=");
        try buf.appendSlice(arena, try urlEncodeQuery(arena, labels));
    }
    return buf.toOwnedSlice(arena);
}

/// Open `url` in the system browser. Honors $BROWSER (a bare command name)
/// before the platform default: `open` on macOS, `rundll32` on Windows,
/// `xdg-open` elsewhere. Returns false when the opener cannot be spawned or
/// exits non-zero — the URL is still emitted either way.
fn openInBrowser(io: std.Io, gpa: std.mem.Allocator, env: *std.process.Environ.Map, url: []const u8) bool {
    var argv_buf: [3][]const u8 = undefined;
    const argv: []const []const u8 = if (env.get("BROWSER")) |b| blk: {
        argv_buf[0] = b;
        argv_buf[1] = url;
        break :blk argv_buf[0..2];
    } else switch (builtin.os.tag) {
        .macos => blk: {
            argv_buf[0] = "open";
            argv_buf[1] = url;
            break :blk argv_buf[0..2];
        },
        .windows => blk: {
            argv_buf[0] = "rundll32";
            argv_buf[1] = "url.dll,FileProtocolHandler";
            argv_buf[2] = url;
            break :blk argv_buf[0..3];
        },
        else => blk: {
            argv_buf[0] = "xdg-open";
            argv_buf[1] = url;
            break :blk argv_buf[0..2];
        },
    };
    const res = std.process.run(gpa, io, .{
        .argv = argv,
        .stdout_limit = .unlimited,
        .stderr_limit = .unlimited,
    }) catch return false;
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);
    return switch (res.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

/// Serialize the final JSON envelope. `body` is the complete issue text
/// (report included unless --no-report); `report` is repeated as its own
/// field so the bundle is directly addressable without ungluing the body.
fn formatBugJson(
    arena: std.mem.Allocator,
    title: []const u8,
    labels: []const u8,
    url: []const u8,
    body: []const u8,
    report: ?[]const u8,
    truncated: bool,
    out_path: ?[]const u8,
    opened: bool,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(arena, "{\"title\":\"");
    try json.escapeInto(arena, &buf, title);
    try buf.appendSlice(arena, "\",\"labels\":\"");
    try json.escapeInto(arena, &buf, labels);
    try buf.appendSlice(arena, "\",\"url\":\"");
    try json.escapeInto(arena, &buf, url);
    try buf.appendSlice(arena, "\",\"body\":\"");
    try json.escapeInto(arena, &buf, body);
    try buf.appendSlice(arena, "\",\"report\":");
    if (report) |r| {
        try buf.append(arena, '"');
        try json.escapeInto(arena, &buf, r);
        try buf.append(arena, '"');
    } else try buf.appendSlice(arena, "null");
    try buf.appendSlice(arena, ",\"url_truncated\":");
    try buf.appendSlice(arena, if (truncated) "true" else "false");
    try buf.appendSlice(arena, ",\"out\":");
    if (out_path) |p| {
        try buf.append(arena, '"');
        try json.escapeInto(arena, &buf, p);
        try buf.append(arena, '"');
    } else try buf.appendSlice(arena, "null");
    try buf.appendSlice(arena, ",\"opened\":");
    try buf.appendSlice(arena, if (opened) "true" else "false");
    try buf.appendSlice(arena, ",\"done\":true}\n");
    return buf.toOwnedSlice(arena);
}

pub fn run(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, cfg: Config, env: *std.process.Environ.Map) !u8 {
    const title = cfg.bug_title orelse default_title;
    const labels = cfg.bug_labels orelse default_labels;

    // Same sweep as `tau doctor --report` — honors the offline/deep and
    // provider/model/api-key overrides the arg parser copied onto cfg.
    const report: ?[]u8 = if (cfg.bug_no_report)
        null
    else blk: {
        const checks = try doctor.collectChecks(io, gpa, arena, cfg, env);
        break :blk try doctor.formatReportMarkdown(io, arena, checks, null, cfg, env);
    };

    // The full issue body always carries the bundle; the URL gets a short
    // fallback body when the encoded link would exceed max_url_chars.
    const body = try issueBody(arena, cfg.bug_body, report, "_No diagnostics attached (`tau bug --no-report`)._");
    var url = try buildIssueUrl(arena, title, body, labels);
    var truncated = false;
    if (url.len > max_url_chars) {
        const short = try issueBody(arena, cfg.bug_body, null, "_Diagnostics bundle omitted — it exceeded the pre-filled-URL size limit. Attach the output of `tau doctor --report` (or the `report` field / --out file from `tau bug`)._");
        url = try buildIssueUrl(arena, title, short, labels);
        truncated = true;
    }

    if (cfg.bug_out) |p| {
        const data = report orelse body;
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = data });
    }

    const opened = cfg.bug_open and openInBrowser(io, gpa, env, url);

    term.out(try formatBugJson(arena, title, labels, url, body, report, truncated, cfg.bug_out, opened));
    return 0;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
const testing = std.testing;

test "urlEncodeQuery: unreserved pass through, reserved get %XX" {
    const a = testing.allocator;
    const got = try urlEncodeQuery(a, "abc-._~ AZaz09");
    defer a.free(got);
    try testing.expectEqualStrings("abc-._~%20AZaz09", got);
}

test "urlEncodeQuery: newlines and markdown escape fully" {
    const a = testing.allocator;
    const got = try urlEncodeQuery(a, "# h1\n`code` & <tag>\n");
    defer a.free(got);
    try testing.expectEqualStrings("%23%20h1%0A%60code%60%20%26%20%3Ctag%3E%0A", got);
}

test "urlEncodeQuery: non-ASCII bytes encode per byte" {
    const a = testing.allocator;
    const got = try urlEncodeQuery(a, "caf\xC3\xA9");
    defer a.free(got);
    try testing.expectEqualStrings("caf%C3%A9", got);
}

test "buildIssueUrl: title/body/labels in query; empty labels omitted" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const with = try buildIssueUrl(a, "T t", "b\n", "bug");
    try testing.expectEqualStrings(
        "https://github.com/javimosch/tau/issues/new?title=T%20t&body=b%0A&labels=bug",
        with,
    );
    const without = try buildIssueUrl(a, "T", "b", "");
    try testing.expect(std.mem.indexOf(u8, without, "&labels=") == null);
}

test "issueBody: description sits above the bundle; notes mark omission" {
    const a = testing.allocator;
    const full = try issueBody(a, "it crashed", "## REPORT", "note");
    defer a.free(full);
    try testing.expectEqualStrings("it crashed\n\n---\n\n## REPORT", full);

    const no_desc = try issueBody(a, null, "## REPORT", "note");
    defer a.free(no_desc);
    try testing.expectEqualStrings("## REPORT", no_desc);

    const omitted = try issueBody(a, "crash", null, "_omitted._");
    defer a.free(omitted);
    try testing.expectEqualStrings("crash\n\n---\n\n_omitted._\n", omitted);

    const bare = try issueBody(a, null, null, "_omitted._");
    defer a.free(bare);
    try testing.expect(std.mem.indexOf(u8, bare, "_Describe the bug here._") != null);
    try testing.expect(std.mem.indexOf(u8, bare, "_omitted._") != null);
}

test "formatBugJson: all fields emitted, nulls for absent report/out" {
    const a = testing.allocator;
    const got = try formatBugJson(a, "t", "bug", "u", "b", null, false, null, false);
    defer a.free(got);
    try testing.expect(std.mem.indexOf(u8, got, "\"report\":null") != null);
    try testing.expect(std.mem.indexOf(u8, got, "\"out\":null") != null);
    try testing.expect(std.mem.indexOf(u8, got, "\"url_truncated\":false") != null);
    try testing.expect(std.mem.indexOf(u8, got, "\"opened\":false") != null);
    try testing.expect(std.mem.endsWith(u8, got, "\"done\":true}\n"));
}
