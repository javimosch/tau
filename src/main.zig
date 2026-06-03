const std = @import("std");
const linux = std.os.linux;
const cfgmod = @import("config.zig");
const argsmod = @import("args.zig");
const json = @import("json.zig");
const Config = cfgmod.Config;

pub const name = "pizig";
pub const version = "0.2.0";

// Semantic exit codes (Square-style).
const ExitCode = enum(u8) {
    success = 0,
    generic_failure = 1,
    invalid_argument = 80,
    missing_required_field = 82,
    connection_timeout = 105,
    auth_failed = 106,
    internal_error = 110,
    unimplemented = 111,
};

fn writeOut(s: []const u8) void {
    _ = linux.write(1, s.ptr, s.len);
}
fn writeErr(s: []const u8) void {
    _ = linux.write(2, s.ptr, s.len);
}

fn printErrorJson(code: u8, error_type: []const u8, message: []const u8, recoverable: bool) void {
    const j = std.fmt.allocPrint(std.heap.page_allocator, "{{\"err\":{{\"code\":{d},\"type\":\"{s}\",\"message\":\"{s}\",\"recoverable\":{}}}}}\n", .{ code, error_type, message, recoverable }) catch return;
    defer std.heap.page_allocator.free(j);
    writeErr(j);
}

const help_text =
    \\pizig - agent-first AI CLI (non-interactive Zig implementation of pi)
    \\
    \\Usage:
    \\  pizig [options] [@files...] [prompt...]
    \\
    \\Options:
    \\  -p, --print                  Non-interactive: process prompt and exit (default)
    \\      --provider <name>        Provider: xiaomi (default), openai, deepseek
    \\      --model <pattern>        Model id, or provider/id (e.g. openai/gpt-4o-mini)
    \\      --api-key <key>          API key (else provider env var, else builtin)
    \\      --system-prompt <text>   Set the system prompt
    \\      --append-system-prompt <text>  Append to the system prompt (repeatable)
    \\      --mode <text|json>       Output mode (default: text)
    \\  -t, --tools <csv>            Allowlist of tool names
    \\  -xt, --exclude-tools <csv>   Denylist of tool names
    \\  -nt, --no-tools              Disable all tools
    \\      --thinking <level>       Thinking level: off|minimal|low|medium|high|xhigh
    \\      --temperature <f>        Sampling temperature (default: 0.7)
    \\      --max-tokens <n>         Max output tokens
    \\      --timeout-ms <n>         Request timeout in ms (default: 120000)
    \\      --help-json              Machine-readable help as JSON
    \\  -h, --help                   Show this help
    \\  -v, --version                Show version
    \\
    \\Examples:
    \\  pizig -p "List the files in src/"
    \\  pizig --model openai/gpt-4o-mini "Explain this error" @log.txt
    \\  pizig --mode json --system-prompt "Be terse" "What is Zig?"
    \\
;

fn printHelp() void {
    writeOut(help_text);
}

fn printVersion() void {
    const v = std.fmt.allocPrint(std.heap.page_allocator, "{s} {s}\n", .{ name, version }) catch return;
    defer std.heap.page_allocator.free(v);
    writeOut(v);
}

// Valid machine-readable help JSON (note: a real JSON object, not the old
// double-brace string that produced malformed output).
fn printHelpJson() void {
    const j = std.fmt.allocPrint(std.heap.page_allocator,
        \\{{"version":"{s}","name":"{s}","description":"Agent-first AI CLI - non-interactive Zig implementation of pi","flags":[{{"name":"--provider","arg":"name"}},{{"name":"--model","arg":"pattern"}},{{"name":"--api-key","arg":"key"}},{{"name":"--system-prompt","arg":"text"}},{{"name":"--append-system-prompt","arg":"text"}},{{"name":"--mode","arg":"text|json"}},{{"name":"--tools","arg":"csv"}},{{"name":"--exclude-tools","arg":"csv"}},{{"name":"--no-tools"}},{{"name":"--thinking","arg":"level"}},{{"name":"--print"}},{{"name":"--help"}},{{"name":"--version"}}],"output_modes":["text","json"],"exit_codes":{{"0":"success","80":"invalid_argument","82":"missing_required_field","105":"connection_timeout","106":"auth_failed","110":"internal_error","111":"unimplemented"}}}}
    , .{ version, name }) catch return;
    defer std.heap.page_allocator.free(j);
    writeOut(j);
    writeOut("\n");
}

// === TEMPORARY single-shot runner ===========================================
// This is a stopgap so `pizig` works end-to-end (M1). The main agent's
// `agent.zig` (tool-calling loop) + `llm/provider.zig` (provider abstraction,
// tool schemas, Anthropic support) will replace `runOnce`. Interface target:
//   pub fn run(io, gpa, cfg) !u8;
// Keep the request/parse logic here minimal and OpenAI-chat-completions shaped.
fn runOnce(io: std.Io, gpa: std.mem.Allocator, cfg: Config, api_key: []const u8, prompt: []const u8) !void {
    // Build the request body with proper JSON escaping.
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    try body.appendSlice(gpa, "{\"model\":\"");
    try json.escapeInto(gpa, &body, cfg.model);
    try body.appendSlice(gpa, "\",\"messages\":[");
    if (cfg.system_prompt) |sp| {
        try body.appendSlice(gpa, "{\"role\":\"system\",\"content\":\"");
        try json.escapeInto(gpa, &body, sp);
        try body.appendSlice(gpa, "\"},");
    }
    try body.appendSlice(gpa, "{\"role\":\"user\",\"content\":\"");
    try json.escapeInto(gpa, &body, prompt);
    try body.appendSlice(gpa, "\"}],\"stream\":false}");

    const auth = try std.fmt.allocPrint(gpa, "Authorization: Bearer {s}", .{api_key});
    defer gpa.free(auth);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ "curl", "-s", "-X", "POST", cfg.endpoint, "-H", auth, "-H", "Content-Type: application/json", "--data-raw", body.items });
    const argv_slice = try argv.toOwnedSlice(gpa);
    defer gpa.free(argv_slice);

    const timeout = std.Io.Timeout{ .duration = .{
        .raw = std.Io.Duration.fromMilliseconds(cfg.timeout_ms),
        .clock = .awake,
    } };

    const result = std.process.run(gpa, io, .{
        .argv = argv_slice,
        .stdout_limit = .unlimited,
        .stderr_limit = .unlimited,
        .timeout = timeout,
    }) catch |err| {
        if (err == error.Timeout) return error.Timeout;
        return error.HTTPRequestFailed;
    };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    const exit_code: u8 = switch (result.term) {
        .exited => |c| c,
        else => 1,
    };
    if (exit_code != 0) return error.HTTPRequestFailed;

    const content = (try json.extractString(gpa, result.stdout, "content")) orelse
        return error.InvalidResponse;
    defer gpa.free(content);

    switch (cfg.mode) {
        .text => {
            writeOut(content);
            writeOut("\n");
        },
        .json => {
            const esc = try json.escapeAlloc(gpa, content);
            defer gpa.free(esc);
            const out = try std.fmt.allocPrint(gpa, "{{\"version\":\"{s}\",\"model\":\"{s}\",\"content\":\"{s}\",\"done\":true}}\n", .{ version, cfg.model, esc });
            defer gpa.free(out);
            writeOut(out);
        },
    }
}
// === end temporary runner ===================================================

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    const parsed = argsmod.parse(io, arena, init.minimal.args, init.environ_map) catch {
        printErrorJson(@intFromEnum(ExitCode.internal_error), "internal_error", "argument parsing failed", false);
        std.process.exit(@intFromEnum(ExitCode.internal_error));
    };

    switch (parsed.action) {
        .help => {
            printHelp();
            return;
        },
        .version => {
            printVersion();
            return;
        },
        .help_json => {
            printHelpJson();
            return;
        },
        .err => {
            const msg = parsed.err_msg orelse "invalid arguments";
            printErrorJson(@intFromEnum(ExitCode.invalid_argument), "invalid_argument", msg, false);
            std.process.exit(@intFromEnum(ExitCode.invalid_argument));
        },
        .run => {},
    }

    const cfg = parsed.config;

    const prompt = cfg.prompt orelse {
        printErrorJson(@intFromEnum(ExitCode.missing_required_field), "missing_required_field", "no prompt provided (pass a prompt or @file; see --help)", false);
        std.process.exit(@intFromEnum(ExitCode.missing_required_field));
    };

    const api_key = cfgmod.resolveApiKey(cfg, init.environ_map) orelse {
        printErrorJson(@intFromEnum(ExitCode.auth_failed), "auth_failed", "no API key (use --api-key or set the provider env var)", false);
        std.process.exit(@intFromEnum(ExitCode.auth_failed));
    };

    runOnce(io, gpa, cfg, api_key, prompt) catch |err| {
        const code: ExitCode = switch (err) {
            error.Timeout => .connection_timeout,
            else => .internal_error,
        };
        printErrorJson(@intFromEnum(code), @errorName(err), "request failed", false);
        std.process.exit(@intFromEnum(code));
    };
}

test {
    std.testing.refAllDecls(@This());
    _ = json;
}
