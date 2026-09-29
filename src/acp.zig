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
const context_mod = @import("context.zig");
const version = @import("version.zig").version;

const builtin = @import("builtin");
const term = @import("term.zig");

/// Best-effort chdir to the client-provided workspace `cwd`. Editors already
/// spawn the agent with the workspace as its cwd, so this is a refinement.
/// std 0.16 exposes no portable chdir, so we only do it on Linux; on macOS and
/// Windows we rely on the inherited spawn cwd.
fn chdirBestEffort(path: [:0]const u8) void {
    if (builtin.os.tag == .linux) _ = std.os.linux.chdir(path.ptr);
}

/// True on platforms where the background daemon (start/stop/status, which use a
/// pid file + signals) is supported. The stdio/Unix-socket `serve` path works
/// everywhere regardless.
const daemon_supported = builtin.os.tag != .windows;

/// Wall-clock milliseconds (for unique session ids).
fn nowMillis(io: std.Io) i64 {
    return std.Io.Clock.Timestamp.now(io, .real).raw.toMilliseconds();
}

pub const Sub = cfgmod.AcpSub;

const PROTOCOL_VERSION = 1;

fn writeErr(s: []const u8) void {
    term.err(s);
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

/// Format the JSON object emitted by `tau acp start` and `tau acp status`.
/// The socket path is user-supplied (or derived from HOME) and can contain
/// JSON-special characters, so it is escaped before insertion.
fn formatAcpDaemonJson(arena: std.mem.Allocator, running: bool, pid: i32, socket: []const u8, note: ?[]const u8) ![]u8 {
    const se = try jsonmod.escapeAlloc(arena, socket);
    if (note) |n| {
        const ne = try jsonmod.escapeAlloc(arena, n);
        return std.fmt.allocPrint(arena, "{{\"acp\":{{\"running\":{},\"pid\":{d},\"socket\":\"{s}\",\"note\":\"{s}\"}}}}\n", .{ running, pid, se, ne });
    }
    return std.fmt.allocPrint(arena, "{{\"acp\":{{\"running\":{},\"pid\":{d},\"socket\":\"{s}\"}}}}\n", .{ running, pid, se });
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
    if (sub == .serve) return serve(io, gpa, cfg, env, socket_opt);
    // start/stop/status manage a background daemon via a pid file + signals,
    // which is POSIX-only. The comptime-known guard prunes the daemon impls
    // (and their pid/kill/`/proc` code) from non-POSIX builds entirely; the
    // stdio `serve` path above works on every platform.
    if (daemon_supported) return switch (sub) {
        .start => start(io, arena, env, socket_opt),
        .stop => stop(io, arena, env),
        .status => status(io, arena, env),
        .serve => unreachable,
    };
    writeErr("{\"err\":{\"code\":111,\"message\":\"acp daemon (start/stop/status) is unsupported on this platform; use `tau acp serve` over stdio\"}}\n");
    return 111;
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
        const msg = try formatAcpDaemonJson(arena, true, pid, sock, "already running");
        term.out(msg);
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

    const msg = try formatAcpDaemonJson(arena, true, pid, sock, null);
    term.out(msg);
    return 0;
}

fn stop(io: std.Io, arena: std.mem.Allocator, env: *std.process.Environ.Map) !u8 {
    const pid = readLivePid(io, arena, env) orelse {
        term.out("{\"acp\":{\"running\":false,\"note\":\"not running\"}}\n");
        // clean up any stale files
        if (pidPath(arena, env)) |pp| std.Io.Dir.cwd().deleteFile(io, pp) catch {};
        return 0;
    };
    std.posix.kill(pid, .TERM) catch {};
    if (pidPath(arena, env)) |pp| std.Io.Dir.cwd().deleteFile(io, pp) catch {};
    if (defaultSocket(arena, env)) |s| std.Io.Dir.cwd().deleteFile(io, s) catch {};
    const msg = try std.fmt.allocPrint(arena, "{{\"acp\":{{\"running\":false,\"stopped_pid\":{d}}}}}\n", .{pid});
    term.out(msg);
    return 0;
}

fn status(io: std.Io, arena: std.mem.Allocator, env: *std.process.Environ.Map) !u8 {
    if (readLivePid(io, arena, env)) |pid| {
        const sock = defaultSocket(arena, env) orelse "";
        const msg = try formatAcpDaemonJson(arena, true, pid, sock, null);
        term.out(msg);
    } else {
        term.out("{\"acp\":{\"running\":false}}\n");
    }
    return 0;
}

// ---- server ----------------------------------------------------------------

fn serve(io: std.Io, gpa: std.mem.Allocator, cfg: anytype, env: *std.process.Environ.Map, socket_opt: ?[]const u8) !u8 {
    var cfg2 = cfg;
    cfg2.api_key = cfgmod.resolveApiKey(cfg, env);
    // Resolve the API endpoint like the CLI path (args.zig) does: the config file only
    // carries provider/model/api_key (never the endpoint), and the `acp` subcommand
    // returns from args.parse before the endpoint-resolution step — so without this,
    // `tau acp serve` always POSTs to the default (providers[0]) endpoint regardless of
    // the configured provider. Map provider -> endpoint, then honor a TAU_ENDPOINT override.
    if (cfgmod.findProvider(cfg2.provider)) |p| cfg2.endpoint = p.endpoint;
    if (env.get("TAU_ENDPOINT")) |ep| {
        if (ep.len > 0) cfg2.endpoint = ep;
    }

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
        const init_result = try std.fmt.allocPrint(gpa,
            "{{\"protocolVersion\":{d},\"agentCapabilities\":{{\"loadSession\":true,\"promptCapabilities\":{{\"image\":false,\"audio\":false,\"embeddedContext\":true}}}},\"authMethods\":[]," ++
            "\"agentInfo\":{{\"name\":\"tau\",\"version\":\"{s}\"}}}}",
            .{ PROTOCOL_VERSION, version });
        defer gpa.free(init_result);
        try respondResult(gpa, w, id_val, init_result);
    } else if (std.mem.eql(u8, method, "authenticate")) {
        try respondResult(gpa, w, id_val, "{}");
    } else if (std.mem.eql(u8, method, "session/new")) {
        // Operate in the project directory the client passed (editors set cwd
        // to the workspace; honoring it makes relative-path tools work there).
        if (params) |p| if (p == .object) if (p.object.get("cwd")) |c| if (c == .string) {
            const z = gpa.dupeZ(u8, c.string) catch null;
            if (z) |zz| {
                chdirBestEffort(zz);
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
        // Extract the sessionId and cwd sent by the client, apply cwd (same as
        // session/new), then confirm the load with {sessionId}. The conversation
        // history is seeded from disk in handlePrompt, so no history needs to be
        // returned here — Zed just needs the confirmation to proceed.
        const loaded_sid: []const u8 = blk: {
            if (params) |p| if (p == .object) if (p.object.get("sessionId")) |s| if (s == .string) break :blk s.string;
            break :blk "unknown";
        };
        const sid_dupe = try gpa.dupe(u8, loaded_sid);
        defer gpa.free(sid_dupe);
        if (params) |p| if (p == .object) if (p.object.get("cwd")) |c| if (c == .string) {
            const z = gpa.dupeZ(u8, c.string) catch null;
            if (z) |zz| { chdirBestEffort(zz); gpa.free(zz); }
        };
        // Compact (or trim) the prior session history before the next prompt.
        // The Zed UI shows no prior messages, but the agent should still have
        // summarised context so it can continue coherently. A temporary arena
        // holds all intermediates; everything is freed after the save.
        var load_arena = std.heap.ArenaAllocator.init(gpa);
        defer load_arena.deinit();
        const la = load_arena.allocator();
        if (session_mod.load(io, la, env, sid_dupe) catch null) |st| {
            if (st.messages.len > 0) {
                var msgs: std.ArrayList(provider.Message) = .empty;
                for (st.messages) |m| try msgs.append(la, m);
                // Try LLM compaction. On failure, fall back to a hard tail trim
                // (last 20 messages) so the agent still has recent context.
                context_mod.compact(io, la, cfg, &msgs) catch {
                    const keep = @min(20, msgs.items.len);
                    var tail: std.ArrayList(provider.Message) = .empty;
                    for (msgs.items[msgs.items.len - keep ..]) |m| tail.append(la, m) catch {};
                    msgs = tail;
                };
                session_mod.save(io, gpa, env, .{ .name = sid_dupe, .messages = msgs.items }) catch {};
            }
        }
        const sid_esc = try jsonmod.escapeAlloc(gpa, sid_dupe);
        defer gpa.free(sid_esc);
        const result = try std.fmt.allocPrint(gpa, "{{\"sessionId\":\"{s}\"}}", .{sid_esc});
        defer gpa.free(result);
        try respondResult(gpa, w, id_val, result);
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

/// Emit a session/update text chunk. `kind` is "agent_message_chunk" (assistant
/// output) or "agent_thought_chunk" (model reasoning).
fn emitTextChunk(gpa: std.mem.Allocator, w: *std.Io.Writer, sid: []const u8, kind: []const u8, text: []const u8) !void {
    const se = try jsonmod.escapeAlloc(gpa, sid);
    defer gpa.free(se);
    const te = try jsonmod.escapeAlloc(gpa, text);
    defer gpa.free(te);
    const n = try std.fmt.allocPrint(gpa, "{{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{{\"sessionId\":\"{s}\",\"update\":{{\"sessionUpdate\":\"{s}\",\"content\":{{\"type\":\"text\",\"text\":\"{s}\"}}}}}}}}", .{ se, kind, te });
    defer gpa.free(n);
    try writeLine(w, n);
}

fn emitMessageChunk(gpa: std.mem.Allocator, w: *std.Io.Writer, sid: []const u8, text: []const u8) !void {
    try emitTextChunk(gpa, w, sid, "agent_message_chunk", text);
}

fn emitThoughtChunk(gpa: std.mem.Allocator, w: *std.Io.Writer, sid: []const u8, text: []const u8) !void {
    try emitTextChunk(gpa, w, sid, "agent_thought_chunk", text);
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
    }
    // Always ensure a system message is present. On a fresh session the loaded
    // history will be empty; on a loaded session it should already have one.
    // Use the configured system prompt if set, otherwise a default that nudges
    // the model to use tools when asked about project state.
    const has_system = messages.items.len > 0 and std.mem.eql(u8, messages.items[0].role, "system");
    if (!has_system) {
        const sp = cfg.system_prompt orelse
            "You are tau, an agent-first AI assistant. " ++
            "When asked about prior work, recent changes, or project status — " ++
            "use the available tools (bash, git log, ls, read) to answer from " ++
            "the actual codebase rather than guessing. Never say you have no memory; " ++
            "instead, inspect the project to reconstruct context.";
        var with_sys: std.ArrayList(provider.Message) = .empty;
        try with_sys.append(a, .{ .role = "system", .content = sp });
        try with_sys.appendSlice(a, messages.items);
        messages = with_sys;
    }

    // Hard cap: trim very long sessions before adding the new user turn.
    // Compaction handles gradual growth; this is a backstop for sessions that
    // accumulated many tool-result messages (each file read can be thousands of
    // tokens) before compaction had a chance to fire.
    const MSG_CAP: usize = 80;
    if (messages.items.len > MSG_CAP) {
        const has_sys = messages.items.len > 0 and std.mem.eql(u8, messages.items[0].role, "system");
        // Keep at most MSG_CAP recent messages (plus the system message).
        var keep_from = messages.items.len -| (MSG_CAP - @as(usize, if (has_sys) 1 else 0));
        // Never start on a tool message (would orphan its assistant turn).
        while (keep_from < messages.items.len and std.mem.eql(u8, messages.items[keep_from].role, "tool")) keep_from += 1;
        var trimmed: std.ArrayList(provider.Message) = .empty;
        if (has_sys) try trimmed.append(a, messages.items[0]);
        for (messages.items[keep_from..]) |m| try trimmed.append(a, m);
        messages = trimmed;
    }

    try messages.append(a, .{ .role = "user", .content = text });

    const enabled = try registry.getEnabledTools(a, cfg.tools_allow, cfg.tools_deny);
    var tinfos: std.ArrayList(provider.ToolInfo) = .empty;
    for (enabled) |t| try tinfos.append(a, .{ .name = t.name, .description = t.description });
    const tools_arg: ?[]const provider.ToolInfo = if (cfg.no_tools) null else tinfos.items;

    // The turn ends when the model stops calling tools (natural exit, like
    // Claude Code / OpenCode). `maxit` is only a runaway backstop (args defaults
    // it to 100 for ACP); on exhaustion we force a final summary answer below.
    const maxit: u32 = if (cfg.max_iterations > 0) cfg.max_iterations else 100;
    var iter: u32 = 0;
    var stop_reason: []const u8 = "max_turn_requests";

    while (iter < maxit) : (iter += 1) {
        // Auto-compact before each model call (same logic as agent.zig).
        if (context_mod.shouldCompact(messages.items, cfg))
            context_mod.compact(io, a, cfg, &messages) catch {};

        const resp = provider.complete(io, a, cfg, messages.items, tools_arg) catch |err| {
            session_mod.save(io, a, env, .{ .name = sid, .messages = messages.items }) catch {};
            if (id_val) |idv| {
                const m = try std.fmt.allocPrint(a, "completion failed: {s}", .{@errorName(err)});
                try respondError(a, w, idv, -32001, m);
            }
            return;
        };

        // Surface reasoning only when --thinking is set; it's verbose and clutters
        // the Zed chat panel on every tool turn when left unconditional.
        if (cfg.thinking) if (resp.reasoning_content) |rc| {
            if (rc.len > 0) try emitThoughtChunk(a, w, sid, rc);
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
            // change lands as an approvable diff. On success, short-circuit with
            // continue. On failure (e.g. Zed rejects a relative path), fall through
            // to direct tool execution so the write still succeeds.
            if (client_fs_write and std.mem.eql(u8, tc.name, "write") and args.len >= 2) {
                if (clientWriteFile(a, r, w, sid, args[0], args[1])) |_| {
                    try emitToolCallUpdate(a, w, sid, tc.id, "completed", "file written via editor");
                    try messages.append(a, .{ .role = "tool", .content = "file written via editor", .tool_call_id = tc.id });
                    continue;
                } else |_| {} // fall through to direct execution
            }
            if (client_fs_write and std.mem.eql(u8, tc.name, "edit") and args.len >= 3) {
                const cur = if (client_fs_read)
                    (clientReadFile(a, r, w, sid, args[0]) catch "")
                else
                    (std.Io.Dir.cwd().readFileAlloc(io, args[0], a, .unlimited) catch "");
                const newc = try replaceAlloc(a, cur, args[1], args[2]);
                if (clientWriteFile(a, r, w, sid, args[0], newc)) |_| {
                    try emitToolCallUpdate(a, w, sid, tc.id, "completed", "file edited via editor");
                    try messages.append(a, .{ .role = "tool", .content = "file edited via editor", .tool_call_id = tc.id });
                    continue;
                } else |_| {} // fall through to direct execution
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

    // If we exhausted the loop while still calling tools (no natural answer),
    // force one final tool-free completion so the user always gets an answer.
    if (std.mem.eql(u8, stop_reason, "max_turn_requests")) {
        try messages.append(a, .{ .role = "user", .content = "You have gathered enough. Stop using tools and give your final answer now." });
        if (provider.complete(io, a, cfg, messages.items, null) catch null) |fin| {
            if (cfg.thinking) if (fin.reasoning_content) |rc| {
                if (rc.len > 0) try emitThoughtChunk(a, w, sid, rc);
            };
            if (fin.content.len > 0) try emitMessageChunk(a, w, sid, fin.content);
            try messages.append(a, .{ .role = "assistant", .content = fin.content });
            stop_reason = "end_turn";
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

// ---- unit tests ------------------------------------------------------------

test "configDir: null when HOME is absent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(a);
    try std.testing.expect(configDir(a, &env) == null);
}

test "configDir: builds ~/.config/tau path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(a);
    try env.put("HOME", "/home/alice");
    const got = configDir(a, &env) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("/home/alice/.config/tau", got);
}

test "pidPath: null when HOME is absent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(a);
    try std.testing.expect(pidPath(a, &env) == null);
}

test "pidPath: builds acp.pid path from HOME" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(a);
    try env.put("HOME", "/home/alice");
    const got = pidPath(a, &env) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("/home/alice/.config/tau/acp.pid", got);
}

test "defaultSocket: builds acp.sock path from HOME" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(a);
    try env.put("HOME", "/home/alice");
    const got = defaultSocket(a, &env) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("/home/alice/.config/tau/acp.sock", got);
}

test "toolKind: maps all known tool names" {
    try std.testing.expectEqualStrings("execute", toolKind("bash"));
    try std.testing.expectEqualStrings("read", toolKind("read"));
    try std.testing.expectEqualStrings("read", toolKind("ls"));
    try std.testing.expectEqualStrings("edit", toolKind("write"));
    try std.testing.expectEqualStrings("edit", toolKind("edit"));
    try std.testing.expectEqualStrings("search", toolKind("grep"));
    try std.testing.expectEqualStrings("search", toolKind("find"));
}

test "toolKind: returns other for unknown tool" {
    try std.testing.expectEqualStrings("other", toolKind("unknown_tool"));
    try std.testing.expectEqualStrings("other", toolKind(""));
    try std.testing.expectEqualStrings("other", toolKind("cat"));
}

test "replaceAlloc: replaces all occurrences" {
    const gpa = std.testing.allocator;
    const got = try replaceAlloc(gpa, "hello world hello", "hello", "hi");
    defer gpa.free(got);
    try std.testing.expectEqualStrings("hi world hi", got);
}

test "replaceAlloc: empty needle returns copy of input" {
    const gpa = std.testing.allocator;
    const got = try replaceAlloc(gpa, "hello", "", "X");
    defer gpa.free(got);
    try std.testing.expectEqualStrings("hello", got);
}

test "replaceAlloc: needle not present returns copy" {
    const gpa = std.testing.allocator;
    const got = try replaceAlloc(gpa, "hello world", "xyz", "Q");
    defer gpa.free(got);
    try std.testing.expectEqualStrings("hello world", got);
}

test "replaceAlloc: needle at start and end" {
    const gpa = std.testing.allocator;
    const got = try replaceAlloc(gpa, "ab middle ab", "ab", "Z");
    defer gpa.free(got);
    try std.testing.expectEqualStrings("Z middle Z", got);
}

test "replaceAlloc: empty string input" {
    const gpa = std.testing.allocator;
    const got = try replaceAlloc(gpa, "", "needle", "repl");
    defer gpa.free(got);
    try std.testing.expectEqualStrings("", got);
}

test "paramSessionId: extracts sessionId from params" {
    const gpa = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, "{\"sessionId\":\"session-abc\"}", .{});
    defer parsed.deinit();
    const sid = paramSessionId(parsed.value, gpa);
    defer gpa.free(sid);
    try std.testing.expectEqualStrings("session-abc", sid);
}

test "paramSessionId: returns unknown when params is null" {
    const gpa = std.testing.allocator;
    const sid = paramSessionId(null, gpa);
    defer gpa.free(sid);
    try std.testing.expectEqualStrings("unknown", sid);
}

test "paramSessionId: returns unknown when sessionId key is absent" {
    const gpa = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, "{\"other\":\"value\"}", .{});
    defer parsed.deinit();
    const sid = paramSessionId(parsed.value, gpa);
    defer gpa.free(sid);
    try std.testing.expectEqualStrings("unknown", sid);
}

test "paramPromptText: string prompt extracted verbatim" {
    const gpa = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, "{\"prompt\":\"hello world\"}", .{});
    defer parsed.deinit();
    const text = try paramPromptText(parsed.value, gpa);
    defer gpa.free(text);
    try std.testing.expectEqualStrings("hello world", text);
}

test "paramPromptText: array of text blocks joined with newlines" {
    const gpa = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, "{\"prompt\":[{\"text\":\"line one\"},{\"text\":\"line two\"}]}", .{});
    defer parsed.deinit();
    const text = try paramPromptText(parsed.value, gpa);
    defer gpa.free(text);
    try std.testing.expectEqualStrings("line one\nline two", text);
}

test "paramPromptText: null params returns empty string" {
    const gpa = std.testing.allocator;
    const text = try paramPromptText(null, gpa);
    defer gpa.free(text);
    try std.testing.expectEqualStrings("", text);
}

test "paramPromptText: missing prompt key returns empty string" {
    const gpa = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, "{\"sessionId\":\"s1\"}", .{});
    defer parsed.deinit();
    const text = try paramPromptText(parsed.value, gpa);
    defer gpa.free(text);
    try std.testing.expectEqualStrings("", text);
}

test "paramPromptText: array blocks missing text key are skipped" {
    const gpa = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, "{\"prompt\":[{\"type\":\"image\"},{\"text\":\"actual text\"}]}", .{});
    defer parsed.deinit();
    const text = try paramPromptText(parsed.value, gpa);
    defer gpa.free(text);
    try std.testing.expectEqualStrings("actual text", text);
}

test "idText: serializes integer id" {
    const gpa = std.testing.allocator;
    const t = try idText(gpa, std.json.Value{ .integer = 42 });
    defer gpa.free(t);
    try std.testing.expectEqualStrings("42", t);
}

test "idText: serializes string id with surrounding quotes" {
    const gpa = std.testing.allocator;
    const t = try idText(gpa, std.json.Value{ .string = "req-1" });
    defer gpa.free(t);
    try std.testing.expectEqualStrings("\"req-1\"", t);
}

test "formatAcpDaemonJson escapes socket path with quotes and backslashes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const got = try formatAcpDaemonJson(a, true, 42, "/tmp/acp\"quote\\sock", null);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, got, .{});
    defer parsed.deinit();
    const acp = parsed.value.object.get("acp").?;
    try std.testing.expectEqual(true, acp.object.get("running").?.bool);
    try std.testing.expectEqual(@as(i64, 42), acp.object.get("pid").?.integer);
    try std.testing.expectEqualStrings("/tmp/acp\"quote\\sock", acp.object.get("socket").?.string);
}

test "formatAcpDaemonJson includes optional note" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const got = try formatAcpDaemonJson(a, true, 7, "/tmp/sock", "already running");
    var parsed = try std.json.parseFromSlice(std.json.Value, a, got, .{});
    defer parsed.deinit();
    const acp = parsed.value.object.get("acp").?;
    try std.testing.expectEqualStrings("already running", acp.object.get("note").?.string);
}

// ---- NDJSON / JSON-RPC line parser tests -------------------------------------
//
// serveConn feeds one stdin line at a time into handleMessage — tau's NDJSON
// event parser. The tests below pin the parser's contract and throw random and
// fuzz-generated lines at it. Everything stays offline: the cfg used has no
// api_key, so session/prompt stops at the -32000 guard before any LLM call,
// and the env maps carry no HOME unless a test deliberately provides one
// (session save/load then no-ops or lands in a tmp dir).

/// Snapshot of the process cwd as a NUL-terminated slice into `buf` (Linux
/// only — chdirBestEffort is a no-op on other platforms, so there is nothing
/// to restore there). `buf` must outlive the returned slice.
fn saveCwd(buf: []u8) ?[:0]const u8 {
    if (comptime builtin.os.tag != .linux) return null;
    const rc = std.os.linux.getcwd(buf.ptr, buf.len);
    if (std.os.linux.errno(rc) != .SUCCESS) return null;
    const n: usize = @intCast(rc); // includes the trailing NUL
    return buf[0 .. n - 1 :0];
}

fn restoreCwd(saved: ?[:0]const u8) void {
    if (comptime builtin.os.tag != .linux) return;
    if (saved) |s| _ = std.os.linux.chdir(s.ptr);
}

/// Feed one (already trimmed) line through handleMessage and capture whatever
/// it writes. The reader is an empty fixed buffer — only reachable by the
/// editor-fs client calls inside session/prompt's tool loop, which require an
/// api_key the test cfg never has. cwd is saved/restored so a fuzzed
/// params.cwd string can never move the test process, and the client-capability
/// globals are reset to keep iterations independent.
fn handleMessageCapture(env: *std.process.Environ.Map, cfg: cfgmod.Config, line: []const u8) ![]u8 {
    const gpa = std.testing.allocator;
    var r: std.Io.Reader = .fixed("");
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var cwd_buf: [4096]u8 = undefined;
    const saved = saveCwd(&cwd_buf);
    defer restoreCwd(saved);
    client_fs_read = false;
    client_fs_write = false;
    try handleMessage(std.testing.io, gpa, cfg, env, &r, line, &aw.writer);
    client_fs_read = false;
    client_fs_write = false;
    return try gpa.dupe(u8, aw.writer.buffer[0..aw.writer.end]);
}

/// Assert `out` consists solely of whole newline-terminated JSON-RPC response
/// objects ({\"jsonrpc\":\"2.0\",\"id\":...,\"result\"|\"error\":...}) and
/// return the number of lines.
fn expectJsonRpcLines(gpa: std.mem.Allocator, out: []const u8) !usize {
    if (out.len == 0) return 0;
    try std.testing.expectEqual(@as(u8, '\n'), out[out.len - 1]);
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, out[0 .. out.len - 1], '\n');
    while (it.next()) |line| {
        count += 1;
        var parsed = std.json.parseFromSlice(std.json.Value, gpa, line, .{}) catch {
            std.debug.print("acp wrote non-JSON line: {s}\n", .{line});
            return error.TestExpectedJsonRpc;
        };
        defer parsed.deinit();
        if (parsed.value != .object) return error.TestExpectedJsonRpc;
        const obj = parsed.value.object;
        const jr = obj.get("jsonrpc") orelse return error.TestExpectedJsonRpc;
        if (jr != .string or !std.mem.eql(u8, jr.string, "2.0")) return error.TestExpectedJsonRpc;
        if (obj.get("id") == null) return error.TestExpectedJsonRpc;
        const has_result = obj.get("result") != null;
        const has_error = obj.get("error") != null;
        if (has_result == has_error) return error.TestExpectedJsonRpc;
    }
    return count;
}

/// The response contract, restated independently: a line only gets a response
/// when it is a JSON object carrying a string "method" (other than the
/// notification-only "session/cancel") AND an "id" member.
fn oracleResponseCount(gpa: std.mem.Allocator, line: []const u8) !usize {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, line, .{}) catch return 0;
    defer parsed.deinit();
    if (parsed.value != .object) return 0;
    const obj = parsed.value.object;
    const m = obj.get("method") orelse return 0;
    if (m != .string) return 0;
    if (std.mem.eql(u8, m.string, "session/cancel")) return 0;
    if (obj.get("id") == null) return 0;
    return 1;
}

/// Assert the response line's "id" echoes the request line's "id" verbatim
/// (compared via canonical serialization, so any JSON value type works).
fn expectIdEcho(gpa: std.mem.Allocator, line: []const u8, resp_line: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const req = try std.json.parseFromSliceLeaky(std.json.Value, a, line, .{});
    const resp = try std.json.parseFromSliceLeaky(std.json.Value, a, resp_line, .{});
    const req_id = try std.json.Stringify.valueAlloc(a, req.object.get("id").?, .{});
    const resp_id = try std.json.Stringify.valueAlloc(a, resp.object.get("id").?, .{});
    try std.testing.expectEqualStrings(req_id, resp_id);
}

fn expectSilent(env: *std.process.Environ.Map, line: []const u8) !void {
    const out = try handleMessageCapture(env, .{}, line);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqual(@as(usize, 0), try expectJsonRpcLines(std.testing.allocator, out));
}

test "handleMessage: non-JSON and non-object lines are ignored" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    for ([_][]const u8{
        "not json at all",
        "{\"unterminated",
        "[1,2,3]",
        "\"just a string\"",
        "42",
        "null",
        "true",
        "{}",
        "{\"id\":1}",
        "{\"method\":42}",
        "{\"method\":null}",
        "{\"method\":{\"nested\":true}}",
        "\x00\x01\x02binary\xff\xfe",
    }) |line| {
        try expectSilent(&env, line);
    }
}

test "handleMessage: requests without an id are notifications and get no reply" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    for ([_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"method\":\"initialize\",\"params\":{}}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"authenticate\"}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"session/new\",\"params\":{\"cwd\":\"/tmp\"}}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"session/load\",\"params\":{\"sessionId\":\"s1\"}}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"session/prompt\",\"params\":{\"sessionId\":\"s\",\"prompt\":\"hi\"}}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"session/cancel\",\"params\":{\"sessionId\":\"s\"}}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"bogus/method\"}",
    }) |line| {
        try expectSilent(&env, line);
    }
}

test "handleMessage: session/cancel stays silent even when an id is present" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try expectSilent(&env, "{\"id\":5,\"method\":\"session/cancel\",\"params\":{\"sessionId\":\"s\"}}");
}

test "handleMessage: unknown method with id gets error -32601" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    const line = "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"bogus/method\"}";
    const out = try handleMessageCapture(&env, .{}, line);
    defer std.testing.allocator.free(out);
    const a = std.testing.allocator;
    try std.testing.expectEqual(@as(usize, 1), try expectJsonRpcLines(a, out));
    var parsed = try std.json.parseFromSlice(std.json.Value, a, std.mem.trim(u8, out, "\n"), .{});
    defer parsed.deinit();
    const err_obj = parsed.value.object.get("error").?.object;
    try std.testing.expectEqual(@as(i64, -32601), err_obj.get("code").?.integer);
    try expectIdEcho(a, line, std.mem.trim(u8, out, "\n"));
}

test "handleMessage: initialize negotiates protocolVersion and advertises agentInfo" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    const line = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":1,\"clientCapabilities\":{\"fs\":{\"readTextFile\":true,\"writeTextFile\":true}}}}";
    const out = try handleMessageCapture(&env, .{}, line);
    defer std.testing.allocator.free(out);
    const a = std.testing.allocator;
    try std.testing.expectEqual(@as(usize, 1), try expectJsonRpcLines(a, out));
    var parsed = try std.json.parseFromSlice(std.json.Value, a, std.mem.trim(u8, out, "\n"), .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("result").?.object;
    try std.testing.expectEqual(@as(i64, PROTOCOL_VERSION), result.get("protocolVersion").?.integer);
    try std.testing.expectEqualStrings("tau", result.get("agentInfo").?.object.get("name").?.string);
    // The advertised fs capabilities were consumed during the call; the harness
    // resets them afterwards so tests stay independent.
    try std.testing.expect(client_fs_read == false and client_fs_write == false);
}

test "handleMessage: authenticate resolves to an empty result object" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    const line = "{\"jsonrpc\":\"2.0\",\"id\":\"auth-1\",\"method\":\"authenticate\"}";
    const out = try handleMessageCapture(&env, .{}, line);
    defer std.testing.allocator.free(out);
    const a = std.testing.allocator;
    try std.testing.expectEqual(@as(usize, 1), try expectJsonRpcLines(a, out));
    var parsed = try std.json.parseFromSlice(std.json.Value, a, std.mem.trim(u8, out, "\n"), .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("result").?;
    try std.testing.expectEqual(@as(usize, 0), result.object.count());
}

test "handleMessage: session/new returns a sessionId even with no HOME" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    const line = "{\"id\":3,\"method\":\"session/new\",\"params\":{\"cwd\":123}}";
    const out = try handleMessageCapture(&env, .{}, line);
    defer std.testing.allocator.free(out);
    const a = std.testing.allocator;
    try std.testing.expectEqual(@as(usize, 1), try expectJsonRpcLines(a, out));
    var parsed = try std.json.parseFromSlice(std.json.Value, a, std.mem.trim(u8, out, "\n"), .{});
    defer parsed.deinit();
    const sid = parsed.value.object.get("result").?.object.get("sessionId").?.string;
    try std.testing.expect(std.mem.startsWith(u8, sid, "acp-"));
}

test "handleMessage: session/new persists a session file under HOME" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    var env = std.process.Environ.Map.init(a);
    try env.put("HOME", home);

    const line = "{\"id\":4,\"method\":\"session/new\",\"params\":{}}";
    const out = try handleMessageCapture(&env, .{}, line);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqual(@as(usize, 1), try expectJsonRpcLines(a, out));
    var parsed = try std.json.parseFromSlice(std.json.Value, a, std.mem.trim(u8, out, "\n"), .{});
    defer parsed.deinit();
    const sid = parsed.value.object.get("result").?.object.get("sessionId").?.string;

    // The ACP session must exist on disk so next turns can pick it up.
    const p = try std.fmt.allocPrint(a, "{s}/.config/tau/sessions/{s}.json", .{ home, sid });
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, p, a, .unlimited);
    const st = try std.json.parseFromSliceLeaky(session_mod.SessionState, a, bytes, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqualStrings(sid, st.name);
    try std.testing.expectEqual(@as(usize, 0), st.messages.len);
}

test "handleMessage: session/load echoes the requested sessionId" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    const line = "{\"id\":6,\"method\":\"session/load\",\"params\":{\"sessionId\":\"abc-123\",\"cwd\":false}}";
    const out = try handleMessageCapture(&env, .{}, line);
    defer std.testing.allocator.free(out);
    const a = std.testing.allocator;
    try std.testing.expectEqual(@as(usize, 1), try expectJsonRpcLines(a, out));
    var parsed = try std.json.parseFromSlice(std.json.Value, a, std.mem.trim(u8, out, "\n"), .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("abc-123", parsed.value.object.get("result").?.object.get("sessionId").?.string);
}

test "handleMessage: session/prompt without an API key fails with -32000" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    const line = "{\"id\":7,\"method\":\"session/prompt\",\"params\":{\"sessionId\":\"s\",\"prompt\":[{\"text\":\"hi\"}]}}";
    const out = try handleMessageCapture(&env, .{}, line);
    defer std.testing.allocator.free(out);
    const a = std.testing.allocator;
    try std.testing.expectEqual(@as(usize, 1), try expectJsonRpcLines(a, out));
    var parsed = try std.json.parseFromSlice(std.json.Value, a, std.mem.trim(u8, out, "\n"), .{});
    defer parsed.deinit();
    const err_obj = parsed.value.object.get("error").?.object;
    try std.testing.expectEqual(@as(i64, -32000), err_obj.get("code").?.integer);
    try std.testing.expect(std.mem.indexOf(u8, err_obj.get("message").?.string, "no API key") != null);
}

test "handleMessage: an explicit null id still counts as a request" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    const line = "{\"id\":null,\"method\":\"bogus\"}";
    const out = try handleMessageCapture(&env, .{}, line);
    defer std.testing.allocator.free(out);
    const a = std.testing.allocator;
    try std.testing.expectEqual(@as(usize, 1), try expectJsonRpcLines(a, out));
    var parsed = try std.json.parseFromSlice(std.json.Value, a, std.mem.trim(u8, out, "\n"), .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("id").? == .null);
    try expectIdEcho(a, line, std.mem.trim(u8, out, "\n"));
}

test "handleMessage: object and array ids echo back verbatim" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    const a = std.testing.allocator;
    for ([_][]const u8{
        "{\"id\":{\"k\":[1,2]},\"method\":\"bogus\"}",
        "{\"id\":[1,{\"x\":true}],\"method\":\"bogus\"}",
        "{\"id\":true,\"method\":\"bogus\"}",
    }) |line| {
        const out = try handleMessageCapture(&env, .{}, line);
        defer a.free(out);
        try std.testing.expectEqual(@as(usize, 1), try expectJsonRpcLines(a, out));
        try expectIdEcho(a, line, std.mem.trim(u8, out, "\n"));
    }
}

test "handleMessage: session/new with a nonexistent cwd does not move the process" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var before_buf: [4096]u8 = undefined;
    const before = saveCwd(&before_buf);
    const line = "{\"id\":8,\"method\":\"session/new\",\"params\":{\"cwd\":\"/definitely/no/such/tau-dir-9f3a\"}}";
    const out = try handleMessageCapture(&env, .{}, line);
    defer std.testing.allocator.free(out);
    var after_buf: [4096]u8 = undefined;
    const after = saveCwd(&after_buf);
    try std.testing.expectEqual(@as(usize, 1), try expectJsonRpcLines(std.testing.allocator, out));
    if (before != null and after != null) try std.testing.expectEqualStrings(before.?, after.?);
}

test "handleMessage: session/new honors a real params.cwd" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    var r: std.Io.Reader = .fixed("");
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    var cwd_buf: [4096]u8 = undefined;
    const saved = saveCwd(&cwd_buf).?;
    const abs_tmp = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ saved, tmp.sub_path[0..] });
    const line = try std.fmt.allocPrint(a, "{{\"id\":11,\"method\":\"session/new\",\"params\":{{\"cwd\":\"{s}\"}}}}", .{abs_tmp});

    var after_buf: [4096]u8 = undefined;
    handleMessage(std.testing.io, gpa, cfgmod.Config{}, &env, &r, line, &aw.writer) catch {};
    const moved = saveCwd(&after_buf).?;
    restoreCwd(saved);
    try std.testing.expectEqualStrings(abs_tmp, moved);
}

test "serveConn: line-framed NDJSON stream isolates each message" {
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    const input =
        "\n" ++ // blank line skipped
        "   \t \r\n" ++ // whitespace-only line skipped
        "this is not json\n" ++
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}\n" ++
        "{\"method\":\"unknown\"}\n" ++ // notification: no reply
        "  {\"id\":2,\"method\":\"authenticate\"}   \r\n" ++ // leading/trailing ws trimmed
        "{\"id\":3,\"method\":\"unknown\"}\n" ++
        "{\"id\":4,\"method\":\"session/cancel\"}\n" ++ // notification-only method
        "{\"id\":5,\"method\":\"session/prompt\",\"params\":{\"sessionId\":\"s\",\"prompt\":\"hi\"}}\n" ++
        "{\"id\":6,\"method\":\"authenticate\"}"; // final line without trailing newline
    var r: std.Io.Reader = .fixed(input);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try serveConn(std.testing.io, gpa, cfgmod.Config{}, &env, &r, &aw.writer);
    const out = aw.writer.buffer[0..aw.writer.end];

    // Exactly five replies, in order: ids 1, 2, 3, 5, 6.
    var it = std.mem.splitScalar(u8, std.mem.trim(u8, out, "\n"), '\n');
    var ids: std.ArrayList(std.json.Value) = .empty;
    defer ids.deinit(gpa);
    while (it.next()) |line| {
        var parsed = try std.json.parseFromSlice(std.json.Value, gpa, line, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value == .object);
        try ids.append(gpa, parsed.value.object.get("id").?);
    }
    try std.testing.expectEqual(@as(usize, 5), ids.items.len);
    const expected_ids = [_]i64{ 1, 2, 3, 5, 6 };
    for (expected_ids, ids.items) |e, idv| {
        try std.testing.expectEqual(@as(i64, e), idv.integer);
    }
}

/// Random JSON string fragment for generated messages — hostile alphabet of
/// quotes, backslashes, control bytes, and multi-byte UTF-8.
fn appendJsonString(gpa: std.mem.Allocator, rng: std.Random, out: *std.ArrayList(u8)) !void {
    const alphabet = "abcXYZ09-_. \\\"\n\t\r{}}[,]:/é€~";
    var sb: [24]u8 = undefined;
    const len = rng.uintLessThan(usize, sb.len + 1);
    for (sb[0..len]) |*b| b.* = alphabet[rng.uintLessThan(usize, alphabet.len)];
    const esc = try jsonmod.escapeAlloc(gpa, sb[0..len]);
    defer gpa.free(esc);
    try out.append(gpa, '"');
    try out.appendSlice(gpa, esc);
    try out.append(gpa, '"');
}

/// Random JSON value (no floats — keeps serialization round-trips exact).
fn genJsonValue(gpa: std.mem.Allocator, rng: std.Random, out: *std.ArrayList(u8), depth: u32) anyerror!void {
    const choice = rng.uintLessThan(u32, if (depth >= 3) 5 else 8);
    switch (choice) {
        0 => try out.appendSlice(gpa, "null"),
        1 => try out.appendSlice(gpa, if (rng.boolean()) "true" else "false"),
        2 => {
            var nb: [24]u8 = undefined;
            const s = std.fmt.bufPrint(&nb, "{d}", .{rng.int(i32)}) catch unreachable;
            try out.appendSlice(gpa, s);
        },
        3 => {
            var nb: [24]u8 = undefined;
            const s = std.fmt.bufPrint(&nb, "{d}", .{rng.int(u64)}) catch unreachable;
            try out.appendSlice(gpa, s);
        },
        4 => try appendJsonString(gpa, rng, out),
        5 => {
            try out.append(gpa, '[');
            const n = rng.uintLessThan(usize, 4);
            for (0..n) |i| {
                if (i > 0) try out.append(gpa, ',');
                try genJsonValue(gpa, rng, out, depth + 1);
            }
            try out.append(gpa, ']');
        },
        6, 7 => {
            try out.append(gpa, '{');
            const keys = [_][]const u8{ "method", "id", "params", "sessionId", "prompt", "cwd", "clientCapabilities", "fs", "text", "jsonrpc", "x", "k" };
            const n = rng.uintLessThan(usize, 4);
            for (0..n) |i| {
                if (i > 0) try out.append(gpa, ',');
                try out.append(gpa, '"');
                try out.appendSlice(gpa, keys[rng.uintLessThan(usize, keys.len)]);
                try out.appendSlice(gpa, "\":");
                try genJsonValue(gpa, rng, out, depth + 1);
            }
            try out.append(gpa, '}');
        },
        else => unreachable,
    }
}

/// params specifically: mixes the members the dispatch actually reads
/// (sessionId, prompt, cwd, clientCapabilities) with arbitrary junk. "cwd" is
/// only ever a guaranteed-nonexistent path or a non-string so chdirBestEffort
/// can never relocate the test process.
fn genParams(gpa: std.mem.Allocator, rng: std.Random, out: *std.ArrayList(u8)) !void {
    try out.append(gpa, '{');
    var n = rng.uintLessThan(usize, 5);
    var first = true;
    while (n > 0) : (n -= 1) {
        if (!first) try out.append(gpa, ',');
        first = false;
        switch (rng.uintLessThan(u32, 6)) {
            0 => {
                try out.appendSlice(gpa, "\"sessionId\":");
                try appendJsonString(gpa, rng, out);
            },
            1 => {
                try out.appendSlice(gpa, "\"prompt\":");
                if (rng.boolean()) {
                    try appendJsonString(gpa, rng, out);
                } else {
                    try out.appendSlice(gpa, "[{\"text\":");
                    try appendJsonString(gpa, rng, out);
                    try out.appendSlice(gpa, "},{\"text\":");
                    try appendJsonString(gpa, rng, out);
                    try out.appendSlice(gpa, "}]");
                }
            },
            2 => {
                try out.appendSlice(gpa, "\"cwd\":");
                if (rng.boolean()) {
                    var nb: [48]u8 = undefined;
                    const s = std.fmt.bufPrint(&nb, "\"/nonexistent-t169-{d}\"", .{rng.int(u32)}) catch unreachable;
                    try out.appendSlice(gpa, s);
                } else {
                    try out.appendSlice(gpa, "42");
                }
            },
            3 => try out.appendSlice(gpa, "\"clientCapabilities\":{\"fs\":{\"readTextFile\":true,\"writeTextFile\":true}}"),
            else => {
                try out.appendSlice(gpa, "\"junk\":");
                try genJsonValue(gpa, rng, out, 1);
            },
        }
    }
    try out.append(gpa, '}');
}

/// Build a random line for the property test: well-formed JSON-RPC-ish
/// requests, notifications, malformed objects, arbitrary JSON values, raw
/// garbage, and truncated/corrupted variants.
fn genRpcLine(gpa: std.mem.Allocator, rng: std.Random) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const methods = [_][]const u8{ "initialize", "authenticate", "session/new", "session/load", "session/prompt", "session/cancel", "bogus", "bogus/method", "", "initialize", "session/prompt", "session/cancel" };
    switch (rng.uintLessThan(u32, 12)) {
        0...6 => {
            try out.appendSlice(gpa, "{\"jsonrpc\":\"2.0\",");
            if (rng.boolean()) {
                try out.appendSlice(gpa, "\"id\":");
                try genJsonValue(gpa, rng, &out, 0);
                try out.append(gpa, ',');
            }
            try out.appendSlice(gpa, "\"method\":\"");
            const esc = try jsonmod.escapeAlloc(gpa, methods[rng.uintLessThan(usize, methods.len)]);
            defer gpa.free(esc);
            try out.appendSlice(gpa, esc);
            try out.append(gpa, '"');
            if (rng.boolean()) {
                try out.appendSlice(gpa, ",\"params\":");
                try genParams(gpa, rng, &out);
            }
            try out.append(gpa, '}');
        },
        7 => { // object without a method member
            try out.appendSlice(gpa, "{\"jsonrpc\":\"2.0\",\"id\":");
            try genJsonValue(gpa, rng, &out, 0);
            try out.append(gpa, '}');
        },
        8 => { // method present but not a string
            try out.appendSlice(gpa, "{\"id\":1,\"method\":");
            switch (rng.uintLessThan(u32, 3)) {
                0 => try out.appendSlice(gpa, "42"),
                1 => try out.appendSlice(gpa, "[\"initialize\"]"),
                else => try out.appendSlice(gpa, "null"),
            }
            try out.append(gpa, '}');
        },
        9, 10 => try genJsonValue(gpa, rng, &out, 0), // arbitrary JSON value
        else => { // raw garbage bytes
            const n = rng.uintLessThan(usize, 64);
            for (0..n) |_| try out.append(gpa, rng.int(u8));
        },
    }
    if (out.items.len > 0) {
        switch (rng.uintLessThan(u32, 6)) {
            0 => out.shrinkRetainingCapacity(rng.uintLessThan(usize, out.items.len + 1)), // truncated
            1 => out.items[rng.uintLessThan(usize, out.items.len)] ^= 0xFF, // corrupted byte
            else => {},
        }
    }
    return try out.toOwnedSlice(gpa);
}

test "property: handleMessage honours the response contract on random lines" {
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    var prng = std.Random.DefaultPrng.init(0xac9);
    const rng = prng.random();
    for (0..1500) |_| {
        const line = try genRpcLine(gpa, rng);
        defer gpa.free(line);
        const want = try oracleResponseCount(gpa, line);
        const out = try handleMessageCapture(&env, .{}, line);
        defer gpa.free(out);
        const got = try expectJsonRpcLines(gpa, out);
        try std.testing.expectEqual(want, got);
        if (want == 1) try expectIdEcho(gpa, line, std.mem.trim(u8, out, "\n"));
    }
}

fn fuzzAcpLine(_: void, smith: *std.testing.Smith) anyerror!void {
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    var buf: [8192]u8 = undefined;
    const input: []const u8 = if (smith.in) |in| blk: {
        const n = @min(in.len, buf.len);
        @memcpy(buf[0..n], in[0..n]);
        break :blk buf[0..n];
    } else buf[0..smith.slice(&buf)];
    // Same framing as serveConn: split on '\n', trim, skip empties.
    var it = std.mem.splitScalar(u8, input, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const want = try oracleResponseCount(gpa, line);
        const out = try handleMessageCapture(&env, .{}, line);
        defer gpa.free(out);
        const got = try expectJsonRpcLines(gpa, out);
        try std.testing.expectEqual(want, got);
    }
}

test "fuzz: handleMessage tolerates arbitrary input lines" {
    try std.testing.fuzz({}, fuzzAcpLine, .{ .corpus = &.{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":1,\"clientCapabilities\":{\"fs\":{\"readTextFile\":true,\"writeTextFile\":false}}}}",
        "{\"id\":9,\"method\":\"session/prompt\",\"params\":{\"sessionId\":\"s\",\"prompt\":[{\"text\":\"hi\"}]}}",
        "{\"id\":\"x\",\"method\":\"session/new\",\"params\":{\"cwd\":42}}",
        "{\"id\":0,\"method\":\"session/cancel\",\"params\":{}}",
        "{\"id\":6,\"method\":\"session/load\",\"params\":{\"sessionId\":\"s1\",\"cwd\":\"/nonexistent\"}}",
        "{\"method\":[]}",
        "not json{",
        "[1,2,3]",
        "{\"id\":1,\"method\":\"initialize\"}\n{\"id\":2,\"method\":\"bogus\"}\ngarbage\n{\"method\":\"authenticate\"}",
        "",
        "{\"id\":{\"a\":[1,2]},\"method\":\"bogus\",\"params\":{\"x\":{\"y\":{\"z\":[null,true,42]}}}}",
        "\"line with unicode é€🎉 inside\"",
    }});
}
