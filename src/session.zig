const std = @import("std");
const provider = @import("llm/provider.zig");

/// Persistent goal state attached to a session.
pub const GoalState = struct {
    objective: []const u8,
    /// "active" | "paused" | "complete" | "budget_limited"
    status: []const u8 = "active",
    /// How many times this session has been resumed to continue the goal.
    continues: u32 = 0,
    /// Estimated output tokens spent toward the goal (for the soft budget).
    tokens_used: u64 = 0,
    token_budget: ?u64 = null,
};

/// Full persisted session: conversation history + optional goal.
/// `messages` uses provider.Message directly (role/content/tool_call_id?/tool_calls?),
/// which is JSON-serializable as-is.
pub const SessionState = struct {
    version: u32 = 1,
    name: []const u8,
    goal: ?GoalState = null,
    messages: []const provider.Message = &.{},
};

/// Reject names that could escape the sessions directory.
fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 128) return false;
    for (name) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '-' or c == '_' or c == '.';
        if (!ok) return false;
    }
    return !std.mem.eql(u8, name, "..") and !std.mem.eql(u8, name, ".");
}

/// <HOME>/.config/tau/sessions
pub fn sessionsDir(a: std.mem.Allocator, env: *std.process.Environ.Map) ?[]u8 {
    const home = env.get("HOME") orelse return null;
    return std.fmt.allocPrint(a, "{s}/.config/tau/sessions", .{home}) catch null;
}

/// <HOME>/.config/tau/sessions/<name>.json (null if HOME unset or bad name).
pub fn path(a: std.mem.Allocator, env: *std.process.Environ.Map, name: []const u8) ?[]u8 {
    if (!validName(name)) return null;
    const dir = sessionsDir(a, env) orelse return null;
    return std.fmt.allocPrint(a, "{s}/{s}.json", .{ dir, name }) catch null;
}

/// Load a session by name. Returns null if the file does not exist (or HOME/name
/// invalid). Parse errors propagate so a corrupt session is visible.
pub fn load(io: std.Io, arena: std.mem.Allocator, env: *std.process.Environ.Map, name: []const u8) !?SessionState {
    const p = path(arena, env, name) orelse return null;
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, p, arena, .unlimited) catch return null;
    return try std.json.parseFromSliceLeaky(SessionState, arena, bytes, .{
        .ignore_unknown_fields = true,
    });
}

/// Persist a session (creates ~/.config/tau/sessions as needed).
pub fn save(io: std.Io, gpa: std.mem.Allocator, env: *std.process.Environ.Map, state: SessionState) !void {
    const dir = sessionsDir(gpa, env) orelse return error.NoHome;
    defer gpa.free(dir);
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    const p = path(gpa, env, state.name) orelse return error.InvalidSessionName;
    defer gpa.free(p);
    const json = try std.json.Stringify.valueAlloc(gpa, state, .{ .whitespace = .indent_2 });
    defer gpa.free(json);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = json });
}

test "validName accepts safe names and rejects unsafe ones" {
    // safe
    try std.testing.expect(validName("my-session"));
    try std.testing.expect(validName("loop_author_0"));
    try std.testing.expect(validName("Session.v2"));
    try std.testing.expect(validName("a")); // minimum length

    // unsafe: traversal
    try std.testing.expect(!validName(".."));
    try std.testing.expect(!validName("."));
    try std.testing.expect(!validName("../../etc/passwd"));
    try std.testing.expect(!validName("foo/bar"));
    try std.testing.expect(!validName("foo\\bar"));
    try std.testing.expect(!validName("foo bar")); // space
    try std.testing.expect(!validName("foo:bar")); // colon
    try std.testing.expect(!validName("")); // empty
}

test "validName rejects names longer than 128 chars" {
    const long = "a" ** 129;
    try std.testing.expect(!validName(long));
    const max_ok = "a" ** 128;
    try std.testing.expect(validName(max_ok));
}

test "sessionsDir and path build correct paths" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const a = arena_inst.allocator();

    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", "/home/user");

    const dir = sessionsDir(a, &env).?;
    try std.testing.expectEqualStrings("/home/user/.config/tau/sessions", dir);

    const p = path(a, &env, "my-session").?;
    try std.testing.expectEqualStrings("/home/user/.config/tau/sessions/my-session.json", p);

    // Bad name → null, no allocation.
    try std.testing.expect(path(a, &env, "../escape") == null);
    try std.testing.expect(path(a, &env, "") == null);
}

test "sessionsDir returns null when HOME unset" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const a = arena_inst.allocator();

    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try std.testing.expect(sessionsDir(a, &env) == null);
    try std.testing.expect(path(a, &env, "s") == null);
}

test "session state round-trips through json" {
    const gpa = std.testing.allocator;
    const tcs = [_]provider.ToolCall{.{ .id = "c1", .name = "bash", .arguments = "{\"command\":\"echo hi\"}" }};
    const msgs = [_]provider.Message{
        .{ .role = "system", .content = "be terse" },
        .{ .role = "user", .content = "do it" },
        .{ .role = "assistant", .content = "", .tool_calls = &tcs },
        .{ .role = "tool", .content = "hi\n", .tool_call_id = "c1" },
    };
    const st = SessionState{
        .name = "t",
        .goal = .{ .objective = "ship", .status = "active", .continues = 2 },
        .messages = &msgs,
    };
    const json = try std.json.Stringify.valueAlloc(gpa, st, .{});
    defer gpa.free(json);

    var arena_inst = std.heap.ArenaAllocator.init(gpa);
    defer arena_inst.deinit();
    const a = arena_inst.allocator();
    const back = try std.json.parseFromSliceLeaky(SessionState, a, json, .{ .ignore_unknown_fields = true });

    try std.testing.expectEqual(@as(usize, 4), back.messages.len);
    try std.testing.expectEqualStrings("do it", back.messages[1].content);
    try std.testing.expectEqualStrings("c1", back.messages[3].tool_call_id.?);
    try std.testing.expectEqualStrings("bash", back.messages[2].tool_calls.?[0].name);
    try std.testing.expectEqualStrings("ship", back.goal.?.objective);
    try std.testing.expectEqual(@as(u32, 2), back.goal.?.continues);
}
