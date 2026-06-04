const std = @import("std");
const cfgmod = @import("config.zig");
const goalmod = @import("goal.zig");
const Config = cfgmod.Config;

pub const Action = enum { run, help, version, help_json, acp, err };

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

    // `tau acp <start|stop|status|serve> [--acp-socket PATH]` — handled before
    // the generic flag/prompt parsing (acp is a command, not a prompt).
    if (argv.len > 0 and eq(argv[0], "acp")) {
        var acfg: Config = base;
        acfg.acp_sub = .serve;
        acfg.max_iterations = 25; // ACP default: exploratory turns need headroom
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
        return errResult(arena, "unknown provider: {s}", .{prov_name});
    cfg.provider = p.name;
    cfg.endpoint = p.endpoint;
    // Model precedence: --model > config-file model (if non-default) > provider default.
    if (model_opt) |m| {
        cfg.model = m;
    } else if (std.mem.eql(u8, base.model, cfgmod.providers[0].default_model)) {
        cfg.model = p.default_model;
    } // else keep base.model (config-file supplied a custom model)
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

    // Handle --help: respect --mode (default json), but --help-json is explicit
    if (help_requested) {
        const action: Action = if (cfg.mode == .json) .help_json else .help;
        return .{ .action = action, .config = cfg, .help_requested = true };
    }

    // No args and no prompt: show help (instead of empty response)
    if (cfg.prompt == null and sys_parts.items.len == 0 and file_parts.items.len == 0) {
        const action: Action = if (cfg.mode == .json) .help_json else .help;
        return .{ .action = action, .config = cfg, .help_requested = true };
    }

    _ = env; // env-key resolution happens later via config.resolveApiKey
    return .{ .action = .run, .config = cfg };
}

fn missing(arena: std.mem.Allocator, flag: []const u8) Parsed {
    return errResult(arena, "missing value for {s}", .{flag}) catch
        .{ .action = .err, .err_msg = "missing value" };
}

fn errResult(arena: std.mem.Allocator, comptime fmt: []const u8, fmtargs: anytype) !Parsed {
    return .{ .action = .err, .err_msg = try std.fmt.allocPrint(arena, fmt, fmtargs) };
}
