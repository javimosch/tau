// `tau doctor` — offline-first setup diagnostics. Validates the whole setup
// chain (config file parse + permissions, provider resolution, API key
// provenance, shell completions, curl, endpoint reachability, optional
// authenticated probe) and prints a JSON report on stdout. Exit 0 when every
// non-skipped check is ok/warn; exit 1 when any check fails. Key material is
// never printed — only its source.
//
// `--fix` remediates fixable outcomes: scaffold a missing config (init),
// restore an unparseable one (moved to config.json.bak first), tighten POSIX
// permission bits (0700 dir / 0600 file), install shell completions. Fixes
// apply per-confirmation: --yes approves all, a TTY stdin gets a y/N prompt,
// non-interactive runs report them as skipped. The emitted report reflects
// the post-fix state when anything was applied.

const std = @import("std");
const builtin = @import("builtin");
const term = @import("term.zig");
const json = @import("json.zig");
const cfgmod = @import("config.zig");
const configfile = @import("configfile.zig");
const initmod = @import("init.zig");
const setup = @import("setup.zig");
const version = @import("version.zig").version;
const Config = cfgmod.Config;

pub const CheckStatus = enum { ok, warn, fail, skip };

/// Remediations `tau doctor --fix` can apply. Attached to a check outcome
/// when it is auto-fixable; `planFixes` collects them in check order and
/// dedupes — several check outcomes can share one remediation.
pub const FixKind = enum {
    /// Write the `tau init` starter config (creates ~/.config/tau).
    scaffold_config,
    /// Move an unparseable config to config.json.bak, then scaffold.
    restore_config,
    /// chmod 0700 on ~/.config/tau and 0600 on config.json.
    chmod_config,
    /// Install/refresh shell completion scripts (+ rc hooks where needed).
    install_completions,
};

pub const Check = struct {
    name: []const u8,
    status: CheckStatus,
    message: []const u8,
    hint: ?[]const u8 = null,
    /// Internal signal for --fix planning; never serialized into the report.
    fix: ?FixKind = null,
};

const Summary = struct { ok: u32 = 0, warn: u32 = 0, fail: u32 = 0, skip: u32 = 0 };

// Reachability probes get a short curl --max-time (do NOT reuse the 120s
// timeout_ms default); the process timeout is a slightly larger backstop.
const probe_max_time_s = 5;
const auth_probe_max_time_s = 15;

fn summarize(checks: []const Check) Summary {
    var s: Summary = .{};
    for (checks) |c| {
        switch (c.status) {
            .ok => s.ok += 1,
            .warn => s.warn += 1,
            .fail => s.fail += 1,
            .skip => s.skip += 1,
        }
    }
    return s;
}

/// Serialize one check as a JSON object (all strings escaped).
fn formatCheckJson(arena: std.mem.Allocator, c: Check) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(arena, "{\"name\":\"");
    try json.escapeInto(arena, &buf, c.name);
    try buf.appendSlice(arena, "\",\"status\":\"");
    try buf.appendSlice(arena, @tagName(c.status));
    try buf.appendSlice(arena, "\",\"message\":\"");
    try json.escapeInto(arena, &buf, c.message);
    try buf.append(arena, '"');
    if (c.hint) |h| {
        try buf.appendSlice(arena, ",\"hint\":\"");
        try json.escapeInto(arena, &buf, h);
        try buf.append(arena, '"');
    }
    try buf.append(arena, '}');
    return buf.toOwnedSlice(arena);
}

fn formatReportJson(arena: std.mem.Allocator, checks: []const Check, fixes: ?[]const FixOutcome) ![]u8 {
    const s = summarize(checks);
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(arena, if (s.fail == 0) "{\"ok\":true" else "{\"ok\":false");
    try buf.appendSlice(arena, ",\"version\":\"");
    try buf.appendSlice(arena, version);
    try buf.appendSlice(arena, "\",\"checks\":[");
    for (checks, 0..) |c, i| {
        if (i != 0) try buf.append(arena, ',');
        try buf.appendSlice(arena, try formatCheckJson(arena, c));
    }
    try buf.append(arena, ']');
    if (fixes) |fx| {
        try buf.appendSlice(arena, ",\"fixes\":[");
        for (fx, 0..) |f, i| {
            if (i != 0) try buf.append(arena, ',');
            try buf.appendSlice(arena, "{\"id\":\"");
            try json.escapeInto(arena, &buf, f.id);
            try buf.appendSlice(arena, "\",\"check\":\"");
            try json.escapeInto(arena, &buf, f.check);
            try buf.appendSlice(arena, "\",\"status\":\"");
            try buf.appendSlice(arena, @tagName(f.status));
            try buf.appendSlice(arena, "\",\"detail\":\"");
            try json.escapeInto(arena, &buf, f.detail);
            try buf.appendSlice(arena, "\"}");
        }
        try buf.append(arena, ']');
    }
    try buf.appendSlice(arena, ",\"summary\":{");
    try buf.appendSlice(arena, try std.fmt.allocPrint(arena, "\"ok\":{d},\"warn\":{d},\"fail\":{d},\"skip\":{d}", .{ s.ok, s.warn, s.fail, s.skip }));
    try buf.appendSlice(arena, "}}\n");
    return buf.toOwnedSlice(arena);
}

fn providerListHint(arena: std.mem.Allocator) []const u8 {
    var buf: std.ArrayList(u8) = .empty;
    for (cfgmod.providers, 0..) |p, i| {
        if (i != 0) buf.appendSlice(arena, ", ") catch return "run 'tau models'";
        buf.appendSlice(arena, p.name) catch return "run 'tau models'";
    }
    return std.fmt.allocPrint(arena, "valid providers: {s} (run 'tau models' for details)", .{buf.items}) catch "run 'tau models'";
}

/// Build a recovery hint for a missing API key: names the env var(s) to set.
/// Mirrors authHint in main.zig (kept local so doctor is self-contained).
fn keyHint(arena: std.mem.Allocator, provider: []const u8) []const u8 {
    const p = cfgmod.findProvider(provider) orelse return "use --api-key <key>";
    if (p.env_keys.len == 0) return "use --api-key <key>";
    var buf: std.ArrayList(u8) = .empty;
    for (p.env_keys, 0..) |ek, i| {
        if (i != 0) buf.appendSlice(arena, " or ") catch return "use --api-key <key>";
        buf.appendSlice(arena, ek) catch return "use --api-key <key>";
    }
    return std.fmt.allocPrint(arena, "set {s} env var, or use --api-key <key>", .{buf.items}) catch "use --api-key <key>";
}

/// Human-readable label for the resolved key's source (never the key itself).
fn keySourceLabel(arena: std.mem.Allocator, cfg: Config, rk: cfgmod.ResolvedKey) []const u8 {
    return switch (rk.source) {
        .flag => "--api-key",
        .config_keys => std.fmt.allocPrint(arena, "keys[{s}]", .{cfg.provider}) catch "keys[?]",
        .env_provider, .env_tau => std.fmt.allocPrint(arena, "env:{s}", .{rk.env_name orelse "?"}) catch "env:?",
        .config_global => "config.api_key",
        .builtin => "builtin",
    };
}

/// Classify config-file bytes: invalid JSON -> fail, unknown provider key ->
/// warn, otherwise ok. Pure (unit-testable); file I/O stays in checkConfigFile.
/// The file is JSONC — comments are stripped first, same as configfile.load,
/// so a `tau init` scaffold (which is commented) parses cleanly.
fn configBodyCheck(arena: std.mem.Allocator, path: []const u8, bytes: []const u8) Check {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, configfile.stripComments(arena, bytes) catch bytes, .{
        .ignore_unknown_fields = true,
    }) catch {
        return .{
            .name = "config_file",
            .status = .fail,
            .message = std.fmt.allocPrint(arena, "config file has invalid JSON and was ignored: {s}", .{path}) catch "config file has invalid JSON",
            .hint = "fix the JSON syntax, delete the file, or run 'tau doctor --fix' to move it aside and scaffold a fresh one",
            .fix = .restore_config,
        };
    };
    if (parsed == .object) {
        if (parsed.object.get("provider")) |pv| {
            if (pv == .string and cfgmod.findProvider(pv.string) == null) {
                return .{
                    .name = "config_file",
                    .status = .warn,
                    .message = std.fmt.allocPrint(arena, "config file provider '{s}' is not a known provider", .{pv.string}) catch "unknown provider in config file",
                    .hint = providerListHint(arena),
                };
            }
        }
    }
    return .{
        .name = "config_file",
        .status = .ok,
        .message = std.fmt.allocPrint(arena, "config file parsed: {s}", .{path}) catch "config file parsed",
    };
}

/// Check 1: config file exists / parses / names a known provider. A missing
/// file is fine — config is optional and defaults apply.
fn checkConfigFile(io: std.Io, arena: std.mem.Allocator, env: *std.process.Environ.Map) Check {
    const p = configfile.path(arena, env) orelse
        return .{ .name = "config_file", .status = .ok, .message = "no config file — using defaults" };
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, p, arena, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return .{
            .name = "config_file",
            .status = .ok,
            .message = std.fmt.allocPrint(arena, "no config file at {s} — using defaults", .{p}) catch "no config file — using defaults",
            .fix = .scaffold_config,
        },
        else => return .{
            .name = "config_file",
            .status = .fail,
            .message = std.fmt.allocPrint(arena, "cannot read config file: {s}", .{p}) catch "cannot read config file",
            .hint = "check file permissions — 'tau doctor --fix' restricts them to 0600",
            .fix = .chmod_config,
        },
    };
    return configBodyCheck(arena, p, bytes);
}

/// Check 2 (POSIX only): ~/.config/tau dir and config.json permission bits.
/// The file can hold API keys, so group/other access warns (auto-fixable to
/// 0700/0600). Skips on Windows, when HOME is unset, or when no config file
/// exists (the scaffold fix handles that case).
fn checkConfigPermissions(io: std.Io, arena: std.mem.Allocator, env: *std.process.Environ.Map) Check {
    if (comptime builtin.os.tag == .windows) {
        return .{ .name = "config_permissions", .status = .skip, .message = "skipped (POSIX permission bits do not apply on Windows)" };
    }
    const p = configfile.path(arena, env) orelse
        return .{ .name = "config_permissions", .status = .skip, .message = "skipped (HOME is not set)" };
    const fstat = std.Io.Dir.cwd().statFile(io, p, .{}) catch |err| switch (err) {
        error.FileNotFound => return .{ .name = "config_permissions", .status = .skip, .message = "skipped (no config file)" },
        else => return .{
            .name = "config_permissions",
            .status = .warn,
            .message = std.fmt.allocPrint(arena, "cannot stat config file: {s}", .{p}) catch "cannot stat config file",
            .hint = "check directory permissions — 'tau doctor --fix' restricts them to 0700",
            .fix = .chmod_config,
        },
    };

    const file_mode = fstat.permissions.toMode() & 0o777;
    var dir_mode: std.posix.mode_t = 0;
    var have_dir = false;
    if (std.mem.lastIndexOfScalar(u8, p, '/')) |idx| {
        if (std.Io.Dir.cwd().statFile(io, p[0..idx], .{})) |ds| {
            dir_mode = ds.permissions.toMode() & 0o777;
            have_dir = true;
        } else |_| {}
    }

    const file_loose = (file_mode & 0o077) != 0;
    const dir_loose = have_dir and (dir_mode & 0o077) != 0;
    if (!file_loose and !dir_loose) {
        return .{
            .name = "config_permissions",
            .status = .ok,
            .message = std.fmt.allocPrint(arena, "config permissions are restrictive (dir {o:0>3}, file {o:0>3})", .{ dir_mode, file_mode }) catch "config permissions are restrictive",
        };
    }
    var msg: std.ArrayList(u8) = .empty;
    if (file_loose)
        tryFmt(&msg, arena, "config file mode {o:0>3} grants group/other access", .{file_mode});
    if (dir_loose) {
        if (msg.items.len > 0) msg.appendSlice(arena, "; ") catch {};
        tryFmt(&msg, arena, "config dir mode {o:0>3} grants group/other access", .{dir_mode});
    }
    return .{
        .name = "config_permissions",
        .status = .warn,
        .message = msg.toOwnedSlice(arena) catch "config permissions grant group/other access",
        .hint = "run 'tau doctor --fix' to restrict to 0600/0700 — the config file can hold API keys",
        .fix = .chmod_config,
    };
}

fn tryFmt(msg: *std.ArrayList(u8), arena: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.allocPrint(arena, fmt, args) catch return;
    msg.appendSlice(arena, s) catch {};
}

/// Check: the detected (or --shell-selected) shells' completion scripts are
/// installed and current. Warns (auto-fixable) when missing/outdated or the
/// rc hook is absent; skips when HOME is unset or no shell resolves.
fn checkCompletions(io: std.Io, arena: std.mem.Allocator, cfg: Config, env: *std.process.Environ.Map) Check {
    const home = env.get("HOME") orelse
        return .{ .name = "shell_completions", .status = .skip, .message = "skipped (HOME is not set)" };
    const shells = setup.resolveShells(arena, cfg, env) catch
        return .{ .name = "shell_completions", .status = .warn, .message = "could not resolve shells" };
    if (shells.len == 0) return .{
        .name = "shell_completions",
        .status = .skip,
        .message = "skipped (could not detect shell from $SHELL)",
        .hint = "pass --shell bash|zsh|fish|pwsh|all",
    };

    var names: std.ArrayList(u8) = .empty;
    var bad: std.ArrayList(u8) = .empty;
    for (shells, 0..) |k, i| {
        const name = setup.shellName(k);
        if (i != 0) names.appendSlice(arena, ",") catch {};
        names.appendSlice(arena, name) catch {};
        const st = setup.completionState(io, arena, home, k) catch setup.CompletionState.missing;
        if (st != .installed) {
            if (bad.items.len > 0) bad.appendSlice(arena, ",") catch {};
            tryFmt(&bad, arena, "{s}:{s}", .{ name, @tagName(st) });
        }
    }
    if (bad.items.len == 0) {
        return .{
            .name = "shell_completions",
            .status = .ok,
            .message = std.fmt.allocPrint(arena, "completions installed for {s}", .{names.items}) catch "completions installed",
        };
    }
    return .{
        .name = "shell_completions",
        .status = .warn,
        .message = std.fmt.allocPrint(arena, "shell completions need attention: {s}", .{bad.items}) catch "shell completions need attention",
        .hint = "run 'tau doctor --fix' to install/refresh completion scripts",
        .fix = .install_completions,
    };
}

/// Check 3: effective provider/model/endpoint/context_window after overrides.
fn checkProvider(arena: std.mem.Allocator, cfg: Config) Check {
    if (cfg.doctor_bad_provider) |bad| {
        return .{
            .name = "provider_resolution",
            .status = .fail,
            .message = std.fmt.allocPrint(arena, "unknown provider '{s}'", .{bad}) catch "unknown provider",
            .hint = providerListHint(arena),
        };
    }
    return .{
        .name = "provider_resolution",
        .status = .ok,
        .message = std.fmt.allocPrint(arena, "provider={s} model={s} endpoint={s} context_window={d}", .{ cfg.provider, cfg.model, cfg.endpoint, cfg.context_window }) catch "provider resolved",
    };
}

/// Check 3: an API key resolves — report which source supplied it, never the
/// key value.
fn checkApiKey(arena: std.mem.Allocator, cfg: Config, rk: ?cfgmod.ResolvedKey) Check {
    const r = rk orelse return .{
        .name = "api_key",
        .status = .fail,
        .message = std.fmt.allocPrint(arena, "no API key for provider '{s}'", .{cfg.provider}) catch "no API key",
        .hint = keyHint(arena, cfg.provider),
    };
    return .{
        .name = "api_key",
        .status = .ok,
        .message = std.fmt.allocPrint(arena, "API key resolved (source: {s})", .{keySourceLabel(arena, cfg, r)}) catch "API key resolved",
    };
}

/// Check 4: curl is on PATH (provider.complete shells out to curl).
fn checkCurl(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator) Check {
    const res = std.process.run(gpa, io, .{
        .argv = &.{ "curl", "--version" },
        .stdout_limit = .unlimited,
        .stderr_limit = .unlimited,
    }) catch {
        return .{
            .name = "curl",
            .status = .fail,
            .message = "curl not found on PATH",
            .hint = "install curl — tau shells out to curl for every LLM request",
        };
    };
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);
    switch (res.term) {
        .exited => |code| {
            if (code == 0) {
                // First line looks like "curl 8.5.0 (platform) ..." — keep the
                // "curl X.Y.Z" prefix for the report.
                const line_end = std.mem.indexOfScalar(u8, res.stdout, '\n') orelse res.stdout.len;
                var line: []const u8 = res.stdout[0..line_end];
                if (std.mem.indexOfScalar(u8, line, '(')) |p| line = line[0..p];
                line = std.mem.trim(u8, line, " \t\r");
                return .{
                    .name = "curl",
                    .status = .ok,
                    .message = std.fmt.allocPrint(arena, "curl available: {s}", .{line}) catch "curl available",
                };
            }
            return .{ .name = "curl", .status = .fail, .message = "curl --version exited non-zero", .hint = "reinstall curl" };
        },
        else => return .{ .name = "curl", .status = .fail, .message = "curl --version did not exit cleanly", .hint = "reinstall curl" },
    }
}

/// Run curl and capture the written-out http_code (e.g. "200", "000" on
/// connect failure). Returns null when curl itself failed to run.
fn curlHttpCode(io: std.Io, gpa: std.mem.Allocator, argv: []const []const u8, timeout_ms: i64) ?[]const u8 {
    const timeout = std.Io.Timeout{ .duration = .{
        .raw = std.Io.Duration.fromMilliseconds(timeout_ms),
        .clock = .awake,
    } };
    const res = std.process.run(gpa, io, .{
        .argv = argv,
        .stdout_limit = .unlimited,
        .stderr_limit = .unlimited,
        .timeout = timeout,
    }) catch return null;
    defer gpa.free(res.stderr);
    switch (res.term) {
        .exited => |code| {
            if (code == 0) return res.stdout;
            gpa.free(res.stdout);
            return null;
        },
        else => {
            gpa.free(res.stdout);
            return null;
        },
    }
}

/// Map an auth-probe HTTP status to a check status. 2xx -> ok, 401/403 ->
/// fail (key rejected), 429 -> warn (throttled, key undetermined), anything
/// else -> warn.
fn probeStatus(code: u16) CheckStatus {
    if (code >= 200 and code < 300) return .ok;
    if (code == 401 or code == 403) return .fail;
    return .warn;
}

/// Check 5: endpoint reachable — any HTTP response counts (even 401/405);
/// DNS/connect failure or timeout fails.
fn checkEndpoint(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, cfg: Config, curl_ok: bool) Check {
    if (cfg.doctor_offline)
        return .{ .name = "endpoint_reachable", .status = .skip, .message = "skipped (--offline)" };
    if (cfg.doctor_bad_provider != null)
        return .{ .name = "endpoint_reachable", .status = .skip, .message = "skipped (provider did not resolve)" };
    if (!curl_ok)
        return .{ .name = "endpoint_reachable", .status = .skip, .message = "skipped (curl unavailable)" };

    const code = curlHttpCode(io, gpa, &.{
        "curl",       "-s",                                                            "-o",         "/dev/null", "-w", "%{http_code}",
        "--max-time", std.fmt.allocPrint(arena, "{d}", .{probe_max_time_s}) catch "5", cfg.endpoint,
    }, (probe_max_time_s + 10) * 1000) orelse {
        return .{
            .name = "endpoint_reachable",
            .status = .fail,
            .message = std.fmt.allocPrint(arena, "endpoint unreachable: {s}", .{cfg.endpoint}) catch "endpoint unreachable",
            .hint = "check network/proxy; set TAU_ENDPOINT to override the endpoint",
        };
    };
    defer gpa.free(code);
    const n = std.fmt.parseInt(u16, std.mem.trim(u8, code, " \t\r\n"), 10) catch 0;
    if (n == 0) {
        return .{
            .name = "endpoint_reachable",
            .status = .fail,
            .message = std.fmt.allocPrint(arena, "endpoint unreachable: {s}", .{cfg.endpoint}) catch "endpoint unreachable",
            .hint = "check network/proxy; set TAU_ENDPOINT to override the endpoint",
        };
    }
    return .{
        .name = "endpoint_reachable",
        .status = .ok,
        .message = std.fmt.allocPrint(arena, "endpoint reachable (HTTP {d})", .{n}) catch "endpoint reachable",
    };
}

/// Check 6 (--deep only): one minimal authenticated completion
/// (max_tokens=1). 401/403 -> the key is rejected; 2xx -> end-to-end ok.
fn checkAuthProbe(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, cfg: Config, rk: ?cfgmod.ResolvedKey, curl_ok: bool) Check {
    if (cfg.doctor_offline)
        return .{ .name = "auth_probe", .status = .skip, .message = "skipped (--offline)" };
    if (!cfg.doctor_deep)
        return .{ .name = "auth_probe", .status = .skip, .message = "skipped", .hint = "pass --deep to validate the key end-to-end" };
    if (cfg.doctor_bad_provider != null)
        return .{ .name = "auth_probe", .status = .skip, .message = "skipped (provider did not resolve)" };
    if (!curl_ok)
        return .{ .name = "auth_probe", .status = .skip, .message = "skipped (curl unavailable)" };
    const r = rk orelse
        return .{ .name = "auth_probe", .status = .skip, .message = "skipped (no API key resolved)" };

    var body: std.ArrayList(u8) = .empty;
    body.appendSlice(arena, "{\"model\":\"") catch return .{ .name = "auth_probe", .status = .fail, .message = "out of memory" };
    json.escapeInto(arena, &body, cfg.model) catch return .{ .name = "auth_probe", .status = .fail, .message = "out of memory" };
    body.appendSlice(arena, "\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"max_tokens\":1,\"stream\":false}") catch return .{ .name = "auth_probe", .status = .fail, .message = "out of memory" };

    const auth = std.fmt.allocPrint(arena, "Authorization: Bearer {s}", .{r.key}) catch
        return .{ .name = "auth_probe", .status = .fail, .message = "out of memory" };
    const code = curlHttpCode(io, gpa, &.{
        "curl",       "-s",                                                                  "-o",                             "/dev/null",  "-w",         "%{http_code}",
        "--max-time", std.fmt.allocPrint(arena, "{d}", .{auth_probe_max_time_s}) catch "15", "-X",                             "POST",       cfg.endpoint, "-H",
        auth,         "-H",                                                                  "Content-Type: application/json", "--data-raw", body.items,
    }, (auth_probe_max_time_s + 15) * 1000) orelse {
        return .{
            .name = "auth_probe",
            .status = .fail,
            .message = "auth probe request failed",
            .hint = "endpoint unreachable or timed out — see the endpoint_reachable check",
        };
    };
    defer gpa.free(code);
    const n = std.fmt.parseInt(u16, std.mem.trim(u8, code, " \t\r\n"), 10) catch 0;
    return switch (probeStatus(n)) {
        .ok => .{
            .name = "auth_probe",
            .status = .ok,
            .message = std.fmt.allocPrint(arena, "authenticated probe succeeded (HTTP {d})", .{n}) catch "authenticated probe succeeded",
        },
        .fail => .{
            .name = "auth_probe",
            .status = .fail,
            .message = std.fmt.allocPrint(arena, "API key rejected (HTTP {d})", .{n}) catch "API key rejected",
            .hint = "verify the key is valid for the resolved provider",
        },
        else => if (n == 429) Check{
            .name = "auth_probe",
            .status = .warn,
            .message = "rate limited (HTTP 429) — key validity undetermined",
        } else Check{
            .name = "auth_probe",
            .status = .warn,
            .message = std.fmt.allocPrint(arena, "unexpected HTTP {d} from endpoint", .{n}) catch "unexpected response",
        },
    };
}

/// The collected doctor verdict: `ok` mirrors the exit code (all non-skipped
/// checks ok/warn) and `json` is the serialized report object with no trailing
/// newline — callers (tau setup) can embed it in a larger envelope.
pub const Report = struct {
    ok: bool,
    json: []const u8,
};

/// Run every check and return the raw list. Local checks run first
/// (config file, permissions, completions), then provider/key, then the
/// curl-gated network checks.
pub fn collectChecks(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, cfg: Config, env: *std.process.Environ.Map) ![]Check {
    var checks: std.ArrayList(Check) = .empty;
    try checks.append(arena, checkConfigFile(io, arena, env));
    try checks.append(arena, checkConfigPermissions(io, arena, env));
    try checks.append(arena, checkProvider(arena, cfg));
    const rk = cfgmod.resolveApiKeyInfo(cfg, env);
    try checks.append(arena, checkApiKey(arena, cfg, rk));
    try checks.append(arena, checkCompletions(io, arena, cfg, env));
    const curl_check = checkCurl(io, gpa, arena);
    const curl_ok = curl_check.status == .ok;
    try checks.append(arena, curl_check);
    try checks.append(arena, checkEndpoint(io, gpa, arena, cfg, curl_ok));
    try checks.append(arena, checkAuthProbe(io, gpa, arena, cfg, rk, curl_ok));
    return checks.toOwnedSlice(arena);
}

/// Run every check and return the report. Split from run() so `tau setup` can
/// embed the same report under a "doctor" step instead of printing it bare.
pub fn collectReport(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, cfg: Config, env: *std.process.Environ.Map) !Report {
    const checks = try collectChecks(io, gpa, arena, cfg, env);
    const report_json = try formatReportJson(arena, checks, null);
    return .{
        .ok = summarize(checks).fail == 0,
        // formatReportJson emits a trailing '\n' — drop it so callers can
        // embed the object inside a larger envelope.
        .json = if (report_json.len > 0 and report_json[report_json.len - 1] == '\n') report_json[0 .. report_json.len - 1] else report_json,
    };
}

// ---------------------------------------------------------------------------
// --fix remediation
// ---------------------------------------------------------------------------

/// A remediation proposed for one check outcome.
const PlannedFix = struct {
    kind: FixKind,
    check: []const u8,
    description: []const u8,
};

/// One entry in the report's "fixes" array.
pub const FixStatus = enum { applied, declined, skipped, failed };

pub const FixOutcome = struct {
    id: []const u8,
    check: []const u8,
    status: FixStatus,
    detail: []const u8,
};

fn fixDescription(k: FixKind) []const u8 {
    return switch (k) {
        .scaffold_config => "create ~/.config/tau and write a commented starter config",
        .restore_config => "move the invalid config to config.json.bak and write a starter config",
        .chmod_config => "restrict permissions (~/.config/tau -> 0700, config.json -> 0600)",
        .install_completions => "install/refresh shell completion scripts",
    };
}

/// Collect fixable check outcomes into a deduped remediation plan.
fn planFixes(arena: std.mem.Allocator, checks: []const Check) ![]PlannedFix {
    var list: std.ArrayList(PlannedFix) = .empty;
    for (checks) |c| {
        const k = c.fix orelse continue;
        var seen = false;
        for (list.items) |pf| {
            if (pf.kind == k) {
                seen = true;
                break;
            }
        }
        if (seen) continue;
        try list.append(arena, .{ .kind = k, .check = c.name, .description = fixDescription(k) });
    }
    return list.toOwnedSlice(arena);
}

/// Write the init scaffold to the config path, creating ~/.config/tau when
/// missing. Returns the path written. Never run when a config already exists
/// — callers only reach this for missing/restored configs.
fn writeScaffold(io: std.Io, arena: std.mem.Allocator, env: *std.process.Environ.Map) ![]const u8 {
    const path = configfile.path(arena, env) orelse return error.HomeUnset;
    const det = try initmod.detectKeys(arena, env);
    const p = initmod.pickProvider(det, null);
    const body = try initmod.renderConfig(arena, det, p);
    _ = try setup.writeIfChanged(io, arena, path, body);
    if (comptime builtin.os.tag != .windows) {
        // The scaffold can hold API keys later — start restrictive so the
        // config_permissions check is clean after one --fix pass.
        if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx|
            std.Io.Dir.cwd().setFilePermissions(io, path[0..idx], .fromMode(0o700), .{}) catch {};
        std.Io.Dir.cwd().setFilePermissions(io, path, .fromMode(0o600), .{}) catch {};
    }
    return path;
}

/// The actual work behind each FixKind. Returns a human/agent-readable detail
/// string on success; errors surface as a failed FixOutcome.
fn applyFix(io: std.Io, arena: std.mem.Allocator, cfg: Config, env: *std.process.Environ.Map, pf: PlannedFix) FixOutcome {
    const detail = switch (pf.kind) {
        .scaffold_config => blk: {
            const path = writeScaffold(io, arena, env) catch |err| break :blk err;
            break :blk std.fmt.allocPrint(arena, "wrote starter config: {s}", .{path}) catch "wrote starter config";
        },
        .restore_config => blk: {
            const path = configfile.path(arena, env) orelse break :blk error.HomeUnset;
            const backup = std.fmt.allocPrint(arena, "{s}.bak", .{path}) catch break :blk error.OutOfMemory;
            // POSIX rename overwrites a stale .bak from an earlier --fix run.
            std.Io.Dir.cwd().rename(path, std.Io.Dir.cwd(), backup, io) catch |err| break :blk err;
            const written = writeScaffold(io, arena, env) catch |err| break :blk err;
            break :blk std.fmt.allocPrint(arena, "moved invalid config to {s}; wrote {s}", .{ backup, written }) catch "restored config";
        },
        .chmod_config => blk: {
            if (comptime builtin.os.tag == .windows) break :blk error.UnsupportedPlatform;
            const path = configfile.path(arena, env) orelse break :blk error.HomeUnset;
            var did: std.ArrayList(u8) = .empty;
            if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| {
                std.Io.Dir.cwd().setFilePermissions(io, path[0..idx], .fromMode(0o700), .{}) catch |err| break :blk err;
                did.appendSlice(arena, "dir -> 0700") catch {};
            }
            // The file may not exist (e.g. only the dir was loose).
            if (std.Io.Dir.cwd().statFile(io, path, .{})) |_| {
                std.Io.Dir.cwd().setFilePermissions(io, path, .fromMode(0o600), .{}) catch |err| break :blk err;
                if (did.items.len > 0) did.appendSlice(arena, ", ") catch {};
                did.appendSlice(arena, "config.json -> 0600") catch {};
            } else |_| {}
            if (did.items.len == 0) break :blk std.fmt.allocPrint(arena, "nothing to restrict: {s}", .{path}) catch "nothing to restrict";
            break :blk std.fmt.allocPrint(arena, "restricted {s} ({s})", .{ did.items, path }) catch "restricted permissions";
        },
        .install_completions => blk: {
            const home = env.get("HOME") orelse break :blk error.HomeUnset;
            const shells = setup.resolveShells(arena, cfg, env) catch |err| break :blk err;
            if (shells.len == 0) break :blk error.NoShellDetected;
            var names: std.ArrayList(u8) = .empty;
            for (shells, 0..) |k, i| {
                _ = setup.installCompletion(io, arena, home, k) catch |err| break :blk err;
                if (i != 0) names.appendSlice(arena, ",") catch {};
                names.appendSlice(arena, setup.shellName(k)) catch {};
            }
            break :blk std.fmt.allocPrint(arena, "installed completions for {s}", .{names.items}) catch "installed completions";
        },
    } catch |err| {
        return .{
            .id = @tagName(pf.kind),
            .check = pf.check,
            .status = .failed,
            .detail = std.fmt.allocPrint(arena, "fix failed: {s}", .{@errorName(err)}) catch "fix failed",
        };
    };
    return .{ .id = @tagName(pf.kind), .check = pf.check, .status = .applied, .detail = detail };
}

/// Prompt on stderr and read one line from the (TTY) stdin reader. Only an
/// explicit y/yes approves; empty lines, EOF, and read errors decline.
fn confirmFix(arena: std.mem.Allocator, r: *std.Io.Reader, pf: PlannedFix) bool {
    const prompt = std.fmt.allocPrint(arena, "doctor --fix: {s} — apply? [y/N] ", .{pf.description}) catch return false;
    term.err(prompt);
    const line = (r.takeDelimiter('\n') catch return false) orelse return false;
    const t = std.mem.trim(u8, line, " \t\r");
    return std.ascii.eqlIgnoreCase(t, "y") or std.ascii.eqlIgnoreCase(t, "yes");
}

fn anyApplied(outcomes: []const FixOutcome) bool {
    for (outcomes) |o| {
        if (o.status == .applied) return true;
    }
    return false;
}

/// Run all checks, print the JSON report on stdout, and return the process
/// exit code: 0 when every non-skipped check is ok/warn, 1 when any fails.
/// With cfg.doctor_fix, plan remediations first; each fix applies only when
/// confirmed (--yes, or a y/yes answer on a TTY prompt). The emitted report
/// carries a "fixes" array and reflects the post-fix state when anything was
/// applied.
pub fn run(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, cfg: Config, env: *std.process.Environ.Map) !u8 {
    if (!cfg.doctor_fix) {
        const report = try collectReport(io, gpa, arena, cfg, env);
        term.out(report.json);
        term.out("\n");
        return if (report.ok) 0 else 1;
    }

    const checks = try collectChecks(io, gpa, arena, cfg, env);
    const planned = try planFixes(arena, checks);
    var outcomes: std.ArrayList(FixOutcome) = .empty;
    if (planned.len > 0) {
        const interactive = !cfg.doctor_yes and (std.Io.File.stdin().isTty(io) catch false);
        var rbuf: [512]u8 = undefined;
        var fr = std.Io.File.stdin().reader(io, &rbuf);
        for (planned) |pf| {
            const approved = cfg.doctor_yes or (interactive and confirmFix(arena, &fr.interface, pf));
            if (approved) {
                try outcomes.append(arena, applyFix(io, arena, cfg, env, pf));
            } else {
                try outcomes.append(arena, .{
                    .id = @tagName(pf.kind),
                    .check = pf.check,
                    .status = if (interactive) .declined else .skipped,
                    .detail = if (interactive) "declined at prompt" else "not confirmed — pass --yes to apply non-interactively",
                });
            }
        }
    }

    // Re-diagnose only when a fix actually changed something; the emitted
    // report (and exit code) then reflects the post-remediation state.
    const final_checks = if (anyApplied(outcomes.items)) try collectChecks(io, gpa, arena, cfg, env) else checks;
    const report_json = try formatReportJson(arena, final_checks, outcomes.items);
    term.out(report_json);
    return if (summarize(final_checks).fail == 0) 0 else 1;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
const testing = std.testing;

test "summarize: counts statuses and drives the ok flag" {
    const checks = [_]Check{
        .{ .name = "a", .status = .ok, .message = "m" },
        .{ .name = "b", .status = .warn, .message = "m" },
        .{ .name = "c", .status = .skip, .message = "m" },
    };
    const s = summarize(&checks);
    try testing.expectEqual(@as(u32, 1), s.ok);
    try testing.expectEqual(@as(u32, 1), s.warn);
    try testing.expectEqual(@as(u32, 0), s.fail);
    try testing.expectEqual(@as(u32, 1), s.skip);
}

test "formatCheckJson: escapes fields and omits empty hint" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const no_hint = try formatCheckJson(a, .{ .name = "api_key", .status = .fail, .message = "no key \"x\"" });
    try testing.expectEqualStrings("{\"name\":\"api_key\",\"status\":\"fail\",\"message\":\"no key \\\"x\\\"\"}", no_hint);

    const with_hint = try formatCheckJson(a, .{ .name = "curl", .status = .ok, .message = "curl available", .hint = "line1\nline2" });
    try testing.expect(std.mem.indexOf(u8, with_hint, "\"hint\":\"line1\\nline2\"") != null);
}

test "formatReportJson: ok=false with summary counts when a check fails" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const checks = [_]Check{
        .{ .name = "config_file", .status = .ok, .message = "parsed" },
        .{ .name = "api_key", .status = .fail, .message = "no key", .hint = "set X env var" },
        .{ .name = "auth_probe", .status = .skip, .message = "skipped" },
    };
    const got = try formatReportJson(a, &checks, null);
    try testing.expect(std.mem.startsWith(u8, got, "{\"ok\":false,\"version\":"));
    try testing.expect(std.mem.indexOf(u8, got, "\"summary\":{\"ok\":1,\"warn\":0,\"fail\":1,\"skip\":1}") != null);
}

test "configBodyCheck: invalid JSON fails with the path and a fix hint" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const c = configBodyCheck(arena.allocator(), "/tmp/x/config.json", "{ not json ");
    try testing.expectEqual(CheckStatus.fail, c.status);
    try testing.expect(std.mem.indexOf(u8, c.message, "/tmp/x/config.json") != null);
    try testing.expect(c.hint != null);
}

test "configBodyCheck: unknown provider key warns, valid file is ok" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const warn = configBodyCheck(a, "/tmp/cfg", "{\"provider\":\"acme\"}");
    try testing.expectEqual(CheckStatus.warn, warn.status);
    try testing.expect(std.mem.indexOf(u8, warn.message, "acme") != null);

    const ok = configBodyCheck(a, "/tmp/cfg", "{\"provider\":\"openai\",\"model\":\"gpt-x\"}");
    try testing.expectEqual(CheckStatus.ok, ok.status);

    // JSONC (as `tau init` writes it) parses after comment stripping.
    const jsonc = configBodyCheck(a, "/tmp/cfg", "// starter\n{\"provider\":\"openai\"} /* tail */");
    try testing.expectEqual(CheckStatus.ok, jsonc.status);

    // Provider as a non-string is tolerated (configfile.load ignores it too).
    const odd = configBodyCheck(a, "/tmp/cfg", "{\"provider\":42}");
    try testing.expectEqual(CheckStatus.ok, odd.status);
}

test "checkProvider: bad provider fails, resolved provider reports fields" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const bad = checkProvider(a, .{ .doctor_bad_provider = "acme" });
    try testing.expectEqual(CheckStatus.fail, bad.status);
    try testing.expect(std.mem.indexOf(u8, bad.message, "unknown provider 'acme'") != null);

    const ok = checkProvider(a, .{ .provider = "openai", .model = "gpt-4o-mini", .endpoint = "https://example.test/x", .context_window = 128_000 });
    try testing.expectEqual(CheckStatus.ok, ok.status);
    try testing.expect(std.mem.indexOf(u8, ok.message, "provider=openai") != null);
    try testing.expect(std.mem.indexOf(u8, ok.message, "model=gpt-4o-mini") != null);
    try testing.expect(std.mem.indexOf(u8, ok.message, "context_window=128000") != null);
}

test "checkApiKey: missing key fails with env-var hint and never prints a key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const fail = checkApiKey(a, .{ .provider = "openai" }, null);
    try testing.expectEqual(CheckStatus.fail, fail.status);
    try testing.expect(std.mem.indexOf(u8, fail.hint.?, "OPENAI_API_KEY") != null);
    try testing.expect(std.mem.indexOf(u8, fail.hint.?, "--api-key") != null);

    const ok = checkApiKey(a, .{ .provider = "openai" }, .{ .key = "sk-secret-9999", .source = .env_provider, .env_name = "OPENAI_API_KEY" });
    try testing.expectEqual(CheckStatus.ok, ok.status);
    try testing.expect(std.mem.indexOf(u8, ok.message, "env:OPENAI_API_KEY") != null);
    try testing.expect(std.mem.indexOf(u8, ok.message, "sk-secret-9999") == null);
}

test "keySourceLabel: covers every precedence level" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cfg = Config{ .provider = "openai" };

    try testing.expectEqualStrings("--api-key", keySourceLabel(a, cfg, .{ .key = "k", .source = .flag }));
    try testing.expectEqualStrings("keys[openai]", keySourceLabel(a, cfg, .{ .key = "k", .source = .config_keys }));
    try testing.expectEqualStrings("env:OPENAI_API_KEY", keySourceLabel(a, cfg, .{ .key = "k", .source = .env_provider, .env_name = "OPENAI_API_KEY" }));
    try testing.expectEqualStrings("config.api_key", keySourceLabel(a, cfg, .{ .key = "k", .source = .config_global }));
    try testing.expectEqualStrings("env:TAU_API_KEY", keySourceLabel(a, cfg, .{ .key = "k", .source = .env_tau, .env_name = "TAU_API_KEY" }));
    try testing.expectEqualStrings("builtin", keySourceLabel(a, cfg, .{ .key = "k", .source = .builtin }));
}

test "probeStatus: 2xx ok, 401/403 fail, 429/other warn" {
    try testing.expectEqual(CheckStatus.ok, probeStatus(200));
    try testing.expectEqual(CheckStatus.ok, probeStatus(201));
    try testing.expectEqual(CheckStatus.fail, probeStatus(401));
    try testing.expectEqual(CheckStatus.fail, probeStatus(403));
    try testing.expectEqual(CheckStatus.warn, probeStatus(429));
    try testing.expectEqual(CheckStatus.warn, probeStatus(500));
}

test "checkEndpoint/checkAuthProbe: offline and dependency gates skip" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const ep_off = checkEndpoint(testing.io, testing.allocator, a, .{ .doctor_offline = true }, true);
    try testing.expectEqual(CheckStatus.skip, ep_off.status);

    const ep_badprov = checkEndpoint(testing.io, testing.allocator, a, .{ .doctor_bad_provider = "acme" }, true);
    try testing.expectEqual(CheckStatus.skip, ep_badprov.status);

    const ep_nocurl = checkEndpoint(testing.io, testing.allocator, a, .{}, false);
    try testing.expectEqual(CheckStatus.skip, ep_nocurl.status);

    const ap_off = checkAuthProbe(testing.io, testing.allocator, a, .{ .doctor_offline = true, .doctor_deep = true }, null, true);
    try testing.expectEqual(CheckStatus.skip, ap_off.status);

    const ap_notdeep = checkAuthProbe(testing.io, testing.allocator, a, .{}, null, true);
    try testing.expectEqual(CheckStatus.skip, ap_notdeep.status);
    try testing.expect(std.mem.indexOf(u8, ap_notdeep.hint.?, "--deep") != null);

    const ap_nokey = checkAuthProbe(testing.io, testing.allocator, a, .{ .doctor_deep = true }, null, true);
    try testing.expectEqual(CheckStatus.skip, ap_nokey.status);
    try testing.expect(std.mem.indexOf(u8, ap_nokey.message, "no API key") != null);
}

/// A throwaway HOME under .zig-cache/tmp so checkConfigFile exercises its real
/// file I/O (same pattern as the TestHome helper in configfile.zig).
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

test "checkConfigFile: no HOME and missing file are ok, valid file parses" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // No HOME -> path() returns null -> defaults are fine.
    var env_no_home = std.process.Environ.Map.init(a);
    const c_nohome = checkConfigFile(testing.io, a, &env_no_home);
    try testing.expectEqual(CheckStatus.ok, c_nohome.status);
    try testing.expect(std.mem.indexOf(u8, c_nohome.message, "using defaults") != null);

    var home = try TestHome.init(a);
    defer home.deinit();

    // HOME set but no config.json -> ok, and the message names the path.
    const c_missing = checkConfigFile(testing.io, a, &home.env);
    try testing.expectEqual(CheckStatus.ok, c_missing.status);
    try testing.expect(std.mem.indexOf(u8, c_missing.message, "config.json") != null);
    try testing.expect(std.mem.indexOf(u8, c_missing.message, "using defaults") != null);

    // Valid file -> ok "config file parsed: <path>".
    try home.writeConfig(a, "{\"provider\":\"openai\",\"model\":\"gpt-4o-mini\"}");
    const c_ok = checkConfigFile(testing.io, a, &home.env);
    try testing.expectEqual(CheckStatus.ok, c_ok.status);
    try testing.expect(std.mem.indexOf(u8, c_ok.message, "config file parsed") != null);
    try testing.expect(std.mem.indexOf(u8, c_ok.message, ".config/tau/config.json") != null);
}

test "checkConfigFile: invalid JSON fails with path and fix hint" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var home = try TestHome.init(a);
    defer home.deinit();
    try home.writeConfig(a, "{ not json ");

    const c = checkConfigFile(testing.io, a, &home.env);
    try testing.expectEqual(CheckStatus.fail, c.status);
    try testing.expect(std.mem.indexOf(u8, c.message, "invalid JSON") != null);
    try testing.expect(std.mem.indexOf(u8, c.message, ".config/tau/config.json") != null);
    try testing.expect(std.mem.indexOf(u8, c.hint.?, "fix the JSON") != null);
}

test "checkConfigFile: unreadable file fails with a permissions hint" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A directory where config.json belongs makes readFileAlloc fail
    // deterministically (IsDir), regardless of the test user's privileges.
    var home = try TestHome.init(a);
    defer home.deinit();
    try std.Io.Dir.cwd().createDirPath(testing.io, try std.fmt.allocPrint(a, "{s}/.config/tau/config.json", .{home.home}));

    const c = checkConfigFile(testing.io, a, &home.env);
    try testing.expectEqual(CheckStatus.fail, c.status);
    try testing.expect(std.mem.indexOf(u8, c.message, "cannot read config file") != null);
    try testing.expect(std.mem.indexOf(u8, c.hint.?, "permissions") != null);
}

test "checkEndpoint: refused connection fails with an actionable hint" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Port 1 requires privileges to bind, so nothing is ever listening — the
    // connect is refused instantly (curl exit != 0 -> curlHttpCode null).
    const c = checkEndpoint(testing.io, testing.allocator, a, .{
        .provider = "openai",
        .endpoint = "http://127.0.0.1:1/",
    }, true);
    try testing.expectEqual(CheckStatus.fail, c.status);
    try testing.expect(std.mem.indexOf(u8, c.message, "endpoint unreachable") != null);
    try testing.expect(std.mem.indexOf(u8, c.message, "127.0.0.1:1") != null);
    try testing.expect(std.mem.indexOf(u8, c.hint.?, "TAU_ENDPOINT") != null);
}

test "checkAuthProbe: deep-mode gates and unreachable-endpoint failure" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rk = cfgmod.ResolvedKey{ .key = "sk-test", .source = .flag };

    // Unresolved provider gates the probe even with --deep and a key.
    const ap_badprov = checkAuthProbe(testing.io, testing.allocator, a, .{ .doctor_deep = true, .doctor_bad_provider = "acme" }, rk, true);
    try testing.expectEqual(CheckStatus.skip, ap_badprov.status);
    try testing.expect(std.mem.indexOf(u8, ap_badprov.message, "provider did not resolve") != null);

    // No curl gates the probe.
    const ap_nocurl = checkAuthProbe(testing.io, testing.allocator, a, .{ .doctor_deep = true }, rk, false);
    try testing.expectEqual(CheckStatus.skip, ap_nocurl.status);
    try testing.expect(std.mem.indexOf(u8, ap_nocurl.message, "curl unavailable") != null);

    // Refused connection -> request failure, hint points at endpoint_reachable.
    const ap_fail = checkAuthProbe(testing.io, testing.allocator, a, .{
        .doctor_deep = true,
        .provider = "openai",
        .model = "gpt-4o-mini",
        .endpoint = "http://127.0.0.1:1/",
    }, rk, true);
    try testing.expectEqual(CheckStatus.fail, ap_fail.status);
    try testing.expect(std.mem.indexOf(u8, ap_fail.message, "auth probe request failed") != null);
    try testing.expect(std.mem.indexOf(u8, ap_fail.hint.?, "endpoint_reachable") != null);
}

test "keyHint: names env vars for known providers, falls back to --api-key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const openai = keyHint(a, "openai");
    try testing.expect(std.mem.indexOf(u8, openai, "OPENAI_API_KEY") != null);
    try testing.expect(std.mem.indexOf(u8, openai, "--api-key") != null);

    // Unknown provider -> generic flag hint.
    try testing.expectEqualStrings("use --api-key <key>", keyHint(a, "bogus-provider"));
}

test "providerListHint: lists providers and points at tau models" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const h = providerListHint(arena.allocator());
    try testing.expect(std.mem.indexOf(u8, h, "valid providers:") != null);
    try testing.expect(std.mem.indexOf(u8, h, "tau models") != null);
    try testing.expect(std.mem.indexOf(u8, h, cfgmod.providers[0].name) != null);
}

test "formatReportJson: warns do not flip the ok flag" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const checks = [_]Check{
        .{ .name = "config_file", .status = .warn, .message = "unknown provider" },
        .{ .name = "api_key", .status = .ok, .message = "resolved" },
        .{ .name = "auth_probe", .status = .skip, .message = "skipped" },
    };
    const got = try formatReportJson(a, &checks, null);
    try testing.expect(std.mem.startsWith(u8, got, "{\"ok\":true,"));
    try testing.expect(std.mem.indexOf(u8, got, "\"summary\":{\"ok\":1,\"warn\":1,\"fail\":0,\"skip\":1}") != null);
}

test "curlHttpCode: spawn failure returns null" {
    const got = curlHttpCode(testing.io, testing.allocator, &.{"definitely-not-a-tau-binary-xyz"}, 1000);
    try testing.expect(got == null);
}

// ---------------------------------------------------------------------------
// --fix tests
// ---------------------------------------------------------------------------

test "planFixes: collects fixable checks in order and dedupes kinds" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const checks = [_]Check{
        .{ .name = "config_file", .status = .fail, .message = "invalid JSON", .fix = .restore_config },
        .{ .name = "config_permissions", .status = .warn, .message = "loose", .fix = .chmod_config },
        .{ .name = "provider_resolution", .status = .ok, .message = "resolved" },
        .{ .name = "api_key", .status = .fail, .message = "no key" },
        // Second chmod outcome collapses into the first remediation.
        .{ .name = "other_perms", .status = .warn, .message = "loose too", .fix = .chmod_config },
        .{ .name = "shell_completions", .status = .warn, .message = "missing", .fix = .install_completions },
    };
    const plan = try planFixes(a, &checks);
    try testing.expectEqual(@as(usize, 3), plan.len);
    try testing.expectEqual(FixKind.restore_config, plan[0].kind);
    try testing.expectEqual(FixKind.chmod_config, plan[1].kind);
    try testing.expectEqual(FixKind.install_completions, plan[2].kind);
    try testing.expectEqualStrings("config_file", plan[0].check);
    try testing.expect(std.mem.indexOf(u8, plan[1].description, "0700") != null);
}

test "formatReportJson: emits the fixes array when provided" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const checks = [_]Check{
        .{ .name = "config_file", .status = .ok, .message = "parsed" },
    };
    const fixes = [_]FixOutcome{
        .{ .id = "scaffold_config", .check = "config_file", .status = .applied, .detail = "wrote /x/config.json" },
        .{ .id = "install_completions", .check = "shell_completions", .status = .skipped, .detail = "pass --yes" },
    };
    const got = try formatReportJson(a, &checks, &fixes);
    try testing.expect(std.mem.indexOf(u8, got, "\"fixes\":[{\"id\":\"scaffold_config\",\"check\":\"config_file\",\"status\":\"applied\",\"detail\":\"wrote /x/config.json\"}") != null);
    try testing.expect(std.mem.indexOf(u8, got, "\"status\":\"skipped\"") != null);
    try testing.expect(std.mem.indexOf(u8, got, "\"summary\":{") != null);
}

test "confirmFix: only y/yes approves; blank, other text, and EOF decline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const pf = PlannedFix{ .kind = .scaffold_config, .check = "config_file", .description = "d" };

    var r_yes = std.Io.Reader.fixed("y\n");
    try testing.expect(confirmFix(a, &r_yes, pf));
    var r_yes2 = std.Io.Reader.fixed(" YES \r\n");
    try testing.expect(confirmFix(a, &r_yes2, pf));
    var r_no = std.Io.Reader.fixed("n\n");
    try testing.expect(!confirmFix(a, &r_no, pf));
    var r_blank = std.Io.Reader.fixed("\n");
    try testing.expect(!confirmFix(a, &r_blank, pf));
    var r_eof = std.Io.Reader.fixed("");
    try testing.expect(!confirmFix(a, &r_eof, pf));
}

test "applyFix scaffold_config writes a commented config under a fresh HOME" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var home = try TestHome.init(a);
    defer home.deinit();
    const cfg_path = try std.fmt.allocPrint(a, "{s}/.config/tau/config.json", .{home.home});
    std.Io.Dir.cwd().deleteFile(testing.io, cfg_path) catch {};

    const out = applyFix(testing.io, a, .{}, &home.env, .{ .kind = .scaffold_config, .check = "config_file", .description = "d" });
    try testing.expectEqual(FixStatus.applied, out.status);
    try testing.expect(std.mem.indexOf(u8, out.detail, cfg_path) != null);

    const body = try std.Io.Dir.cwd().readFileAlloc(testing.io, cfg_path, a, .unlimited);
    try testing.expect(std.mem.indexOf(u8, body, "\"provider\"") != null);
}

test "applyFix restore_config moves an invalid config aside and re-scaffolds" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var home = try TestHome.init(a);
    defer home.deinit();
    try home.writeConfig(a, "{ not json ");
    const cfg_path = try std.fmt.allocPrint(a, "{s}/.config/tau/config.json", .{home.home});

    const out = applyFix(testing.io, a, .{}, &home.env, .{ .kind = .restore_config, .check = "config_file", .description = "d" });
    try testing.expectEqual(FixStatus.applied, out.status);

    // Original bytes preserved at .bak; the live path now parses.
    const bak = try std.Io.Dir.cwd().readFileAlloc(testing.io, try std.fmt.allocPrint(a, "{s}.bak", .{cfg_path}), a, .unlimited);
    try testing.expectEqualStrings("{ not json ", bak);
    const body = try std.Io.Dir.cwd().readFileAlloc(testing.io, cfg_path, a, .unlimited);
    try testing.expect(std.mem.indexOf(u8, body, "\"provider\"") != null);
    const c = checkConfigFile(testing.io, a, &home.env);
    try testing.expectEqual(CheckStatus.ok, c.status);
}

test "checkCompletions + install_completions fix round-trips under a mock HOME" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var home = try TestHome.init(a);
    defer home.deinit();

    // No shell detected -> skip (env has only HOME).
    const c_skip = checkCompletions(testing.io, a, .{}, &home.env);
    try testing.expectEqual(CheckStatus.skip, c_skip.status);

    // Explicit --shell bash: nothing installed -> warn, fixable.
    const cfg = Config{ .setup_shell = "bash" };
    const c_warn = checkCompletions(testing.io, a, cfg, &home.env);
    try testing.expectEqual(CheckStatus.warn, c_warn.status);
    try testing.expect(std.mem.indexOf(u8, c_warn.message, "bash:missing") != null);
    try testing.expectEqual(FixKind.install_completions, c_warn.fix.?);

    // Apply the fix -> check goes ok, script landed at the bash path.
    const out = applyFix(testing.io, a, cfg, &home.env, .{ .kind = .install_completions, .check = "shell_completions", .description = "d" });
    try testing.expectEqual(FixStatus.applied, out.status);
    try testing.expect(std.mem.indexOf(u8, out.detail, "bash") != null);
    const c_ok = checkCompletions(testing.io, a, cfg, &home.env);
    try testing.expectEqual(CheckStatus.ok, c_ok.status);
}

test "checkConfigPermissions: loose file warns fixable, chmod fix tightens" {
    if (comptime builtin.os.tag == .windows) return;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var home = try TestHome.init(a);
    defer home.deinit();
    const cfg_path = try std.fmt.allocPrint(a, "{s}/.config/tau/config.json", .{home.home});
    const dir_path = try std.fmt.allocPrint(a, "{s}/.config/tau", .{home.home});

    // No config file -> skip.
    std.Io.Dir.cwd().deleteFile(testing.io, cfg_path) catch {};
    const c_skip = checkConfigPermissions(testing.io, a, &home.env);
    try testing.expectEqual(CheckStatus.skip, c_skip.status);

    // World-readable config in a group-accessible dir -> warn, fixable.
    try home.writeConfig(a, "{\"provider\":\"openai\"}");
    try std.Io.Dir.cwd().setFilePermissions(testing.io, cfg_path, .fromMode(0o644), .{});
    try std.Io.Dir.cwd().setFilePermissions(testing.io, dir_path, .fromMode(0o755), .{});
    const c_warn = checkConfigPermissions(testing.io, a, &home.env);
    try testing.expectEqual(CheckStatus.warn, c_warn.status);
    try testing.expectEqual(FixKind.chmod_config, c_warn.fix.?);
    try testing.expect(std.mem.indexOf(u8, c_warn.message, "group/other") != null);

    // chmod fix -> dir 0700, file 0600, check goes ok.
    const out = applyFix(testing.io, a, .{}, &home.env, .{ .kind = .chmod_config, .check = "config_permissions", .description = "d" });
    try testing.expectEqual(FixStatus.applied, out.status);
    const c_ok = checkConfigPermissions(testing.io, a, &home.env);
    try testing.expectEqual(CheckStatus.ok, c_ok.status);
    const fstat = try std.Io.Dir.cwd().statFile(testing.io, cfg_path, .{});
    try testing.expectEqual(@as(std.posix.mode_t, 0o600), fstat.permissions.toMode() & 0o777);
    const dstat = try std.Io.Dir.cwd().statFile(testing.io, dir_path, .{});
    try testing.expectEqual(@as(std.posix.mode_t, 0o700), dstat.permissions.toMode() & 0o777);
}

test "collectChecks: fixable outcomes are attached to the right checks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var home = try TestHome.init(a);
    defer home.deinit();
    // Missing config.json -> scaffold fix; SHELL unset -> completions skip.
    const cfg_path = try std.fmt.allocPrint(a, "{s}/.config/tau/config.json", .{home.home});
    std.Io.Dir.cwd().deleteFile(testing.io, cfg_path) catch {};

    const checks = try collectChecks(testing.io, testing.allocator, a, .{}, &home.env);
    var saw_scaffold = false;
    for (checks) |c| {
        if (c.name.len == "config_file".len and std.mem.eql(u8, c.name, "config_file")) {
            try testing.expectEqual(FixKind.scaffold_config, c.fix.?);
            saw_scaffold = true;
        }
        // api_key/network checks are never auto-fixable.
        if (std.mem.eql(u8, c.name, "api_key")) try testing.expect(c.fix == null);
        if (std.mem.eql(u8, c.name, "curl")) try testing.expect(c.fix == null);
        if (std.mem.eql(u8, c.name, "endpoint_reachable")) try testing.expect(c.fix == null);
        if (std.mem.eql(u8, c.name, "auth_probe")) try testing.expect(c.fix == null);
    }
    try testing.expect(saw_scaffold);
}
