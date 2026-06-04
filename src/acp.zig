// ACP — Agent Client Protocol support for tau.
//
// ACP is JSON-RPC 2.0 between a client (editor) and an agent. Standard transport
// is stdio (the client spawns the agent). tau additionally supports running the
// server as a background daemon on a Unix socket, managed by:
//   tau acp start    -> spawn `tau acp serve --acp-socket ~/.config/tau/acp.sock` detached, write PID
//   tau acp stop     -> SIGTERM the daemon, remove pid + socket
//   tau acp status   -> report running/stopped (JSON)
//   tau acp serve    -> run the JSON-RPC server (stdio, or --acp-socket <path>)
//
// Implemented agent methods: initialize (version negotiation + agentInfo +
// capabilities), authenticate, session/new, session/load, session/prompt — which
// runs tau's full agentic tool loop and streams it as ACP session/update
// notifications (tool_call -> tool_call_update -> agent_message_chunk) ending in
// a PromptResponse{stopReason}. session/cancel is a notification. Unknown methods
// return JSON-RPC error -32601. Newline-delimited JSON-RPC over stdio (standard)
// or a Unix socket.
const std = @import("std");
const provider = @import("llm/provider.zig");
const registry = @import("tools/registry.zig");
const agentmod = @import("agent.zig");
const session_mod = @import("session.zig");
const cfgmod = @import("config.zig");
const jsonmod = @import("json.zig");

const linux = std.os.linux;

/// Wall-clock milliseconds (for unique session ids).
fn nowMillis(io: std.Io) i64 {
    return std.Io.Clock.Timestamp.now(io, .real).raw.toMilliseconds();
}

pub const Sub = cfgmod.AcpSub;

const PROTOCOL_VERSION = 1;

fn writeErr(s: []const u8) void {
    _ = linux.write(2, s.ptr, s.len);
}

// ---- paths -----------------------------------------------------------------

fn configDir(arena: std.mem.Allocator, env: *std.process.Environ.Map) ?[]u8 {
    const home = env.get("HOME") orelse return null;
    return std.fmt.allocPrint(arena, "{s}/.config/tau", .{home}) catch null;
}

fn pidPath(arena: std.mem.Allocator, env: *std.process.Environ.Map) ?[]u8 {
    const dir = configDir(arena, env) orelse return null;
    return std.fmt.allocPrint(arena, "{s}/acp.pid", .{dir}) catch null;
}

fn defaultSocket(arena: std.mem.Allocator, env: *std.process.Environ.Map) ?[]u8 {
    const dir = configDir(arena, env) orelse return null;
    return std.fmt.allocPrint(arena, "{s}/acp.sock", .{dir}) catch null;
}

/// Returns the pid stored in the pid file if that process is alive, else null
/// (and a stale pid file is treated as not-running).
fn readLivePid(io: std.Io, arena: std.mem.Allocator, env: *std.process.Environ.Map) ?i32 {
    const pp = pidPath(arena, env) orelse return null;
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, pp, arena, .unlimited) catch return null;
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    const pid = std.fmt.parseInt(i32, trimmed, 10) catch return null;
    // /proc/<pid> existence = alive (Linux).
    const proc = std.fmt.allocPrint(arena, "/proc/{d}/comm", .{pid}) catch return null;
    _ = std.Io.Dir.cwd().readFileAlloc(io, proc, arena, .unlimited) catch return null;
    return pid;
}

// ---- entry -----------------------------------------------------------------

pub fn run(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    cfg: anytype,
    env: *std.process.Environ.Map,
    sub: Sub,
    socket_opt: ?[]const u8,
) !u8 {
    return switch (sub) {
        .serve => serve(io, gpa, cfg, env, socket_opt),
        .start => start(io, arena, env, socket_opt),
        .stop => stop(io, arena, env),
        .status => status(io, arena, env),
    };
}

// ---- daemon management -----------------------------------------------------

fn start(io: std.Io, arena: std.mem.Allocator, env: *std.process.Environ.Map, socket_opt: ?[]const u8) !u8 {
    const dir = configDir(arena, env) orelse {
        writeErr("{\"err\":{\"code\":82,\"message\":\"HOME not set\"}}\n");
        return 82;
    };
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    const sock = socket_opt orelse (defaultSocket(arena, env) orelse return 110);
    const pp = pidPath(arena, env) orelse return 110;

    if (readLivePid(io, arena, env)) |pid| {
        const msg = try std.fmt.allocPrint(arena, "{{\"acp\":{{\"running\":true,\"pid\":{d},\"socket\":\"{s}\",\"note\":\"already running\"}}}}\n", .{ pid, sock });
        _ = linux.write(1, msg.ptr, msg.len);
        return 0;
    }

    const exe = try std.process.executablePathAlloc(io, arena);
    const logp = try std.fmt.allocPrint(arena, "{s}/acp.log", .{dir});
    const logf = std.Io.Dir.cwd().createFile(io, logp, .{}) catch null;

    const child = try std.process.spawn(io, .{
        .argv = &.{ exe, "acp", "serve", "--acp-socket", sock },
        .stdin = .ignore,
        .stdout = if (logf) |f| .{ .file = f } else .ignore,
        .stderr = if (logf) |f| .{ .file = f } else .ignore,
    });
    // Detach: record the pid and let it run. Do NOT wait or kill.
    const pid: i32 = @intCast(child.id orelse 0);
    var pbuf: [16]u8 = undefined;
    const pidstr = std.fmt.bufPrint(&pbuf, "{d}", .{pid}) catch "0";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = pp, .data = pidstr });

    const msg = try std.fmt.allocPrint(arena, "{{\"acp\":{{\"running\":true,\"pid\":{d},\"socket\":\"{s}\"}}}}\n", .{ pid, sock });
    _ = linux.write(1, msg.ptr, msg.len);
    return 0;
}

fn stop(io: std.Io, arena: std.mem.Allocator, env: *std.process.Environ.Map) !u8 {
    const pid = readLivePid(io, arena, env) orelse {
        _ = linux.write(1, "{\"acp\":{\"running\":false,\"note\":\"not running\"}}\n".ptr, 47);
        // clean up any stale files
        if (pidPath(arena, env)) |pp| std.Io.Dir.cwd().deleteFile(io, pp) catch {};
        return 0;
    };
    std.posix.kill(pid, .TERM) catch {};
    if (pidPath(arena, env)) |pp| std.Io.Dir.cwd().deleteFile(io, pp) catch {};
    if (defaultSocket(arena, env)) |s| std.Io.Dir.cwd().deleteFile(io, s) catch {};
    const msg = try std.fmt.allocPrint(arena, "{{\"acp\":{{\"running\":false,\"stopped_pid\":{d}}}}}\n", .{pid});
    _ = linux.write(1, msg.ptr, msg.len);
    return 0;
}

fn status(io: std.Io, arena: std.mem.Allocator, env: *std.process.Environ.Map) !u8 {
    if (readLivePid(io, arena, env)) |pid| {
        const sock = defaultSocket(arena, env) orelse "";
        const msg = try std.fmt.allocPrint(arena, "{{\"acp\":{{\"running\":true,\"pid\":{d},\"socket\":\"{s}\"}}}}\n", .{ pid, sock });
        _ = linux.write(1, msg.ptr, msg.len);
    } else {
        _ = linux.write(1, "{\"acp\":{\"running\":false}}\n".ptr, 25);
    }
    return 0;
}

// ---- server ----------------------------------------------------------------

fn serve(io: std.Io, gpa: std.mem.Allocator, cfg: anytype, env: *std.process.Environ.Map, socket_opt: ?[]const u8) !u8 {
    var cfg2 = cfg;
    cfg2.api_key = cfgmod.resolveApiKey(cfg, env);

    const rbuf = try gpa.alloc(u8, 1 << 18);
    defer gpa.free(rbuf);
    const wbuf = try gpa.alloc(u8, 1 << 18);
    defer gpa.free(wbuf);

    if (socket_opt) |sockpath| {
        std.Io.Dir.cwd().deleteFile(io, sockpath) catch {}; // clear stale socket
        const ua = try std.Io.net.UnixAddress.init(sockpath);
        var server = ua.listen(io, .{}) catch |err| {
            const m = try std.fmt.allocPrint(gpa, "acp: listen failed on {s}: {s}\n", .{ sockpath, @errorName(err) });
            writeErr(m);
            return 110;
        };
        defer server.deinit(io);
        while (true) {
            var stream = server.accept(io) catch break;
            var sr = stream.reader(io, rbuf);
            var sw = stream.writer(io, wbuf);
            serveConn(io, gpa, cfg2, env, &sr.interface, &sw.interface) catch {};
            stream.close(io);
        }
        return 0;
    }

    // stdio transport (standard ACP — the client spawned us)
    var fr = std.Io.File.stdin().reader(io, rbuf);
    var fw = std.Io.File.stdout().writer(io, wbuf);
    serveConn(io, gpa, cfg2, env, &fr.interface, &fw.interface) catch {};
    return 0;
}

fn serveConn(io: std.Io, gpa: std.mem.Allocator, cfg: anytype, env: *std.process.Environ.Map, r: *std.Io.Reader, w: *std.Io.Writer) !void {
    while (true) {
        const line = (r.takeDelimiter('\n') catch return) orelse return;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        handleMessage(io, gpa, cfg, env, r, trimmed, w) catch |err| {
            const m = std.fmt.allocPrint(gpa, "acp: message error: {s}\n", .{@errorName(err)}) catch continue;
            defer gpa.free(m);
            writeErr(m);
        };
    }
}

fn writeLine(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeAll(s);
    try w.writeByte('\n');
    try w.flush();
}

var session_counter: u32 = 0;
// Client capabilities learned at initialize; used to route mutating tools
// through the editor's fs methods so edits land as approvable diffs.
var client_fs_read: bool = false;
var client_fs_write: bool = false;
var fs_req_counter: u64 = 0;

fn handleMessage(io: std.Io, gpa: std.mem.Allocator, cfg: anytype, env: *std.process.Environ.Map, r: *std.Io.Reader, line: []const u8, w: *std.Io.Writer) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, line, .{}) catch {
        return; // not valid JSON; ignore (cannot form a proper error without an id)
    };
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const obj = parsed.value.object;

    const method = blk: {
        const m = obj.get("method") orelse return;
        break :blk if (m == .string) m.string else return;
    };
    const id_val = obj.get("id"); // absent => notification
    const params = obj.get("params");

    if (std.mem.eql(u8, method, "initialize")) {
        // Learn the client's fs capabilities so mutating tools can be routed
        // through fs/write_text_file (edits appear as diffs in the editor).
        if (params) |p| if (p == .object) if (p.object.get("clientCapabilities")) |cc| if (cc == .object) if (cc.object.get("fs")) |fs| if (fs == .object) {
            if (fs.object.get("readTextFile")) |b| {
                if (b == .bool) client_fs_read = b.bool;
            }
            if (fs.object.get("writeTextFile")) |b| {
                if (b == .bool) client_fs_write = b.bool;
            }
        };
        // Version negotiation: we support v1, so always answer v1 (== client's
        // version when they request 1; our latest otherwise, per spec).
        try respondResult(gpa, w, id_val,
            "{\"protocolVersion\":" ++ std.fmt.comptimePrint("{d}", .{PROTOCOL_VERSION}) ++
            ",\"agentCapabilities\":{\"loadSession\":false,\"promptCapabilities\":{\"image\":false,\"audio\":false,\"embeddedContext\":true}},\"authMethods\":[]," ++
            "\"agentInfo\":{\"name\":\"tau\",\"version\":\"0.2.0\"}}");
    } else if (std.mem.eql(u8, method, "authenticate")) {
        try respondResult(gpa, w, id_val, "{}");
    } else if (std.mem.eql(u8, method, "session/new")) {
        // Operate in the project directory the client passed (editors set cwd
        // to the workspace; honoring it makes relative-path tools work there).
        if (params) |p| if (p == .object) if (p.object.get("cwd")) |c| if (c == .string) {
            const z = gpa.dupeZ(u8, c.string) catch null;
            if (z) |zz| {
                _ = linux.chdir(zz.ptr);
                gpa.free(zz);
            }
        };
        session_counter += 1;
        // Unique, inspectable session id (timestamp + counter). Persist an empty
        // session file immediately so new ACP sessions show up on disk at
        // ~/.config/tau/sessions/<id>.json.
        const sid = try std.fmt.allocPrint(gpa, "acp-{d}-{d}", .{ nowMillis(io), session_counter });
        defer gpa.free(sid);
        session_mod.save(io, gpa, env, .{ .name = sid, .messages = &.{} }) catch {};
        const result = try std.fmt.allocPrint(gpa, "{{\"sessionId\":\"{s}\"}}", .{sid});
        defer gpa.free(result);
        try respondResult(gpa, w, id_val, result);
    } else if (std.mem.eql(u8, method, "session/load")) {
        try respondResult(gpa, w, id_val, "{}");
    } else if (std.mem.eql(u8, method, "session/prompt")) {
        try handlePrompt(io, gpa, cfg, env, r, w, id_val, params);
    } else if (std.mem.eql(u8, method, "session/cancel")) {
        // notification only — nothing to respond.
    } else if (id_val != null) {
        try respondError(gpa, w, id_val.?, -32601, "method not found");
    }
}

/// Extract a session id from params (or "unknown").
fn paramSessionId(params: ?std.json.Value, gpa: std.mem.Allocator) []u8 {
    if (params) |p| if (p == .object) if (p.object.get("sessionId")) |s| if (s == .string)
        return gpa.dupe(u8, s.string) catch gpa.dupe(u8, "unknown") catch unreachable;
    return gpa.dupe(u8, "unknown") catch unreachable;
}

/// Concatenate the text of all text content blocks in params.prompt.
fn paramPromptText(params: ?std.json.Value, gpa: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    if (params) |p| if (p == .object) {
        if (p.object.get("prompt")) |pr| switch (pr) {
            .string => |s| try out.appendSlice(gpa, s),
            .array => |arr| for (arr.items) |blk| {
                if (blk == .object) if (blk.object.get("text")) |t| if (t == .string) {
                    if (out.items.len > 0) try out.append(gpa, '\n');
                    try out.appendSlice(gpa, t.string);
                };
            },
            else => {},
        };
    };
    return out.toOwnedSlice(gpa);
}

/// Map a tool name to an ACP tool-call kind.
fn toolKind(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "bash")) return "execute";
    if (std.mem.eql(u8, name, "read") or std.mem.eql(u8, name, "ls")) return "read";
    if (std.mem.eql(u8, name, "write") or std.mem.eql(u8, name, "edit")) return "edit";
    if (std.mem.eql(u8, name, "grep") or std.mem.eql(u8, name, "find")) return "search";
    return "other";
}

fn emitMessageChunk(gpa: std.mem.Allocator, w: *std.Io.Writer, sid: []const u8, text: []const u8) !void {
    const se = try jsonmod.escapeAlloc(gpa, sid);
    defer gpa.free(se);
    const te = try jsonmod.escapeAlloc(gpa, text);
    defer gpa.free(te);
    const n = try std.fmt.allocPrint(gpa, "{{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{{\"sessionId\":\"{s}\",\"update\":{{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{{\"type\":\"text\",\"text\":\"{s}\"}}}}}}}}", .{ se, te });
    defer gpa.free(n);
    try writeLine(w, n);
}

fn emitToolCall(gpa: std.mem.Allocator, w: *std.Io.Writer, sid: []const u8, id: []const u8, title: []const u8, kind: []const u8, raw_args: []const u8) !void {
    const se = try jsonmod.escapeAlloc(gpa, sid);
    defer gpa.free(se);
    const ide = try jsonmod.escapeAlloc(gpa, id);
    defer gpa.free(ide);
    const te = try jsonmod.escapeAlloc(gpa, title);
    defer gpa.free(te);
    // rawInput is an object; embed the model's args JSON verbatim if it looks
    // like an object, else an empty object.
    const raw = if (raw_args.len > 0 and raw_args[0] == '{') raw_args else "{}";
    const n = try std.fmt.allocPrint(gpa, "{{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{{\"sessionId\":\"{s}\",\"update\":{{\"sessionUpdate\":\"tool_call\",\"toolCallId\":\"{s}\",\"title\":\"{s}\",\"kind\":\"{s}\",\"status\":\"pending\",\"rawInput\":{s}}}}}}}", .{ se, ide, te, kind, raw });
    defer gpa.free(n);
    try writeLine(w, n);
}

fn emitToolCallUpdate(gpa: std.mem.Allocator, w: *std.Io.Writer, sid: []const u8, id: []const u8, st: []const u8, content_text: []const u8) !void {
    const se = try jsonmod.escapeAlloc(gpa, sid);
    defer gpa.free(se);
    const ide = try jsonmod.escapeAlloc(gpa, id);
    defer gpa.free(ide);
    const ce = try jsonmod.escapeAlloc(gpa, content_text);
    defer gpa.free(ce);
    const n = try std.fmt.allocPrint(gpa, "{{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{{\"sessionId\":\"{s}\",\"update\":{{\"sessionUpdate\":\"tool_call_update\",\"toolCallId\":\"{s}\",\"status\":\"{s}\",\"content\":[{{\"type\":\"content\",\"content\":{{\"type\":\"text\",\"text\":\"{s}\"}}}}]}}}}}}", .{ se, ide, st, ce });
    defer gpa.free(n);
    try writeLine(w, n);
}

// ---- client-method calls (agent -> editor) ---------------------------------

/// Send a JSON-RPC request to the client and block until the matching response
/// arrives, returning the parsed response object. Notifications/unrelated
/// messages received meanwhile are ignored. `params_json` is the raw params JSON.
fn clientRequest(a: std.mem.Allocator, r: *std.Io.Reader, w: *std.Io.Writer, method: []const u8, params_json: []const u8) !std.json.Value {
    fs_req_counter += 1;
    const reqid = try std.fmt.allocPrint(a, "tau-fs-{d}", .{fs_req_counter});
    const msg = try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":\"{s}\",\"method\":\"{s}\",\"params\":{s}}}", .{ reqid, method, params_json });
    try writeLine(w, msg);
    while (true) {
        const line = (r.takeDelimiter('\n') catch return error.AcpClosed) orelse return error.AcpClosed;
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len == 0) continue;
        const v = std.json.parseFromSliceLeaky(std.json.Value, a, t, .{}) catch continue;
        if (v != .object) continue;
        if (v.object.get("id")) |iv| {
            if (iv == .string and std.mem.eql(u8, iv.string, reqid)) return v;
        }
        // a notification (e.g. session/cancel) arrived during our call — ignore.
    }
}

/// Write a file via the editor (fs/write_text_file) so the change shows as a diff.
fn clientWriteFile(a: std.mem.Allocator, r: *std.Io.Reader, w: *std.Io.Writer, sid: []const u8, path: []const u8, content: []const u8) !void {
    const se = try jsonmod.escapeAlloc(a, sid);
    const pe = try jsonmod.escapeAlloc(a, path);
    const ce = try jsonmod.escapeAlloc(a, content);
    const params = try std.fmt.allocPrint(a, "{{\"sessionId\":\"{s}\",\"path\":\"{s}\",\"content\":\"{s}\"}}", .{ se, pe, ce });
    const resp = try clientRequest(a, r, w, "fs/write_text_file", params);
    if (resp.object.get("error") != null) return error.ClientWriteFailed;
}

/// Read a file via the editor (fs/read_text_file) — sees unsaved buffer content.
fn clientReadFile(a: std.mem.Allocator, r: *std.Io.Reader, w: *std.Io.Writer, sid: []const u8, path: []const u8) ![]const u8 {
    const se = try jsonmod.escapeAlloc(a, sid);
    const pe = try jsonmod.escapeAlloc(a, path);
    const params = try std.fmt.allocPrint(a, "{{\"sessionId\":\"{s}\",\"path\":\"{s}\"}}", .{ se, pe });
    const resp = try clientRequest(a, r, w, "fs/read_text_file", params);
    const result = resp.object.get("result") orelse return error.ClientReadFailed;
    if (result == .object) if (result.object.get("content")) |c| if (c == .string) return c.string;
    return error.ClientReadFailed;
}

/// Replace all occurrences of `needle` with `repl` (arena-allocated).
fn replaceAlloc(a: std.mem.Allocator, s: []const u8, needle: []const u8, repl: []const u8) ![]u8 {
    if (needle.len == 0) return a.dupe(u8, s);
    var out: std.ArrayList(u8) = .empty;
    var rest = s;
    while (std.mem.indexOf(u8, rest, needle)) |idx| {
        try out.appendSlice(a, rest[0..idx]);
        try out.appendSlice(a, repl);
        rest = rest[idx + needle.len ..];
    }
    try out.appendSlice(a, rest);
    return out.toOwnedSlice(a);
}

/// Run a full prompt turn: load the persisted session, run tau's agentic tool
/// loop (streamed as ACP session/update notifications), persist the updated
/// conversation, then reply with a PromptResponse. All turn allocations live in
/// a per-turn arena (freed on return) so a long-running server stays bounded;
/// conversation state lives on disk at ~/.config/tau/sessions/<id>.json — which
/// is also what makes Zed usage inspectable. Mutating tools (write/edit) are
/// routed through the editor's fs methods when the client supports them, so the
/// changes appear as diffs instead of silent disk writes.
fn handlePrompt(io: std.Io, gpa: std.mem.Allocator, cfg: anytype, env: *std.process.Environ.Map, r: *std.Io.Reader, w: *std.Io.Writer, id_val: ?std.json.Value, params: ?std.json.Value) !void {
    var arena_inst = std.heap.ArenaAllocator.init(gpa);
    defer arena_inst.deinit();
    const a = arena_inst.allocator();

    if (cfg.api_key == null) {
        if (id_val) |idv| try respondError(a, w, idv, -32000, "no API key configured");
        return;
    }

    const sid = paramSessionId(params, a);
    const text = try paramPromptText(params, a);

    // Seed from the persisted session (multi-turn memory + on-disk inspection).
    var messages: std.ArrayList(provider.Message) = .empty;
    if (session_mod.load(io, a, env, sid) catch null) |st| {
        for (st.messages) |m| try messages.append(a, m);
    } else if (cfg.system_prompt) |sp| {
        try messages.append(a, .{ .role = "system", .content = sp });
    }
    try messages.append(a, .{ .role = "user", .content = text });

    const enabled = try registry.getEnabledTools(a, cfg.tools_allow, cfg.tools_deny);
    var tinfos: std.ArrayList(provider.ToolInfo) = .empty;
    for (enabled) |t| try tinfos.append(a, .{ .name = t.name, .description = t.description });
    const tools_arg: ?[]const provider.ToolInfo = if (cfg.no_tools) null else tinfos.items;

    const maxit: u32 = if (cfg.max_iterations > 0) cfg.max_iterations else 10;
    var iter: u32 = 0;
    var stop_reason: []const u8 = "max_turn_requests";

    while (iter < maxit) : (iter += 1) {
        const resp = provider.complete(io, a, cfg, messages.items, tools_arg) catch |err| {
            session_mod.save(io, a, env, .{ .name = sid, .messages = messages.items }) catch {};
            if (id_val) |idv| {
                const m = try std.fmt.allocPrint(a, "completion failed: {s}", .{@errorName(err)});
                try respondError(a, w, idv, -32001, m);
            }
            return;
        };

        if (resp.content.len > 0) try emitMessageChunk(a, w, sid, resp.content);
        try messages.append(a, .{
            .role = "assistant",
            .content = resp.content,
            .tool_calls = if (resp.tool_calls.len > 0) resp.tool_calls else null,
        });

        if (resp.tool_calls.len == 0) {
            stop_reason = "end_turn";
            break;
        }

        for (resp.tool_calls) |tc| {
            try emitToolCall(a, w, sid, tc.id, tc.name, toolKind(tc.name), tc.arguments);
            const args = agentmod.buildToolArgs(a, tc.name, tc.arguments) catch {
                try emitToolCallUpdate(a, w, sid, tc.id, "failed", "invalid tool arguments");
                try messages.append(a, .{ .role = "tool", .content = "invalid tool arguments", .tool_call_id = tc.id });
                continue;
            };

            // Route file mutations through the editor (fs/write_text_file) so the
            // change lands as an approvable diff. Falls back to direct execution
            // when the client has no fs capability.
            if (client_fs_write and std.mem.eql(u8, tc.name, "write") and args.len >= 2) {
                const ok = if (clientWriteFile(a, r, w, sid, args[0], args[1])) |_| true else |_| false;
                const out = if (ok) "file written via editor" else "editor write failed";
                try emitToolCallUpdate(a, w, sid, tc.id, if (ok) "completed" else "failed", out);
                try messages.append(a, .{ .role = "tool", .content = out, .tool_call_id = tc.id });
                continue;
            }
            if (client_fs_write and std.mem.eql(u8, tc.name, "edit") and args.len >= 3) {
                const cur = if (client_fs_read)
                    (clientReadFile(a, r, w, sid, args[0]) catch "")
                else
                    (std.Io.Dir.cwd().readFileAlloc(io, args[0], a, .unlimited) catch "");
                const newc = try replaceAlloc(a, cur, args[1], args[2]);
                const ok = if (clientWriteFile(a, r, w, sid, args[0], newc)) |_| true else |_| false;
                const out = if (ok) "file edited via editor" else "editor edit failed";
                try emitToolCallUpdate(a, w, sid, tc.id, if (ok) "completed" else "failed", out);
                try messages.append(a, .{ .role = "tool", .content = out, .tool_call_id = tc.id });
                continue;
            }

            // Otherwise execute tau's tool directly.
            const tool = registry.getTool(tc.name) orelse {
                try emitToolCallUpdate(a, w, sid, tc.id, "failed", "tool not found");
                try messages.append(a, .{ .role = "tool", .content = "tool not found", .tool_call_id = tc.id });
                continue;
            };
            const tr = tool.execute(io, a, args, cfg.timeout_ms) catch |err| {
                const em = try std.fmt.allocPrint(a, "execution failed: {s}", .{@errorName(err)});
                try emitToolCallUpdate(a, w, sid, tc.id, "failed", em);
                try messages.append(a, .{ .role = "tool", .content = em, .tool_call_id = tc.id });
                continue;
            };
            const out = if (tr.success) tr.stdout else tr.stderr;
            try emitToolCallUpdate(a, w, sid, tc.id, if (tr.success) "completed" else "failed", out);
            try messages.append(a, .{ .role = "tool", .content = out, .tool_call_id = tc.id });
        }
    }

    // Persist the full conversation (for inspection + next-turn memory).
    session_mod.save(io, a, env, .{ .name = sid, .messages = messages.items }) catch {};

    const result = try std.fmt.allocPrint(a, "{{\"stopReason\":\"{s}\"}}", .{stop_reason});
    try respondResult(a, w, id_val, result);
}

// ---- JSON-RPC response helpers ---------------------------------------------

fn idText(gpa: std.mem.Allocator, id_val: std.json.Value) ![]u8 {
    return std.json.Stringify.valueAlloc(gpa, id_val, .{});
}

fn respondResult(gpa: std.mem.Allocator, w: *std.Io.Writer, id_val: ?std.json.Value, result_json: []const u8) !void {
    const idv = id_val orelse return; // notification: no response
    const idt = try idText(gpa, idv);
    defer gpa.free(idt);
    const msg = try std.fmt.allocPrint(gpa, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}", .{ idt, result_json });
    defer gpa.free(msg);
    try writeLine(w, msg);
}

fn respondError(gpa: std.mem.Allocator, w: *std.Io.Writer, id_val: std.json.Value, code: i32, message: []const u8) !void {
    const idt = try idText(gpa, id_val);
    defer gpa.free(idt);
    const mesc = try jsonmod.escapeAlloc(gpa, message);
    defer gpa.free(mesc);
    const msg = try std.fmt.allocPrint(gpa, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":{d},\"message\":\"{s}\"}}}}", .{ idt, code, mesc });
    defer gpa.free(msg);
    try writeLine(w, msg);
}
