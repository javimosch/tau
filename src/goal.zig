const std = @import("std");
const cfgmod = @import("config.zig");
const GoalAction = cfgmod.GoalAction;

/// The model emits this token (on its own line) when the objective is verified done.
pub const SENTINEL = "<GOAL_MET>";

/// Appended as a user turn when the model stopped (no tool calls) without the
/// sentinel — pushes it to audit and either confirm completion or keep working.
pub const NUDGE =
    "You stopped without emitting " ++ SENTINEL ++ ". Audit the objective now: " ++
    "verify each requirement is actually satisfied (re-read files / re-run checks). " ++
    "If it is fully complete, briefly confirm and end with " ++ SENTINEL ++ " on its " ++
    "own line. Otherwise continue working toward it using the tools.";

pub const Parsed = struct {
    action: GoalAction,
    objective: ?[]const u8 = null,
    token_budget: ?u64 = null,
};

fn parseBudget(s: []const u8) ?u64 {
    if (s.len == 0) return null;
    var end = s.len;
    var mult: u64 = 1;
    switch (s[s.len - 1]) {
        'k', 'K' => {
            mult = 1_000;
            end -= 1;
        },
        'm', 'M' => {
            mult = 1_000_000;
            end -= 1;
        },
        else => {},
    }
    const n = std.fmt.parseInt(u64, s[0..end], 10) catch return null;
    return n * mult;
}

/// Parse a prompt that begins with "/goal". Returns null if it's not a /goal
/// command (normal prompt). Recognizes subcommands and `/goal [--tokens N] <obj>`.
pub fn parse(prompt: []const u8) ?Parsed {
    const t = std.mem.trim(u8, prompt, " \t\r\n");
    if (!std.mem.startsWith(u8, t, "/goal")) return null;
    var rest = std.mem.trim(u8, t["/goal".len..], " \t\r\n");

    if (rest.len == 0) return Parsed{ .action = .status };
    if (std.mem.eql(u8, rest, "status")) return Parsed{ .action = .status };
    if (std.mem.eql(u8, rest, "pause")) return Parsed{ .action = .pause };
    if (std.mem.eql(u8, rest, "resume")) return Parsed{ .action = .resume_ };
    if (std.mem.eql(u8, rest, "clear")) return Parsed{ .action = .clear };
    if (std.mem.eql(u8, rest, "complete")) return Parsed{ .action = .complete };

    var budget: ?u64 = null;
    if (std.mem.startsWith(u8, rest, "--tokens")) {
        rest = std.mem.trimStart(u8, rest["--tokens".len..], " \t");
        const sp = std.mem.indexOfAny(u8, rest, " \t") orelse rest.len;
        budget = parseBudget(rest[0..sp]);
        rest = std.mem.trimStart(u8, rest[sp..], " \t");
    }
    if (rest.len == 0) return Parsed{ .action = .status };
    return Parsed{ .action = .set, .objective = rest, .token_budget = budget };
}

/// Persistent system directive injected when working a goal. Caller owns result.
pub fn directive(gpa: std.mem.Allocator, objective: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa,
        \\You are operating in GOAL MODE. Objective:
        \\{s}
        \\
        \\Work autonomously using the available tools until the objective is fully
        \\achieved. Before declaring completion, AUDIT your work: verify each part of
        \\the objective is actually done (re-read files, re-run checks). When — and only
        \\when — the objective is fully verified complete, end your final message with
        \\the token {s} on its own line. Do not emit {s} until the work is truly done.
    , .{ objective, SENTINEL, SENTINEL });
}

/// True when content contains the sentinel on its own line (or at the very
/// start/end of the string), preventing false positives from mid-sentence
/// mentions of the token in the model's reasoning text.
pub fn isMet(content: []const u8) bool {
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        if (std.mem.eql(u8, std.mem.trim(u8, line, " \t\r"), SENTINEL)) return true;
    }
    return false;
}

test "parse subcommands and set" {
    try std.testing.expect(parse("hello") == null);
    try std.testing.expectEqual(GoalAction.status, parse("/goal status").?.action);
    try std.testing.expectEqual(GoalAction.status, parse("/goal").?.action);
    try std.testing.expectEqual(GoalAction.pause, parse("/goal pause").?.action);
    try std.testing.expectEqual(GoalAction.resume_, parse("/goal resume").?.action);
    try std.testing.expectEqual(GoalAction.clear, parse("/goal clear").?.action);

    const set = parse("/goal build the thing").?;
    try std.testing.expectEqual(GoalAction.set, set.action);
    try std.testing.expectEqualStrings("build the thing", set.objective.?);

    const budg = parse("/goal --tokens 250K ship it").?;
    try std.testing.expectEqual(@as(u64, 250_000), budg.token_budget.?);
    try std.testing.expectEqualStrings("ship it", budg.objective.?);
}

test "parse complete subcommand" {
    try std.testing.expectEqual(GoalAction.complete, parse("/goal complete").?.action);
}

test "parse --tokens with lowercase k and m suffixes" {
    const k = parse("/goal --tokens 500k do X").?;
    try std.testing.expectEqual(@as(u64, 500_000), k.token_budget.?);
    try std.testing.expectEqualStrings("do X", k.objective.?);

    const m = parse("/goal --tokens 2m do Y").?;
    try std.testing.expectEqual(@as(u64, 2_000_000), m.token_budget.?);

    // --tokens alone (no objective) falls back to status.
    const no_obj = parse("/goal --tokens 100k").?;
    try std.testing.expectEqual(GoalAction.status, no_obj.action);
    try std.testing.expect(no_obj.token_budget == null); // no objective → status branch, budget dropped
}

test "isMet detects sentinel on its own line" {
    try std.testing.expect(isMet("<GOAL_MET>"));
    try std.testing.expect(isMet("work done\n<GOAL_MET>\n"));
    try std.testing.expect(isMet("work done\n  <GOAL_MET>  \n"));
    // Inline mention must NOT trigger.
    try std.testing.expect(!isMet("the <GOAL_MET> token is just referenced here"));
    try std.testing.expect(!isMet(""));
    try std.testing.expect(!isMet("almost done"));
}

test "directive embeds objective and sentinel" {
    const gpa = std.testing.allocator;
    const dir = try directive(gpa, "write the widget");
    defer gpa.free(dir);
    try std.testing.expect(std.mem.indexOf(u8, dir, "write the widget") != null);
    try std.testing.expect(std.mem.indexOf(u8, dir, SENTINEL) != null);
    try std.testing.expect(std.mem.indexOf(u8, dir, "GOAL MODE") != null);
}
