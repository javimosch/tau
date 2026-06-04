const std = @import("std");
const jsonmod = @import("../json.zig");
const linux = std.os.linux;

pub const Message = struct {
    role: []const u8,
    content: []const u8,
    /// Required by the API on `tool` role messages: the id of the tool_call
    /// this message answers. Serialized only when present.
    tool_call_id: ?[]const u8 = null,
    /// On an `assistant` message that triggered tools, the tool_calls it made.
    /// Echoing these back lets the model see it already called the tool (so it
    /// produces a final answer instead of re-calling). Serialized when present.
    tool_calls: ?[]const ToolCall = null,
};

pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments: []const u8,
};

pub const Response = struct {
    content: []const u8,
    tool_calls: []ToolCall,
    reasoning_content: ?[]const u8 = null,
};

pub const ToolInfo = struct {
    name: []const u8,
    description: []const u8,
};

pub const Provider = struct {
    name: []const u8,
    endpoint: []const u8,
    default_model: []const u8,
    env_keys: []const []const u8 = &.{},
    builtin_key: ?[]const u8 = null,
    /// Model context window in tokens (used for the compaction threshold).
    context_window: u32 = 256_000,
};

// Provider table (moved from config.zig as requested)
pub const providers = [_]Provider{
    .{
        .name = "xiaomi",
        .endpoint = "https://token-plan-ams.xiaomimimo.com/v1/chat/completions",
        .default_model = "mimo-v2.5",
        .env_keys = &.{ "XIAOMI_API_KEY", "PIZIG_API_KEY" },
        // No hardcoded key. Supply via ~/.config/tau/config.json ("api_key"),
        // a provider env var, TAU_API_KEY, or --api-key.
    },
    .{
        .name = "openai",
        .endpoint = "https://api.openai.com/v1/chat/completions",
        .default_model = "gpt-4o-mini",
        .env_keys = &.{"OPENAI_API_KEY"},
        .context_window = 128_000,
    },
    .{
        .name = "deepseek",
        .endpoint = "https://api.deepseek.com/v1/chat/completions",
        .default_model = "deepseek-chat",
        .env_keys = &.{"DEEPSEEK_API_KEY"},
        .context_window = 65_536,
    },
};

pub fn findProvider(name: []const u8) ?*const Provider {
    for (&providers) |*p| {
        if (std.mem.eql(u8, p.name, name)) return p;
    }
    return null;
}

/// Extract tool_calls from OpenAI response JSON
fn extractToolCalls(gpa: std.mem.Allocator, response: []const u8) ![]ToolCall {
    var tool_calls = std.ArrayList(ToolCall).empty;
    defer tool_calls.deinit(gpa);

    // Look for "tool_calls":[...] pattern
    const tool_calls_start = std.mem.indexOf(u8, response, "\"tool_calls\":[") orelse return &.{};

    var pos = tool_calls_start + "\"tool_calls\":[".len;
    var depth: usize = 0;
    var in_string = false;
    var escape_next = false;

    // Scan to the END OF THE ARRAY (the matching ']'), tracking object-brace
    // depth so nested '{' '}' and string contents don't terminate us early.
    // (Breaking at the first object's '}' would drop that closing brace and
    // also miss any 2nd..Nth tool call.)
    const array_start = pos;
    var found_end = false;
    while (pos < response.len) : (pos += 1) {
        const c = response[pos];

        if (escape_next) {
            escape_next = false;
            continue;
        }

        if (c == '\\') {
            escape_next = true;
            continue;
        }

        if (c == '"') {
            in_string = !in_string;
            continue;
        }

        if (!in_string) {
            if (c == '{') depth += 1;
            if (c == '}') depth -= 1;
            if (c == ']' and depth == 0) {
                found_end = true;
                break;
            }
        }
    }

    if (!found_end) return &.{};

    // Spans the full content between '[' and ']' (all tool-call objects).
    const tool_calls_json = response[array_start..pos];

    // Parse each tool call object
    var call_start: ?usize = null;
    var call_depth: usize = 0;
    var call_in_string = false;
    var call_escape_next = false;

    for (tool_calls_json, 0..) |c, i| {
        if (call_escape_next) {
            call_escape_next = false;
            continue;
        }

        if (c == '\\') {
            call_escape_next = true;
            continue;
        }

        if (c == '"') {
            call_in_string = !call_in_string;
            continue;
        }

        if (!call_in_string) {
            if (c == '{') {
                if (call_start == null) call_start = i;
                call_depth += 1;
            }
            if (c == '}') {
                call_depth -= 1;
                if (call_depth == 0 and call_start != null) {
                    const call_json = tool_calls_json[call_start.?..i+1];
                    // Parse this tool call
                    if (try parseToolCall(gpa, call_json)) |tc| {
                        try tool_calls.append(gpa, tc);
                    }
                    call_start = null;
                }
            }
        }
    }

    return try tool_calls.toOwnedSlice(gpa);
}

/// Parse a single tool call from JSON
fn parseToolCall(gpa: std.mem.Allocator, call_json: []const u8) !?ToolCall {
    const id = (try jsonmod.extractString(gpa, call_json, "id")) orelse return null;
    defer gpa.free(id);

    // Extract function.name
    const func_start = std.mem.indexOf(u8, call_json, "\"function\":{") orelse return null;
    const func_json = call_json[func_start..];
    const name = (try jsonmod.extractString(gpa, func_json, "name")) orelse return null;
    defer gpa.free(name);

    // Extract function.arguments
    const arguments = (try jsonmod.extractString(gpa, func_json, "arguments")) orelse return null;

    return ToolCall{
        .id = try gpa.dupe(u8, id),
        .name = try gpa.dupe(u8, name),
        .arguments = arguments,
    };
}

/// JSON Schema `parameters` object for a built-in tool. Property names MUST
/// match what agent.buildToolArgs() reads, or the model will supply argument
/// names the executor can't find. Unknown tools fall back to no parameters.
fn toolParamsJson(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "bash"))
        return "{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\",\"description\":\"the shell command to run\"}},\"required\":[\"command\"]}";
    if (std.mem.eql(u8, name, "read"))
        return "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"path to the file to read\"}},\"required\":[\"path\"]}";
    if (std.mem.eql(u8, name, "write"))
        return "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"file path to write\"},\"content\":{\"type\":\"string\",\"description\":\"content to write\"}},\"required\":[\"path\",\"content\"]}";
    if (std.mem.eql(u8, name, "edit"))
        return "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"old_string\":{\"type\":\"string\"},\"new_string\":{\"type\":\"string\"}},\"required\":[\"path\",\"old_string\",\"new_string\"]}";
    if (std.mem.eql(u8, name, "ls"))
        return "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"directory to list\"}},\"required\":[\"path\"]}";
    if (std.mem.eql(u8, name, "grep"))
        return "{\"type\":\"object\",\"properties\":{\"pattern\":{\"type\":\"string\",\"description\":\"regex/text to search\"},\"path\":{\"type\":\"string\",\"description\":\"file or dir to search\"}},\"required\":[\"pattern\",\"path\"]}";
    if (std.mem.eql(u8, name, "find"))
        return "{\"type\":\"object\",\"properties\":{\"pattern\":{\"type\":\"string\",\"description\":\"name/glob to find\"},\"path\":{\"type\":\"string\",\"description\":\"directory to search in\"}},\"required\":[\"pattern\",\"path\"]}";
    return "{\"type\":\"object\",\"properties\":{}}";
}

const max_http_attempts: u32 = 3;

const BodyClass = enum { ok, auth, retryable };

fn bodyContains(body: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, body, needle) != null;
}

/// Classify a successful-transport response body. Only bodies carrying an
/// `"error":` envelope are treated as failures; normal/tool-call responses
/// (including "content":null) are `.ok`.
fn classifyBody(body: []const u8) BodyClass {
    if (!bodyContains(body, "\"error\":")) return .ok;
    if (bodyContains(body, "invalid_key") or bodyContains(body, "Invalid API Key") or
        bodyContains(body, "401") or bodyContains(body, "nauthorized")) return .auth;
    // 429 / 5xx / overload / rate-limit are transient; unknown error envelopes
    // are retried once as well (could be transient).
    return .retryable;
}

/// Exponential backoff between HTTP attempts (500ms, 1s, 2s, ...).
fn backoff(io: std.Io, attempt: u32) void {
    const ms: i64 = @as(i64, 500) * (@as(i64, 1) << @intCast(attempt - 1));
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(ms), .awake) catch {};
}

/// Complete an LLM request with optional tool schema.
/// Returns Response with content and any tool_calls from the LLM. Transient HTTP
/// failures (curl error, 429/5xx) are retried with exponential backoff; a 401 /
/// invalid key surfaces as error.AuthFailed.
pub fn complete(io: std.Io, gpa: std.mem.Allocator, cfg: anytype,
                messages: []const Message, tools: ?[]const ToolInfo) !Response {

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
        try body.appendSlice(gpa, "\"");
        if (msg.tool_call_id) |tcid| {
            try body.appendSlice(gpa, ",\"tool_call_id\":\"");
            try jsonmod.escapeInto(gpa, &body, tcid);
            try body.appendSlice(gpa, "\"");
        }
        if (msg.tool_calls) |tcs| {
            try body.appendSlice(gpa, ",\"tool_calls\":[");
            for (tcs, 0..) |tc, j| {
                if (j > 0) try body.appendSlice(gpa, ",");
                try body.appendSlice(gpa, "{\"id\":\"");
                try jsonmod.escapeInto(gpa, &body, tc.id);
                try body.appendSlice(gpa, "\",\"type\":\"function\",\"function\":{\"name\":\"");
                try jsonmod.escapeInto(gpa, &body, tc.name);
                try body.appendSlice(gpa, "\",\"arguments\":\"");
                try jsonmod.escapeInto(gpa, &body, tc.arguments);
                try body.appendSlice(gpa, "\"}}");
            }
            try body.appendSlice(gpa, "]");
        }
        try body.appendSlice(gpa, "}");
    }

    try body.appendSlice(gpa, "],\"stream\":false");

    // Add tool schema if tools are provided
    if (tools) |t| {
        if (t.len > 0) {
            try body.appendSlice(gpa, ",\"tools\":[");
            for (t, 0..) |tool, i| {
                if (i > 0) try body.appendSlice(gpa, ",");
                try body.appendSlice(gpa, "{\"type\":\"function\",\"function\":{\"name\":\"");
                try jsonmod.escapeInto(gpa, &body, tool.name);
                try body.appendSlice(gpa, "\",\"description\":\"");
                try jsonmod.escapeInto(gpa, &body, tool.description);
                try body.appendSlice(gpa, "\",\"parameters\":");
                try body.appendSlice(gpa, toolParamsJson(tool.name));
                try body.appendSlice(gpa, "}}");
            }
            try body.appendSlice(gpa, "]");
        }
    }

    try body.appendSlice(gpa, "}");

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

    var attempt: u32 = 0;
    const result = while (true) {
        const res = std.process.run(gpa, io, .{
            .argv = argv_slice,
            .stdout_limit = .unlimited,
            .stderr_limit = .unlimited,
            .timeout = timeout,
        }) catch |err| {
            if (err == error.Timeout) return error.Timeout;
            if (attempt + 1 < max_http_attempts) {
                attempt += 1;
                backoff(io, attempt);
                continue;
            }
            return error.HTTPRequestFailed;
        };
        const ec: u8 = switch (res.term) {
            .exited => |c| c,
            else => 1,
        };
        if (ec != 0) {
            gpa.free(res.stdout);
            gpa.free(res.stderr);
            if (attempt + 1 < max_http_attempts) {
                attempt += 1;
                backoff(io, attempt);
                continue;
            }
            return error.HTTPRequestFailed;
        }
        switch (classifyBody(res.stdout)) {
            .ok => break res,
            .auth => {
                gpa.free(res.stdout);
                gpa.free(res.stderr);
                return error.AuthFailed;
            },
            .retryable => {
                gpa.free(res.stdout);
                gpa.free(res.stderr);
                if (attempt + 1 < max_http_attempts) {
                    attempt += 1;
                    backoff(io, attempt);
                    continue;
                }
                return error.HTTPRequestFailed;
            },
        }
    };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    // Log raw response if debug mode is enabled
    if (cfg.debug) {
        const debug_raw = try std.fmt.allocPrint(gpa, "[DEBUG] Raw API response: {s}\n", .{result.stdout});
        defer gpa.free(debug_raw);
        _ = linux.write(2, debug_raw.ptr, debug_raw.len);
    }

    // Parse tool_calls first: on a tool-call turn the model returns
    // "content":null, which is valid (not an error).
    const tool_calls = try extractToolCalls(gpa, result.stdout);

    const content = (try jsonmod.extractString(gpa, result.stdout, "content")) orelse blk: {
        // No string content. Fine if this is a tool-call turn. Otherwise, if
        // the envelope carries an error object, surface it as a failure.
        if (tool_calls.len == 0 and std.mem.indexOf(u8, result.stdout, "\"error\"") != null) {
            return error.HTTPRequestFailed;
        }
        break :blk try gpa.dupe(u8, "");
    };

    // Extract reasoning_content if available (thinking chunks)
    const reasoning_content = try jsonmod.extractString(gpa, result.stdout, "reasoning_content");

    return Response{
        .content = content,
        .tool_calls = tool_calls,
        .reasoning_content = reasoning_content,
    };
}

/// Return the JSON-escaped slice of `delta.content` within an SSE chunk (the
/// chars between the quotes), or null if the field is absent or null. The
/// `"content":"` needle never matches inside `"reasoning_content":"` (the byte
/// before `content` is `_`, not `"`), so reasoning deltas are skipped.
fn extractDeltaContent(json: []const u8) ?[]const u8 {
    const needle = "\"content\":\"";
    const at = std.mem.indexOf(u8, json, needle) orelse return null;
    const start = at + needle.len;
    var end = start;
    while (end < json.len) : (end += 1) {
        if (json[end] == '\\') {
            end += 1;
            continue;
        }
        if (json[end] == '"') break;
    } else return null;
    return json[start..end];
}

/// Return the JSON-escaped slice of `delta.reasoning_content` within an SSE chunk.
fn extractDeltaReasoning(json: []const u8) ?[]const u8 {
    const needle = "\"reasoning_content\":\"";
    const at = std.mem.indexOf(u8, json, needle) orelse return null;
    const start = at + needle.len;
    var end = start;
    while (end < json.len) : (end += 1) {
        if (json[end] == '\\') {
            end += 1;
            continue;
        }
        if (json[end] == '"') break;
    } else return null;
    return json[start..end];
}

/// Streaming completion: sends `"stream":true`, spawns `curl -N`, parses the
/// SSE `data:` events, and writes content deltas to stdout incrementally per
/// cfg.mode. A pure chat turn (no tools — tool_call assembly is not streamed).
/// text mode: raw token deltas. json mode: NDJSON `{"chunk":..,"done":false}`
/// lines, then a final `{"model":..,"done":true}`.
pub fn completeStream(io: std.Io, gpa: std.mem.Allocator, cfg: anytype, messages: []const Message) !void {
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
    try body.appendSlice(gpa, "],\"stream\":true}");

    const api_key = cfg.api_key orelse return error.AuthFailed;
    const auth = try std.fmt.allocPrint(gpa, "Authorization: Bearer {s}", .{api_key});
    defer gpa.free(auth);

    const argv = &[_][]const u8{
        "curl",          "-s",                          "-N", "-X", "POST", cfg.endpoint,
        "-H",            auth,                          "-H", "Content-Type: application/json",
        "--data-raw", body.items,
    };

    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    defer child.kill(io);

    const out = child.stdout.?;
    var rbuf: [16384]u8 = undefined;
    var fr = out.readerStreaming(io, &rbuf);
    const r = &fr.interface;

    var saw_data = false;
    while (true) {
        const line = (r.takeDelimiter('\n') catch break) orelse break;
        if (line.len == 0) continue;

        if (cfg.debug) {
            const debug_line = try std.fmt.allocPrint(gpa, "[DEBUG] SSE line: {s}\n", .{line});
            defer gpa.free(debug_line);
            _ = linux.write(2, debug_line.ptr, debug_line.len);
        }

        if (!std.mem.startsWith(u8, line, "data:")) {
            // Non-SSE line before any data: likely an error envelope.
            if (!saw_data and std.mem.indexOf(u8, line, "\"error\"") != null) {
                _ = child.wait(io) catch {};
                return error.HTTPRequestFailed;
            }
            continue;
        }
        saw_data = true;
        var data = line["data:".len..];
        if (data.len > 0 and data[0] == ' ') data = data[1..];
        if (std.mem.eql(u8, data, "[DONE]")) break;

        // Extract reasoning_content first if thinking mode is enabled
        if (cfg.thinking) {
            if (extractDeltaReasoning(data)) |reasoning_esc| {
                if (reasoning_esc.len > 0) {
                    switch (cfg.mode) {
                        .text => {
                            const txt = try jsonmod.unescapeAlloc(gpa, reasoning_esc);
                            defer gpa.free(txt);
                            const prefix = "[THINKING] ";
                            _ = linux.write(1, prefix.ptr, prefix.len);
                            _ = linux.write(1, txt.ptr, txt.len);
                            _ = linux.write(1, "\n".ptr, 1);
                        },
                        .json => {
                            const out_line = try std.fmt.allocPrint(gpa, "{{\"reasoning\":\"{s}\",\"done\":false}}\n", .{reasoning_esc});
                            defer gpa.free(out_line);
                            _ = linux.write(1, out_line.ptr, out_line.len);
                        },
                    }
                }
            }
        }

        const esc = extractDeltaContent(data) orelse continue;
        if (esc.len == 0) continue;
        switch (cfg.mode) {
            .text => {
                const txt = try jsonmod.unescapeAlloc(gpa, esc);
                defer gpa.free(txt);
                _ = linux.write(1, txt.ptr, txt.len);
            },
            .json => {
                // esc is already valid JSON-escaped text; embed it directly.
                const out_line = try std.fmt.allocPrint(gpa, "{{\"chunk\":\"{s}\",\"done\":false}}\n", .{esc});
                defer gpa.free(out_line);
                _ = linux.write(1, out_line.ptr, out_line.len);
            },
        }
    }

    _ = child.wait(io) catch {};

    switch (cfg.mode) {
        .text => _ = linux.write(1, "\n".ptr, 1),
        .json => {
            const done = try std.fmt.allocPrint(gpa, "{{\"model\":\"{s}\",\"done\":true}}\n", .{cfg.model});
            defer gpa.free(done);
            _ = linux.write(1, done.ptr, done.len);
        },
    }
}