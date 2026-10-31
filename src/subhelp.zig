//! Per-subcommand help texts for `tau <sub> -h|--help`.
//!
//! Every registered subcommand gets a dedicated, focused help page — usage,
//! arguments/options, and a runnable `Examples:` section — instead of making
//! the user hunt through the monolithic `tau --help` output. `Examples:`
//! blocks hold copy-pasteable invocations; the tests below prove every one
//! of them parses to its real action (never .err), so they cannot drift into
//! broken commands. Goldens under tests/golden/help-*.stdout byte-lock the
//! rendered output (regenerate: GOLDEN_UPDATE=1 ./scripts/smoke.sh --group
//! golden-help).

const std = @import("std");
const argsmod = @import("args.zig");
const cfgmod = @import("config.zig");

const acp_help =
    \\tau acp - Agent Client Protocol server (JSON-RPC for editor clients)
    \\
    \\Usage:
    \\  tau acp serve [--acp-socket <path>] [--max-iterations <n>]
    \\  tau acp start [--acp-socket <path>]
    \\  tau acp stop
    \\  tau acp status
    \\
    \\Commands:
    \\  serve                    Run the JSON-RPC agent server on stdio
    \\                           (default when no command is given), or on
    \\                           a Unix socket with --acp-socket
    \\  start                    Launch the server as a background daemon
    \\  stop                     Stop the background daemon
    \\  status                   Report daemon status as JSON
    \\
    \\Options:
    \\      --acp-socket <path>  Unix socket path
    \\                           (default ~/.config/tau/acp.sock)
    \\      --max-iterations <n> Tool-loop runaway backstop (default: 100)
    \\
    \\Examples:
    \\  tau acp serve
    \\  tau acp serve --acp-socket /tmp/tau.sock
    \\  tau acp start
    \\  tau acp status
    \\  tau acp stop
    \\
;

const bug_help =
    \\tau bug - file a pre-filled GitHub issue with redacted diagnostics
    \\
    \\Usage:
    \\  tau bug [options]
    \\
    \\Options:
    \\      --title <text>     Issue title (default "Bug report")
    \\      --body <text>      Description placed above the bundle
    \\      --labels <csv>     Issue labels (default "bug"; "" = none)
    \\      --open             Open the issue URL in the system browser
    \\      --out <path>       Also write the diagnostics bundle to a file
    \\      --no-report        Omit the diagnostics bundle
    \\      --offline/--deep   Passed through to the diagnostic sweep
    \\      --provider <name>  Diagnose an override provider
    \\      --model <id>       Diagnose an override model
    \\      --api-key <key>    Diagnose an override API key
    \\      --shell <name>     Completions shell: bash|zsh|fish|pwsh|all
    \\
    \\Examples:
    \\  tau bug
    \\  tau bug --title "crash on startup" --open
    \\  tau bug --no-report --labels bug,crash
    \\  tau bug --out report.md
    \\
;

const config_help =
    \\tau config - inspect and edit ~/.config/tau/config.json
    \\
    \\Usage:
    \\  tau config show [global flags]       Merged effective config as JSON
    \\                                       (file + env + flags; redacted)
    \\  tau config validate [path]           Validate a config file
    \\                                       (CI/pre-commit friendly)
    \\  tau config set <key> <value> [path]  Schema-checked edit to the FILE
    \\                                       (<field> or keys.<provider>)
    \\  tau config get <key> [path]          Print a value (secrets redacted)
    \\  tau config unset <key> [path]        Remove a key from the file
    \\  tau config edit [path]               Open in $EDITOR; validates on save
    \\  tau config schema                    Print the config file's JSON
    \\                                       Schema (draft 2020-12)
    \\
    \\Options:
    \\      --json             Stable schema-checked JSON (show, validate)
    \\      --mode text|json   Output mode
    \\      --raw              (get only) Print the value unredacted
    \\
    \\Examples:
    \\  tau config show
    \\  tau config show --provider openai
    \\  tau config validate
    \\  tau config set provider openai
    \\  tau config set keys.openai sk-your-key
    \\  tau config get provider
    \\  tau config unset model
    \\  tau config edit
    \\  tau config schema
    \\
;

const doctor_help =
    \\tau doctor - validate your setup (config, credentials, client wiring)
    \\
    \\Usage:
    \\  tau doctor [options]
    \\
    \\Options:
    \\      --provider <name>  Diagnose an override provider
    \\      --model <id>       Diagnose an override model
    \\      --api-key <key>    Diagnose an override API key
    \\      --offline          Skip network checks
    \\      --deep             Also run an authenticated probe (~1 token)
    \\      --probe            Live-verify connectivity + credentials for
    \\                         every provider (~1 token per keyed provider)
    \\      --selftest         Credential-free end-to-end check against a
    \\                         loopback stub provider (no keys, no network)
    \\      --fix              Propose remediations for fixable checks;
    \\                         prompts per fix on a TTY
    \\  -y, --yes              Apply --fix remediations without prompting
    \\      --json             Stream NDJSON check/fix events + verdict
    \\                         (schema/tau-doctor.schema.json)
    \\      --report           Print a redacted Markdown diagnostics bundle
    \\                         for bug reports (mutex with --json)
    \\      --shell <name>     Completions shell: bash|zsh|fish|pwsh|all
    \\                         (default: detect from $SHELL)
    \\
    \\Examples:
    \\  tau doctor
    \\  tau doctor --offline
    \\  tau doctor --selftest
    \\  tau doctor --fix --yes
    \\  tau doctor --probe
    \\  tau doctor --report
    \\
;

const explain_help =
    \\tau explain - offline error catalog lookup (no API key needed)
    \\
    \\Usage:
    \\  tau explain [<code|type>] [--json|--human]
    \\
    \\Arguments:
    \\  <code|type>   Exit code (e.g. 106) or error type (e.g. authfailed);
    \\                omit to list the whole catalog
    \\
    \\Options:
    \\      --json   Stable schema-checked JSON form (default;
    \\               schema/tau-explain.schema.json)
    \\      --human  Render as prose
    \\
    \\Examples:
    \\  tau explain
    \\  tau explain 106
    \\  tau explain authfailed
    \\  tau explain --human 105
    \\
;

const fleet_help =
    \\tau fleet - orchestrate parallel tau workers toward a goal
    \\
    \\Usage:
    \\  tau fleet run --goal <text> [options]
    \\  tau fleet status <id>
    \\  tau fleet list
    \\  tau fleet logs <id>
    \\  tau fleet cancel <id>
    \\
    \\Commands:
    \\  run            Decompose the goal and dispatch workers
    \\  status <id>    Show the fleet manifest (spec + per-item status)
    \\  list           List active fleet ids
    \\  logs <id>      Show per-worker session hints
    \\  cancel <id>    Cancel a running fleet
    \\
    \\Options (run):
    \\      --goal <text>              Objective to decompose (required)
    \\      --items <json>             Pre-supplied items (skip coordinator)
    \\      --schema <json|@file>      JSON Schema for the coordinator reply
    \\      --coordinator-model <id>   Override the coordinator's model
    \\      --worker-model <id>        Override the workers' model
    \\      --provider <name>          Provider override
    \\      --model <id>               Model override
    \\      --api-key <key>            API key override
    \\      --sequential               Run workers one at a time
    \\      --parallel                 Run workers in parallel (default)
    \\
    \\Examples:
    \\  tau fleet run --goal "ship the redesign"
    \\  tau fleet run --goal "add tests" --sequential
    \\  tau fleet run --goal "x" --items '{"items":[{"title":"t","prompt":"p"}]}'
    \\  tau fleet list
    \\  tau fleet status fleet-2026-10-31
    \\  tau fleet cancel fleet-2026-10-31
    \\
;

const guide_help =
    \\tau guide - embedded operator manual (drive tau with no external docs)
    \\
    \\Usage:
    \\  tau guide [--human]
    \\
    \\Options:
    \\      --human   Render the guide as markdown (default: JSON for agents)
    \\
    \\Examples:
    \\  tau guide
    \\  tau guide --human
    \\
;

const init_help =
    \\tau init - write a commented starter ~/.config/tau/config.json
    \\
    \\Usage:
    \\  tau init [--force] [--stdout] [--provider <name>]
    \\
    \\Options:
    \\      --force            Overwrite an existing config file
    \\      --stdout           Print the starter config without writing it
    \\      --provider <name>  Scaffold for a specific provider
    \\
    \\Examples:
    \\  tau init
    \\  tau init --provider openai
    \\  tau init --stdout
    \\  tau init --force
    \\
;

const models_help =
    \\tau models - list available providers and their default models
    \\
    \\Usage:
    \\  tau models
    \\
    \\Examples:
    \\  tau models
    \\
;

const setup_help =
    \\tau setup - one-shot onboarding (init + completions + clients + doctor)
    \\
    \\Usage:
    \\  tau setup [options]
    \\
    \\Options:
    \\      --shell <name>     Shell completions to install:
    \\                         bash|zsh|fish|pwsh|all
    \\                         (default: detect $SHELL; env TAU_SETUP_SHELL)
    \\      --client <name>    Editor/ACP client config to write:
    \\                         zed|nvim|vscode|jetbrains|windsurf|gemini|
    \\                         claude-desktop|all (env TAU_SETUP_CLIENT)
    \\      --provider <name>  Seed the config scaffold for a provider
    \\      --model <id>       Passed through to the doctor step
    \\      --api-key <key>    Passed through to the doctor step
    \\      --offline          Passed to the doctor step (skip network)
    \\      --deep             Passed to the doctor step (auth'd probe)
    \\  -y, --yes              Approve all write steps (env TAU_YES=1)
    \\      --non-interactive  Unattended contract for scripts/CI: never
    \\                         prompts, never reads stdin
    \\                         (env TAU_NONINTERACTIVE=1)
    \\      --dry-run          Preview every write step; change nothing
    \\
    \\Examples:
    \\  tau setup
    \\  tau setup --dry-run
    \\  tau setup --yes --client zed
    \\  tau setup --shell bash --client claude-desktop --yes
    \\
;

const skills_help =
    \\tau skills - autodiscover and load agent skills (~/.agents/skills/)
    \\
    \\Usage:
    \\  tau skills list
    \\  tau skills search <query>
    \\  tau skills load <name>
    \\
    \\Commands:
    \\  list             List all discoverable skills (JSON)
    \\  search <query>   Search skills by keyword
    \\  load <name>      Load a skill into system context
    \\
    \\Examples:
    \\  tau skills list
    \\  tau skills search memory
    \\  tau skills load agent-memory-toolbox
    \\
;

const upgrade_help =
    \\tau upgrade - self-update in place from the latest release
    \\
    \\Usage:
    \\  tau upgrade [--yes|-y] [--dir <path>] [--dry-run]
    \\
    \\Options:
    \\  -y, --yes        Upgrade without prompting (env TAU_YES=1); a TTY
    \\                   gets a [y/N] prompt instead
    \\      --dir <path> Install destination (default: the running binary's
    \\                   directory; env TAU_INSTALL_DIR)
    \\      --dry-run    Print the resolved plan + release notes; install
    \\                   nothing
    \\
    \\The release notes between your version and the target print before
    \\any install. POSIX-only; on Windows re-run install.ps1.
    \\
    \\Examples:
    \\  tau upgrade --dry-run
    \\  tau upgrade --yes
    \\  tau upgrade --dir ~/.local/bin
    \\
;

const version_help =
    \\tau version - print the version (command form of -v/--version)
    \\
    \\Usage:
    \\  tau version [--verbose] [--check] [--json] [--mode text|json]
    \\
    \\Options:
    \\      --verbose        Include build metadata (git commit, target
    \\                       triple, build date, zig version)
    \\      --check          Non-blocking check for a newer release; always
    \\                       exits 0 (opt out: TAU_NO_UPDATE_CHECK=1)
    \\      --json           Stable {"name","version",...} object for
    \\                       scripts (schema/tau-version.schema.json);
    \\                       mutually exclusive with --mode text
    \\      --mode text|json Output mode
    \\
    \\Examples:
    \\  tau version
    \\  tau version --verbose
    \\  tau version --check
    \\  tau version --json
    \\
;

pub const Entry = struct { name: []const u8, text: []const u8 };

/// One help page per registered subcommand — kept in registered order.
/// The tests below pin this table against the `eq(argv[0], "...")`
/// subcommand literals in args.zig, so a new subcommand without a help
/// page (or a stale page for a removed one) fails the suite.
pub const entries = [_]Entry{
    .{ .name = "acp", .text = acp_help },
    .{ .name = "models", .text = models_help },
    .{ .name = "version", .text = version_help },
    .{ .name = "upgrade", .text = upgrade_help },
    .{ .name = "doctor", .text = doctor_help },
    .{ .name = "bug", .text = bug_help },
    .{ .name = "guide", .text = guide_help },
    .{ .name = "explain", .text = explain_help },
    .{ .name = "skills", .text = skills_help },
    .{ .name = "init", .text = init_help },
    .{ .name = "setup", .text = setup_help },
    .{ .name = "fleet", .text = fleet_help },
    .{ .name = "config", .text = config_help },
};

/// The help text for `tau <name> --help`, or null for the global help.
pub fn lookup(name: []const u8) ?[]const u8 {
    for (entries) |e| {
        if (std.mem.eql(u8, e.name, name)) return e.text;
    }
    return null;
}

// ── Tests ───────────────────────────────────────────────────────────────────

const args_source = @embedFile("args.zig");

/// Iterate `eq(argv[0], "<sub>")` literals — the registered subcommands.
/// Same source-scan contract as the surface tests in main.zig.
fn nextSubcommand(pos: *usize) ?[]const u8 {
    const needle = "eq(argv[0], \"";
    const i = std.mem.indexOfPos(u8, args_source, pos.*, needle) orelse return null;
    const start = i + needle.len;
    const end = std.mem.indexOfPos(u8, args_source, start, "\"") orelse return null;
    pos.* = end + 1;
    return args_source[start..end];
}

/// The action a `tau <sub> ...` invocation must parse to.
fn expectedAction(name: []const u8) argsmod.Action {
    const map = .{
        .{ "acp", argsmod.Action.acp },
        .{ "models", argsmod.Action.models },
        .{ "version", argsmod.Action.version },
        .{ "upgrade", argsmod.Action.upgrade },
        .{ "doctor", argsmod.Action.doctor },
        .{ "bug", argsmod.Action.bug },
        .{ "guide", argsmod.Action.guide },
        .{ "explain", argsmod.Action.explain },
        .{ "skills", argsmod.Action.skills },
        .{ "init", argsmod.Action.init },
        .{ "setup", argsmod.Action.setup },
        .{ "fleet", argsmod.Action.fleet },
        .{ "config", argsmod.Action.config },
    };
    inline for (map) |m| {
        if (std.mem.eql(u8, name, m[0])) return m[1];
    }
    return .run;
}

/// Split an example command line on spaces, honoring '...' and "..."
/// quoting the way a shell would (quotes are stripped, not kept).
fn tokenize(arena: std.mem.Allocator, line: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < line.len) {
        while (i < line.len and line[i] == ' ') i += 1;
        if (i >= line.len) break;
        var tok: std.ArrayList(u8) = .empty;
        while (i < line.len and line[i] != ' ') {
            const c = line[i];
            if (c == '\'' or c == '"') {
                i += 1;
                while (i < line.len and line[i] != c) : (i += 1)
                    try tok.append(arena, line[i]);
                if (i < line.len) i += 1; // closing quote
            } else {
                try tok.append(arena, c);
                i += 1;
            }
        }
        try out.append(arena, try tok.toOwnedSlice(arena));
    }
    return out.toOwnedSlice(arena);
}

test "every registered subcommand has a help entry (and vice versa)" {
    var pos: usize = 0;
    while (nextSubcommand(&pos)) |sub| {
        if (lookup(sub) == null)
            std.debug.print("subhelp.zig has no help text for registered subcommand '{s}'\n", .{sub});
        try std.testing.expect(lookup(sub) != null);
    }
    for (entries) |e| {
        var sp: usize = 0;
        var found = false;
        while (nextSubcommand(&sp)) |sub| {
            if (std.mem.eql(u8, sub, e.name)) found = true;
        }
        if (!found)
            std.debug.print("subhelp.zig entry '{s}' is not a registered subcommand\n", .{e.name});
        try std.testing.expect(found);
    }
}

test "every subcommand help has Usage and a runnable Examples section" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var env = std.process.Environ.Map.init(a);

    for (entries) |e| {
        try std.testing.expect(std.mem.indexOf(u8, e.text, "Usage:") != null);
        try std.testing.expect(std.mem.indexOf(u8, e.text, "Examples:") != null);

        var example_count: usize = 0;
        var in_examples = false;
        var lines = std.mem.splitScalar(u8, e.text, '\n');
        while (lines.next()) |line| {
            if (std.mem.eql(u8, line, "Examples:")) in_examples = true;
            if (!in_examples or !std.mem.startsWith(u8, line, "  tau ")) continue;
            example_count += 1;
            const toks = try tokenize(a, std.mem.trim(u8, line, " "));
            try std.testing.expect(toks.len >= 2);
            try std.testing.expectEqualStrings("tau", toks[0]);
            // The example must exercise the subcommand itself.
            try std.testing.expectEqualStrings(e.name, toks[1]);
            // ...and it must actually parse (runnable, not a typo'd flag).
            const p = try argsmod.parse(std.testing.io, a, toks, &env, .{});
            if (p.action == .err)
                std.debug.print("{s} help example does not parse: {s} ({s})\n", .{ e.name, line, p.err_msg orelse "?" });
            try std.testing.expect(p.action != .err);
            try std.testing.expectEqual(expectedAction(e.name), p.action);
        }
        if (example_count == 0)
            std.debug.print("{s} help has no runnable '  tau {s} ...' examples\n", .{ e.name, e.name });
        try std.testing.expect(example_count > 0);
    }
}

test "lookup returns null for unknown subcommands" {
    try std.testing.expect(lookup("bogus") == null);
    try std.testing.expect(lookup("") == null);
    try std.testing.expect(lookup("acp") != null);
}
