const std = @import("std");
const provider_mod = @import("llm/provider.zig");
const registry_mod = @import("tools/registry.zig");
const cfgmod = @import("config.zig");

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
        try messages.append(gpa, .{
            .role = "system",
            .content = sp,
        });
    }

    // Add user prompt
    const prompt = cfg.prompt orelse return 82; // missing_required_field
    try messages.append(gpa, .{
        .role = "user",
        .content = prompt,
    });

    // Get enabled tools
    const enabled_tools = try registry_mod.getEnabledTools(gpa, cfg.tools_allow, cfg.tools_deny);
    defer gpa.free(enabled_tools);

    // Main agentic loop
    var iteration: u32 = 0;
    const max_iterations = 10; // Prevent infinite loops

    while (iteration < max_iterations) : (iteration += 1) {
        // Call LLM
        const response = try provider_mod.complete(io, gpa, cfg_with_key, messages.items, null);
        defer gpa.free(response.content);

        // Add assistant response to history
        try messages.append(gpa, .{
            .role = "assistant",
            .content = response.content,
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
        for (response.tool_calls) |_| {
            // TODO: Parse tool_call.arguments and execute the tool
            // For now, just acknowledge
            try messages.append(gpa, .{
                .role = "tool",
                .content = "Tool execution not yet implemented",
            });
        }
    }

    return 110; // internal_error - max iterations exceeded
}