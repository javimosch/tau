const std = @import("std");

pub const OutputMode = enum { text, json };

pub const Provider = struct {
    name: []const u8,
    endpoint: []const u8,
    default_model: []const u8,
    env_keys: []const []const u8 = &.{},
    builtin_key: ?[]const u8 = null,
};

// STOPGAP provider table (M1). The main agent's llm/provider.zig may supersede
// or extend this (e.g. Anthropic's /v1/messages schema). It lives here so the
// argument parser can resolve `--provider` to an endpoint without yet depending
// on the provider module. All entries below speak the OpenAI
// /v1/chat/completions wire format.
pub const providers = [_]Provider{
    .{
        .name = "xiaomi",
        .endpoint = "https://token-plan-ams.xiaomimimo.com/v1/chat/completions",
        .default_model = "mimo-v2.5",
        .env_keys = &.{ "PIZIG_API_KEY", "XIAOMI_API_KEY" },
        .builtin_key = "tp-ejau4ye7ifigruk0ji0r5xul1nk00vwc9i1m32jdstxpcg52",
    },
    .{
        .name = "openai",
        .endpoint = "https://api.openai.com/v1/chat/completions",
        .default_model = "gpt-4o-mini",
        .env_keys = &.{"OPENAI_API_KEY"},
    },
    .{
        .name = "deepseek",
        .endpoint = "https://api.deepseek.com/v1/chat/completions",
        .default_model = "deepseek-chat",
        .env_keys = &.{"DEEPSEEK_API_KEY"},
    },
};

pub fn findProvider(name: []const u8) ?*const Provider {
    for (&providers) |*p| {
        if (std.mem.eql(u8, p.name, name)) return p;
    }
    return null;
}

pub const Config = struct {
    provider: []const u8 = providers[0].name,
    endpoint: []const u8 = providers[0].endpoint,
    model: []const u8 = providers[0].default_model,
    api_key: ?[]const u8 = null,
    prompt: ?[]const u8 = null,
    system_prompt: ?[]const u8 = null,
    mode: OutputMode = .text,
    no_tools: bool = false,
    /// Allowlist of tool names (null = all built-ins enabled). Owned elsewhere.
    tools_allow: ?[]const []const u8 = null,
    /// Denylist of tool names. Owned elsewhere.
    tools_deny: ?[]const []const u8 = null,
    thinking: ?[]const u8 = null,
    temperature: f32 = 0.7,
    max_tokens: ?u32 = null,
    // Reasoning models routinely take >30s; default generously (the old 30s
    // limit was the real cause of the "exit 110" blocker).
    timeout_ms: i64 = 120_000,
};

/// Resolve the effective API key. Precedence: explicit `--api-key` >
/// provider-specific env var(s) > provider builtin key (xiaomi default).
pub fn resolveApiKey(cfg: Config, env: *std.process.Environ.Map) ?[]const u8 {
    if (cfg.api_key) |k| return k;
    if (findProvider(cfg.provider)) |p| {
        for (p.env_keys) |ek| {
            if (env.get(ek)) |v| {
                if (v.len > 0) return v;
            }
        }
        return p.builtin_key;
    }
    return null;
}
