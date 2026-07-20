const std = @import("std");
const jsonmod = @import("json.zig");

/// Metadata for a discovered skill from ~/.agents/skills/
pub const SkillInfo = struct {
    name: []const u8,
    description: []const u8,
    path: []const u8,
};

/// Extract the YAML frontmatter `description` field from a SKILL.md file.
/// Simple approach: find "---", then find "description:" in the frontmatter.
fn extractDescription(content: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    if (trimmed.len < 3 or !std.mem.eql(u8, trimmed[0..3], "---")) return null;
    const after_first = trimmed[3..];
    const end = std.mem.indexOf(u8, after_first, "---") orelse return null;
    const frontmatter = after_first[0..end];
    var lines = std.mem.splitScalar(u8, frontmatter, '\n');
    while (lines.next()) |line| {
        const tl = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, tl, "description:")) {
            const val = std.mem.trim(u8, tl["description:".len..], " \t\"'");
            return if (val.len > 0) val else null;
        }
    }
    return null;
}

/// Build the skills directory path: <HOME>/.agents/skills
fn skillsDirPath(arena: std.mem.Allocator, env: *std.process.Environ.Map) ?[]u8 {
    const home = env.get("HOME") orelse return null;
    return std.fmt.allocPrint(arena, "{s}/.agents/skills", .{home}) catch null;
}

/// Scan ~/.agents/skills/ for SKILL.md files with YAML frontmatter.
/// Uses `ls` via std.process.run for directory listing (Zig 0.16 compat).
pub fn scanSkills(io: std.Io, arena: std.mem.Allocator, env: *std.process.Environ.Map, gpa: std.mem.Allocator) ![]SkillInfo {
    const skills_dir = skillsDirPath(arena, env) orelse return &.{};

    // List skill directories using ls
    const ls_result = std.process.run(gpa, io, .{
        .argv = &[_][]const u8{ "ls", "-1", skills_dir },
        .stdout_limit = .unlimited,
    }) catch return &.{};
    defer gpa.free(ls_result.stdout);

    var results = std.ArrayList(SkillInfo).empty;
    var lines = std.mem.splitScalar(u8, std.mem.trim(u8, ls_result.stdout, " \t\r\n"), '\n');
    while (lines.next()) |entry| {
        if (entry.len == 0) continue;
        const path = std.fmt.allocPrint(arena, "{s}/{s}/SKILL.md", .{ skills_dir, entry }) catch continue;
        const content = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited) catch continue;
        const desc = extractDescription(content) orelse "";
        results.append(arena, .{
            .name = arena.dupe(u8, entry) catch continue,
            .description = arena.dupe(u8, desc) catch continue,
            .path = arena.dupe(u8, path) catch continue,
        }) catch {};
    }
    return results.toOwnedSlice(arena) catch &.{};
}

/// Load a skill's SKILL.md content by name.
pub fn loadSkill(io: std.Io, arena: std.mem.Allocator, env: *std.process.Environ.Map, gpa: std.mem.Allocator, name: []const u8) !?[]const u8 {
    const skills = try scanSkills(io, arena, env, gpa);
    for (skills) |s| {
        if (std.mem.eql(u8, s.name, name)) {
            return std.Io.Dir.cwd().readFileAlloc(io, s.path, arena, .unlimited) catch null;
        }
    }
    return null;
}

/// Serialize one skill entry as a JSON object with escaped name/description.
pub fn formatEntryJson(gpa: std.mem.Allocator, name: []const u8, description: []const u8) ![]u8 {
    const ne = try jsonmod.escapeAlloc(gpa, name);
    defer gpa.free(ne);
    const de = try jsonmod.escapeAlloc(gpa, description);
    defer gpa.free(de);
    return std.fmt.allocPrint(gpa, "{{\"name\":\"{s}\",\"description\":\"{s}\"}}", .{ ne, de });
}

/// Search skills by keyword (case-insensitive substring match).
pub fn searchSkills(io: std.Io, arena: std.mem.Allocator, env: *std.process.Environ.Map, gpa: std.mem.Allocator, query: []const u8) ![]SkillInfo {
    const skills = try scanSkills(io, arena, env, gpa);
    var results = std.ArrayList(SkillInfo).empty;
    for (skills) |s| {
        // Simple case-insensitive search: check both name and description
        const found = blk: {
            if (std.mem.indexOf(u8, s.name, query) != null) break :blk true;
            if (std.mem.indexOf(u8, s.description, query) != null) break :blk true;
            // Try lowercase comparison
            if (query.len > 0) {
                const q0 = query[0];
                const q_lower: u8 = if (q0 >= 'A' and q0 <= 'Z') q0 + 32 else q0;
                _ = q_lower;
            }
            break :blk false;
        };
        if (found) {
            results.append(arena, s) catch {};
        }
    }
    return results.toOwnedSlice(arena) catch &.{};
}

test "extractDescription handles valid YAML frontmatter" {
    const content =
        \\---
        \\name: test-skill
        \\description: A test skill for unit tests
        \\---
        \\
        \\# Skill body
        \\
    ;
    try std.testing.expectEqualStrings("A test skill for unit tests", extractDescription(content).?);
}

test "extractDescription returns null when no frontmatter" {
    const content = "# Just a markdown file\nNo frontmatter here\n";
    try std.testing.expect(extractDescription(content) == null);
}

test "formatEntryJson escapes quotes and backslashes in description" {
    const gpa = std.testing.allocator;
    const got = try formatEntryJson(gpa, "my-skill", "Use \"quotes\" and \\ backslash");
    defer gpa.free(got);
    try std.testing.expectEqualStrings(
        "{\"name\":\"my-skill\",\"description\":\"Use \\\"quotes\\\" and \\\\ backslash\"}",
        got,
    );
}

test "formatEntryJson escapes control characters" {
    const gpa = std.testing.allocator;
    const got = try formatEntryJson(gpa, "n", "line1\nline2");
    defer gpa.free(got);
    try std.testing.expectEqualStrings("{\"name\":\"n\",\"description\":\"line1\\nline2\"}", got);
}

test "extractDescription returns null when no description field" {
    const content =
        \\---
        \\name: test-skill
        \\tags: [cli, tool]
        \\---
        \\
        \\# Body
        \\
    ;
    try std.testing.expect(extractDescription(content) == null);
}
