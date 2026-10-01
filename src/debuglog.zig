//! Redacted diagnostic log file for bug reports (`--debug`).
//!
//! When `--debug` is set, tau mirrors every `[DEBUG]` line (plus the run's
//! perf summary) to `~/.config/tau/debug/<UTC-timestamp>-<rand>.log`. The file
//! copy is redacted — the resolved API key, every other configured/env key,
//! Bearer tokens, `"api_key"`-style JSON fields, and `*_KEY=`/`*_TOKEN=`-style
//! env assignments are all masked — so the log is safe to attach to a bug
//! report. stderr keeps the raw output for live debugging. Set TAU_DEBUG_LOG
//! to override the destination path.
//!
//! main() opens the log once for the `.run` action; emitters in agent.zig and
//! provider.zig call emit(). path() exposes the active file so error envelopes
//! can link to it. When no log is open (open failed, or a non-run action),
//! emit() still writes to stderr and the file write is a no-op.

const std = @import("std");
const term = @import("term.zig");
const cfgmod = @import("config.zig");

/// Replacement text for masked secrets in the log file.
pub const mask = "***REDACTED***";

/// Per-entry byte cap for the file copy — tool results can be megabytes; a
/// bounded line keeps the log small enough to attach to an issue.
pub const max_line_bytes = 8192;

/// Registered secrets shorter than this are skipped: masking a tiny literal
/// would mangle unrelated substrings all over the log.
const min_secret_len = 6;

var g_io: ?std.Io = null;
var g_file: ?std.Io.File = null;
var g_alloc: ?std.mem.Allocator = null;
var g_path: ?[]const u8 = null;
var g_secrets: std.ArrayList([]const u8) = .empty;

/// Path of the active log, or null when no log is open. Error envelopes use
/// this to link failures to the diagnostic file.
pub fn path() ?[]const u8 {
    return g_path;
}

/// `,"debug_log":"<path>"` for splicing into a `{"err":{...}}` envelope, or
/// null when no log is open (or on OOM — callers degrade to no field). The
/// path is JSON-escaped; the returned slice is allocator-owned.
pub fn envelopeSuffix(a: std.mem.Allocator) ?[]u8 {
    const p = g_path orelse return null;
    const pe = @import("json.zig").escapeAlloc(a, p) catch return null;
    defer a.free(pe);
    return std.fmt.allocPrint(a, ",\"debug_log\":\"{s}\"", .{pe}) catch null;
}

/// <HOME>/.config/tau/debug (sibling of sessions/). null when HOME is unset.
pub fn dirPath(a: std.mem.Allocator, env: *std.process.Environ.Map) ?[]u8 {
    const home = env.get("HOME") orelse return null;
    return std.fmt.allocPrint(a, "{s}/.config/tau/debug", .{home}) catch null;
}

/// `YYYY-MM-DDTHH:MM:SSZ` (file_safe=false) or `YYYY-MM-DDTHH-MM-SSZ`
/// (file_safe=true, no colons in filenames).
fn formatIso(a: std.mem.Allocator, epoch_secs: u64, file_safe: bool) ?[]u8 {
    const es = std.time.epoch.EpochSeconds{ .secs = epoch_secs };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    const tsep: u8 = if (file_safe) '-' else ':';
    return std.fmt.allocPrint(a, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}{c}{d:0>2}{c}{d:0>2}Z", .{
        yd.year,                md.month.numeric(),       md.day_index + 1,
        ds.getHoursIntoDay(),   tsep,                     ds.getMinutesIntoHour(),
        tsep,                   ds.getSecondsIntoMinute(),
    }) catch null;
}

/// `debug-2026-09-29T08-45-12Z-1a2b.log` — UTC stamp + nanosecond-derived
/// suffix so back-to-back runs never collide.
fn fileName(a: std.mem.Allocator, epoch_secs: u64, suffix: u16) ?[]u8 {
    const stamp = formatIso(a, epoch_secs, true) orelse return null;
    return std.fmt.allocPrint(a, "debug-{s}-{x:0>4}.log", .{ stamp, suffix }) catch null;
}

/// Resolve the log destination: TAU_DEBUG_LOG wins (used verbatim), else a
/// timestamped file under dirPath(). null when neither can be built.
pub fn resolvePath(a: std.mem.Allocator, env: *std.process.Environ.Map, epoch_secs: u64, name_suffix: u16) ?[]u8 {
    if (env.get("TAU_DEBUG_LOG")) |p| {
        if (p.len > 0) return a.dupe(u8, p) catch null;
    }
    const dir = dirPath(a, env) orelse return null;
    const name = fileName(a, epoch_secs, name_suffix) orelse return null;
    return std.fmt.allocPrint(a, "{s}/{s}", .{ dir, name }) catch null;
}

/// Open the diagnostic log, register every credential source for masking, and
/// write a provenance header. Returns the log path, or null when the file
/// cannot be created (caller should warn; stderr debug output is unaffected).
/// `a` must outlive the run (main's arena) — the log stays open until exit.
pub fn open(io: std.Io, a: std.mem.Allocator, env: *std.process.Environ.Map, cfg: cfgmod.Config) ?[]const u8 {
    const now = std.Io.Timestamp.now(io, .real);
    const secs: u64 = @intCast(@max(now.toSeconds(), 0));
    const suffix: u16 = @truncate(@as(u96, @bitCast(now.nanoseconds)));
    const p = resolvePath(a, env, secs, suffix) orelse return null;

    if (std.fs.path.dirname(p)) |d| std.Io.Dir.cwd().createDirPath(io, d) catch {};
    // Owner-only: the log is redacted but still carries tool I/O and endpoint
    // details. Permissions are POSIX-only; elsewhere .default_file applies.
    const opts: std.Io.Dir.CreateFileOptions = if (@hasDecl(std.Io.File.Permissions, "fromMode"))
        .{ .permissions = .fromMode(0o600) }
    else
        .{};
    const f = std.Io.Dir.cwd().createFile(io, p, opts) catch return null;

    g_io = io;
    g_file = f;
    g_alloc = a;
    g_path = p;
    registerSecrets(a, env, cfg);
    writeHeader(a, cfg, p, secs, cfgmod.resolveApiKey(cfg, env) != null);
    return p;
}

/// Write `line` verbatim to stderr, then a redacted copy to the log file
/// (no-op for the file when no log is open).
pub fn emit(line: []const u8) void {
    term.err(line);
    writeRedacted(line);
}

/// Emit the run's perf summary as a `[DEBUG] perf:` line (stderr + log).
/// Help advertises "perf stats"; this is what makes that true.
pub fn emitPerf(io: std.Io, start: std.Io.Timestamp, tokens_out: u64, exit_code: u8) void {
    const elapsed_ms = start.durationTo(std.Io.Timestamp.now(io, .real)).toMilliseconds();
    var buf: [160]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "[DEBUG] perf: tokens_out={d} elapsed_ms={d} exit_code={d}\n", .{
        tokens_out, elapsed_ms, exit_code,
    }) catch return;
    emit(line);
}

/// Register a literal secret to mask in the file copy.
fn registerSecret(a: std.mem.Allocator, s: []const u8) void {
    if (s.len < min_secret_len) return;
    for (g_secrets.items) |existing| {
        if (std.mem.eql(u8, existing, s)) return;
    }
    const owned = a.dupe(u8, s) catch return;
    g_secrets.append(a, owned) catch {};
}

/// Mask every credential the run could leak — not just the winning key. The
/// resolved key plus the flag/config/env losers all get registered so a value
/// echoed into tool output or a response body can't slip through.
fn registerSecrets(a: std.mem.Allocator, env: *std.process.Environ.Map, cfg: cfgmod.Config) void {
    if (cfgmod.resolveApiKey(cfg, env)) |k| registerSecret(a, k);
    if (cfg.api_key) |k| registerSecret(a, k);
    if (cfg.config_api_key) |k| registerSecret(a, k);
    if (cfg.keys) |km| {
        var it = km.valueIterator();
        while (it.next()) |v| registerSecret(a, v.*);
    }
    if (env.get("TAU_API_KEY")) |v| registerSecret(a, v);
    for (cfgmod.providers) |p| {
        for (p.env_keys) |ek| {
            if (env.get(ek)) |v| registerSecret(a, v);
        }
        if (p.builtin_key) |bk| registerSecret(a, bk);
    }
}

/// Provenance header at the top of every log: what version/config produced
/// it. Values pass through writeRedacted like everything else.
fn writeHeader(a: std.mem.Allocator, cfg: cfgmod.Config, p: []const u8, epoch_secs: u64, key_resolved: bool) void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    buf.appendSlice(a, "# tau diagnostic log — credentials are masked; review before attaching to a bug report\n") catch return;
    headerLine(a, &buf, "version", @import("version.zig").version);
    headerLine(a, &buf, "created_utc", formatIso(a, epoch_secs, false) orelse "unknown");
    headerLine(a, &buf, "path", p);
    headerLine(a, &buf, "provider", cfg.provider);
    headerLine(a, &buf, "model", cfg.model);
    headerLine(a, &buf, "endpoint", cfg.endpoint);
    headerLine(a, &buf, "mode", @tagName(cfg.mode));
    headerLine(a, &buf, "stream", if (cfg.stream) "true" else "false");
    headerLine(a, &buf, "session", cfg.session orelse "-");
    headerLine(a, &buf, "key_resolved", if (key_resolved) "yes" else "no");
    buf.appendSlice(a, "# ---\n") catch return;
    writeRedacted(buf.items);
}

fn headerLine(a: std.mem.Allocator, buf: *std.ArrayList(u8), key: []const u8, value: []const u8) void {
    const line = std.fmt.allocPrint(a, "# {s}: {s}\n", .{ key, value }) catch return;
    defer a.free(line);
    buf.appendSlice(a, line) catch {};
}

fn writeRedacted(line: []const u8) void {
    const f = g_file orelse return;
    const io = g_io orelse return;
    const a = g_alloc orelse return;
    const red = redactAlloc(a, line, g_secrets.items) catch return;
    defer a.free(red);
    if (red.len <= max_line_bytes) {
        f.writeStreamingAll(io, red) catch {};
        return;
    }
    f.writeStreamingAll(io, red[0..max_line_bytes]) catch {};
    const tail = std.fmt.allocPrint(a, "\n[debuglog: truncated {d} bytes]\n", .{red.len - max_line_bytes}) catch return;
    defer a.free(tail);
    f.writeStreamingAll(io, tail) catch {};
}

/// Return a redacted copy of `s`: every registered secret literal, plus
/// generic credential patterns (Bearer tokens, `"api_key"`-style JSON fields,
/// `*_KEY=`-style env assignments). Caller owns the result.
pub fn redactAlloc(a: std.mem.Allocator, s: []const u8, secrets: []const []const u8) ![]u8 {
    var cur = try a.dupe(u8, s);
    for (secrets) |sec| {
        if (sec.len < min_secret_len) continue;
        const next = try std.mem.replaceOwned(u8, a, cur, sec, mask);
        a.free(cur);
        cur = next;
    }
    const masked = try maskPatterns(a, cur);
    a.free(cur);
    return masked;
}

// ---------------------------------------------------------------------------
// Generic credential-pattern masking
// ---------------------------------------------------------------------------

/// JSON field names whose string values are always masked (case-insensitive).
const secret_json_fields = [_][]const u8{
    "api_key",        "apikey",    "api-key",     "authorization",
    "x-api-key",      "access_token", "refresh_token", "id_token",
    "client_secret",  "token",     "secret",      "password",
};

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.';
}

/// Chars that terminate a credential value in log text (whitespace plus the
/// JSON/shell delimiters that commonly follow a token).
fn isValueEnd(c: u8) bool {
    return std.ascii.isWhitespace(c) or c == '"' or c == '\'' or c == ',' or
        c == '}' or c == ']' or c == ';' or c == '&' or c == ')';
}

fn eqlIC(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}

fn startsWithIC(s: []const u8, prefix: []const u8) bool {
    return s.len >= prefix.len and eqlIC(s[0..prefix.len], prefix);
}

/// True when a NAME (in `NAME=value`) looks like it carries a credential:
/// exact match on a generic name, or a *_KEY/*_TOKEN/*_SECRET/*_PASSWORD/
/// *_APIKEY suffix (covers OPENAI_API_KEY, GITHUB_TOKEN, etc.).
fn looksSecretName(name: []const u8) bool {
    const generics = [_][]const u8{
        "key", "api_key", "apikey", "token", "secret", "password",
        "auth", "authorization", "access_token", "client_secret", "credential",
    };
    for (generics) |g| {
        if (eqlIC(name, g)) return true;
    }
    const suffixes = [_][]const u8{ "_key", "_token", "_secret", "_password", "_apikey", "_credential" };
    for (suffixes) |suf| {
        if (name.len > suf.len and eqlIC(name[name.len - suf.len ..], suf)) return true;
    }
    return false;
}

/// True when the quoted string starting at s[0]=='"' names a credential field
/// (e.g. `"x-api-key"`). Returns the index just past the closing quote.
fn secretFieldLen(s: []const u8) ?usize {
    if (s.len < 3 or s[0] != '"') return null;
    var end: usize = 1;
    while (end < s.len and s[end] != '"') : (end += 1) {}
    if (end >= s.len or end - 1 > 40) return null;
    const name = s[1..end];
    for (secret_json_fields) |f| {
        if (eqlIC(name, f)) return end + 1;
    }
    return null;
}

fn maskPatterns(a: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);

    var i: usize = 0;
    while (i < s.len) {
        // 1) Bearer <token> — the shape curl headers take when echoed back.
        if (startsWithIC(s[i..], "bearer") and (i == 0 or !isWordChar(s[i - 1]))) {
            var j = i + 6;
            while (j < s.len and (s[j] == ' ' or s[j] == '\t')) j += 1;
            const tstart = j;
            while (j < s.len and !isValueEnd(s[j])) j += 1;
            if (j > tstart) {
                try out.appendSlice(a, s[i .. i + 6]);
                try out.append(a, ' ');
                try out.appendSlice(a, mask);
                i = j;
                continue;
            }
        }

        // 2) "<secret-field>" : "<value>" — masks the string value.
        if (s[i] == '"') {
            if (secretFieldLen(s[i..])) |flen| {
                var j = i + flen;
                while (j < s.len and (s[j] == ' ' or s[j] == '\t')) j += 1;
                if (j < s.len and s[j] == ':') {
                    j += 1;
                    while (j < s.len and (s[j] == ' ' or s[j] == '\t')) j += 1;
                    if (j < s.len and s[j] == '"') {
                        j += 1;
                        var k = j;
                        while (k < s.len and s[k] != '"') {
                            k += if (s[k] == '\\') 2 else 1;
                        }
                        try out.appendSlice(a, s[i..j]); // "field":"
                        try out.appendSlice(a, mask);
                        i = k; // resumes on the closing quote
                        continue;
                    }
                }
            }
        }

        // 3) NAME=value env-style assignments with credential-looking names.
        if (isWordChar(s[i]) and (i == 0 or !isWordChar(s[i - 1]))) {
            var j = i;
            while (j < s.len and isWordChar(s[j])) j += 1;
            const name = s[i..j];
            if (j < s.len and s[j] == '=' and looksSecretName(name)) {
                var v = j + 1;
                while (v < s.len and !isValueEnd(s[v])) v += 1;
                if (v > j + 1) {
                    try out.appendSlice(a, s[i .. j + 1]); // NAME=
                    try out.appendSlice(a, mask);
                    i = v;
                    continue;
                }
            }
        }

        try out.append(a, s[i]);
        i += 1;
    }
    return out.toOwnedSlice(a);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn redactOne(s: []const u8, secrets: []const []const u8) ![]u8 {
    return redactAlloc(testing.allocator, s, secrets);
}

test "redactAlloc masks registered secret literals" {
    const secrets = [_][]const u8{"sk-live-abc123"};
    const out = try redactOne("response echoed sk-live-abc123 back", &secrets);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("response echoed " ++ mask ++ " back", out);
}

test "redactAlloc masks every occurrence of the secret" {
    const secrets = [_][]const u8{"key-999999"};
    const out = try redactOne("key-999999 and again key-999999", &secrets);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(mask ++ " and again " ++ mask, out);
}

test "redactAlloc skips secrets shorter than min_secret_len" {
    const secrets = [_][]const u8{"abc"};
    const out = try redactOne("abc stays — too short to mask safely", &secrets);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("abc stays — too short to mask safely", out);
}

test "redactAlloc masks Bearer tokens without registration" {
    const out = try redactOne("[DEBUG] header: Authorization: Bearer tok_2Zx9Qw8 rest", &.{});
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("[DEBUG] header: Authorization: Bearer " ++ mask ++ " rest", out);
}

test "redactAlloc masks api_key-style JSON string fields" {
    const out = try redactOne(
        \\{"config":{"api_key":"sup3rs3cret","model":"mimo"}}
    , &.{});
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        \\{"config":{"api_key":"***REDACTED***","model":"mimo"}}
    , out);
}

test "redactAlloc masks whitespace-tolerant and case-insensitive JSON fields" {
    const out = try redactOne("{ \"X-API-Key\" :  \"s3cr3t-v4lue\" }", &.{});
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("{ \"X-API-Key\" :  \"" ++ mask ++ "\" }", out);
}

test "redactAlloc masks env-style NAME=value for credential names" {
    const out = try redactOne("ran OPENAI_API_KEY=sk-abc123 ./deploy.sh", &.{});
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("ran OPENAI_API_KEY=" ++ mask ++ " ./deploy.sh", out);
}

test "redactAlloc masks generic credential names" {
    const out = try redactOne("password=hunter2 token=tok-value", &.{});
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("password=" ++ mask ++ " token=" ++ mask, out);
}

test "redactAlloc leaves non-credential assignments alone" {
    const out = try redactOne("HOME=/root count=42 LANG=en_US.UTF-8", &.{});
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("HOME=/root count=42 LANG=en_US.UTF-8", out);
}

test "redactAlloc does not overmatch inside larger words" {
    // 'unbearerable' contains 'bearer'; 'monkey=' ends with 'key' but not '_KEY'.
    const out = try redactOne("unbearerable monkey=banana keyring=1", &.{});
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("unbearerable monkey=banana keyring=1", out);
}

test "redactAlloc masks combined leak shapes in one line" {
    const secrets = [_][]const u8{"resolved-key-777"};
    const out = try redactOne(
        "[DEBUG] Raw API response: {\"echo\":\"Bearer resolved-key-777\",\"client_secret\":\"shh-999\",\"note\":\"ok\"}",
        &secrets,
    );
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        "[DEBUG] Raw API response: {\"echo\":\"Bearer " ++ mask ++ "\",\"client_secret\":\"" ++ mask ++ "\",\"note\":\"ok\"}",
        out,
    );
}

test "dirPath builds <HOME>/.config/tau/debug and is null without HOME" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(a);
    try env.put("HOME", "/home/tester");
    try testing.expectEqualStrings("/home/tester/.config/tau/debug", dirPath(a, &env).?);
    var env2 = std.process.Environ.Map.init(a);
    try testing.expect(dirPath(a, &env2) == null);
}

test "resolvePath honors TAU_DEBUG_LOG verbatim" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(a);
    try env.put("HOME", "/home/tester");
    try env.put("TAU_DEBUG_LOG", "/tmp/custom/tau.log");
    try testing.expectEqualStrings("/tmp/custom/tau.log", resolvePath(a, &env, 1_700_000_000, 0).?);
}

test "resolvePath default is timestamped under the debug dir" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(a);
    try env.put("HOME", "/home/tester");
    const p = resolvePath(a, &env, 1_790_726_400, 0).?; // 2026-09-30T00:00:00Z
    try testing.expect(std.mem.startsWith(u8, p, "/home/tester/.config/tau/debug/debug-2026-"));
    try testing.expect(std.mem.endsWith(u8, p, ".log"));
}

test "fileName produces a filesystem-safe UTC stamp" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const name = fileName(a, 1_790_726_400, 0x00ab).?; // 2026-09-30T00:00:00Z
    try testing.expect(std.mem.startsWith(u8, name, "debug-2026-09-30T00-00-00Z-"));
    try testing.expect(std.mem.endsWith(u8, name, ".log"));
    try testing.expect(std.mem.indexOfScalar(u8, name, ':') == null);
}
