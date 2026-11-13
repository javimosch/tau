const std = @import("std");
const cfgmod = @import("config.zig");
const Config = cfgmod.Config;

/// Mirror of the persisted config schema — every key optional so missing keys
/// fall back to the in-code default. Unknown keys are ignored.
/// `pub` so `tau config validate` can derive its checks from the same struct
/// (single source of truth for the file schema).
pub const FileConfig = struct {
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    /// Per-provider API keys: provider-name → api-key string.
    keys: ?std.json.Value = null,
    mode: ?[]const u8 = null, // "text" | "json"
    stream: ?bool = null,
    thinking: ?bool = null,
    debug: ?bool = null,
    temperature: ?f32 = null,
    max_tokens: ?u32 = null,
    timeout_ms: ?i64 = null,
    context_window: ?u32 = null,
    auto_compact: ?bool = null,
    compact_threshold: ?f32 = null,
    compact_keep_recent_tokens: ?u32 = null,
    goal_max_iterations: ?u32 = null,
    goal_max_continues: ?u32 = null,
};

/// One deprecated config-key spelling and the canonical key that replaced it.
/// Config-key renames follow the deprecation policy in docs/stability.md:
/// during the overlap window the old spelling still loads (the canonical key
/// wins when both are present) and the load raises a {"warn"} envelope naming
/// the replacement; `tau config validate` reports the member with a position
/// and `tau doctor --fix` rewrites the file. `old` is a top-level member name
/// that is never a FileConfig field — canonical keys are; deprecated
/// spellings stay out of the published schema so editors flag them. Nested
/// renames (keys.<provider>) are out of scope for now.
pub const RenamedKey = struct {
    /// The deprecated top-level member name.
    old: []const u8,
    /// Its replacement — always a FileConfig field name (compile-checked).
    new: []const u8,
    /// Where the spelling came from (shown in warnings/docs).
    note: []const u8,
};

/// The registry of deprecated/renamed config keys. Seeded with the
/// --compact-keep-recent flag spelling: it reads naturally inside
/// config.json but was never a config key — before the deprecation machinery
/// existed it was silently ignored, so honoring it now can only deliver the
/// value the file's author intended. Future key renames add a row here (and
/// drop the old FileConfig field when the overlap window closes).
pub const renamed_keys = [_]RenamedKey{
    .{
        .old = "compact_keep_recent",
        .new = "compact_keep_recent_tokens",
        .note = "the --compact-keep-recent flag spelling, honored as a compatibility alias",
    },
};

comptime {
    const fields = @typeInfo(FileConfig).@"struct".fields;
    for (renamed_keys) |rk| {
        var is_field = false;
        for (fields) |f| {
            if (std.mem.eql(u8, f.name, rk.new)) is_field = true;
            if (std.mem.eql(u8, f.name, rk.old))
                @compileError("renamed_keys: '" ++ rk.old ++ "' must not be a FileConfig field — deprecated spellings live outside the schema");
        }
        if (!is_field)
            @compileError("renamed_keys: '" ++ rk.new ++ "' is not a FileConfig field — the canonical key must be");
    }
}

/// Look up a deprecated spelling by member name. Returns the registry entry
/// or null when `old` is a current (or unknown) key.
pub fn renamedKey(old: []const u8) ?RenamedKey {
    for (renamed_keys) |rk| {
        if (std.mem.eql(u8, old, rk.old)) return rk;
    }
    return null;
}

/// Build the config-file path: <HOME>/.config/tau/config.json. Returns null if
/// HOME is unset.
pub fn path(arena: std.mem.Allocator, env: *std.process.Environ.Map) ?[]u8 {
    const home = env.get("HOME") orelse return null;
    return std.fmt.allocPrint(arena, "{s}/.config/tau/config.json", .{home}) catch null;
}

/// Remove JSONC-style comments (`//` line and `/* */` block) so the strict
/// std.json parser accepts a commented config file (e.g. one written by
/// `tau init`). Newlines inside comments are preserved so line numbers stay
/// stable. Comment markers inside string literals are kept verbatim.
pub fn stripComments(arena: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    var in_string = false;
    while (i < bytes.len) {
        const c = bytes[i];
        if (in_string) {
            try out.append(arena, c);
            if (c == '\\' and i + 1 < bytes.len) {
                i += 1;
                try out.append(arena, bytes[i]);
            } else if (c == '"') {
                in_string = false;
            }
            i += 1;
            continue;
        }
        if (c == '"') {
            in_string = true;
            try out.append(arena, c);
            i += 1;
            continue;
        }
        if (c == '/' and i + 1 < bytes.len) {
            if (bytes[i + 1] == '/') {
                // Line comment: drop up to (not including) the newline.
                i += 2;
                while (i < bytes.len and bytes[i] != '\n') i += 1;
                continue;
            }
            if (bytes[i + 1] == '*') {
                // Block comment: keep newlines so line numbers stay stable.
                i += 2;
                while (i + 1 < bytes.len and !(bytes[i] == '*' and bytes[i + 1] == '/')) {
                    if (bytes[i] == '\n') try out.append(arena, '\n');
                    i += 1;
                }
                i = if (i + 1 < bytes.len) i + 2 else bytes.len; // skip */ or EOF
                continue;
            }
        }
        try out.append(arena, c);
        i += 1;
    }
    return out.toOwnedSlice(arena);
}

/// Position of a JSON syntax error (1-based, like std.json.Diagnostics).
pub const JsonPos = struct { line: usize, col: usize };

/// Line/column of the first JSON syntax error in `bytes`, or null when the
/// document parses. The file is JSONC: comments are stripped before the
/// strict scan — stripComments preserves newlines, so line numbers always
/// match the original file (columns can differ only when a block comment
/// precedes the error on the same line — the same caveat `config validate`
/// reports under).
pub fn jsonErrorPos(arena: std.mem.Allocator, bytes: []const u8) ?JsonPos {
    const stripped = stripComments(arena, bytes) catch bytes;
    var scanner = std.json.Scanner.initCompleteInput(arena, stripped);
    defer scanner.deinit();
    var diag: std.json.Diagnostics = .{};
    scanner.enableDiagnostics(&diag);
    _ = std.json.parseFromTokenSourceLeaky(std.json.Value, arena, &scanner, .{}) catch |err| {
        if (err == error.OutOfMemory) return null;
        return .{ .line = diag.getLine(), .col = diag.getColumn() };
    };
    return null;
}

/// 1-based line/column of a byte offset into the ORIGINAL file bytes — used
/// to position findings on members located by configedit.scanDoc (offsets
/// are always into raw, comment-included bytes, so positions are exact).
pub fn offsetPos(bytes: []const u8, off: usize) JsonPos {
    var pos: JsonPos = .{ .line = 1, .col = 1 };
    var i: usize = 0;
    while (i < off and i < bytes.len) : (i += 1) {
        if (bytes[i] == '\n') {
            pos.line += 1;
            pos.col = 1;
        } else {
            pos.col += 1;
        }
    }
    return pos;
}

/// Load ~/.config/tau/config.json into a base Config. Missing file / bad JSON /
/// no HOME all degrade gracefully to defaults (never errors — config file is
/// optional). JSONC-style comments (`//`, `/* */`) are stripped before parsing.
/// The returned Config is meant to be passed to args.parse as `base` so CLI
/// flags override it.
pub fn load(io: std.Io, arena: std.mem.Allocator, env: *std.process.Environ.Map) Config {
    var cfg: Config = .{};
    const p = path(arena, env) orelse return cfg;
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, p, arena, .unlimited) catch return cfg;
    // File exists and was read; record the path even if the JSON below fails
    // to parse (config_warning carries that) so `tau doctor`/`tau config show`
    // can report it.
    cfg.config_path = p;
    const stripped = stripComments(arena, bytes) catch bytes;
    var fc = std.json.parseFromSliceLeaky(FileConfig, arena, stripped, .{
        .ignore_unknown_fields = true,
    }) catch {
        cfg.config_warning = if (jsonErrorPos(arena, bytes)) |pos|
            std.fmt.allocPrint(arena, "config file has invalid JSON at line {d}, column {d} and was ignored: {s} — fix the JSON syntax or delete the file", .{ pos.line, pos.col, p }) catch null
        else
            std.fmt.allocPrint(arena, "config file has invalid JSON and was ignored: {s} — fix the JSON syntax or delete the file", .{p}) catch null;
        return cfg;
    };

    // Deprecated spellings (renamed_keys) still load during the deprecation
    // window: when the canonical key is absent the alias member's value is
    // coerced onto its canonical field — a value of the wrong JSON kind is
    // left unhonored rather than breaking the whole load (validate reports
    // it). Either way the deprecated member raises a deprecation warning.
    if (renamed_keys.len > 0) {
        const root: ?std.json.Value = if (std.json.parseFromSliceLeaky(std.json.Value, arena, stripped, .{})) |r| r else |_| null;
        var dep_list: std.ArrayList(u8) = .empty;
        var dep_count: usize = 0;
        if (root) |r| {
            if (r == .object) {
                inline for (renamed_keys) |rk| {
                    if (r.object.get(rk.old)) |mv| {
                        dep_count += 1;
                        if (dep_list.items.len > 0) dep_list.appendSlice(arena, ", ") catch {};
                        dep_list.appendSlice(arena, std.fmt.allocPrint(arena, "\"{s}\" (renamed to \"{s}\")", .{ rk.old, rk.new }) catch rk.old) catch {};
                        const FT = @FieldType(FileConfig, rk.new);
                        const InnerT = @typeInfo(FT).optional.child;
                        if (@field(fc, rk.new) == null) {
                            if (std.json.parseFromValueLeaky(InnerT, arena, mv, .{})) |v| {
                                @field(fc, rk.new) = v;
                            } else |_| {}
                        }
                    }
                }
            }
        }
        if (dep_list.items.len > 0) {
            cfg.config_warning = std.fmt.allocPrint(arena, "config file {s} uses deprecated {s} {s} — the old spelling still loads during the deprecation window; run 'tau doctor --fix' to migrate", .{ p, if (dep_count > 1) "keys" else "key", dep_list.items }) catch null;
        }
    }


    if (fc.provider) |v| cfg.provider = v;
    if (fc.model) |v| {
        cfg.model = v;
        cfg.model_set = true;
    }
    if (fc.api_key) |v| cfg.config_api_key = v;
    if (fc.mode) |v| {
        if (std.mem.eql(u8, v, "text")) cfg.mode = .text else if (std.mem.eql(u8, v, "json")) cfg.mode = .json;
    }
    if (fc.stream) |v| cfg.stream = v;
    if (fc.thinking) |v| cfg.thinking = v;
    if (fc.debug) |v| cfg.debug = v;
    if (fc.temperature) |v| cfg.temperature = v;
    if (fc.max_tokens) |v| cfg.max_tokens = v;
    if (fc.timeout_ms) |v| cfg.timeout_ms = v;
    if (fc.context_window) |v| {
        cfg.context_window = v;
        cfg.context_window_set = true;
    }
    if (fc.auto_compact) |v| cfg.auto_compact = v;
    if (fc.compact_threshold) |v| cfg.compact_threshold = v;
    if (fc.compact_keep_recent_tokens) |v| cfg.compact_keep_recent_tokens = v;
    if (fc.goal_max_iterations) |v| cfg.goal_max_iterations = v;
    if (fc.goal_max_continues) |v| cfg.goal_max_continues = v;
    if (fc.keys) |keys_val| {
        if (keys_val == .object) {
            var km = std.StringHashMap([]const u8).init(arena);
            var it = keys_val.object.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.* == .string) {
                    km.put(entry.key_ptr.*, entry.value_ptr.*.string) catch {};
                }
            }
            cfg.keys = km;
        }
    }
    return cfg;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
const testing = std.testing;

/// A throwaway HOME rooted at a fresh tmp dir, with `<HOME>/.config/tau`
/// created so a config.json can be dropped in. `load`/`path` read it via
/// std.Io.Dir.cwd(), so HOME is a path (relative to the test cwd) — that is
/// fine because readFileAlloc resolves it against cwd.
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

    /// Drop a config.json into <HOME>/.config/tau with the given raw bytes.
    fn writeConfig(self: *TestHome, arena: std.mem.Allocator, content: []const u8) !void {
        const p = try std.fmt.allocPrint(arena, "{s}/.config/tau/config.json", .{self.home});
        try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = p, .data = content });
    }

    fn deinit(self: *TestHome) void {
        self.tmp.cleanup();
    }
};

test "load: missing config file degrades to defaults" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var th = try TestHome.init(arena);
    defer th.deinit();
    // No config.json written.

    const cfg = load(testing.io, arena, &th.env);
    try testing.expectEqualStrings(cfgmod.providers[0].name, cfg.provider);
    try testing.expectEqualStrings(cfgmod.providers[0].default_model, cfg.model);
    try testing.expectEqual(cfgmod.OutputMode.json, cfg.mode);
    try testing.expectEqual(true, cfg.stream);
    try testing.expectEqual(@as(?[]const u8, null), cfg.config_api_key);
    try testing.expectEqual(@as(?std.StringHashMap([]const u8), null), cfg.keys);
}

test "load: no HOME degrades to defaults" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var env = std.process.Environ.Map.init(arena);
    // HOME deliberately absent → path() returns null.
    const cfg = load(testing.io, arena, &env);
    try testing.expectEqualStrings(cfgmod.providers[0].name, cfg.provider);
    try testing.expectEqual(cfgmod.OutputMode.json, cfg.mode);
}

test "load: malformed JSON degrades to defaults" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var th = try TestHome.init(arena);
    defer th.deinit();
    try th.writeConfig(arena, "{ this is not valid json ");

    const cfg = load(testing.io, arena, &th.env);
    try testing.expectEqualStrings(cfgmod.providers[0].name, cfg.provider);
    try testing.expectEqual(cfgmod.OutputMode.json, cfg.mode);
    try testing.expectEqual(true, cfg.stream);
}

test "load: string key overrides (provider, model, api_key)" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var th = try TestHome.init(arena);
    defer th.deinit();
    try th.writeConfig(arena,
        \\{ "provider": "openai", "model": "gpt-x", "api_key": "sk-file" }
    );

    const cfg = load(testing.io, arena, &th.env);
    try testing.expectEqualStrings("openai", cfg.provider);
    try testing.expectEqualStrings("gpt-x", cfg.model);
    try testing.expect(cfg.model_set);
    // api_key in the file maps onto config_api_key (not the --api-key flag slot).
    try testing.expectEqualStrings("sk-file", cfg.config_api_key.?);
    try testing.expectEqual(@as(?[]const u8, null), cfg.api_key);
}

test "load: mode string maps to the OutputMode enum" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    {
        var th = try TestHome.init(arena);
        defer th.deinit();
        try th.writeConfig(arena,
            \\{ "mode": "text" }
        );
        const cfg = load(testing.io, arena, &th.env);
        try testing.expectEqual(cfgmod.OutputMode.text, cfg.mode);
    }
    {
        var th = try TestHome.init(arena);
        defer th.deinit();
        try th.writeConfig(arena,
            \\{ "mode": "json" }
        );
        const cfg = load(testing.io, arena, &th.env);
        try testing.expectEqual(cfgmod.OutputMode.json, cfg.mode);
    }
    {
        // Unrecognized mode leaves the default (.json) untouched.
        var th = try TestHome.init(arena);
        defer th.deinit();
        try th.writeConfig(arena,
            \\{ "mode": "yaml" }
        );
        const cfg = load(testing.io, arena, &th.env);
        try testing.expectEqual(cfgmod.OutputMode.json, cfg.mode);
    }
}

test "load: bool and numeric key overrides" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var th = try TestHome.init(arena);
    defer th.deinit();
    try th.writeConfig(arena,
        \\{
        \\  "stream": false,
        \\  "thinking": true,
        \\  "debug": true,
        \\  "temperature": 0.25,
        \\  "max_tokens": 4096,
        \\  "timeout_ms": 9000,
        \\  "context_window": 128000,
        \\  "auto_compact": false,
        \\  "compact_threshold": 0.75,
        \\  "compact_keep_recent_tokens": 8000,
        \\  "goal_max_iterations": 12,
        \\  "goal_max_continues": 34
        \\}
    );

    const cfg = load(testing.io, arena, &th.env);
    try testing.expectEqual(false, cfg.stream);
    try testing.expectEqual(true, cfg.thinking);
    try testing.expectEqual(true, cfg.debug);
    try testing.expectEqual(@as(f32, 0.25), cfg.temperature);
    try testing.expectEqual(@as(?u32, 4096), cfg.max_tokens);
    try testing.expectEqual(@as(i64, 9000), cfg.timeout_ms);
    try testing.expectEqual(@as(u32, 128000), cfg.context_window);
    try testing.expect(cfg.context_window_set);
    try testing.expectEqual(false, cfg.auto_compact);
    try testing.expectEqual(@as(f32, 0.75), cfg.compact_threshold);
    try testing.expectEqual(@as(u32, 8000), cfg.compact_keep_recent_tokens);
    try testing.expectEqual(@as(u32, 12), cfg.goal_max_iterations);
    try testing.expectEqual(@as(u32, 34), cfg.goal_max_continues);
}

test "load: per-provider keys object builds a string map" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var th = try TestHome.init(arena);
    defer th.deinit();
    try th.writeConfig(arena,
        \\{ "keys": { "openai": "sk-oai", "anthropic": "sk-ant", "broken": 123 } }
    );

    const cfg = load(testing.io, arena, &th.env);
    try testing.expect(cfg.keys != null);
    var km = cfg.keys.?;
    try testing.expectEqualStrings("sk-oai", km.get("openai").?);
    try testing.expectEqualStrings("sk-ant", km.get("anthropic").?);
    // Non-string values are skipped rather than poisoning the map.
    try testing.expectEqual(@as(?[]const u8, null), km.get("broken"));
}

test "load: unknown keys are ignored, known keys still applied" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var th = try TestHome.init(arena);
    defer th.deinit();
    try th.writeConfig(arena,
        \\{ "provider": "groq", "totally_unknown_field": 42, "nested": { "x": 1 } }
    );

    const cfg = load(testing.io, arena, &th.env);
    try testing.expectEqualStrings("groq", cfg.provider);
    // Unrecognized fields don't disturb defaults.
    try testing.expectEqual(cfgmod.OutputMode.json, cfg.mode);
}

test "load: config_path records the read file, stays null when absent" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var th = try TestHome.init(arena);
    defer th.deinit();

    // No file yet → config_path stays null.
    var cfg = load(testing.io, arena, &th.env);
    try testing.expectEqual(@as(?[]const u8, null), cfg.config_path);

    // After writing the file, config_path points at it — even for invalid JSON.
    try th.writeConfig(arena, "{ not json ");
    cfg = load(testing.io, arena, &th.env);
    const want = try std.fmt.allocPrint(arena, "{s}/.config/tau/config.json", .{th.home});
    try testing.expectEqualStrings(want, cfg.config_path.?);
    try testing.expect(cfg.config_warning != null);
}

test "path: builds <HOME>/.config/tau/config.json and is null without HOME" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var env = std.process.Environ.Map.init(arena);
    try env.put("HOME", "/home/tester");
    const p = path(arena, &env).?;
    try testing.expectEqualStrings("/home/tester/.config/tau/config.json", p);

    var empty = std.process.Environ.Map.init(arena);
    try testing.expectEqual(@as(?[]u8, null), path(arena, &empty));
}

test "stripComments removes // and /* */ comments but keeps // inside strings" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const got = try stripComments(arena,
        \\// leading comment
        \\{
        \\  "provider": "openai", // trailing comment
        \\  "api_key": "https://host//path", /* block
        \\  comment */ "mode": "text"
        \\} // tail at EOF
    );
    // Comment markers inside the URL string survive; everything else is gone.
    try testing.expect(std.mem.indexOf(u8, got, "https://host//path") != null);
    try testing.expect(std.mem.indexOf(u8, got, "leading comment") == null);
    try testing.expect(std.mem.indexOf(u8, got, "trailing comment") == null);
    try testing.expect(std.mem.indexOf(u8, got, "block") == null);
    try testing.expect(std.mem.indexOf(u8, got, "tail at EOF") == null);
    // And the stripped text is valid JSON with the fields intact.
    const fc = try std.json.parseFromSliceLeaky(FileConfig, arena, got, .{ .ignore_unknown_fields = true });
    try testing.expectEqualStrings("openai", fc.provider.?);
    try testing.expectEqualStrings("https://host//path", fc.api_key.?);
    try testing.expectEqualStrings("text", fc.mode.?);
}

test "stripComments respects escaped chars and unterminated comments" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // `\\` inside a string is an escaped backslash, so the following `"` is the
    // real closer — a naive scanner that ignores escapes would stay in-string.
    const got = try stripComments(arena, "{ \"a\": \"x\\\\\" } // tail");
    const fc = try std.json.parseFromSliceLeaky(std.json.Value, arena, got, .{});
    try testing.expectEqualStrings("x\\", fc.object.get("a").?.string);

    // `//` inside a string value is preserved verbatim.
    const got2 = try stripComments(arena, "{ \"a\": \"x // inside\" } // outside");
    const fc2 = try std.json.parseFromSliceLeaky(std.json.Value, arena, got2, .{});
    try testing.expectEqualStrings("x // inside", fc2.object.get("a").?.string);

    // An unterminated line comment at EOF just truncates.
    try testing.expectEqualStrings("{} ", try stripComments(arena, "{} // rest is gone"));
}

test "jsonErrorPos: reports line/column of the first syntax error" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // Clean document -> null.
    try testing.expectEqual(@as(?JsonPos, null), jsonErrorPos(arena, "{ \"a\": 1 }"));

    // Error on line 3.
    const pos = jsonErrorPos(arena, "{\n  \"provider\": \"openai\",\n  bad\n}").?;
    try testing.expectEqual(@as(usize, 3), pos.line);
    try testing.expect(pos.col >= 1);

    // Comments don't shift line numbers (newlines preserved by stripComments).
    const pos2 = jsonErrorPos(arena, "// header\n{\n  /* block\n     comment */\n  \"a\":,\n}").?;
    try testing.expectEqual(@as(usize, 5), pos2.line);
}

test "load: malformed JSON warning carries line/column context" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var th = try TestHome.init(arena);
    defer th.deinit();
    try th.writeConfig(arena, "{\n  \"provider\": \"openai\",\n  bad\n}");

    const cfg = load(testing.io, arena, &th.env);
    const w = cfg.config_warning.?;
    try testing.expect(std.mem.indexOf(u8, w, "invalid JSON at line 3, column") != null);
    try testing.expect(std.mem.indexOf(u8, w, "was ignored") != null);
    try testing.expect(std.mem.indexOf(u8, w, th.home) != null);
}

test "load: commented (JSONC) config file parses cleanly" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var th = try TestHome.init(arena);
    defer th.deinit();
    try th.writeConfig(arena,
        \\// starter config
        \\{
        \\  "provider": "deepseek", // inline note
        \\  /* "model": "ignored", */
        \\  "mode": "text"
        \\}
    );

    const cfg = load(testing.io, arena, &th.env);
    try testing.expectEqualStrings("deepseek", cfg.provider);
    try testing.expectEqual(cfgmod.OutputMode.text, cfg.mode);
    // No invalid-JSON warning was produced.
    try testing.expectEqual(@as(?[]const u8, null), cfg.config_warning);
}

test "load: deprecated spelling loads onto the canonical key with a warning" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var th = try TestHome.init(arena);
    defer th.deinit();
    try th.writeConfig(arena,
        \\{ "compact_keep_recent": 8000 }
    );

    const cfg = load(testing.io, arena, &th.env);
    // The alias is honored during the deprecation window…
    try testing.expectEqual(@as(u32, 8000), cfg.compact_keep_recent_tokens);
    // …and a warning names the rename.
    const w = cfg.config_warning.?;
    try testing.expect(std.mem.indexOf(u8, w, "deprecated key \"compact_keep_recent\"") != null);
    try testing.expect(std.mem.indexOf(u8, w, "compact_keep_recent_tokens") != null);
    try testing.expect(std.mem.indexOf(u8, w, "tau doctor --fix") != null);
}

test "load: canonical key wins over the deprecated spelling" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var th = try TestHome.init(arena);
    defer th.deinit();
    try th.writeConfig(arena,
        \\{ "compact_keep_recent": 8000, "compact_keep_recent_tokens": 4000 }
    );

    const cfg = load(testing.io, arena, &th.env);
    try testing.expectEqual(@as(u32, 4000), cfg.compact_keep_recent_tokens);
    // The deprecated member still warns — it's dead config to migrate.
    try testing.expect(cfg.config_warning != null);
}

test "load: deprecated spelling with a wrong-typed value is not honored" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var th = try TestHome.init(arena);
    defer th.deinit();
    try th.writeConfig(arena,
        \\{ "compact_keep_recent": "lots", "provider": "openai" }
    );

    const cfg = load(testing.io, arena, &th.env);
    // The rest of the file still loads — a bad alias never poisons it.
    try testing.expectEqualStrings("openai", cfg.provider);
    try testing.expectEqual(@as(u32, 20000), cfg.compact_keep_recent_tokens);
    try testing.expect(cfg.config_warning != null);
}

test "renamedKey: resolves the registry entries, nothing else" {
    const rk = renamedKey("compact_keep_recent").?;
    try testing.expectEqualStrings("compact_keep_recent_tokens", rk.new);
    try testing.expect(rk.note.len > 0);
    try testing.expect(renamedKey("compact_keep_recent_tokens") == null);
    try testing.expect(renamedKey("bogus") == null);
}

test "offsetPos: 1-based line/column of a byte offset" {
    const pos = offsetPos("{\n  \"k\": 1\n}", 4);
    try testing.expectEqual(@as(usize, 2), pos.line);
    try testing.expectEqual(@as(usize, 3), pos.col);
    const first = offsetPos("{\n  \"k\": 1\n}", 0);
    try testing.expectEqual(@as(usize, 1), first.line);
    try testing.expectEqual(@as(usize, 1), first.col);
}
