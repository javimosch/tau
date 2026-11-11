//! The `tau doctor` check catalog behind `tau explain doctor.<check>` —
//! one CheckSpec per check id the report can emit, so `tau explain
//! doctor.proxy_env` prints offline what the row means and how to fix it.
//!
//! The static rows (collectChecks order) plus the dynamic families —
//! `client_<name>` for every ClientKind `tau setup --client` can wire and
//! `probe_<provider>`/`probe_<provider>_auth` for every registered provider —
//! are the source of truth for the generated check table in
//! docs/troubleshooting.md (scripts/gen-doctor-checks-doc.py splices it
//! between the GENERATED DOCTOR CHECKS markers; the doc-mirror test below
//! pins the rows verbatim). Keep fails_when/remediation free of `{`, `}`, and
//! `|` so the Python parser and the markdown table stay well-formed.

const std = @import("std");
const json = @import("json.zig");
const setup = @import("setup.zig");
const cfgmod = @import("config.zig");
const version = @import("version.zig");

/// Every check entry links the doctor section of the troubleshooting page —
/// the generated table the entry mirrors lives there.
pub const doctor_doc_url = version.troubleshooting_doc_url ++ "#setup--config-problems--tau-doctor";

/// One row of the generated check table (and one `tau explain doctor.<id>`
/// entry): the report's check `name`, the condition that makes it warn or
/// fail, and the remediation that resolves it.
pub const CheckSpec = struct {
    name: []const u8,
    fails_when: []const u8,
    remediation: []const u8,
    docs: []const u8 = doctor_doc_url,
};

/// Shared spec text for the per-client wiring rows (`client_<name>` — one
/// per ClientKind, only emitted when that client's settings dir exists).
pub const client_fails_when = "tau isn't wired into that client's settings, or the wiring is stale — a dead `command` path or wrong `args` counts as stale; the row is absent entirely when the client isn't installed";

/// Remediation template for `client_<name>` rows: the first `{s}` is the
/// `--client` name, the second the per-client guide file under docs/clients/.
/// gen-doctor-checks-doc.py substitutes positionally.
pub const client_remediation_tmpl = "run `tau setup --client {s}` to wire or refresh it — `tau doctor --fix` auto-fixes the bridge/ACP clients and writes a paste-ready snippet for the manual ones; guide: docs/clients/{s}.md";

/// Shared spec text for the `--probe` connectivity rows (`probe_<provider>`).
pub const probe_fails_when = "the `--probe` connectivity check against that provider's endpoint failed or timed out";
pub const probe_remediation = "verify network reachability — DNS, firewall, and the proxy_env/tls_ca rows; the endpoint is listed by `tau models`";

/// Shared spec text for the `--probe` credential rows
/// (`probe_<provider>_auth`) — the `{s}` is the provider name, spliced into
/// the `keys.<provider>` member path.
pub const probe_auth_fails_when = "the `--probe` credential check failed — the key resolved for that provider was rejected by a one-token authenticated completion";
pub const probe_auth_remediation_tmpl = "re-issue or rotate the key — it resolves from the provider's env var, keys.{s} in config.json, TAU_API_KEY, or --api-key";

/// The fixed check rows, in collectChecks report order.
pub const static_specs = [_]CheckSpec{
    .{
        .name = "config_file",
        .fails_when = "~/.config/tau/config.json doesn't parse (fail), or names an unregistered provider (warn) — a missing file is ok, config is optional",
        .remediation = "fix the JSON or delete the file — `tau config validate` pinpoints the error with line/column; `tau doctor --fix` moves a broken config to config.json.bak and writes a starter",
    },
    .{
        .name = "config_deprecated_keys",
        .fails_when = "the config file still uses a deprecated or renamed key spelling (e.g. compact_keep_recent) — old spellings still load with a warn envelope during the deprecation window but are scheduled for removal (skipped when there is no config file or it doesn't parse)",
        .remediation = "run `tau doctor --fix` to rewrite the deprecated spellings in place — `tau config validate` prints the exact line/column and the canonical key name",
    },
    .{
        .name = "config_permissions",
        .fails_when = "the config dir or config.json grants group/other read access (POSIX only — the file can hold API keys)",
        .remediation = "run `tau doctor --fix` (chmod 0700 on ~/.config/tau, 0600 on config.json) or chmod them yourself",
    },
    .{
        .name = "plaintext_secrets",
        .fails_when = "credentials sit on disk as plaintext — api_key/keys.* values in the config file, or `env` blocks inside client settings files (warn only; reports key names and counts, never values)",
        .remediation = "move keys to environment variables — `tau config unset api_key` or `tau config unset keys.<provider>` — the provider env var still resolves; not auto-fixable",
    },
    .{
        .name = "config_secret_permissions",
        .fails_when = "the config file actually stores credentials (api_key or keys.<provider> values) and its mode grants group/other access — real exposure, not the hypothetical config_permissions covers (POSIX only; skipped when the file is missing or unparseable)",
        .remediation = "run `tau doctor --fix` (chmod 0600 on config.json via the shared chmod_config remediation — it also tightens the dir to 0700) or chmod it yourself; `tau config unset` moves keys to env vars",
    },
    .{
        .name = "shell_completions",
        .fails_when = "completion scripts are missing or stale for the detected shells",
        .remediation = "run `tau doctor --fix` or `tau setup --yes` to (re)install them",
    },
    .{
        .name = "provider_resolution",
        .fails_when = "the configured or --provider provider isn't registered",
        .remediation = "pick a registered provider — `tau models` lists them; `tau config set provider <name>` persists it",
    },
    .{
        .name = "api_key",
        .fails_when = "no API key resolves at any level of the precedence chain",
        .remediation = "pass --api-key, set the provider env var or TAU_API_KEY, or add api_key/keys.<provider> to config.json — `tau init` scaffolds a starter",
    },
    .{
        .name = "curl",
        .fails_when = "curl is missing or `curl --version` fails — every LLM request goes through curl",
        .remediation = "install curl via your package manager and re-run `tau doctor`",
    },
    .{
        .name = "proxy_env",
        .fails_when = "a *_proxy/*_PROXY variable looks wrong for the resolved endpoint — unparseable URL, credentials embedded in the URL (always redacted in output), HTTP_PROXY alone for an HTTPS endpoint (silent no-op), or NO_PROXY covering the endpoint host (warn only; runs under --offline)",
        .remediation = "export HTTPS_PROXY for https:// endpoints, drop credentials from the proxy URL, and make sure NO_PROXY doesn't cover the provider host — see \"Behind a corporate proxy\" below",
    },
    .{
        .name = "tls_ca",
        .fails_when = "CURL_CA_BUNDLE/SSL_CERT_FILE points at a missing or non-file path, or an SSL_CERT_DIR entry is missing (fail — every HTTPS request would error); a configured proxy with no custom CA bundle warns — the corporate TLS-intercept case (runs under --offline)",
        .remediation = "set CURL_CA_BUNDLE (or SSL_CERT_FILE/SSL_CERT_DIR) to your organization's PEM bundle, or fix/remove the missing path",
    },
    .{
        .name = "endpoint_reachable",
        .fails_when = "the provider endpoint doesn't answer within the probe timeout (skipped under --offline or without curl)",
        .remediation = "check the network, DNS, and the proxy_env/tls_ca rows — TAU_ENDPOINT overrides the endpoint",
    },
    .{
        .name = "auth_probe",
        .fails_when = "a one-token authenticated completion fails — the resolved key is rejected (--deep only; skipped under --offline, without curl, or with no key resolved)",
        .remediation = "re-issue or rotate the key — the check names which source it resolved from (env var, config, or TAU_API_KEY)",
    },
    .{
        .name = "client_wiring",
        .fails_when = "placeholder row — HOME is unset or no editor config dir was detected, so no per-client rows ran",
        .remediation = "install the editor you want wired, then run `tau setup --client <name>`",
    },
    .{
        .name = "client_permissions",
        .fails_when = "a detected client settings file (or the mcacp bridge config) grants group/other access — `env` blocks inside it can hold API keys (POSIX only)",
        .remediation = "run `tau doctor --fix` (chmod 0600 on every detected client settings file and mcacp.json) or chmod them yourself",
    },
    .{
        .name = "provider_probes",
        .fails_when = "placeholder row for the opt-in sweep — skipped unless --probe is passed",
        .remediation = "run `tau doctor --probe` to live-verify connectivity and credentials for every registered provider",
    },
    .{
        .name = "update_available",
        .fails_when = "a newer release exists upstream (warn only; skipped under --offline, TAU_NO_UPDATE_CHECK=1, or without curl)",
        .remediation = "run `tau upgrade` — TAU_NO_UPDATE_CHECK=1 silences the row",
    },
    .{
        .name = "selftest",
        .fails_when = "the credential-free end-to-end run against a loopback stub provider fails (--selftest only) — the installed binary can't complete a session",
        .remediation = "re-run `tau doctor --selftest --debug` and attach the redacted log to `tau bug`",
    },
};

/// The per-client guide filename under docs/clients/ — every file except
/// Gemini CLI's is named after the `--client` name.
fn guideFile(comptime k: setup.ClientKind) []const u8 {
    const n = comptime setup.clientName(k);
    return if (comptime std.mem.eql(u8, n, "gemini")) "gemini-cli" else n;
}

/// `clientName` with hyphens folded to underscores — the same rule
/// doctor.zig's clientCheckName applies, so catalog ids match report rows.
fn underscored(comptime s: []const u8) []const u8 {
    var out: [s.len]u8 = undefined;
    for (s, 0..) |ch, i| out[i] = if (ch == '-') '_' else ch;
    const frozen = out;
    return &frozen;
}

/// Everything `tau explain doctor.<check>` resolves: the fixed rows, then
/// `client_<name>` for every wireable client, then `probe_<provider>` and
/// `probe_<provider>_auth` for every registered provider.
pub const check_catalog = blk: {
    var c: [static_specs.len + setup.all_clients.len + cfgmod.providers.len * 2]CheckSpec = undefined;
    for (static_specs, 0..) |s, i| c[i] = s;
    var n = static_specs.len;
    for (setup.all_clients) |k| {
        const disp = setup.clientName(k);
        c[n] = .{
            .name = "client_" ++ underscored(disp),
            .fails_when = client_fails_when,
            .remediation = std.fmt.comptimePrint(client_remediation_tmpl, .{ disp, guideFile(k) }),
        };
        n += 1;
    }
    for (cfgmod.providers) |p| {
        c[n] = .{ .name = "probe_" ++ p.name, .fails_when = probe_fails_when, .remediation = probe_remediation };
        c[n + 1] = .{
            .name = "probe_" ++ p.name ++ "_auth",
            .fails_when = probe_auth_fails_when,
            .remediation = std.fmt.comptimePrint(probe_auth_remediation_tmpl, .{p.name}),
        };
        n += 2;
    }
    break :blk c;
};

/// Resolve a doctor-check query. Accepts the bare check id or the
/// `doctor.<id>` spelling — the prefix is how a check wins when its bare
/// name collides with another catalog (`api_key` resolves the config key;
/// `doctor.api_key` resolves the check). Check ids are case-sensitive.
/// Returns null when nothing matches.
pub fn findCheck(query: []const u8) ?CheckSpec {
    const q = std.mem.trim(u8, query, " \t");
    const id = if (std.mem.startsWith(u8, q, "doctor.")) q["doctor.".len..] else q;
    if (id.len == 0) return null;
    for (check_catalog) |cs| {
        if (std.mem.eql(u8, id, cs.name)) return cs;
    }
    return null;
}

/// Serialize one check entry for `tau explain` (no trailing newline — the
/// caller owns framing):
/// {"check":"N","fails_when":"F","remediation":"R","docs":"U"}
/// Caller owns the returned slice.
pub fn formatCheckJson(a: std.mem.Allocator, cs: CheckSpec) ![]u8 {
    const ne = try json.escapeAlloc(a, cs.name);
    defer a.free(ne);
    const fe = try json.escapeAlloc(a, cs.fails_when);
    defer a.free(fe);
    const re = try json.escapeAlloc(a, cs.remediation);
    defer a.free(re);
    const de = try json.escapeAlloc(a, cs.docs);
    defer a.free(de);
    return std.fmt.allocPrint(a, "{{\"check\":\"{s}\",\"fails_when\":\"{s}\",\"remediation\":\"{s}\",\"docs\":\"{s}\"}}", .{ ne, fe, re, de });
}

/// Human-readable `tau explain --human doctor.<check>` rendering — drawn
/// from the same CheckSpec so the prose and JSON forms can never drift
/// apart.
pub fn formatCheckHuman(a: std.mem.Allocator, cs: CheckSpec) ![]u8 {
    return std.fmt.allocPrint(a, "doctor check  {s}\n  fails when: {s}\n  fix:        {s}\n  docs:       {s}\n", .{ cs.name, cs.fails_when, cs.remediation, cs.docs });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "findCheck: bare ids and the doctor. prefix resolve" {
    const bare = findCheck("tls_ca").?;
    try testing.expectEqualStrings("tls_ca", bare.name);
    const prefixed = findCheck("doctor.tls_ca").?;
    try testing.expectEqualStrings("tls_ca", prefixed.name);
    // The prefix is how a shared name reaches the check instead of the
    // config key of the same spelling.
    const shared = findCheck("doctor.api_key").?;
    try testing.expectEqualStrings("api_key", shared.name);
}

test "findCheck: dynamic ids and rejects" {
    try testing.expect(findCheck("doctor.client_zed") != null);
    try testing.expect(findCheck("doctor.client_claude_desktop") != null);
    try testing.expect(findCheck("doctor.client_roo_code") != null);
    try testing.expect(findCheck("doctor.probe_xiaomi") != null);
    try testing.expect(findCheck("doctor.probe_opencode-go_auth") != null);
    try testing.expect(findCheck("doctor.") == null);
    try testing.expect(findCheck("doctor.bogus") == null);
    try testing.expect(findCheck("doctor.client_nope") == null);
    try testing.expect(findCheck("Doctor.TLS_CA") == null);
    try testing.expect(findCheck("") == null);
}

test "check_catalog ids are unique and match report naming rules" {
    for (check_catalog, 0..) |cs, i| {
        for (check_catalog[i + 1 ..]) |other| {
            try testing.expect(!std.mem.eql(u8, cs.name, other.name));
        }
        // Identifiers only — the id appears verbatim in JSON check rows and
        // `tau explain doctor.<id>` queries.
        for (cs.name) |ch| {
            try testing.expect(std.ascii.isLower(ch) or std.ascii.isDigit(ch) or ch == '_' or ch == '-');
        }
    }
}

test "check_catalog client ids match doctor's clientCheckName rule" {
    // client_<clientName with '-' -> '_'> — proven against the same inputs
    // collectChecks iterates (setup.all_clients in order). The catalog is
    // laid out static rows first, then one client_<kind> per all_clients
    // member, so the slice after the static block is the client run.
    const run = check_catalog[static_specs.len .. static_specs.len + setup.all_clients.len];
    try testing.expectEqual(setup.all_clients.len, run.len);
    inline for (setup.all_clients, 0..) |k, i| {
        const want = "client_" ++ comptime underscored(setup.clientName(k));
        try testing.expectEqualStrings(want, run[i].name);
    }
    // Static rows named client_* are separate checks, not client rows.
    try testing.expect(findCheck("doctor.client_wiring") != null);
    try testing.expect(findCheck("doctor.client_permissions") != null);
}

test "every client guide file named by a check entry exists" {
    const gpa = testing.allocator;
    inline for (setup.all_clients) |k| {
        const path = try std.fmt.allocPrint(gpa, "docs/clients/{s}.md", .{guideFile(k)});
        defer gpa.free(path);
        const f = std.Io.Dir.cwd().openFile(testing.io, path, .{}) catch {
            std.debug.print("missing client guide {s}\n", .{path});
            return error.TestUnexpectedResult;
        };
        f.close(testing.io);
    }
}

test "explain: check catalog rows mirror the docs/troubleshooting.md table verbatim" {
    const gpa = testing.allocator;
    const doc = try std.Io.Dir.cwd().readFileAlloc(testing.io, "docs/troubleshooting.md", gpa, .unlimited);
    defer gpa.free(doc);
    for (check_catalog) |cs| {
        // Cell-escaped like the generated table (`|` -> `\|`).
        var esc_f: std.ArrayList(u8) = .empty;
        defer esc_f.deinit(gpa);
        for (cs.fails_when) |ch| {
            if (ch == '|') try esc_f.append(gpa, '\\');
            try esc_f.append(gpa, ch);
        }
        var esc_r: std.ArrayList(u8) = .empty;
        defer esc_r.deinit(gpa);
        for (cs.remediation) |ch| {
            if (ch == '|') try esc_r.append(gpa, '\\');
            try esc_r.append(gpa, ch);
        }
        var buf: [2000]u8 = undefined;
        const row = std.fmt.bufPrint(&buf, "| `{s}` | {s} | {s} |", .{ cs.name, esc_f.items, esc_r.items }) catch unreachable;
        if (std.mem.indexOf(u8, doc, row) == null) {
            std.debug.print("docs/troubleshooting.md missing check row '{s}'\n", .{row});
            return error.TestUnexpectedResult;
        }
    }
}

test "explain: every check-catalog entry resolves via findCheck" {
    for (check_catalog) |cs| {
        var buf: [80]u8 = undefined;
        const q = std.fmt.bufPrint(&buf, "doctor.{s}", .{cs.name}) catch unreachable;
        const got = findCheck(q) orelse {
            std.debug.print("findCheck failed to resolve catalog check '{s}'\n", .{cs.name});
            return error.TestUnexpectedResult;
        };
        try testing.expectEqualStrings(cs.name, got.name);
    }
}

test "explain: formatCheckJson emits the check entry shape" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const got = try formatCheckJson(ar.allocator(), findCheck("doctor.tls_ca").?);
    try testing.expect(std.mem.startsWith(u8, got, "{\"check\":\"tls_ca\""));
    try testing.expect(std.mem.indexOf(u8, got, "\"fails_when\":\"") != null);
    try testing.expect(std.mem.indexOf(u8, got, "\"remediation\":\"") != null);
    try testing.expect(std.mem.indexOf(u8, got, "docs/troubleshooting.md") != null);
    const v = try std.json.parseFromSliceLeaky(std.json.Value, ar.allocator(), got, .{});
    try testing.expect(v.object.get("check").?.string.len > 0);
}

test "explain: formatCheckHuman renders fails-when, fix, and docs" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const cs = findCheck("doctor.update_available").?;
    const got = try formatCheckHuman(ar.allocator(), cs);
    try testing.expect(std.mem.indexOf(u8, got, "doctor check  update_available") != null);
    try testing.expect(std.mem.indexOf(u8, got, "fails when:") != null);
    try testing.expect(std.mem.indexOf(u8, got, "fix:") != null);
    try testing.expect(std.mem.indexOf(u8, got, cs.remediation) != null);
}
