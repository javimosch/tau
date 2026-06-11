const std = @import("std");
const term = @import("term.zig");
const cfgmod = @import("config.zig");
const argsmod = @import("args.zig");
const json = @import("json.zig");
const agent = @import("agent.zig");
const Config = cfgmod.Config;

pub const name = "tau";
pub const version = "0.3.0";

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
    term.out(s);
}
fn writeErr(s: []const u8) void {
    term.err(s);
}

fn printErrorJson(code: u8, error_type: []const u8, message: []const u8, recoverable: bool) void {
    const j = std.fmt.allocPrint(std.heap.page_allocator, "{{\"err\":{{\"code\":{d},\"type\":\"{s}\",\"message\":\"{s}\",\"recoverable\":{}}}}}\n", .{ code, error_type, message, recoverable }) catch return;
    defer std.heap.page_allocator.free(j);
    writeErr(j);
}

const help_text =
    \\tau - agent-first AI CLI (non-interactive Zig implementation of pi)
    \\
    \\Usage:
    \\  tau [options] [@files...] [prompt...]
    \\
    \\Options:
    \\  -p, --print                  Non-interactive: process prompt and exit (default)
    \\      --provider <name>        Provider: xiaomi (default), openai, deepseek
    \\      --model <pattern>        Model id, or provider/id (e.g. openai/gpt-4o-mini)
    \\      --api-key <key>          API key (else provider env var, else builtin)
    \\      --system-prompt <text>   Set the system prompt
    \\      --append-system-prompt <text>  Append to the system prompt (repeatable)
    \\      --mode <text|json>       Output mode (default: json)
    \\      --no-stream              Disable streaming (streaming is default)
    \\  -t, --tools <csv>            Allowlist of tool names
    \\  -xt, --exclude-tools <csv>   Denylist of tool names
    \\  -nt, --no-tools              Disable all tools
    \\      --thinking               Enable thinking chunks (show model reasoning)
    \\      --debug                  Show perf stats and tool calls (input+output)
    \\      --dry-run                Report the tools that would be called; execute none
    \\      --temperature <f>        Sampling temperature (default: 0.7)
    \\      --max-tokens <n>         Max output tokens
    \\      --timeout-ms <n>         Request timeout in ms (default: 120000)
    \\      --session <name>         Persist conversation + goal to ~/.config/tau/sessions/<name>.json
    \\      --context-window <n>     Model context window in tokens (default: per-provider)
    \\      --compact-threshold <f>  Auto-compact above this fraction of the window (default: 0.5)
    \\      --compact-keep-recent <n>  Tokens of recent history kept verbatim (default: 20000)
    \\      --no-compact             Disable automatic context compaction
    \\      --role <author|critic|coordinator|none>
    \\                          Set the agent role (default: none)
    \\      --max-iterations <n>     Tool-loop runaway backstop (default: 100; forces a final answer)
    \\      --goal-max-iterations <n>  Per-run loop cap in goal mode (default: 50)
    \\      --help-json              Machine-readable help as JSON
    \\  -h, --help                   Show this help
    \\  -v, --version                Show version
    \\
    \\Goal mode (in the prompt):
    \\  /goal <objective>            Work autonomously until the objective is audited-complete
    \\  /goal [--tokens N] <obj>     ...with a soft output-token budget (e.g. 250K)
    \\  /goal status|pause|resume|clear|complete   Manage the session's goal (needs --session)
    \\
    \\ACP (Agent Client Protocol) server:
    \\  tau acp serve [--acp-socket P] Run the JSON-RPC agent server (stdio, or a Unix socket)
    \\  tau acp start                 Start the ACP server as a background daemon
    \\  tau acp stop                  Stop the background ACP daemon
    \\  tau acp status                Report ACP daemon status (JSON)
    \\
    \\Author<->Critic loop:
    \\  --role <author|critic|coordinator|none>  Set the agent role (default: none)
    \\
    \\Fleet orchestration:
    \\  tau fleet run --goal <text>   Decompose goal into work items and dispatch workers
    \\      --coordinator-model <model> Override coordinator LLM model
    \\      --worker-model <model>      Override worker LLM model
    \\      --sequential                Run workers sequentially (default: parallel)
    \\      --items <json>              Pre-supplied items JSON (skip coordinator)
    \\  tau fleet status <id>         Show fleet manifest (spec + per-item status)
    \\  tau fleet list                List active fleet ids
    \\  tau fleet logs <id>           Show per-worker session hint
    \\  tau fleet cancel <id>         Cancel a running fleet
    \\
    \\Examples:
    \\  tau "List the files in src/"
    \\  tau --model openai/gpt-4o-mini "Explain this error" @log.txt
    \\  tau --session work1 "Remember: the build uses zig 0.16"
    \\  tau --session work1 "/goal add a --version flag and verify it builds"
    \\  tau --session work1 "/goal status"
    \\  tau --role author --tools bash,write "add version flag"
    \\  tau fleet run --goal "add OAuth and write tests"
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

// Single source of truth for all CLI flags. printHelpJson and the test both
// derive from this table; help_text Options section must be kept in sync.
const FlagSpec = struct { long: []const u8, short: ?[]const u8 = null, arg: ?[]const u8 = null };
const flag_specs = [_]FlagSpec{
    .{ .long = "--print",                .short = "-p"           },
    .{ .long = "--provider",             .arg = "name"           },
    .{ .long = "--model",                .arg = "pattern"        },
    .{ .long = "--api-key",              .arg = "key"            },
    .{ .long = "--system-prompt",        .arg = "text"           },
    .{ .long = "--append-system-prompt", .arg = "text"           },
    .{ .long = "--mode",                 .arg = "text|json"      },
    .{ .long = "--no-stream"                                     },
    .{ .long = "--tools",                .short = "-t",  .arg = "csv" },
    .{ .long = "--exclude-tools",        .short = "-xt", .arg = "csv" },
    .{ .long = "--no-tools",             .short = "-nt"          },
    .{ .long = "--thinking"                                      },
    .{ .long = "--debug"                                         },
    .{ .long = "--dry-run"                                       },
    .{ .long = "--temperature",          .arg = "f"              },
    .{ .long = "--max-tokens",           .arg = "n"              },
    .{ .long = "--timeout-ms",           .arg = "n"              },
    .{ .long = "--session",              .arg = "name"           },
    .{ .long = "--context-window",       .arg = "n"              },
    .{ .long = "--compact-threshold",    .arg = "f"              },
    .{ .long = "--compact-keep-recent",  .arg = "n"              },
    .{ .long = "--no-compact"                                    },
    .{ .long = "--role",                 .arg = "author|critic|coordinator|none" },
    .{ .long = "--max-iterations",       .arg = "n"              },
    .{ .long = "--goal-max-iterations",  .arg = "n"              },
    .{ .long = "--help-json"                                     },
    .{ .long = "--help",                 .short = "-h"           },
    .{ .long = "--version",              .short = "-v"           },
};

fn printHelpJson() void {
    const alloc = std.heap.page_allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    buf.appendSlice(alloc, "{\"version\":\"") catch return;
    buf.appendSlice(alloc, version) catch return;
    buf.appendSlice(alloc, "\",\"name\":\"") catch return;
    buf.appendSlice(alloc, name) catch return;
    buf.appendSlice(alloc, "\",\"description\":\"Agent-first AI CLI - non-interactive Zig implementation of pi\",\"flags\":[") catch return;

    for (flag_specs, 0..) |f, i| {
        if (i != 0) buf.append(alloc, ',') catch return;
        buf.appendSlice(alloc, "{\"name\":\"") catch return;
        buf.appendSlice(alloc, f.long) catch return;
        buf.append(alloc, '"') catch return;
        if (f.arg) |a| {
            buf.appendSlice(alloc, ",\"arg\":\"") catch return;
            buf.appendSlice(alloc, a) catch return;
            buf.append(alloc, '"') catch return;
        }
        buf.append(alloc, '}') catch return;
    }

    buf.appendSlice(alloc,
        "],\"goal_commands\":[\"/goal <objective>\",\"/goal status\",\"/goal pause\",\"/goal resume\",\"/goal clear\",\"/goal complete\"]" ++
        ",\"output_modes\":[\"json\"]" ++
        ",\"defaults\":{\"mode\":\"json\",\"stream\":true,\"auto_compact\":true}" ++
        ",\"exit_codes\":{\"0\":\"success\",\"80\":\"invalid_argument\",\"82\":\"missing_required_field\",\"105\":\"connection_timeout\",\"106\":\"auth_failed\",\"110\":\"internal_error\",\"111\":\"unimplemented\"}}\n"
    ) catch return;

    writeOut(buf.items);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    term.init(io); // portable stdout/stderr (replaces Linux-only write syscalls)

    // Config-file defaults (~/.config/tau/config.json); CLI flags override these.
    const base_cfg: Config = @import("configfile.zig").load(io, arena, init.environ_map);

    const parsed = argsmod.parse(io, arena, init.minimal.args, init.environ_map, base_cfg) catch {
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
        .acp => {
            const acp = @import("acp.zig");
            const code = acp.run(io, gpa, arena, parsed.config, init.environ_map, parsed.config.acp_sub, parsed.config.acp_socket) catch |err| {
                printErrorJson(@intFromEnum(ExitCode.internal_error), @errorName(err), "acp failed", false);
                std.process.exit(@intFromEnum(ExitCode.internal_error));
            };
            std.process.exit(code);
        },
        .fleet => {
            const fleet = @import("fleet.zig");
            const sub_str = parsed.config.fleet_sub orelse "run";
            const sub = std.meta.stringToEnum(fleet.FleetSub, sub_str) orelse {
                printErrorJson(@intFromEnum(ExitCode.invalid_argument), "invalid_argument", "unknown fleet subcommand", false);
                std.process.exit(@intFromEnum(ExitCode.invalid_argument));
            };
            // Resolve API key for fleet run (coordinator LLM call needs it).
            // Other fleet subcommands (status/list/cancel/logs) are read-only
            // and don't need auth, so only check for .run.
            var fleet_cfg = parsed.config;
            if (sub == .run) {
                if (cfgmod.resolveApiKey(fleet_cfg, init.environ_map)) |key| {
                    fleet_cfg.api_key = key;
                } else {
                    printErrorJson(@intFromEnum(ExitCode.auth_failed), "AuthFailed", "invalid or missing API key", false);
                    std.process.exit(@intFromEnum(ExitCode.auth_failed));
                }
            }
            const code = fleet.dispatch(io, gpa, arena, fleet_cfg, init.environ_map, sub, fleet_cfg.fleet_id, fleet_cfg.fleet_goal) catch |err| {
                printErrorJson(@intFromEnum(ExitCode.internal_error), @errorName(err), "fleet failed", false);
                std.process.exit(@intFromEnum(ExitCode.internal_error));
            };
            std.process.exit(code);
        },
        .run => {},
    }

    const cfg = parsed.config;

    // Run the agent (replaces temporary runOnce)
    const result = agent.run(io, gpa, arena, cfg, init.environ_map) catch |err| {
        const code: ExitCode = switch (err) {
            error.Timeout => .connection_timeout,
            error.AuthFailed => .auth_failed,
            else => .internal_error,
        };
        const detail = if (err == error.AuthFailed) "invalid or missing API key" else "request failed";
        printErrorJson(@intFromEnum(code), @errorName(err), detail, false);
        std.process.exit(@intFromEnum(code));
    };
    std.process.exit(result.exit_code);
}

test {
    std.testing.refAllDecls(@This());
    _ = json;
    _ = @import("goal.zig");
    _ = @import("context.zig");
    _ = @import("session.zig");
}

test "flag_specs appear in help_text" {
    for (flag_specs) |f| {
        const found = std.mem.indexOf(u8, help_text, f.long) != null;
        if (!found) std.debug.print("flag_specs entry '{s}' not found in help_text\n", .{f.long});
        try std.testing.expect(found);
    }
}
