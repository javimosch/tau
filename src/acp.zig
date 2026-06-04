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
const cfgmod = @import("config.zig");
const jsonmod = @import("json.zig");

const linux = std.os.linux;

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
            serveConn(io, gpa, cfg2, &sr.interface, &sw.interface) catch {};
            stream.close(io);
        }
        return 0;
    }

    // stdio transport (standard ACP — the client spawned us)
    var fr = std.Io.File.stdin().reader(io, rbuf);
    var fw = std.Io.File.stdout().writer(io, wbuf);
    serveConn(io, gpa, cfg2, &fr.interface, &fw.interface) catch {};
    return 0;
}

fn serveConn(io: std.Io, gpa: std.mem.Allocator, cfg: anytype, r: *std.Io.Reader, w: *std.Io.Writer) !void {
    while (true) {
        const line = (r.takeDelimiter('\n') catch return) orelse return;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        handleMessage(io, gpa, cfg, trimmed, w) catch |err| {
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

fn handleMessage(io: std.Io, gpa: std.mem.Allocator, cfg: anytype, line: []const u8, w: *std.Io.Writer) !void {
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
        // Version negotiation: we support v1, so always answer v1 (== client's
        // version when they request 1; our latest otherwise, per spec).
        try respondResult(gpa, w, id_val,
            "{\"protocolVersion\":" ++ std.fmt.comptimePrint("{d}", .{PROTOCOL_VERSION}) ++
            ",\"agentCapabilities\":{\"loadSession\":false,\"promptCapabilities\":{\"image\":false,\"audio\":false,\"embeddedContext\":true}},\"authMethods\":[]," ++
            "\"agentInfo\":{\"name\":\"tau\",\"version\":\"0.2.0\"}}");
    } else if (std.mem.eql(u8, method, "authenticate")) {
        try respondResult(gpa, w, id_val, "{}");
    } else if (std.mem.eql(u8, method, "session/new")) {
        session_counter += 1;
        const result = try std.fmt.allocPrint(gpa, "{{\"sessionId\":\"tau-{d}\"}}", .{session_counter});
        defer gpa.free(result);
        try respondResult(gpa, w, id_val, result);
    } else if (std.mem.eql(u8, method, "session/load")) {
        try respondResult(gpa, w, id_val, "{}");
    } else if (std.mem.eql(u8, method, "session/prompt")) {
        try handlePrompt(io, gpa, cfg, w, id_val, params);
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

/// Run a full prompt turn: tau's agentic tool loop, streamed as ACP
/// session/update notifications (agent_message_chunk + tool_call/tool_call_update),
/// then a PromptResponse with stopReason.
fn handlePrompt(io: std.Io, gpa: std.mem.Allocator, cfg: anytype, w: *std.Io.Writer, id_val: ?std.json.Value, params: ?std.json.Value) !void {
    const sid = paramSessionId(params, gpa);
    defer gpa.free(sid);
    const text = try paramPromptText(params, gpa);
    defer gpa.free(text);

    if (cfg.api_key == null) {
        if (id_val) |idv| try respondError(gpa, w, idv, -32000, "no API key configured");
        return;
    }

    var messages: std.ArrayList(provider.Message) = .empty;
    defer messages.deinit(gpa);
    if (cfg.system_prompt) |sp| try messages.append(gpa, .{ .role = "system", .content = sp });
    try messages.append(gpa, .{ .role = "user", .content = text });

    const enabled = try registry.getEnabledTools(gpa, cfg.tools_allow, cfg.tools_deny);
    defer gpa.free(enabled);
    var tinfos: std.ArrayList(provider.ToolInfo) = .empty;
    defer tinfos.deinit(gpa);
    for (enabled) |t| try tinfos.append(gpa, .{ .name = t.name, .description = t.description });
    const tinfos_slice = try tinfos.toOwnedSlice(gpa);
    defer gpa.free(tinfos_slice);
    const tools_arg: ?[]const provider.ToolInfo = if (cfg.no_tools) null else tinfos_slice;

    const maxit: u32 = if (cfg.max_iterations > 0) cfg.max_iterations else 10;
    var iter: u32 = 0;
    var stop_reason: []const u8 = "max_turn_requests";

    while (iter < maxit) : (iter += 1) {
        const resp = provider.complete(io, gpa, cfg, messages.items, tools_arg) catch |err| {
            if (id_val) |idv| {
                const m = try std.fmt.allocPrint(gpa, "completion failed: {s}", .{@errorName(err)});
                defer gpa.free(m);
                try respondError(gpa, w, idv, -32001, m);
            }
            return;
        };

        if (resp.content.len > 0) try emitMessageChunk(gpa, w, sid, resp.content);
        const content_dupe = try gpa.dupe(u8, resp.content);
        try messages.append(gpa, .{
            .role = "assistant",
            .content = content_dupe,
            .tool_calls = if (resp.tool_calls.len > 0) resp.tool_calls else null,
        });

        if (resp.tool_calls.len == 0) {
            gpa.free(resp.content);
            stop_reason = "end_turn";
            break;
        }
        gpa.free(resp.content);

        for (resp.tool_calls) |tc| {
            const tcid = try gpa.dupe(u8, tc.id);
            try emitToolCall(gpa, w, sid, tc.id, tc.name, toolKind(tc.name), tc.arguments);

            const tool = registry.getTool(tc.name) orelse {
                try emitToolCallUpdate(gpa, w, sid, tc.id, "failed", "tool not found");
                try messages.append(gpa, .{ .role = "tool", .content = try gpa.dupe(u8, "tool not found"), .tool_call_id = tcid });
                continue;
            };
            const args = agentmod.buildToolArgs(gpa, tc.name, tc.arguments) catch {
                try emitToolCallUpdate(gpa, w, sid, tc.id, "failed", "invalid tool arguments");
                try messages.append(gpa, .{ .role = "tool", .content = try gpa.dupe(u8, "invalid tool arguments"), .tool_call_id = tcid });
                continue;
            };
            defer {
                for (args) |a| gpa.free(a);
                gpa.free(args);
            }
            const tr = tool.execute(io, gpa, args, cfg.timeout_ms) catch |err| {
                const em = try std.fmt.allocPrint(gpa, "execution failed: {s}", .{@errorName(err)});
                try emitToolCallUpdate(gpa, w, sid, tc.id, "failed", em);
                try messages.append(gpa, .{ .role = "tool", .content = em, .tool_call_id = tcid });
                continue;
            };
            const out = if (tr.success) tr.stdout else tr.stderr;
            try emitToolCallUpdate(gpa, w, sid, tc.id, if (tr.success) "completed" else "failed", out);
            try messages.append(gpa, .{ .role = "tool", .content = try gpa.dupe(u8, out), .tool_call_id = tcid });
        }
        // resp.tool_calls is referenced by the assistant message above; leave it
        // alive for the rest of the turn (process-lifetime ownership, as in agent.zig).
    }

    const result = try std.fmt.allocPrint(gpa, "{{\"stopReason\":\"{s}\"}}", .{stop_reason});
    defer gpa.free(result);
    try respondResult(gpa, w, id_val, result);
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
