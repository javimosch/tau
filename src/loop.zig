const std = @import("std");
const cfgmod = @import("config.zig");
const agent_mod = @import("agent.zig");
const jsonmod = @import("json.zig");

/// Sentinels for the Author↔Critic micro-loop. The model emits one of these on
/// its own line to signal its terminal verdict. Detected by `hasSentinel`.
pub const READY_SENTINEL = "<READY_FOR_REVIEW>";
pub const APPROVED_SENTINEL = "<APPROVED>";
pub const BLOCKED_SENTINEL = "<BLOCKED>";

/// Default tool allowlists when a role doesn't specify its own.
pub const DEFAULT_AUTHOR_TOOLS = [_][]const u8{ "bash", "read", "write", "edit", "ls", "grep", "find" };
pub const DEFAULT_CRITIC_TOOLS = [_][]const u8{ "read", "ls", "grep", "find" };

/// Reusable Author↔Critic spec (the "what" — not the runtime config). Holds the
/// parts that are constant across both roles. The runtime Config is derived
/// from this per-role in `runAuthorCritic`.
pub const AuthorCriticSpec = struct {
    goal: []const u8,
    deliverables: []const u8,
    /// Optional formal spec / requirements that the Critic will judge against.
    spec_or_requirements: ?[]const u8 = null,
    /// How many Author↔Critic pairs to run before giving up.
    max_iterations: u32 = 8,
    /// Optional override of the tool allowlist for the Author role.
    author_tools: ?[]const []const u8 = null,
    /// Optional override of the tool allowlist for the Critic role (typically
    /// a read-only subset).
    critic_tools: ?[]const []const u8 = null,
    /// Optional soft output-token budget shared across both roles.
    token_budget: ?u64 = null,
    /// Session-name prefix; per-role session is `<prefix>-author` / `<prefix>-critic`.
    session_prefix: []const u8 = "loop",
    /// Per-role tool-calling loop cap. The Author↔Critic PAIRO cap is
    /// `max_iterations`; this is the inner per-turn cap.
    max_inner_iterations: u32 = 50,
};

/// Verdict of a single Critic turn.
pub const Verdict = enum { approved, blocked, inconclusive };

/// Result of a single Critic turn.
pub const CriticTurnResult = struct {
    content: []const u8,
    verdict: Verdict,
    /// When verdict is .blocked, the feedback text (content trimmed of the
    /// sentinel) that the Author should act on next.
    feedback: ?[]const u8 = null,
    tokens_used: u64 = 0,
};

/// Result of a single Author↔Critic iteration pair.
pub const IterResult = struct {
    iteration: u32,
    /// Verbatim assistant output from the Author turn.
    author_content: []const u8,
    /// True if the Author emitted READY_SENTINEL on its own line.
    author_ready: bool,
    /// Verbatim assistant output from the Critic turn.
    critic_content: []const u8,
    critic_verdict: Verdict,
    /// Tokens consumed this iteration (Author + Critic).
    tokens_used: u64 = 0,
};

/// Final status of the whole loop.
pub const FinalStatus = enum {
    /// Critic emitted <APPROVED>.
    approved,
    /// Reached max_iterations without an <APPROVED>.
    max_iterations,
    /// token_budget was hit.
    budget_limited,
    /// Author never emitted <READY_SENTINEL> in a turn.
    author_inconclusive,
};

pub const LoopResult = struct {
    iterations: []const IterResult,
    final_status: FinalStatus,
    total_tokens: u64,
};

/// Build the Author directive (system prompt). Caller owns the result.
pub fn authorDirective(gpa: std.mem.Allocator, spec: AuthorCriticSpec) ![]u8 {
    return std.fmt.allocPrint(gpa,
        \\You are the AUTHOR in an Author↔Critic micro-loop.
        \\
        \\Goal:
        \\{s}
        \\
        \\Deliverables (what "done" looks like):
        \\{s}
        \\
        \\Work autonomously with the available tools. You can read, write, edit,
        \\and run shell commands.
        \\
        \\When — and ONLY when — your work is complete and you have audited it
        \\(re-read files, re-run checks), end your final message with the token
        \\{s} on its own line. Do not emit it prematurely.
        \\
        \\If the previous Critic feedback is appended below your goal, address
        \\every concrete defect before declaring READY.
    , .{ spec.goal, spec.deliverables, READY_SENTINEL });
}

/// Build the Critic directive (system prompt). Caller owns the result.
pub fn criticDirective(gpa: std.mem.Allocator, spec: AuthorCriticSpec) ![]u8 {
    const reqs = spec.spec_or_requirements orelse "(no formal spec — judge against the goal and deliverables above)";
    return std.fmt.allocPrint(gpa,
        \\You are the CRITIC in an Author↔Critic micro-loop.
        \\
        \\Spec / requirements:
        \\{s}
        \\
        \\Deliverables to verify:
        \\{s}
        \\
        \\Your job: ATTACK the current work. Read the spec, read the code, read
        \\the tests, run them, and look for flaws. You have READ-ONLY tools only
        \\(no write/edit/bash). Be specific: file:line, what is wrong, what
        \\should change.
        \\
        \\When your verdict is final, end your message with exactly ONE of:
        \\  {s} — work is correct, complete, and meets the spec.
        \\  {s} — work has defects; describe them concretely so the Author can
        \\            act on the feedback without guessing.
        \\
        \\Do not declare APPROVED just because the code compiles. Audit behavior,
        \\edge cases, missing tests, and spec deviations.
    , .{ reqs, spec.deliverables, APPROVED_SENTINEL, BLOCKED_SENTINEL });
}

/// True if `content` contains `sentinel` on its own line (or at the very
/// start/end of the string). Same convention as `goalmod.isMet`.
pub fn hasSentinel(content: []const u8, sentinel: []const u8) bool {
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        if (std.mem.eql(u8, std.mem.trim(u8, line, " \t\r"), sentinel)) return true;
    }
    return false;
}

/// Extract the feedback (text BEFORE the BLOCKED sentinel, trimmed). The
/// sentinel is expected to be the final line. Returns null if BLOCKED absent.
pub fn extractFeedback(content: []const u8) ?[]const u8 {
    if (!hasSentinel(content, BLOCKED_SENTINEL)) return null;
    if (std.mem.lastIndexOf(u8, content, BLOCKED_SENTINEL)) |idx| {
        return std.mem.trim(u8, content[0..idx], " \t\r\n");
    }
    return null;
}

/// Classify a Critic's output into a Verdict.
pub fn classifyCritic(content: []const u8) Verdict {
    if (hasSentinel(content, APPROVED_SENTINEL)) return .approved;
    if (hasSentinel(content, BLOCKED_SENTINEL)) return .blocked;
    return .inconclusive;
}

/// Run one Author or Critic turn by delegating to `agent.run()`. The runtime
/// Config is built from the base cfg + role-specific overrides (sentinel,
/// tools, session name, feedback injection).
fn runRole(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    base_cfg: cfgmod.Config,
    env_map: *std.process.Environ.Map,
    role: cfgmod.Role,
    spec: AuthorCriticSpec,
    iter_index: u32,
    feedback: ?[]const u8,
) !u64 {
    var cfg = base_cfg;
    cfg.role = role;
    cfg.max_iterations = spec.max_inner_iterations;
    // The inner agent loop's goal-mode check uses a fixed sentinel (<GOAL_MET>);
    // for the A/C loop we need to pass our own sentinel. We do that by
    // piggy-backing on the goal directive but overriding the sentinel check:
    //   - Author: exit when READY_SENTINEL appears in the assistant turn
    //   - Critic: exit when APPROVED or BLOCKED appears
    // We set `goal_action = .set` with a synthetic objective so the agent
    // injects the goal-mode directive, then patch the sentinel via the
    // feedback_message field. The actual sentinel comparison happens in
    // agent.zig via the `exit_sentinel` field — see step 2.
    cfg.goal_action = .set;
    cfg.goal = switch (role) {
        .author => try std.fmt.allocPrint(arena, "AUTHOR turn for item: {s}", .{spec.goal}),
        .critic => try std.fmt.allocPrint(arena, "CRITIC turn for item: {s}", .{spec.goal}),
        .coordinator => try std.fmt.allocPrint(arena, "COORDINATOR for: {s}", .{spec.goal}),
        .none => unreachable,
    };
    cfg.exit_sentinel = switch (role) {
        .author => READY_SENTINEL,
        .critic => APPROVED_SENTINEL, // BLOCKED is also a valid exit; agent.zig handles both
        .coordinator, .none => null,
    };
    cfg.tools_allow = switch (role) {
        .author => spec.author_tools orelse &DEFAULT_AUTHOR_TOOLS,
        .critic => spec.critic_tools orelse &DEFAULT_CRITIC_TOOLS,
        .coordinator, .none => null,
    };
    cfg.feedback_message = feedback;
    cfg.session = try std.fmt.allocPrint(arena, "{s}-{s}-{d}", .{
        spec.session_prefix,
        @tagName(role),
        iter_index,
    });
    const result = try agent_mod.run(io, gpa, arena, cfg, env_map);
    return result.tokens_out;
}

/// Run the Author↔Critic loop end-to-end. Each iteration: Author turn, then
/// Critic turn. The Critic's feedback (if any) is fed into the next Author turn.
/// Loop terminates on Critic APPROVED, max_iterations, or token_budget.
pub fn runAuthorCritic(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    base_cfg: cfgmod.Config,
    env_map: *std.process.Environ.Map,
    spec: AuthorCriticSpec,
) !LoopResult {
    var iterations = std.ArrayList(IterResult).empty;
    var total_tokens: u64 = 0;
    var last_feedback: ?[]const u8 = null;
    var final_status: FinalStatus = .max_iterations;

    var iter: u32 = 0;
    while (iter < spec.max_iterations) : (iter += 1) {
        // --- Author turn ---
        const author_tokens = runRole(io, gpa, arena, base_cfg, env_map, .author, spec, iter, last_feedback) catch |err| {
            // Treat tool/IO failures as inconclusive; surface to caller via status.
            const it = IterResult{
                .iteration = iter,
                .author_content = try std.fmt.allocPrint(gpa, "[error] author turn failed: {s}", .{@errorName(err)}),
                .author_ready = false,
                .critic_content = "",
                .critic_verdict = .inconclusive,
                .tokens_used = total_tokens,
            };
            try iterations.append(gpa, it);
            final_status = .author_inconclusive;
            break;
        };
        total_tokens += author_tokens;

        // Pull the last assistant message from the session JSON to inspect for
        // READY_SENTINEL. (We can't read it from `agent.run()` directly because
        // it doesn't return the final content; the session is the source of
        // truth.) If the session can't be loaded, treat as inconclusive.
        const author_session = try std.fmt.allocPrint(arena, "{s}-author-{d}", .{ spec.session_prefix, iter });
        const author_content = blk: {
            if (try sessionLastAssistant(io, arena, env_map, author_session)) |c| break :blk c;
            break :blk "";
        };
        const author_ready = hasSentinel(author_content, READY_SENTINEL);
        if (!author_ready) {
            try iterations.append(gpa, .{
                .iteration = iter,
                .author_content = author_content,
                .author_ready = false,
                .critic_content = "",
                .critic_verdict = .inconclusive,
                .tokens_used = total_tokens,
            });
            final_status = .author_inconclusive;
            break;
        }

        // --- Critic turn ---
        const critic_tokens = runRole(io, gpa, arena, base_cfg, env_map, .critic, spec, iter, null) catch |err| {
            try iterations.append(gpa, .{
                .iteration = iter,
                .author_content = author_content,
                .author_ready = true,
                .critic_content = try std.fmt.allocPrint(gpa, "[error] critic turn failed: {s}", .{@errorName(err)}),
                .critic_verdict = .inconclusive,
                .tokens_used = total_tokens,
            });
            final_status = .author_inconclusive;
            break;
        };
        total_tokens += critic_tokens;

        const critic_session = try std.fmt.allocPrint(arena, "{s}-critic-{d}", .{ spec.session_prefix, iter });
        const critic_content = blk: {
            if (try sessionLastAssistant(io, arena, env_map, critic_session)) |c| break :blk c;
            break :blk "";
        };
        const verdict = classifyCritic(critic_content);
        const feedback: ?[]const u8 = if (verdict == .blocked) extractFeedback(critic_content) else null;

        try iterations.append(gpa, .{
            .iteration = iter,
            .author_content = author_content,
            .author_ready = true,
            .critic_content = critic_content,
            .critic_verdict = verdict,
            .tokens_used = total_tokens,
        });

        switch (verdict) {
            .approved => {
                final_status = .approved;
                break;
            },
            .blocked => {
                last_feedback = feedback;
            },
            .inconclusive => {
                // Treat as soft-block: feed the whole critic content back.
                last_feedback = critic_content;
            },
        }

        if (spec.token_budget) |b| if (total_tokens >= b) {
            final_status = .budget_limited;
            break;
        };
    }

    return LoopResult{
        .iterations = try iterations.toOwnedSlice(gpa),
        .final_status = final_status,
        .total_tokens = total_tokens,
    };
}

/// Read the last assistant message content from a session JSON file. Returns
/// null if the session doesn't exist or has no assistant turns.
fn sessionLastAssistant(
    io: std.Io,
    arena: std.mem.Allocator,
    env_map: *std.process.Environ.Map,
    name: []const u8,
) !?[]const u8 {
    const session_mod = @import("session.zig");
    const st = (try session_mod.load(io, arena, env_map, name)) orelse return null;
    var i: ?usize = null;
    for (st.messages, 0..) |m, idx| {
        if (std.mem.eql(u8, m.role, "assistant")) i = idx;
    }
    const idx = i orelse return null;
    return st.messages[idx].content;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "hasSentinel detects standalone line" {
    try std.testing.expect(hasSentinel("all done\n<APPROVED>\n", APPROVED_SENTINEL));
    try std.testing.expect(hasSentinel("<APPROVED>", APPROVED_SENTINEL));
    try std.testing.expect(hasSentinel("READY\n<READY_FOR_REVIEW>", READY_SENTINEL));
    try std.testing.expect(hasSentinel("flaw on line 7\n<BLOCKED>\nmore", BLOCKED_SENTINEL));
    // Mid-sentence mention is NOT a sentinel hit.
    try std.testing.expect(!hasSentinel("the <APPROVED> token is used", APPROVED_SENTINEL));
    try std.testing.expect(!hasSentinel("", APPROVED_SENTINEL));
}

test "extractFeedback pulls text before BLOCKED" {
    const fb = extractFeedback("fix X on line 3\n<BLOCKED>\n") orelse "";
    try std.testing.expectEqualStrings("fix X on line 3", fb);
    try std.testing.expect(extractFeedback("just <APPROVED> text") == null);
    try std.testing.expect(extractFeedback("") == null);
}

test "classifyCritic returns the right verdict" {
    try std.testing.expectEqual(Verdict.approved, classifyCritic("looks good\n<APPROVED>\n"));
    try std.testing.expectEqual(Verdict.blocked, classifyCritic("defect here\n<BLOCKED>\n"));
    try std.testing.expectEqual(Verdict.inconclusive, classifyCritic("I'm still thinking about this"));
    // Approved takes precedence if both somehow appear.
    try std.testing.expectEqual(Verdict.approved, classifyCritic("ok\n<APPROVED>\n<BLOCKED>"));
}

test "directives embed goal and deliverables" {
    const a = std.testing.allocator;
    const spec = AuthorCriticSpec{
        .goal = "build the thing",
        .deliverables = "src/thing.zig exists and zig build succeeds",
        .spec_or_requirements = "Acceptance: zig build && zig build test pass",
    };
    const a_dir = try authorDirective(a, spec);
    defer a.free(a_dir);
    try std.testing.expect(std.mem.indexOf(u8, a_dir, "build the thing") != null);
    try std.testing.expect(std.mem.indexOf(u8, a_dir, "src/thing.zig exists") != null);
    try std.testing.expect(std.mem.indexOf(u8, a_dir, READY_SENTINEL) != null);

    const c_dir = try criticDirective(a, spec);
    defer a.free(c_dir);
    try std.testing.expect(std.mem.indexOf(u8, c_dir, "Acceptance: zig build") != null);
    try std.testing.expect(std.mem.indexOf(u8, c_dir, APPROVED_SENTINEL) != null);
    try std.testing.expect(std.mem.indexOf(u8, c_dir, BLOCKED_SENTINEL) != null);
    try std.testing.expect(std.mem.indexOf(u8, c_dir, "READ-ONLY") != null);
}
