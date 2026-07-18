const std = @import("std");
const jsonmod = @import("../json.zig");
const term = @import("../term.zig");

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
    /// Total tokens consumed (from API usage.total_tokens). null when the API
    /// doesn't report usage (some streaming responses may omit it).
    total_tokens: ?u64 = null,
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
    .{
        .name = "opencode-go",
        .endpoint = "https://opencode.ai/zen/go/v1/chat/completions",
        .default_model = "deepseek-v4-flash",
        .env_keys = &.{"OPENCODE_API_KEY"},
        .context_window = 204_800,
    },
};

pub fn findProvider(name: []const u8) ?*const Provider {
    for (&providers) |*p| {
        if (std.mem.eql(u8, p.name, name)) return p;
    }
    return null;
}

/// Extract usage.total_tokens from an OpenAI-compatible response body.
/// Returns null if the "usage" object or its "total_tokens" field is absent.
fn extractUsage(json: []const u8) ?u64 {
    const needle = "\"total_tokens\":";
    const at = std.mem.indexOf(u8, json, needle) orelse return null;
    var start = at + needle.len;
    while (start < json.len and (json[start] == ' ' or json[start] == '\t')) start += 1;
    var end = start;
    while (end < json.len and json[end] >= '0' and json[end] <= '9') end += 1;
    if (end == start) return null;
    return std.fmt.parseInt(u64, json[start..end], 10) catch null;
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

// ---------------------------------------------------------------------------
// Request body builder (shared by complete() and completeStreamWithTools())
// ---------------------------------------------------------------------------

fn appendRequestBody(
    gpa: std.mem.Allocator,
    body: *std.ArrayList(u8),
    cfg: anytype,
    messages: []const Message,
    tools: ?[]const ToolInfo,
    stream: bool,
) !void {
    try body.appendSlice(gpa, "{\"model\":\"");
    try jsonmod.escapeInto(gpa, body, cfg.model);
    try body.appendSlice(gpa, "\",\"messages\":[");

    for (messages, 0..) |msg, i| {
        if (i > 0) try body.appendSlice(gpa, ",");
        try body.appendSlice(gpa, "{\"role\":\"");
        try jsonmod.escapeInto(gpa, body, msg.role);
        try body.appendSlice(gpa, "\",\"content\":\"");
        try jsonmod.escapeInto(gpa, body, msg.content);
        try body.appendSlice(gpa, "\"");
        if (msg.tool_call_id) |tcid| {
            try body.appendSlice(gpa, ",\"tool_call_id\":\"");
            try jsonmod.escapeInto(gpa, body, tcid);
            try body.appendSlice(gpa, "\"");
        }
        if (msg.tool_calls) |tcs| {
            try body.appendSlice(gpa, ",\"tool_calls\":[");
            for (tcs, 0..) |tc, j| {
                if (j > 0) try body.appendSlice(gpa, ",");
                try body.appendSlice(gpa, "{\"id\":\"");
                try jsonmod.escapeInto(gpa, body, tc.id);
                try body.appendSlice(gpa, "\",\"type\":\"function\",\"function\":{\"name\":\"");
                try jsonmod.escapeInto(gpa, body, tc.name);
                try body.appendSlice(gpa, "\",\"arguments\":\"");
                try jsonmod.escapeInto(gpa, body, tc.arguments);
                try body.appendSlice(gpa, "\"}}");
            }
            try body.appendSlice(gpa, "]");
        }
        try body.appendSlice(gpa, "}");
    }

    if (stream) {
        try body.appendSlice(gpa, "],\"stream\":true");
    } else {
        try body.appendSlice(gpa, "],\"stream\":false");
    }

    if (tools) |t| {
        if (t.len > 0) {
            try body.appendSlice(gpa, ",\"tools\":[");
            for (t, 0..) |tool, i| {
                if (i > 0) try body.appendSlice(gpa, ",");
                try body.appendSlice(gpa, "{\"type\":\"function\",\"function\":{\"name\":\"");
                try jsonmod.escapeInto(gpa, body, tool.name);
                try body.appendSlice(gpa, "\",\"description\":\"");
                try jsonmod.escapeInto(gpa, body, tool.description);
                try body.appendSlice(gpa, "\",\"parameters\":");
                try body.appendSlice(gpa, toolParamsJson(tool.name));
                try body.appendSlice(gpa, "}}");
            }
            try body.appendSlice(gpa, "]");
        }
    }

    // response_format for JSON Schema structured output
    if (@hasField(@TypeOf(cfg), "schema")) {
        if (cfg.schema) |s| {
            try body.appendSlice(gpa, ",\"response_format\":{\"type\":\"json_schema\",\"json_schema\":{\"name\":\"response\",\"strict\":true,\"schema\":");
            try body.appendSlice(gpa, s);
            try body.appendSlice(gpa, "}}");
        }
    }

    try body.appendSlice(gpa, "}");
}

// ---------------------------------------------------------------------------
// Non-streaming completion (blocking, full JSON response)
// ---------------------------------------------------------------------------

/// Complete an LLM request with optional tool schema.
/// Returns Response with content and any tool_calls from the LLM. Transient HTTP
/// failures (curl error, 429/5xx) are retried with exponential backoff; a 401 /
/// invalid key surfaces as error.AuthFailed.
pub fn complete(io: std.Io, gpa: std.mem.Allocator, cfg: anytype,
                messages: []const Message, tools: ?[]const ToolInfo) !Response {

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    try appendRequestBody(gpa, &body, cfg, messages, tools, false);

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
        term.err(debug_raw);
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

    // Extract usage.total_tokens if the API reports it.
    const total_tokens = extractUsage(result.stdout);

    return Response{
        .content = content,
        .tool_calls = tool_calls,
        .reasoning_content = reasoning_content,
        .total_tokens = total_tokens,
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

// ---------------------------------------------------------------------------
// Whitespace-tolerant SSE field scanning
// ---------------------------------------------------------------------------
//
// SSE `data:` chunks are located with byte-exact needles. A pretty-printing
// OpenAI-compatible server inserts insignificant JSON whitespace after the
// colon (`"index": 0`, `"tool_calls": [ {`), which byte-exact needles miss —
// silently dropping streaming tool calls and reasoning deltas (issue #67, the
// streaming twin of #65). The helpers below match `"key":`, skip whitespace,
// then expect the value's opening delimiter, so both compact and spaced chunks
// parse identically.

/// Skip insignificant JSON whitespace (space, tab, CR, LF) from `i`.
fn skipSseWs(json: []const u8, i: usize) usize {
    var p = i;
    while (p < json.len and (json[p] == ' ' or json[p] == '\t' or json[p] == '\r' or json[p] == '\n')) p += 1;
    return p;
}

/// Find `key` (a full `"name":` needle) at or after `from`, skip whitespace
/// after the colon, and if the next byte equals `open`, return the index just
/// past it. Returns null if the key is absent or the value does not open with
/// `open`. Tolerates pretty-printed (spaced) JSON.
fn valueAfterKey(json: []const u8, from: usize, key: []const u8, open: u8) ?usize {
    const at = std.mem.indexOfPos(u8, json, from, key) orelse return null;
    const vs = skipSseWs(json, at + key.len);
    if (vs >= json.len or json[vs] != open) return null;
    return vs + 1;
}

/// Read a JSON string body starting at `start` (just past the opening quote),
/// returning the raw escaped slice up to — but not including — the closing
/// quote. Returns null if the string is unterminated.
fn readSseString(json: []const u8, start: usize) ?[]const u8 {
    var end = start;
    while (end < json.len) : (end += 1) {
        if (json[end] == '\\') { end += 1; continue; }
        if (json[end] == '"') return json[start..end];
    }
    return null;
}

/// Index just past the `{` opening the first tool_calls object, tolerating
/// whitespace in `"tool_calls": [ { ...`. Null when there is no tool_call
/// delta (e.g. `"tool_calls":null`).
fn tcObjStart(json: []const u8) ?usize {
    const arr = valueAfterKey(json, 0, "\"tool_calls\":", '[') orelse return null;
    const ws = skipSseWs(json, arr);
    if (ws >= json.len or json[ws] != '{') return null;
    return ws + 1;
}

/// Return the JSON-escaped slice of `delta.reasoning_content` within an SSE chunk.
fn extractDeltaReasoning(json: []const u8) ?[]const u8 {
    const start = valueAfterKey(json, 0, "\"reasoning_content\":", '"') orelse return null;
    return readSseString(json, start);
}

// ---------------------------------------------------------------------------
// SSE tool_call delta extractors
// ---------------------------------------------------------------------------

/// True when this SSE chunk carries a tool_calls delta (vs. null).
fn hasDeltaToolCall(json: []const u8) bool {
    return tcObjStart(json) != null;
}

/// Index of the tool_call being streamed (always 0 for single-tool turns,
/// higher for parallel tool calls). Returns null if no tool_call delta.
fn extractDeltaTCIndex(json: []const u8) ?usize {
    const start = tcObjStart(json) orelse return null;
    const needle = "\"index\":";
    const at = std.mem.indexOfPos(u8, json, start, needle) orelse return null;
    const vs = skipSseWs(json, at + needle.len);
    var end = vs;
    while (end < json.len and json[end] >= '0' and json[end] <= '9') end += 1;
    if (end == vs) return null;
    return std.fmt.parseInt(usize, json[vs..end], 10) catch null;
}

/// The call id (e.g. "call_abc123") from the first chunk for a given index.
/// Subsequent chunks have "id":null; this returns null in that case.
/// Searches within the tool_calls section to avoid matching the top-level
/// response "id" field that also appears in every SSE chunk.
fn extractDeltaTCId(json: []const u8) ?[]const u8 {
    const tc_start = tcObjStart(json) orelse return null;
    const start = valueAfterKey(json, tc_start, "\"id\":", '"') orelse return null;
    return readSseString(json, start);
}

/// The function name from the first chunk for a given index ("name":"bash").
/// Subsequent chunks have "name":null; returns null in that case.
fn extractDeltaTCName(json: []const u8) ?[]const u8 {
    // The name lives inside "function":{...} — search from there to avoid
    // matching other "name" fields (e.g. the tool's registered name elsewhere).
    const func_at = valueAfterKey(json, 0, "\"function\":", '{') orelse return null;
    const start = valueAfterKey(json, func_at, "\"name\":", '"') orelse return null;
    return readSseString(json, start); // already unescaped (tool names are ASCII)
}

/// The raw JSON-escaped arguments fragment from this chunk. Concatenate across
/// all chunks for a given index to get the full escaped arguments body, then
/// call unescapeAlloc once to get the final arguments string.
fn extractDeltaTCArgs(json: []const u8) ?[]const u8 {
    const start = valueAfterKey(json, 0, "\"arguments\":", '"') orelse return null;
    return readSseString(json, start);
}

// ---------------------------------------------------------------------------
// Streaming completion with tool_call reassembly
// ---------------------------------------------------------------------------

/// Per-index buffer for an in-progress streaming tool_call.
const InProgressTC = struct {
    id: std.ArrayList(u8) = .empty,
    name: std.ArrayList(u8) = .empty,
    /// Raw JSON-escaped argument fragments, concatenated across chunks.
    /// Unescaped once at the end to produce the final arguments string.
    args_raw: std.ArrayList(u8) = .empty,
    active: bool = false,
};

/// Streaming completion with full tool_call support. Sends `"stream":true`
/// with the tool schema, spawns `curl -N`, and for each SSE chunk:
///   - reasoning_content deltas → streamed to stdout (if --thinking)
///   - content deltas          → streamed to stdout token-by-token
///   - tool_calls deltas       → accumulated silently by index
/// Returns Response with the assembled content string and tool_calls (same
/// shape as complete()). The caller runs tool execution and the next iteration
/// exactly as for the non-streaming path. The final "done" marker is emitted
/// internally for pure-content turns; callers must NOT call emitFinal.
/// When strip_sentinel is true, lines equal to "<GOAL_MET>" are suppressed
/// from text-mode terminal output (the content is still returned in Response).
pub fn completeStreamWithTools(
    io: std.Io,
    gpa: std.mem.Allocator,
    cfg: anytype,
    messages: []const Message,
    tools: ?[]const ToolInfo,
    strip_sentinel: bool,
) !Response {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    try appendRequestBody(gpa, &body, cfg, messages, tools, true);

    const api_key = cfg.api_key orelse return error.AuthFailed;
    const auth = try std.fmt.allocPrint(gpa, "Authorization: Bearer {s}", .{api_key});
    defer gpa.free(auth);

    var child = try std.process.spawn(io, .{
        .argv = &[_][]const u8{
            "curl", "-s", "-N", "-X", "POST", cfg.endpoint,
            "-H",   auth, "-H", "Content-Type: application/json",
            "--data-raw", body.items,
        },
        .stdin  = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    defer child.kill(io);

    var content_buf: std.ArrayList(u8) = .empty;
    errdefer content_buf.deinit(gpa);
    var reasoning_buf: std.ArrayList(u8) = .empty;
    defer reasoning_buf.deinit(gpa);
    // Line buffer for sentinel suppression (goal mode, text mode only).
    var line_buf: std.ArrayList(u8) = .empty;
    defer line_buf.deinit(gpa);

    // Up to 8 concurrent tool calls (models rarely exceed 4 in parallel).
    var tc_buf = [_]InProgressTC{.{}} ** 8;
    defer for (&tc_buf) |*tc| {
        tc.id.deinit(gpa);
        tc.name.deinit(gpa);
        tc.args_raw.deinit(gpa);
    };

    const out = child.stdout.?;
    var rbuf: [16384]u8 = undefined;
    var fr = out.readerStreaming(io, &rbuf);
    const r = &fr.interface;

    var saw_data = false;
    var stream_usage: ?u64 = null;
    while (true) {
        const line = (r.takeDelimiter('\n') catch break) orelse break;
        if (line.len == 0) continue;

        if (cfg.debug) {
            const dbg = try std.fmt.allocPrint(gpa, "[DEBUG] SSE line: {s}\n", .{line});
            defer gpa.free(dbg);
            term.err(dbg);
        }

        if (!std.mem.startsWith(u8, line, "data:")) {
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

        // Usage chunk: extract total_tokens from any SSE line that carries it.
        if (stream_usage == null) {
            stream_usage = extractUsage(data);
        }

        // Reasoning deltas → stream if --thinking, accumulate.
        if (cfg.thinking) {
            if (extractDeltaReasoning(data)) |esc| {
                if (esc.len > 0) {
                    const txt = try jsonmod.unescapeAlloc(gpa, esc);
                    defer gpa.free(txt);
                    try reasoning_buf.appendSlice(gpa, txt);
                    switch (cfg.mode) {
                        .text => { term.out("[THINKING] "); term.out(txt); term.out("\n"); },
                        .json => {
                            const ol = try std.fmt.allocPrint(gpa, "{{\"reasoning\":\"{s}\",\"done\":false}}\n", .{esc});
                            defer gpa.free(ol);
                            term.out(ol);
                        },
                    }
                }
            }
        }

        // Content deltas → stream to stdout, accumulate in content_buf.
        if (extractDeltaContent(data)) |esc| {
            if (esc.len > 0) {
                const txt = try jsonmod.unescapeAlloc(gpa, esc);
                defer gpa.free(txt);
                try content_buf.appendSlice(gpa, txt);
                switch (cfg.mode) {
                    .text => if (strip_sentinel) {
                        // Buffer line by line; suppress lines that equal the sentinel.
                        for (txt) |c| {
                            try line_buf.append(gpa, c);
                            if (c == '\n') {
                                const trimmed = std.mem.trim(u8, line_buf.items, " \t\r\n");
                                if (!std.mem.eql(u8, trimmed, "<GOAL_MET>")) term.out(line_buf.items);
                                line_buf.clearRetainingCapacity();
                            }
                        }
                    } else {
                        term.out(txt);
                    },
                    .json => {
                        const ol = try std.fmt.allocPrint(gpa, "{{\"chunk\":\"{s}\",\"done\":false}}\n", .{esc});
                        defer gpa.free(ol);
                        term.out(ol);
                    },
                }
            }
        }

        // Tool_call deltas → accumulate silently by index.
        if (hasDeltaToolCall(data)) {
            if (extractDeltaTCIndex(data)) |idx| {
                if (idx < tc_buf.len) {
                    tc_buf[idx].active = true;
                    if (extractDeltaTCId(data)) |id|
                        try tc_buf[idx].id.appendSlice(gpa, id);
                    if (extractDeltaTCName(data)) |nm|
                        try tc_buf[idx].name.appendSlice(gpa, nm);
                    if (extractDeltaTCArgs(data)) |frag|
                        try tc_buf[idx].args_raw.appendSlice(gpa, frag);
                }
            }
        }
    }

    _ = child.wait(io) catch {};

    // Assemble tool_calls from accumulated fragments.
    var tool_calls: std.ArrayList(ToolCall) = .empty;
    errdefer {
        for (tool_calls.items) |tc| {
            gpa.free(tc.id);
            gpa.free(tc.name);
            gpa.free(tc.arguments);
        }
        tool_calls.deinit(gpa);
    }
    for (&tc_buf) |*tc| {
        if (!tc.active) continue;
        const args = try jsonmod.unescapeAlloc(gpa, tc.args_raw.items);
        try tool_calls.append(gpa, .{
            .id        = try gpa.dupe(u8, tc.id.items),
            .name      = try gpa.dupe(u8, tc.name.items),
            .arguments = args,
        });
    }

    // Flush any partial line remaining in the line buffer (no trailing '\n').
    // A partial sentinel can't be a complete lone line, so always emit.
    if (strip_sentinel and line_buf.items.len > 0) {
        const trimmed = std.mem.trim(u8, line_buf.items, " \t\r\n");
        if (!std.mem.eql(u8, trimmed, "<GOAL_MET>")) term.out(line_buf.items);
    }

    // Emit terminal marker for pure-content turns (no tool calls).
    // Tool-call turns have no marker — the caller will execute tools and loop.
    if (tool_calls.items.len == 0) {
        switch (cfg.mode) {
            .text => term.out("\n"),
            .json => {
                const done = try std.fmt.allocPrint(gpa, "{{\"model\":\"{s}\",\"done\":true}}\n", .{cfg.model});
                defer gpa.free(done);
                term.out(done);
            },
        }
    }

    const reasoning = if (reasoning_buf.items.len > 0)
        try gpa.dupe(u8, reasoning_buf.items)
    else
        null;

    return Response{
        .content        = try content_buf.toOwnedSlice(gpa),
        .tool_calls     = try tool_calls.toOwnedSlice(gpa),
        .reasoning_content = reasoning,
        .total_tokens   = stream_usage,
    };
}

// ---------------------------------------------------------------------------
// Unit tests — SSE delta extractors
// Real SSE chunk shapes captured from the xiaomi/mimo-v2.5 endpoint probe.
// ---------------------------------------------------------------------------

// Minimal real-shape SSE chunks (trimmed to the fields under test).
const SSE_REASONING = "{\"id\":\"e34d\",\"choices\":[{\"delta\":{\"content\":null,\"tool_calls\":null,\"reasoning_content\":\"I'll use the bash tool\"},\"finish_reason\":null,\"index\":0}]}";
const SSE_CONTENT   = "{\"id\":\"e34d\",\"choices\":[{\"delta\":{\"content\":\"Hello world\",\"tool_calls\":null,\"reasoning_content\":null},\"finish_reason\":null,\"index\":0}]}";
// First tool_call chunk: id + name present, arguments empty.
const SSE_TC_HEADER = "{\"id\":\"e34d\",\"choices\":[{\"delta\":{\"content\":null,\"tool_calls\":[{\"index\":0,\"id\":\"call_469abc\",\"function\":{\"arguments\":\"\",\"name\":\"bash\"},\"type\":\"function\"}],\"reasoning_content\":null},\"finish_reason\":null}]}";
// Subsequent argument fragment: id/name null, arguments is a partial JSON fragment.
const SSE_TC_ARGS1  = "{\"id\":\"e34d\",\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":null,\"function\":{\"arguments\":\"{\\\"command\\\": \",\"name\":null},\"type\":\"function\"}]},\"finish_reason\":null}]}";
const SSE_TC_ARGS2  = "{\"id\":\"e34d\",\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":null,\"function\":{\"arguments\":\"\\\"ls /tmp\\\"\",\"name\":null},\"type\":\"function\"}]},\"finish_reason\":null}]}";
const SSE_TC_ARGS3  = "{\"id\":\"e34d\",\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":null,\"function\":{\"arguments\":\"}\",\"name\":null},\"type\":\"function\"}]},\"finish_reason\":null}]}";
// finish_reason=tool_calls, no content.
const SSE_TC_FINISH = "{\"id\":\"e34d\",\"choices\":[{\"delta\":{\"content\":null,\"tool_calls\":null,\"reasoning_content\":null},\"finish_reason\":\"tool_calls\",\"index\":0}]}";
// Parallel tool call at index 2.
const SSE_TC_IDX2   = "{\"id\":\"e34d\",\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":2,\"id\":\"call_zyx\",\"function\":{\"arguments\":\"\",\"name\":\"read\"},\"type\":\"function\"}]}}]}";

test "hasDeltaToolCall" {
    try std.testing.expect(!hasDeltaToolCall(SSE_REASONING));
    try std.testing.expect(!hasDeltaToolCall(SSE_CONTENT));
    try std.testing.expect(!hasDeltaToolCall(SSE_TC_FINISH));
    try std.testing.expect(hasDeltaToolCall(SSE_TC_HEADER));
    try std.testing.expect(hasDeltaToolCall(SSE_TC_ARGS1));
    try std.testing.expect(hasDeltaToolCall(SSE_TC_IDX2));
}

test "extractDeltaContent and extractDeltaReasoning" {
    try std.testing.expect(extractDeltaContent(SSE_REASONING) == null);
    try std.testing.expectEqualStrings("I'll use the bash tool", extractDeltaReasoning(SSE_REASONING).?);

    try std.testing.expectEqualStrings("Hello world", extractDeltaContent(SSE_CONTENT).?);
    try std.testing.expect(extractDeltaReasoning(SSE_CONTENT) == null);

    // Tool-call chunks carry no content or reasoning.
    try std.testing.expect(extractDeltaContent(SSE_TC_HEADER) == null);
    try std.testing.expect(extractDeltaReasoning(SSE_TC_HEADER) == null);
}

test "extractDeltaTCIndex" {
    try std.testing.expect(extractDeltaTCIndex(SSE_CONTENT) == null);
    try std.testing.expect(extractDeltaTCIndex(SSE_REASONING) == null);
    try std.testing.expectEqual(@as(usize, 0), extractDeltaTCIndex(SSE_TC_HEADER).?);
    try std.testing.expectEqual(@as(usize, 0), extractDeltaTCIndex(SSE_TC_ARGS1).?);
    try std.testing.expectEqual(@as(usize, 2), extractDeltaTCIndex(SSE_TC_IDX2).?);
}

test "extractDeltaTCId: returns call id, NOT the top-level response id" {
    // The bug: every SSE chunk starts with "id":"e34d..." (response id).
    // extractDeltaTCId must return the *call* id inside tool_calls, not "e34d".
    try std.testing.expectEqualStrings("call_469abc", extractDeltaTCId(SSE_TC_HEADER).?);
    // Subsequent chunks have "id":null inside tool_calls → should return null.
    try std.testing.expect(extractDeltaTCId(SSE_TC_ARGS1) == null);
    try std.testing.expect(extractDeltaTCId(SSE_TC_ARGS2) == null);
    try std.testing.expectEqualStrings("call_zyx", extractDeltaTCId(SSE_TC_IDX2).?);
    // Non-tool chunks: no tool_calls section → null (not the top-level response id).
    try std.testing.expect(extractDeltaTCId(SSE_CONTENT) == null);
}

test "extractDeltaTCName" {
    try std.testing.expectEqualStrings("bash", extractDeltaTCName(SSE_TC_HEADER).?);
    try std.testing.expectEqualStrings("read", extractDeltaTCName(SSE_TC_IDX2).?);
    // Subsequent chunks have "name":null inside function → null.
    try std.testing.expect(extractDeltaTCName(SSE_TC_ARGS1) == null);
    // Non-tool chunks → null.
    try std.testing.expect(extractDeltaTCName(SSE_CONTENT) == null);
}

test "extractDeltaTCArgs" {
    // First chunk: empty arguments string.
    try std.testing.expectEqualStrings("", extractDeltaTCArgs(SSE_TC_HEADER).?);
    // Argument fragment chunks return the raw JSON-escaped body.
    try std.testing.expectEqualStrings("{\\\"command\\\": ", extractDeltaTCArgs(SSE_TC_ARGS1).?);
    try std.testing.expectEqualStrings("\\\"ls /tmp\\\"", extractDeltaTCArgs(SSE_TC_ARGS2).?);
    try std.testing.expectEqualStrings("}", extractDeltaTCArgs(SSE_TC_ARGS3).?);
    // Non-tool chunks → null.
    try std.testing.expect(extractDeltaTCArgs(SSE_CONTENT) == null);
}

// Pretty-printed SSE chunks: a space after every colon and around the
// tool_calls array/object openers, as some OpenAI-compatible servers emit.
// The streaming extractors must parse these identically to the compact ones
// (issue #67, the SSE twin of #65).
const SSE_TC_SPACED = "{\"id\": \"e34d\",\"choices\": [{\"delta\": {\"content\": null,\"tool_calls\": [ { \"index\": 0,\"id\": \"call_1\",\"function\": {\"arguments\": \"{\\\"path\\\": \",\"name\": \"bash\"},\"type\": \"function\"} ],\"reasoning_content\": null},\"finish_reason\": null}]}";
const SSE_REASONING_SPACED = "{\"choices\": [{\"delta\": {\"reasoning_content\": \"thinking hard\",\"tool_calls\": null}}]}";

test "streaming extractors tolerate whitespace after colons (spaced SSE, #67)" {
    // Reasoning delta with a space after the colon.
    try std.testing.expectEqualStrings("thinking hard", extractDeltaReasoning(SSE_REASONING_SPACED).?);
    try std.testing.expect(!hasDeltaToolCall(SSE_REASONING_SPACED));

    // Spaced tool-call header: detection + every field must resolve.
    try std.testing.expect(hasDeltaToolCall(SSE_TC_SPACED));
    try std.testing.expectEqual(@as(usize, 0), extractDeltaTCIndex(SSE_TC_SPACED).?);
    try std.testing.expectEqualStrings("call_1", extractDeltaTCId(SSE_TC_SPACED).?);
    try std.testing.expectEqualStrings("bash", extractDeltaTCName(SSE_TC_SPACED).?);
    try std.testing.expectEqualStrings("{\\\"path\\\": ", extractDeltaTCArgs(SSE_TC_SPACED).?);
    // reasoning_content is null here → no reasoning delta.
    try std.testing.expect(extractDeltaReasoning(SSE_TC_SPACED) == null);
}

test "tool_call fragment accumulation and unescape round-trip" {
    // Simulate the accumulation loop: concatenate raw argument fragments across
    // SSE_TC_HEADER, SSE_TC_ARGS1, SSE_TC_ARGS2, SSE_TC_ARGS3.
    const gpa = std.testing.allocator;
    var args_raw = std.ArrayList(u8).empty;
    defer args_raw.deinit(gpa);

    const chunks = [_][]const u8{ SSE_TC_HEADER, SSE_TC_ARGS1, SSE_TC_ARGS2, SSE_TC_ARGS3 };
    for (chunks) |chunk| {
        if (extractDeltaTCArgs(chunk)) |frag| try args_raw.appendSlice(gpa, frag);
    }
    // args_raw is the concatenated raw escaped body.
    const result = try jsonmod.unescapeAlloc(gpa, args_raw.items);
    defer gpa.free(result);
    try std.testing.expectEqualStrings("{\"command\": \"ls /tmp\"}", result);
}

test "extractUsage parses total_tokens from API response JSON" {
    // Happy path: standard usage object.
    const a = "{\"usage\":{\"total_tokens\":42}}";
    try std.testing.expectEqual(@as(u64, 42), extractUsage(a).?);

    // Zero tokens.
    const b = "{\"usage\":{\"total_tokens\":0}}";
    try std.testing.expectEqual(@as(u64, 0), extractUsage(b).?);

    // Large number (18 quintillion).
    const c = "{\"usage\":{\"total_tokens\":18446744073709551615}}";
    try std.testing.expectEqual(@as(u64, 18446744073709551615), extractUsage(c).?);

    // No usage object at all.
    const d = "{\"choices\":[{\"message\":{\"content\":\"hi\"}}]}";
    try std.testing.expect(extractUsage(d) == null);

    // total_tokens present but null.
    const e = "{\"usage\":{\"total_tokens\":null}}";
    try std.testing.expect(extractUsage(e) == null);

    // Empty string.
    try std.testing.expect(extractUsage("") == null);
}