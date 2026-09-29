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
    defer a.free(dir);
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

// ---- property / fuzz-style tests --------------------------------------------

/// Independent oracle for validName: every byte must be in the portable
/// filename charset, length must be 1..=128, and "." / ".." are rejected.
fn oracleValidName(name: []const u8) bool {
    if (name.len < 1 or name.len > 128) return false;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    for (name) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '_', '.' => {},
        else => return false,
    };
    return true;
}

test "property: validName verdict matches the charset oracle on random names" {
    var prng = std.Random.DefaultPrng.init(0x9a11);
    const rng = prng.random();
    // Hostile alphabet: separators, traversal dots, spaces, escapes, and
    // enough ordinary chars that valid names also appear.
    const alphabet = "abcdzAZ09-_. .../\\~!@#$%^&*()";
    var buf: [200]u8 = undefined;
    for (0..4000) |i| {
        // Bias every third case toward tiny lengths so "." and ".." show up.
        const len = if (i % 3 == 0)
            rng.uintLessThan(usize, 4)
        else
            rng.uintLessThan(usize, buf.len + 1);
        for (buf[0..len]) |*b| b.* = alphabet[rng.uintLessThan(usize, alphabet.len)];
        const name = buf[0..len];
        try std.testing.expectEqual(oracleValidName(name), validName(name));
    }
}

/// Random JSON-safe (valid UTF-8) string: a mix of ASCII, quote/backslash/
/// control bytes that must survive escaping, and multi-byte codepoints.
fn randString(gpa: std.mem.Allocator, rng: std.Random, max_len: usize) ![]u8 {
    const frags = [_][]const u8{
        "a",        "z",       "A",    "Z",       "0",        "9",
        "-",        "_",       ".",    " ",       "\"",       "\\",
        "\n",       "\t",      "\r",   "\x07",    "\x0b",     "\x1f",
        "/",        "{",       "}",    "[",       "]",        ":",
        ",",        "\x7f",    "é",    "ü",       "€",        "🎉",
        "plain ",   "日本語", "</x>",  "null",    "true",     "~",
    };
    const len = rng.uintLessThan(usize, max_len + 1);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (0..len) |_| {
        try out.appendSlice(gpa, frags[rng.uintLessThan(usize, frags.len)]);
    }
    return out.toOwnedSlice(gpa);
}

fn randToolCall(gpa: std.mem.Allocator, rng: std.Random) !provider.ToolCall {
    return .{
        .id = try randString(gpa, rng, 16),
        .name = try randString(gpa, rng, 12),
        .arguments = try randString(gpa, rng, 48),
    };
}

fn randMessage(gpa: std.mem.Allocator, rng: std.Random) !provider.Message {
    const roles = [_][]const u8{ "system", "user", "assistant", "tool" };
    var msg = provider.Message{
        .role = roles[rng.uintLessThan(usize, roles.len)],
        .content = try randString(gpa, rng, 64),
    };
    if (rng.boolean()) msg.tool_call_id = try randString(gpa, rng, 16);
    if (rng.boolean()) {
        const n = rng.uintLessThan(usize, 4);
        const tcs = try gpa.alloc(provider.ToolCall, n);
        for (tcs) |*tc| tc.* = try randToolCall(gpa, rng);
        msg.tool_calls = tcs;
    }
    return msg;
}

fn randGoal(gpa: std.mem.Allocator, rng: std.Random) !GoalState {
    const statuses = [_][]const u8{ "active", "paused", "complete", "budget_limited" };
    var g = GoalState{
        .objective = try randString(gpa, rng, 48),
        .status = statuses[rng.uintLessThan(usize, statuses.len)],
        .continues = rng.int(u32),
        .tokens_used = rng.int(u64),
    };
    if (rng.boolean()) g.token_budget = rng.int(u64);
    return g;
}

fn randState(gpa: std.mem.Allocator, rng: std.Random, name: []const u8) !SessionState {
    var st = SessionState{
        .name = name,
        // Mostly the current version, occasionally arbitrary ints.
        .version = if (rng.boolean()) 1 else rng.int(u32),
    };
    if (rng.boolean()) st.goal = try randGoal(gpa, rng);
    const n = rng.uintLessThan(usize, 9);
    const msgs = try gpa.alloc(provider.Message, n);
    for (msgs) |*m| m.* = try randMessage(gpa, rng);
    st.messages = msgs;
    return st;
}

fn expectOptStr(expected: ?[]const u8, actual: ?[]const u8) !void {
    try std.testing.expect((expected == null) == (actual == null));
    if (expected) |e| try std.testing.expectEqualStrings(e, actual.?);
}

fn expectMessageEqual(expected: provider.Message, actual: provider.Message) !void {
    try std.testing.expectEqualStrings(expected.role, actual.role);
    try std.testing.expectEqualStrings(expected.content, actual.content);
    try expectOptStr(expected.tool_call_id, actual.tool_call_id);
    try std.testing.expect((expected.tool_calls == null) == (actual.tool_calls == null));
    if (expected.tool_calls) |et| {
        const at = actual.tool_calls.?;
        try std.testing.expectEqual(et.len, at.len);
        for (et, at) |e, a| {
            try std.testing.expectEqualStrings(e.id, a.id);
            try std.testing.expectEqualStrings(e.name, a.name);
            try std.testing.expectEqualStrings(e.arguments, a.arguments);
        }
    }
}

fn expectStateEqual(expected: SessionState, actual: SessionState) !void {
    try std.testing.expectEqual(expected.version, actual.version);
    try std.testing.expectEqualStrings(expected.name, actual.name);
    try std.testing.expect((expected.goal == null) == (actual.goal == null));
    if (expected.goal) |eg| {
        const ag = actual.goal.?;
        try std.testing.expectEqualStrings(eg.objective, ag.objective);
        try std.testing.expectEqualStrings(eg.status, ag.status);
        try std.testing.expectEqual(eg.continues, ag.continues);
        try std.testing.expectEqual(eg.tokens_used, ag.tokens_used);
        try std.testing.expect((eg.token_budget == null) == (ag.token_budget == null));
        if (eg.token_budget) |b| try std.testing.expectEqual(b, ag.token_budget.?);
    }
    try std.testing.expectEqual(expected.messages.len, actual.messages.len);
    for (expected.messages, actual.messages) |em, am| try expectMessageEqual(em, am);
}

test "property: random SessionState survives a JSON round-trip" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const a = arena_inst.allocator();
    var prng = std.Random.DefaultPrng.init(0x5e55);
    const rng = prng.random();
    for (0..400) |i| {
        const st = try randState(a, rng, "prop");
        // Alternate between compact output and the indent_2 format save() uses.
        const json = try std.json.Stringify.valueAlloc(a, st, .{
            .whitespace = if (i % 2 == 0) .indent_2 else .minified,
        });
        const back = try std.json.parseFromSliceLeaky(SessionState, a, json, .{
            .ignore_unknown_fields = true,
        });
        try expectStateEqual(st, back);
    }
}

/// A throwaway HOME rooted at a fresh tmp dir (mirrors configfile.zig's
/// TestHome): path()/save()/load() resolve <HOME>/.config/tau/sessions via
/// cwd(), so a relative path is fine.
const SessionHome = struct {
    tmp: std.testing.TmpDir,
    env: std.process.Environ.Map,
    home: []const u8,

    fn init(arena: std.mem.Allocator) !SessionHome {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const home = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
        var env = std.process.Environ.Map.init(arena);
        try env.put("HOME", home);
        return .{ .tmp = tmp, .env = env, .home = home };
    }

    fn writeRaw(self: *SessionHome, arena: std.mem.Allocator, name: []const u8, content: []const u8) !void {
        const io = std.testing.io;
        const dir = try std.fmt.allocPrint(arena, "{s}/.config/tau/sessions", .{self.home});
        try std.Io.Dir.cwd().createDirPath(io, dir);
        const p = try std.fmt.allocPrint(arena, "{s}/{s}.json", .{ dir, name });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = content });
    }

    fn deinit(self: *SessionHome) void {
        self.tmp.cleanup();
    }
};

test "save/load: random SessionState round-trips through the filesystem" {
    // path() leaks sessionsDir() by design — run everything on an arena so the
    // testing allocator does not report it.
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const a = arena_inst.allocator();
    const io = std.testing.io;

    var th = try SessionHome.init(a);
    defer th.deinit();

    var prng = std.Random.DefaultPrng.init(0xf17e);
    const rng = prng.random();
    for (0..20) |i| {
        const name = try std.fmt.allocPrint(a, "prop-{d}", .{i});
        const st = try randState(a, rng, name);
        try save(io, a, &th.env, st);
        const back = (try load(io, a, &th.env, name)).?;
        try expectStateEqual(st, back);
    }
}

test "load: missing file returns null, corrupt or mistyped file propagates a parse error" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const a = arena_inst.allocator();
    const io = std.testing.io;

    var th = try SessionHome.init(a);
    defer th.deinit();

    // Missing file -> null (fresh sessions are not an error).
    try std.testing.expect((try load(io, a, &th.env, "missing")) == null);
    // Invalid name -> null before touching the filesystem.
    try std.testing.expect((try load(io, a, &th.env, "../escape")) == null);

    // Corrupt / truncated / mistyped files must surface an error, NOT silently
    // degrade to an empty session (that would drop conversation history).
    try th.writeRaw(a, "truncated", "{\"version\":1,\"name\":\"truncated\",\"messages\":[{");
    try th.writeRaw(a, "garbage", "this is not json");
    try th.writeRaw(a, "mistyped", "{\"version\":1,\"name\":\"mistyped\",\"messages\":\"nope\"}");
    for ([_][]const u8{ "truncated", "garbage", "mistyped" }) |name| {
        if (load(io, a, &th.env, name)) |_| {
            return error.TestExpectedError;
        } else |_| {}
    }
}

test "load: unknown fields are ignored and version is surfaced" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const a = arena_inst.allocator();
    const io = std.testing.io;

    var th = try SessionHome.init(a);
    defer th.deinit();

    try th.writeRaw(a, "future",
        \\{"version":99,"name":"future","messages":[],"future_field":{"x":[1,2,3]}}
    );
    const st = (try load(io, a, &th.env, "future")).?;
    try std.testing.expectEqual(@as(u32, 99), st.version);
    try std.testing.expectEqualStrings("future", st.name);
    try std.testing.expectEqual(@as(usize, 0), st.messages.len);
}
