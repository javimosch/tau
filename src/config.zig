const std = @import("std");
const provider_mod = @import("llm/provider.zig");

pub const OutputMode = enum { text, json };

/// Which /goal sub-action the prompt requested (if any).
/// `resume_` avoids the Zig `resume` keyword; maps to the "resume" subcommand.
pub const GoalAction = enum { none, set, status, pause, resume_, clear, complete };

/// ACP (Agent Client Protocol) subcommand for `tau acp <sub>`.
pub const AcpSub = enum { serve, start, stop, status };

// Re-export provider table from llm/provider.zig
pub const Provider = provider_mod.Provider;
pub const providers = provider_mod.providers;
pub const findProvider = provider_mod.findProvider;

pub const Config = struct {
    provider: []const u8 = provider_mod.providers[0].name,
    endpoint: []const u8 = provider_mod.providers[0].endpoint,
    model: []const u8 = provider_mod.providers[0].default_model,
    api_key: ?[]const u8 = null,
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

    // --- Context compaction ---
    /// Model context window in tokens; 256k when unknown. Used for the compaction threshold.
    context_window: u32 = 256_000,
    /// Auto-compact the message history when it grows too large.
    auto_compact: bool = true,
    /// Compact when estimated tokens exceed this fraction of context_window.
    compact_threshold: f32 = 0.5,
    /// Tokens of recent history kept verbatim during compaction (pi default).
    compact_keep_recent_tokens: u32 = 20_000,
};

/// Resolve the effective API key. Precedence: explicit `--api-key` (or config
/// file `api_key`) > provider-specific env var(s) > global TAU_API_KEY > provider
/// builtin key (none ship by default). No key is hardcoded in the binary.
pub fn resolveApiKey(cfg: Config, env: *std.process.Environ.Map) ?[]const u8 {
    if (cfg.api_key) |k| return k;
    if (findProvider(cfg.provider)) |p| {
        for (p.env_keys) |ek| {
            if (env.get(ek)) |v| {
                if (v.len > 0) return v;
            }
        }
        if (p.builtin_key) |bk| return bk;
    }
    if (env.get("TAU_API_KEY")) |v| {
        if (v.len > 0) return v;
    }
    return null;
}
