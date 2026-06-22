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
    }) catch return cfg;

    if (fc.provider) |v| cfg.provider = v;
    if (fc.model) |v| cfg.model = v;
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
    if (fc.context_window) |v| cfg.context_window = v;
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
