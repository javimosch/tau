const std = @import("std");
const term = @import("term.zig");
const cfgmod = @import("config.zig");
const configfile = @import("configfile.zig");
const argsmod = @import("args.zig");
const json = @import("json.zig");
const agent = @import("agent.zig");
const debuglog = @import("debuglog.zig");
const errs = @import("errors.zig");
const crash = @import("crash.zig");
const Config = cfgmod.Config;

pub const name = "tau";
pub const version = @import("version.zig").version;

// Route every panic (and segfaults via the segfault handler) through the
// crash bundle writer before the default trace + abort — see crash.zig.
pub const panic = std.debug.FullPanic(crash.panicHandler);

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

const doc_url = @import("version.zig").troubleshooting_doc_url;
const providers_doc_url = @import("version.zig").providers_doc_url;

fn formatErrorJson(gpa: std.mem.Allocator, code: u8, error_type: []const u8, message: []const u8, recoverable: bool) ![]u8 {
    return errs.format(gpa, errs.specFor(code), message, .{ .type_name = error_type, .recoverable = recoverable });
}

fn printErrorJson(code: u8, error_type: []const u8, message: []const u8, recoverable: bool) void {
    printErrorJsonHint(code, error_type, message, recoverable, null);
}

/// printErrorJson with a dynamic remediation hint (e.g. authHint names the
/// provider's env var); null falls back to the catalog hint for `code`.
fn printErrorJsonHint(code: u8, error_type: []const u8, message: []const u8, recoverable: bool, hint: ?[]const u8) void {
    errs.printErr(std.heap.page_allocator, errs.specFor(code), message, .{ .type_name = error_type, .recoverable = recoverable, .hint = hint });
}

fn formatWarnJson(gpa: std.mem.Allocator, message: []const u8) ![]u8 {
    const mr = try debuglog.redactRegistered(gpa, message);
    defer gpa.free(mr);
    const me = try json.escapeAlloc(gpa, mr);
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
    \\      --debug                  Show perf stats and tool calls (input+output) on
    \\                          stderr, and write a redacted diagnostic log to
    \\                          ~/.config/tau/debug/ for bug reports
    \\                          (override the path with TAU_DEBUG_LOG)
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
    \\Setup:
    \\  tau init                    Write a commented starter config to
    \\                              ~/.config/tau/config.json (detects env API keys)
    \\      --force                 Overwrite an existing config file
    \\      --provider <name>       Scaffold for a specific provider
    \\      --stdout                Print the starter config without writing it
    \\  tau setup                   One-shot onboarding: init + install shell
    \\                              completions + doctor health summary (NDJSON)
    \\      --shell <name>          Completions shell: bash|zsh|fish|pwsh|all
    \\                              (default: detect from $SHELL)
    \\      --offline/--deep        Passed through to the doctor step
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
    \\Diagnostics:
    \\  tau doctor                    Validate setup (config file, provider, API key, connectivity)
    \\      --offline                 Skip network checks
    \\      --deep                    Also run an authenticated probe (spends ~1 token)
    \\      --probe                   Live-verify connectivity + credentials for every
    \\                              provider (per-provider pass/fail rows; spends
    \\                              ~1 token per keyed provider)
    \\      --provider/--model/--api-key   Diagnose an override instead of the configured default
    \\      --fix                     Propose remediations for fixable checks (missing
    \\                              config, loose permissions, missing completions);
    \\                              prompts per fix on a TTY
    \\      --yes                     Apply --fix remediations without prompting
    \\      --json                    Stream NDJSON check/fix events + a done:true
    \\                              verdict instead of the single-object report
    \\      --report                  Print a Markdown diagnostics bundle (build
    \\                              metadata, checks, sanitized config file) for
    \\                              pasting into a bug report; mutually exclusive
    \\                              with --json
    \\      --shell <name>            Completions shell: bash|zsh|fish|pwsh|all
    \\                              (default: detect from $SHELL)
    \\  tau bug                     Build a pre-filled GitHub issue carrying the
    \\                              redacted doctor --report diagnostics bundle
    \\      --title <text>          Issue title (default: "Bug report")
    \\      --body <text>           Description placed above the bundle
    \\      --labels <csv>          Issue labels (default: bug; "" = none)
    \\      --open                  Open the issue URL in the system browser
    \\                              ($BROWSER, else open/xdg-open/rundll32)
    \\      --out <path>            Also write the bundle to a file
    \\      --no-report             Omit the diagnostics bundle
    \\      --offline/--deep        Passed through to the diagnostic sweep
    \\
    \\Config:
    \\  tau config show [flags]       Print the resolved effective config as JSON
    \\                              (config file + env + CLI flags merged; API keys redacted)
    \\  tau config validate [path]    Validate a config file — JSON report on stdout,
    \\                              exit 1 with every problem listed (CI/pre-commit)
    \\  tau config set <key> <v> [path]  Schema-checked edit to the config FILE
    \\                                 (keys are <field> or keys.<provider>; creates the file)
    \\  tau config get <key> [path]   Print a config file value (secrets redacted; --raw)
    \\  tau config unset <key> [path] Remove a key from the config file
    \\  tau config edit [path]        Open the config in $EDITOR (TAU_EDITOR >
    \\                              VISUAL > EDITOR > vi/notepad); validates on save
    \\
    \\
    \\Version:
    \\  tau version                   Print the version (same as -v/--version)
    \\      --verbose                 Include build metadata: git commit, target
    \\                              triple, build date, zig version (JSON;
    \\                              --mode text prints key: value lines)
    \\
    \\Models:
    \\  tau models                    List available providers and models
    \\
    \\Guide (embedded operator manual — read once, drive with no external docs):
    \\  tau guide                     Print the full guide as JSON (agent-readable)
    \\  tau guide --human             ...as markdown
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

fn printVersion(cfg: Config) void {
    const a = std.heap.page_allocator;
    const b = @import("version.zig").build;
    const v = blk: {
        if (!cfg.version_verbose) break :blk std.fmt.allocPrint(a, "{s} {s}\n", .{ name, version }) catch return;
        if (cfg.mode == .text) break :blk std.fmt.allocPrint(a,
            "name: {s}\nversion: {s}\ncommit: {s}\ntarget: {s}\nbuild_date: {s}\nzig: {s}\n",
            .{ name, version, b.commit, b.target, b.date, b.zig }) catch return;
        break :blk std.fmt.allocPrint(a,
            "{{\"name\":\"{s}\",\"version\":\"{s}\",\"commit\":\"{s}\",\"target\":\"{s}\",\"build_date\":\"{s}\",\"zig\":\"{s}\"}}\n",
            .{ name, version, b.commit, b.target, b.date, b.zig }) catch return;
    };
    defer a.free(v);
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
const guide_model = "You (an agent) invoke tau once per task; it runs a single agentic turn (LLM + tools) and exits — no REPL, never blocks on stdin. Output is JSON by default (--mode text for prose; errors are always JSON {err:{code,type,message,hint,docs}}). Provider/model/key resolve from ~/.config/tau/config.json, provider env vars, or TAU_API_KEY; endpoints are OpenAI-compatible /chat/completions (override with TAU_ENDPOINT).";
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
    .{ .a = "tau init [--force] [--provider <name>]", .b = "write a commented starter ~/.config/tau/config.json seeded from detected env keys." },
    .{ .a = "tau setup [--shell <sh>] [--offline|--deep]", .b = "one-shot onboarding: init + install shell completions + doctor health summary (NDJSON)." },
    .{ .a = "tau doctor [--offline|--deep|--probe] [--fix [--yes]] [--json|--report] [--shell <sh>]", .b = "diagnose the setup chain (config, provider, key, completions, connectivity) — JSON report; --probe live-verifies every provider's connectivity and credentials; --json streams NDJSON events; --report prints a Markdown bundle for bug reports; --fix remediates behind confirmation." },
    .{ .a = "tau bug [--title <t>] [--body <text>] [--open] [--out <path>] [--no-report]", .b = "pre-filled GitHub issue URL carrying the redacted doctor diagnostics bundle (JSON: url + body + report)." },
    .{ .a = "tau models", .b = "list providers + default models (JSON)." },
    .{ .a = "tau config show [--flags]", .b = "print the resolved effective config (file+env+flags merged; keys redacted)." },
    .{ .a = "tau config validate [path]", .b = "validate a config file offline; exit 1 + JSON error report on failure (CI/pre-commit)." },
    .{ .a = "tau config set <key> <value> [path]", .b = "schema-checked edit to the config FILE (<field> or keys.<provider>); creates the file if missing." },
    .{ .a = "tau config get <key> [path] [--raw]", .b = "print a config file value; secrets are redacted unless --raw." },
    .{ .a = "tau config unset <key> [path]", .b = "remove a key from the config file." },
    .{ .a = "tau config edit [path]", .b = "open the config file in $EDITOR (TAU_EDITOR > VISUAL > EDITOR > vi/notepad), validate on save; seeds the init scaffold when missing." },
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
    "JSON is the default; use --mode text for prose. Errors are JSON {err:{code,type,message,hint,docs}} even in text mode.",
    "Provider endpoint is resolved at parse time — config.json's provider does NOT set the endpoint; TAU_ENDPOINT overrides it.",
    "API-key precedence: config api_key > keys[provider] > provider env > global api_key > TAU_API_KEY. A stale config api_key silently outranks TAU_API_KEY.",
    "config.json accepts // and /* */ comments (JSONC) — `tau init` scaffolds a commented starter.",
    "tau acp serve reads no model env var; the model comes from config.json or --model.",
    "Requires curl on PATH for LLM HTTP; no other runtime deps.",
    "The tool loop ends when the model stops calling tools or hits --max-iterations (default backstop).",
    "--debug mirrors its stderr output into a redacted log under ~/.config/tau/debug/ (TAU_DEBUG_LOG overrides) — error envelopes link it via debug_log.",
    "tau config validate is fully offline — it only checks the file, so it works in CI and pre-commit hooks.",
    "tau config set|get|unset edit the FILE (git-config style), not the merged view — `config show` still reports effective values. set is schema-checked; get redacts secrets unless --raw.",
    "tau config edit opens the file in $EDITOR (TAU_EDITOR > VISUAL > EDITOR > vi) and runs the `config validate` checks on save — a validation failure exits 1 and lists every problem, but the edits stay on disk.",
};
const guide_see_also = [_][]const u8{
    "tau --help-json (machine-readable command/flag catalog)",
    "tau --help (human help)",
    "README.md (ships with the source)",
    "docs/troubleshooting.md — " ++ doc_url ++ " (error-message → fix FAQ)",
    "docs/providers.md — " ++ providers_doc_url ++ " (per-provider credential setup + auth troubleshooting)",
    "https://cli-specs.intrane.fr/ (guide spec)",
};

fn appendJsonStr(alloc: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8) void {
    buf.append(alloc, '"') catch return;
    json.escapeInto(alloc, buf, s) catch return;
    buf.append(alloc, '"') catch return;
}

/// `"value"` when set, `null` when not.
fn appendJsonStrOrNull(alloc: std.mem.Allocator, buf: *std.ArrayList(u8), s: ?[]const u8) void {
    if (s) |v| {
        appendJsonStr(alloc, buf, v);
    } else {
        buf.appendSlice(alloc, "null") catch return;
    }
}

/// `[ "a", "b" ]` when set, `null` when not.
fn appendJsonStrListOrNull(alloc: std.mem.Allocator, buf: *std.ArrayList(u8), list: ?[]const []const u8) void {
    const l = list orelse {
        buf.appendSlice(alloc, "null") catch return;
        return;
    };
    buf.append(alloc, '[') catch return;
    for (l, 0..) |s, i| {
        if (i != 0) buf.append(alloc, ',') catch return;
        appendJsonStr(alloc, buf, s);
    }
    buf.append(alloc, ']') catch return;
}

/// A finite float as a JSON number, `null` for NaN/Inf (which are not valid
/// JSON literals — parseFloat accepts "nan"/"inf" from flags and config).
fn appendJsonFloatOrNull(alloc: std.mem.Allocator, buf: *std.ArrayList(u8), v: f32) void {
    if (!std.math.isFinite(v)) {
        buf.appendSlice(alloc, "null") catch return;
        return;
    }
    const s = std.fmt.allocPrint(alloc, "{d}", .{v}) catch return;
    defer alloc.free(s);
    buf.appendSlice(alloc, s) catch return;
}

fn appendJsonIntOrNull(alloc: std.mem.Allocator, buf: *std.ArrayList(u8), v: ?u32) void {
    if (v) |n| {
        const s = std.fmt.allocPrint(alloc, "{d}", .{n}) catch return;
        defer alloc.free(s);
        buf.appendSlice(alloc, s) catch return;
    } else {
        buf.appendSlice(alloc, "null") catch return;
    }
}

/// Serialize the resolved effective config for `tau config show`. Reflects the
/// full merge — config file → env vars → CLI flags — exactly as a run would see
/// it. Secrets are never printed: `api_key.value` is masked via redactApiKey and
/// `api_key.source` reports which precedence level supplied the key.
fn formatEffectiveConfig(alloc: std.mem.Allocator, cfg: Config, env: *std.process.Environ.Map) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    const b = &buf;
    const A = alloc;

    try b.appendSlice(A, "{\"version\":");
    appendJsonStr(A, b, version);

    // Where config came from: the probed file path, whether a file was read,
    // and any parse warning (the file is optional; defaults fill the rest).
    try b.appendSlice(A, ",\"config_file\":{\"path\":");
    appendJsonStrOrNull(A, b, configfile.path(A, env));
    try b.appendSlice(A, ",\"exists\":");
    try b.appendSlice(A, if (cfg.config_path != null) "true" else "false");
    try b.appendSlice(A, ",\"warning\":");
    appendJsonStrOrNull(A, b, cfg.config_warning);
    try b.append(A, '}');

    try b.appendSlice(A, ",\"provider\":");
    appendJsonStr(A, b, cfg.provider);
    try b.appendSlice(A, ",\"model\":");
    appendJsonStr(A, b, cfg.model);
    try b.appendSlice(A, ",\"endpoint\":");
    appendJsonStr(A, b, cfg.endpoint);
    // TAU_ENDPOINT is applied during arg resolution; label where the final
    // endpoint came from so overrides are visible.
    const ep_src: []const u8 = blk: {
        if (env.get("TAU_ENDPOINT")) |ep| {
            if (ep.len > 0) break :blk "env:TAU_ENDPOINT";
        }
        break :blk "provider";
    };
    try b.appendSlice(A, ",\"endpoint_source\":");
    appendJsonStr(A, b, ep_src);

    // Resolved API key: redacted value + provenance, never the raw key.
    try b.appendSlice(A, ",\"api_key\":{");
    if (cfgmod.resolveApiKeyInfo(cfg, env)) |rk| {
        const source: []const u8 = switch (rk.source) {
            .flag => "--api-key",
            .config_keys => try std.fmt.allocPrint(A, "config keys[{s}]", .{cfg.provider}),
            .env_provider => try std.fmt.allocPrint(A, "env {s}", .{rk.env_name orelse "?"}),
            .config_global => "config api_key",
            .env_tau => "env TAU_API_KEY",
            .builtin => "builtin",
        };
        try b.appendSlice(A, "\"set\":true,\"value\":");
        appendJsonStr(A, b, cfgmod.redactApiKey(A, rk.key));
        try b.appendSlice(A, ",\"source\":");
        appendJsonStr(A, b, source);
    } else {
        try b.appendSlice(A, "\"set\":false,\"value\":null,\"source\":null");
    }
    try b.append(A, '}');

    // Per-provider keys present in the config file, each value redacted.
    try b.appendSlice(A, ",\"keys\":");
    if (cfg.keys) |km| {
        var it = km.iterator();
        // Sort provider names for deterministic output.
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(A);
        while (it.next()) |e| try names.append(A, e.key_ptr.*);
        std.mem.sort([]const u8, names.items, {}, struct {
            fn lt(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.order(u8, x, y) == .lt;
            }
        }.lt);
        try b.append(A, '{');
        for (names.items, 0..) |n, i| {
            if (i != 0) try b.append(A, ',');
            appendJsonStr(A, b, n);
            try b.append(A, ':');
            appendJsonStr(A, b, cfgmod.redactApiKey(A, km.get(n).?));
        }
        try b.append(A, '}');
    } else {
        try b.appendSlice(A, "null");
    }

    try b.appendSlice(A, ",\"mode\":");
    appendJsonStr(A, b, @tagName(cfg.mode));
    try b.appendSlice(A, ",\"role\":");
    appendJsonStr(A, b, @tagName(cfg.role));
    try b.appendSlice(A, ",\"session\":");
    appendJsonStrOrNull(A, b, cfg.session);
    try b.appendSlice(A, ",\"stream\":");
    try b.appendSlice(A, if (cfg.stream) "true" else "false");
    try b.appendSlice(A, ",\"no_tools\":");
    try b.appendSlice(A, if (cfg.no_tools) "true" else "false");
    try b.appendSlice(A, ",\"tools_allow\":");
    appendJsonStrListOrNull(A, b, cfg.tools_allow);
    try b.appendSlice(A, ",\"tools_deny\":");
    appendJsonStrListOrNull(A, b, cfg.tools_deny);
    try b.appendSlice(A, ",\"thinking\":");
    try b.appendSlice(A, if (cfg.thinking) "true" else "false");
    try b.appendSlice(A, ",\"debug\":");
    try b.appendSlice(A, if (cfg.debug) "true" else "false");
    try b.appendSlice(A, ",\"dry_run\":");
    try b.appendSlice(A, if (cfg.dry_run) "true" else "false");
    try b.appendSlice(A, ",\"temperature\":");
    appendJsonFloatOrNull(A, b, cfg.temperature);
    try b.appendSlice(A, ",\"max_tokens\":");
    appendJsonIntOrNull(A, b, cfg.max_tokens);
    {
        const s = try std.fmt.allocPrint(A, ",\"timeout_ms\":{d},\"max_iterations\":{d}", .{ cfg.timeout_ms, cfg.max_iterations });
        defer A.free(s);
        try b.appendSlice(A, s);
    }
    try b.appendSlice(A, ",\"context_window\":");
    {
        const s = try std.fmt.allocPrint(A, "{d}", .{cfg.context_window});
        defer A.free(s);
        try b.appendSlice(A, s);
    }
    try b.appendSlice(A, ",\"auto_compact\":");
    try b.appendSlice(A, if (cfg.auto_compact) "true" else "false");
    try b.appendSlice(A, ",\"compact_threshold\":");
    appendJsonFloatOrNull(A, b, cfg.compact_threshold);
    try b.appendSlice(A, ",\"compact_keep_recent_tokens\":");
    {
        const s = try std.fmt.allocPrint(A, "{d}", .{cfg.compact_keep_recent_tokens});
        defer A.free(s);
        try b.appendSlice(A, s);
    }
    {
        const s = try std.fmt.allocPrint(A, ",\"goal_max_iterations\":{d},\"goal_max_continues\":{d}}}\n", .{ cfg.goal_max_iterations, cfg.goal_max_continues });
        defer A.free(s);
        try b.appendSlice(A, s);
    }
    // Defense-in-depth on top of the field-level redactApiKey masks: strip
    // every registered credential literal (resolved/env/config keys, endpoint
    // userinfo passwords) plus generic credential patterns — `config show`
    // must never be a credential leak channel.
    return debuglog.redactRegistered(A, try b.toOwnedSlice(A));
}

fn printEffectiveConfig(arena: std.mem.Allocator, cfg: Config, env: *std.process.Environ.Map) void {
    const s = formatEffectiveConfig(arena, cfg, env) catch return;
    writeOut(s);
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
    crash.init(io, arena, init.environ_map, init.minimal.args);

    // Config-file defaults (~/.config/tau/config.json); CLI flags override these.
    const base_cfg: Config = configfile.load(io, arena, init.environ_map);
    // Warn if the config file exists but has invalid JSON (load degrades silently).
    if (base_cfg.config_warning) |w| printWarnJson(w);

    const parsed = argsmod.parse(io, arena, init.minimal.args, init.environ_map, base_cfg) catch {
        printErrorJson(@intFromEnum(ExitCode.internal_error), "internal_error", "argument parsing failed", false);
        std.process.exit(@intFromEnum(ExitCode.internal_error));
    };

    // Register every credential this process could leak (resolved key, all
    // config/env losers, endpoint userinfo) so error envelopes and doctor
    // output mask them — not just the --debug log. Deduped; debuglog.open
    // re-registers under --debug.
    debuglog.registerSecrets(arena, init.environ_map, parsed.config);

    // Smoke/e2e hook: forces a panic through the installed handler so the
    // crash-bundle write + `tau bug` pointer can be exercised end to end.
    if (init.environ_map.get("TAU_CRASH_SELFTEST") != null) {
        @panic("crash selftest (TAU_CRASH_SELFTEST)");
    }

    switch (parsed.action) {
        .help => {
            printHelp();
            return;
        },
        .version => {
            printVersion(parsed.config);
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
        .doctor => {
            const doctor = @import("doctor.zig");
            const code = doctor.run(io, gpa, arena, parsed.config, init.environ_map) catch |err| {
                printErrorJson(@intFromEnum(ExitCode.internal_error), @errorName(err), "doctor failed", false);
                std.process.exit(@intFromEnum(ExitCode.internal_error));
            };
            std.process.exit(code);
        },
        .bug => {
            const bug = @import("bug.zig");
            const code = bug.run(io, gpa, arena, parsed.config, init.environ_map) catch |err| {
                printErrorJson(@intFromEnum(ExitCode.internal_error), @errorName(err), "bug failed", false);
                std.process.exit(@intFromEnum(ExitCode.internal_error));
            };
            std.process.exit(code);
        },
        .init => {
            const initmod = @import("init.zig");
            const code = initmod.run(io, arena, init.environ_map, parsed.config.init_force, parsed.config.init_stdout, parsed.config.init_provider) catch |err| {
                printErrorJson(@intFromEnum(ExitCode.internal_error), @errorName(err), "init failed", false);
                std.process.exit(@intFromEnum(ExitCode.internal_error));
            };
            std.process.exit(code);
        },
        .setup => {
            const setup = @import("setup.zig");
            const code = setup.run(io, gpa, arena, parsed.config, init.environ_map) catch |err| {
                printErrorJson(@intFromEnum(ExitCode.internal_error), @errorName(err), "setup failed", false);
                std.process.exit(@intFromEnum(ExitCode.internal_error));
            };
            std.process.exit(code);
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
        .config => {
            if (std.mem.eql(u8, parsed.config.config_sub orelse "show", "validate")) {
                const cval = @import("configvalidate.zig");
                const path = parsed.config.validate_path orelse (configfile.path(arena, init.environ_map) orelse {
                    printErrorJson(@intFromEnum(ExitCode.invalid_argument), "invalid_argument",
                        "no config path given and HOME is unset — pass a path: tau config validate <path>", false);
                    std.process.exit(@intFromEnum(ExitCode.invalid_argument));
                });
                const report = cval.validate(io, arena, path) catch |err| {
                    printErrorJson(@intFromEnum(ExitCode.internal_error), @errorName(err), "config validation failed", false);
                    std.process.exit(@intFromEnum(ExitCode.internal_error));
                };
                const out = if (parsed.config.mode == .text)
                    cval.formatText(arena, report) catch {
                        printErrorJson(@intFromEnum(ExitCode.internal_error), "OutOfMemory", "config validation failed", false);
                        std.process.exit(@intFromEnum(ExitCode.internal_error));
                    }
                else
                    cval.formatJson(arena, report) catch {
                        printErrorJson(@intFromEnum(ExitCode.internal_error), "OutOfMemory", "config validation failed", false);
                        std.process.exit(@intFromEnum(ExitCode.internal_error));
                    };
                term.out(debuglog.redactRegistered(arena, out) catch out);
                // Exit 1 (generic_failure) on validation errors — the pinned
                // contract needs no new code; CI/pre-commit just check non-zero.
                std.process.exit(if (report.ok()) 0 else @intFromEnum(ExitCode.generic_failure));
            }
            const config_sub = parsed.config.config_sub orelse "show";
            if (std.mem.eql(u8, config_sub, "edit")) {
                const cedit = @import("configedit.zig");
                const outcome = cedit.runEditor(
                    io,
                    arena,
                    parsed.config.edit_path,
                    init.environ_map,
                    parsed.config.mode,
                ) catch |err| {
                    printErrorJson(@intFromEnum(ExitCode.internal_error), @errorName(err), "config edit failed", false);
                    std.process.exit(@intFromEnum(ExitCode.internal_error));
                };
                switch (outcome) {
                    .ok => |s| {
                        term.out(debuglog.redactRegistered(arena, s) catch s);
                        return;
                    },
                    // Validation report on stdout (same channel/shape as
                    // `config validate`), exit 1 — the saved file needs fixes.
                    .invalid => |s| {
                        term.out(debuglog.redactRegistered(arena, s) catch s);
                        std.process.exit(@intFromEnum(ExitCode.generic_failure));
                    },
                    .fail => |f| {
                        printErrorJson(f.code, f.type_name, f.message, false);
                        std.process.exit(f.code);
                    },
                }
            }
            if (std.meta.stringToEnum(@import("configedit.zig").Sub, config_sub)) |csub| {
                const cedit = @import("configedit.zig");
                const outcome = cedit.run(
                    io,
                    arena,
                    csub,
                    parsed.config.config_key orelse "",
                    parsed.config.config_value,
                    parsed.config.edit_path,
                    init.environ_map,
                    parsed.config.config_raw,
                    parsed.config.mode,
                ) catch |err| {
                    printErrorJson(@intFromEnum(ExitCode.internal_error), @errorName(err), "config edit failed", false);
                    std.process.exit(@intFromEnum(ExitCode.internal_error));
                };
                switch (outcome) {
                    .ok => |s| {
                        term.out(s);
                        return;
                    },
                    .fail => |f| {
                        printErrorJson(f.code, f.type_name, f.message, false);
                        std.process.exit(f.code);
                    },
                }
            }
            printEffectiveConfig(arena, parsed.config, init.environ_map);
            return;
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
                    printErrorJsonHint(@intFromEnum(ExitCode.auth_failed), "AuthFailed", msg, false, hint);
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

    // --debug: open the redacted diagnostic log before the run so every error
    // path below can link to it and [DEBUG] lines land in the file.
    if (cfg.debug) {
        if (debuglog.open(io, arena, init.environ_map, cfg)) |lp| {
            if (json.escapeAlloc(arena, lp) catch null) |pe| {
                if (std.fmt.allocPrint(arena, "{{\"debug_log\":\"{s}\"}}\n", .{pe}) catch null) |line| {
                    term.err(line);
                }
            }
        } else {
            printWarnJson("--debug: could not create diagnostic log (set TAU_DEBUG_LOG to a writable path, or check ~/.config/tau)");
        }
    }

    // Run the agent (replaces temporary runOnce)
    const run_started = std.Io.Timestamp.now(io, .real);
    const result = agent.run(io, gpa, arena, cfg, init.environ_map) catch |err| {
        const code: ExitCode = switch (err) {
            error.Timeout => .connection_timeout,
            error.AuthFailed => .auth_failed,
            else => .internal_error,
        };
        if (cfg.debug) debuglog.emitPerf(io, run_started, 0, @intFromEnum(code));
        var hint: ?[]const u8 = null;
        const detail = if (err == error.AuthFailed) blk: {
            hint = authHint(arena, cfg.provider);
            break :blk std.fmt.allocPrint(arena,
                "no API key for provider '{s}' — {s}", .{ cfg.provider, hint.? }) catch "missing API key";
        } else "request failed";
        printErrorJsonHint(@intFromEnum(code), @errorName(err), detail, false, hint);
        std.process.exit(@intFromEnum(code));
    };
    if (cfg.debug) debuglog.emitPerf(io, run_started, result.tokens_out, result.exit_code);
    std.process.exit(result.exit_code);
}

test {
    std.testing.refAllDecls(@This());
    _ = json;
    _ = debuglog;
    _ = errs;
    _ = @import("goal.zig");
    _ = @import("context.zig");
    _ = @import("session.zig");
    _ = @import("doctor.zig");
    _ = @import("init.zig");
    _ = @import("setup.zig");
    _ = @import("version.zig");
    _ = @import("configvalidate.zig");
    _ = @import("configedit.zig");
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

// Golden tests for the {"err":...} envelope (task #134): the envelope shape
// and the docs link are a user-visible contract — changes must be deliberate.
test "formatErrorJson emits the golden envelope including hint and docs link" {
    const gpa = std.testing.allocator;
    const got = try formatErrorJson(gpa, 80, "invalid_argument", "bad flag --nope", false);
    defer gpa.free(got);
    try std.testing.expectEqualStrings(
        "{\"err\":{\"code\":80,\"type\":\"invalid_argument\",\"message\":\"bad flag --nope\",\"recoverable\":false,\"hint\":\"run `tau --help` (or `tau --help-json`) for the valid flags and values\",\"docs\":\"https://github.com/javimosch/tau/blob/master/docs/troubleshooting.md\"}}\n",
        got,
    );
}

test "every catalog error code is advertised in --help-json exit_codes" {
    const gpa = std.testing.allocator;
    const got = try formatHelpJson(gpa);
    defer gpa.free(got);
    for (errs.specs) |s| {
        // Exit code 1 (not_found) is intentionally absent from the advertised
        // map — the integration contract documents it as the unlisted generic.
        if (s.code == 1) continue;
        var buf: [16]u8 = undefined;
        const entry = std.fmt.bufPrint(&buf, "\"{d}\":\"", .{s.code}) catch unreachable;
        if (std.mem.indexOf(u8, got, entry) == null) {
            std.debug.print("--help-json exit_codes missing code {d} ({s})\n", .{ s.code, s.type_name });
            return error.TestUnexpectedResult;
        }
    }
}

test "every literal err emitter in src carries a hint and docs link" {
    // Hand-rolled {"err":...} literals live outside errors.format in these
    // files; scan each emission site so a new one can't forget the hint/docs
    // fields (the catalog's snapshot tests live in errors.zig).
    const sources = [_][]const u8{
        @embedFile("main.zig"),
        @embedFile("agent.zig"),
        @embedFile("acp.zig"),
        @embedFile("fleet.zig"),
        @embedFile("helpers.zig"),
        @embedFile("errors.zig"),
    };
    for (sources) |src| {
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, src, pos, "err\\\":{")) |i| {
            const window = src[i..@min(src.len, i + 700)];
            try std.testing.expect(std.mem.indexOf(u8, window, "hint\\\":") != null);
            try std.testing.expect(std.mem.indexOf(u8, window, "docs\\\":") != null);
            pos = i + 1;
        }
    }
}

test "troubleshooting doc exists and indexes every exit code" {
    const gpa = std.testing.allocator;
    const doc = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "docs/troubleshooting.md", gpa, .unlimited);
    defer gpa.free(doc);
    for ([_][]const u8{ "| `80`", "| `82`", "| `105`", "| `106`", "| `110`", "| `111`" }) |row| {
        const found = std.mem.indexOf(u8, doc, row) != null;
        if (!found) std.debug.print("troubleshooting.md missing exit-code row '{s}'\n", .{row});
        try std.testing.expect(found);
    }
    try std.testing.expect(std.mem.indexOf(u8, doc, @import("version.zig").troubleshooting_doc_url) != null);
}

test "README links to the troubleshooting doc" {
    const gpa = std.testing.allocator;
    const readme = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "README.md", gpa, .unlimited);
    defer gpa.free(readme);
    try std.testing.expect(std.mem.indexOf(u8, readme, "docs/troubleshooting.md") != null);
}

// ── tau config show ─────────────────────────────────────────────────────────

test "formatEffectiveConfig emits merged values with the key redacted" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var env = std.process.Environ.Map.init(a);

    const cfg = Config{
        .provider = "openai",
        .model = "gpt-x",
        .endpoint = "https://api.openai.com/v1/chat/completions",
        .api_key = "sk-supersecret-9f8e",
        .mode = .text,
        .stream = false,
        .timeout_ms = 9000,
        .session = "work",
        .role = .author,
    };
    const out = try formatEffectiveConfig(a, cfg, &env);

    try std.testing.expect(std.mem.indexOf(u8, out, "\"provider\":\"openai\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"model\":\"gpt-x\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"mode\":\"text\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"stream\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"timeout_ms\":9000") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"session\":\"work\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"role\":\"author\"") != null);
    // The raw key must never appear — only the masked tail and its source.
    try std.testing.expect(std.mem.indexOf(u8, out, "sk-supersecret-9f8e") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"api_key\":{\"set\":true,\"value\":\"***9f8e\",\"source\":\"--api-key\"}") != null);
}

test "formatEffectiveConfig reports env key source and endpoint override" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var env = std.process.Environ.Map.init(a);
    try env.put("OPENAI_API_KEY", "sk-env-9999");
    try env.put("TAU_ENDPOINT", "http://localhost:8080/v1/chat/completions");

    const cfg = Config{
        .provider = "openai",
        .endpoint = "http://localhost:8080/v1/chat/completions",
    };
    const out = try formatEffectiveConfig(a, cfg, &env);
    try std.testing.expect(std.mem.indexOf(u8, out, "sk-env-9999") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"source\":\"env OPENAI_API_KEY\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"endpoint_source\":\"env:TAU_ENDPOINT\"") != null);
}

test "formatEffectiveConfig reports set:false and provider endpoint without overrides" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var env = std.process.Environ.Map.init(a);

    const cfg = Config{};
    const out = try formatEffectiveConfig(a, cfg, &env);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"api_key\":{\"set\":false,\"value\":null,\"source\":null}") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"endpoint_source\":\"provider\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"exists\":false") != null);
}

test "formatEffectiveConfig redacts each per-provider keys entry and sorts them" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var env = std.process.Environ.Map.init(a);

    var km = std.StringHashMap([]const u8).init(a);
    try km.put("xiaomi", "xiaomi-key-bbbb");
    try km.put("deepseek", "deepseek-key-aaaa");
    const cfg = Config{ .provider = "openai", .keys = km };
    const out = try formatEffectiveConfig(a, cfg, &env);

    try std.testing.expect(std.mem.indexOf(u8, out, "deepseek-key-aaaa") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "xiaomi-key-bbbb") == null);
    // Sorted: deepseek before xiaomi; each value masked to its last 4.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"keys\":{\"deepseek\":\"***aaaa\",\"xiaomi\":\"***bbbb\"}") != null);
    // The resolved api_key for provider openai comes from the map miss → set:false.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"api_key\":{\"set\":false") != null);
}

test "formatEffectiveConfig reports config file path and warning" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var env = std.process.Environ.Map.init(a);
    try env.put("HOME", "/home/tester");

    const cfg = Config{
        .config_path = "/home/tester/.config/tau/config.json",
        .config_warning = "config file has invalid JSON and was ignored",
    };
    const out = try formatEffectiveConfig(a, cfg, &env);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"path\":\"/home/tester/.config/tau/config.json\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"exists\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"warning\":\"config file has invalid JSON and was ignored\"") != null);
}

test "formatEffectiveConfig emits null for non-finite floats (valid JSON)" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var env = std.process.Environ.Map.init(a);

    const cfg = Config{ .temperature = std.math.nan(f32) };
    const out = try formatEffectiveConfig(a, cfg, &env);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"temperature\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "nan") == null);
}

// ── Redaction invariant: `tau config show` ──────────────────────────────────
// Config inspection is a credential surface: the resolved key, per-provider
// keys, and endpoint userinfo passwords must never reach stdout — field-level
// ***last4 masks plus a process-wide secret sweep (debuglog.redactRegistered)
// enforce it. `k-`-prefixed random secrets can't collide with static output
// text, so any substring hit is a real leak.

const show_secret_alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._";

fn randShowSecret(r: std.Random, a: std.mem.Allocator) ![]u8 {
    const s = try a.alloc(u8, r.intRangeAtMost(usize, 10, 36));
    s[0] = 'k';
    s[1] = '-';
    for (s[2..]) |*ch| ch.* = show_secret_alphabet[r.uintLessThan(usize, show_secret_alphabet.len)];
    return s;
}

test "property: credentials never survive `tau config show` output" {
    var prng = std.Random.DefaultPrng.init(0x237_c5ec);
    const r = prng.random();
    var iter: usize = 0;
    while (iter < 120) : (iter += 1) {
        var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer ar.deinit();
        const a = ar.allocator();
        var env = std.process.Environ.Map.init(a);

        const k_flag = try randShowSecret(r, a); // --api-key winner
        const k_cfg = try randShowSecret(r, a); // config api_key loser
        const k_map = try randShowSecret(r, a); // keys[openai]
        const k_map2 = try randShowSecret(r, a); // keys[deepseek]
        const k_env = try randShowSecret(r, a); // env loser
        const k_pw = try randShowSecret(r, a); // endpoint userinfo password

        var km = std.StringHashMap([]const u8).init(a);
        try km.put("openai", k_map);
        try km.put("deepseek", k_map2);
        try env.put("DEEPSEEK_API_KEY", k_env);
        const cfg = Config{
            .provider = "openai",
            .api_key = k_flag,
            .config_api_key = k_cfg,
            .keys = km,
            .endpoint = try std.fmt.allocPrint(a, "https://user:{s}@api.example.com/v1", .{k_pw}),
        };
        // Register every secret EXCEPT k_pw — the endpoint password must be
        // caught by the generic userinfo pattern alone (file-embedded
        // endpoints aren't in the process registry either).
        debuglog.addSecretsForTest(&.{ k_flag, k_cfg, k_map, k_map2, k_env });
        defer debuglog.clearSecretsForTest();

        const out = try formatEffectiveConfig(a, cfg, &env);
        for ([_][]const u8{ k_flag, k_cfg, k_map, k_map2, k_env, k_pw }) |sec| {
            if (std.mem.indexOf(u8, out, sec) != null) {
                std.debug.print("config show leaked '{s}': {s}\n", .{ sec, out });
                return error.TestUnexpectedResult;
            }
        }
        // The endpoint stays identifiable — only the password component goes.
        try std.testing.expect(std.mem.indexOf(u8, out, "api.example.com") != null);
    }
}
