//! Contract-pin tests for the agent-facing output surface.
//!
//! These tests pin the exact JSON shapes documented in docs/integration.md —
//! the fields, event types, envelopes, and exit codes that downstream agent
//! consumers parse. A change that breaks one of these tests breaks the
//! integration contract: fix the code, or update docs/integration.md and
//! CHANGELOG.md in the same commit.

const std = @import("std");
const main_mod = @import("main.zig");
const agent_mod = @import("agent.zig");
const provider_mod = @import("llm/provider.zig");
const skills_mod = @import("skills.zig");
const agents_md_mod = @import("agents_md.zig");

const doc_path = "docs/integration.md";

fn readDoc(gpa: std.mem.Allocator) ![]u8 {
    // zig build test runs with cwd = repo root.
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, doc_path, gpa, .unlimited);
}

// ── Exact envelope shapes ───────────────────────────────────────────────────

test "contract: non-streaming final envelope is {version,model,content,done:true}" {
    const gpa = std.testing.allocator;
    const got = try agent_mod.formatFinalJson(gpa, "0.4.0", "xiaomi/mimo-v2.5", "hi");
    defer gpa.free(got);
    try std.testing.expectEqualStrings(
        "{\"version\":\"0.4.0\",\"model\":\"xiaomi/mimo-v2.5\",\"content\":\"hi\",\"done\":true}\n",
        got,
    );
}

test "contract: streaming terminal marker is {model,done:true}" {
    const gpa = std.testing.allocator;
    const got = try provider_mod.formatStreamDoneJson(gpa, "xiaomi/mimo-v2.5");
    defer gpa.free(got);
    try std.testing.expectEqualStrings(
        "{\"model\":\"xiaomi/mimo-v2.5\",\"done\":true}\n",
        got,
    );
}

test "contract: full error envelope carries code,type,message,recoverable" {
    const gpa = std.testing.allocator;
    const got = try main_mod.formatErrorJson(gpa, 80, "invalid_argument", "unknown option: --bogus", false);
    defer gpa.free(got);
    try std.testing.expectEqualStrings(
        "{\"err\":{\"code\":80,\"type\":\"invalid_argument\",\"message\":\"unknown option: --bogus\",\"recoverable\":false}}\n",
        got,
    );
}

test "contract: warning envelope is {warn:{message}}" {
    const gpa = std.testing.allocator;
    const got = try main_mod.formatWarnJson(gpa, "config file has invalid JSON");
    defer gpa.free(got);
    try std.testing.expectEqualStrings(
        "{\"warn\":{\"message\":\"config file has invalid JSON\"}}\n",
        got,
    );
}

test "contract: skill load result is {skill,content}" {
    const gpa = std.testing.allocator;
    const got = try main_mod.formatSkillLoadJson(gpa, "my-skill", "# Body");
    defer gpa.free(got);
    try std.testing.expectEqualStrings(
        "{\"skill\":\"my-skill\",\"content\":\"# Body\"}\n",
        got,
    );
}

test "contract: provider entry is {name,default_model,endpoint,context_window}" {
    const gpa = std.testing.allocator;
    const got = try provider_mod.formatProviderJson(gpa, .{
        .name = "openai",
        .endpoint = "https://api.openai.com/v1/chat/completions",
        .default_model = "gpt-4o-mini",
        .context_window = 128_000,
    });
    defer gpa.free(got);
    try std.testing.expectEqualStrings(
        "{\"name\":\"openai\",\"default_model\":\"gpt-4o-mini\",\"endpoint\":\"https://api.openai.com/v1/chat/completions\",\"context_window\":128000}",
        got,
    );
}

test "contract: skills entry is {name,description}" {
    const gpa = std.testing.allocator;
    const got = try skills_mod.formatEntryJson(gpa, "my-skill", "does things");
    defer gpa.free(got);
    try std.testing.expectEqualStrings(
        "{\"name\":\"my-skill\",\"description\":\"does things\"}",
        got,
    );
}

test "contract: agents_md entry is {path,first_line,size}" {
    const gpa = std.testing.allocator;
    const got = try agents_md_mod.formatEntryJson(gpa, "./AGENTS.md", "# Guide", 100);
    defer gpa.free(got);
    try std.testing.expectEqualStrings(
        "{\"path\":\"./AGENTS.md\",\"first_line\":\"# Guide\",\"size\":100}",
        got,
    );
}

// ── Stream event literals (emitted inline, not via a formatter) ────────────

test "contract: stream chunk and reasoning event literals keep documented shape" {
    const gpa = std.testing.allocator;
    const src = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/llm/provider.zig", gpa, .unlimited);
    defer gpa.free(src);
    // Source fmt literals are escaped: \"chunk\":\"{s}\",\"done\":false
    try std.testing.expect(std.mem.indexOf(u8, src, "\\\"chunk\\\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "\\\"reasoning\\\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "\\\"done\\\":false") != null);
}

test "contract: dry-run and goal event literals keep documented shape" {
    const gpa = std.testing.allocator;
    const src = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/agent.zig", gpa, .unlimited);
    defer gpa.free(src);
    // {"dry_run":true,"tool_calls":[{"name","arguments"}]}
    try std.testing.expect(std.mem.indexOf(u8, src, "\\\"dry_run\\\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "\\\"tool_calls\\\":[") != null);
    // {"goal":{"objective","status","continues","tokens_used"}} / {"goal":null}
    try std.testing.expect(std.mem.indexOf(u8, src, "\\\"objective\\\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "\\\"tokens_used\\\":{d}") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "\\\"goal\\\":null") != null);
}

// ── Envelope invariants across every emitter ────────────────────────────────

test "contract: every {\"err\" literal in the codebase carries a code" {
    const gpa = std.testing.allocator;
    const emitters = [_][]const u8{
        "src/main.zig",
        "src/agent.zig",
        "src/fleet.zig",
        "src/helpers.zig",
        "src/acp.zig",
    };
    for (emitters) |path| {
        const src = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, gpa, .unlimited);
        defer gpa.free(src);
        var rest = src;
        while (std.mem.indexOf(u8, rest, "\\\"err\\\"")) |i| {
            const end = @min(rest.len, i + 160);
            const window = rest[i..end];
            if (std.mem.indexOf(u8, window, "\\\"code\\\"") == null) {
                std.debug.print("{s}: err-envelope literal at byte {d} lacks a nearby code field\n", .{ path, i });
                return error.MissingErrCode;
            }
            rest = rest[end..];
        }
    }
}

// ── Doc ↔ code sync ─────────────────────────────────────────────────────────

test "contract: integration doc documents every ExitCode" {
    const gpa = std.testing.allocator;
    const doc = try readDoc(gpa);
    defer gpa.free(doc);
    inline for (@typeInfo(main_mod.ExitCode).@"enum".fields) |f| {
        const code: u8 = @intFromEnum(@field(main_mod.ExitCode, f.name));
        var buf: [16]u8 = undefined;
        const cell = try std.fmt.bufPrint(&buf, "`{d}`", .{code});
        if (std.mem.indexOf(u8, doc, cell) == null) {
            std.debug.print("docs/integration.md is missing exit code {d} ({s})\n", .{ code, f.name });
            return error.UndocumentedExitCode;
        }
        if (std.mem.indexOf(u8, doc, f.name) == null) {
            std.debug.print("docs/integration.md is missing exit code name {s}\n", .{f.name});
            return error.UndocumentedExitCode;
        }
    }
}

test "contract: integration doc documents every pinned field" {
    const gpa = std.testing.allocator;
    const doc = try readDoc(gpa);
    defer gpa.free(doc);
    // Field names agent consumers rely on — each must appear in the doc.
    const fields = [_][]const u8{
        // chat envelope + stream events
        "\"version\"",  "\"model\"",    "\"content\"",   "\"done\"",
        "\"chunk\"",    "\"reasoning\"", "\"dry_run\"",  "\"tool_calls\"",
        "\"arguments\"",
        // envelopes
        "\"err\"",      "\"code\"",     "\"type\"",      "\"message\"",
        "\"recoverable\"", "\"warn\"",
        // command results
        "\"providers\"", "\"default_model\"", "\"endpoint\"", "\"context_window\"",
        "\"skills\"",   "\"description\"", "\"skill\"",
        "\"agents_md_files\"", "\"first_line\"", "\"size\"",
        "\"goal\"",     "\"objective\"", "\"status\"",   "\"continues\"",
        "\"tokens_used\"",
        "\"fleets\"",   "\"fleet\"",    "\"note\"",
        "\"flags\"",    "\"goal_commands\"", "\"output_modes\"", "\"defaults\"",
        "\"exit_codes\"",
        "\"one_liner\"", "\"concepts\"", "\"term\"",     "\"desc\"",
        "\"commands\"", "\"cmd\"",      "\"examples\"",  "\"gotchas\"",
        "\"see_also\"",
        // fleet manifest
        "\"id\"",       "\"spec\"",     "\"items\"",     "\"depends_on\"",
        "\"acceptance\"", "\"deliverables\"", "\"scope\"", "\"title\"",
        "\"iterations\"", "\"feedback_history\"",
        "\"created_at\"", "\"updated_at\"", "\"global_status\"",
        "\"name\"",     "\"arg\"",
    };
    for (fields) |f| {
        if (std.mem.indexOf(u8, doc, f) == null) {
            std.debug.print("docs/integration.md is missing pinned field {s}\n", .{f});
            return error.UndocumentedField;
        }
    }
}

test "contract: help-json exit_codes map matches the pinned table" {
    const gpa = std.testing.allocator;
    const got = try main_mod.formatHelpJson(gpa);
    defer gpa.free(got);
    // Pinned exactly: the advertised map intentionally omits 1
    // (generic_failure); docs/integration.md's table is authoritative.
    try std.testing.expect(std.mem.indexOf(u8, got,
        "\"exit_codes\":{\"0\":\"success\",\"80\":\"invalid_argument\",\"82\":\"missing_required_field\",\"105\":\"connection_timeout\",\"106\":\"auth_failed\",\"110\":\"internal_error\",\"111\":\"unimplemented\"}"
    ) != null);
}
