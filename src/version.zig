const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

/// tau package version. Single source of truth so CLI, JSON output and ACP
/// `agentInfo` all report the same value.
pub const version = "0.4.0";

/// Canonical troubleshooting doc URL. Embedded in every `{"err":...}` envelope
/// so agents and humans can jump straight from an error to the fix list.
pub const troubleshooting_doc_url = "https://github.com/javimosch/tau/blob/master/docs/troubleshooting.md";

/// Provider credentials + auth troubleshooting doc URL. `AuthFailed` envelopes
/// link here instead of the generic troubleshooting page.
pub const providers_doc_url = "https://github.com/javimosch/tau/blob/master/docs/providers.md";

/// Build metadata baked in by build.zig + comptime `builtin` queries. Surfaced
/// by `tau version --verbose`, the `tau doctor` report/verdict "build" field,
/// and the --debug log header — the triage trio that lets a bug report say
/// exactly which binary produced it.
pub const build = struct {
    /// Short git hash of HEAD at build time ("unknown" for tarball builds;
    /// "-dirty" suffix marks a worktree with uncommitted changes).
    pub const commit: []const u8 = build_options.git_commit;
    /// `arch-os-abi` target triple, e.g. "x86_64-linux-gnu".
    pub const target: []const u8 = std.fmt.comptimePrint("{t}-{t}-{t}", .{
        builtin.target.cpu.arch, builtin.target.os.tag, builtin.target.abi,
    });
    /// UTC build stamp `YYYY-MM-DDTHH:MM:SSZ`. Honors SOURCE_DATE_EPOCH so
    /// reproducible release builds embed a fixed date instead of wall-clock.
    pub const date: []const u8 = build_options.build_date;
    /// Zig compiler version that produced this binary, e.g. "0.16.0".
    pub const zig: []const u8 = std.fmt.comptimePrint("{f}", .{builtin.zig_version});
};

/// `{"commit":"…","target":"…","build_date":"…","zig":"…"}` — the shared
/// "build" object spliced into the doctor report/verdict and (with name +
/// version) the `version --verbose` JSON output. Values are ASCII-only (hex,
/// tag names, digits, `T`/`Z`/`:`) so no escaping is needed.
pub fn buildJson(a: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(a,
        "{{\"commit\":\"{s}\",\"target\":\"{s}\",\"build_date\":\"{s}\",\"zig\":\"{s}\"}}",
        .{ build.commit, build.target, build.date, build.zig });
}

/// `commit=<c> target=<t> date=<d> zig=<z>` — one-line form for the --debug
/// log header.
pub fn buildLine(a: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(a, "commit={s} target={s} date={s} zig={s}", .{
        build.commit, build.target, build.date, build.zig,
    });
}

test "version is a non-empty dotted triple" {
    try @import("std").testing.expect(version.len > 0);
    try @import("std").testing.expectEqualStrings("0.4.0", version);
}

test "build metadata fields are populated" {
    try std.testing.expect(build.commit.len > 0);
    try std.testing.expect(build.target.len > 0);
    try std.testing.expect(build.date.len > 0);
    try std.testing.expect(build.zig.len > 0);
    // Target triple is three non-empty arch-os-abi tags.
    var it = std.mem.splitScalar(u8, build.target, '-');
    try std.testing.expect(it.next() != null);
    try std.testing.expect(it.next() != null);
    try std.testing.expect(it.next() != null);
}

test "buildJson carries all four keys" {
    const a = std.testing.allocator;
    const got = try buildJson(a);
    defer a.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"commit\":\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"target\":\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"build_date\":\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"zig\":\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, build.target) != null);
    try std.testing.expect(std.mem.indexOf(u8, got, build.zig) != null);
}

test "buildLine is the key=value one-liner for log headers" {
    const a = std.testing.allocator;
    const got = try buildLine(a);
    defer a.free(got);
    try std.testing.expect(std.mem.startsWith(u8, got, "commit="));
    try std.testing.expect(std.mem.indexOf(u8, got, " target=") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, " date=") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, " zig=") != null);
}
