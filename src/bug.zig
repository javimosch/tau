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
const debuglog = @import("debuglog.zig");
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
/// it). `report_note` is the reason line used when no bundle follows. The
/// composed body is masked with `secrets` before returning: the report
/// arrives pre-masked (idempotent — the mask text matches no secret), and a
/// credential that reached the description must not leak into the issue
/// body, the pre-filled URL, or an --out file.
fn issueBody(arena: std.mem.Allocator, secrets: []const []const u8, desc: ?[]const u8, report: ?[]const u8, report_note: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(arena);
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
    return debuglog.redactAlloc(arena, buf.items, secrets);
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
    // Mask list = credentials derivable from this cfg/env plus everything
    // registered process-wide — applied to the user-controlled title/labels
    // and (inside issueBody) the composed body so no channel carries a key.
    const secrets = try debuglog.collectAllSecrets(arena, env, cfg);
    const title = try debuglog.redactAlloc(arena, cfg.bug_title orelse default_title, secrets);
    const labels = try debuglog.redactAlloc(arena, cfg.bug_labels orelse default_labels, secrets);

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
    const body = try issueBody(arena, secrets, cfg.bug_body, report, "_No diagnostics attached (`tau bug --no-report`)._");
    var url = try buildIssueUrl(arena, title, body, labels);
    var truncated = false;
    if (url.len > max_url_chars) {
        const short = try issueBody(arena, secrets, cfg.bug_body, null, "_Diagnostics bundle omitted — it exceeded the pre-filled-URL size limit. Attach the output of `tau doctor --report` (or the `report` field / --out file from `tau bug`)._");
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
    const none: []const []const u8 = &.{};
    const full = try issueBody(a, none, "it crashed", "## REPORT", "note");
    defer a.free(full);
    try testing.expectEqualStrings("it crashed\n\n---\n\n## REPORT", full);

    const no_desc = try issueBody(a, none, null, "## REPORT", "note");
    defer a.free(no_desc);
    try testing.expectEqualStrings("## REPORT", no_desc);

    const omitted = try issueBody(a, none, "crash", null, "_omitted._");
    defer a.free(omitted);
    try testing.expectEqualStrings("crash\n\n---\n\n_omitted._\n", omitted);

    const bare = try issueBody(a, none, null, null, "_omitted._");
    defer a.free(bare);
    try testing.expect(std.mem.indexOf(u8, bare, "_Describe the bug here._") != null);
    try testing.expect(std.mem.indexOf(u8, bare, "_omitted._") != null);
}

test "issueBody: secrets in the description or bundle are masked" {
    const a = testing.allocator;
    const secrets: []const []const u8 = &.{"k-secret-123456"};
    const body = try issueBody(a, secrets, "token was k-secret-123456", "bundle: k-secret-123456", "note");
    defer a.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "k-secret-123456") == null);
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, body, debuglog.mask));
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

// ---------------------------------------------------------------------------
// Redaction invariants — credentials that reach the issue body, the
// pre-filled URL, the JSON envelope, or an --out attachment must not survive.
// ---------------------------------------------------------------------------

/// A throwaway HOME under .zig-cache/tmp so formatReportMarkdown exercises
/// its real config-file read (same TestHome pattern as doctor.zig).
const TestHome = struct {
    tmp: testing.TmpDir,
    env: std.process.Environ.Map,
    home: []const u8,

    fn init(arena: std.mem.Allocator) !TestHome {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const home = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
        try std.Io.Dir.cwd().createDirPath(testing.io, try std.fmt.allocPrint(arena, "{s}/.config/tau", .{home}));
        var env = std.process.Environ.Map.init(arena);
        try env.put("HOME", home);
        return .{ .tmp = tmp, .env = env, .home = home };
    }

    fn writeConfig(self: *TestHome, arena: std.mem.Allocator, content: []const u8) !void {
        try std.Io.Dir.cwd().writeFile(testing.io, .{
            .sub_path = try std.fmt.allocPrint(arena, "{s}/.config/tau/config.json", .{self.home}),
            .data = content,
        });
    }

    fn deinit(self: *TestHome) void {
        self.tmp.cleanup();
    }
};

const redact_alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._";

/// Random secret with a `k-` prefix so it can never coincide with static
/// output text (field names, "openai", URL boilerplate) — any hit is a real
/// leak. Every alphabet char is URL-unreserved, so a leaked literal shows up
/// verbatim in the percent-encoded URL too.
fn randKey(r: std.Random, a: std.mem.Allocator) ![]u8 {
    const s = try a.alloc(u8, r.intRangeAtMost(usize, 10, 36));
    s[0] = 'k';
    s[1] = '-';
    for (s[2..]) |*ch| ch.* = redact_alphabet[r.uintLessThan(usize, redact_alphabet.len)];
    return s;
}

fn expectNoLeak(out: []const u8, secret: []const u8) !void {
    if (std.mem.indexOf(u8, out, secret) != null) {
        std.debug.print("tau bug output leaked '{s}': {s}\n", .{ secret, out });
        return error.TestUnexpectedResult;
    }
}

test "property: generated secrets never survive the `tau bug` envelope or attachments" {
    var prng = std.Random.DefaultPrng.init(0x279_b06);
    const r = prng.random();
    var iter: usize = 0;
    while (iter < 60) : (iter += 1) {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var home = try TestHome.init(a);
        defer home.deinit();

        // One generated secret per leak channel: config file, keys map, env
        // var, --api-key flag value, endpoint userinfo password, and one
        // registered credential pasted into the --body description.
        const k_file = try randKey(r, a);
        const k_map = try randKey(r, a);
        const k_env = try randKey(r, a);
        const k_flag = try randKey(r, a);
        const k_pw = try randKey(r, a);
        const k_desc = try randKey(r, a);
        try home.writeConfig(a, try std.fmt.allocPrint(a,
            "{{ \"provider\": \"openai\", \"api_key\": \"{s}\", \"keys\": {{ \"openai\": \"{s}\" }} }}",
            .{ k_file, k_map },
        ));
        var km = std.StringHashMap([]const u8).init(a);
        try km.put("openai", k_map);
        try home.env.put("TAU_API_KEY", k_env);
        const cfg = Config{
            .provider = "openai",
            .api_key = k_flag,
            .config_api_key = k_file,
            .keys = km,
            .endpoint = try std.fmt.allocPrint(a, "https://user:{s}@127.0.0.1:1/", .{k_pw}),
            .bug_title = try std.fmt.allocPrint(a, "crash with {s}", .{k_desc}),
            .bug_body = try std.fmt.allocPrint(a, "repro: auth header was {s}", .{k_desc}),
        };
        debuglog.addSecretsForTest(&.{ k_file, k_map, k_env, k_flag, k_pw, k_desc });
        defer debuglog.clearSecretsForTest();

        // Hostile diagnostics: a check embedding the endpoint and key
        // outright — stands in for any future check that interpolates
        // credentials into the attached bundle.
        const checks = [_]doctor.Check{
            .{
                .name = "endpoint_reachable",
                .status = .fail,
                .message = try std.fmt.allocPrint(a, "endpoint unreachable: {s}", .{cfg.endpoint}),
                .hint = try std.fmt.allocPrint(a, "verify token {s}", .{k_flag}),
            },
        };
        const report = try doctor.formatReportMarkdown(testing.io, a, &checks, null, cfg, &home.env);

        // Drive the same seams run() does: mask list, composed body,
        // issues/new URL, JSON envelope, and the --out payload selection.
        const secrets = try debuglog.collectAllSecrets(a, &home.env, cfg);
        const title = try debuglog.redactAlloc(a, cfg.bug_title.?, secrets);
        const labels = try debuglog.redactAlloc(a, default_labels, secrets);
        const body = try issueBody(a, secrets, cfg.bug_body, report, "_No diagnostics attached._");
        const url = try buildIssueUrl(a, title, body, labels);
        const envelope = try formatBugJson(a, title, labels, url, body, report, false, "report.md", false);
        const out_data: []const u8 = report; // --out payload in run() (report branch)

        for ([_][]const u8{ k_file, k_map, k_env, k_flag, k_pw, k_desc }) |sec| {
            try expectNoLeak(report, sec);
            try expectNoLeak(body, sec);
            try expectNoLeak(url, sec);
            try expectNoLeak(title, sec);
            try expectNoLeak(envelope, sec);
            try expectNoLeak(out_data, sec);
            // A secret spelled inside the JSON envelope arrives escaped —
            // the escaped variant must be absent too.
            try expectNoLeak(envelope, try json.escapeAlloc(a, sec));
        }
        // Masking actually ran on the secret-bearing channels.
        try testing.expect(std.mem.indexOf(u8, body, debuglog.mask) != null);
        try testing.expect(std.mem.indexOf(u8, title, debuglog.mask) != null);

        // The truncated fallback body (report dropped for URL length) still
        // masks the description channel.
        const short = try issueBody(a, secrets, cfg.bug_body, null, "_omitted._");
        try expectNoLeak(short, k_desc);
        // --no-report: the body is the only --out payload left.
        const norep = try issueBody(a, secrets, cfg.bug_body, null, "_No diagnostics attached (`tau bug --no-report`)._");
        for ([_][]const u8{ k_file, k_map, k_env, k_flag, k_pw, k_desc }) |sec| {
            try expectNoLeak(norep, sec);
        }
    }
}
