const std = @import("std");
const jsonmod = @import("../json.zig");
const linux = std.os.linux;

pub const Message = struct {
    role: []const u8,
    content: []const u8,
};

pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments: []const u8,
};

pub const Response = struct {
    content: []const u8,
    tool_calls: []ToolCall,
};

pub const Provider = struct {
    name: []const u8,
    endpoint: []const u8,
    default_model: []const u8,
    env_keys: []const []const u8 = &.{},
    builtin_key: ?[]const u8 = null,
};

// Provider table (moved from config.zig as requested)
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

/// Complete an LLM request with optional tool schema.
/// Returns Response with content and any tool_calls from the LLM.
pub fn complete(io: std.Io, gpa: std.mem.Allocator, cfg: anytype,
                messages: []const Message, tools_json: ?[]const u8) !Response {
    _ = tools_json; // TODO: implement tool schema in request

    // Build request body with proper JSON escaping
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);

    try body.appendSlice(gpa, "{\"model\":\"");
    try jsonmod.escapeInto(gpa, &body, cfg.model);
    try body.appendSlice(gpa, "\",\"messages\":[");

    for (messages, 0..) |msg, i| {
        if (i > 0) try body.appendSlice(gpa, ",");
        try body.appendSlice(gpa, "{\"role\":\"");
        try jsonmod.escapeInto(gpa, &body, msg.role);
        try body.appendSlice(gpa, "\",\"content\":\"");
        try jsonmod.escapeInto(gpa, &body, msg.content);
        try body.appendSlice(gpa, "\"}");
    }

    try body.appendSlice(gpa, "],\"stream\":false}");

    const api_key = cfg.api_key orelse return error.AuthFailed;
    const auth = try std.fmt.allocPrint(gpa, "Authorization: Bearer {s}", .{api_key});
    defer gpa.free(auth);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ "curl", "-s", "-X", "POST", cfg.endpoint, "-H", auth, "-H", "Content-Type: application/json", "--data-raw", body.items });
    const argv_slice = try argv.toOwnedSlice(gpa);
    defer gpa.free(argv_slice);

    const timeout = std.Io.Timeout{ .duration = .{
        .raw = std.Io.Duration.fromMilliseconds(cfg.timeout_ms),
        .clock = .awake,
    } };

    const result = std.process.run(gpa, io, .{
        .argv = argv_slice,
        .stdout_limit = .unlimited,
        .stderr_limit = .unlimited,
        .timeout = timeout,
    }) catch |err| {
        if (err == error.Timeout) return error.Timeout;
        return error.HTTPRequestFailed;
    };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    const exit_code: u8 = switch (result.term) {
        .exited => |c| c,
        else => 1,
    };
    if (exit_code != 0) return error.HTTPRequestFailed;

    const content = (try jsonmod.extractString(gpa, result.stdout, "content")) orelse
        return error.InvalidResponse;

    // TODO: Parse tool_calls from response
    const tool_calls: []ToolCall = &.{};

    return Response{
        .content = content,
        .tool_calls = tool_calls,
    };
}