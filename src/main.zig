const std = @import("std");
const linux = std.os.linux;
const cfgmod = @import("config.zig");
const argsmod = @import("args.zig");
const json = @import("json.zig");
const agent = @import("agent.zig");
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

    // Run the agent (replaces temporary runOnce)
    const exit_code = agent.run(io, gpa, cfg, init.environ_map) catch |err| {
        const code: ExitCode = switch (err) {
            error.Timeout => .connection_timeout,
            else => .internal_error,
        };
        printErrorJson(@intFromEnum(code), @errorName(err), "request failed", false);
        std.process.exit(@intFromEnum(code));
    };
    std.process.exit(exit_code);
}

test {
    std.testing.refAllDecls(@This());
    _ = json;
}
