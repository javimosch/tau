const std = @import("std");
const cfgmod = @import("config.zig");
const Config = cfgmod.Config;

/// Mirror of the persisted config schema — every key optional so missing keys
/// fall back to the in-code default. Unknown keys are ignored.
const FileConfig = struct {
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

/// Build the config-file path: <HOME>/.config/tau/config.json. Returns null if
/// HOME is unset.
pub fn path(arena: std.mem.Allocator, env: *std.process.Environ.Map) ?[]u8 {
    const home = env.get("HOME") orelse return null;
    return std.fmt.allocPrint(arena, "{s}/.config/tau/config.json", .{home}) catch null;
}

/// Load ~/.config/tau/config.json into a base Config. Missing file / bad JSON /
/// no HOME all degrade gracefully to defaults (never errors — config file is
/// optional). The returned Config is meant to be passed to args.parse as `base`
/// so CLI flags override it.
pub fn load(io: std.Io, arena: std.mem.Allocator, env: *std.process.Environ.Map) Config {
    var cfg: Config = .{};
    const p = path(arena, env) orelse return cfg;
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, p, arena, .unlimited) catch return cfg;
    const fc = std.json.parseFromSliceLeaky(FileConfig, arena, bytes, .{
        .ignore_unknown_fields = true,
    }) catch {
        cfg.config_warning = std.fmt.allocPrint(arena, "config file has invalid JSON and was ignored: {s} — fix the JSON syntax or delete the file", .{p}) catch null;
        return cfg;
    };

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
