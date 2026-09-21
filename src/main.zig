const std = @import("std");
const term = @import("term.zig");
const cfgmod = @import("config.zig");
const argsmod = @import("args.zig");
const json = @import("json.zig");
const agent = @import("agent.zig");
const Config = cfgmod.Config;

pub const name = "tau";
pub const version = @import("version.zig").version;

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

fn formatErrorJson(gpa: std.mem.Allocator, code: u8, error_type: []const u8, message: []const u8, recoverable: bool) ![]u8 {
    const te = try json.escapeAlloc(gpa, error_type);
    defer gpa.free(te);
    const me = try json.escapeAlloc(gpa, message);
    defer gpa.free(me);
    return try std.fmt.allocPrint(gpa, "{{\"err\":{{\"code\":{d},\"type\":\"{s}\",\"message\":\"{s}\",\"recoverable\":{}}}}}\n", .{ code, te, me, recoverable });
}

fn printErrorJson(code: u8, error_type: []const u8, message: []const u8, recoverable: bool) void {
    const j = formatErrorJson(std.heap.page_allocator, code, error_type, message, recoverable) catch return;
    defer std.heap.page_allocator.free(j);
    writeErr(j);
}

fn formatWarnJson(gpa: std.mem.Allocator, message: []const u8) ![]u8 {
    const me = try json.escapeAlloc(gpa, message);
    defer gpa.free(me);
    return try std.fmt.allocPrint(gpa, "{{\"warn\":{{\"message\":\"{s}\"}}}}\n", .{me});
}

fn printWarnJson(message: []const u8) void {
    const j = formatWarnJson(std.heap.page_allocator, message) catch return;
    defer std.heap.page_allocator.free(j);
    writeErr(j);
}

/// Serialize a `tau skills load` response with escaped name and content.
fn formatSkillLoadJson(gpa: std.mem.Allocator, skill_name: []const u8, content: []const u8) ![]u8 {
    const ne = try json.escapeAlloc(gpa, skill_name);
    defer gpa.free(ne);
    const ce = try json.escapeAlloc(gpa, content);
    defer gpa.free(ce);
    return try std.fmt.allocPrint(gpa, "{{\"skill\":\"{s}\",\"content\":\"{s}\"}}\n", .{ ne, ce });
}

/// Build a recovery hint for a missing API key: names the env var(s) to set.
fn authHint(arena: std.mem.Allocator, provider: []const u8) []const u8 {
    const p = cfgmod.findProvider(provider) orelse return "use --api-key <key>";
    if (p.env_keys.len == 0) return "use --api-key <key>";
    var buf: std.ArrayList(u8) = .empty;
    for (p.env_keys, 0..) |ek, i| {
        if (i != 0) buf.appendSlice(arena, " or ") catch return "use --api-key <key>";
        buf.appendSlice(arena, ek) catch return "use --api-key <key>";
    }
    return std.fmt.allocPrint(arena, "set {s} env var, or use --api-key <key>", .{buf.items}) catch "use --api-key <key>";
}

const help_text =
    \\tau - agent-first AI CLI (non-interactive Zig implementation of pi)
    \\
    \\Usage:
    \\  tau [options] [@files...] [prompt...]
    \\
    \\Options:
    \\  -p, --print                  Non-interactive: process prompt and exit (default)
    \\      --provider <name>        Provider: xiaomi (default), openai, deepseek, opencode-go
    \\      --model <pattern>        Model id, or provider/id (e.g. openai/gpt-4o-mini)
    \\      --api-key <key>          API key (else provider env var, else builtin)
    \\      --system-prompt <text>   Set the system prompt
    \\      --append-system-prompt <text>  Append to the system prompt (repeatable)
    \\      --mode <text|json>       Output mode (default: json)
    \\      --no-stream              Disable streaming (streaming is default)
    \\      --stream                 Enable streaming (overrides a no-stream config default)
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
    \\      --schema <json|@file>    JSON Schema for structured output. Model must
    \\                          produce valid JSON matching this schema.
    \\                          Inline: --schema '{\"type\":\"object\",...}'
    \\                          File:   --schema @path/to/schema.json
    \\      --max-iterations <n>     Tool-loop runaway backstop (default: 100; forces a final answer)
    \\      --scan-agents            Scan CWD for AGENTS.md files and list them
    \\      --load-agents-md <path>  Load an AGENTS.md file into system context
    \\      --auto-agents-md         Auto-load cwd/AGENTS.md on startup
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
    \\      --schema <json|@file>        JSON Schema for the coordinator response
    \\  tau fleet status <id>         Show fleet manifest (spec + per-item status)
    \\  tau fleet list                List active fleet ids
    \\  tau fleet logs <id>           Show per-worker session hint
    \\  tau fleet cancel <id>         Cancel a running fleet
    \\
    \\Skills (autodiscover ~/.agents/skills/):
    \\  tau skills list               List all discoverable skills
    \\  tau skills search <query>     Search skills by keyword
    \\  tau skills load <name>        Load a skill into system context
    \\
    \\
    \\
    \\Models:
    \\  tau models                    List available providers and models
    \\
    \\Guide (embedded operator manual — read once, drive with no external docs):
    \\  tau guide                     Print the full guide as JSON (agent-readable)
    \\  tau guide --human             ...as markdown
    \\\Examples:
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
    .{ .long = "--stream"                                        },
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
    .{ .long = "--schema",              .arg = "json|@file"     },
    .{ .long = "--scan-agents"                                     },
    .{ .long = "--load-agents-md",       .arg = "path"           },
    .{ .long = "--auto-agents-md"                                  },
    .{ .long = "--max-iterations",       .arg = "n"              },
    .{ .long = "--goal-max-iterations",  .arg = "n"              },
    .{ .long = "--help-json"                                     },
    .{ .long = "--help",                 .short = "-h"           },
    .{ .long = "--version",              .short = "-v"           },
};

fn formatHelpJson(alloc: std.mem.Allocator) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);

    try buf.appendSlice(alloc, "{\"version\":\"");
    try buf.appendSlice(alloc, version);
    try buf.appendSlice(alloc, "\",\"name\":\"");
    try buf.appendSlice(alloc, name);
    try buf.appendSlice(alloc, "\",\"description\":\"Agent-first AI CLI - non-interactive Zig implementation of pi\",\"flags\":[");

    for (flag_specs, 0..) |f, i| {
        if (i != 0) try buf.append(alloc, ',');
        try buf.appendSlice(alloc, "{\"name\":\"");
        try buf.appendSlice(alloc, f.long);
        try buf.append(alloc, '"');
        if (f.arg) |a| {
            try buf.appendSlice(alloc, ",\"arg\":\"");
            try buf.appendSlice(alloc, a);
            try buf.append(alloc, '"');
        }
        try buf.append(alloc, '}');
    }

    try buf.appendSlice(alloc,
        "],\"goal_commands\":[\"/goal <objective>\",\"/goal status\",\"/goal pause\",\"/goal resume\",\"/goal clear\",\"/goal complete\"]" ++
        ",\"output_modes\":[\"text\",\"json\"]" ++
        ",\"defaults\":{\"mode\":\"json\",\"stream\":true,\"auto_compact\":true}" ++
        ",\"exit_codes\":{\"0\":\"success\",\"80\":\"invalid_argument\",\"82\":\"missing_required_field\",\"105\":\"connection_timeout\",\"106\":\"auth_failed\",\"110\":\"internal_error\",\"111\":\"unimplemented\"}}\n"
    );

    return buf.toOwnedSlice(alloc);
}

fn printHelpJson() void {
    const alloc = std.heap.page_allocator;
    const s = formatHelpJson(alloc) catch return;
    defer alloc.free(s);
    writeOut(s);
}

// ---- guide (cli-guide-spec: embedded operator manual, no runtime fetch) -----
// Single source of truth: the consts below render to JSON (default) or markdown (--human).
const GuideItem = struct { a: []const u8, b: []const u8 };
const guide_one_liner = "tau — a non-interactive, agent-first AI CLI (Zig): single-shot chat with tool-calling, sessions, goal mode, fleet orchestration, and an ACP server. JSON output by default; semantic exit codes.";
const guide_model = "You (an agent) invoke tau once per task; it runs a single agentic turn (LLM + tools) and exits — no REPL, never blocks on stdin. Output is JSON by default (--mode text for prose; errors are always JSON {err:{code,type,message}}). Provider/model/key resolve from ~/.config/tau/config.json, provider env vars, or TAU_API_KEY; endpoints are OpenAI-compatible /chat/completions (override with TAU_ENDPOINT).";
const guide_loop = "parse args -> resolve provider/model/endpoint/key -> build messages -> LLM turn -> if the model calls tools, run them (allowlisted via --tools) and loop -> stop when the model stops calling tools or hits --max-iterations -> emit result + semantic exit code. --session <name> persists conversation+goal across calls; /goal <directive> runs autonomously until the <GOAL_MET> sentinel.";
const guide_concepts = [_]GuideItem{
    .{ .a = "non-interactive", .b = "one prompt in, one result out; built for scripts and agents, not a REPL." },
    .{ .a = "json-first", .b = "default output is JSON; pass --mode text for human-readable prose." },
    .{ .a = "semantic exit codes", .b = "0 ok, 80 invalid arg, 82 missing field, 105 timeout, 106 auth, 110 internal, 111 unimplemented." },
    .{ .a = "sessions", .b = "--session <name> persists conversation + goal to ~/.config/tau/sessions/<name>.json." },
    .{ .a = "goal mode", .b = "/goal <directive> works autonomously until <GOAL_MET>; /goal status|pause|resume|clear|complete." },
    .{ .a = "tools", .b = "built-in bash/read/write/edit/ls/grep/find/calculator; enable with --tools <csv>, deny with --exclude-tools." },
    .{ .a = "fleet", .b = "tau fleet run --goal ... decomposes work via a coordinator turn and dispatches worker tau processes (topo-ordered)." },
    .{ .a = "acp", .b = "tau acp serve is an Agent Client Protocol server (JSON-RPC over stdio/socket) so hosts drive tau as a coding agent." },
    .{ .a = "providers", .b = "OpenAI-compatible endpoints (xiaomi default, openai, deepseek, opencode-go); TAU_ENDPOINT overrides the endpoint." },
};
const guide_commands = [_]GuideItem{
    .{ .a = "tau \"<prompt>\"", .b = "single-shot chat (JSON); add --tools bash,read for a tool loop." },
    .{ .a = "tau --mode text \"<prompt>\"", .b = "human-readable output." },
    .{ .a = "tau --session <name> \"<prompt>\"", .b = "persistent session." },
    .{ .a = "tau --session <name> \"/goal <directive>\"", .b = "autonomous goal mode." },
    .{ .a = "tau acp serve [--acp-socket <path>]", .b = "ACP server (stdio or socket); acp start|stop|status manage a daemon." },
    .{ .a = "tau fleet <run|status|list|logs|cancel>", .b = "multi-agent orchestration." },
    .{ .a = "tau models", .b = "list providers + default models (JSON)." },
    .{ .a = "tau skills <list|search|load>", .b = "skill discovery from ~/.agents/skills." },
    .{ .a = "tau guide [--human]", .b = "this guide — JSON, or --human for markdown." },
    .{ .a = "tau --help-json", .b = "machine-readable flag catalog." },
};
const guide_examples = [_]GuideItem{
    .{ .a = "tau --tools bash,read \"Count the .zig files under src/\"", .b = "agentic tool loop." },
    .{ .a = "tau --model openai/gpt-4o-mini --mode text \"Explain build.zig\"", .b = "pick a model, prose output." },
    .{ .a = "tau --session proj \"/goal add a --foo flag and verify zig build\"", .b = "autonomous goal in a session." },
    .{ .a = "TAU_ENDPOINT=https://openrouter.ai/api/v1/chat/completions TAU_API_KEY=sk-or-... tau --model deepseek/deepseek-v4-flash \"hi\"", .b = "point at any OpenAI-compatible endpoint (OpenRouter)." },
};
const guide_gotchas = [_][]const u8{
    "JSON is the default; use --mode text for prose. Errors are JSON {err:{code,type,message}} even in text mode.",
    "Provider endpoint is resolved at parse time — config.json's provider does NOT set the endpoint; TAU_ENDPOINT overrides it.",
    "API-key precedence: config api_key > keys[provider] > provider env > global api_key > TAU_API_KEY. A stale config api_key silently outranks TAU_API_KEY.",
    "tau acp serve reads no model env var; the model comes from config.json or --model.",
    "Requires curl on PATH for LLM HTTP; no other runtime deps.",
    "The tool loop ends when the model stops calling tools or hits --max-iterations (default backstop).",
};
const guide_see_also = [_][]const u8{
    "tau --help-json (machine-readable command/flag catalog)",
    "tau --help (human help)",
    "README.md (ships with the source)",
    "https://cli-specs.intrane.fr/ (guide spec)",
};

fn appendJsonStr(alloc: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8) void {
    buf.append(alloc, '"') catch return;
    json.escapeInto(alloc, buf, s) catch return;
    buf.append(alloc, '"') catch return;
}

fn printGuideJson() void {
    const A = std.heap.page_allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(A);
    buf.appendSlice(A, "{\"one_liner\":") catch return;
    appendJsonStr(A, &buf, guide_one_liner);
    buf.appendSlice(A, ",\"model\":") catch return;
    appendJsonStr(A, &buf, guide_model);
    buf.appendSlice(A, ",\"loop\":") catch return;
    appendJsonStr(A, &buf, guide_loop);
    buf.appendSlice(A, ",\"concepts\":[") catch return;
    for (guide_concepts, 0..) |c, i| {
        if (i != 0) buf.append(A, ',') catch return;
        buf.appendSlice(A, "{\"term\":") catch return;
        appendJsonStr(A, &buf, c.a);
        buf.appendSlice(A, ",\"desc\":") catch return;
        appendJsonStr(A, &buf, c.b);
        buf.append(A, '}') catch return;
    }
    buf.appendSlice(A, "],\"commands\":[") catch return;
    for (guide_commands, 0..) |c, i| {
        if (i != 0) buf.append(A, ',') catch return;
        buf.appendSlice(A, "{\"cmd\":") catch return;
        appendJsonStr(A, &buf, c.a);
        buf.appendSlice(A, ",\"desc\":") catch return;
        appendJsonStr(A, &buf, c.b);
        buf.append(A, '}') catch return;
    }
    buf.appendSlice(A, "],\"examples\":[") catch return;
    for (guide_examples, 0..) |c, i| {
        if (i != 0) buf.append(A, ',') catch return;
        buf.appendSlice(A, "{\"cmd\":") catch return;
        appendJsonStr(A, &buf, c.a);
        buf.appendSlice(A, ",\"desc\":") catch return;
        appendJsonStr(A, &buf, c.b);
        buf.append(A, '}') catch return;
    }
    buf.appendSlice(A, "],\"gotchas\":[") catch return;
    for (guide_gotchas, 0..) |g, i| {
        if (i != 0) buf.append(A, ',') catch return;
        appendJsonStr(A, &buf, g);
    }
    buf.appendSlice(A, "],\"see_also\":[") catch return;
    for (guide_see_also, 0..) |g, i| {
        if (i != 0) buf.append(A, ',') catch return;
        appendJsonStr(A, &buf, g);
    }
    buf.appendSlice(A, "],\"version\":") catch return;
    appendJsonStr(A, &buf, version);
    buf.appendSlice(A, "}\n") catch return;
    writeOut(buf.items);
}

fn printGuideHuman() void {
    const A = std.heap.page_allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(A);
    buf.appendSlice(A, "# tau — guide\n\n") catch return;
    buf.appendSlice(A, guide_one_liner) catch return;
    buf.appendSlice(A, "\n\n## Model\n") catch return;
    buf.appendSlice(A, guide_model) catch return;
    buf.appendSlice(A, "\n\n## Loop\n") catch return;
    buf.appendSlice(A, guide_loop) catch return;
    buf.appendSlice(A, "\n\n## Concepts\n") catch return;
    for (guide_concepts) |c| {
        const line = std.fmt.allocPrint(A, "- **{s}** — {s}\n", .{ c.a, c.b }) catch continue;
        defer A.free(line);
        buf.appendSlice(A, line) catch return;
    }
    buf.appendSlice(A, "\n## Commands\n") catch return;
    for (guide_commands) |c| {
        const line = std.fmt.allocPrint(A, "- `{s}` — {s}\n", .{ c.a, c.b }) catch continue;
        defer A.free(line);
        buf.appendSlice(A, line) catch return;
    }
    buf.appendSlice(A, "\n## Examples\n") catch return;
    for (guide_examples) |c| {
        const line = std.fmt.allocPrint(A, "- `{s}` — {s}\n", .{ c.a, c.b }) catch continue;
        defer A.free(line);
        buf.appendSlice(A, line) catch return;
    }
    buf.appendSlice(A, "\n## Gotchas\n") catch return;
    for (guide_gotchas) |g| {
        const line = std.fmt.allocPrint(A, "- {s}\n", .{g}) catch continue;
        defer A.free(line);
        buf.appendSlice(A, line) catch return;
    }
    buf.appendSlice(A, "\n## See also\n") catch return;
    for (guide_see_also) |g| {
        const line = std.fmt.allocPrint(A, "- {s}\n", .{g}) catch continue;
        defer A.free(line);
        buf.appendSlice(A, line) catch return;
    }
    const ver = std.fmt.allocPrint(A, "\n_tau {s}_\n", .{version}) catch return;
    defer A.free(ver);
    buf.appendSlice(A, ver) catch return;
    writeOut(buf.items);
}

fn printGuide(human: bool) void {
    if (human) printGuideHuman() else printGuideJson();
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    term.init(io); // portable stdout/stderr (replaces Linux-only write syscalls)

    // Config-file defaults (~/.config/tau/config.json); CLI flags override these.
    const base_cfg: Config = @import("configfile.zig").load(io, arena, init.environ_map);
    // Warn if the config file exists but has invalid JSON (load degrades silently).
    if (base_cfg.config_warning) |w| printWarnJson(w);

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
        .guide => {
            printGuide(parsed.config.guide_human);
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
                .models => {
            const provs = cfgmod.providers;
            term.out("{\"providers\":[");
            for (provs, 0..) |p, i| {
                if (i > 0) term.out(",");
                const entry = cfgmod.formatProviderJson(arena, p) catch continue;
                term.out(entry);
            }
            term.out("]}\n");
            return;
        },
        .skills => {
            const skills = @import("skills.zig");

            if (std.mem.eql(u8, parsed.config.skills_sub orelse "", "list")) {
                const entries = skills.scanSkills(io, arena, init.environ_map, gpa) catch |err| {
                    printErrorJson(@intFromEnum(ExitCode.internal_error), @errorName(err), "skills scan failed", false);
                    std.process.exit(@intFromEnum(ExitCode.internal_error));
                };
                term.out("{\"skills\":[");
                for (entries, 0..) |e, i| {
                    if (i > 0) term.out(",");
                    const entry = skills.formatEntryJson(arena, e.name, e.description) catch continue;
                    term.out(entry);
                }
                term.out("]}\n");
                return;
            }
            if (std.mem.eql(u8, parsed.config.skills_sub orelse "", "search")) {
                const q = parsed.config.skills_arg orelse "";
                const entries = skills.searchSkills(io, arena, init.environ_map, gpa, q) catch |err| {
                    printErrorJson(@intFromEnum(ExitCode.internal_error), @errorName(err), "skills search failed", false);
                    std.process.exit(@intFromEnum(ExitCode.internal_error));
                };
                term.out("{\"skills\":[");
                for (entries, 0..) |e, i| {
                    if (i > 0) term.out(",");
                    const entry = skills.formatEntryJson(arena, e.name, e.description) catch continue;
                    term.out(entry);
                }
                term.out("]}\n");
                return;
            }
            if (std.mem.eql(u8, parsed.config.skills_sub orelse "", "load")) {
                const skill_name = parsed.config.skills_arg orelse {
                    printErrorJson(@intFromEnum(ExitCode.missing_required_field), "missing_required_field", "skill name required", false);
                    std.process.exit(@intFromEnum(ExitCode.missing_required_field));
                };
                const content = (skills.loadSkill(io, arena, init.environ_map, gpa, skill_name) catch null) orelse {
                    const msg = try std.fmt.allocPrint(arena, "skill not found: {s}", .{skill_name});
                    printErrorJson(@intFromEnum(ExitCode.generic_failure), "not_found", msg, false);
                    std.process.exit(@intFromEnum(ExitCode.generic_failure));
                };
                const out = formatSkillLoadJson(gpa, skill_name, content) catch |err| {
                    printErrorJson(@intFromEnum(ExitCode.internal_error), @errorName(err), "failed to serialize skill", false);
                    std.process.exit(@intFromEnum(ExitCode.internal_error));
                };
                defer gpa.free(out);
                term.out(out);
                return;
            }
            printErrorJson(@intFromEnum(ExitCode.invalid_argument), "invalid_argument", "invalid skills subcommand", false);
            std.process.exit(@intFromEnum(ExitCode.invalid_argument));
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
                    const hint = authHint(arena, fleet_cfg.provider);
                    const msg = std.fmt.allocPrint(arena,
                        "no API key for provider '{s}' — {s}", .{ fleet_cfg.provider, hint }) catch "missing API key";
                    printErrorJson(@intFromEnum(ExitCode.auth_failed), "AuthFailed", msg, false);
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

    var cfg = parsed.config;

    // Handle --scan-agents: list AGENTS.md files and exit
    if (cfg.scan_agents) {
        const agents_md = @import("agents_md.zig");
        const entries = agents_md.scanAgentsMd(io, gpa, arena, ".") catch |err| {
            printErrorJson(@intFromEnum(ExitCode.internal_error), @errorName(err), "agents scan failed", false);
            std.process.exit(@intFromEnum(ExitCode.internal_error));
        };
        term.out("{\"agents_md_files\":[");
        for (entries, 0..) |e, i| {
            if (i > 0) term.out(",");
            const entry = agents_md.formatEntryJson(arena, e.path, e.first_line, e.size) catch continue;
            term.out(entry);
        }
        term.out("]}\n");
        return;
    }

    // Handle --load-agents-md: inject AGENTS.md content into system prompt
    if (cfg.load_agents_md) |path| {
        const agents_md = @import("agents_md.zig");
        const content = agents_md.loadAgentsMd(io, arena, path) orelse {
            const msg = try std.fmt.allocPrint(arena, "AGENTS.md not found: {s}", .{path});
            printErrorJson(@intFromEnum(ExitCode.generic_failure), "not_found", msg, false);
            std.process.exit(@intFromEnum(ExitCode.generic_failure));
        };
        // Prepend to system prompt
        const existing = cfg.system_prompt orelse "";
        cfg.system_prompt = try std.fmt.allocPrint(arena, "{s}\n\n---\nContext from {s}:\n{s}\n---", .{ existing, path, content });
    }

    // Handle --auto-agents-md: auto-load cwd/AGENTS.md
    if (cfg.auto_agents_md) {
        const agents_md = @import("agents_md.zig");
        if (agents_md.loadAgentsMd(io, arena, "AGENTS.md")) |content| {
            const existing = cfg.system_prompt orelse "";
            cfg.system_prompt = try std.fmt.allocPrint(arena, "{s}\n\n---\nContext from AGENTS.md:\n{s}\n---", .{ existing, content });
        }
    }

    // Run the agent (replaces temporary runOnce)
    const result = agent.run(io, gpa, arena, cfg, init.environ_map) catch |err| {
        const code: ExitCode = switch (err) {
            error.Timeout => .connection_timeout,
            error.AuthFailed => .auth_failed,
            else => .internal_error,
        };
        const detail = if (err == error.AuthFailed) blk: {
            const hint = authHint(arena, cfg.provider);
            break :blk std.fmt.allocPrint(arena,
                "no API key for provider '{s}' — {s}", .{ cfg.provider, hint }) catch "missing API key";
        } else "request failed";
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

test "formatHelpJson lists text and json output modes" {
    const gpa = std.testing.allocator;
    const got = try formatHelpJson(gpa);
    defer gpa.free(got);
    // The machine-readable help must advertise both supported output modes.
    try std.testing.expect(std.mem.indexOf(u8, got, "\"output_modes\":[\"text\",\"json\"]") != null);
}

test "formatHelpJson includes every flag from flag_specs" {
    const gpa = std.testing.allocator;
    const got = try formatHelpJson(gpa);
    defer gpa.free(got);
    for (flag_specs) |f| {
        const found = std.mem.indexOf(u8, got, f.long) != null;
        if (!found) std.debug.print("flag '{s}' missing from help-json\n", .{f.long});
        try std.testing.expect(found);
    }
}

test "formatErrorJson escapes quotes and backslashes in message" {
    const gpa = std.testing.allocator;
    const got = try formatErrorJson(gpa, 80, "invalid_argument", "invalid --timeout-ms: \"bad\"", false);
    defer gpa.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "\\\"bad\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"code\":80") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"type\":\"invalid_argument\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"recoverable\":false") != null);
}

test "formatErrorJson escapes control characters in message and type" {
    const gpa = std.testing.allocator;
    const got = try formatErrorJson(gpa, 110, "type\nhere", "line1\nline2", true);
    defer gpa.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "type\\nhere") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "line1\\nline2") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"recoverable\":true") != null);
}

test "formatWarnJson escapes quotes and control characters" {
    const gpa = std.testing.allocator;
    const got = try formatWarnJson(gpa, "config \"broken\" at /path\nfix it");
    defer gpa.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "config \\\"broken\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "/path\\nfix it") != null);
}

test "formatSkillLoadJson escapes quotes, backslashes, and control characters" {
    const gpa = std.testing.allocator;
    const got = try formatSkillLoadJson(gpa, "skill\"name", "Use \"quotes\" and \\ backslash\nline2");
    defer gpa.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"skill\":\"skill\\\"name\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"content\":\"Use \\\"quotes\\\" and \\\\ backslash\\nline2\"") != null);
}
