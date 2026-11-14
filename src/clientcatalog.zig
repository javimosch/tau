//! The `tau setup --client` catalog behind `tau explain client.<id>` — one
//! entry per supported editor client, so `tau explain client.zed` prints
//! offline what the wiring needs (prerequisites), where it lands (config
//! paths), and how to finish it (the restart + in-editor verify step).
//!
//! Everything derivable comes from the ClientKind tables in src/setup.zig —
//! clientName/parseClientName, clientUsesBridge, clientSettingsPath,
//! clientConfigDir, clientNextStep, snippetPath, mcacpConfigPath — the same
//! source gen-compat-doc.py renders docs/compatibility.md from, so the
//! catalog cannot drift from the wiring itself. Only the prerequisites
//! text and the snippet clients' merge targets live here, mirrored from the
//! per-client guides in docs/clients/; the doc-mirror tests below pin them.

const std = @import("std");
const json = @import("json.zig");
const setup = @import("setup.zig");
const doctorcat = @import("doctorcatalog.zig");

/// Per-client guide links resolve under docs/clients/ — each guide is the
/// long-form version of the explain entry (verified snippets, per-OS paths).
const clients_doc_base = "https://github.com/javimosch/tau/blob/master/docs/clients/";

/// How the editor reaches tau — `acp` clients spawn `tau acp serve`
/// directly; `mcacp` clients speak MCP and go through the mcacp bridge.
pub const Transport = enum { acp, mcacp };

/// How `tau setup --client` installs the entry — `direct` splices the
/// settings file; `snippet` writes a paste-ready fragment under
/// ~/.config/tau/snippets/ for a config format it can't splice
/// (Lua, elisp, YAML, TOML).
pub const Wiring = enum { direct, snippet };

/// One resolved client entry — the fields `tau explain client.<id>` emits.
/// `settings_path` is the config file that carries the agent/server entry:
/// the settings file setup splices for `direct` clients, or the native
/// file the user merges the snippet into for `snippet` clients.
/// `bridge_path` is set only for `mcacp` transports (the shared mcacp.json).
pub const Spec = struct {
    client: []const u8,
    transport: Transport,
    wiring: Wiring,
    prereqs: []const u8,
    setup_cmd: []const u8,
    config_dir: []const u8,
    settings_path: []const u8,
    snippet_path: []const u8,
    bridge_path: ?[]const u8,
    verify: []const u8,
    doctor_check: []const u8,
    docs: []const u8,
};

/// The prereq every guide leads with — `tau doctor` ok means the provider
/// and API-key halves are already proven before the editor wiring starts.
const tau_ready = "tau installed and configured — `tau doctor` reports an ok provider and API key";

/// Bridge clients also need Node.js on the PATH their process sees — the
/// mcacp bridge runs as `npx -y mcacp`.
fn bridgePrereq(comptime who: []const u8) []const u8 {
    return tau_ready ++ "; Node.js with `npx` on the PATH " ++ who ++ " sees — the bridge runs as `npx -y mcacp` (or install it once with `npm i -g mcacp`)";
}

/// What must be true before `tau setup --client <name>` runs — mirrors the
/// `## Prerequisites` section of each docs/clients/<name>.md guide.
fn prereqs(k: setup.ClientKind) []const u8 {
    return switch (k) {
        .zed, .vscode, .cursor => tau_ready,
        .jetbrains => "a JetBrains IDE with AI Assistant 2025.1 or newer (custom agents are not supported under WSL — use a native Windows or Linux/macOS install); " ++ tau_ready,
        .nvim => "Neovim with avante.nvim or CodeCompanion.nvim installed; " ++ tau_ready,
        .emacs => "Emacs 29.1+ with agent-shell and acp installed from MELPA; " ++ tau_ready,
        .windsurf => comptime bridgePrereq("Windsurf"),
        .gemini => comptime bridgePrereq("Gemini CLI"),
        .claude_desktop => comptime bridgePrereq("Claude Desktop"),
        .opencode => comptime bridgePrereq("OpenCode"),
        .cline, .roo => comptime bridgePrereq("VS Code"),
        .goose => comptime bridgePrereq("Goose"),
        .continue_ => comptime bridgePrereq("Continue"),
        .kilo => comptime bridgePrereq("the Kilo Code process"),
        .amazonq => comptime bridgePrereq("the `q` process"),
        .codex => comptime bridgePrereq("Codex"),
    };
}

/// The config file a snippet client merges its generated fragment into —
/// clientSettingsPath returns null for these because setup can't splice
/// Lua/elisp/YAML/TOML; the merge target comes from each client's guide.
fn mergeTarget(k: setup.ClientKind) []const u8 {
    return switch (k) {
        .nvim => "~/.config/nvim/init.lua",
        .emacs => "~/.emacs.d/init.el",
        .goose => "~/.config/goose/config.yaml",
        .continue_ => "~/.continue/config.yaml",
        .codex => "~/.codex/config.toml",
        else => unreachable,
    };
}

/// `client_<name with '-' -> '_'>` — the `tau doctor` row id that verifies
/// the wiring (same rule doctor.zig's clientCheckName applies), also
/// resolvable as `tau explain doctor.<id>`.
fn doctorCheckName(a: std.mem.Allocator, name: []const u8) ![]u8 {
    const out = try a.alloc(u8, "client_".len + name.len);
    @memcpy(out[0.."client_".len], "client_");
    for (name, 0..) |ch, i| out["client_".len + i] = if (ch == '-') '_' else ch;
    return out;
}

/// The per-client guide file — the same rule as doctorcatalog.guideFile,
/// re-exposed for a runtime kind (docs URL building happens at runtime).
fn guideFile(k: setup.ClientKind) []const u8 {
    inline for (setup.all_clients) |cand| {
        if (cand == k) return comptime doctorcat.guideFile(cand);
    }
    unreachable;
}

/// Build the full client entry for `k` — paths rendered with a `~` home
/// prefix, matching the docs/compatibility.md matrix and the guides.
/// Caller owns the allocated path strings (pass an arena).
pub fn specFor(arena: std.mem.Allocator, k: setup.ClientKind) !Spec {
    const name = setup.clientName(k);
    const bridge = setup.clientUsesBridge(k);
    const settings = try setup.clientSettingsPath(arena, "~", k);
    return .{
        .client = name,
        .transport = if (bridge) .mcacp else .acp,
        .wiring = if (settings == null) .snippet else .direct,
        .prereqs = prereqs(k),
        .setup_cmd = try std.fmt.allocPrint(arena, "tau setup --client {s} --yes", .{name}),
        .config_dir = try setup.clientConfigDir(arena, "~", k),
        .settings_path = settings orelse mergeTarget(k),
        .snippet_path = try setup.snippetPath(arena, "~", k),
        .bridge_path = if (bridge) try setup.mcacpConfigPath(arena, "~") else null,
        .verify = setup.clientNextStep(k),
        .doctor_check = try doctorCheckName(arena, name),
        .docs = try std.fmt.allocPrint(arena, "{s}{s}.md", .{ clients_doc_base, guideFile(k) }),
    };
}

/// Resolve a client query. Accepts the bare client name or the `client.<id>`
/// spelling — the prefix is the namespaced form (mirroring `doctor.<id>`),
/// and `--client` aliases resolve too (`client.code` is vscode,
/// `client.claude` is claude-desktop). Case-sensitive like the flag.
/// Returns null when nothing matches.
pub fn findClient(query: []const u8) ?setup.ClientKind {
    const q = std.mem.trim(u8, query, " \t");
    const id = if (std.mem.startsWith(u8, q, "client.")) q["client.".len..] else q;
    if (id.len == 0) return null;
    return setup.parseClientName(id);
}

/// Append `"<escaped s>"` to buf.
fn jstr(a: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
    try buf.append(a, '"');
    try json.escapeInto(a, buf, s);
    try buf.append(a, '"');
}

/// Serialize one client entry for `tau explain` (no trailing newline — the
/// caller owns framing):
/// {"client":"N","transport":"acp|mcacp","wiring":"direct|snippet",
///  "prereqs":"P","setup":"CMD","config_dir":"D","settings_path":"S",
///  "snippet_path":"S",["bridge_path":"B",]"verify":"V",
///  "doctor_check":"client_N","docs":"U"}
/// Caller owns the returned slice.
pub fn formatClientJson(a: std.mem.Allocator, s: Spec) ![]u8 {
    var b: std.ArrayList(u8) = .empty;
    try b.appendSlice(a, "{\"client\":");
    try jstr(a, &b, s.client);
    try b.appendSlice(a, ",\"transport\":");
    try jstr(a, &b, @tagName(s.transport));
    try b.appendSlice(a, ",\"wiring\":");
    try jstr(a, &b, @tagName(s.wiring));
    try b.appendSlice(a, ",\"prereqs\":");
    try jstr(a, &b, s.prereqs);
    try b.appendSlice(a, ",\"setup\":");
    try jstr(a, &b, s.setup_cmd);
    try b.appendSlice(a, ",\"config_dir\":");
    try jstr(a, &b, s.config_dir);
    try b.appendSlice(a, ",\"settings_path\":");
    try jstr(a, &b, s.settings_path);
    try b.appendSlice(a, ",\"snippet_path\":");
    try jstr(a, &b, s.snippet_path);
    if (s.bridge_path) |bp| {
        try b.appendSlice(a, ",\"bridge_path\":");
        try jstr(a, &b, bp);
    }
    try b.appendSlice(a, ",\"verify\":");
    try jstr(a, &b, s.verify);
    try b.appendSlice(a, ",\"doctor_check\":");
    try jstr(a, &b, s.doctor_check);
    try b.appendSlice(a, ",\"docs\":");
    try jstr(a, &b, s.docs);
    try b.appendSlice(a, "}");
    return b.toOwnedSlice(a);
}

/// Human-readable `tau explain --human client.<id>` rendering — drawn from
/// the same Spec so the prose and JSON forms can never drift apart.
pub fn formatClientHuman(a: std.mem.Allocator, s: Spec) ![]u8 {
    var b: std.ArrayList(u8) = .empty;
    try b.appendSlice(a, try std.fmt.allocPrint(a, "client  {s} ({s} · {s})\n  prereqs:   {s}\n  setup:     {s}\n  paths:     config dir {s}\n             settings   {s}\n             snippet    {s}\n", .{ s.client, @tagName(s.transport), @tagName(s.wiring), s.prereqs, s.setup_cmd, s.config_dir, s.settings_path, s.snippet_path }));
    if (s.bridge_path) |bp| {
        try b.appendSlice(a, try std.fmt.allocPrint(a, "             bridge     {s}\n", .{bp}));
    }
    try b.appendSlice(a, try std.fmt.allocPrint(a, "  verify:    {s}\n  doctor:    {s} (resolve via `tau explain doctor.{s}`)\n  docs:      {s}\n", .{ s.verify, s.doctor_check, s.doctor_check, s.docs }));
    return b.toOwnedSlice(a);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "findClient: bare names, the client. prefix, and aliases resolve" {
    try testing.expectEqual(setup.ClientKind.zed, findClient("zed").?);
    try testing.expectEqual(setup.ClientKind.zed, findClient("client.zed").?);
    try testing.expectEqual(setup.ClientKind.claude_desktop, findClient("claude-desktop").?);
    try testing.expectEqual(setup.ClientKind.claude_desktop, findClient("client.claude").?);
    try testing.expectEqual(setup.ClientKind.vscode, findClient("client.code").?);
    try testing.expectEqual(setup.ClientKind.gemini, findClient("gemini-cli").?);
    try testing.expectEqual(setup.ClientKind.continue_, findClient("continue").?);
    try testing.expectEqual(setup.ClientKind.kilo, findClient("client.kilo-code").?);
    try testing.expectEqual(setup.ClientKind.codex, findClient("codex-cli").?);
}

test "findClient: rejects stay out of the registry" {
    try testing.expect(findClient("client.") == null);
    try testing.expect(findClient("client.bogus") == null);
    try testing.expect(findClient("client_zed") == null); // a doctor check id, not a client name
    try testing.expect(findClient("Zed") == null); // case-sensitive like --client
    try testing.expect(findClient("client.Zed") == null);
    try testing.expect(findClient("") == null);
    try testing.expect(findClient("all") == null); // --client all is a fan-out, not a client
}

test "findClient: every canonical name resolves both spellings" {
    for (setup.all_clients) |k| {
        const name = setup.clientName(k);
        try testing.expectEqual(k, findClient(name).?);
        var buf: [80]u8 = undefined;
        const q = std.fmt.bufPrint(&buf, "client.{s}", .{name}) catch unreachable;
        try testing.expectEqual(k, findClient(q).?);
    }
}

test "specFor: fields derive from the setup tables" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const z = try specFor(a, .zed);
    try testing.expectEqualStrings("zed", z.client);
    try testing.expect(z.transport == .acp);
    try testing.expect(z.wiring == .direct);
    try testing.expectEqualStrings("~/.config/zed", z.config_dir);
    try testing.expectEqualStrings("~/.config/zed/settings.json", z.settings_path);
    try testing.expectEqualStrings("~/.config/tau/snippets/zed.jsonc", z.snippet_path);
    try testing.expect(z.bridge_path == null);
    try testing.expectEqualStrings("client_zed", z.doctor_check);
    try testing.expectEqualStrings("open the Agent Panel, click +, and pick tau", z.verify);
    try testing.expect(std.mem.endsWith(u8, z.docs, "docs/clients/zed.md"));
}

test "specFor: bridge clients carry transport, bridge path, and npx prereqs" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    for (setup.all_clients) |k| {
        const s = try specFor(a, k);
        if (setup.clientUsesBridge(k)) {
            try testing.expect(s.transport == .mcacp);
            try testing.expectEqualStrings("~/.config/mcacp/mcacp.json", s.bridge_path.?);
            try testing.expect(std.mem.indexOf(u8, s.prereqs, "npx") != null);
            try testing.expect(std.mem.indexOf(u8, s.prereqs, "mcacp") != null);
        } else {
            try testing.expect(s.transport == .acp);
            try testing.expect(s.bridge_path == null);
        }
        // Every spec carries the common tau prereq and the derived paths.
        try testing.expect(std.mem.indexOf(u8, s.prereqs, "tau doctor") != null);
        try testing.expect(std.mem.startsWith(u8, s.config_dir, "~/"));
        try testing.expect(std.mem.startsWith(u8, s.settings_path, "~/"));
        try testing.expect(std.mem.startsWith(u8, s.snippet_path, "~/"));
        var buf: [80]u8 = undefined;
        const want = std.fmt.bufPrint(&buf, "tau setup --client {s} --yes", .{s.client}) catch unreachable;
        try testing.expectEqualStrings(want, s.setup_cmd);
    }
}

test "specFor: snippet clients point settings_path at the merge target" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const wants = .{
        .{ setup.ClientKind.nvim, "~/.config/nvim/init.lua" },
        .{ setup.ClientKind.emacs, "~/.emacs.d/init.el" },
        .{ setup.ClientKind.goose, "~/.config/goose/config.yaml" },
        .{ setup.ClientKind.continue_, "~/.continue/config.yaml" },
        .{ setup.ClientKind.codex, "~/.codex/config.toml" },
    };
    inline for (wants) |w| {
        const s = try specFor(a, w[0]);
        try testing.expect(s.wiring == .snippet);
        try testing.expectEqualStrings(w[1], s.settings_path);
    }
}

test "doctor_check ids match doctor's clientCheckName rule" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    for (setup.all_clients) |k| {
        const s = try specFor(a, k);
        // The id must resolve as a real doctor check entry too.
        const q = try std.fmt.allocPrint(a, "doctor.{s}", .{s.doctor_check});
        try testing.expect(doctorcat.findCheck(q) != null);
    }
}

test "every client entry's docs link and guide file exists" {
    const gpa = testing.allocator;
    inline for (setup.all_clients) |k| {
        const path = try std.fmt.allocPrint(gpa, "docs/clients/{s}.md", .{doctorcat.guideFile(k)});
        defer gpa.free(path);
        const f = std.Io.Dir.cwd().openFile(testing.io, path, .{}) catch {
            std.debug.print("missing client guide {s}\n", .{path});
            return error.TestUnexpectedResult;
        };
        f.close(testing.io);
    }
}

test "spec paths mirror the generated compatibility matrix" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const doc = try std.Io.Dir.cwd().readFileAlloc(testing.io, "docs/compatibility.md", a, .unlimited);
    for (setup.all_clients) |k| {
        const s = try specFor(a, k);
        // The matrix row carries the detection dir, the snippet fallback,
        // and (for direct clients) the settings file — all `~`-prefixed.
        for ([_][]const u8{ s.config_dir, s.snippet_path }) |p| {
            const needle = try std.fmt.allocPrint(a, "`{s}`", .{p});
            if (std.mem.indexOf(u8, doc, needle) == null) {
                std.debug.print("compatibility.md missing path {s} (client {s})\n", .{ needle, s.client });
                return error.TestUnexpectedResult;
            }
        }
        if (s.wiring == .direct) {
            const needle = try std.fmt.allocPrint(a, "`{s}`", .{s.settings_path});
            if (std.mem.indexOf(u8, doc, needle) == null) {
                std.debug.print("compatibility.md missing settings path {s}\n", .{needle});
                return error.TestUnexpectedResult;
            }
        } else {
            // Snippet clients document the merge target in their guide —
            // at minimum the filename being merged (nvim's guide says
            // "your init.lua" rather than the full ~/.config/nvim path).
            const guide = try std.fmt.allocPrint(a, "docs/clients/{s}.md", .{guideFile(k)});
            const text = try std.Io.Dir.cwd().readFileAlloc(testing.io, guide, a, .unlimited);
            const base = std.fs.path.basename(s.settings_path);
            if (std.mem.indexOf(u8, text, base) == null) {
                std.debug.print("{s} does not name merge target {s}\n", .{ guide, s.settings_path });
                return error.TestUnexpectedResult;
            }
        }
    }
}

test "explain: formatClientJson emits the client entry shape" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const got = try formatClientJson(a, try specFor(a, .zed));
    try testing.expect(std.mem.startsWith(u8, got, "{\"client\":\"zed\""));
    try testing.expect(std.mem.indexOf(u8, got, "\"transport\":\"acp\"") != null);
    try testing.expect(std.mem.indexOf(u8, got, "\"wiring\":\"direct\"") != null);
    try testing.expect(std.mem.indexOf(u8, got, "\"settings_path\":\"~/.config/zed/settings.json\"") != null);
    try testing.expect(std.mem.indexOf(u8, got, "\"doctor_check\":\"client_zed\"") != null);
    try testing.expect(std.mem.indexOf(u8, got, "bridge_path") == null);
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, got, .{});
    try testing.expect(v.object.get("client").?.string.len > 0);
    // A bridge entry carries the shared mcacp path.
    const b = try formatClientJson(a, try specFor(a, .claude_desktop));
    try testing.expect(std.mem.indexOf(u8, b, "\"transport\":\"mcacp\"") != null);
    try testing.expect(std.mem.indexOf(u8, b, "\"bridge_path\":\"~/.config/mcacp/mcacp.json\"") != null);
    // And a snippet client is tagged accordingly.
    const g = try formatClientJson(a, try specFor(a, .goose));
    try testing.expect(std.mem.indexOf(u8, g, "\"wiring\":\"snippet\"") != null);
    try testing.expect(std.mem.indexOf(u8, g, "\"settings_path\":\"~/.config/goose/config.yaml\"") != null);
}

test "explain: formatClientHuman renders prereqs, paths, verify, and docs" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const s = try specFor(a, .windsurf);
    const got = try formatClientHuman(a, s);
    try testing.expect(std.mem.indexOf(u8, got, "client  windsurf (mcacp · direct)") != null);
    try testing.expect(std.mem.indexOf(u8, got, "prereqs:") != null);
    try testing.expect(std.mem.indexOf(u8, got, "bridge     ~/.config/mcacp/mcacp.json") != null);
    try testing.expect(std.mem.indexOf(u8, got, s.verify) != null);
    try testing.expect(std.mem.indexOf(u8, got, "doctor.client_windsurf") != null);
    try testing.expect(std.mem.indexOf(u8, got, s.docs) != null);
}
