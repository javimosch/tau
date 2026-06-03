const std = @import("std");
const provider_mod = @import("llm/provider.zig");

pub const OutputMode = enum { text, json };

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
