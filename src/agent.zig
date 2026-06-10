const std = @import("std");
const provider_mod = @import("llm/provider.zig");
const registry_mod = @import("tools/registry.zig");
const cfgmod = @import("config.zig");
const jsonmod = @import("json.zig");
const goalmod = @import("goal.zig");
const loopmod = @import("loop.zig");
const context_mod = @import("context.zig");
const session_mod = @import("session.zig");

const term = @import("term.zig");

/// The exit sentinel for the current run. Priority:
///   1. cfg.exit_sentinel (Author↔Critic loop overrides)
///   2. GOAL_MET (goal mode default)
///   3. null (no sentinel check; tool-stop is terminal)
fn effectiveSentinel(cfg: anytype) ?[]const u8 {
    if (cfg.exit_sentinel) |s| return s;
    if (cfg.goal_action == .set) return goalmod.SENTINEL;
    return null;
}

pub fn run(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    cfg: anytype,
    env_map: *std.process.Environ.Map,
) !struct { exit_code: u8, tokens_out: u64 } {
    const api_key = cfgmod.resolveApiKey(cfg, env_map) orelse return .{ .exit_code = 106, .tokens_out = 0 };
    var cfg_with_key = cfg;
    cfg_with_key.api_key = api_key;

    var messages = std.ArrayList(provider_mod.Message).empty;
    defer messages.deinit(gpa);

    // --- Load session (prior history + goal), if a named session was given ---
    var stored_goal: ?session_mod.GoalState = null;
    if (cfg.session) |name| {
        if (try session_mod.load(io, arena, env_map, name)) |st| {
            for (st.messages) |m| try messages.append(gpa, m);
            stored_goal = st.goal;
        }
    }

    // --- Goal subcommands that don't run the model ---
    switch (cfg.goal_action) {
        .status, .pause, .resume_, .clear, .complete => {
            const code = try goalSubcommand(io, gpa, env_map, cfg, &messages, &stored_goal);
            return .{ .exit_code = code, .tokens_out = 0 };
        },
        else => {},
    }

    // --- Author↔Critic / role directive ---
    // When a non-default role is set, build the role-specific directive and
    // inject it as the system message (replacing any prior system turn). This
    // takes precedence over the goal directive when cfg.goal_action is not .set.
    if (cfg.role != .none) {
        if (messages.items.len > 0 and std.mem.eql(u8, messages.items[0].role, "system"))
            _ = messages.orderedRemove(0);
        const spec = loopmod.AuthorCriticSpec{
            .goal = cfg.goal orelse "",
            .deliverables = cfg.goal orelse "",
        };
        const role_dir = switch (cfg.role) {
            .author => try loopmod.authorDirective(gpa, spec),
            .critic => try loopmod.criticDirective(gpa, spec),
            .coordinator => try loopmod.authorDirective(gpa, spec), // coordinator uses author-style directive for now
            .none => unreachable,
        };
        const sys_content = if (cfg.system_prompt) |sp|
            try std.fmt.allocPrint(gpa, "{s}\n\n{s}", .{ sp, role_dir })
        else
            role_dir;
        try messages.insert(gpa, 0, .{ .role = "system", .content = sys_content });
    }

    // --- Determine the active goal (set this turn, or an active stored one) ---
    var goal_active = false;
    var objective: []const u8 = "";
    if (cfg.goal_action == .set) {
        goal_active = true;
        objective = cfg.goal orelse "";
        // Read prior continues into a temp BEFORE assigning — the struct literal
        // is built in-place into stored_goal (result location), so reading
        // stored_goal inside its own initializer would see undefined memory.
        const prev_continues: u32 = if (stored_goal) |g| g.continues else 0;
        stored_goal = .{
            .objective = try gpa.dupe(u8, objective),
            .status = "active",
            .continues = prev_continues,
            .tokens_used = 0,
            .token_budget = cfg.token_budget,
        };
    } else if (stored_goal) |g| {
        if (std.mem.eql(u8, g.status, "active")) {
            goal_active = true;
            objective = g.objective;
        }
    }

    // --- System message: goal directive (replaces any prior system) or system_prompt ---
    if (goal_active) {
        if (messages.items.len > 0 and std.mem.eql(u8, messages.items[0].role, "system"))
            _ = messages.orderedRemove(0);
        const dir = try goalmod.directive(gpa, objective);
        const sys_content = if (cfg.system_prompt) |sp|
            try std.fmt.allocPrint(gpa, "{s}\n\n{s}", .{ sp, dir })
        else
            dir;
        try messages.insert(gpa, 0, .{ .role = "system", .content = sys_content });
    } else if (messages.items.len == 0) {
        if (cfg.system_prompt) |sp|
            try messages.append(gpa, .{ .role = "system", .content = try gpa.dupe(u8, sp) });
    }

    // --- User turn ---
    const user_text: []const u8 = blk: {
        if (cfg.goal_action == .set) break :blk "Begin working toward the objective above.";
        if (cfg.prompt) |p| break :blk p;
        if (goal_active) break :blk "Continue working toward the objective.";
        return .{ .exit_code = 82, .tokens_out = 0 };
    };
    // Feedback injection: when loopmod provides feedback, prepend it to the
    // user turn so the Author sees the Critic's review.
    const final_user_text: []const u8 = blk: {
        if (cfg.feedback_message) |fb| {
            const composed = try std.fmt.allocPrint(gpa,
                "Previous critic feedback (address every concrete defect before declaring READY):\n{s}\n\nBegin your Author turn.",
                .{fb});
            break :blk composed;
        }
        break :blk user_text;
    };
    try messages.append(gpa, .{ .role = "user", .content = try gpa.dupe(u8, final_user_text) });

    // --- Tools ---
    const enabled_tools = try registry_mod.getEnabledTools(gpa, cfg.tools_allow, cfg.tools_deny);
    defer gpa.free(enabled_tools);
    var tool_infos = std.ArrayList(provider_mod.ToolInfo).empty;
    defer tool_infos.deinit(gpa);
    for (enabled_tools) |tool| {
        try tool_infos.append(gpa, .{ .name = tool.name, .description = tool.description });
    }
    const tool_infos_slice = try tool_infos.toOwnedSlice(gpa);
    defer gpa.free(tool_infos_slice);

    // --- Dry run: one planning turn, report tools that WOULD run, execute none ---
    if (cfg.dry_run) {
        const resp = try provider_mod.complete(io, gpa, cfg_with_key, messages.items, tool_infos_slice);
        defer gpa.free(resp.content);
        if (resp.tool_calls.len == 0) {
            try emitFinal(gpa, cfg, resp, false);
            return .{ .exit_code = 0, .tokens_out = 0 };
        }
        switch (cfg.mode) {
            .text => {
                const hdr = "[dry-run] tau would call:\n";
                term.out(hdr);
                for (resp.tool_calls) |tc| {
                    const line = try std.fmt.allocPrint(gpa, "  - {s} {s}\n", .{ tc.name, tc.arguments });
                    defer gpa.free(line);
                    term.out(line);
                }
            },
            .json => {
                var buf: std.ArrayList(u8) = .empty;
                defer buf.deinit(gpa);
                try buf.appendSlice(gpa, "{\"dry_run\":true,\"tool_calls\":[");
                for (resp.tool_calls, 0..) |tc, i| {
                    if (i != 0) try buf.append(gpa, ',');
                    const ne = try jsonmod.escapeAlloc(gpa, tc.name);
                    defer gpa.free(ne);
                    const ae = try jsonmod.escapeAlloc(gpa, tc.arguments);
                    defer gpa.free(ae);
                    const obj = try std.fmt.allocPrint(gpa, "{{\"name\":\"{s}\",\"arguments\":\"{s}\"}}", .{ ne, ae });
                    defer gpa.free(obj);
                    try buf.appendSlice(gpa, obj);
                }
                try buf.appendSlice(gpa, "]}\n");
                term.out(buf.items);
            },
        }
        return .{ .exit_code = 0, .tokens_out = 0 };
    }

    // --- Agentic loop ---
    var iteration: u32 = 0;
    const max_iterations: u32 = if (goal_active) cfg.goal_max_iterations else cfg.max_iterations;
    var tokens_out: u64 = if (stored_goal) |g| g.tokens_used else 0;
    var exit_code: u8 = 110; // cap exceeded unless we break out cleanly
    var goal_done = false;
    var budget_hit = false;

    loop: while (iteration < max_iterations) : (iteration += 1) {
        const sentinel = effectiveSentinel(cfg);
        // Auto-compaction before each model call (best-effort).
        if (context_mod.shouldCompact(messages.items, cfg_with_key))
            context_mod.compact(io, gpa, cfg_with_key, &messages) catch {};

        // Streaming path: token-stream content + silently assemble tool_calls.
        // Non-streaming path: blocking full-response.
        // Both return the same Response shape; tool execution is identical either way.
        const response = if (cfg.stream and !cfg.dry_run)
            try provider_mod.completeStreamWithTools(io, gpa, cfg_with_key, messages.items, tool_infos_slice, goal_active)
        else
            try provider_mod.complete(io, gpa, cfg_with_key, messages.items, tool_infos_slice);
        defer gpa.free(response.content);
        // Prefer API-reported token count; fall back to content-length estimate.
        tokens_out += response.total_tokens orelse (response.content.len + 3) / 4;

        const content_dupe = try gpa.dupe(u8, response.content);
        try messages.append(gpa, .{
            .role = "assistant",
            .content = content_dupe,
            .tool_calls = if (response.tool_calls.len > 0) response.tool_calls else null,
        });

        if (response.tool_calls.len == 0) {
            // Sentinel check: when an effective sentinel is set (goal mode OR
            // Author↔Critic exit_sentinel), a no-tool turn is only terminal if
            // the model emitted the sentinel on its own line. Otherwise nudge.
            if (sentinel != null and !sentinelMatch(response.content, sentinel.?)) {
                if (cfg.token_budget) |b| if (tokens_out >= b) {
                    budget_hit = true;
                    exit_code = 0;
                    break :loop;
                };
                // Nudge: goal mode uses a generic nudge; A/C uses a role-specific nudge.
                const nudge_text: []const u8 = switch (cfg.role) {
                    .author => "You stopped without emitting <READY_FOR_REVIEW>. Audit your work, finish, and end with <READY_FOR_REVIEW> on its own line.",
                    .critic => "You stopped without emitting <APPROVED> or <BLOCKED>. Finish your review and end with exactly one of those tokens on its own line.",
                    else => goalmod.NUDGE,
                };
                try messages.append(gpa, .{ .role = "user", .content = try gpa.dupe(u8, nudge_text) });
                continue :loop;
            }
            // Streaming already emitted content + done marker; non-streaming needs emitFinal.
            if (!cfg.stream) try emitFinal(gpa, cfg, response, goal_active);
            if (goal_active) goal_done = true;
            exit_code = 0;
            break :loop;
        }

        if (goal_active) if (cfg.token_budget) |b| if (tokens_out >= b) {
            budget_hit = true;
            exit_code = 0;
            break :loop;
        };

        // Execute tool calls.
        for (response.tool_calls) |tool_call| {
            const tcid = try gpa.dupe(u8, tool_call.id);
            const tool = registry_mod.getTool(tool_call.name) orelse {
                const error_msg = try std.fmt.allocPrint(gpa, "Tool '{s}' not found", .{tool_call.name});
                defer gpa.free(error_msg);
                const error_dupe = try gpa.dupe(u8, error_msg);
                try messages.append(gpa, .{ .role = "tool", .content = error_dupe, .tool_call_id = tcid });
                continue;
            };

            if (cfg.debug) {
                const debug_input = try std.fmt.allocPrint(gpa, "[DEBUG] Tool: {s}, Args: {s}\n", .{ tool_call.name, tool_call.arguments });
                defer gpa.free(debug_input);
                term.err(debug_input);
            }

            const args = try buildToolArgs(gpa, tool_call.name, tool_call.arguments);
            defer {
                for (args) |arg| gpa.free(arg);
                gpa.free(args);
            }

            const tool_result = tool.execute(io, gpa, args, cfg.timeout_ms) catch |err| {
                const error_msg = try std.fmt.allocPrint(gpa, "Tool execution failed: {s}", .{@errorName(err)});
                defer gpa.free(error_msg);
                const error_dupe = try gpa.dupe(u8, error_msg);
                try messages.append(gpa, .{ .role = "tool", .content = error_dupe, .tool_call_id = tcid });
                continue;
            };

            if (cfg.debug) {
                const debug_output = try std.fmt.allocPrint(gpa, "[DEBUG] Tool result (success={}): {s}\n", .{ tool_result.success, tool_result.stdout });
                defer gpa.free(debug_output);
                term.err(debug_output);
                if (!tool_result.success and tool_result.stderr.len > 0) {
                    const debug_err = try std.fmt.allocPrint(gpa, "[DEBUG] Tool stderr: {s}\n", .{tool_result.stderr});
                    defer gpa.free(debug_err);
                    term.err(debug_err);
                }
            }

            const result_msg = if (tool_result.success)
                try std.fmt.allocPrint(gpa, "{s}", .{tool_result.stdout})
            else
                try std.fmt.allocPrint(gpa, "Error: {s}", .{tool_result.stderr});
            defer gpa.free(result_msg);

            const result_dupe = try gpa.dupe(u8, result_msg);
            try messages.append(gpa, .{ .role = "tool", .content = result_dupe, .tool_call_id = tcid });
        }
    }

    // If the (non-goal) loop hit the cap while still calling tools, force one
    // final tool-free completion so there is always an answer (matches ACP).
    if (exit_code == 110 and !goal_active) {
        try messages.append(gpa, .{ .role = "user", .content = try gpa.dupe(u8, "You have gathered enough. Stop using tools and give your final answer now.") });
        if (provider_mod.complete(io, gpa, cfg_with_key, messages.items, null) catch null) |fin| {
            try emitFinal(gpa, cfg, fin, false);
            try messages.append(gpa, .{ .role = "assistant", .content = fin.content });
            exit_code = 0;
        }
    }

    // --- Persist session (history + updated goal) ---
    if (cfg.session) |name| {
        if (stored_goal) |*g| {
            g.continues += 1;
            g.tokens_used = tokens_out;
            if (goal_done) {
                g.status = "complete";
            } else if (budget_hit) {
                g.status = "budget_limited";
            }
        }
        saveSession(io, gpa, env_map, name, messages.items, stored_goal);
    }

    return .{ .exit_code = exit_code, .tokens_out = tokens_out };
}

/// Handle /goal status|pause|resume|clear|complete (no model call). Requires a
/// session. Prints the resulting goal state and persists it.
fn goalSubcommand(
    io: std.Io,
    gpa: std.mem.Allocator,
    env_map: *std.process.Environ.Map,
    cfg: anytype,
    messages: *std.ArrayList(provider_mod.Message),
    stored_goal: *?session_mod.GoalState,
) !u8 {
    const name = cfg.session orelse {
        const msg = "{\"err\":{\"code\":80,\"type\":\"invalid_argument\",\"message\":\"/goal subcommands require --session <name>\"}}\n";
        term.err(msg);
        return 80;
    };

    switch (cfg.goal_action) {
        .pause => if (stored_goal.*) |*g| {
            g.status = "paused";
        },
        .resume_ => if (stored_goal.*) |*g| {
            g.status = "active";
        },
        .complete => if (stored_goal.*) |*g| {
            g.status = "complete";
        },
        .clear => stored_goal.* = null,
        else => {}, // status: print only
    }

    if (stored_goal.*) |g| {
        const obj = try jsonmod.escapeAlloc(gpa, g.objective);
        defer gpa.free(obj);
        const out = try std.fmt.allocPrint(gpa, "{{\"goal\":{{\"objective\":\"{s}\",\"status\":\"{s}\",\"continues\":{d},\"tokens_used\":{d}}}}}\n", .{ obj, g.status, g.continues, g.tokens_used });
        defer gpa.free(out);
        term.out(out);
    } else {
        const out = "{\"goal\":null}\n";
        term.out(out);
    }

    saveSession(io, gpa, env_map, name, messages.items, stored_goal.*);
    return 0;
}

/// Emit the final assistant turn (optional thinking block + content). In goal
/// mode the sentinel token is stripped from the printed content.
fn emitFinal(gpa: std.mem.Allocator, cfg: anytype, response: provider_mod.Response, goal_active: bool) !void {
    if (cfg.thinking) {
        if (response.reasoning_content) |rc| switch (cfg.mode) {
            .text => {
                const prefix = "[THINKING] ";
                term.out(prefix);
                term.out(rc);
                term.out("\n");
            },
            .json => {
                const esc = try jsonmod.escapeAlloc(gpa, rc);
                defer gpa.free(esc);
                const out = try std.fmt.allocPrint(gpa, "{{\"reasoning\":\"{s}\",\"done\":false}}\n", .{esc});
                defer gpa.free(out);
                term.out(out);
            },
        };
    }

    var content = response.content;
    var owned: ?[]u8 = null;
    defer if (owned) |o| gpa.free(o);
    if (goal_active and goalmod.isMet(content)) {
        const stripped = try stripAll(gpa, content, goalmod.SENTINEL);
        owned = stripped;
        content = std.mem.trim(u8, stripped, " \t\r\n");
    }

    switch (cfg.mode) {
        .text => {
            term.out(content);
            term.out("\n");
        },
        .json => {
            const esc = try jsonmod.escapeAlloc(gpa, content);
            defer gpa.free(esc);
            const out = try std.fmt.allocPrint(gpa, "{{\"version\":\"{s}\",\"model\":\"{s}\",\"content\":\"{s}\",\"done\":true}}\n", .{ @import("main.zig").version, cfg.model, esc });
            defer gpa.free(out);
            term.out(out);
        },
    }
}

fn stripAll(gpa: std.mem.Allocator, s: []const u8, needle: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var rest = s;
    while (std.mem.indexOf(u8, rest, needle)) |idx| {
        try out.appendSlice(gpa, rest[0..idx]);
        rest = rest[idx + needle.len ..];
    }
    try out.appendSlice(gpa, rest);
    return out.toOwnedSlice(gpa);
}

/// Best-effort session persistence. Failures are reported to stderr but do not
/// abort the run.
fn saveSession(
    io: std.Io,
    gpa: std.mem.Allocator,
    env_map: *std.process.Environ.Map,
    name: []const u8,
    msgs: []const provider_mod.Message,
    goal: ?session_mod.GoalState,
) void {
    const st = session_mod.SessionState{ .name = name, .goal = goal, .messages = msgs };
    session_mod.save(io, gpa, env_map, st) catch |err| {
        const m = std.fmt.allocPrint(gpa, "[WARN] failed to save session {s}: {s}\n", .{ name, @errorName(err) }) catch return;
        defer gpa.free(m);
        term.err(m);
    };
}

fn hasNull(s: []const u8) bool {
    return std.mem.indexOfScalar(u8, s, 0) != null;
}

/// True if `content` contains `sentinel` on its own line. Wraps `loopmod.hasSentinel`
/// or `goalmod.isMet` depending on the sentinel string.
fn sentinelMatch(content: []const u8, sentinel: []const u8) bool {
    if (std.mem.eql(u8, sentinel, goalmod.SENTINEL)) return goalmod.isMet(content);
    return loopmod.hasSentinel(content, sentinel);
}

/// A tool path must be non-empty, null-free, and free of `..` traversal
/// components (absolute paths and clean relative paths are allowed; only
/// parent-escapes like ../../etc/passwd are rejected).
fn safePath(p: []const u8) bool {
    if (p.len == 0 or hasNull(p)) return false;
    var it = std.mem.splitScalar(u8, p, '/');
    while (it.next()) |seg| if (std.mem.eql(u8, seg, "..")) return false;
    return true;
}

const FieldKind = enum { path, command, content, pattern };
const FieldSpec = struct { key: []const u8, required: bool, kind: FieldKind };
const ToolSpec = struct { name: []const u8, fields: []const FieldSpec };

const tool_specs = [_]ToolSpec{
    .{ .name = "bash", .fields = &.{
        .{ .key = "command",    .required = true,  .kind = .command },
    }},
    .{ .name = "ls", .fields = &.{
        .{ .key = "path",       .required = false, .kind = .path },
    }},
    .{ .name = "read", .fields = &.{
        .{ .key = "path",       .required = true,  .kind = .path },
    }},
    .{ .name = "write", .fields = &.{
        .{ .key = "path",       .required = true,  .kind = .path },
        .{ .key = "content",    .required = true,  .kind = .content },
    }},
    .{ .name = "edit", .fields = &.{
        .{ .key = "path",       .required = true,  .kind = .path },
        .{ .key = "old_string", .required = true,  .kind = .content },
        .{ .key = "new_string", .required = true,  .kind = .content },
    }},
    .{ .name = "grep", .fields = &.{
        .{ .key = "pattern",    .required = true,  .kind = .pattern },
        .{ .key = "path",       .required = false, .kind = .path },
    }},
    .{ .name = "find", .fields = &.{
        .{ .key = "pattern",    .required = true,  .kind = .pattern },
        .{ .key = "path",       .required = false, .kind = .path },
    }},
};

/// Build argument array for a tool based on its name and arguments JSON.
/// Validates inputs: rejects null bytes in any argument, empty bash commands,
/// and `..` traversal in file paths (returns error.UnsafeArgument).
pub fn buildToolArgs(gpa: std.mem.Allocator, tool_name: []const u8, args_json: []const u8) ![][]const u8 {
    const spec = blk: {
        for (&tool_specs) |*s| {
            if (std.mem.eql(u8, s.name, tool_name)) break :blk s;
        }
        return error.UnknownTool;
    };

    var args = std.ArrayList([]const u8).empty;
    defer args.deinit(gpa);

    for (spec.fields) |field| {
        const val = try jsonmod.getStringArg(gpa, args_json, field.key);
        if (val == null) {
            if (field.required) return error.MissingArgument;
            continue;
        }
        const v = val.?;
        const ok = switch (field.kind) {
            .path    => safePath(v),
            .command => v.len > 0 and !hasNull(v),
            .content => !hasNull(v),
            .pattern => !hasNull(v),
        };
        if (!ok) return error.UnsafeArgument;
        try args.append(gpa, v);
    }

    return args.toOwnedSlice(gpa);
}

test "buildToolArgs rejects unsafe paths and empty commands" {
    // Use an arena (as the real callers do — per-turn arena in ACP, process
    // lifetime in the CLI) so partial allocations on the validated error paths
    // are reclaimed in one shot.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.UnsafeArgument, buildToolArgs(a, "write", "{\"path\":\"../../etc/passwd\",\"content\":\"x\"}"));
    try std.testing.expectError(error.UnsafeArgument, buildToolArgs(a, "read", "{\"path\":\"a/../../b\"}"));
    try std.testing.expectError(error.UnsafeArgument, buildToolArgs(a, "bash", "{\"command\":\"\"}"));
    const ok = try buildToolArgs(a, "read", "{\"path\":\"/home/u/proj/main.zig\"}");
    try std.testing.expectEqualStrings("/home/u/proj/main.zig", ok[0]);
}
