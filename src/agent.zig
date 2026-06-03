const std = @import("std");
const provider_mod = @import("llm/provider.zig");
const registry_mod = @import("tools/registry.zig");
const cfgmod = @import("config.zig");
const jsonmod = @import("json.zig");

pub fn run(io: std.Io, gpa: std.mem.Allocator, cfg: anytype, env_map: *std.process.Environ.Map) !u8 {
    // Resolve API key
    const api_key = cfgmod.resolveApiKey(cfg, env_map) orelse return 106; // auth_failed

    // Build config with resolved API key
    var cfg_with_key = cfg;
    cfg_with_key.api_key = api_key;
    // Build initial message array
    var messages = std.ArrayList(provider_mod.Message).empty;
    defer messages.deinit(gpa);

    // Add system prompt if provided
    if (cfg.system_prompt) |sp| {
        const sp_dupe = try gpa.dupe(u8, sp);
        try messages.append(gpa, .{
            .role = "system",
            .content = sp_dupe,
        });
    }

    // Add user prompt
    const prompt = cfg.prompt orelse return 82; // missing_required_field
    const prompt_dupe = try gpa.dupe(u8, prompt);
    try messages.append(gpa, .{
        .role = "user",
        .content = prompt_dupe,
    });

    // Streaming path: a pure chat turn, no tools (tool_call assembly is not
    // streamed). completeStream writes output incrementally per cfg.mode.
    if (cfg.stream) {
        try provider_mod.completeStream(io, gpa, cfg_with_key, messages.items);
        return 0;
    }

    // Get enabled tools
    const enabled_tools = try registry_mod.getEnabledTools(gpa, cfg.tools_allow, cfg.tools_deny);
    defer gpa.free(enabled_tools);

    // Build tool info array for provider
    var tool_infos = std.ArrayList(provider_mod.ToolInfo).empty;
    defer tool_infos.deinit(gpa);
    for (enabled_tools) |tool| {
        try tool_infos.append(gpa, .{
            .name = tool.name,
            .description = tool.description,
        });
    }
    const tool_infos_slice = try tool_infos.toOwnedSlice(gpa);
    defer gpa.free(tool_infos_slice);

    // Main agentic loop
    var iteration: u32 = 0;
    const max_iterations = 10; // Prevent infinite loops

    while (iteration < max_iterations) : (iteration += 1) {
        // Call LLM with tool schema
        const response = try provider_mod.complete(io, gpa, cfg_with_key, messages.items, tool_infos_slice);
        defer gpa.free(response.content);

        // Add assistant response to history (dupe content to avoid UAF). Carry
        // the tool_calls so the model sees its own call on the next turn and
        // answers instead of re-calling. response.tool_calls outlives this loop
        // iteration (freed at function end), so referencing it here is safe.
        const content_dupe = try gpa.dupe(u8, response.content);
        try messages.append(gpa, .{
            .role = "assistant",
            .content = content_dupe,
            .tool_calls = if (response.tool_calls.len > 0) response.tool_calls else null,
        });

        // If no tool calls, we're done
        if (response.tool_calls.len == 0) {
            // Output the final response
            switch (cfg.mode) {
                .text => {
                    const linux = std.os.linux;
                    _ = linux.write(1, response.content.ptr, response.content.len);
                    _ = linux.write(1, "\n".ptr, 1);
                },
                .json => {
                    const json_mod = @import("json.zig");
                    const esc = try json_mod.escapeAlloc(gpa, response.content);
                    defer gpa.free(esc);
                    const out = try std.fmt.allocPrint(gpa, "{{\"version\":\"{s}\",\"model\":\"{s}\",\"content\":\"{s}\",\"done\":true}}\n", .{ @import("main.zig").version, cfg.model, esc });
                    defer gpa.free(out);
                    const linux = std.os.linux;
                    _ = linux.write(1, out.ptr, out.len);
                },
            }
            return 0; // success
        }

        // Execute tool calls
        for (response.tool_calls) |tool_call| {
            // Find tool in registry
            const tcid = try gpa.dupe(u8, tool_call.id);
            const tool = registry_mod.getTool(tool_call.name) orelse {
                const error_msg = try std.fmt.allocPrint(gpa, "Tool '{s}' not found", .{tool_call.name});
                defer gpa.free(error_msg);
                const error_dupe = try gpa.dupe(u8, error_msg);
                try messages.append(gpa, .{
                    .role = "tool",
                    .content = error_dupe,
                    .tool_call_id = tcid,
                });
                continue;
            };

            // Parse arguments using json.zig helpers
            const args = try buildToolArgs(gpa, tool_call.name, tool_call.arguments);
            defer {
                for (args) |arg| gpa.free(arg);
                gpa.free(args);
            }

            // Execute tool with parsed arguments
            const tool_result = tool.execute(io, gpa, args, cfg.timeout_ms) catch |err| {
                const error_msg = try std.fmt.allocPrint(gpa, "Tool execution failed: {s}", .{@errorName(err)});
                defer gpa.free(error_msg);
                const error_dupe = try gpa.dupe(u8, error_msg);
                try messages.append(gpa, .{
                    .role = "tool",
                    .content = error_dupe,
                    .tool_call_id = tcid,
                });
                continue;
            };

            // Append tool result as tool role message
            const result_msg = if (tool_result.success)
                try std.fmt.allocPrint(gpa, "{s}", .{tool_result.stdout})
            else
                try std.fmt.allocPrint(gpa, "Error: {s}", .{tool_result.stderr});
            defer gpa.free(result_msg);

            const result_dupe = try gpa.dupe(u8, result_msg);
            try messages.append(gpa, .{
                .role = "tool",
                .content = result_dupe,
                .tool_call_id = tcid,
            });
        }
    }

    return 110; // internal_error - max iterations exceeded
}

/// Build argument array for a tool based on its name and arguments JSON
fn buildToolArgs(gpa: std.mem.Allocator, tool_name: []const u8, args_json: []const u8) ![][]const u8 {
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