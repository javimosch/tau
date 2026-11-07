// `tau upgrade` — self-update in place. Reuses the release lookup from
// update.zig (the `tau version --check` path — same TAU_UPDATE_URL /
// TAU_NO_UPDATE_CHECK contract) to decide whether a newer release exists,
// asks for confirmation (a [y/N] prompt on a TTY stdin; --yes or TAU_YES=1
// approves non-interactively), then downloads the release tag's own
// install.sh and execs it — the same fail-closed, SHA256-verified install
// path documented for fresh installs, so upgrade inherits the installer's
// checksum gating for free (plus its TAU_BASE_URL/TAU_SKIP_CHECKSUM/
// TAU_VERIFY_SIGSTORE env contract, which flows through the child env).
// --verify-signature is the discoverable spelling of TAU_VERIFY_SIGSTORE=1:
// it is injected into the installer's env so the opt-in cosign check runs on
// the downloaded asset before the swap — no cosign, no signature bundle, or
// a failed verify all fail closed and surface through the report's hint.
// TAU_INSTALL_URL overrides the installer script URL (file:// stubs in
// tests, mirrors behind proxies). When an update exists the tag's own
// CHANGELOG.md is fetched too (TAU_CHANGELOG_URL overrides): the sections
// between the installed and target versions render as a pre-upgrade
// summary on stderr before the prompt/install and ride along as the
// report's "changelog" field — best-effort, a fetch/parse miss drops the
// summary, never the upgrade. Failed runs ("status":"failed", exit 1)
// carry a "hint" field with one-line remediation: lookup/download
// failures name the network or the TAU_*_URL overrides, and installer
// failures are classified from the install.sh error line (checksum
// mismatch -> distrust the mirror, download failed -> check the
// network/TAU_BASE_URL, unwritable dest -> --dir/TAU_INSTALL_DIR).
// The install destination resolves as
// --dir > TAU_INSTALL_DIR > the running binary's directory > the
// installer's own default. POSIX-only — Windows is told to re-run
// install.ps1 (exit 111, unimplemented).

const std = @import("std");
const builtin = @import("builtin");
const term = @import("term.zig");
const errs = @import("errors.zig");
const json = @import("json.zig");
const ver = @import("version.zig");
const update = @import("update.zig");
const cfgmod = @import("config.zig");
const Config = cfgmod.Config;

/// Outcome of a `tau upgrade` run — serialized as the "status" field.
/// Exit-code mapping: up_to_date/upgraded/declined/dry_run -> 0,
/// skipped/failed -> 1 (a script can tell "nothing was installed" apart
/// from a user decline).
pub const Status = enum {
    /// checked, already on the latest release.
    up_to_date,
    /// the installer ran and exited 0.
    upgraded,
    /// the user answered no at the TTY prompt.
    declined,
    /// the check was disabled, or a non-interactive run lacked --yes.
    skipped,
    /// the lookup, the installer download, or the install itself failed.
    failed,
    /// --dry-run: the resolved plan was reported, nothing was touched.
    dry_run,
};

/// One release-notes section lifted from the tag's CHANGELOG.md — the
/// `## [x.y.z]` heading version plus the section body verbatim.
pub const ChangelogEntry = struct {
    version: []const u8,
    notes: []const u8,
};

/// One upgrade result — serialized as a single JSON object on stdout.
pub const Report = struct {
    checked: bool,
    latest: ?[]const u8 = null,
    tag: ?[]const u8 = null,
    update_available: bool = false,
    status: Status,
    detail: []const u8,
    /// One-line remediation for a failed run — the flag, env var, or
    /// command that fixes it (the same convention the {"err"} envelope's
    /// "hint" field follows). Present only when status is "failed".
    hint: ?[]const u8 = null,
    release_url: ?[]const u8 = null,
    install_dir: ?[]const u8 = null,
    /// CHANGELOG sections between the installed and target versions;
    /// present only when the fetch produced at least one matching section.
    changelog: ?[]const ChangelogEntry = null,
};

/// Format the report as one JSON object. Dynamic strings (detail, paths)
/// go through json.escapeInto so the line stays valid no matter what the
/// environment holds.
pub fn formatReport(arena: std.mem.Allocator, r: Report) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(arena, "{\"name\":\"tau\",\"version\":\"");
    try buf.appendSlice(arena, ver.version);
    try buf.appendSlice(arena, "\",\"checked\":");
    try buf.appendSlice(arena, if (r.checked) "true" else "false");
    if (r.latest) |l| {
        try buf.appendSlice(arena, ",\"latest\":\"");
        try buf.appendSlice(arena, l);
        try buf.appendSlice(arena, "\"");
    }
    if (r.tag) |t| {
        try buf.appendSlice(arena, ",\"tag\":\"");
        try buf.appendSlice(arena, t);
        try buf.appendSlice(arena, "\"");
    }
    if (r.checked) {
        try buf.appendSlice(arena, ",\"update_available\":");
        try buf.appendSlice(arena, if (r.update_available) "true" else "false");
    }
    try buf.appendSlice(arena, ",\"status\":\"");
    try buf.appendSlice(arena, @tagName(r.status));
    try buf.appendSlice(arena, "\",\"detail\":\"");
    try json.escapeInto(arena, &buf, r.detail);
    try buf.appendSlice(arena, "\"");
    if (r.hint) |h| {
        try buf.appendSlice(arena, ",\"hint\":\"");
        try json.escapeInto(arena, &buf, h);
        try buf.appendSlice(arena, "\"");
    }
    if (r.release_url) |u| {
        try buf.appendSlice(arena, ",\"release_url\":\"");
        try json.escapeInto(arena, &buf, u);
        try buf.appendSlice(arena, "\"");
    }
    if (r.install_dir) |d| {
        try buf.appendSlice(arena, ",\"install_dir\":\"");
        try json.escapeInto(arena, &buf, d);
        try buf.appendSlice(arena, "\"");
    }
    if (r.changelog) |entries| {
        try buf.appendSlice(arena, ",\"changelog\":[");
        for (entries, 0..) |e, i| {
            if (i > 0) try buf.appendSlice(arena, ",");
            try buf.appendSlice(arena, "{\"version\":\"");
            try json.escapeInto(arena, &buf, e.version);
            try buf.appendSlice(arena, "\",\"notes\":\"");
            try json.escapeInto(arena, &buf, e.notes);
            try buf.appendSlice(arena, "\"}");
        }
        try buf.appendSlice(arena, "]");
    }
    try buf.appendSlice(arena, "}");
    return buf.items;
}

fn emit(arena: std.mem.Allocator, r: Report) void {
    const line = formatReport(arena, r) catch return;
    term.out(line);
    term.out("\n");
}

/// Installer script URL: TAU_INSTALL_URL override, else the install.sh
/// shipped at the release tag being installed.
pub fn installerUrl(arena: std.mem.Allocator, env: *std.process.Environ.Map, tag: []const u8) ![]u8 {
    if (env.get("TAU_INSTALL_URL")) |u| {
        if (u.len > 0) return arena.dupe(u8, u);
    }
    return std.fmt.allocPrint(arena, "https://raw.githubusercontent.com/javimosch/tau/{s}/install.sh", .{tag});
}

/// Install destination: --dir flag > TAU_INSTALL_DIR env > the running
/// binary's own directory ("in place") > null, which lets the installer
/// fall back to its own default (~/.local/bin).
pub fn resolveInstallDir(io: std.Io, arena: std.mem.Allocator, cfg: Config, env: *std.process.Environ.Map) ?[]const u8 {
    if (cfg.upgrade_dir) |d| {
        if (d.len > 0) return d;
    }
    if (env.get("TAU_INSTALL_DIR")) |d| {
        if (d.len > 0) return d;
    }
    const exe = std.process.executablePathAlloc(io, arena) catch return null;
    return std.fs.path.dirname(exe);
}

/// Changelog URL: TAU_CHANGELOG_URL override, else the CHANGELOG.md
/// shipped at the release tag being installed — the file CI regenerates
/// from the release notes users audit before upgrading.
pub fn changelogUrl(arena: std.mem.Allocator, env: *std.process.Environ.Map, tag: []const u8) ![]u8 {
    if (env.get("TAU_CHANGELOG_URL")) |u| {
        if (u.len > 0) return arena.dupe(u8, u);
    }
    return std.fmt.allocPrint(arena, "https://raw.githubusercontent.com/javimosch/tau/{s}/CHANGELOG.md", .{tag});
}

/// Version from a `## [x.y.z] - date` heading, or null for any other
/// heading shape (`## [Unreleased]`, `## Notes`). The brackets keep this
/// from matching plain-text `##` headings.
fn headingVersion(line: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, "## [")) return null;
    const close = std.mem.indexOfScalarPos(u8, line, 4, ']') orelse return null;
    const v = line[4..close];
    return if (v.len > 0) v else null;
}

/// true when `v` parses and falls in (current, latest] — the window a
/// pre-upgrade summary covers. Unparseable versions never match.
fn versionInRange(current: []const u8, v: []const u8, latest: []const u8) bool {
    const lo = update.compareVersions(current, v) orelse return false;
    const hi = update.compareVersions(v, latest) orelse return false;
    return lo == .lt and hi != .gt;
}

/// Lift the `## [x.y.z]` sections of a Keep-a-Changelog file whose version
/// falls in (current, latest], newest-first in file order. A section's
/// body runs to the next `## ` heading, a `[x.y.z]: url` link definition,
/// or EOF; `[Unreleased]` and unparseable headings never match the range.
pub fn changelogEntries(arena: std.mem.Allocator, text: []const u8, current: []const u8, latest: []const u8) ![]ChangelogEntry {
    var list: std.ArrayList(ChangelogEntry) = .empty;
    var sec_ver: []const u8 = "";
    var sec_start: usize = 0;
    var open = false;
    var pos: usize = 0;
    while (pos <= text.len) {
        const nl = std.mem.indexOfScalarPos(u8, text, pos, '\n') orelse text.len;
        const line = text[pos..nl];
        const is_head = std.mem.startsWith(u8, line, "## ");
        const is_linkdef = line.len > 2 and line[0] == '[' and
            std.mem.indexOf(u8, line, "]:") != null;
        if (is_head or is_linkdef) {
            if (open) {
                open = false;
                const body = std.mem.trim(u8, text[sec_start..pos], " \t\r\n");
                // Dupe into the arena: callers may free the source text
                // (the fetched changelog body) once parsing returns.
                if (body.len > 0 and versionInRange(current, sec_ver, latest))
                    try list.append(arena, .{
                        .version = try arena.dupe(u8, sec_ver),
                        .notes = try arena.dupe(u8, body),
                    });
            }
            if (is_head) {
                sec_ver = headingVersion(line) orelse "";
                sec_start = nl + 1;
                open = true;
            }
        }
        pos = nl + 1;
    }
    if (open) {
        // A trailing `## ` heading with no following line leaves
        // sec_start == text.len + 1 — clamp so the empty body is skipped.
        const body = std.mem.trim(u8, text[@min(sec_start, text.len)..text.len], " \t\r\n");
        if (body.len > 0 and versionInRange(current, sec_ver, latest))
            try list.append(arena, .{
                .version = try arena.dupe(u8, sec_ver),
                .notes = try arena.dupe(u8, body),
            });
    }
    return list.items;
}

/// Human-readable "what's new" preview for stderr — runs ahead of the
/// [y/N] prompt and the installer log so an upgrade is never a blind jump.
/// Plain text, never styled: the summary is informational, not a prompt.
pub fn formatChangelogSummary(arena: std.mem.Allocator, entries: []const ChangelogEntry, current: []const u8, latest: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(arena, try std.fmt.allocPrint(arena, "changes in tau {s} -> {s}:\n", .{ current, latest }));
    for (entries) |e| {
        try buf.appendSlice(arena, "[");
        try buf.appendSlice(arena, e.version);
        try buf.appendSlice(arena, "]\n");
        try buf.appendSlice(arena, e.notes);
        try buf.appendSlice(arena, "\n\n");
    }
    return buf.items;
}

/// Best-effort fetch of the tag's CHANGELOG.md and extraction of the
/// sections in (installed, latest]. Null when the fetch fails or no
/// section matches — the summary is advisory and never blocks the upgrade.
fn fetchChangelog(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, env: *std.process.Environ.Map, tag: []const u8, latest: []const u8) ?[]ChangelogEntry {
    const url = changelogUrl(arena, env, tag) catch return null;
    const body = update.fetchLatest(io, gpa, arena, url) orelse return null;
    defer gpa.free(body);
    const entries = changelogEntries(arena, body, ver.version, latest) catch return null;
    return if (entries.len == 0) null else entries;
}

/// Create a fresh $TMPDIR/tau-upgrade-<ts> staging dir; the caller removes
/// it with deleteTree. Null when no candidate name can be created.
fn stageDir(io: std.Io, arena: std.mem.Allocator, env: *std.process.Environ.Map) ?[]u8 {
    const base = env.get("TMPDIR") orelse "/tmp";
    const uniq: u64 = @intCast(@max(0, std.Io.Timestamp.now(io, .real).toNanoseconds()));
    var attempt: u64 = 0;
    while (attempt < 8) : (attempt += 1) {
        const path = std.fmt.allocPrint(arena, "{s}/tau-upgrade-{d}-{d}", .{ base, uniq, attempt }) catch return null;
        std.Io.Dir.cwd().createDirPath(io, path) catch |e| switch (e) {
            error.PathAlreadyExists => continue,
            else => return null,
        };
        return path;
    }
    return null;
}

/// Print the prompt on stderr and read one line from the (TTY) stdin
/// reader. Only an explicit y/yes approves; blank lines, EOF and read
/// errors decline — the same contract as `tau doctor --fix`.
fn confirm(r: *std.Io.Reader, prompt: []const u8) bool {
    term.err(prompt);
    const line = (r.takeDelimiter('\n') catch return false) orelse return false;
    const t = std.mem.trim(u8, line, " \t\r");
    return std.ascii.eqlIgnoreCase(t, "y") or std.ascii.eqlIgnoreCase(t, "yes");
}

/// Map a failed install.sh run's stderr to the one-line remediation hint
/// the report's "hint" field carries. Substring-matched against the
/// installer's own failure lines — that message set is a stable contract
/// documented in docs/troubleshooting.md ("Install & upgrade failures").
/// First match wins; unknown output gets the generic retry hint.
pub fn installerHint(stderr: []const u8) []const u8 {
    // Sigstore verification failures first — opt-in via --verify-signature /
    // TAU_VERIFY_SIGSTORE=1, every path fails closed.
    if (std.mem.indexOf(u8, stderr, "requires cosign on PATH") != null)
        return "signature verification needs cosign on PATH — install cosign (https://docs.sigstore.dev) and retry, or drop --verify-signature/TAU_VERIFY_SIGSTORE";
    if (std.mem.indexOf(u8, stderr, ".sigstore.json") != null)
        return "the release ships no cosign signature bundle for this asset — retry without --verify-signature, or point TAU_BASE_URL at a mirror that carries .sigstore.json files";
    if (std.mem.indexOf(u8, stderr, "sigstore signature verification failed") != null)
        return "the asset was not signed by the tau release workflow — distrust the mirror and retry; report persistent failures via `tau bug`";
    if (std.mem.indexOf(u8, stderr, "checksum verification failed") != null)
        return "the asset's SHA256 did not match the release manifest — retry; if it persists, distrust the mirror (do not bypass with TAU_SKIP_CHECKSUM=1 unless the source is trusted)";
    if (std.mem.indexOf(u8, stderr, "is not listed in SHA256SUMS") != null)
        return "the asset is missing from the release checksum manifest — fix the mirror or pick another version";
    if (std.mem.indexOf(u8, stderr, "could not download SHA256SUMS") != null)
        return "the release ships no checksum manifest — fix the mirror (TAU_SKIP_CHECKSUM=1 bypasses on a trusted source only)";
    if (std.mem.indexOf(u8, stderr, "no sha256sum") != null)
        return "no checksum tool on PATH — install coreutils (TAU_SKIP_CHECKSUM=1 bypasses on a trusted source only)";
    if (std.mem.indexOf(u8, stderr, "download failed") != null)
        return "the release asset could not be downloaded — check the network/proxy or TAU_BASE_URL mirror, then retry";
    if (std.mem.indexOf(u8, stderr, "failed to extract") != null)
        return "the downloaded archive is corrupt or truncated — retry; if it persists, distrust the mirror";
    if (std.mem.indexOf(u8, stderr, "cannot create install dir") != null or
        std.mem.indexOf(u8, stderr, "cannot write") != null)
        return "the install destination is not writable — pass --dir/TAU_INSTALL_DIR or fix permissions";
    if (std.mem.indexOf(u8, stderr, "unsupported OS") != null or
        std.mem.indexOf(u8, stderr, "unsupported architecture") != null)
        return "no prebuilt asset for this platform — build from source (see README 'Build & Install')";
    if (std.mem.indexOf(u8, stderr, "curl not found") != null or
        std.mem.indexOf(u8, stderr, "tar not found") != null)
        return "the installer needs curl and tar on PATH — install them or build from source";
    return "the installer failed — see its log on stderr, or install manually via install.sh";
}

/// The installer's environment: a clone of the caller's map with
/// TAU_VERIFY_SIGSTORE=1 injected when --verify-signature asked for it —
/// the flag is the discoverable spelling of the env contract install.sh
/// already honors. Null when no injection is needed (the child then
/// inherits the process env unchanged, so a user-set TAU_VERIFY_SIGSTORE
/// keeps flowing through untouched).
fn installerEnv(gpa: std.mem.Allocator, env: *std.process.Environ.Map, verify_signature: bool) !?std.process.Environ.Map {
    if (!verify_signature) return null;
    var child = try env.clone(gpa);
    errdefer child.deinit();
    try child.put("TAU_VERIFY_SIGSTORE", "1");
    return child;
}

/// Download the installer, stage it, run `sh install.sh --version <latest>
/// [--dir <d>]` and relay its progress to stderr so stdout stays a pure
/// JSON result. Returns the post-install Report (caller fills the release
/// fields and maps status to an exit code).
fn runInstaller(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, env: *std.process.Environ.Map, url: []const u8, latest: []const u8, dir: ?[]const u8, verify_signature: bool) Report {
    const fail = struct {
        fn f(status: Status, detail: []const u8, hint: []const u8, d: ?[]const u8) Report {
            return .{ .checked = true, .status = status, .detail = detail, .hint = hint, .install_dir = d };
        }
    }.f;

    const body = update.fetchLatest(io, gpa, arena, url) orelse
        return fail(.failed, std.fmt.allocPrint(arena, "installer download failed ({s})", .{url}) catch "installer download failed", "the release tag's install.sh could not be fetched — check the network/proxy or set TAU_INSTALL_URL to a reachable mirror, then retry", dir);
    defer gpa.free(body);

    const tmp = stageDir(io, arena, env) orelse
        return fail(.failed, "could not create a staging dir under TMPDIR", "set TMPDIR to a writable directory and retry", dir);
    defer std.Io.Dir.cwd().deleteTree(io, tmp) catch {};
    const script = std.fmt.allocPrint(arena, "{s}/install.sh", .{tmp}) catch
        return fail(.failed, "out of memory staging the installer", "set TMPDIR to a writable directory and retry", dir);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = script, .data = body }) catch
        return fail(.failed, "could not write the staged installer", "set TMPDIR to a writable directory and retry", dir);

    var argv: std.ArrayList([]const u8) = .empty;
    argv.appendSlice(arena, &.{ "sh", script, "--version", latest }) catch
        return fail(.failed, "out of memory building the installer command", "retry; if it persists, install manually via install.sh", dir);
    if (dir) |d| argv.appendSlice(arena, &.{ "--dir", d }) catch {};

    var child_env = installerEnv(gpa, env, verify_signature) catch
        return fail(.failed, "out of memory building the installer environment", "retry; if it persists, install manually via install.sh", dir);
    defer if (child_env) |*m| m.deinit();

    const res = std.process.run(gpa, io, .{
        .argv = argv.items,
        .environ_map = if (child_env) |*m| m else null,
        .stdout_limit = .unlimited,
        .stderr_limit = .unlimited,
    }) catch return fail(.failed, "could not launch the installer (sh not on PATH?)", "install.sh runs via sh — ensure a POSIX shell is on PATH, or run the installer manually", dir);
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);
    // The installer narrates on both streams; relay to stderr so our
    // stdout remains the single JSON result line.
    if (res.stdout.len > 0) term.err(res.stdout);
    if (res.stderr.len > 0) term.err(res.stderr);

    switch (res.term) {
        .exited => |code| {
            if (code == 0) {
                const dest = dir orelse "~/.local/bin";
                return .{
                    .checked = true,
                    .status = .upgraded,
                    .detail = std.fmt.allocPrint(arena, "installed tau {s} -> {s}/tau", .{ latest, dest }) catch "installed",
                    .install_dir = dir,
                };
            }
            return fail(.failed, std.fmt.allocPrint(arena, "installer exited {d} — see stderr for its log", .{code}) catch "installer failed", installerHint(res.stderr), dir);
        },
        else => return fail(.failed, "installer terminated abnormally", "retry; if it persists, run install.sh manually and file its log via `tau bug`", dir),
    }
}

/// Entry point. Prints one JSON report on stdout; returns the exit code.
pub fn run(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, cfg: Config, env: *std.process.Environ.Map) !u8 {
    if (builtin.os.tag == .windows) {
        errs.printErr(arena, errs.unimplemented, "tau upgrade is unsupported on this platform; re-run install.ps1 to update", .{});
        return 111;
    }

    const res = update.check(io, gpa, arena, env);
    if (!res.checked) {
        const disabled = res.reason != null and std.mem.startsWith(u8, res.reason.?, "disabled");
        emit(arena, .{
            .checked = false,
            .status = if (disabled) .skipped else .failed,
            .detail = res.reason orelse "release lookup unavailable",
            .hint = if (disabled) null else "the release lookup is unreachable — check the network/proxy (tau doctor reports proxy_env) or set TAU_UPDATE_URL to a reachable mirror, then retry",
        });
        return 1;
    }
    // checked but the tag could not be compared — there is nothing safe to
    // install, so this is a failure, not "up to date".
    const latest = res.latest orelse {
        emit(arena, .{
            .checked = true,
            .status = .failed,
            .detail = res.reason orelse "release tag not comparable",
            .hint = "the release payload's tag is not a usable version — file it via `tau bug`, or upgrade manually with install.sh",
        });
        return 1;
    };
    const tag = res.tag orelse latest;
    const release_url = if (res.update_available)
        update.releaseUrl(arena, tag) catch null
    else
        null;

    if (!res.update_available) {
        emit(arena, .{
            .checked = true,
            .latest = latest,
            .tag = tag,
            .status = .up_to_date,
            .detail = std.fmt.allocPrint(arena, "tau {s} is the latest release", .{ver.version}) catch "already up to date",
        });
        return 0;
    }

    const dir = resolveInstallDir(io, arena, cfg, env);
    const url = try installerUrl(arena, env, tag);

    // Pre-upgrade summary: the tag's CHANGELOG.md sections in (installed,
    // latest] — rendered on stderr for humans and carried in the report
    // for scripts. Best-effort; a fetch/parse miss changes nothing else.
    const changelog = fetchChangelog(io, gpa, arena, env, tag, latest);
    if (changelog) |entries| {
        const summary = formatChangelogSummary(arena, entries, ver.version, latest) catch null;
        if (summary) |s| term.err(s);
    }

    if (cfg.upgrade_dry_run) {
        emit(arena, .{
            .checked = true,
            .latest = latest,
            .tag = tag,
            .update_available = true,
            .status = .dry_run,
            .detail = if (cfg.upgrade_verify_signature)
                std.fmt.allocPrint(arena, "would install tau {s} via {s} into {s} after verifying the cosign signature (TAU_VERIFY_SIGSTORE=1)", .{ latest, url, dir orelse "the installer default (~/.local/bin)" }) catch "would install"
            else
                std.fmt.allocPrint(arena, "would install tau {s} via {s} into {s}", .{ latest, url, dir orelse "the installer default (~/.local/bin)" }) catch "would install",
            .release_url = release_url,
            .install_dir = dir,
            .changelog = changelog,
        });
        return 0;
    }

    const interactive = !cfg.upgrade_yes and (std.Io.File.stdin().isTty(io) catch false);
    const styled = interactive and term.colorEnabled(io, env, std.Io.File.stderr());
    var rbuf: [512]u8 = undefined;
    var fr = std.Io.File.stdin().reader(io, &rbuf);
    const prompt = std.fmt.allocPrint(arena, "upgrade: tau {s} -> {s} — install the update? [y/N] ", .{ ver.version, latest }) catch "upgrade? [y/N] ";
    const approved = cfg.upgrade_yes or
        (interactive and confirm(&fr.interface, term.sgrWrap(arena, prompt, "1", styled) catch prompt));
    if (!approved) {
        emit(arena, .{
            .checked = true,
            .latest = latest,
            .tag = tag,
            .update_available = true,
            .status = if (interactive) .declined else .skipped,
            .detail = if (interactive) "declined at prompt" else "not confirmed — pass --yes to upgrade non-interactively",
            .release_url = release_url,
            .install_dir = dir,
            .changelog = changelog,
        });
        return if (interactive) 0 else 1;
    }

    var rep = runInstaller(io, gpa, arena, env, url, latest, dir, cfg.upgrade_verify_signature);
    rep.latest = latest;
    rep.tag = tag;
    rep.update_available = true;
    rep.release_url = release_url;
    rep.changelog = changelog;
    emit(arena, rep);
    return switch (rep.status) {
        .upgraded => 0,
        else => 1,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
const testing = std.testing;

test "confirm: only y/yes approves; blank, other text and EOF decline" {
    var r_yes = std.Io.Reader.fixed("y\n");
    try testing.expect(confirm(&r_yes, "prompt"));
    var r_yes2 = std.Io.Reader.fixed(" YES \r\n");
    try testing.expect(confirm(&r_yes2, "prompt"));
    var r_no = std.Io.Reader.fixed("n\n");
    try testing.expect(!confirm(&r_no, "prompt"));
    var r_blank = std.Io.Reader.fixed("\n");
    try testing.expect(!confirm(&r_blank, "prompt"));
    var r_eof = std.Io.Reader.fixed("");
    try testing.expect(!confirm(&r_eof, "prompt"));
}

test "installerUrl: TAU_INSTALL_URL overrides; default tracks the tag" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();

    const def = try installerUrl(a, &env, "v9.9.9");
    try testing.expectEqualStrings("https://raw.githubusercontent.com/javimosch/tau/v9.9.9/install.sh", def);

    try env.put("TAU_INSTALL_URL", "file:///tmp/install.sh");
    try testing.expectEqualStrings("file:///tmp/install.sh", try installerUrl(a, &env, "v9.9.9"));

    try env.put("TAU_INSTALL_URL", "");
    try testing.expectEqualStrings(def, try installerUrl(a, &env, "v9.9.9"));
}

test "resolveInstallDir: flag > TAU_INSTALL_DIR > self-exe dir" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();

    var cfg = Config{};
    cfg.upgrade_dir = "/opt/bin";
    try env.put("TAU_INSTALL_DIR", "/env/bin");
    try testing.expectEqualStrings("/opt/bin", resolveInstallDir(testing.io, a, cfg, &env).?);

    cfg.upgrade_dir = null;
    try testing.expectEqualStrings("/env/bin", resolveInstallDir(testing.io, a, cfg, &env).?);

    _ = env.swapRemove("TAU_INSTALL_DIR");
    const d = resolveInstallDir(testing.io, a, cfg, &env);
    // The test runner has a real exe path with a dirname; we only pin that
    // the fallback resolves to a non-empty dir.
    try testing.expect(d != null and d.?.len > 0);
}

test "formatReport: pinned JSON shape for each outcome" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const up = try formatReport(a, .{
        .checked = true,
        .latest = "0.5.0",
        .tag = "v0.5.0",
        .update_available = true,
        .status = .upgraded,
        .detail = "installed tau 0.5.0 -> /home/u/.local/bin/tau",
        .release_url = "https://github.com/javimosch/tau/releases/tag/v0.5.0",
        .install_dir = "/home/u/.local/bin",
    });
    try testing.expectEqualStrings("{\"name\":\"tau\",\"version\":\"0.4.0\",\"checked\":true,\"latest\":\"0.5.0\",\"tag\":\"v0.5.0\",\"update_available\":true,\"status\":\"upgraded\",\"detail\":\"installed tau 0.5.0 -> /home/u/.local/bin/tau\",\"release_url\":\"https://github.com/javimosch/tau/releases/tag/v0.5.0\",\"install_dir\":\"/home/u/.local/bin\"}", up);

    const cur = try formatReport(a, .{
        .checked = true,
        .latest = "0.4.0",
        .tag = "v0.4.0",
        .status = .up_to_date,
        .detail = "tau 0.4.0 is the latest release",
    });
    try testing.expectEqualStrings("{\"name\":\"tau\",\"version\":\"0.4.0\",\"checked\":true,\"latest\":\"0.4.0\",\"tag\":\"v0.4.0\",\"update_available\":false,\"status\":\"up_to_date\",\"detail\":\"tau 0.4.0 is the latest release\"}", cur);

    const off = try formatReport(a, .{
        .checked = false,
        .status = .skipped,
        .detail = "disabled (TAU_NO_UPDATE_CHECK)",
    });
    try testing.expectEqualStrings("{\"name\":\"tau\",\"version\":\"0.4.0\",\"checked\":false,\"status\":\"skipped\",\"detail\":\"disabled (TAU_NO_UPDATE_CHECK)\"}", off);

    // detail strings with quotes/backslashes/newlines stay valid JSON.
    const esc = try formatReport(a, .{
        .checked = false,
        .status = .failed,
        .detail = "path \"c:\\dir\" not found\n",
    });
    try testing.expect(std.mem.indexOf(u8, esc, "\\\"c:\\\\dir\\\"") != null);
    try testing.expect(std.mem.indexOf(u8, esc, "not found\\n") != null);
}

test "formatReport: hint serializes after detail, absent when null" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const rep = try formatReport(a, .{
        .checked = false,
        .status = .failed,
        .detail = "release lookup failed (http://127.0.0.1:1/)",
        .hint = "check the network, then retry",
    });
    try testing.expect(std.mem.indexOf(u8, rep, "\"status\":\"failed\",\"detail\":\"release lookup failed (http://127.0.0.1:1/)\",\"hint\":\"check the network, then retry\"") != null);

    // Hints keep the JSON valid when they carry quotes.
    const esc = try formatReport(a, .{
        .checked = true,
        .status = .failed,
        .detail = "installer exited 1",
        .hint = "say \"no\" to TAU_SKIP_CHECKSUM",
    });
    try testing.expect(std.mem.indexOf(u8, esc, "\\\"no\\\"") != null);
}

test "installerHint: install.sh failure lines map to remediation hints" {
    const H = struct {
        fn has(haystack: []const u8, needle: []const u8) bool {
            return std.mem.indexOf(u8, haystack, needle) != null;
        }
    };

    // Checksum mismatch -> distrust-the-mirror guidance, not a bypass.
    const ck = installerHint("install.sh: checksum verification failed for tau-linux-x86_64.tar.gz — the download is corrupted or tampered; aborting\n");
    try testing.expect(H.has(ck, "SHA256"));
    try testing.expect(H.has(ck, "TAU_SKIP_CHECKSUM"));

    // A mirror missing the manifest vs the asset missing from the manifest.
    try testing.expect(H.has(installerHint("install.sh: could not download SHA256SUMS.txt for release v9.9.9\n"), "no checksum manifest"));
    try testing.expect(H.has(installerHint("install.sh: tau-linux-x86_64.tar.gz is not listed in SHA256SUMS.txt\n"), "missing from the release checksum manifest"));

    // Interrupted/missing download -> network/mirror retry.
    try testing.expect(H.has(installerHint("install.sh: download failed — check that release v9.9.9 ships tau-linux-x86_64.tar.gz\n"), "could not be downloaded"));

    // Truncated archive that passed a regenerated manifest -> extract fail.
    try testing.expect(H.has(installerHint("install.sh: failed to extract tau-linux-x86_64.tar.gz\n"), "corrupt or truncated"));

    // Destination + platform + prerequisite failures.
    try testing.expect(H.has(installerHint("install.sh: cannot write /root/bin/tau\n"), "not writable"));
    try testing.expect(H.has(installerHint("install.sh: unsupported OS 'FreeBSD'\n"), "no prebuilt asset"));
    try testing.expect(H.has(installerHint("install.sh: curl not found on PATH\n"), "curl and tar"));

    // Unknown installer output falls back to the generic retry hint.
    try testing.expect(H.has(installerHint("install.sh: something else broke\n"), "install.sh"));

    // Sigstore opt-in failures — every path fails closed with actionable
    // guidance back at the flag/env spelling.
    try testing.expect(H.has(installerHint("install.sh: TAU_VERIFY_SIGSTORE=1 requires cosign on PATH — install cosign or unset TAU_VERIFY_SIGSTORE\n"), "cosign"));
    try testing.expect(H.has(installerHint("install.sh: could not download tau-linux-x86_64.tar.gz.sigstore.json for v9.9.9\n"), "signature bundle"));
    try testing.expect(H.has(installerHint("install.sh: sigstore signature verification failed for tau-linux-x86_64.tar.gz\n"), "not signed"));
}

test "installerEnv: --verify-signature injects TAU_VERIFY_SIGSTORE=1" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("KEEP", "me");

    // Flag off -> no override map (the child inherits the process env).
    try testing.expect((try installerEnv(a, &env, false)) == null);

    // Flag on -> cloned env plus the contract var; the caller's map is
    // untouched.
    var child = (try installerEnv(a, &env, true)).?;
    defer child.deinit();
    try testing.expectEqualStrings("1", child.get("TAU_VERIFY_SIGSTORE").?);
    try testing.expectEqualStrings("me", child.get("KEEP").?);
    try testing.expect(env.get("TAU_VERIFY_SIGSTORE") == null);

    // An explicit TAU_VERIFY_SIGSTORE=0 loses to the flag.
    try env.put("TAU_VERIFY_SIGSTORE", "0");
    var forced = (try installerEnv(a, &env, true)).?;
    defer forced.deinit();
    try testing.expectEqualStrings("1", forced.get("TAU_VERIFY_SIGSTORE").?);
}

test "formatReport: changelog entries serialize as {version,notes} objects" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const entries = [_]ChangelogEntry{
        .{ .version = "0.5.0", .notes = "### Added\n- new thing" },
        .{ .version = "0.4.1", .notes = "### Fixed\n- a \"quoted\" bug" },
    };
    const rep = try formatReport(a, .{
        .checked = true,
        .latest = "0.5.0",
        .tag = "v0.5.0",
        .update_available = true,
        .status = .dry_run,
        .detail = "would install",
        .changelog = &entries,
    });
    try testing.expect(std.mem.indexOf(u8, rep, "\"changelog\":[{\"version\":\"0.5.0\",\"notes\":\"### Added\\n- new thing\"},{\"version\":\"0.4.1\",\"notes\":\"### Fixed\\n- a \\\"quoted\\\" bug\"}]}") != null);

    // Absent field when no summary was produced.
    const none = try formatReport(a, .{
        .checked = true,
        .latest = "0.5.0",
        .tag = "v0.5.0",
        .update_available = true,
        .status = .dry_run,
        .detail = "would install",
    });
    try testing.expect(std.mem.indexOf(u8, none, "changelog") == null);
}

test "changelogUrl: TAU_CHANGELOG_URL overrides; default tracks the tag" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();

    const def = try changelogUrl(a, &env, "v9.9.9");
    try testing.expectEqualStrings("https://raw.githubusercontent.com/javimosch/tau/v9.9.9/CHANGELOG.md", def);

    try env.put("TAU_CHANGELOG_URL", "file:///tmp/CHANGELOG.md");
    try testing.expectEqualStrings("file:///tmp/CHANGELOG.md", try changelogUrl(a, &env, "v9.9.9"));

    try env.put("TAU_CHANGELOG_URL", "");
    try testing.expectEqualStrings(def, try changelogUrl(a, &env, "v9.9.9"));
}

test "changelogEntries: lifts in-range sections, newest first" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const text =
        \\# Changelog
        \\
        \\## [Unreleased]
        \\
        \\### Added
        \\- work in progress
        \\
        \\## [99.9.9] - 2027-01-01
        \\
        \\### Added
        \\- shiny feature
        \\- another one
        \\
        \\## [0.5.0] - 2026-12-01
        \\
        \\### Fixed
        \\- mid-range fix
        \\
        \\[99.9.9]: https://example.com/rel/99.9.9
        \\[0.5.0]: https://example.com/rel/0.5.0
        \\## [0.4.0] - 2026-06-12
        \\
        \\### Added
        \\- already installed
        \\
    ;

    const entries = try changelogEntries(a, text, "0.4.0", "99.9.9");
    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expectEqualStrings("99.9.9", entries[0].version);
    try testing.expectEqualStrings("### Added\n- shiny feature\n- another one", entries[0].notes);
    try testing.expectEqualStrings("0.5.0", entries[1].version);
    try testing.expectEqualStrings("### Fixed\n- mid-range fix", entries[1].notes);

    // A single-step range picks just the target section.
    const step = try changelogEntries(a, text, "0.5.0", "99.9.9");
    try testing.expectEqual(@as(usize, 1), step.len);
    try testing.expectEqualStrings("99.9.9", step[0].version);

    // Nothing in range -> empty (the report omits the field).
    const none = try changelogEntries(a, text, "0.4.0", "0.4.0");
    try testing.expectEqual(@as(usize, 0), none.len);
}

test "changelogEntries: heading edge cases and missing trailing newline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Last section ends at EOF without a newline; a plain `## ` heading
    // closes a section but never matches the range itself.
    const entries = try changelogEntries(a, "## [0.5.0] - 2026-01-01\n- item\n## Notes\n## [0.4.0]\n- old", "0.3.0", "0.5.0");
    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expectEqualStrings("0.5.0", entries[0].version);
    try testing.expectEqualStrings("- item", entries[0].notes);
    try testing.expectEqualStrings("0.4.0", entries[1].version);

    // A dangling heading at EOF is just skipped.
    const dangle = try changelogEntries(a, "## [0.5.0]", "0.3.0", "0.5.0");
    try testing.expectEqual(@as(usize, 0), dangle.len);
}

test "formatChangelogSummary: header + per-version labeled notes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const entries = [_]ChangelogEntry{
        .{ .version = "0.5.0", .notes = "### Added\n- x" },
    };
    const s = try formatChangelogSummary(a, &entries, "0.4.0", "0.5.0");
    try testing.expectEqualStrings("changes in tau 0.4.0 -> 0.5.0:\n[0.5.0]\n### Added\n- x\n\n", s);
}
