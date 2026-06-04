const std = @import("std");
const provider_mod = @import("llm/provider.zig");
const registry_mod = @import("tools/registry.zig");
const cfgmod = @import("config.zig");
const jsonmod = @import("json.zig");
const goalmod = @import("goal.zig");
const context_mod = @import("context.zig");
const session_mod = @import("session.zig");

const linux = std.os.linux;

pub fn run(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    cfg: anytype,
    env_map: *std.process.Environ.Map,
) !u8 {
    const api_key = cfgmod.resolveApiKey(cfg, env_map) orelse return 106; // auth_failed
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
            return goalSubcommand(io, gpa, env_map, cfg, &messages, &stored_goal);
        },
        else => {},
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
        return 82; // missing_required_field
    };
    try messages.append(gpa, .{ .role = "user", .content = try gpa.dupe(u8, user_text) });

    // --- Streaming chat path (ephemeral single-shot only) ---
    // Skipped for goal mode (needs the tool loop) and for sessions (streaming
    // doesn't capture the assistant turn, so history would be incomplete — the
    // non-streaming loop below records full history instead).
    if (cfg.stream and !goal_active and cfg.session == null) {
        try provider_mod.completeStream(io, gpa, cfg_with_key, messages.items);
        return 0;
    }

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

    // --- Agentic loop ---
    var iteration: u32 = 0;
    const max_iterations: u32 = if (goal_active) cfg.goal_max_iterations else cfg.max_iterations;
    var tokens_out: u64 = if (stored_goal) |g| g.tokens_used else 0;
    var exit_code: u8 = 110; // cap exceeded unless we break out cleanly
    var goal_done = false;
    var budget_hit = false;

    loop: while (iteration < max_iterations) : (iteration += 1) {
        // Auto-compaction before each model call (best-effort).
        if (context_mod.shouldCompact(messages.items, cfg_with_key))
            context_mod.compact(io, gpa, cfg_with_key, &messages) catch {};

        const response = try provider_mod.complete(io, gpa, cfg_with_key, messages.items, tool_infos_slice);
        defer gpa.free(response.content);
        tokens_out += (response.content.len + 3) / 4;

        const content_dupe = try gpa.dupe(u8, response.content);
        try messages.append(gpa, .{
            .role = "assistant",
            .content = content_dupe,
            .tool_calls = if (response.tool_calls.len > 0) response.tool_calls else null,
        });

        if (response.tool_calls.len == 0) {
            // In goal mode, a no-tool turn is only terminal with the sentinel.
            if (goal_active and !goalmod.isMet(response.content)) {
                if (cfg.token_budget) |b| if (tokens_out >= b) {
                    budget_hit = true;
                    exit_code = 0;
                    break :loop;
                };
                try messages.append(gpa, .{ .role = "user", .content = try gpa.dupe(u8, goalmod.NUDGE) });
                continue :loop;
            }
            try emitFinal(gpa, cfg, response, goal_active);
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
                _ = linux.write(2, debug_input.ptr, debug_input.len);
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
                _ = linux.write(2, debug_output.ptr, debug_output.len);
                if (!tool_result.success and tool_result.stderr.len > 0) {
                    const debug_err = try std.fmt.allocPrint(gpa, "[DEBUG] Tool stderr: {s}\n", .{tool_result.stderr});
                    defer gpa.free(debug_err);
                    _ = linux.write(2, debug_err.ptr, debug_err.len);
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

    return exit_code;
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
        _ = linux.write(2, msg.ptr, msg.len);
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
        _ = linux.write(1, out.ptr, out.len);
    } else {
        const out = "{\"goal\":null}\n";
        _ = linux.write(1, out.ptr, out.len);
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
                _ = linux.write(1, prefix.ptr, prefix.len);
                _ = linux.write(1, rc.ptr, rc.len);
                _ = linux.write(1, "\n".ptr, 1);
            },
            .json => {
                const esc = try jsonmod.escapeAlloc(gpa, rc);
                defer gpa.free(esc);
                const out = try std.fmt.allocPrint(gpa, "{{\"reasoning\":\"{s}\",\"done\":false}}\n", .{esc});
                defer gpa.free(out);
                _ = linux.write(1, out.ptr, out.len);
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
            _ = linux.write(1, content.ptr, content.len);
            _ = linux.write(1, "\n".ptr, 1);
        },
        .json => {
            const esc = try jsonmod.escapeAlloc(gpa, content);
            defer gpa.free(esc);
            const out = try std.fmt.allocPrint(gpa, "{{\"version\":\"{s}\",\"model\":\"{s}\",\"content\":\"{s}\",\"done\":true}}\n", .{ @import("main.zig").version, cfg.model, esc });
            defer gpa.free(out);
            _ = linux.write(1, out.ptr, out.len);
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
        _ = linux.write(2, m.ptr, m.len);
    };
}

/// Build argument array for a tool based on its name and arguments JSON
pub fn buildToolArgs(gpa: std.mem.Allocator, tool_name: []const u8, args_json: []const u8) ![][]const u8 {
    var args = std.ArrayList([]const u8).empty;
    defer args.deinit(gpa);

    if (std.mem.eql(u8, tool_name, "bash")) {
        const command = (try jsonmod.getStringArg(gpa, args_json, "command")) orelse return error.MissingArgument;
        try args.append(gpa, command);
    } else if (std.mem.eql(u8, tool_name, "ls")) {
        const path = try jsonmod.getStringArg(gpa, args_json, "path");
        if (path) |p| try args.append(gpa, p);
    } else if (std.mem.eql(u8, tool_name, "read")) {
        const path = (try jsonmod.getStringArg(gpa, args_json, "path")) orelse return error.MissingArgument;
        try args.append(gpa, path);
    } else if (std.mem.eql(u8, tool_name, "write")) {
        const path = (try jsonmod.getStringArg(gpa, args_json, "path")) orelse return error.MissingArgument;
        const content = (try jsonmod.getStringArg(gpa, args_json, "content")) orelse return error.MissingArgument;
        try args.append(gpa, path);
        try args.append(gpa, content);
    } else if (std.mem.eql(u8, tool_name, "edit")) {
        const path = (try jsonmod.getStringArg(gpa, args_json, "path")) orelse return error.MissingArgument;
        const old_string = (try jsonmod.getStringArg(gpa, args_json, "old_string")) orelse return error.MissingArgument;
        const new_string = (try jsonmod.getStringArg(gpa, args_json, "new_string")) orelse return error.MissingArgument;
        try args.append(gpa, path);
        try args.append(gpa, old_string);
        try args.append(gpa, new_string);
    } else if (std.mem.eql(u8, tool_name, "grep")) {
        const pattern = (try jsonmod.getStringArg(gpa, args_json, "pattern")) orelse return error.MissingArgument;
        try args.append(gpa, pattern);
        const path = try jsonmod.getStringArg(gpa, args_json, "path");
        if (path) |p| try args.append(gpa, p);
    } else if (std.mem.eql(u8, tool_name, "find")) {
        const pattern = (try jsonmod.getStringArg(gpa, args_json, "pattern")) orelse return error.MissingArgument;
        try args.append(gpa, pattern);
        const path = try jsonmod.getStringArg(gpa, args_json, "path");
        if (path) |p| try args.append(gpa, p);
    } else {
        return error.UnknownTool;
    }

    return args.toOwnedSlice(gpa);
}
