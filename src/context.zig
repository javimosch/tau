const std = @import("std");
const provider = @import("llm/provider.zig");
const Message = provider.Message;

/// Structured summarization directive (modeled on pi's SUMMARIZATION_SYSTEM_PROMPT):
/// preserve goal, decisions, file paths, tool results/errors, and pending work.
const SUMMARY_SYSTEM =
    "You are compacting a long agent conversation to free up context. Summarize " ++
    "the transcript below into a concise but complete brief. PRESERVE exactly: the " ++
    "task/goal, key decisions and rationale, every file path read or written, " ++
    "important tool results and errors, and any work still in progress or pending. " ++
    "Do NOT invent anything. Output only the summary prose, no preamble.";

/// Estimated tokens for one message: content + tool-call name/args, chars/4 (ceil).
fn msgTokens(m: Message) usize {
    var chars: usize = m.content.len;
    if (m.tool_calls) |tcs| for (tcs) |tc| {
        chars += tc.name.len + tc.arguments.len;
    };
    return (chars + 3) / 4;
}

/// Conservative chars/4 token estimate for the whole message list.
pub fn estimateTokens(messages: []const Message) usize {
    var total: usize = 0;
    for (messages) |m| total += msgTokens(m);
    return total;
}

/// True when auto-compaction is on and estimated usage exceeds the configured
/// fraction of the model context window.
pub fn shouldCompact(messages: []const Message, cfg: anytype) bool {
    if (!cfg.auto_compact) return false;
    const est: f32 = @floatFromInt(estimateTokens(messages));
    const limit = @as(f32, @floatFromInt(cfg.context_window)) * cfg.compact_threshold;
    return est > limit;
}

/// Index where the verbatim-kept tail begins: walk back from the end accumulating
/// tokens until `keep_recent_tokens` is reached, then back off any leading `tool`
/// messages so the tail never starts orphaned from the assistant `tool_calls`
/// turn that produced them. Never cuts in the middle of a tool group.
pub fn safeTailStartByTokens(messages: []const Message, keep_recent_tokens: u32) usize {
    if (messages.len == 0) return 0;
    var acc: usize = 0;
    var i: usize = messages.len;
    while (i > 0) {
        i -= 1;
        acc += msgTokens(messages[i]);
        if (acc >= keep_recent_tokens) break;
    }
    while (i > 0 and std.mem.eql(u8, messages[i].role, "tool")) : (i -= 1) {}
    return i;
}

/// Replace messages[head .. tail] with one LLM-generated summary message, keeping
/// the system message (if any) and the recent tail verbatim. Best-effort: on any
/// error the caller proceeds with the uncompacted list (wrap in `catch {}`).
/// `cfg` must already carry a resolved api_key.
pub fn compact(io: std.Io, gpa: std.mem.Allocator, cfg: anytype, messages: *std.ArrayList(Message)) !void {
    const items = messages.items;
    const has_system = items.len > 0 and std.mem.eql(u8, items[0].role, "system");
    const head: usize = if (has_system) 1 else 0;
    const tail_start = safeTailStartByTokens(items, cfg.compact_keep_recent_tokens);
    if (tail_start <= head + 1) return; // not enough middle to be worth summarizing

    // Serialize the span being summarized into a transcript.
    var transcript: std.ArrayList(u8) = .empty;
    defer transcript.deinit(gpa);
    for (items[head..tail_start]) |m| {
        try transcript.appendSlice(gpa, m.role);
        try transcript.appendSlice(gpa, ": ");
        try transcript.appendSlice(gpa, m.content);
        if (m.tool_calls) |tcs| for (tcs) |tc| {
            try transcript.appendSlice(gpa, "\n[tool_call ");
            try transcript.appendSlice(gpa, tc.name);
            try transcript.appendSlice(gpa, " ");
            try transcript.appendSlice(gpa, tc.arguments);
            try transcript.append(gpa, ']');
        };
        try transcript.append(gpa, '\n');
    }

    const sum_messages = [_]Message{
        .{ .role = "system", .content = SUMMARY_SYSTEM },
        .{ .role = "user", .content = transcript.items },
    };
    const resp = try provider.complete(io, gpa, cfg, &sum_messages, null);
    if (resp.tool_calls.len > 0) gpa.free(resp.tool_calls);
    const summary_body = try std.fmt.allocPrint(gpa, "[Earlier conversation summary]\n{s}", .{resp.content});
    gpa.free(resp.content);

    // Rebuild: [system?] + summary + verbatim tail.
    var rebuilt: std.ArrayList(Message) = .empty;
    errdefer rebuilt.deinit(gpa);
    if (has_system) try rebuilt.append(gpa, items[0]);
    try rebuilt.append(gpa, .{ .role = "system", .content = summary_body });
    for (items[tail_start..]) |m| try rebuilt.append(gpa, m);

    messages.deinit(gpa);
    messages.* = rebuilt;
}

test "estimateTokens chars/4" {
    const msgs = [_]Message{
        .{ .role = "user", .content = "12345678" }, // 8 chars -> 2 tokens
        .{ .role = "assistant", .content = "abcd" }, // 4 -> 1
    };
    try std.testing.expectEqual(@as(usize, 3), estimateTokens(&msgs));
}

test "shouldCompact threshold" {
    const Cfg = struct { auto_compact: bool, context_window: u32, compact_threshold: f32 };
    const big = "x" ** 4000; // 4000 chars -> 1000 tokens
    const msgs = [_]Message{.{ .role = "user", .content = big }};
    try std.testing.expect(shouldCompact(&msgs, Cfg{ .auto_compact = true, .context_window = 1000, .compact_threshold = 0.5 }));
    try std.testing.expect(!shouldCompact(&msgs, Cfg{ .auto_compact = true, .context_window = 10000, .compact_threshold = 0.5 }));
    try std.testing.expect(!shouldCompact(&msgs, Cfg{ .auto_compact = false, .context_window = 1000, .compact_threshold = 0.5 }));
}

test "safeTailStart never starts on a tool message" {
    const tcs = [_]provider.ToolCall{.{ .id = "c1", .name = "bash", .arguments = "{}" }};
    const big = "y" ** 400; // ~100 tokens each
    const msgs = [_]Message{
        .{ .role = "system", .content = "sys" },
        .{ .role = "user", .content = big },
        .{ .role = "assistant", .content = big, .tool_calls = &tcs },
        .{ .role = "tool", .content = big, .tool_call_id = "c1" }, // would-be boundary
        .{ .role = "assistant", .content = big },
    };
    // keep_recent small enough that the naive boundary lands on the tool msg.
    const start = safeTailStartByTokens(&msgs, 150);
    try std.testing.expect(!std.mem.eql(u8, msgs[start].role, "tool"));
}
