const std = @import("std");
const cfgmod = @import("config.zig");
const goalmod = @import("goal.zig");
const Config = cfgmod.Config;

pub const Action = enum { run, help, version, help_json, acp, fleet, skills, models, err };

pub const Parsed = struct {
    action: Action = .run,
    config: Config = .{},
    err_msg: ?[]const u8 = null,
    help_requested: bool = false,
};

fn val(argv: []const []const u8, i: *usize) ?[]const u8 {
    if (i.* + 1 >= argv.len) return null;
    i.* += 1;
    return argv[i.*];
}

fn splitCsv(arena: std.mem.Allocator, s: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, s, ',');
    while (it.next()) |part| {
        const t = std.mem.trim(u8, part, " \t");
        if (t.len > 0) try out.append(arena, t);
    }
    return out.toOwnedSlice(arena);
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Parse argv into an Action + Config. All retained strings are allocated in
/// `arena` (freed automatically at process exit, so no leak bookkeeping). `io`
/// is used to read `@file` arguments.
pub fn parse(
    io: std.Io,
    arena: std.mem.Allocator,
    args: std.process.Args,
    env: *std.process.Environ.Map,
    base: Config,
) !Parsed {
    var it = try std.process.Args.Iterator.initAllocator(args, arena);
    _ = it.next(); // skip argv[0]

    var argv_list: std.ArrayList([]const u8) = .empty;
    while (it.next()) |a| try argv_list.append(arena, try arena.dupe(u8, a));
    const argv = argv_list.items;

    // Fleet-subcommand scratch state (declared up here so the fleet subcommand
    // block above can write into them before the generic flag loop runs).
    var fleet_goal: ?[]const u8 = null;
    var fleet_id: ?[]const u8 = null;
    var fleet_items: ?[]const u8 = null; // raw JSON blob of pre-supplied items

    // `tau acp <start|stop|status|serve> [--acp-socket PATH]` — handled before
    // the generic flag/prompt parsing (acp is a command, not a prompt).
    if (argv.len > 0 and eq(argv[0], "acp")) {
        var acfg: Config = base;
        acfg.acp_sub = .serve;
        // ACP loop: the turn ends naturally when the model stops calling tools
        // (like Claude Code / OpenCode, which don't cap by default). This is just
        // a runaway backstop; compaction bounds context, and on hitting it we
        // force a final summary answer. --max-iterations tunes it.
        acfg.max_iterations = 100;
        var j: usize = 1;
        while (j < argv.len) : (j += 1) {
            const a = argv[j];
            if (eq(a, "start")) acfg.acp_sub = .start else if (eq(a, "stop")) acfg.acp_sub = .stop else if (eq(a, "status")) acfg.acp_sub = .status else if (eq(a, "serve")) acfg.acp_sub = .serve else if (eq(a, "--acp-socket")) {
                j += 1;
                if (j >= argv.len) return missing(arena, a);
                acfg.acp_socket = argv[j];
            } else if (eq(a, "--max-iterations")) {
                j += 1;
                if (j >= argv.len) return missing(arena, a);
                acfg.max_iterations = std.fmt.parseInt(u32, argv[j], 10) catch
                    return errResult(arena, "invalid --max-iterations: {s}", .{argv[j]});
            } else return errResult(arena, "unknown acp argument: {s}", .{a});
        }
        return .{ .action = .acp, .config = acfg };
    }

    // `tau models` — list available providers and their models.
    if (argv.len > 0 and eq(argv[0], "models")) {
        return .{ .action = .models, .config = base };
    }

    // `tau skills <list|search|load> [args]` — parallel to `tau acp` / `tau fleet`.
    if (argv.len > 0 and eq(argv[0], "skills")) {
        var scfg: Config = base;
        if (argv.len < 2) return errResult(arena, "skills subcommand required: list | search | load", .{});
        scfg.skills_sub = argv[1];
        if (argv.len > 2) scfg.skills_arg = argv[2];
        if (!eq(argv[1], "list") and !eq(argv[1], "search") and !eq(argv[1], "load")) {
            return errResult(arena, "invalid skills subcommand (want list|search|load): {s}", .{argv[1]});
        }
        return .{ .action = .skills, .config = scfg };
    }

    // `tau fleet <run|status|list|logs|cancel> ...` — parallel to `tau acp`.
    if (argv.len > 0 and eq(argv[0], "fleet")) {
        var fcfg: Config = base;
        // Resolve provider → endpoint (the non-fleet path does this at the end
        // of parse; fleet returns early so it must be done here).
        const p = cfgmod.findProvider(fcfg.provider) orelse
            return unknownProviderErr(arena, fcfg.provider);
        fcfg.provider = p.name;
        fcfg.endpoint = p.endpoint;
        // TAU_ENDPOINT overrides the provider's endpoint (see non-fleet path).
        if (env.get("TAU_ENDPOINT")) |ep| {
            if (ep.len > 0) fcfg.endpoint = try arena.dupe(u8, ep);
        }
        if (std.mem.eql(u8, base.model, cfgmod.providers[0].default_model)) {
            fcfg.model = p.default_model;
        } // else keep base.model (config-file supplied a custom model)
        if (argv.len < 2) return errResult(arena, "fleet subcommand required: run | status | list | logs | cancel", .{});
        var j: usize = 1;
        var mode: ?[]const u8 = null;
        while (j < argv.len) : (j += 1) {
            const a = argv[j];
            if (eq(a, "--goal")) {
                j += 1;
                if (j >= argv.len) return missing(arena, a);
                fleet_goal = argv[j];
            } else if (eq(a, "--id")) {
                j += 1;
                if (j >= argv.len) return missing(arena, a);
                fleet_id = argv[j];
            } else if (eq(a, "--api-key")) {
                j += 1;
                if (j >= argv.len) return missing(arena, a);
                fcfg.api_key = argv[j];
            } else if (eq(a, "--provider")) {
                j += 1;
                if (j >= argv.len) return missing(arena, a);
                fcfg.provider = argv[j];
            } else if (eq(a, "--coordinator-model")) {
                j += 1;
                if (j >= argv.len) return missing(arena, a);
                fcfg.coordinator_model = argv[j];
            } else if (eq(a, "--model")) {
                j += 1;
                if (j >= argv.len) return missing(arena, a);
                fcfg.model = argv[j];
            } else if (eq(a, "--worker-model")) {
                j += 1;
                if (j >= argv.len) return missing(arena, a);
                fcfg.worker_model = argv[j];
            } else if (eq(a, "--sequential")) {
                fcfg.fleet_parallel = false;
            } else if (eq(a, "--parallel")) {
                fcfg.fleet_parallel = true;
            } else if (eq(a, "--items")) {
                j += 1;
                if (j >= argv.len) return missing(arena, a);
                fleet_items = argv[j];
            } else if (eq(a, "--schema")) {
                j += 1;
                if (j >= argv.len) return missing(arena, a);
                if (argv[j].len > 0 and argv[j][0] == '@') {
                    const path = argv[j][1..];
                    const content = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited) catch
                        return errResult(arena, "cannot read schema file: {s}", .{argv[j]});
                    fcfg.schema = content;
                } else {
                    fcfg.schema = argv[j];
                }
            } else if (mode == null and (eq(a, "run") or eq(a, "status") or eq(a, "list") or eq(a, "logs") or eq(a, "cancel"))) {
                mode = a;
            } else if (mode != null and a.len > 0 and a[0] != '-') {
                // Positional argument: fleet_id for status/cancel/logs.
                if (fleet_id != null) return errResult(arena, "unexpected extra argument: {s}", .{a});
                fleet_id = a;
            } else {
                return errResult(arena, "unknown fleet argument: {s}", .{a});
            }
        }
        const m = mode orelse return errResult(arena, "fleet subcommand required: run | status | list | logs | cancel", .{});
        // Stash mode + id + goal on Config so main.zig can dispatch.
        fcfg.fleet_sub = m;
        fcfg.fleet_id = fleet_id;
        fcfg.fleet_goal = fleet_goal;
        fcfg.fleet_items = fleet_items;
        return .{ .action = .fleet, .config = fcfg };
    }

    // Start from `base` (config-file defaults). CLI flags below override it.
    var cfg: Config = base;
    var provider_opt: ?[]const u8 = null;
    var model_opt: ?[]const u8 = null;
    var api_key_opt: ?[]const u8 = null;
    var ctx_window_opt: ?u32 = null;
    var sys_parts: std.ArrayList([]const u8) = .empty;
    var msg_parts: std.ArrayList([]const u8) = .empty;
    var file_parts: std.ArrayList([]const u8) = .empty;
    var help_requested = false;

    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];

        if (eq(a, "-h") or eq(a, "--help")) {
            help_requested = true;
            continue;
        }
        if (eq(a, "-v") or eq(a, "--version")) return .{ .action = .version };
        if (eq(a, "--help-json")) return .{ .action = .help_json };
        if (eq(a, "-p") or eq(a, "--print")) continue; // always non-interactive
        if (eq(a, "--stream")) {
            cfg.stream = true;
            continue;
        }
        if (eq(a, "--no-stream")) {
            cfg.stream = false;
            continue;
        }
        if (eq(a, "--no-tools") or eq(a, "-nt")) {
            cfg.no_tools = true;
            continue;
        }
        if (eq(a, "--session")) {
            cfg.session = val(argv, &i) orelse return missing(arena, a);
            continue;
        }
        if (eq(a, "--context-window")) {
            const v = val(argv, &i) orelse return missing(arena, a);
            ctx_window_opt = std.fmt.parseInt(u32, v, 10) catch
                return errResult(arena, "invalid --context-window: {s}", .{v});
            continue;
        }
        if (eq(a, "--compact-threshold")) {
            const v = val(argv, &i) orelse return missing(arena, a);
            cfg.compact_threshold = std.fmt.parseFloat(f32, v) catch
                return errResult(arena, "invalid --compact-threshold: {s}", .{v});
            continue;
        }
        if (eq(a, "--no-compact")) {
            cfg.auto_compact = false;
            continue;
        }
        if (eq(a, "--role")) {
            const v = val(argv, &i) orelse return missing(arena, a);
            if (eq(v, "author")) cfg.role = .author
            else if (eq(v, "critic")) cfg.role = .critic
            else if (eq(v, "coordinator")) cfg.role = .coordinator
            else if (eq(v, "none")) cfg.role = .none
            else return errResult(arena, "invalid --role (want author|critic|coordinator|none): {s}", .{v});
            continue;
        }
        if (eq(a, "--compact-keep-recent")) {
            const v = val(argv, &i) orelse return missing(arena, a);
            cfg.compact_keep_recent_tokens = std.fmt.parseInt(u32, v, 10) catch
                return errResult(arena, "invalid --compact-keep-recent: {s}", .{v});
            continue;
        }
        if (eq(a, "--goal-max-iterations")) {
            const v = val(argv, &i) orelse return missing(arena, a);
            cfg.goal_max_iterations = std.fmt.parseInt(u32, v, 10) catch
                return errResult(arena, "invalid --goal-max-iterations: {s}", .{v});
            continue;
        }
        if (eq(a, "--max-iterations")) {
            const v = val(argv, &i) orelse return missing(arena, a);
            cfg.max_iterations = std.fmt.parseInt(u32, v, 10) catch
                return errResult(arena, "invalid --max-iterations: {s}", .{v});
            continue;
        }

        if (eq(a, "--schema")) {
            const v = val(argv, &i) orelse return missing(arena, a);
            if (v.len > 0 and v[0] == '@') {
                // Load schema from file
                const path = v[1..];
                const content = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited) catch
                    return errResult(arena, "cannot read schema file: {s}", .{v});
                cfg.schema = content;
            } else {
                cfg.schema = v;
            }
            continue;
        }

        if (eq(a, "--scan-agents")) {
            cfg.scan_agents = true;
            continue;
        }
        if (eq(a, "--load-agents-md")) {
            cfg.load_agents_md = val(argv, &i) orelse return missing(arena, a);
            continue;
        }
        if (eq(a, "--auto-agents-md")) {
            cfg.auto_agents_md = true;
            continue;
        }

        if (eq(a, "--provider")) {
            provider_opt = val(argv, &i) orelse return missing(arena, a);
            continue;
        }
        if (eq(a, "--model")) {
            model_opt = val(argv, &i) orelse return missing(arena, a);
            continue;
        }
        if (eq(a, "--api-key")) {
            api_key_opt = val(argv, &i) orelse return missing(arena, a);
            continue;
        }
        if (eq(a, "--system-prompt")) {
            const v = val(argv, &i) orelse return missing(arena, a);
            sys_parts.clearRetainingCapacity();
            try sys_parts.append(arena, v);
            continue;
        }
        if (eq(a, "--append-system-prompt")) {
            try sys_parts.append(arena, val(argv, &i) orelse return missing(arena, a));
            continue;
        }
        if (eq(a, "--mode")) {
            const v = val(argv, &i) orelse return missing(arena, a);
            if (eq(v, "text")) {
                cfg.mode = .text;
            } else if (eq(v, "json")) {
                cfg.mode = .json;
            } else {
                return errResult(arena, "invalid --mode (want text|json): {s}", .{v});
            }
            continue;
        }
        if (eq(a, "--tools") or eq(a, "-t")) {
            cfg.tools_allow = try splitCsv(arena, val(argv, &i) orelse return missing(arena, a));
            continue;
        }
        if (eq(a, "--exclude-tools") or eq(a, "-xt")) {
            cfg.tools_deny = try splitCsv(arena, val(argv, &i) orelse return missing(arena, a));
            continue;
        }
        if (eq(a, "--thinking")) {
            cfg.thinking = true;
            continue;
        }
        if (eq(a, "--debug")) {
            cfg.debug = true;
            continue;
        }
        if (eq(a, "--dry-run")) {
            cfg.dry_run = true;
            continue;
        }
        if (eq(a, "--temperature")) {
            const v = val(argv, &i) orelse return missing(arena, a);
            cfg.temperature = std.fmt.parseFloat(f32, v) catch
                return errResult(arena, "invalid --temperature: {s}", .{v});
            continue;
        }
        if (eq(a, "--max-tokens")) {
            const v = val(argv, &i) orelse return missing(arena, a);
            cfg.max_tokens = std.fmt.parseInt(u32, v, 10) catch
                return errResult(arena, "invalid --max-tokens: {s}", .{v});
            continue;
        }
        if (eq(a, "--timeout-ms")) {
            const v = val(argv, &i) orelse return missing(arena, a);
            cfg.timeout_ms = std.fmt.parseInt(i64, v, 10) catch
                return errResult(arena, "invalid --timeout-ms: {s}", .{v});
            continue;
        }

        if (a.len > 0 and a[0] == '@') {
            try file_parts.append(arena, a[1..]);
            continue;
        }
        if (a.len > 1 and a[0] == '-') {
            return errResult(arena, "unknown option: {s}", .{a});
        }
        try msg_parts.append(arena, a); // positional message part
    }

    // Resolve provider / model / endpoint. Support `--model provider/id`.
    if (model_opt) |m| {
        if (std.mem.indexOfScalar(u8, m, '/')) |slash| {
            if (provider_opt == null) provider_opt = m[0..slash];
            model_opt = m[slash + 1 ..];
        }
    }
    const prov_name = provider_opt orelse cfg.provider;
    const p = cfgmod.findProvider(prov_name) orelse
        return unknownProviderErr(arena, prov_name);
    cfg.provider = p.name;
    cfg.endpoint = p.endpoint;
    // TAU_ENDPOINT overrides the provider's endpoint — point tau at any
    // OpenAI-compatible server (a local llama.cpp/vllm/machin-colibri, a proxy).
    if (env.get("TAU_ENDPOINT")) |ep| {
        if (ep.len > 0) cfg.endpoint = try arena.dupe(u8, ep);
    }
    // Model precedence:
    // 1. --model (or the provider/id shorthand).
    // 2. A config-file model, but only while the provider is not being
    //    explicitly switched to a different one (a model chosen for the
    //    previous provider is unlikely to be valid on the new one).
    // 3. The selected provider's default model.
    if (model_opt) |m| {
        cfg.model = m;
    } else {
        const provider_changed = if (provider_opt) |po| !std.mem.eql(u8, po, base.provider) else false;
        if (provider_changed) {
            cfg.model = p.default_model;
        } else if (std.mem.eql(u8, base.model, cfgmod.providers[0].default_model)) {
            // The base model is still the initial hardcoded default, so no
            // model was explicitly configured; use the selected provider's default.
            cfg.model = p.default_model;
        }
        // else keep base.model (config-file supplied a custom model).
    }
    if (api_key_opt) |k| cfg.api_key = k; // else keep base.api_key (config-file)

    // Context window precedence: --context-window > config-file value (if it set
    // a non-default) > provider/model table default. Wrong values only shift WHEN
    // compaction triggers, never correctness.
    if (ctx_window_opt) |cw| {
        cfg.context_window = cw;
    } else if (base.context_window == 256_000) {
        cfg.context_window = p.context_window;
    } // else keep base (config-file supplied a custom window)

    // Build the system prompt (parts joined by newlines).
    if (sys_parts.items.len > 0) {
        var sb: std.ArrayList(u8) = .empty;
        for (sys_parts.items, 0..) |s, idx| {
            if (idx != 0) try sb.append(arena, '\n');
            try sb.appendSlice(arena, s);
        }
        cfg.system_prompt = try sb.toOwnedSlice(arena);
    }

    // Build the user prompt: @file contents first, then positional message.
    var pb: std.ArrayList(u8) = .empty;
    for (file_parts.items) |fp| {
        const content = std.Io.Dir.cwd().readFileAlloc(io, fp, arena, .unlimited) catch
            return errResult(arena, "cannot read file @{s}", .{fp});
        try pb.appendSlice(arena, "Contents of ");
        try pb.appendSlice(arena, fp);
        try pb.appendSlice(arena, ":\n");
        try pb.appendSlice(arena, content);
        try pb.appendSlice(arena, "\n\n");
    }
    for (msg_parts.items, 0..) |m, idx| {
        if (idx != 0) try pb.append(arena, ' ');
        try pb.appendSlice(arena, m);
    }
    if (pb.items.len > 0) cfg.prompt = try pb.toOwnedSlice(arena);

    // /goal detection: a prompt beginning with "/goal" sets goal mode. .set also
    // forces non-streaming (goal needs the tool loop). Objective is arena-owned
    // (a slice of cfg.prompt). Subcommands carry no objective.
    if (cfg.prompt) |pr| {
        if (goalmod.parse(pr)) |g| {
            cfg.goal_action = g.action;
            cfg.goal = g.objective;
            if (g.token_budget) |b| cfg.token_budget = b;
            if (g.action == .set) cfg.stream = false;
        }
    }

    // -h/--help always shows human-readable text; --help-json is the machine form.
    if (help_requested) return .{ .action = .help, .config = cfg, .help_requested = true };

    // No args and no prompt: show human-readable help (not JSON),
    // unless a standalone flag like --scan-agents or --load-agents-md is set.
    const has_standalone_flag = cfg.scan_agents or cfg.load_agents_md != null or cfg.auto_agents_md;
    if (cfg.prompt == null and sys_parts.items.len == 0 and file_parts.items.len == 0 and !has_standalone_flag) {
        return .{ .action = .help, .config = cfg, .help_requested = true };
    }

    return .{ .action = .run, .config = cfg };
}

fn missing(arena: std.mem.Allocator, flag: []const u8) Parsed {
    return errResult(arena, "missing value for {s}", .{flag}) catch
        .{ .action = .err, .err_msg = "missing value" };
}

fn errResult(arena: std.mem.Allocator, comptime fmt: []const u8, fmtargs: anytype) !Parsed {
    return .{ .action = .err, .err_msg = try std.fmt.allocPrint(arena, fmt, fmtargs) };
}

// ── Tests ───────────────────────────────────────────────────────────────────
//
// `parse` consumes a `std.process.Args` (the platform argv vector) and a
// `std.process.Environ.Map`. On the test host both are constructed directly:
// `Args.vector` is just a `[]const [*:0]const u8`, so an array of string
// literals (with a dummy argv[0], which `parse` skips) drives the parser. The
// env map is left empty — env-key resolution happens later in main, not here.

const provider_mod = @import("llm/provider.zig");

/// Run `parse` over an explicit argv (caller supplies argv[0]). All retained
/// strings land in `arena`, freed together by the caller's arena.deinit().
fn parseArgv(arena: std.mem.Allocator, argv: []const [*:0]const u8, base: Config) !Parsed {
    var env = std.process.Environ.Map.init(arena);
    const args: std.process.Args = .{ .vector = argv };
    return parse(std.testing.io, arena, args, &env, base);
}

test "parse: bare positional becomes a run prompt" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const p = try parseArgv(a, &.{ "tau", "hello", "world" }, .{});
    try std.testing.expectEqual(Action.run, p.action);
    try std.testing.expectEqualStrings("hello world", p.config.prompt.?);
}

test "parse: no args shows help" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const p = try parseArgv(a, &.{"tau"}, .{});
    try std.testing.expectEqual(Action.help, p.action);
    try std.testing.expect(p.help_requested);
    try std.testing.expect(p.config.prompt == null);
}

test "parse: -h/--help requests help, -v/--version selects version" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    try std.testing.expectEqual(Action.help, (try parseArgv(a, &.{ "tau", "-h" }, .{})).action);
    try std.testing.expectEqual(Action.help, (try parseArgv(a, &.{ "tau", "--help" }, .{})).action);
    try std.testing.expectEqual(Action.version, (try parseArgv(a, &.{ "tau", "-v" }, .{})).action);
    try std.testing.expectEqual(Action.version, (try parseArgv(a, &.{ "tau", "--version" }, .{})).action);
    try std.testing.expectEqual(Action.help_json, (try parseArgv(a, &.{ "tau", "--help-json" }, .{})).action);
}

test "parse: boolean flags toggle config" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const p = try parseArgv(a, &.{ "tau", "--no-stream", "--no-tools", "--thinking", "--debug", "--dry-run", "--no-compact", "hi" }, .{});
    try std.testing.expectEqual(Action.run, p.action);
    try std.testing.expect(!p.config.stream);
    try std.testing.expect(p.config.no_tools);
    try std.testing.expect(p.config.thinking);
    try std.testing.expect(p.config.debug);
    try std.testing.expect(p.config.dry_run);
    try std.testing.expect(!p.config.auto_compact);

    // Short aliases: -nt == --no-tools.
    const q = try parseArgv(a, &.{ "tau", "-nt", "hi" }, .{});
    try std.testing.expect(q.config.no_tools);

    // --stream re-enables streaming after a config-file default of false.
    const r = try parseArgv(a, &.{ "tau", "--stream", "hi" }, .{ .stream = false });
    try std.testing.expect(r.config.stream);
}

test "parse: numeric flags parse and validate" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const p = try parseArgv(a, &.{ "tau", "--temperature", "0.2", "--max-tokens", "1024", "--timeout-ms", "9000", "--max-iterations", "7", "--context-window", "65536", "hi" }, .{});
    try std.testing.expectEqual(@as(f32, 0.2), p.config.temperature);
    try std.testing.expectEqual(@as(u32, 1024), p.config.max_tokens.?);
    try std.testing.expectEqual(@as(i64, 9000), p.config.timeout_ms);
    try std.testing.expectEqual(@as(u32, 7), p.config.max_iterations);
    try std.testing.expectEqual(@as(u32, 65536), p.config.context_window);

    // Invalid numeric values surface a descriptive error, not a crash.
    const e1 = try parseArgv(a, &.{ "tau", "--temperature", "hot" }, .{});
    try std.testing.expectEqual(Action.err, e1.action);
    try std.testing.expectEqualStrings("invalid --temperature: hot", e1.err_msg.?);

    const e2 = try parseArgv(a, &.{ "tau", "--max-tokens", "lots" }, .{});
    try std.testing.expectEqual(Action.err, e2.action);
    try std.testing.expectEqualStrings("invalid --max-tokens: lots", e2.err_msg.?);

    const e3 = try parseArgv(a, &.{ "tau", "--context-window", "wide" }, .{});
    try std.testing.expectEqual(Action.err, e3.action);
    try std.testing.expectEqualStrings("invalid --context-window: wide", e3.err_msg.?);
}

test "parse: missing value for a flag that needs one" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const p = try parseArgv(a, &.{ "tau", "--session" }, .{});
    try std.testing.expectEqual(Action.err, p.action);
    try std.testing.expectEqualStrings("missing value for --session", p.err_msg.?);

    const q = try parseArgv(a, &.{ "tau", "--model" }, .{});
    try std.testing.expectEqual(Action.err, q.action);
    try std.testing.expectEqualStrings("missing value for --model", q.err_msg.?);
}

test "parse: unknown option is rejected" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const p = try parseArgv(a, &.{ "tau", "--nope" }, .{});
    try std.testing.expectEqual(Action.err, p.action);
    try std.testing.expectEqualStrings("unknown option: --nope", p.err_msg.?);
}

test "parse: --role accepts known roles and rejects others" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    try std.testing.expectEqual(cfgmod.Role.author, (try parseArgv(a, &.{ "tau", "--role", "author", "hi" }, .{})).config.role);
    try std.testing.expectEqual(cfgmod.Role.critic, (try parseArgv(a, &.{ "tau", "--role", "critic", "hi" }, .{})).config.role);
    try std.testing.expectEqual(cfgmod.Role.coordinator, (try parseArgv(a, &.{ "tau", "--role", "coordinator", "hi" }, .{})).config.role);
    try std.testing.expectEqual(cfgmod.Role.none, (try parseArgv(a, &.{ "tau", "--role", "none", "hi" }, .{})).config.role);

    const e = try parseArgv(a, &.{ "tau", "--role", "boss", "hi" }, .{});
    try std.testing.expectEqual(Action.err, e.action);
    try std.testing.expectEqualStrings("invalid --role (want author|critic|coordinator|none): boss", e.err_msg.?);
}

test "parse: --mode accepts text|json and rejects others" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    try std.testing.expectEqual(cfgmod.OutputMode.text, (try parseArgv(a, &.{ "tau", "--mode", "text", "hi" }, .{})).config.mode);
    try std.testing.expectEqual(cfgmod.OutputMode.json, (try parseArgv(a, &.{ "tau", "--mode", "json", "hi" }, .{})).config.mode);

    const e = try parseArgv(a, &.{ "tau", "--mode", "yaml", "hi" }, .{});
    try std.testing.expectEqual(Action.err, e.action);
    try std.testing.expectEqualStrings("invalid --mode (want text|json): yaml", e.err_msg.?);
}

test "parse: --tools / --exclude-tools split CSV and trim whitespace" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const p = try parseArgv(a, &.{ "tau", "--tools", "bash, read , write", "--exclude-tools", "grep", "hi" }, .{});
    const allow = p.config.tools_allow.?;
    try std.testing.expectEqual(@as(usize, 3), allow.len);
    try std.testing.expectEqualStrings("bash", allow[0]);
    try std.testing.expectEqualStrings("read", allow[1]);
    try std.testing.expectEqualStrings("write", allow[2]);
    const deny = p.config.tools_deny.?;
    try std.testing.expectEqual(@as(usize, 1), deny.len);
    try std.testing.expectEqualStrings("grep", deny[0]);
}

test "parse: system prompt parts join with newlines" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const p = try parseArgv(a, &.{ "tau", "--system-prompt", "base", "--append-system-prompt", "more", "hi" }, .{});
    try std.testing.expectEqualStrings("base\nmore", p.config.system_prompt.?);

    // A later --system-prompt resets earlier parts.
    const q = try parseArgv(a, &.{ "tau", "--append-system-prompt", "dropped", "--system-prompt", "fresh", "hi" }, .{});
    try std.testing.expectEqualStrings("fresh", q.config.system_prompt.?);
}

// ── Provider / model resolution ──────────────────────────────────────────────

test "parse: default provider resolves to the first provider table entry" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const p = try parseArgv(a, &.{ "tau", "hi" }, .{});
    const want = provider_mod.providers[0];
    try std.testing.expectEqualStrings(want.name, p.config.provider);
    try std.testing.expectEqualStrings(want.endpoint, p.config.endpoint);
    try std.testing.expectEqualStrings(want.default_model, p.config.model);
}

test "parse: --provider sets endpoint and provider default model" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const p = try parseArgv(a, &.{ "tau", "--provider", "openai", "hi" }, .{});
    const oai = provider_mod.findProvider("openai").?;
    try std.testing.expectEqualStrings("openai", p.config.provider);
    try std.testing.expectEqualStrings(oai.endpoint, p.config.endpoint);
    try std.testing.expectEqualStrings(oai.default_model, p.config.model);
    try std.testing.expectEqual(oai.context_window, p.config.context_window);
}

test "parse: --model provider/id form sets both provider and model" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const p = try parseArgv(a, &.{ "tau", "--model", "deepseek/deepseek-reasoner", "hi" }, .{});
    try std.testing.expectEqualStrings("deepseek", p.config.provider);
    try std.testing.expectEqualStrings("deepseek-reasoner", p.config.model);
    try std.testing.expectEqualStrings(provider_mod.findProvider("deepseek").?.endpoint, p.config.endpoint);
}

test "parse: --model without slash keeps the current provider" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const p = try parseArgv(a, &.{ "tau", "--model", "my-custom-model", "hi" }, .{});
    try std.testing.expectEqualStrings(provider_mod.providers[0].name, p.config.provider);
    try std.testing.expectEqualStrings("my-custom-model", p.config.model);
}

test "parse: explicit --provider wins over provider implied by --model" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    // --provider precedes --model: provider_opt is already set, so the slash
    // prefix only contributes the model id, not the provider.
    const p = try parseArgv(a, &.{ "tau", "--provider", "openai", "--model", "deepseek/x", "hi" }, .{});
    try std.testing.expectEqualStrings("openai", p.config.provider);
    try std.testing.expectEqualStrings("x", p.config.model);
}

test "parse: a config-file custom model survives provider defaulting" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    // base.model differs from providers[0].default_model → keep it even when no
    // --model flag is given (config-file precedence over provider default).
    const p = try parseArgv(a, &.{ "tau", "hi" }, .{ .model = "configured-model" });
    try std.testing.expectEqualStrings("configured-model", p.config.model);
}

test "parse: switching provider drops a config-file model tied to the old provider" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    // The config file has a custom xiaomi model; switching to openai should not
    // reuse that provider-specific model.
    const base = Config{ .provider = "xiaomi", .model = "mimo-custom" };
    const p = try parseArgv(a, &.{ "tau", "--provider", "openai", "hi" }, base);
    try std.testing.expectEqualStrings("openai", p.config.provider);
    try std.testing.expectEqualStrings(provider_mod.findProvider("openai").?.default_model, p.config.model);
}

test "parse: config-file provider with no model uses that provider's default" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    // Config only sets provider. base.model is still the in-code default, so it
    // should be replaced with the configured provider's default model.
    const base = Config{ .provider = "openai" };
    const p = try parseArgv(a, &.{ "tau", "hi" }, base);
    try std.testing.expectEqualStrings("openai", p.config.provider);
    try std.testing.expectEqualStrings(provider_mod.findProvider("openai").?.default_model, p.config.model);
}

test "parse: unknown provider is rejected" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const p = try parseArgv(a, &.{ "tau", "--provider", "acme", "hi" }, .{});
    try std.testing.expectEqual(Action.err, p.action);
    // Message wording is owned by unknownProviderErr (lists valid providers); assert the essentials.
    try std.testing.expect(std.mem.indexOf(u8, p.err_msg.?, "unknown provider") != null);
    try std.testing.expect(std.mem.indexOf(u8, p.err_msg.?, "acme") != null);
}

test "parse: --api-key overrides, otherwise base api_key is preserved" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const p = try parseArgv(a, &.{ "tau", "--api-key", "sk-flag", "hi" }, .{ .api_key = "sk-base" });
    try std.testing.expectEqualStrings("sk-flag", p.config.api_key.?);

    const q = try parseArgv(a, &.{ "tau", "hi" }, .{ .api_key = "sk-base" });
    try std.testing.expectEqualStrings("sk-base", q.config.api_key.?);
}

// ── Subcommands: acp / models / skills / fleet ───────────────────────────────

test "parse: acp subcommands and validation" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const serve = try parseArgv(a, &.{ "tau", "acp" }, .{});
    try std.testing.expectEqual(Action.acp, serve.action);
    try std.testing.expectEqual(cfgmod.AcpSub.serve, serve.config.acp_sub);

    const start = try parseArgv(a, &.{ "tau", "acp", "start", "--acp-socket", "/tmp/tau.sock" }, .{});
    try std.testing.expectEqual(cfgmod.AcpSub.start, start.config.acp_sub);
    try std.testing.expectEqualStrings("/tmp/tau.sock", start.config.acp_socket.?);

    const bad = try parseArgv(a, &.{ "tau", "acp", "--frob" }, .{});
    try std.testing.expectEqual(Action.err, bad.action);
    try std.testing.expectEqualStrings("unknown acp argument: --frob", bad.err_msg.?);

    const bad_iter = try parseArgv(a, &.{ "tau", "acp", "--max-iterations", "ten" }, .{});
    try std.testing.expectEqual(Action.err, bad_iter.action);
    try std.testing.expectEqualStrings("invalid --max-iterations: ten", bad_iter.err_msg.?);
}

test "parse: models subcommand" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const p = try parseArgv(a, &.{ "tau", "models" }, .{});
    try std.testing.expectEqual(Action.models, p.action);
}

test "parse: skills subcommand validation" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const list = try parseArgv(a, &.{ "tau", "skills", "list" }, .{});
    try std.testing.expectEqual(Action.skills, list.action);
    try std.testing.expectEqualStrings("list", list.config.skills_sub.?);

    const search = try parseArgv(a, &.{ "tau", "skills", "search", "deploy" }, .{});
    try std.testing.expectEqualStrings("search", search.config.skills_sub.?);
    try std.testing.expectEqualStrings("deploy", search.config.skills_arg.?);

    const none = try parseArgv(a, &.{ "tau", "skills" }, .{});
    try std.testing.expectEqual(Action.err, none.action);
    try std.testing.expectEqualStrings("skills subcommand required: list | search | load", none.err_msg.?);

    const bad = try parseArgv(a, &.{ "tau", "skills", "frob" }, .{});
    try std.testing.expectEqual(Action.err, bad.action);
    try std.testing.expectEqualStrings("invalid skills subcommand (want list|search|load): frob", bad.err_msg.?);
}

test "parse: fleet run resolves provider and captures goal" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const p = try parseArgv(a, &.{ "tau", "fleet", "run", "--goal", "ship it", "--sequential" }, .{});
    try std.testing.expectEqual(Action.fleet, p.action);
    try std.testing.expectEqualStrings("run", p.config.fleet_sub.?);
    try std.testing.expectEqualStrings("ship it", p.config.fleet_goal.?);
    try std.testing.expect(!p.config.fleet_parallel);
    // Provider resolution happens inline for the fleet early-return path.
    try std.testing.expectEqualStrings(provider_mod.providers[0].endpoint, p.config.endpoint);
}

test "parse: fleet positional id and validation errors" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const status = try parseArgv(a, &.{ "tau", "fleet", "status", "job-42" }, .{});
    try std.testing.expectEqualStrings("status", status.config.fleet_sub.?);
    try std.testing.expectEqualStrings("job-42", status.config.fleet_id.?);

    const none = try parseArgv(a, &.{ "tau", "fleet" }, .{});
    try std.testing.expectEqual(Action.err, none.action);
    try std.testing.expectEqualStrings("fleet subcommand required: run | status | list | logs | cancel", none.err_msg.?);

    const bad = try parseArgv(a, &.{ "tau", "fleet", "frob" }, .{});
    try std.testing.expectEqual(Action.err, bad.action);
    try std.testing.expectEqualStrings("unknown fleet argument: frob", bad.err_msg.?);
}

test "parse: /goal prompt switches into goal mode and disables streaming" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const p = try parseArgv(a, &.{ "tau", "/goal", "build the parser" }, .{});
    try std.testing.expectEqual(Action.run, p.action);
    try std.testing.expectEqual(cfgmod.GoalAction.set, p.config.goal_action);
    try std.testing.expectEqualStrings("build the parser", p.config.goal.?);
    // `/goal --tokens N` budgets, and a .set goal forces non-streaming.
    try std.testing.expect(!p.config.stream);
}
/// Build "unknown provider 'X' — valid providers: a, b, c (run 'tau models')" error.
fn unknownProviderErr(arena: std.mem.Allocator, given: []const u8) !Parsed {
    var buf: std.ArrayList(u8) = .empty;
    for (cfgmod.providers, 0..) |p, i| {
        if (i != 0) try buf.appendSlice(arena, ", ");
        try buf.appendSlice(arena, p.name);
    }
    const msg = try std.fmt.allocPrint(arena,
        "unknown provider '{s}' — valid providers: {s} (run 'tau models' for details)", .{ given, buf.items });
    return .{ .action = .err, .err_msg = msg };
}
