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

/// Serialize a span of messages into the transcript sent to the summarizer:
/// one "role: content" line each, with a "[tool_call name args]" line appended
/// for every tool call an assistant message made.
fn buildTranscript(gpa: std.mem.Allocator, items: []const Message) !std.ArrayList(u8) {
    var transcript: std.ArrayList(u8) = .empty;
    errdefer transcript.deinit(gpa);
    for (items) |m| {
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
    return transcript;
}

/// Assemble the post-compaction list: the original system message (if any),
/// then the generated summary message, then the verbatim recent tail.
fn rebuildWithSummary(gpa: std.mem.Allocator, items: []const Message, has_system: bool, tail_start: usize, summary_body: []const u8) !std.ArrayList(Message) {
    var rebuilt: std.ArrayList(Message) = .empty;
    errdefer rebuilt.deinit(gpa);
    if (has_system) try rebuilt.append(gpa, items[0]);
    try rebuilt.append(gpa, .{ .role = "system", .content = summary_body });
    for (items[tail_start..]) |m| try rebuilt.append(gpa, m);
    return rebuilt;
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
    var transcript = try buildTranscript(gpa, items[head..tail_start]);
    defer transcript.deinit(gpa);

    const sum_messages = [_]Message{
        .{ .role = "system", .content = SUMMARY_SYSTEM },
        .{ .role = "user", .content = transcript.items },
    };
    const resp = try provider.complete(io, gpa, cfg, &sum_messages, null);
    if (resp.tool_calls.len > 0) gpa.free(resp.tool_calls);
    const summary_body = try std.fmt.allocPrint(gpa, "[Earlier conversation summary]\n{s}", .{resp.content});
    gpa.free(resp.content);

    // Rebuild: [system?] + summary + verbatim tail.
    const rebuilt = try rebuildWithSummary(gpa, items, has_system, tail_start, summary_body);
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

test "estimateTokens: empty list and tool_call accounting" {
    try std.testing.expectEqual(@as(usize, 0), estimateTokens(&.{}));
    const tcs = [_]provider.ToolCall{.{ .id = "c1", .name = "bash", .arguments = "{}" }};
    const msgs = [_]Message{
        // tool_call name + arguments count toward the estimate: 4 + 2 = 6 chars.
        .{ .role = "assistant", .content = "", .tool_calls = &tcs },
    };
    try std.testing.expectEqual(@as(usize, 2), estimateTokens(&msgs));
}

test "estimateTokens: ceil rounding per message" {
    const msgs = [_]Message{
        .{ .role = "user", .content = "a" }, // 1 char -> 1 token
        .{ .role = "user", .content = "abcde" }, // 5 chars -> 2 tokens
        .{ .role = "user", .content = "" }, // 0 chars -> 0 tokens
    };
    try std.testing.expectEqual(@as(usize, 3), estimateTokens(&msgs));
}

test "shouldCompact: strict greater-than boundary and degenerate windows" {
    const Cfg = struct { auto_compact: bool, context_window: u32, compact_threshold: f32 };
    const big = "x" ** 4000; // exactly 1000 tokens
    const msgs = [_]Message{.{ .role = "user", .content = big }};
    // est == limit must NOT compact (comparison is >, not >=).
    try std.testing.expect(!shouldCompact(&msgs, Cfg{ .auto_compact = true, .context_window = 2000, .compact_threshold = 0.5 }));
    // est > limit compacts.
    try std.testing.expect(shouldCompact(&msgs, Cfg{ .auto_compact = true, .context_window = 1999, .compact_threshold = 0.5 }));
    // Degenerate zero window: any content compacts, empty history does not.
    try std.testing.expect(shouldCompact(&msgs, Cfg{ .auto_compact = true, .context_window = 0, .compact_threshold = 0.0 }));
    try std.testing.expect(!shouldCompact(&.{}, Cfg{ .auto_compact = true, .context_window = 0, .compact_threshold = 0.0 }));
}

test "safeTailStartByTokens: empty list and keep-everything budget" {
    try std.testing.expectEqual(@as(usize, 0), safeTailStartByTokens(&.{}, 100));
    const msgs = [_]Message{
        .{ .role = "user", .content = "hi" },
        .{ .role = "assistant", .content = "yo" },
    };
    // Budget larger than the whole list keeps everything verbatim.
    try std.testing.expectEqual(@as(usize, 0), safeTailStartByTokens(&msgs, 1_000_000));
}

test "safeTailStartByTokens: exact token-boundary accounting" {
    const big = "y" ** 400; // exactly 100 tokens each
    const msgs = [_]Message{
        .{ .role = "user", .content = big },
        .{ .role = "assistant", .content = big },
        .{ .role = "user", .content = big },
    };
    try std.testing.expectEqual(@as(usize, 2), safeTailStartByTokens(&msgs, 100));
    try std.testing.expectEqual(@as(usize, 1), safeTailStartByTokens(&msgs, 101));
    try std.testing.expectEqual(@as(usize, 1), safeTailStartByTokens(&msgs, 200)); // boundary is inclusive
    try std.testing.expectEqual(@as(usize, 0), safeTailStartByTokens(&msgs, 201));
}

test "safeTailStartByTokens: keep=0 still retains the last message" {
    const msgs = [_]Message{
        .{ .role = "user", .content = "a" },
        .{ .role = "assistant", .content = "b" },
    };
    try std.testing.expectEqual(@as(usize, 1), safeTailStartByTokens(&msgs, 0));
}

test "safeTailStartByTokens: backs off a multi-message tool group" {
    const tcs = [_]provider.ToolCall{
        .{ .id = "c1", .name = "bash", .arguments = "{}" },
        .{ .id = "c2", .name = "read", .arguments = "{}" },
    };
    const big = "y" ** 400; // ~100 tokens each
    const msgs = [_]Message{
        .{ .role = "user", .content = big },
        .{ .role = "assistant", .content = big, .tool_calls = &tcs },
        .{ .role = "tool", .content = big, .tool_call_id = "c1" },
        .{ .role = "tool", .content = big, .tool_call_id = "c2" },
        .{ .role = "assistant", .content = big },
    };
    // Naive boundary lands on the second tool message (index 3); the tail must
    // back off past BOTH tool messages to the assistant turn that owns them.
    try std.testing.expectEqual(@as(usize, 1), safeTailStartByTokens(&msgs, 200));
}

test "safeTailStartByTokens: tool-only history cannot back off below zero" {
    const msgs = [_]Message{
        .{ .role = "tool", .content = "x", .tool_call_id = "c1" },
        .{ .role = "tool", .content = "y", .tool_call_id = "c2" },
    };
    try std.testing.expectEqual(@as(usize, 0), safeTailStartByTokens(&msgs, 1));
}

test "safeTailStartByTokens: oversized single message becomes the whole tail" {
    const huge = "z" ** 40_000; // ~10000 tokens, far over the keep budget
    const msgs = [_]Message{
        .{ .role = "system", .content = "sys" },
        .{ .role = "user", .content = huge },
    };
    try std.testing.expectEqual(@as(usize, 1), safeTailStartByTokens(&msgs, 100));
    // A lone oversized message still yields index 0 (kept whole).
    const solo = [_]Message{.{ .role = "user", .content = huge }};
    try std.testing.expectEqual(@as(usize, 0), safeTailStartByTokens(&solo, 100));
}

test "buildTranscript: preserves order and formats tool_call lines" {
    const gpa = std.testing.allocator;
    const tcs = [_]provider.ToolCall{.{ .id = "c1", .name = "bash", .arguments = "{\"command\":\"ls\"}" }};
    const msgs = [_]Message{
        .{ .role = "user", .content = "list files" },
        .{ .role = "assistant", .content = "", .tool_calls = &tcs },
        .{ .role = "tool", .content = "file.txt", .tool_call_id = "c1" },
    };
    var t = try buildTranscript(gpa, &msgs);
    defer t.deinit(gpa);
    try std.testing.expectEqualStrings(
        "user: list files\n" ++
            "assistant: \n[tool_call bash {\"command\":\"ls\"}]\n" ++
            "tool: file.txt\n",
        t.items,
    );
}

test "rebuildWithSummary: keeps system message then summary then tail in order" {
    const gpa = std.testing.allocator;
    const msgs = [_]Message{
        .{ .role = "system", .content = "orig sys" },
        .{ .role = "user", .content = "old q" },
        .{ .role = "assistant", .content = "old a" },
        .{ .role = "user", .content = "recent q" },
        .{ .role = "assistant", .content = "recent a" },
    };
    var rebuilt = try rebuildWithSummary(gpa, &msgs, true, 3, "[Earlier conversation summary]\nbrief");
    defer rebuilt.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 4), rebuilt.items.len);
    try std.testing.expectEqualStrings("system", rebuilt.items[0].role);
    try std.testing.expectEqualStrings("orig sys", rebuilt.items[0].content);
    try std.testing.expectEqualStrings("system", rebuilt.items[1].role);
    try std.testing.expectEqualStrings("[Earlier conversation summary]\nbrief", rebuilt.items[1].content);
    // Verbatim tail, original order.
    try std.testing.expectEqualStrings("recent q", rebuilt.items[2].content);
    try std.testing.expectEqualStrings("recent a", rebuilt.items[3].content);
}

test "rebuildWithSummary: without a system message the summary leads" {
    const gpa = std.testing.allocator;
    const msgs = [_]Message{
        .{ .role = "user", .content = "old" },
        .{ .role = "assistant", .content = "recent" },
    };
    var rebuilt = try rebuildWithSummary(gpa, &msgs, false, 1, "sum");
    defer rebuilt.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), rebuilt.items.len);
    try std.testing.expectEqualStrings("system", rebuilt.items[0].role);
    try std.testing.expectEqualStrings("sum", rebuilt.items[0].content);
    try std.testing.expectEqualStrings("recent", rebuilt.items[1].content);
}

test "compact: returns early leaving list unchanged when middle is too small" {
    const gpa = std.testing.allocator;
    // Default keep budget (20k) dwarfs this history, so tail_start = 0 and
    // compact() must return before any summarization attempt (no HTTP call).
    const cfg = @import("config.zig").Config{};
    var messages: std.ArrayList(Message) = .empty;
    defer messages.deinit(gpa);
    try messages.append(gpa, .{ .role = "system", .content = "sys" });
    try messages.append(gpa, .{ .role = "user", .content = "hi" });
    try compact(std.testing.io, gpa, cfg, &messages);
    try std.testing.expectEqual(@as(usize, 2), messages.items.len);
    try std.testing.expectEqualStrings("hi", messages.items[1].content);
}
