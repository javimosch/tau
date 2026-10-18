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

/// Append `s` to `out` when it is long enough to mask safely and not already
/// listed. Items are duped into `a`.
fn appendSecret(a: std.mem.Allocator, out: *std.ArrayList([]const u8), s: []const u8) void {
    if (s.len < min_secret_len) return;
    for (out.items) |existing| {
        if (std.mem.eql(u8, existing, s)) return;
    }
    const owned = a.dupe(u8, s) catch return;
    out.append(a, owned) catch {};
}

/// Collect every credential the run could leak — not just the winning key.
/// The resolved key plus the flag/config/env losers are all listed so a value
/// echoed into tool output, a response body, or the `tau doctor --report`
/// config dump can't slip through. The endpoint's URL-userinfo password is
/// listed too: check messages and headers print cfg.endpoint verbatim, so
/// `https://user:pass@host` must not leak `pass`. Every secret's JSON-escaped
/// spelling is also registered — a key echoed inside a JSON string arrives
/// escaped (`sk\"abc`) and would slip past literal masking otherwise. The
/// list is `a`-allocated and duped/deduped; callers may keep it for
/// redactAlloc or register it globally.
pub fn collectSecrets(a: std.mem.Allocator, env: *std.process.Environ.Map, cfg: cfgmod.Config) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    if (cfgmod.resolveApiKey(cfg, env)) |k| appendSecret(a, &out, k);
    if (cfg.api_key) |k| appendSecret(a, &out, k);
    if (cfg.config_api_key) |k| appendSecret(a, &out, k);
    if (cfg.keys) |km| {
        var it = km.valueIterator();
        while (it.next()) |v| appendSecret(a, &out, v.*);
    }
    if (env.get("TAU_API_KEY")) |v| appendSecret(a, &out, v);
    for (cfgmod.providers) |p| {
        for (p.env_keys) |ek| {
            if (env.get(ek)) |v| appendSecret(a, &out, v);
        }
        if (p.builtin_key) |bk| appendSecret(a, &out, bk);
    }
    if (endpointPassword(cfg.endpoint)) |pw| appendSecret(a, &out, pw);
    // Escaped spellings: re-index each iteration since appendSecret may
    // reallocate out.items. Raw_count bounds the loop to the originals.
    const raw_count = out.items.len;
    var i: usize = 0;
    while (i < raw_count) : (i += 1) {
        const esc = @import("json.zig").escapeAlloc(a, out.items[i]) catch continue;
        appendSecret(a, &out, esc);
    }
    return out.items;
}

/// Password component of a URL userinfo (`scheme://user:pass@host`), or null
/// when the endpoint carries none. Only the password is registered — masking
/// it leaves `scheme://user:***REDACTED***@host`, which keeps the endpoint
/// identifiable in diagnostics.
fn endpointPassword(endpoint: []const u8) ?[]const u8 {
    const scheme = std.mem.indexOf(u8, endpoint, "://") orelse return null;
    const rest = endpoint[scheme + 3 ..];
    const authority = rest[0 .. std.mem.indexOfScalar(u8, rest, '/') orelse rest.len];
    const at = std.mem.lastIndexOfScalar(u8, authority, '@') orelse return null;
    const colon = std.mem.indexOfScalar(u8, authority[0..at], ':') orelse return null;
    const pw = authority[colon + 1 .. at];
    return if (pw.len == 0) null else pw;
}

/// Register the collected secrets so process-wide masking (the --debug log
/// file copy, error envelopes, and doctor serialization) masks them. Deduped
/// per value — safe to call more than once.
pub fn registerSecrets(a: std.mem.Allocator, env: *std.process.Environ.Map, cfg: cfgmod.Config) void {
    g_secrets.appendSlice(a, collectSecrets(a, env, cfg)) catch {};
}

/// The process-wide mask list — for callers merging it with their own
/// collected secrets (e.g. `tau doctor --report`).
pub fn registeredSecrets() []const []const u8 {
    return g_secrets.items;
}

/// Redact `s` with every secret registered for this process — empty before
/// registerSecrets/open runs, in which case only the generic Bearer,
/// `"api_key":`, and `NAME=` credential patterns are masked. Error envelopes
/// and doctor output route through this so a credential interpolated into a
/// message can't leak. Caller owns the result.
pub fn redactRegistered(a: std.mem.Allocator, s: []const u8) ![]u8 {
    return redactAlloc(a, s, g_secrets.items);
}

/// Test-only hooks for sibling modules pinning the process-wide masking
/// invariant. Items are page-allocated (the tracking allocator would report
/// the intentionally-unfreed globals as leaks); clear in a defer so no
/// ordering dependency leaks between tests.
pub fn addSecretsForTest(secrets: []const []const u8) void {
    for (secrets) |s| appendSecret(std.heap.page_allocator, &g_secrets, s);
}

pub fn clearSecretsForTest() void {
    // Drop the whole list: capacity allocated by a caller's arena must not be
    // reused after that arena is gone.
    g_secrets = .empty;
}

/// Provenance header at the top of every log: what version/config produced
/// it. Values pass through writeRedacted like everything else.
fn writeHeader(a: std.mem.Allocator, cfg: cfgmod.Config, p: []const u8, epoch_secs: u64, key_resolved: bool) void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    buf.appendSlice(a, "# tau diagnostic log — credentials are masked; review before attaching to a bug report\n") catch return;
    const version_mod = @import("version.zig");
    headerLine(a, &buf, "version", version_mod.version);
    // Build metadata (commit/target/date/zig) — lets a bug report pin down
    // exactly which binary produced the log.
    headerLine(a, &buf, "build", version_mod.buildLine(a) catch "unknown");
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

// ---------------------------------------------------------------------------
// Property/invariant tests — deterministic PRNG sweeps over the masking
// contract. The invariant under test: bytes that name a credential never
// survive redactAlloc, in any of the shapes a real log/diagnostic can take.
// ---------------------------------------------------------------------------

const prop_alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._";
const prop_json_fields = [_][]const u8{ "api_key", "token", "secret", "password", "x-api-key", "authorization", "access_token" };
const prop_env_names = [_][]const u8{ "OPENAI_API_KEY", "GITHUB_TOKEN", "APP_SECRET", "DB_PASSWORD", "key", "auth", "credential" };
const prop_filler = [_][]const u8{
    "[DEBUG] tool args: {\"path\":\"/tmp/x\"}",
    " response ok status=200 ",
    "{\"content\":\"hello\"}",
    "run tau doctor --report ",
    "mode=json stream=true ",
};

fn propSecret(r: std.Random, a: std.mem.Allocator, with_escape_chars: bool) ![]u8 {
    const s = try a.alloc(u8, r.intRangeAtMost(usize, 6, 40));
    for (s) |*ch| {
        if (with_escape_chars and r.uintLessThan(usize, 25) == 0) {
            ch.* = "\"\\\n\t"[r.uintLessThan(usize, 4)];
        } else {
            ch.* = prop_alphabet[r.uintLessThan(usize, prop_alphabet.len)];
        }
    }
    return s;
}

/// True when `s` nests inside another registered secret (or the mask text):
/// masking the inner literal first would leave a surviving tail of the outer
/// one, which is a different (untested) property — keep secrets disjoint.
fn propOverlaps(s: []const u8, existing: []const []const u8) bool {
    if (std.mem.indexOf(u8, mask, s) != null) return true;
    for (existing) |x| {
        if (std.mem.indexOf(u8, x, s) != null or std.mem.indexOf(u8, s, x) != null) return true;
    }
    return false;
}

test "property: generated secrets never survive redactAlloc" {
    var prng = std.Random.DefaultPrng.init(0x232_d1ce);
    const r = prng.random();
    var iter: usize = 0;
    while (iter < 400) : (iter += 1) {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const n = r.intRangeAtMost(usize, 1, 3);
        var secrets: std.ArrayList([]const u8) = .empty;
        var guard: usize = 0;
        while (secrets.items.len < n and guard < 40) : (guard += 1) {
            const s = try propSecret(r, a, iter % 3 == 0);
            if (!propOverlaps(s, secrets.items)) try secrets.append(a, s);
        }
        // Mirror collectSecrets: the JSON-escaped spelling is registered too.
        const raw_n = secrets.items.len;
        var si: usize = 0;
        while (si < raw_n) : (si += 1) {
            const esc = @import("json.zig").escapeAlloc(a, secrets.items[si]) catch continue;
            var dup = false;
            for (secrets.items) |x| {
                if (std.mem.eql(u8, x, esc)) {
                    dup = true;
                    break;
                }
            }
            if (!dup) try secrets.append(a, esc);
        }

        // Compose a document of random fragments: filler text or a secret
        // planted in one of the real leak shapes (bare token, Bearer header,
        // JSON credential field, NAME= env assignment, nested/escaped echo).
        var doc: std.ArrayList(u8) = .empty;
        var planted = false;
        const frags = r.intRangeAtMost(usize, 1, 8);
        var fi: usize = 0;
        while (fi < frags) : (fi += 1) {
            if (r.uintLessThan(usize, 10) < 4) {
                try doc.appendSlice(a, prop_filler[r.uintLessThan(usize, prop_filler.len)]);
                continue;
            }
            const s = secrets.items[r.uintLessThan(usize, raw_n)];
            const esc = @import("json.zig").escapeAlloc(a, s) catch s;
            planted = true;
            switch (r.uintLessThan(usize, 7)) {
                0 => try doc.appendSlice(a, try std.fmt.allocPrint(a, " {s} ", .{s})),
                1 => try doc.appendSlice(a, try std.fmt.allocPrint(a, " Authorization: Bearer {s} ", .{s})),
                2 => try doc.appendSlice(a, try std.fmt.allocPrint(a, "bearer\t{s}", .{s})),
                3 => try doc.appendSlice(a, try std.fmt.allocPrint(a, "\"{s}\":\"{s}\"", .{ prop_json_fields[r.uintLessThan(usize, prop_json_fields.len)], esc })),
                4 => try doc.appendSlice(a, try std.fmt.allocPrint(a, "{s}={s} ", .{ prop_env_names[r.uintLessThan(usize, prop_env_names.len)], s })),
                5 => try doc.appendSlice(a, try std.fmt.allocPrint(a, "{{\"echo\":\"{s}\",\"nested\":{{\"token\":\"{s}\"}}}}", .{ s, esc })),
                else => try doc.appendSlice(a, try std.fmt.allocPrint(a, "Bearer {s} {s}", .{ s, s })),
            }
        }

        const out = try redactAlloc(a, doc.items, secrets.items);
        for (secrets.items) |s| {
            if (std.mem.indexOf(u8, out, s) != null) {
                std.debug.print("secret survived redaction: '{s}' in '{s}'\n", .{ s, out });
                return error.TestUnexpectedResult;
            }
        }
        if (planted) try testing.expect(std.mem.indexOf(u8, out, mask) != null);
        // Redaction is idempotent — re-masking a redacted doc changes nothing.
        const twice = try redactAlloc(a, out, secrets.items);
        try testing.expectEqualStrings(out, twice);
    }
}

fn hasSecret(list: []const []const u8, s: []const u8) bool {
    for (list) |x| {
        if (std.mem.eql(u8, x, s)) return true;
    }
    return false;
}

test "collectSecrets: covers every source, endpoint password, escaped spellings, dedup" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(a);
    try env.put("TAU_API_KEY", "sk-tau-9999");
    try env.put("OPENAI_API_KEY", "sk-env-8888");
    var km = std.StringHashMap([]const u8).init(a);
    try km.put("openai", "sk-keys-7777");
    try km.put("other", "sk-quote\"66");
    const cfg = cfgmod.Config{
        .provider = "openai",
        .api_key = "sk-flag-1111",
        .config_api_key = "sk-cfg-2222",
        .keys = km,
        .endpoint = "https://svc:pw-leak-999@api.example.com/v1",
    };
    const secrets = collectSecrets(a, &env, cfg);
    const want = [_][]const u8{
        "sk-flag-1111", "sk-cfg-2222", "sk-keys-7777", "sk-quote\"66",
        "sk-tau-9999",  "sk-env-8888", "pw-leak-999",
    };
    for (want) |w| {
        if (!hasSecret(secrets, w)) {
            std.debug.print("collectSecrets missed '{s}'\n", .{w});
            return error.TestUnexpectedResult;
        }
    }
    // The JSON-escaped spelling of a quote-bearing key is registered too.
    const esc = try @import("json.zig").escapeAlloc(a, "sk-quote\"66");
    try testing.expect(hasSecret(secrets, esc));
    // Dedup: the flag key resolved once even though it names two sources.
    var count: usize = 0;
    for (secrets) |x| {
        if (std.mem.eql(u8, x, "sk-flag-1111")) count += 1;
    }
    try testing.expectEqual(@as(usize, 1), count);
}

test "endpointPassword: extracts the userinfo password, null when absent" {
    try testing.expectEqualStrings("p%40ss", endpointPassword("https://u:p%40ss@h/v1").?);
    try testing.expectEqualStrings("pw-9", endpointPassword("http://u:pw-9@h:8080/x?y=1").?);
    try testing.expect(endpointPassword("https://h/v1") == null);
    try testing.expect(endpointPassword("https://u@h/v1") == null);
    try testing.expect(endpointPassword("https://u:@h/v1") == null);
    try testing.expect(endpointPassword("not-a-url") == null);
}
