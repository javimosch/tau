const std = @import("std");

/// Unified-diff rendering for the `--dry-run` file previews (`tau setup`,
/// `tau completions install`). `unified` produces `git diff`-style output:
/// `---`/`+++` headers, `@@ -s,c +s,c @@` hunks with three context lines,
/// and `\ No newline at end of file` markers. A null `old` renders a
/// new-file diff (`--- /dev/null`); a null `new` renders a deletion
/// (`+++ /dev/null`). The diff is byte-exact — whatever a real run would
/// write is exactly what the preview shows.

/// Lines of a file, split on '\n' without the terminator. `ends_nl` records
/// whether the file's last byte is '\n' — needed for the `\ No newline`
/// marker and to surface a trailing-newline-only change.
const Lines = struct {
    items: []const []const u8,
    ends_nl: bool,
};

fn splitLines(arena: std.mem.Allocator, s: []const u8) !Lines {
    var list: std.ArrayList([]const u8) = .empty;
    var start: usize = 0;
    for (s, 0..) |c, i| {
        if (c == '\n') {
            try list.append(arena, s[start..i]);
            start = i + 1;
        }
    }
    if (start < s.len) try list.append(arena, s[start..]);
    return .{ .items = list.items, .ends_nl = s.len == 0 or s[s.len - 1] == '\n' };
}

const Op = enum { keep, del, ins };

/// One emitted diff line: `op` over `text`; `oi`/`ni` are the 0-based line
/// index on the old/new side (-1 when the op doesn't consume that side).
const DiffLine = struct { op: Op, oi: i64, ni: i64, text: []const u8 };

/// Past this many DP cells the LCS is skipped and the diff falls back to a
/// whole-file replace hunk — a degenerate but still exact unified diff.
const max_cells: usize = 8_000_000;

/// Longest-common-subsequence edit script over the two line lists. Returns
/// null when the DP table would exceed max_cells (caller falls back to a
/// whole-file replace).
fn editScript(arena: std.mem.Allocator, a: []const []const u8, b: []const []const u8) !?[]Op {
    const n = a.len;
    const m = b.len;
    if (n != 0 and m != 0 and n > max_cells / m) return null;
    // lcs[(i*(m+1))+j] = LCS length of a[i..] vs b[j..]
    var lcs = try arena.alloc(u32, (n + 1) * (m + 1));
    @memset(lcs, 0);
    const stride = m + 1;
    var i: usize = n;
    while (i > 0) : (i -= 1) {
        var j: usize = m;
        while (j > 0) : (j -= 1) {
            const ii = i - 1;
            const jj = j - 1;
            lcs[ii * stride + jj] = if (std.mem.eql(u8, a[ii], b[jj]))
                lcs[i * stride + j] + 1
            else
                @max(lcs[i * stride + jj], lcs[ii * stride + j]);
        }
    }
    var ops: std.ArrayList(Op) = .empty;
    var x: usize = 0;
    var y: usize = 0;
    while (x < n and y < m) {
        if (std.mem.eql(u8, a[x], b[y])) {
            try ops.append(arena, .keep);
            x += 1;
            y += 1;
        } else if (lcs[(x + 1) * stride + y] >= lcs[x * stride + y + 1]) {
            try ops.append(arena, .del);
            x += 1;
        } else {
            try ops.append(arena, .ins);
            y += 1;
        }
    }
    while (x < n) : (x += 1) try ops.append(arena, .del);
    while (y < m) : (y += 1) try ops.append(arena, .ins);
    return ops.items;
}

/// Expand the op list into DiffLine records with per-side indices.
fn diffLines(arena: std.mem.Allocator, a: []const []const u8, b: []const []const u8, ops: []const Op) !std.ArrayList(DiffLine) {
    var out: std.ArrayList(DiffLine) = .empty;
    var oi: i64 = 0;
    var ni: i64 = 0;
    for (ops) |op| {
        switch (op) {
            .keep => {
                try out.append(arena, .{ .op = .keep, .oi = oi, .ni = ni, .text = a[@intCast(oi)] });
                oi += 1;
                ni += 1;
            },
            .del => {
                try out.append(arena, .{ .op = .del, .oi = oi, .ni = -1, .text = a[@intCast(oi)] });
                oi += 1;
            },
            .ins => {
                try out.append(arena, .{ .op = .ins, .oi = -1, .ni = ni, .text = b[@intCast(ni)] });
                ni += 1;
            },
        }
    }
    return out;
}

const context: usize = 3;

/// True when this emitted line is the file's last line on the side it came
/// from AND that side lacks a trailing newline — i.e. it needs the
/// `\ No newline at end of file` marker after it.
fn lastNoNl(l: DiffLine, old_n: usize, new_n: usize, old_ends_nl: bool, new_ends_nl: bool) bool {
    const old_last: i64 = @intCast(old_n);
    const new_last: i64 = @intCast(new_n);
    return switch (l.op) {
        .keep => (!old_ends_nl and l.oi == old_last - 1) or
            (!new_ends_nl and l.ni == new_last - 1),
        .del => !old_ends_nl and l.oi == old_last - 1,
        .ins => !new_ends_nl and l.ni == new_last - 1,
    };
}

fn emitLine(arena: std.mem.Allocator, buf: *std.ArrayList(u8), prefix: u8, l: DiffLine, old_n: usize, new_n: usize, old_ends_nl: bool, new_ends_nl: bool) !void {
    try buf.append(arena, prefix);
    try buf.appendSlice(arena, l.text);
    try buf.append(arena, '\n');
    if (lastNoNl(l, old_n, new_n, old_ends_nl, new_ends_nl))
        try buf.appendSlice(arena, "\\ No newline at end of file\n");
}

/// Emit one hunk: `@@` header, then `lines[lo..hi]` with dels grouped
/// before ins inside each change block.
fn emitHunk(arena: std.mem.Allocator, buf: *std.ArrayList(u8), lines: []const DiffLine, lo: usize, hi: usize, old_n: usize, new_n: usize, old_ends_nl: bool, new_ends_nl: bool) !void {
    var oc: usize = 0;
    var nc: usize = 0;
    var ostart: i64 = -1;
    var nstart: i64 = -1;
    for (lines[lo..hi]) |l| {
        if (l.op != .ins) {
            oc += 1;
            if (ostart < 0) ostart = l.oi;
        }
        if (l.op != .del) {
            nc += 1;
            if (nstart < 0) nstart = l.ni;
        }
    }
    // A 0-count range displays the line index BEFORE which content goes
    // (0-indexed insertion point); a non-empty range is 1-based.
    const os: i64 = if (oc == 0) @max(ostart, 0) else ostart + 1;
    const ns: i64 = if (nc == 0) @max(nstart, 0) else nstart + 1;
    try buf.appendSlice(arena, try std.fmt.allocPrint(arena, "@@ -{d},{d} +{d},{d} @@\n", .{ os, oc, ns, nc }));

    var i = lo;
    while (i < hi) {
        if (lines[i].op == .keep) {
            try emitLine(arena, buf, ' ', lines[i], old_n, new_n, old_ends_nl, new_ends_nl);
            i += 1;
            continue;
        }
        var j = i;
        while (j < hi and lines[j].op != .keep) : (j += 1) {}
        for (lines[i..j]) |l| {
            if (l.op == .del) try emitLine(arena, buf, '-', l, old_n, new_n, old_ends_nl, new_ends_nl);
        }
        for (lines[i..j]) |l| {
            if (l.op == .ins) try emitLine(arena, buf, '+', l, old_n, new_n, old_ends_nl, new_ends_nl);
        }
        i = j;
    }
}

/// Render `old` -> `new` for `path` as a unified diff. `old == null` renders
/// `--- /dev/null` (new file); `new == null` renders `+++ /dev/null`
/// (deletion). Identical inputs render just the headers.
pub fn unified(arena: std.mem.Allocator, path: []const u8, old: ?[]const u8, new: ?[]const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    if (old != null) {
        try buf.appendSlice(arena, "--- a/");
        try buf.appendSlice(arena, path);
    } else {
        try buf.appendSlice(arena, "--- /dev/null");
    }
    try buf.append(arena, '\n');
    if (new != null) {
        try buf.appendSlice(arena, "+++ b/");
        try buf.appendSlice(arena, path);
    } else {
        try buf.appendSlice(arena, "+++ /dev/null");
    }
    try buf.append(arena, '\n');

    const a = try splitLines(arena, old orelse "");
    const b = try splitLines(arena, new orelse "");
    const ops = (try editScript(arena, a.items, b.items)) orelse blk: {
        // Too big for the DP — a whole-file replace is still an exact diff.
        var all: std.ArrayList(Op) = .empty;
        for (a.items) |_| try all.append(arena, .del);
        for (b.items) |_| try all.append(arena, .ins);
        break :blk all.items;
    };
    var lines = try diffLines(arena, a.items, b.items, ops);

    // A trailing-newline-only change keeps identical last lines — the LCS
    // pairs them as context, but the bytes do differ: rewrite that final
    // pairing as -/+ so the marker shows what actually changes.
    if (a.ends_nl != b.ends_nl and a.items.len > 0 and b.items.len > 0) {
        const al: i64 = @intCast(a.items.len - 1);
        const bl: i64 = @intCast(b.items.len - 1);
        for (lines.items, 0..) |*l, idx| {
            if (l.op == .keep and l.oi == al and l.ni == bl) {
                const del: DiffLine = .{ .op = .del, .oi = l.oi, .ni = -1, .text = l.text };
                const ins: DiffLine = .{ .op = .ins, .oi = -1, .ni = l.ni, .text = l.text };
                l.* = del;
                try lines.insert(arena, idx + 1, ins);
                break;
            }
        }
    }

    // Find maximal changed regions, widen by `context`, merge overlaps.
    var i: usize = 0;
    const items = lines.items;
    while (i < items.len) {
        if (items[i].op == .keep) {
            i += 1;
            continue;
        }
        const lo = if (i >= context) i - context else 0;
        var last_change = i;
        var j = i;
        while (j < items.len) : (j += 1) {
            if (items[j].op != .keep) {
                last_change = j;
            } else if (j - last_change > 2 * context) {
                break;
            }
        }
        const hi = @min(last_change + context + 1, items.len);
        try emitHunk(arena, &buf, items, lo, hi, a.items.len, b.items.len, a.ends_nl, b.ends_nl);
        i = hi;
    }
    return buf.items;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "unified: new file renders /dev/null source" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const d = try unified(ar.allocator(), "/h/cfg.json", null, "{\n  \"a\": 1\n}\n");
    try std.testing.expectEqualStrings(
        \\--- /dev/null
        \\+++ b//h/cfg.json
        \\@@ -0,0 +1,3 @@
        \\+{
        \\+  "a": 1
        \\+}
        \\
    , d);
}

test "unified: deletion renders /dev/null target" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const d = try unified(ar.allocator(), "/h/x", "one\ntwo\n", null);
    try std.testing.expectEqualStrings(
        \\--- a//h/x
        \\+++ /dev/null
        \\@@ -1,2 +0,0 @@
        \\-one
        \\-two
        \\
    , d);
}

test "unified: in-place edit with context lines" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const d = try unified(ar.allocator(), "/h/f", "a\nb\nc\nd\ne\nf\ng\n", "a\nb\nc\nD\ne\nf\ng\n");
    try std.testing.expectEqualStrings(
        \\--- a//h/f
        \\+++ b//h/f
        \\@@ -1,7 +1,7 @@
        \\ a
        \\ b
        \\ c
        \\-d
        \\+D
        \\ e
        \\ f
        \\ g
        \\
    , d);
}

test "unified: distant changes produce separate hunks" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const d = try unified(ar.allocator(), "/f", "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n", "1\nX\n3\n4\n5\n6\n7\n8\n9\nY\n");
    try std.testing.expectEqualStrings(
        \\--- a//f
        \\+++ b//f
        \\@@ -1,5 +1,5 @@
        \\ 1
        \\-2
        \\+X
        \\ 3
        \\ 4
        \\ 5
        \\@@ -7,4 +7,4 @@
        \\ 7
        \\ 8
        \\ 9
        \\-10
        \\+Y
        \\
    , d);
}

test "unified: trailing-newline-only change surfaces as -/+" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const d = try unified(ar.allocator(), "/f", "a\nb", "a\nb\n");
    try std.testing.expectEqualStrings(
        \\--- a//f
        \\+++ b//f
        \\@@ -1,2 +1,2 @@
        \\ a
        \\-b
        \\\ No newline at end of file
        \\+b
        \\
    , d);
}

test "unified: insertion at top carries context" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const d = try unified(ar.allocator(), "/f", "a\nb\n", "new\na\nb\n");
    try std.testing.expectEqualStrings(
        \\--- a//f
        \\+++ b//f
        \\@@ -1,2 +1,3 @@
        \\+new
        \\ a
        \\ b
        \\
    , d);
}
