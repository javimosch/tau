const std = @import("std");
const provider_mod = @import("llm/provider.zig");

pub const OutputMode = enum { text, json };

/// Which /goal sub-action the prompt requested (if any).
/// `resume_` avoids the Zig `resume` keyword; maps to the "resume" subcommand.
pub const GoalAction = enum { none, set, status, pause, resume_, clear, complete };

/// ACP (Agent Client Protocol) subcommand for `tau acp <sub>`.
pub const AcpSub = enum { serve, start, stop, status };

/// Role for an Author↔Critic loop turn. `none` is the default (plain agent).
/// `author` and `critic` get role-specific sentinels and tool allowlists; the
/// fleet coordinator uses a planner role that emits no tools and produces a
/// JSON work breakdown.
pub const Role = enum { none, author, critic, coordinator };

// Re-export provider table from llm/provider.zig
pub const Provider = provider_mod.Provider;
pub const providers = provider_mod.providers;
pub const findProvider = provider_mod.findProvider;
pub const formatProviderJson = provider_mod.formatProviderJson;

pub const Config = struct {
    provider: []const u8 = provider_mod.providers[0].name,
    endpoint: []const u8 = provider_mod.providers[0].endpoint,
    model: []const u8 = provider_mod.providers[0].default_model,
    api_key: ?[]const u8 = null,
    /// Global api_key from config file (below per-provider keys in precedence).
    config_api_key: ?[]const u8 = null,
    /// Per-provider API keys from config file's "keys" object.
    keys: ?std.StringHashMap([]const u8) = null,
    prompt: ?[]const u8 = null,
    system_prompt: ?[]const u8 = null,
    mode: OutputMode = .json,
    /// Stream the response token-by-token (SSE). Implies a pure chat turn with
    /// no tools (tool_call assembly is not streamed). text mode streams raw
    /// deltas; json mode streams NDJSON {"chunk":..,"done":false} then a final
    /// {"done":true}.
    stream: bool = true,
    no_tools: bool = false,
    /// Allowlist of tool names (null = all built-ins enabled). Owned elsewhere.
    tools_allow: ?[]const []const u8 = null,
    /// Denylist of tool names. Owned elsewhere.
    tools_deny: ?[]const []const u8 = null,
    /// Enable thinking chunks in output (shows model reasoning)
    thinking: bool = false,
    /// Debug mode: show perf stats and tool calls (input+output)
    debug: bool = false,
    /// Dry run: do one planning turn and report the tool calls the model would
    /// make, without executing any of them.
    dry_run: bool = false,
    temperature: f32 = 0.7,
    max_tokens: ?u32 = null,
    // Reasoning models routinely take >30s; default generously (the old 30s
    // limit was the real cause of the "exit 110" blocker).
    timeout_ms: i64 = 120_000,
    /// Runaway backstop for the (non-goal) agentic tool loop. The turn normally
    /// ends when the model stops calling tools (like Claude Code / OpenCode);
    /// on hitting this cap, a final tool-free summary answer is forced.
    max_iterations: u32 = 100,

    // --- ACP (Agent Client Protocol) ---
    acp_sub: AcpSub = .serve,
    /// Unix socket path for the ACP daemon (null = stdio for `serve`).
    acp_socket: ?[]const u8 = null,

    // --- Session management ---
    /// Named session; persists conversation + goal to ~/.config/tau/sessions/<name>.json.
    /// null = stateless single-shot (legacy behavior).
    session: ?[]const u8 = null,

    // --- Goal mode ---
    /// Goal objective text (set when the prompt is "/goal <objective>").
    goal: ?[]const u8 = null,
    /// Which /goal action the prompt requested.
    goal_action: GoalAction = .none,
    /// Per-run agentic loop cap when working a goal (normal loop stays 10).
    goal_max_iterations: u32 = 50,
    /// Cross-invocation continuation cap (skill parity).
    goal_max_continues: u32 = 500,
    /// Optional soft output-token budget (/goal --tokens N).
    token_budget: ?u64 = null,

    // --- Author↔Critic loop (loop.zig) ---
    /// Current turn's role. When not .none, agent.zig injects the role-specific
    /// directive and uses `exit_sentinel` as the termination token.
    role: Role = .none,
    /// Override the goal-mode exit sentinel. Used by the Author↔Critic loop
    /// (READY_FOR_REVIEW / APPROVED / BLOCKED). When null and goal_action is
    /// .set, the default `<GOAL_MET>` is used.
    exit_sentinel: ?[]const u8 = null,
    /// Optional feedback string prepended to the next user turn. Used by the
    /// loop to inject Critic feedback into the Author's next pass.
    feedback_message: ?[]const u8 = null,

    // --- Fleet (fleet.zig) ---
    /// `tau fleet <run|status|list|logs|cancel>` subcommand selector. Null means
    /// the CLI was not invoked as a fleet subcommand.
    fleet_sub: ?[]const u8 = null,
    /// Fleet id (when subcommand needs one). Required for status/logs/cancel.
    fleet_id: ?[]const u8 = null,
    /// Fleet goal text (only for `fleet run`).
    fleet_goal: ?[]const u8 = null,
    /// Optional pre-supplied items JSON (skips the coordinator LLM turn).
    fleet_items: ?[]const u8 = null,
    /// Worker parallelism (default true).
    fleet_parallel: bool = true,
    /// Optional model override for the coordinator turn.
    coordinator_model: ?[]const u8 = null,
    /// Optional model override for worker turns.
    worker_model: ?[]const u8 = null,

    // --- Schema structured output ---
    /// JSON Schema for structured output. When set, the model is constrained
    /// to produce valid JSON matching this schema (via response_format).
    /// Can be inline JSON or prefixed with @ to load from a file.
    schema: ?[]const u8 = null,

    // --- AGENTS.md scanning ---
    /// If true, scan CWD for AGENTS.md files on startup (lazy: stat + first line only).
    scan_agents: bool = false,
    /// If set, load this AGENTS.md file content into the system prompt.
    load_agents_md: ?[]const u8 = null,
    /// If true, auto-inject the root-level AGENTS.md (cwd/AGENTS.md) on startup.
    auto_agents_md: bool = false,

    // --- Skills autodiscovery ---
    /// `tau skills <list|search|load>` subcommand selector. Null means no skills subcommand.
    skills_sub: ?[]const u8 = null,
    /// Argument to the skills subcommand (e.g. skill name for `load`, query for `search`).
    skills_arg: ?[]const u8 = null,

    // --- Context compaction ---
    /// Model context window in tokens; 256k when unknown. Used for the compaction threshold.
    context_window: u32 = 256_000,
    /// Auto-compact the message history when it grows too large.
    auto_compact: bool = true,
    /// Compact when estimated tokens exceed this fraction of context_window.
    compact_threshold: f32 = 0.5,
    /// Tokens of recent history kept verbatim during compaction (pi default).
    compact_keep_recent_tokens: u32 = 20_000,

    /// Set by configfile.load() when the config file exists but has invalid JSON.
    /// main.zig emits a warning and continues with defaults.
    config_warning: ?[]const u8 = null,
};

/// Resolve the effective API key. Precedence:
/// 1. `--api-key` (explicit flag)
/// 2. config `keys[selected_provider]`
/// 3. provider env var(s)
/// 4. config global `api_key`
/// 5. `TAU_API_KEY`
/// 6. provider builtin / keyless
pub fn resolveApiKey(cfg: Config, env: *std.process.Environ.Map) ?[]const u8 {
    // 1. --api-key (explicit flag)
    if (cfg.api_key) |k| return k;

    // 2. config keys[selected_provider]
    if (cfg.keys) |keys_map| {
        if (keys_map.get(cfg.provider)) |k| {
            if (k.len > 0) return k;
        }
    }

    // 3. provider env var(s)
    if (findProvider(cfg.provider)) |p| {
        for (p.env_keys) |ek| {
            if (env.get(ek)) |v| {
                if (v.len > 0) return v;
            }
        }
    }

    // 4. config global api_key
    if (cfg.config_api_key) |k| return k;

    // 5. TAU_API_KEY
    if (env.get("TAU_API_KEY")) |v| {
        if (v.len > 0) return v;
    }

    // 6. provider builtin
    if (findProvider(cfg.provider)) |p| {
        if (p.builtin_key) |bk| return bk;
    }

    return null;
}

const testing = std.testing;

test "resolveApiKey: explicit --api-key wins all lower levels" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = std.process.Environ.Map.init(alloc);
    try env.put("OPENAI_API_KEY", "env-key");
    try env.put("TAU_API_KEY", "tau-key");
    const cfg = Config{ .provider = "openai", .api_key = "explicit-key", .config_api_key = "global-key" };
    try testing.expectEqualStrings("explicit-key", resolveApiKey(cfg, &env).?);
}

test "resolveApiKey: config keys map beats provider env var" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = std.process.Environ.Map.init(alloc);
    try env.put("OPENAI_API_KEY", "env-key");
    var km = std.StringHashMap([]const u8).init(alloc);
    try km.put("openai", "map-key");
    const cfg = Config{ .provider = "openai", .keys = km };
    try testing.expectEqualStrings("map-key", resolveApiKey(cfg, &env).?);
}

test "resolveApiKey: provider env var is used when no higher source present" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var env = std.process.Environ.Map.init(arena.allocator());
    try env.put("OPENAI_API_KEY", "env-key");
    try env.put("TAU_API_KEY", "tau-key");
    const cfg = Config{ .provider = "openai" };
    try testing.expectEqualStrings("env-key", resolveApiKey(cfg, &env).?);
}

test "resolveApiKey: second provider env key is tried when first absent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var env = std.process.Environ.Map.init(arena.allocator());
    try env.put("PIZIG_API_KEY", "pizig-key");
    const cfg = Config{ .provider = "xiaomi" };
    try testing.expectEqualStrings("pizig-key", resolveApiKey(cfg, &env).?);
}

test "resolveApiKey: config_api_key beats TAU_API_KEY" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var env = std.process.Environ.Map.init(arena.allocator());
    try env.put("TAU_API_KEY", "tau-key");
    const cfg = Config{ .provider = "openai", .config_api_key = "global-key" };
    try testing.expectEqualStrings("global-key", resolveApiKey(cfg, &env).?);
}

test "resolveApiKey: TAU_API_KEY used as last resort before null" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var env = std.process.Environ.Map.init(arena.allocator());
    try env.put("TAU_API_KEY", "tau-key");
    const cfg = Config{ .provider = "openai" };
    try testing.expectEqualStrings("tau-key", resolveApiKey(cfg, &env).?);
}

test "resolveApiKey: returns null when no key available" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var env = std.process.Environ.Map.init(arena.allocator());
    const cfg = Config{ .provider = "openai" };
    try testing.expect(resolveApiKey(cfg, &env) == null);
}

test "resolveApiKey: empty string env values are skipped" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var env = std.process.Environ.Map.init(arena.allocator());
    try env.put("OPENAI_API_KEY", "");
    try env.put("TAU_API_KEY", "tau-key");
    const cfg = Config{ .provider = "openai" };
    try testing.expectEqualStrings("tau-key", resolveApiKey(cfg, &env).?);
}
