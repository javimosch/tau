const std = @import("std");
const linux = std.os.linux;

// Custom errors for LLM API calls
const LLMError = error {
    MissingApiKey,
    HTTPRequestFailed,
    InvalidResponse,
    Timeout,
};

// Semantic exit codes following Square's system
const ExitCode = enum(u8) {
    success = 0,
    generic_failure = 1,
    // User errors (80-89): Input/validation errors
    invalid_argument = 80,
    bad_permissions = 81,
    missing_required_field = 82,
    // Resource/state errors (90-99)
    resource_not_found = 92,
    resource_already_exists = 93,
    conflict = 94,
    // Integration/external errors (100-109)
    connection_timeout = 105,
    auth_failed = 106,
    rate_limited = 107,
    // Internal software errors (110-119)
    internal_error = 110,
    unimplemented = 111,
};

const Config = struct {
    json_output: bool = true, // Default to JSON for agents
    stream_output: bool = true, // Default to streaming
    help_json: bool = false,
    prompt: ?[]const u8 = null,
    model: []const u8 = "mimo-v2.5",
    api_key: ?[]const u8 = "tp-ejau4ye7ifigruk0ji0r5xul1nk00vwc9i1m32jdstxpcg52",
    api_endpoint: []const u8 = "https://token-plan-ams.xiaomimimo.com/v1/chat/completions",
    max_tokens: ?u32 = null,
    temperature: f32 = 0.7,
    // Reasoning models (e.g. mimo-v2.5) routinely take >30s for non-trivial
    // generations, so default generously. Earlier 30s caused spurious timeouts.
    timeout_ms: i64 = 120_000,
};

// Simple JSON output using direct Linux write calls (from supercli-zig pattern)
fn printJson(version: []const u8, chunk: []const u8, done: bool) void {
    const json = std.fmt.allocPrint(std.heap.page_allocator, "{{\"version\":\"{s}\",\"chunk\":\"{s}\",\"done\":{any}}}\n", .{ version, chunk, done }) catch return;
    defer std.heap.page_allocator.free(json);
    _ = linux.write(1, json.ptr, json.len);
}

// Call LLM API using curl with Zig 0.16.0 std.process.run API (from supercli-zig pattern)
fn callLLMAPI(io: std.Io, gpa: std.mem.Allocator, config: Config, prompt: []const u8) ![]const u8 {
    // For simplicity, we'll use the prompt as-is and assume no special characters
    // In production, proper JSON escaping would be needed
    const json_body = try std.fmt.allocPrint(gpa, "{{\"model\":\"{s}\",\"messages\":[{{\"role\":\"user\",\"content\":\"{s}\"}}],\"stream\":false}}", .{ config.model, prompt });
    defer gpa.free(json_body);

    // Use curl with --data-raw for the API call
    // Execute curl directly instead of via shell to avoid quoting issues
    var argv_list: std.ArrayList([]const u8) = .empty;
    defer argv_list.deinit(gpa);
    try argv_list.append(gpa, "curl");
    try argv_list.append(gpa, "-s");
    try argv_list.append(gpa, "-X");
    try argv_list.append(gpa, "POST");
    try argv_list.append(gpa, config.api_endpoint);
    try argv_list.append(gpa, "-H");
    try argv_list.append(gpa, "Authorization: Bearer tp-ejau4ye7ifigruk0ji0r5xul1nk00vwc9i1m32jdstxpcg52");
    try argv_list.append(gpa, "-H");
    try argv_list.append(gpa, "Content-Type: application/json");
    try argv_list.append(gpa, "--data-raw");
    try argv_list.append(gpa, json_body);

    const argv_slice = try argv_list.toOwnedSlice(gpa);
    defer gpa.free(argv_slice);

    // Use Zig 0.16.0 std.process.run API (from supercli-zig pattern).
    // A relative timeout on the monotonic ("awake") clock — immune to
    // wall-clock adjustments. The std.process.run timeout is reliable; the
    // previous "exit code 110" blocker was simply a too-short (30s) limit
    // being exceeded by the LLM, surfacing as piz's own internal_error code.
    const timeout = std.Io.Timeout{
        .duration = .{
            .raw = std.Io.Duration.fromMilliseconds(config.timeout_ms),
            .clock = .awake,
        },
    };

    const result = std.process.run(gpa, io, .{
        .argv = argv_slice,
        .stdout_limit = .unlimited,
        .stderr_limit = .unlimited,
        .timeout = timeout,
    }) catch |err| {
        if (err == error.Timeout) {
            return error.Timeout;
        }
        return error.HTTPRequestFailed;
    };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    const exit_code: u8 = switch (result.term) {
        .exited => |c| c,
        else => 1,
    };

    if (exit_code != 0) {
        return error.HTTPRequestFailed;
    }

    const response = std.mem.trim(u8, result.stdout, "\n\r ");

    // Parse JSON response to extract content
    // Response format: {"choices":[{"message":{"content":"..."}}]}
    var content_start = std.mem.indexOf(u8, response, "\"content\":\"") orelse return error.InvalidResponse;
    content_start += "\"content\":\"".len;

    // Find the closing quote, skipping escaped quotes (\") — the content is
    // JSON-encoded HTML and is full of escaped quotes that would otherwise
    // truncate it at the first inner quote.
    var content_end = content_start;
    while (content_end < response.len) : (content_end += 1) {
        if (response[content_end] == '\\') {
            content_end += 1; // skip the escaped character
            continue;
        }
        if (response[content_end] == '"') break;
    } else return error.InvalidResponse;

    // Extract content
    const content = response[content_start..content_end];

    // Return a copy of the content
    return gpa.dupe(u8, content);
}

fn printErrorJson(code: u8, error_type: []const u8, message: []const u8, recoverable: bool) void {
    const json = std.fmt.allocPrint(std.heap.page_allocator, "{{\"err\":{{\"code\":{d},\"type\":\"{s}\",\"message\":\"{s}\",\"recoverable\":{any}}}}}\n", .{ code, error_type, message, recoverable }) catch return;
    defer std.heap.page_allocator.free(json);
    _ = linux.write(2, json.ptr, json.len);
}

fn printHelpJson() void {
    const json = "{{\"version\":\"0.1.0\",\"name\":\"piz\",\"description\":\"Agent-first AI CLI - simplified Zig implementation of pi\",\"commands\":{{\"main\":{{\"description\":\"Run AI agent with prompt\",\"flags\":[{{\"name\":\"--json\",\"description\":\"Output in JSON format (default: true)\"}},{{\"name\":\"--no-json\",\"description\":\"Disable JSON output\"}},{{\"name\":\"--stream\",\"description\":\"Enable streaming output (default: true)\"}},{{\"name\":\"--no-stream\",\"description\":\"Disable streaming output\"}},{{\"name\":\"--help-json\",\"description\":\"Output machine-readable help in JSON\"}}]}}}},\"output_formats\":[\"json\",\"stream\"],\"exit_codes\":{{\"0\":\"success\",\"80\":\"invalid_argument\",\"82\":\"missing_required_field\",\"105\":\"connection_timeout\",\"110\":\"internal_error\"}}}}\n";
    _ = linux.write(1, json.ptr, json.len);
}

fn streamLLMResponse(io: std.Io, gpa: std.mem.Allocator, config: Config) !void {
    if (config.api_key == null) {
        printErrorJson(82, "missing_required_field", "API key required (set OPENAI_API_KEY or use --api-key)", false);
        return error.MissingApiKey;
    }

    const prompt = config.prompt orelse "Hello, please introduce yourself.";

    // Call the real LLM API
    const response = callLLMAPI(io, gpa, config, prompt) catch |err| {
        printErrorJson(110, "api_error", "Failed to call LLM API", false);
        return err;
    };
    defer gpa.free(response);

    // For now, implement simple streaming by chunking the response
    if (config.json_output and config.stream_output) {
        // Split response into chunks for streaming demonstration
        var chunk_start: usize = 0;
        const chunk_size: usize = 20; // Small chunks for demo

        while (chunk_start < response.len) {
            const chunk_end = @min(chunk_start + chunk_size, response.len);
            const chunk = response[chunk_start..chunk_end];
            printJson("0.1.0", chunk, false);
            chunk_start = chunk_end;
        }
        printJson("0.1.0", "", true);
    } else if (config.json_output) {
        const json = std.fmt.allocPrint(std.heap.page_allocator, "{{\"version\":\"0.1.0\",\"content\":\"{s}\",\"model\":\"{s}\",\"done\":true}}\n", .{ response, config.model }) catch return;
        defer std.heap.page_allocator.free(json);
        _ = linux.write(1, json.ptr, json.len);
    } else {
        _ = linux.write(1, response.ptr, response.len);
        _ = linux.write(1, "\n".ptr, 1);
    }

    // Log metadata
    const meta = std.fmt.allocPrint(std.heap.page_allocator, "Model: {s}, Tokens: {any}, Temperature: {d:.2}\n", .{
        config.model,
        config.max_tokens,
        config.temperature,
    }) catch return;
    defer std.heap.page_allocator.free(meta);
    _ = linux.write(1, meta.ptr, meta.len);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    // For demonstration, use a simple hardcoded config with real API credentials
    const config = Config{
        .prompt = "Create a simple HTML landing page for Piz CLI tool",
        .json_output = true,
        .stream_output = true,
    };

    // Demonstrate the help-json functionality
    printHelpJson();

    const separator = "\n--- Real LLM API Response ---\n\n";
    _ = linux.write(1, separator.ptr, separator.len);

    // Demonstrate streaming response with real API
    streamLLMResponse(io, gpa, config) catch {
        printErrorJson(110, "internal_error", "Failed to process LLM response", false);
        std.process.exit(@intFromEnum(ExitCode.internal_error));
    };
}