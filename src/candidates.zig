//! `tau completions candidates <group>` — dynamic completion candidates for
//! the shipped shell scripts. Emits one candidate per line on stdout; the
//! scripts invoke this at completion time so `tau config get|set|unset <key>`
//! positions offer values computed from the live config file instead of a
//! hardcoded list.
//!
//! Groups:
//!   config-set    — every key `tau config set` accepts: each FileConfig
//!                   field plus keys.<provider> for every live provider.
//!   config-get    — keys actually present in the resolved config file
//!   config-unset  —   ($HOME/.config/tau/config.json): each top-level
//!                   member plus keys.<member> for entries inside `keys`.
//!                   Missing/unreadable/invalid file -> no candidates.
//!   doctor-check  — every check id `tau doctor --check <id>` and
//!                   `tau doctor --fix <id>` resolve: the static report rows
//!                   plus client_<name> and probe_<provider>[/_auth].
//!
//! Deliberately a plain line list, not a --json contract surface: output is
//! consumed by compgen/compadd/fish -a/CompletionResult inside completion
//! functions, never parsed as JSON.

const std = @import("std");
const cfgmod = @import("config.zig");
const configfile = @import("configfile.zig");
const configedit = @import("configedit.zig");
const doctorcatalog = @import("doctorcatalog.zig");
const term = @import("term.zig");

const file_fields = @typeInfo(configfile.FileConfig).@"struct".fields;

/// The candidate groups `tau completions candidates` accepts.
pub const groups = [_][]const u8{ "config-set", "config-get", "config-unset", "doctor-check" };

pub fn isGroup(name: []const u8) bool {
    for (groups) |g| {
        if (std.mem.eql(u8, name, g)) return true;
    }
    return false;
}

/// "a | b | c" join of the group names, for error messages.
pub fn groupNames(arena: std.mem.Allocator) ![]u8 {
    var b: std.ArrayList(u8) = .empty;
    for (groups, 0..) |g, i| {
        if (i != 0) try b.appendSlice(arena, " | ");
        try b.appendSlice(arena, g);
    }
    return b.toOwnedSlice(arena);
}

/// Emit the group's candidates — one per line — on stdout. The group is
/// validated at parse time; an unvalidated name emits nothing. Exit 0.
pub fn run(io: std.Io, arena: std.mem.Allocator, env: *std.process.Environ.Map, group: []const u8) !u8 {
    const keys = if (std.mem.eql(u8, group, "config-set"))
        try setKeys(arena)
    else if (std.mem.eql(u8, group, "config-get") or std.mem.eql(u8, group, "config-unset"))
        try fileKeys(io, arena, env)
    else if (std.mem.eql(u8, group, "doctor-check"))
        try checkIds(arena)
    else
        &.{};
    for (keys) |k| {
        term.out(k);
        term.out("\n");
    }
    return 0;
}

/// `config set` candidates — FileConfig fields in declaration order, then
/// `keys.<provider>` per live provider (the only dotted key form the config
/// file accepts). Mirrors configedit's strict set-time key check, so the
/// list cannot drift from what the command actually accepts.
pub fn setKeys(arena: std.mem.Allocator) ![][]const u8 {
    var keys: std.ArrayList([]const u8) = .empty;
    inline for (file_fields) |f| try keys.append(arena, f.name);
    for (cfgmod.providers) |p|
        try keys.append(arena, try std.fmt.allocPrint(arena, "keys.{s}", .{p.name}));
    return keys.items;
}

/// `config get|unset` candidates — the members present in the resolved
/// config file, in file order. get/unset accept any key that exists in the
/// file (configedit only strict-checks `set`), so unknown and deprecated
/// spellings complete too. `keys` is emitted as a whole plus one
/// `keys.<member>` per entry inside it. Any read or parse failure yields
/// zero candidates — completion stays silent rather than guessing.
pub fn fileKeys(io: std.Io, arena: std.mem.Allocator, env: *std.process.Environ.Map) ![][]const u8 {
    var keys: std.ArrayList([]const u8) = .empty;
    const path = configfile.path(arena, env) orelse return keys.items;
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited) catch return keys.items;
    const obj = configedit.scanDoc(arena, bytes) catch return keys.items;
    for (obj.members) |m| {
        try keys.append(arena, m.key);
        if (std.mem.eql(u8, m.key, "keys") and m.value_start < bytes.len and bytes[m.value_start] == '{') {
            const inner = configedit.scanObj(arena, bytes, m.value_start) catch continue;
            for (inner.members) |im|
                try keys.append(arena, try std.fmt.allocPrint(arena, "keys.{s}", .{im.key}));
        }
    }
    return keys.items;
}

/// `doctor --check|--fix <id>` candidates — the bare check ids from the
/// doctorcatalog registry (static rows, then client_<name>, then
/// probe_<provider> and probe_<provider>_auth). The catalog is the same pool
/// `--check` resolves through findCheck and `--fix` resolves through the
/// emitted row names, so the candidates can't drift from accepted spellings.
/// The `doctor.` prefix is offered neither here nor required — both flags
/// take the bare id.
pub fn checkIds(arena: std.mem.Allocator) ![][]const u8 {
    const ids = try arena.alloc([]const u8, doctorcatalog.check_catalog.len);
    for (doctorcatalog.check_catalog, 0..) |cs, i| ids[i] = cs.name;
    return ids;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Throwaway HOME rooted at a fresh tmp dir; env map carries only HOME so
/// fileKeys resolves $HOME/.config/tau/config.json like a real run.
const TestHome = struct {
    tmp: testing.TmpDir,
    env: std.process.Environ.Map,
    home: []const u8,

    fn init(arena: std.mem.Allocator) !TestHome {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const home = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
        const dir = try std.fmt.allocPrint(arena, "{s}/.config/tau", .{home});
        try std.Io.Dir.cwd().createDirPath(testing.io, dir);
        var env = std.process.Environ.Map.init(arena);
        try env.put("HOME", home);
        return .{ .tmp = tmp, .env = env, .home = home };
    }

    fn writeConfig(self: *TestHome, arena: std.mem.Allocator, content: []const u8) !void {
        const p = try std.fmt.allocPrint(arena, "{s}/.config/tau/config.json", .{self.home});
        try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = p, .data = content });
    }

    fn deinit(self: *TestHome) void {
        self.tmp.cleanup();
    }
};

fn hasKey(keys: []const []const u8, name: []const u8) bool {
    for (keys) |k| {
        if (std.mem.eql(u8, k, name)) return true;
    }
    return false;
}

test "isGroup + groupNames cover exactly the registered groups" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    try testing.expect(isGroup("config-set"));
    try testing.expect(isGroup("config-get"));
    try testing.expect(isGroup("config-unset"));
    try testing.expect(isGroup("doctor-check"));
    try testing.expect(!isGroup("config"));
    try testing.expect(!isGroup("doctor"));
    try testing.expect(!isGroup("bogus"));
    try testing.expectEqualStrings("config-set | config-get | config-unset | doctor-check", try groupNames(arena));
}

test "setKeys: every FileConfig field plus keys.<provider>, no $schema" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const keys = try setKeys(arena);
    try testing.expectEqual(file_fields.len + cfgmod.providers.len, keys.len);
    inline for (file_fields) |f| try testing.expect(hasKey(keys, f.name));
    for (cfgmod.providers) |p| {
        const want = try std.fmt.allocPrint(arena, "keys.{s}", .{p.name});
        try testing.expect(hasKey(keys, want));
    }
    // $schema is a file member, not a settable key — strict set rejects it.
    try testing.expect(!hasKey(keys, "$schema"));
}

test "fileKeys: no HOME, missing file, and invalid JSON all yield nothing" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var env = std.process.Environ.Map.init(arena);
    try testing.expectEqual(@as(usize, 0), (try fileKeys(testing.io, arena, &env)).len);

    var th = try TestHome.init(arena);
    defer th.deinit();
    try testing.expectEqual(@as(usize, 0), (try fileKeys(testing.io, arena, &th.env)).len);

    try th.writeConfig(arena, "{ this is not json");
    try testing.expectEqual(@as(usize, 0), (try fileKeys(testing.io, arena, &th.env)).len);
}

test "fileKeys: file members in order plus keys.<member> entries" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var th = try TestHome.init(arena);
    defer th.deinit();
    // JSONC comments are part of the file — the scanner tolerates them, and
    // unknown + deprecated members still complete (get/unset accept them).
    try th.writeConfig(arena,
        \\// starter config
        \\{
        \\  "$schema": "https://example.invalid/schema.json",
        \\  "provider": "openai",
        \\  "compact_keep_recent": 100,
        \\  "keys": { "openai": "sk-x", "deepseek": "sk-y" },
        \\  "custom_user_key": 1
        \\}
    );

    const keys = try fileKeys(testing.io, arena, &th.env);
    const expected = [_][]const u8{
        "$schema",           "provider",  "compact_keep_recent",
        "keys",              "keys.openai", "keys.deepseek",
        "custom_user_key",
    };
    try testing.expectEqual(expected.len, keys.len);
    for (expected, 0..) |want, i| try testing.expectEqualStrings(want, keys[i]);
}

test "fileKeys: keys member that is not an object contributes no dotted names" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var th = try TestHome.init(arena);
    defer th.deinit();
    try th.writeConfig(arena, "{\"keys\": \"oops\", \"mode\": \"text\"}\n");

    const keys = try fileKeys(testing.io, arena, &th.env);
    try testing.expectEqual(@as(usize, 2), keys.len);
    try testing.expectEqualStrings("keys", keys[0]);
    try testing.expectEqualStrings("mode", keys[1]);
}

test "checkIds: every doctorcatalog entry as a bare id, each resolvable" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const ids = try checkIds(arena);
    try testing.expectEqual(doctorcatalog.check_catalog.len, ids.len);
    for (doctorcatalog.check_catalog, 0..) |cs, i| {
        try testing.expectEqualStrings(cs.name, ids[i]);
        // Every offered id resolves the way `--check` resolves it.
        try testing.expect(doctorcatalog.findCheck(ids[i]) != null);
        // The `doctor.` prefix is an explain spelling, not a check id.
        try testing.expect(!std.mem.startsWith(u8, ids[i], "doctor."));
    }
}
