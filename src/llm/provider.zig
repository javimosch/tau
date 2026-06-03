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

/// Complete an LLM request with optional tool schema.
/// Returns Response with content and any tool_calls from the LLM.
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

    return Response{
        .content = content,
        .tool_calls = tool_calls,
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