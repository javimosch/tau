// Non-blocking, opt-out update check shared by `tau version --check` and the
// `tau doctor` update_available row. Fetches the GitHub "latest release" API
// payload via curl (the same subprocess transport the provider layer uses)
// with a short --max-time so the check can never hang a run. TAU_UPDATE_URL
// overrides the lookup URL (file:// stubs in tests, mirrors behind proxies);
// TAU_NO_UPDATE_CHECK disables the check everywhere, including an explicit
// `version --check`, which then reports checked:false so scripts can see why.

const std = @import("std");
const ver = @import("version.zig");

/// curl --max-time for the release lookup. Deliberately short: the check is
/// advisory and must never make a command feel hung. The process timeout is
/// a slightly larger backstop.
pub const max_time_s: u32 = 5;

/// Outcome of one update check.
pub const Result = struct {
    /// true when a response was fetched and a release tag was extracted.
    checked: bool = false,
    /// Latest version with any leading v/V stripped ("0.5.0"); null when the
    /// check did not run or the tag did not parse as a dotted numeric version.
    latest: ?[]const u8 = null,
    /// Raw tag from the API ("v0.5.0"); basis for the release page URL.
    tag: ?[]const u8 = null,
    /// true only when `latest` parses and is strictly newer than `version`.
    update_available: bool = false,
    /// Why the check did not produce a comparable version (disabled, network
    /// failure, unexpected payload, unparseable tag).
    reason: ?[]const u8 = null,
};

/// Opt-out: TAU_NO_UPDATE_CHECK set to anything but "" or "0" disables every
/// update check.
pub fn disabled(env: *std.process.Environ.Map) bool {
    const v = env.get("TAU_NO_UPDATE_CHECK") orelse return false;
    return v.len > 0 and !std.mem.eql(u8, v, "0");
}

/// Lookup URL: TAU_UPDATE_URL override, else the GitHub latest-release API.
pub fn lookupUrl(env: *std.process.Environ.Map) []const u8 {
    if (env.get("TAU_UPDATE_URL")) |u| {
        if (u.len > 0) return u;
    }
    return ver.latest_release_url;
}

/// Release page for a tag, e.g. ".../releases/tag/v0.5.0" — the "upgrade here"
/// link emitted when update_available is true.
pub fn releaseUrl(arena: std.mem.Allocator, tag: []const u8) ![]u8 {
    return std.fmt.allocPrint(arena, "{s}/tag/{s}", .{ ver.releases_page_url, tag });
}

/// Parse a dotted numeric version into components (max 8). A leading v/V is
/// stripped and each component contributes only its leading digit run, so
/// "v0.4.0-beta" parses as [0,4,0] and "0.4rc1" as [0,4]. Null when no
/// component carries digits at all.
fn parseComponents(s: []const u8, out: *[8]u64) ?usize {
    var str = s;
    if (str.len > 0 and (str[0] == 'v' or str[0] == 'V')) str = str[1..];
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, str, '.');
    while (it.next()) |comp| {
        if (n >= out.len) break;
        var d_end: usize = 0;
        while (d_end < comp.len and std.ascii.isDigit(comp[d_end])) d_end += 1;
        if (d_end == 0) {
            if (n == 0) return null;
            break; // trailing non-numeric component ("0.4.beta"): stop, keep prefix
        }
        out[n] = std.fmt.parseInt(u64, comp[0..d_end], 10) catch return null;
        n += 1;
    }
    return if (n == 0) null else n;
}

/// Ordering of two versions like std.mem.order: .lt when a < b. Missing
/// trailing components count as 0 ("0.4" == "0.4.0"). Null when either side
/// has no digits to compare.
pub fn compareVersions(a: []const u8, b: []const u8) ?std.math.Order {
    var abuf: [8]u64 = undefined;
    var bbuf: [8]u64 = undefined;
    const an = parseComponents(a, &abuf) orelse return null;
    const bn = parseComponents(b, &bbuf) orelse return null;
    const n = @max(an, bn);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const x: u64 = if (i < an) abuf[i] else 0;
        const y: u64 = if (i < bn) bbuf[i] else 0;
        if (x < y) return .lt;
        if (x > y) return .gt;
    }
    return .eq;
}

/// Extract "tag_name" from a release API payload. Null when the body is not
/// an object or the tag is missing/not a string.
fn parseTag(arena: std.mem.Allocator, body: []const u8) ?[]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, arena, body, .{}) catch return null;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const tag = obj.get("tag_name") orelse return null;
    return switch (tag) {
        .string => |s| if (s.len > 0) arena.dupe(u8, s) catch null else null,
        else => null,
    };
}

/// GET a URL via curl; returns the response body (gpa-allocated) or null on
/// any failure: curl missing, non-zero exit (-f rejects HTTP >= 400),
/// timeout, empty body. Shared by the release lookup and `tau upgrade`'s
/// installer download — same transport, same short --max-time.
pub fn fetchLatest(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, url: []const u8) ?[]u8 {
    const mt = std.fmt.allocPrint(arena, "{d}", .{max_time_s}) catch return null;
    const ua = std.fmt.allocPrint(arena, "User-Agent: tau/{s}", .{ver.version}) catch return null;
    const timeout = std.Io.Timeout{ .duration = .{
        .raw = std.Io.Duration.fromMilliseconds((max_time_s + 10) * 1000),
        .clock = .awake,
    } };
    const res = std.process.run(gpa, io, .{
        .argv = &.{ "curl", "-fsSL", "--max-time", mt, "-H", ua, "-H", "Accept: application/vnd.github+json", url },
        .stdout_limit = .unlimited,
        .stderr_limit = .unlimited,
        .timeout = timeout,
    }) catch return null;
    defer gpa.free(res.stderr);
    switch (res.term) {
        .exited => |code| {
            if (code == 0 and res.stdout.len > 0) return res.stdout;
            gpa.free(res.stdout);
            return null;
        },
        else => {
            gpa.free(res.stdout);
            return null;
        },
    }
}

/// Run the check. Never fails hard: every failure path returns a Result with
/// checked:false and a human-readable reason.
pub fn check(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, env: *std.process.Environ.Map) Result {
    if (disabled(env)) return .{ .reason = "disabled (TAU_NO_UPDATE_CHECK)" };
    const url = lookupUrl(env);
    const body = fetchLatest(io, gpa, arena, url) orelse
        return .{ .reason = std.fmt.allocPrint(arena, "release lookup failed ({s})", .{url}) catch "release lookup failed" };
    defer gpa.free(body);
    const raw = parseTag(arena, body) orelse
        return .{ .reason = "release payload had no tag_name" };
    var res = Result{ .checked = true, .tag = raw };
    const norm = if (raw[0] == 'v' or raw[0] == 'V') raw[1..] else raw;
    const ord = compareVersions(ver.version, norm) orelse {
        res.reason = "unparseable release tag";
        return res;
    };
    res.latest = norm;
    res.update_available = ord == .lt;
    return res;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
const testing = std.testing;

test "disabled: unset, empty and 0 stay enabled; anything else opts out" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try testing.expect(!disabled(&env));
    try env.put("TAU_NO_UPDATE_CHECK", "");
    try testing.expect(!disabled(&env));
    try env.put("TAU_NO_UPDATE_CHECK", "0");
    try testing.expect(!disabled(&env));
    try env.put("TAU_NO_UPDATE_CHECK", "1");
    try testing.expect(disabled(&env));
    try env.put("TAU_NO_UPDATE_CHECK", "yes");
    try testing.expect(disabled(&env));
}

test "lookupUrl: TAU_UPDATE_URL overrides, empty falls back to the default" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try testing.expectEqualStrings(ver.latest_release_url, lookupUrl(&env));
    try env.put("TAU_UPDATE_URL", "");
    try testing.expectEqualStrings(ver.latest_release_url, lookupUrl(&env));
    try env.put("TAU_UPDATE_URL", "file:///tmp/release.json");
    try testing.expectEqualStrings("file:///tmp/release.json", lookupUrl(&env));
}

test "compareVersions: dotted triples order numerically" {
    try testing.expectEqual(std.math.Order.eq, compareVersions("0.4.0", "0.4.0").?);
    try testing.expectEqual(std.math.Order.lt, compareVersions("0.4.0", "0.5.0").?);
    try testing.expectEqual(std.math.Order.gt, compareVersions("0.10.0", "0.9.9").?);
    try testing.expectEqual(std.math.Order.lt, compareVersions("0.4.0", "1.0").?);
}

test "compareVersions: v-prefix, missing components and suffixes" {
    try testing.expectEqual(std.math.Order.eq, compareVersions("0.4.0", "v0.4.0").?);
    try testing.expectEqual(std.math.Order.eq, compareVersions("0.4", "0.4.0").?);
    try testing.expectEqual(std.math.Order.lt, compareVersions("0.4.0", "0.4.1").?);
    try testing.expectEqual(std.math.Order.eq, compareVersions("0.4.0-beta", "0.4.0").?);
    try testing.expectEqual(std.math.Order.eq, compareVersions("V1.2", "1.2.0").?);
}

test "compareVersions: unparseable input returns null" {
    try testing.expect(compareVersions("0.4.0", "latest") == null);
    try testing.expect(compareVersions("", "0.4.0") == null);
    try testing.expect(compareVersions("x.y", "z") == null);
    // A trailing non-numeric component just truncates — still comparable.
    try testing.expectEqual(std.math.Order.eq, compareVersions("1.2.beta", "1.2.0").?);
}

test "parseTag: pulls tag_name, rejects non-object and missing fields" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqualStrings("v9.9.9", parseTag(a, "{\"tag_name\":\"v9.9.9\",\"name\":\"x\"}").?);
    try testing.expect(parseTag(a, "{\"name\":\"x\"}") == null);
    try testing.expect(parseTag(a, "{\"tag_name\":42}") == null);
    try testing.expect(parseTag(a, "{\"tag_name\":\"\"}") == null);
    try testing.expect(parseTag(a, "[1,2]") == null);
    try testing.expect(parseTag(a, "not json") == null);
}

test "releaseUrl: builds the tag page" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const u = try releaseUrl(arena.allocator(), "v0.5.0");
    try testing.expectEqualStrings("https://github.com/javimosch/tau/releases/tag/v0.5.0", u);
}
