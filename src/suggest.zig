const std = @import("std");

/// Levenshtein edit distance — the names compared here (config keys, flags,
/// subcommands, providers) are short, so a two-row O(n·m) DP is plenty.
/// Returns null on allocation failure.
pub fn editDistance(arena: std.mem.Allocator, a: []const u8, b: []const u8) ?usize {
    var p = arena.alloc(usize, b.len + 1) catch return null;
    var c = arena.alloc(usize, b.len + 1) catch return null;
    for (p, 0..) |*cell, j| cell.* = j;
    for (a, 0..) |ca, i| {
        c[0] = i + 1;
        for (b, 0..) |cb, j| {
            const sub = p[j] + @intFromBool(ca != cb);
            c[j + 1] = @min(@min(c[j] + 1, p[j + 1] + 1), sub);
        }
        std.mem.swap([]usize, &p, &c);
    }
    return p[b.len];
}

/// Nearest candidate within 2 edits, else null — a 1–2 char typo always
/// produces a suggestion, an unrelated name (e.g. "zztopp") never does.
pub fn suggest(arena: std.mem.Allocator, name: []const u8, candidates: []const []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_d: usize = std.math.maxInt(usize);
    for (candidates) |c| {
        const d = editDistance(arena, name, c) orelse continue;
        if (d <= 2 and d < best_d) {
            best = c;
            best_d = d;
        }
    }
    return best;
}

test "editDistance: exact, typo, and unrelated distances" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const arena = ar.allocator();

    try std.testing.expectEqual(@as(?usize, 0), editDistance(arena, "mode", "mode"));
    try std.testing.expectEqual(@as(?usize, 1), editDistance(arena, "temprature", "temperature"));
    try std.testing.expectEqual(@as(?usize, 1), editDistance(arena, "opnai", "openai"));
    try std.testing.expectEqual(@as(?usize, 0), editDistance(arena, "", ""));
    try std.testing.expectEqual(@as(?usize, 3), editDistance(arena, "", "abc"));
    try std.testing.expect(editDistance(arena, "zztopp", "temperature").? > 2);
}

test "suggest: typos resolve to nearest key, unrelated names get none" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const arena = ar.allocator();

    const known_keys = [_][]const u8{ "provider", "model", "mode", "temperature" };
    const provider_names = [_][]const u8{ "openai", "deepseek", "xiaomi" };
    try std.testing.expectEqualStrings("temperature", suggest(arena, "temprature", &known_keys).?);
    try std.testing.expectEqualStrings("openai", suggest(arena, "opnai", &provider_names).?);
    try std.testing.expectEqual(@as(?[]const u8, null), suggest(arena, "zztopp", &known_keys));
    // Exact matches are never "unknown", but suggest still resolves them.
    try std.testing.expectEqualStrings("mode", suggest(arena, "mode", &known_keys).?);
}
