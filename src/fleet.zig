const std = @import("std");
const cfgmod = @import("config.zig");
const jsonmod = @import("json.zig");
const term = @import("term.zig");
const session_mod = @import("session.zig");
const provider_mod = @import("llm/provider.zig");
const helpers = @import("helpers.zig");

/// One work item in a fleet — the unit of work for a single worker.
pub const WorkItem = struct {
    id: []const u8,
    title: []const u8,
    scope: []const u8,
    deliverables: []const u8,
    acceptance: []const u8,
    /// IDs of items this depends on (must be completed first).
    depends_on: []const []const u8 = &.{},
};

/// Per-worker status. Persisted in the manifest.
pub const ItemStatus = enum { pending, running, approved, blocked, failed };

pub const ItemResult = struct {
    item: WorkItem,
    status: ItemStatus = .pending,
    iterations: u32 = 0,
    feedback_history: []const []const u8 = &.{},
};

/// Top-level fleet spec — what the user (or coordinator) hands to `tau fleet run`.
pub const FleetSpec = struct {
    goal: []const u8,
    items: []const WorkItem,
    /// Max times to re-plan via the coordinator if a work breakdown isn't pre-supplied.
    max_fleet_iterations: u32 = 3,
    /// Cap for each worker's inner Author↔Critic loop.
    worker_max_iterations: u32 = 8,
    /// When true, workers can run in parallel (independent items); false = sequential.
    parallel: bool = true,
    /// Optional per-fleet token budget (soft).
    token_budget: ?u64 = null,
    /// Optional model override for the coordinator turn.
    coordinator_model: ?[]const u8 = null,
    /// Optional model override for worker turns.
    worker_model: ?[]const u8 = null,
};

/// Persisted manifest: ~/.config/tau/fleets/<id>.json
pub const Manifest = struct {
    version: u32 = 1,
    id: []const u8,
    spec: FleetSpec,
    items: []const ItemResult,
    created_at: i64,
    updated_at: i64,
    global_status: enum { running, done, partial, failed, cancelled } = .running,
};

// ---------------------------------------------------------------------------
// Paths
// ---------------------------------------------------------------------------

/// ~/.config/tau/fleets
pub fn fleetsDir(a: std.mem.Allocator, env: *std.process.Environ.Map) ?[]u8 {
    const home = env.get("HOME") orelse return null;
    return std.fmt.allocPrint(a, "{s}/.config/tau/fleets", .{home}) catch null;
}

/// ~/.config/tau/fleets/<id>.json (null if HOME unset or bad id)
pub fn manifestPath(a: std.mem.Allocator, env: *std.process.Environ.Map, id: []const u8) ?[]u8 {
    if (!validId(id)) return null;
    const dir = fleetsDir(a, env) orelse return null;
    return std.fmt.allocPrint(a, "{s}/{s}.json", .{ dir, id }) catch null;
}

fn validId(name: []const u8) bool {
    if (name.len == 0 or name.len > 128) return false;
    for (name) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '-' or c == '_' or c == '.';
        if (!ok) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Coordinator
// ---------------------------------------------------------------------------

/// Build the coordinator directive. The coordinator is a one-shot LLM call
/// (no tools) that decomposes `goal` into a JSON work breakdown.
pub fn coordinatorDirective(gpa: std.mem.Allocator, goal: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa,
        \\You are a FLEET COORDINATOR. Your only job is to plan, not to implement.
        \\
        \\Decompose the GOAL into 2-6 work items that can be implemented in
        \\parallel by separate workers. Output a single JSON object — nothing else,
        \\no prose, no markdown fences. The JSON MUST match this schema:
        \\
        \\{{
        \\  "items": [
        \\    {{
        \\      "id": "kebab-case-id",
        \\      "title": "short title",
        \\      "scope": "what this item covers (1-3 sentences)",
        \\      "deliverables": "what 'done' looks like (files, tests, behavior)",
        \\      "acceptance": "concrete criteria the Critic will use to judge",
        \\      "depends_on": ["other-item-id", ...]
        \\    }}
        \\  ]
        \\}}
        \\
        \\Rules:
        \\  - 2-6 items total. Prefer fewer, larger items over many tiny ones.
        \\  - IDs MUST be unique kebab-case identifiers (a-z, 0-9, '-').
        \\  - depends_on may be empty; only list real data/contract dependencies.
        \\  - acceptance must be testable (a Critic with read-only tools should
        \\    be able to verify it).
        \\
        \\GOAL:
        \\{s}
    , .{goal});
}

/// Index of the closing `}` for a balanced `{...}` object starting at `start`.
/// Respects JSON string literals and backslash escapes.
fn balancedObjectEnd(s: []const u8, start: usize) ?usize {
    if (start >= s.len or s[start] != '{') return null;
    var depth: u32 = 0;
    var in_string = false;
    var escape = false;
    var i: usize = start;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (in_string) {
            if (escape) {
                escape = false;
            } else if (c == '\\') {
                escape = true;
            } else if (c == '"') {
                in_string = false;
            }
            continue;
        }
        switch (c) {
            '"' => in_string = true,
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    return null;
}

/// Try to extract a JSON object from a coordinator's response. Handles:
///  - Markdown fences (```json ... ``` or ``` ... ```)
///  - XML-style think blocks (<think> / <thinking> ...) with prose/logic
///  - Prose before the JSON (e.g., "Here is the plan:\n{\"items\":[]}")
///  - Brace literals in prose (e.g., "hint: {key: val}\n{\"items\":[]}")
/// Returns the JSON slice (caller must dup) or null.
pub fn extractCoordinatorJson(gpa: std.mem.Allocator, response: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, response, " \t\r\n");

    // --- 1. Strip <think> / <thinking> blocks ---
    // Models may emit reasoning in XML tags. Strip all occurrences; any
    // remaining text after the last block is the payload. <thinking> takes
    // priority when it overlaps <think> (tag `>` is 10+12 chars vs 7+8).
    var strip_think = trimmed;
    while (true) {
        const thk = std.mem.indexOf(u8, strip_think, "<think>");
        const thkng = std.mem.indexOf(u8, strip_think, "<thinking>");

        // Prefer <thinking> when it appears no later than <think>.
        if (thkng != null and (thk == null or thkng.? <= thk.?)) {
            const after_tag = strip_think[thkng.? + 10 ..];
            if (std.mem.indexOf(u8, after_tag, "</thinking>")) |tag_end| {
                const start = tag_end + 12;
                strip_think = if (start <= after_tag.len) after_tag[start..] else "";
                continue;
            }
            strip_think = "";
            break;
        }
        if (thk != null) {
            const after_tag = strip_think[thk.? + 7 ..];
            if (std.mem.indexOf(u8, after_tag, "</think>")) |tag_end| {
                const start = tag_end + 8;
                strip_think = if (start <= after_tag.len) after_tag[start..] else "";
                continue;
            }
            strip_think = "";
            break;
        }
        break;
    }

    // After stripping think blocks, re-trim
    const cleaned = std.mem.trim(u8, strip_think, " \t\r\n");
    if (cleaned.len == 0) return null;

    // --- 2. Strip ``` fences (```json ... ``` or ``` ... ```) ---
    if (std.mem.startsWith(u8, cleaned, "```")) {
        // find first newline
        var start: usize = 0;
        while (start < cleaned.len and cleaned[start] != '\n') start += 1;
        if (start < cleaned.len) start += 1;
        // find last ```
        var end = cleaned.len;
        if (std.mem.lastIndexOf(u8, cleaned[start..], "```")) |rel| {
            end = start + rel;
        }
        return std.mem.trim(u8, cleaned[start..end], " \t\r\n");
    }

    // --- 3. Brace-balanced scan: prefer parseable objects whose root key is "items" ---
    var i: usize = 0;
    var fallback: ?[]const u8 = null;
    while (i < cleaned.len) {
        if (cleaned[i] != '{') {
            i += 1;
            continue;
        }
        const end = balancedObjectEnd(cleaned, i) orelse {
            i += 1;
            continue;
        };
        const candidate = cleaned[i .. end + 1];
        var parsed = std.json.parseFromSlice(std.json.Value, gpa, candidate, .{}) catch {
            i = end + 1;
            continue;
        };
        const is_object = parsed.value == .object;
        const has_items = is_object and parsed.value.object.get("items") != null;
        parsed.deinit();
        if (!is_object) {
            i = end + 1;
            continue;
        }
        if (has_items) return candidate;
        if (fallback == null) fallback = candidate;
        i = end + 1;
    }
    return fallback;
}

/// Emit a structured stderr line identifying which work item index and field
/// caused a parse failure. Best-effort — write errors are swallowed but a
/// fallback minimal diagnostic is emitted so the reader is never silent.
fn logInvalidWorkItem(idx: usize, field: []const u8) void {
    var buf: [512]u8 = undefined;
    if (std.fmt.bufPrint(
        &buf,
        "{{\"err\":{{\"code\":110,\"message\":\"InvalidWorkItem at index {d}: missing or non-string field '{s}'\"}}}}\n",
        .{ idx, field },
    )) |msg| {
        term.err(msg);
    } else |_| {
        // Fallback when 512-byte buffer is too small for the field name.
        term.err("{\"err\":{\"code\":110,\"message\":\"InvalidWorkItem (overflow)\"}}\n");
    }
}

/// Sanitize a byte slice to valid UTF-8 by replacing any non-UTF-8 sequences
/// with the Unicode replacement character (U+FFFD = 0xEF 0xBF 0xBD).
/// Returns a new gpa-allocated slice (always valid UTF-8).
fn sanitizeUtf8(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    if (std.unicode.utf8ValidateSlice(s)) return try gpa.dupe(u8, s);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < s.len) {
        const cp_len = std.unicode.utf8ByteSequenceLength(s[i]) catch {
            try out.appendSlice(gpa, "\xEF\xBF\xBD"); // U+FFFD
            i += 1;
            continue;
        };
        if (i + cp_len > s.len) {
            try out.appendSlice(gpa, "\xEF\xBF\xBD");
            i += 1;
            continue;
        }
        const cp = std.unicode.utf8Decode(s[i..][0..cp_len]) catch {
            try out.appendSlice(gpa, "\xEF\xBF\xBD");
            i += 1;
            continue;
        };
        _ = cp;
        try out.appendSlice(gpa, s[i .. i + cp_len]);
        i += cp_len;
    }
    return out.toOwnedSlice(gpa);
}

/// Parse a WorkItem from a JSON object. `idx` is the array index of this item
/// in the coordinator response; included in error logs so a retry can target
/// the failing item. All string fields are sanitized to valid UTF-8 so they
/// never crash the JSON serializer.
fn parseWorkItem(gpa: std.mem.Allocator, obj: std.json.Value, idx: usize) !WorkItem {
    if (obj != .object) {
        logInvalidWorkItem(idx, "<root>");
        return error.InvalidWorkItem;
    }
    const id = (try objStr(obj, "id")) orelse {
        logInvalidWorkItem(idx, "id");
        return error.InvalidWorkItem;
    };
    const title = (try objStr(obj, "title")) orelse {
        logInvalidWorkItem(idx, "title");
        return error.InvalidWorkItem;
    };
    const scope = (try objStr(obj, "scope")) orelse {
        logInvalidWorkItem(idx, "scope");
        return error.InvalidWorkItem;
    };
    const deliverables = (try objStr(obj, "deliverables")) orelse {
        logInvalidWorkItem(idx, "deliverables");
        return error.InvalidWorkItem;
    };
    const acceptance = (try objStr(obj, "acceptance")) orelse {
        logInvalidWorkItem(idx, "acceptance");
        return error.InvalidWorkItem;
    };
    var deps_storage = std.ArrayList([]const u8).empty;
    if (obj.object.get("depends_on")) |d| {
        if (d == .array) {
            for (d.array.items) |it| {
                // Dupe each dependency string — it.string points into the
                // parsed JSON tree which is freed by parsed.deinit() in
                // buildSpec. Dangling pointers here crash saveManifest.
                const dep_str = if (it == .string) try gpa.dupe(u8, it.string) else "";
                try deps_storage.append(gpa, dep_str);
            }
        }
    }
    const deps = try deps_storage.toOwnedSlice(gpa);
    return .{
        .id = try sanitizeUtf8(gpa, id),
        .title = try sanitizeUtf8(gpa, title),
        .scope = try sanitizeUtf8(gpa, scope),
        .deliverables = try sanitizeUtf8(gpa, deliverables),
        .acceptance = try sanitizeUtf8(gpa, acceptance),
        .depends_on = deps,
    };
}

/// Look up `key` in an object JSON value and return the string slice (no copy).
/// Returns null if missing or not a string.
fn objStr(obj: std.json.Value, key: []const u8) !?[]const u8 {
    if (obj != .object) return null;
    const v = obj.object.get(key) orelse return null;
    return if (v == .string) v.string else null;
}


/// Extract the worker's status from its session's last assistant message.
/// Returns .approved when the message contains <READY_FOR_REVIEW>, else .failed.
/// Pure function so it can be unit-tested without spawning real workers.
fn statusFromAssistant(content: ?[]const u8) ItemStatus {
    const lc = content orelse return .failed;
    if (std.mem.indexOf(u8, lc, "<READY_FOR_REVIEW>") != null) return .approved;
    return .failed;
}

/// Walk a session's message history and return the content of the most recent
/// assistant turn, or null if no assistant message exists.
fn lastAssistantContent(messages: []const provider_mod.Message) ?[]const u8 {
    var last_content: ?[]const u8 = null;
    for (messages) |msg| {
        if (std.mem.eql(u8, msg.role, "assistant")) {
            last_content = msg.content;
        }
    }
    return last_content;
}

// ---------------------------------------------------------------------------
// Dependency helpers
// ---------------------------------------------------------------------------

/// True when every dependency id appears in `done`.
fn depsMet(deps: []const []const u8, done: []const []const u8) bool {
    for (deps) |dep| {
        var found = false;
        for (done) |d| {
            if (std.mem.eql(u8, dep, d)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Topological sort
// ---------------------------------------------------------------------------

/// Topologically sort items by depends_on. Returns a fresh slice in execution
/// order. Returns error.Cycle if a cycle is detected.
pub fn topoSort(gpa: std.mem.Allocator, items: []const WorkItem) ![]const WorkItem {
    var sorted: std.ArrayList(WorkItem) = .empty;
    var done = std.ArrayList(bool).empty;
    defer done.deinit(gpa);
    try done.resize(gpa, items.len);
    @memset(done.items, false);

    // Recursive DFS for each item
    var on_stack = std.ArrayList(bool).empty;
    defer on_stack.deinit(gpa);
    try on_stack.resize(gpa, items.len);
    @memset(on_stack.items, false);

    for (items, 0..) |_, i| {
        if (done.items[i]) continue;
        try topoVisit(gpa, items, i, &done, &on_stack, &sorted);
    }
    return try sorted.toOwnedSlice(gpa);
}

fn topoVisit(gpa: std.mem.Allocator, items: []const WorkItem, idx: usize, done: *std.ArrayList(bool), on_stack: *std.ArrayList(bool), out: *std.ArrayList(WorkItem)) !void {
    if (done.items[idx]) return;
    if (on_stack.items[idx]) return error.Cycle;
    on_stack.items[idx] = true;
    const item = items[idx];
    for (item.depends_on) |dep| {
        const dep_idx = blk: {
            for (items, 0..) |it, j| {
                if (std.mem.eql(u8, it.id, dep)) break :blk j;
            }
            return error.UnknownDependency;
        };
        try topoVisit(gpa, items, dep_idx, done, on_stack, out);
    }
    done.items[idx] = true;
    on_stack.items[idx] = false;
    try out.append(gpa, item);
}

// ---------------------------------------------------------------------------
// Manifest persistence
// ---------------------------------------------------------------------------

pub fn saveManifest(
    io: std.Io,
    gpa: std.mem.Allocator,
    env: *std.process.Environ.Map,
    manifest: Manifest,
) !void {
    const dir = fleetsDir(gpa, env) orelse return error.NoHome;
    defer gpa.free(dir);
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    const p = manifestPath(gpa, env, manifest.id) orelse return error.InvalidFleetId;
    defer gpa.free(p);
    const json = try std.json.Stringify.valueAlloc(gpa, manifest, .{ .whitespace = .indent_2 });
    defer gpa.free(json);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = json });
}

pub fn loadManifest(
    io: std.Io,
    arena: std.mem.Allocator,
    env: *std.process.Environ.Map,
    id: []const u8,
) !?Manifest {
    const p = manifestPath(arena, env, id) orelse return null;
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, p, arena, .unlimited) catch return null;
    return try std.json.parseFromSliceLeaky(Manifest, arena, bytes, .{
        .ignore_unknown_fields = true,
    });
}

// ---------------------------------------------------------------------------
// Model override + worker argv helpers
// ---------------------------------------------------------------------------

/// Split `--model provider/id` shorthand into components.
pub fn splitProviderModel(spec: []const u8) struct { provider: ?[]const u8, model: []const u8 } {
    if (std.mem.indexOfScalar(u8, spec, '/')) |slash| {
        return .{ .provider = spec[0..slash], .model = spec[slash + 1 ..] };
    }
    return .{ .provider = null, .model = spec };
}

/// Apply a model override string to a config copy (coordinator/worker turns).
fn applyModelOverride(cfg: anytype, model_spec: []const u8) void {
    const split = splitProviderModel(model_spec);
    cfg.model = split.model;
    if (split.provider) |prov_name| {
        if (cfgmod.findProvider(prov_name)) |p| {
            cfg.provider = p.name;
            cfg.endpoint = p.endpoint;
        }
    }
}

/// Build argv for a fleet worker subprocess. Forwards model/provider/api-key
/// overrides and caps the worker tool loop via --max-iterations.
pub fn buildWorkerArgv(
    arena: std.mem.Allocator,
    session_name: []const u8,
    scope: []const u8,
    cfg: cfgmod.Config,
    worker_max_iterations: u32,
) ![]const []const u8 {
    var argv = std.ArrayList([]const u8).empty;
    try argv.append(arena, "tau");
    try argv.append(arena, "--role");
    try argv.append(arena, "author");
    try argv.append(arena, "--session");
    try argv.append(arena, session_name);

    if (cfg.worker_model) |wm| {
        const split = splitProviderModel(wm);
        if (split.provider != null) {
            try argv.append(arena, "--model");
            try argv.append(arena, wm);
        } else {
            try argv.append(arena, "--provider");
            try argv.append(arena, cfg.provider);
            try argv.append(arena, "--model");
            try argv.append(arena, wm);
        }
    } else {
        try argv.append(arena, "--provider");
        try argv.append(arena, cfg.provider);
        try argv.append(arena, "--model");
        try argv.append(arena, cfg.model);
    }

    if (cfg.api_key) |key| {
        try argv.append(arena, "--api-key");
        try argv.append(arena, key);
    }

    const max_iter_str = try std.fmt.allocPrint(arena, "{d}", .{worker_max_iterations});
    try argv.append(arena, "--max-iterations");
    try argv.append(arena, max_iter_str);

    try argv.append(arena, scope);
    return try argv.toOwnedSlice(arena);
}

// ---------------------------------------------------------------------------
// Fleet CLI dispatch
// ---------------------------------------------------------------------------

pub const FleetSub = enum { run, status, list, logs, cancel };

/// Build the spec from CLI args, or call the LLM coordinator to produce one.
/// Returns the final FleetSpec (caller frees via deinitSpec). When the
/// coordinator is used, `coordinator_response` is set to its raw output for
/// logging; otherwise null.
pub fn buildSpec(
    gpa: std.mem.Allocator,
    cfg: anytype,
    goal: []const u8,
    items_override: ?[]const WorkItem,
    io: std.Io,
) !struct {
    spec: FleetSpec,
    coordinator_response: ?[]u8 = null,
} {
    if (items_override) |items| {
        return .{
            .spec = FleetSpec{
                .goal = try gpa.dupe(u8, goal),
                .items = items,
                .parallel = cfg.fleet_parallel,
            },
        };
    }
    // LLM coordinator turn with retry — when all items fail to parse, re-query
    // the coordinator with a stronger directive (max 3 attempts).
    var coord_cfg = cfg;
    coord_cfg.goal = null;
    coord_cfg.goal_action = .none;
    coord_cfg.exit_sentinel = null;
    coord_cfg.feedback_message = null;
    coord_cfg.role = .coordinator;
    coord_cfg.stream = false;
    if (cfg.coordinator_model) |m| applyModelOverride(&coord_cfg, m);

    const max_attempts: u32 = 3;
    var attempt: u32 = 0;
    var last_raw: ?[]u8 = null;
    // errdefer frees last_raw on any error return (but NOT on success — the
    // caller takes ownership via coordinator_response).
    errdefer if (last_raw) |lr| gpa.free(lr);

    while (attempt < max_attempts) : (attempt += 1) {
        // Free the previous attempt's raw response before allocating a new one.
        if (last_raw) |lr| {
            gpa.free(lr);
            last_raw = null;
        }

        // Build the system directive. On retry, prepend a note demanding
        // valid JSON only (the model already knows the schema from attempt 0).
        const sys = try coordinatorDirective(gpa, goal);
        defer gpa.free(sys);
        const sys_msg: []const u8 = if (attempt == 0)
            sys
        else
            try std.fmt.allocPrint(gpa,
                "⚠️ RETRY — your previous response had parse errors on ALL items. " ++
                    "Output ONLY the JSON object specified below. No prose, no markdown fences, " ++
                    "no thinking tags. Every item MUST have all required fields: id, title, scope, " ++
                    "deliverables, acceptance.\n\n{s}",
                .{sys});
        defer if (attempt > 0) gpa.free(sys_msg);

        const user_turn = try gpa.dupe(u8,
            if (attempt == 0) "Produce the work breakdown as JSON now."
            else "Produce ONLY valid JSON. No other text.");
        defer gpa.free(user_turn);

        const messages = [_]provider_mod.Message{
            .{ .role = "system", .content = sys_msg },
            .{ .role = "user", .content = user_turn },
        };
        const resp = try provider_mod.complete(io, gpa, coord_cfg, &messages, null);
        defer gpa.free(resp.content);
        last_raw = try gpa.dupe(u8, resp.content);

        // When schema is set, the model produces valid JSON directly
        // (no extractCoordinatorJson needed — response IS the JSON).
        const json_slice = if (@hasField(@TypeOf(cfg), "schema") and cfg.schema != null)
            last_raw.?
        else
            extractCoordinatorJson(gpa, last_raw.?) orelse {
                if (attempt + 1 >= max_attempts) return error.CoordinatorParseFailed;
                continue;
            };
        var parsed = std.json.parseFromSlice(std.json.Value, gpa, json_slice, .{}) catch {
            if (attempt + 1 >= max_attempts) return error.CoordinatorParseFailed;
            continue;
        };
        defer parsed.deinit();
        if (parsed.value != .object) {
            if (attempt + 1 >= max_attempts) return error.CoordinatorParseFailed;
            continue;
        }
        const items_v = parsed.value.object.get("items") orelse {
            if (attempt + 1 >= max_attempts) return error.CoordinatorParseFailed;
            continue;
        };
        if (items_v != .array) {
            if (attempt + 1 >= max_attempts) return error.CoordinatorParseFailed;
            continue;
        }

        // Collect items. Individual parse failures are logged via
        // logInvalidWorkItem but do NOT abort — we retry only when ALL
        // items fail (partial success is better than retrying forever).
        var items = std.ArrayList(WorkItem).empty;
        var any_failed = false;
        for (items_v.array.items, 0..) |it, idx| {
            const wi = parseWorkItem(gpa, it, idx) catch {
                any_failed = true;
                continue;
            };
            try items.append(gpa, wi);
        }

        if (items.items.len > 0) {
            // At least some items parsed — return them. The coordinator_response
            // carries last_raw (ownership transferred; errdefer will NOT free it
            // because this is a success return, not an error).
            return .{
                .spec = FleetSpec{
                    .goal = try gpa.dupe(u8, goal),
                    .items = try items.toOwnedSlice(gpa),
                    .parallel = cfg.fleet_parallel,
                },
                .coordinator_response = last_raw,
            };
        }

        if (!any_failed) {
            // Empty items array with no individual parse errors → fatal
            return error.CoordinatorParseFailed;
        }

        // All items failed to parse. Clean up the empty ArrayList and retry.
        items.deinit(gpa);
    }

    return error.CoordinatorParseFailed;
}

/// Parse a pre-supplied items JSON blob (same schema the coordinator
/// produces) into a slice of WorkItem. Used by the --items CLI flag.
pub fn parseItemsJson(gpa: std.mem.Allocator, raw_json: []const u8) ![]const WorkItem {
    const json_slice = extractCoordinatorJson(gpa, raw_json) orelse return error.CoordinatorParseFailed;
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, json_slice, .{}) catch
        return error.CoordinatorParseFailed;
    defer parsed.deinit();
    if (parsed.value != .object) return error.CoordinatorParseFailed;
    const items_v = parsed.value.object.get("items") orelse return error.CoordinatorParseFailed;
    if (items_v != .array) return error.CoordinatorParseFailed;

    var items = std.ArrayList(WorkItem).empty;
    for (items_v.array.items, 0..) |it, idx| {
        try items.append(gpa, try parseWorkItem(gpa, it, idx));
    }
    if (items.items.len == 0) return error.CoordinatorParseFailed;
    return try items.toOwnedSlice(gpa);
}

/// Dispatch a fleet subcommand. Exit code returned.
pub fn dispatch(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    cfg: cfgmod.Config,
    env: *std.process.Environ.Map,
    sub: FleetSub,
    fleet_id: ?[]const u8,
    goal: ?[]const u8,
) !u8 {
    return switch (sub) {
        .status => statusCmd(io, gpa, arena, env, fleet_id),
        .list => listCmd(io, gpa, arena, env),
        .cancel => cancelCmd(io, gpa, arena, env, fleet_id),
        .logs => logsCmd(io, gpa, arena, env, fleet_id),
        .run => runCmd(io, gpa, arena, cfg, env, fleet_id, goal),
    };
}

fn statusCmd(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, env: *std.process.Environ.Map, fleet_id: ?[]const u8) !u8 {
    const id = fleet_id orelse return helpers.fleetRequires("status", "<id>", 80);
    if (try loadManifest(io, arena, env, id)) |m| {
        try helpers.fleetPrintJson(gpa, m);
    } else {
        return helpers.fleetEmpty("fleet", false);
    }
    return 0;
}

fn listCmd(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, env: *std.process.Environ.Map) !u8 {
    const dir = fleetsDir(arena, env) orelse return helpers.fleetEmpty("fleets", true);
    defer arena.free(dir);
    var d = std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return helpers.fleetEmpty("fleets", true);
    defer d.close(io);
    var it = d.iterate();
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(arena);
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.endsWith(u8, entry.name, ".json")) {
            // strip .json
            const base = entry.name[0 .. entry.name.len - 5];
            try names.append(arena, base);
        }
    }
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try out.appendSlice(gpa, "{\"fleets\":[");
    for (names.items, 0..) |n, i| {
        if (i != 0) try out.append(gpa, ',');
        const ne = try jsonmod.escapeAlloc(gpa, n);
        defer gpa.free(ne);
        const line = try std.fmt.allocPrint(gpa, "\"{s}\"", .{ne});
        defer gpa.free(line);
        try out.appendSlice(gpa, line);
    }
    try out.appendSlice(gpa, "]}\n");
    term.out(out.items);
    return 0;
}

fn cancelCmd(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, env: *std.process.Environ.Map, fleet_id: ?[]const u8) !u8 {
    const id = fleet_id orelse return helpers.fleetRequires("cancel", "<id>", 80);
    const m = (try loadManifest(io, arena, env, id)) orelse return helpers.fleetEmpty("fleet", false);
    var updated = m;
    updated.global_status = .cancelled;
    updated.updated_at = std.Io.Clock.Timestamp.now(io, .real).raw.toMilliseconds();
    saveManifest(io, gpa, env, updated) catch |err| return helpers.fleetErr(arena, "cancel save failed", err);
    // Verify persistence by reloading from disk — if the on-disk manifest
    // does not reflect the cancelled status, surface that as a failure rather
    // than silently lying to the caller.
    if (try loadManifest(io, arena, env, id)) |reloaded| {
        if (reloaded.global_status != .cancelled) {
            term.out("{\"err\":{\"code\":110,\"message\":\"cancel did not persist global_status\"}}\n");
            return 110;
        }
    } else {
        term.out("{\"err\":{\"code\":110,\"message\":\"cancel persisted but reload failed\"}}\n");
        return 110;
    }
    try helpers.fleetPrintJson(gpa, updated);
    return 0;
}

fn logsCmd(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, env: *std.process.Environ.Map, fleet_id: ?[]const u8) !u8 {
    _ = gpa;
    _ = arena;
    _ = env;
    _ = io;
    const id = fleet_id orelse return helpers.fleetRequires("logs", "<id>", 80);
    term.out("{\"note\":\"logs: inspect sessions under ~/.config/tau/sessions/ matching prefix ");
    term.out(id);
    term.out("-<item-id>-*\"}\n");
    return 0;
}

fn runCmd(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    cfg: cfgmod.Config,
    env: *std.process.Environ.Map,
    fleet_id: ?[]const u8,
    goal: ?[]const u8,
) !u8 {
    const gl = goal orelse return helpers.fleetRequires("run", "--goal <text>", 82);
    const id = fleet_id orelse blk: {
        const ts = std.Io.Clock.Timestamp.now(io, .real).raw.toMilliseconds();
        break :blk try std.fmt.allocPrint(arena, "fleet-{d}", .{ts});
    };
    defer if (fleet_id == null) arena.free(id);

    // Build spec: use pre-supplied --items JSON if given, otherwise coordinator LLM.
    const items_override: ?[]const WorkItem = if (cfg.fleet_items) |raw|
        try parseItemsJson(gpa, raw)
    else
        null;
    const built = try buildSpec(gpa, cfg, gl, items_override, io);
    const coordinator_response: ?[]u8 = built.coordinator_response;
    defer if (coordinator_response) |cr| gpa.free(cr);
    const spec = built.spec;

    // Validate no cycles in sequential mode (parallel mode detects cycles
    // dynamically via depsMet — an empty wave with pending items is a cycle).

    // Initialize item results
    var items = std.ArrayList(ItemResult).empty;
    defer items.deinit(gpa);
    for (spec.items) |it| try items.append(gpa, .{ .item = it });

    // Clone items for the initial manifest (toOwnedSlice would consume the
    // ArrayList, leaving the worker dispatch loop with zero items).
    const manifest_items = try gpa.alloc(ItemResult, items.items.len);
    @memcpy(manifest_items, items.items);

    // Write the initial manifest
    const manifest = Manifest{
        .id = try gpa.dupe(u8, id),
        .spec = spec,
        .items = manifest_items,
        .created_at = std.Io.Clock.Timestamp.now(io, .real).raw.toMilliseconds(),
        .updated_at = std.Io.Clock.Timestamp.now(io, .real).raw.toMilliseconds(),
    };
    saveManifest(io, gpa, env, manifest) catch |err| return helpers.fleetErr(arena, "manifest save failed", err);

    // Dispatch workers. In parallel mode, use wave-based dispatch: items
    // whose dependencies are all satisfied are spawned simultaneously.
    // In sequential mode, follow the topo-sorted order one at a time.
    if (spec.parallel) {
        // Parallel wave-based dispatch.
        var done_ids: std.ArrayList([]const u8) = .empty;
        defer done_ids.deinit(gpa);
        var pending: std.ArrayList(usize) = .empty;
        defer pending.deinit(gpa);
        for (0..items.items.len) |idx| try pending.append(gpa, idx);

        while (pending.items.len > 0) {
            // Build the next wave: items whose deps are all done.
            var wave_idxs: std.ArrayList(usize) = .empty;
            defer wave_idxs.deinit(gpa);
            var children: std.ArrayList(?std.process.Child) = .empty;
            defer children.deinit(gpa);

            var pi: usize = 0;
            while (pi < pending.items.len) {
                const idx = pending.items[pi];
                const it = spec.items[idx];
                if (depsMet(it.depends_on, done_ids.items)) {
                    const session_name = try std.fmt.allocPrint(arena, "{s}-{s}", .{ id, it.id });
                    const cmd_argv = try buildWorkerArgv(arena, session_name, it.scope, cfg, spec.worker_max_iterations);
                    items.items[idx].status = .running;

                    const child = std.process.spawn(io, .{
                        .argv = cmd_argv,
                        .stdin = .ignore,
                        .stdout = .ignore,
                        .stderr = .ignore,
                    }) catch null;
                    try children.append(gpa, child);
                    try wave_idxs.append(gpa, idx);
                    _ = pending.swapRemove(pi);
                } else {
                    pi += 1;
                }
            }

            if (wave_idxs.items.len == 0) {
                // All remaining items have unmet dependencies (including failed
                // deps) or there is a genuine cycle. Mark remaining pending
                // items as blocked and exit the wave loop gracefully.
                for (pending.items) |idx| {
                    if (items.items[idx].status == .pending)
                        items.items[idx].status = .blocked;
                }
                break;
            }

            // Persist in-flight status before waiting on workers.
            const wave_updated = Manifest{
                .id = id,
                .spec = spec,
                .items = items.items,
                .created_at = manifest.created_at,
                .updated_at = std.Io.Clock.Timestamp.now(io, .real).raw.toMilliseconds(),
                .global_status = .running,
            };
            saveManifest(io, gpa, env, wave_updated) catch {};

            // Wait for each child, update its status, and persist immediately.
            for (children.items, 0..) |*maybe_child, i| {
                if (maybe_child.*) |*ch| {
                    _ = ch.wait(io) catch {};
                }

                const idx = wave_idxs.items[i];
                const it = spec.items[idx];
                const session_name = try std.fmt.allocPrint(arena, "{s}-{s}", .{ id, it.id });

                var status: ItemStatus = .failed;
                if (session_mod.load(io, arena, env, session_name)) |maybe_st| {
                    if (maybe_st) |st| {
                        status = statusFromAssistant(lastAssistantContent(st.messages));
                    }
                } else |_| {}

                items.items[idx].status = status;
                items.items[idx].iterations = if (status == .approved) @as(u32, 1) else @as(u32, 0);
                if (status == .approved) {
                    try done_ids.append(gpa, it.id);
                }

                // Save manifest incrementally after each individual worker completes.
                const updated = Manifest{
                    .id = id,
                    .spec = spec,
                    .items = items.items,
                    .created_at = manifest.created_at,
                    .updated_at = std.Io.Clock.Timestamp.now(io, .real).raw.toMilliseconds(),
                    .global_status = .running,
                };
                saveManifest(io, gpa, env, updated) catch {};
            }
        }
    } else {
        // Sequential dispatch (original behavior).
        const sorted = topoSort(gpa, spec.items) catch |err| return helpers.fleetErr(arena, "toposort failed", err);
        defer gpa.free(sorted);
        for (sorted) |it| {
            const item_idx = blk: {
                for (items.items, 0..) |ir, j| {
                    if (std.mem.eql(u8, ir.item.id, it.id)) break :blk j;
                }
                unreachable;
            };

            const session_name = try std.fmt.allocPrint(arena, "{s}-{s}", .{ id, it.id });
            items.items[item_idx].status = .running;
            const running_updated = Manifest{
                .id = id,
                .spec = spec,
                .items = items.items,
                .created_at = manifest.created_at,
                .updated_at = std.Io.Clock.Timestamp.now(io, .real).raw.toMilliseconds(),
                .global_status = .running,
            };
            saveManifest(io, gpa, env, running_updated) catch {};

            const cmd_argv = try buildWorkerArgv(arena, session_name, it.scope, cfg, spec.worker_max_iterations);
            var child = std.process.spawn(io, .{
                .argv = cmd_argv,
                .stdin = .ignore,
                .stdout = .ignore,
                .stderr = .ignore,
            }) catch null;
            if (child) |*ch| {
                _ = ch.wait(io) catch {};
            }

            // Check the worker's session file for the READY_FOR_REVIEW sentinel.
            var status: ItemStatus = .failed;
            if (session_mod.load(io, arena, env, session_name)) |maybe_st| {
                if (maybe_st) |st| {
                    status = statusFromAssistant(lastAssistantContent(st.messages));
                }
            } else |_| {}

            items.items[item_idx].status = status;
            items.items[item_idx].iterations = if (status == .approved) @as(u32, 1) else @as(u32, 0);

            // Save manifest incrementally.
            const updated = Manifest{
                .id = id,
                .spec = spec,
                .items = items.items,
                .created_at = manifest.created_at,
                .updated_at = std.Io.Clock.Timestamp.now(io, .real).raw.toMilliseconds(),
                .global_status = .running,
            };
            saveManifest(io, gpa, env, updated) catch {};
        }
    }

    // Count approvals for the final output and persist final status.
    var approved_count: u32 = 0;
    var failed_count: u32 = 0;
    for (items.items) |ir| {
        switch (ir.status) {
            .approved => approved_count += 1,
            .failed, .blocked => failed_count += 1,
            else => {},
        }
    }
    const final_status: []const u8 = if (failed_count == 0 and approved_count == items.items.len) "done"
        else if (approved_count > 0) "partial"
        else "failed";

    // Persist final manifest with correct global_status.
    const final_manifest = Manifest{
        .id = id,
        .spec = spec,
        .items = items.items,
        .created_at = manifest.created_at,
        .updated_at = std.Io.Clock.Timestamp.now(io, .real).raw.toMilliseconds(),
        .global_status = if (std.mem.eql(u8, final_status, "done")) .done
            else if (std.mem.eql(u8, final_status, "partial")) .partial
            else .failed,
    };
    saveManifest(io, gpa, env, final_manifest) catch {};

    const final_out = try std.fmt.allocPrint(gpa, "{{\"fleet\":{{\"id\":\"{s}\",\"status\":\"{s}\",\"approved\":{d},\"failed\":{d},\"items\":{d}}}}}\n", .{ id, final_status, approved_count, failed_count, items.items.len });
    defer gpa.free(final_out);
    term.out(final_out);
    return 0;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "extractCoordinatorJson strips fences" {
    const a = "```json\n{\"items\":[]}\n```";
    const got = extractCoordinatorJson(std.testing.allocator,a).?;
    try std.testing.expectEqualStrings("{\"items\":[]}", got);

    const b = "{\"items\":[]}";
    try std.testing.expectEqualStrings(b, extractCoordinatorJson(std.testing.allocator,b).?);

    const c = "   leading\n{\"items\":[]}\ntrailing   ";
    try std.testing.expectEqualStrings("{\"items\":[]}", extractCoordinatorJson(std.testing.allocator,c).?);

    try std.testing.expect(extractCoordinatorJson(std.testing.allocator,"no braces here") == null);
    try std.testing.expect(extractCoordinatorJson(std.testing.allocator,"") == null);
}

test "extractCoordinatorJson strips think blocks" {
    // Single think block before JSON
    const a = "<think>Let me plan this carefully</think>\n{\"items\":[]}";
    try std.testing.expectEqualStrings("{\"items\":[]}", extractCoordinatorJson(std.testing.allocator,a).?);

    // Think block with braces inside (should not confuse the parser)
    const b = "<think>Need to output { and } as JSON</think>\n{\"items\":[{\"id\":\"a\"}]}";
    try std.testing.expectEqualStrings("{\"items\":[{\"id\":\"a\"}]}", extractCoordinatorJson(std.testing.allocator,b).?);

    // Multiple think blocks
    const c = "<think>first</think><think>second</think>{\"items\":[]}";
    try std.testing.expectEqualStrings("{\"items\":[]}", extractCoordinatorJson(std.testing.allocator,c).?);

    // Think block + markdown fences
    const d = "<think>reasoning</think>```json\n{\"items\":[]}\n```";
    try std.testing.expectEqualStrings("{\"items\":[]}", extractCoordinatorJson(std.testing.allocator,d).?);

    // Think block with nested braces in reasoning
    const e = "<think>I'll output {\"items\":[{\"id\":\"x\"}]} as the plan</think>\n{\"items\":[{\"id\":\"x\"}]}";
    try std.testing.expectEqualStrings("{\"items\":[{\"id\":\"x\"}]}", extractCoordinatorJson(std.testing.allocator,e).?);

    // Unclosed think tag
    const f = "<think>unclosed";
    try std.testing.expect(extractCoordinatorJson(std.testing.allocator,f) == null);

    // Only think block, no JSON
    const g = "<think>just reasoning</think>";
    try std.testing.expect(extractCoordinatorJson(std.testing.allocator,g) == null);

    // --- <thinking> tag (longer variant) ---

    // Single <thinking> block before JSON
    const h = "<thinking>planning approach</thinking>\n{\"items\":[]}";
    try std.testing.expectEqualStrings("{\"items\":[]}", extractCoordinatorJson(std.testing.allocator,h).?);

    // <thinking> with braces inside
    const i = "<thinking>considering { and } output</thinking>\n{\"items\":[{\"id\":\"b\"}]}";
    try std.testing.expectEqualStrings("{\"items\":[{\"id\":\"b\"}]}", extractCoordinatorJson(std.testing.allocator,i).?);

    // Unclosed <thinking> tag
    const j = "<thinking>unclosed";
    try std.testing.expect(extractCoordinatorJson(std.testing.allocator,j) == null);

    // Only <thinking> block, no JSON
    const k = "<thinking>just planning</thinking>";
    try std.testing.expect(extractCoordinatorJson(std.testing.allocator,k) == null);

    // Mixed <think> and <thinking> blocks
    const l = "<thinking>high level</thinking><think>details</think>{\"items\":[]}";
    try std.testing.expectEqualStrings("{\"items\":[]}", extractCoordinatorJson(std.testing.allocator,l).?);

    // <thinking> block with nested braces
    const m = "<thinking>output {\"x\":1} format</thinking>\n{\"items\":[]}";
    try std.testing.expectEqualStrings("{\"items\":[]}", extractCoordinatorJson(std.testing.allocator,m).?);
}

test "extractCoordinatorJson handles prose before JSON" {
    // Prose then JSON
    const a = "Here is the plan:\n{\"items\":[{\"id\":\"a\"}]}";
    try std.testing.expectEqualStrings("{\"items\":[{\"id\":\"a\"}]}", extractCoordinatorJson(std.testing.allocator, a).?);

    // Prose before and after
    const b = "The breakdown is:\n{\"items\":[]}\nThat should work.";
    try std.testing.expectEqualStrings("{\"items\":[]}", extractCoordinatorJson(std.testing.allocator, b).?);

    // Prose + think block + prose + JSON
    const c = "Let me think...\n<think>analyzing</think>\nHere:\n{\"items\":[{\"id\":\"ok\"}]}\nDone.";
    try std.testing.expectEqualStrings("{\"items\":[{\"id\":\"ok\"}]}", extractCoordinatorJson(std.testing.allocator, c).?);

    // Prose without any braces
    const d = "I cannot produce a breakdown right now.";
    try std.testing.expect(extractCoordinatorJson(std.testing.allocator, d) == null);
}

test "extractCoordinatorJson skips brace literals in prose (#7)" {
    const a = "hint: {key: val}\n{\"items\":[{\"id\":\"a\"}]}";
    try std.testing.expectEqualStrings("{\"items\":[{\"id\":\"a\"}]}", extractCoordinatorJson(std.testing.allocator, a).?);

    const b = "Example shape: {id: x, title: y}\n{\"items\":[]}";
    try std.testing.expectEqualStrings("{\"items\":[]}", extractCoordinatorJson(std.testing.allocator, b).?);

    const c = "nested {\"partial\": {\"x\": 1}} then real\n{\"items\":[{\"id\":\"z\"}]}";
    try std.testing.expectEqualStrings("{\"items\":[{\"id\":\"z\"}]}", extractCoordinatorJson(std.testing.allocator, c).?);
}

test "validId allows safe characters only" {
    try std.testing.expect(validId("fleet-2026-06-09"));
    try std.testing.expect(validId("a"));
    try std.testing.expect(!validId(""));
    try std.testing.expect(!validId("../escape"));
    try std.testing.expect(!validId("has space"));
    try std.testing.expect(!validId("slash/here"));
}

test "topoSort respects depends_on" {
    const a = std.testing.allocator;
    const items = [_]WorkItem{
        .{ .id = "a", .title = "A", .scope = "a", .deliverables = "a", .acceptance = "a", .depends_on = &.{} },
        .{ .id = "b", .title = "B", .scope = "b", .deliverables = "b", .acceptance = "b", .depends_on = &.{"a"} },
        .{ .id = "c", .title = "C", .scope = "c", .deliverables = "c", .acceptance = "c", .depends_on = &.{"a","b"} },
    };
    const sorted = try topoSort(a, &items);
    defer a.free(sorted);
    try std.testing.expectEqual(@as(usize, 3), sorted.len);
    // a must come before b, b before c.
    var a_idx: ?usize = null;
    var b_idx: ?usize = null;
    var c_idx: ?usize = null;
    for (sorted, 0..) |it, i| {
        if (std.mem.eql(u8, it.id, "a")) a_idx = i;
        if (std.mem.eql(u8, it.id, "b")) b_idx = i;
        if (std.mem.eql(u8, it.id, "c")) c_idx = i;
    }
    try std.testing.expect(a_idx.? < b_idx.?);
    try std.testing.expect(b_idx.? < c_idx.?);
}

test "topoSort detects cycle" {
    const a = std.testing.allocator;
    const items = [_]WorkItem{
        .{ .id = "x", .title = "X", .scope = "x", .deliverables = "x", .acceptance = "x", .depends_on = &.{"y"} },
        .{ .id = "y", .title = "Y", .scope = "y", .deliverables = "y", .acceptance = "y", .depends_on = &.{"x"} },
    };
    try std.testing.expectError(error.Cycle, topoSort(a, &items));
}

test "Manifest JSON round-trip: serialize then parse" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Build a known manifest.
    const work_item = WorkItem{
        .id = "build-core",
        .title = "Build core",
        .scope = "Implement the core module",
        .deliverables = "src/core.zig passes tests",
        .acceptance = "zig build test passes",
        .depends_on = &.{"init"},
    };
    const items_gpa = try gpa.alloc(WorkItem, 1);
    defer gpa.free(items_gpa);
    items_gpa[0] = work_item;
    const item_result = ItemResult{
        .item = work_item,
        .status = .approved,
        .iterations = 3,
    };
    const irs_gpa = try gpa.alloc(ItemResult, 1);
    defer gpa.free(irs_gpa);
    irs_gpa[0] = item_result;

    const original = Manifest{
        .id = "roundtrip-test",
        .spec = FleetSpec{
            .goal = "ship v1",
            .items = items_gpa,
            .parallel = true,
        },
        .items = irs_gpa,
        .created_at = 1000,
        .updated_at = 2000,
        .global_status = .done,
    };

    // Serialize to JSON.
    const json = try std.json.Stringify.valueAlloc(gpa, original, .{ .whitespace = .indent_2 });
    defer gpa.free(json);

    // Parse back from JSON.
    const loaded = try std.json.parseFromSliceLeaky(Manifest, arena, json, .{
        .ignore_unknown_fields = true,
    });

    // Assert round-trip equality.
    try std.testing.expectEqualStrings("roundtrip-test", loaded.id);
    try std.testing.expectEqualStrings("ship v1", loaded.spec.goal);
    try std.testing.expectEqual(@as(usize, 1), loaded.spec.items.len);
    try std.testing.expectEqualStrings("build-core", loaded.spec.items[0].id);
    try std.testing.expectEqualStrings("Build core", loaded.spec.items[0].title);
    try std.testing.expectEqualStrings("Implement the core module", loaded.spec.items[0].scope);
    try std.testing.expectEqualStrings("src/core.zig passes tests", loaded.spec.items[0].deliverables);
    try std.testing.expectEqualStrings("zig build test passes", loaded.spec.items[0].acceptance);
    try std.testing.expectEqual(@as(usize, 1), loaded.spec.items[0].depends_on.len);
    try std.testing.expectEqualStrings("init", loaded.spec.items[0].depends_on[0]);
    try std.testing.expect(loaded.spec.parallel);
    try std.testing.expectEqual(@as(usize, 1), loaded.items.len);
    try std.testing.expectEqual(ItemStatus.approved, loaded.items[0].status);
    try std.testing.expectEqual(@as(u32, 3), loaded.items[0].iterations);
    try std.testing.expectEqualStrings("build-core", loaded.items[0].item.id);
    try std.testing.expectEqual(@as(i64, 1000), loaded.created_at);
    try std.testing.expectEqual(@as(i64, 2000), loaded.updated_at);
    try std.testing.expectEqual(@TypeOf(loaded.global_status).done, loaded.global_status);
}


test "parseWorkItem returns InvalidWorkItem on missing field" {
    const a = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Missing 'scope' field at index 2 — should return error.InvalidWorkItem.
    // The structured stderr log is best-effort and not asserted here, but the
    // index-aware signature is exercised.
    const json_str =
        \\{"id":"x","title":"t","deliverables":"d","acceptance":"acc"}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, arena, json_str, .{});
    defer parsed.deinit();
    try std.testing.expectError(error.InvalidWorkItem, parseWorkItem(a, parsed.value, 2));

    // Non-object at index 0 — same error.
    const json_arr = "[1, 2, 3]";
    var parsed2 = try std.json.parseFromSlice(std.json.Value, arena, json_arr, .{});
    defer parsed2.deinit();
    try std.testing.expectError(error.InvalidWorkItem, parseWorkItem(a, parsed2.value, 0));

    // Happy path — all fields present, no error.
    const ok =
        \\{"id":"a","title":"T","scope":"S","deliverables":"D","acceptance":"A"}
    ;
    var parsed3 = try std.json.parseFromSlice(std.json.Value, arena, ok, .{});
    defer parsed3.deinit();
    const wi = try parseWorkItem(a, parsed3.value, 0);
    a.free(wi.id);
    a.free(wi.title);
    a.free(wi.scope);
    a.free(wi.deliverables);
    a.free(wi.acceptance);
    a.free(wi.depends_on);
}

test "lastAssistantContent picks the most recent assistant turn" {
    // Regression guard: must skip user/tool roles and return the LAST assistant
    // content, not the first.
    const msgs = [_]provider_mod.Message{
        .{ .role = "user", .content = "user-1" },
        .{ .role = "assistant", .content = "first-assistant" },
        .{ .role = "tool", .content = "tool-result" },
        .{ .role = "assistant", .content = "last-assistant" },
    };
    const got = lastAssistantContent(&msgs).?;
    try std.testing.expectEqualStrings("last-assistant", got);

    // Empty slice — returns null.
    const empty: []const provider_mod.Message = &.{};
    try std.testing.expect(lastAssistantContent(empty) == null);

    // No assistant role — returns null.
    const no_asst = [_]provider_mod.Message{
        .{ .role = "user", .content = "u" },
        .{ .role = "tool", .content = "t" },
    };
    try std.testing.expect(lastAssistantContent(&no_asst) == null);
}

test "statusFromAssistant maps sentinel presence to ItemStatus" {
    // Regression guard for #4: the helper extracted from runCmd must classify
    // worker results into .approved (sentinel present) or .failed (anything
    // else — missing sentinel, null content, empty content). Items must never
    // be left in .pending or .running by this code path.
    try std.testing.expectEqual(ItemStatus.approved, statusFromAssistant("prose\n<READY_FOR_REVIEW>\n"));
    try std.testing.expectEqual(ItemStatus.approved, statusFromAssistant("<READY_FOR_REVIEW>at-start"));
    try std.testing.expectEqual(ItemStatus.failed, statusFromAssistant("still working on it"));
    try std.testing.expectEqual(ItemStatus.failed, statusFromAssistant(""));
    try std.testing.expectEqual(ItemStatus.failed, statusFromAssistant(null));
}

test "Manifest with global_status: cancelled round-trips through JSON" {
    // Regression guard for #3: the persisted Manifest correctly serializes
    // and deserializes the cancelled status, so cancelCmd's reload-and-verify
    // path can trust loadManifest's result.
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const empty_items: []const WorkItem = &.{};
    const empty_results: []const ItemResult = &.{};
    const original = Manifest{
        .id = "cancel-test",
        .spec = FleetSpec{ .goal = "x", .items = empty_items },
        .items = empty_results,
        .created_at = 1,
        .updated_at = 2,
        .global_status = .cancelled,
    };
    const json = try std.json.Stringify.valueAlloc(gpa, original, .{});
    defer gpa.free(json);
    const loaded = try std.json.parseFromSliceLeaky(Manifest, arena, json, .{
        .ignore_unknown_fields = true,
    });
    try std.testing.expectEqual(@TypeOf(loaded.global_status).cancelled, loaded.global_status);
}

// ---------------------------------------------------------------------------
// Regression tests — fleet orchestration bugs found & fixed (June 2026)
// ---------------------------------------------------------------------------

test "splitProviderModel splits provider/id shorthand" {
    const s = splitProviderModel("openai/gpt-4o-mini");
    try std.testing.expectEqualStrings("openai", s.provider.?);
    try std.testing.expectEqualStrings("gpt-4o-mini", s.model);
}

test "splitProviderModel bare model has null provider" {
    const s = splitProviderModel("deepseek-chat");
    try std.testing.expect(s.provider == null);
    try std.testing.expectEqualStrings("deepseek-chat", s.model);
}

test "applyModelOverride resolves coordinator provider/id override" {
    var cfg = cfgmod.Config{};
    applyModelOverride(&cfg, "deepseek/deepseek-chat");
    try std.testing.expectEqualStrings("deepseek", cfg.provider);
    try std.testing.expectEqualStrings("deepseek-chat", cfg.model);
    try std.testing.expectEqualStrings(
        cfgmod.findProvider("deepseek").?.endpoint,
        cfg.endpoint,
    );
}

test "buildWorkerArgv forwards worker model, api key, and max-iterations" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const cfg = cfgmod.Config{
        .provider = "openai",
        .model = "gpt-4o-mini",
        .api_key = "sk-test",
        .worker_model = "deepseek/deepseek-chat",
    };
    const argv = try buildWorkerArgv(arena, "fleet-a-item1", "implement feature", cfg, 8);
    try std.testing.expectEqual(@as(usize, 12), argv.len);
    try std.testing.expectEqualStrings("tau", argv[0]);
    try std.testing.expectEqualStrings("--role", argv[1]);
    try std.testing.expectEqualStrings("author", argv[2]);
    try std.testing.expectEqualStrings("--session", argv[3]);
    try std.testing.expectEqualStrings("fleet-a-item1", argv[4]);
    try std.testing.expectEqualStrings("--model", argv[5]);
    try std.testing.expectEqualStrings("deepseek/deepseek-chat", argv[6]);
    try std.testing.expectEqualStrings("--api-key", argv[7]);
    try std.testing.expectEqualStrings("sk-test", argv[8]);
    try std.testing.expectEqualStrings("--max-iterations", argv[9]);
    try std.testing.expectEqualStrings("8", argv[10]);
    try std.testing.expectEqualStrings("implement feature", argv[11]);
}

test "buildWorkerArgv uses provider + bare worker model" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const cfg = cfgmod.Config{
        .provider = "openai",
        .model = "gpt-4o-mini",
        .worker_model = "gpt-4o",
    };
    const argv = try buildWorkerArgv(arena, "s1", "scope text", cfg, 12);
    try std.testing.expectEqualStrings("--provider", argv[5]);
    try std.testing.expectEqualStrings("openai", argv[6]);
    try std.testing.expectEqualStrings("--model", argv[7]);
    try std.testing.expectEqualStrings("gpt-4o", argv[8]);
    try std.testing.expectEqualStrings("--max-iterations", argv[9]);
    try std.testing.expectEqualStrings("12", argv[10]);
    try std.testing.expectEqualStrings("scope text", argv[11]);
}

test "sanitizeUtf8 passes through valid UTF-8 unchanged" {
    const gpa = std.testing.allocator;
    const input = "Hello, 世界! 🌍";
    const result = try sanitizeUtf8(gpa, input);
    defer gpa.free(result);
    try std.testing.expectEqualStrings(input, result);
}

test "sanitizeUtf8 handles empty string" {
    const gpa = std.testing.allocator;
    const result = try sanitizeUtf8(gpa, "");
    defer gpa.free(result);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "sanitizeUtf8 replaces single invalid byte with U+FFFD" {
    const gpa = std.testing.allocator;
    // 0xFF is never valid as a UTF-8 start byte or continuation byte.
    const input: []const u8 = &.{ 'A', 0xFF, 'B' };
    const result = try sanitizeUtf8(gpa, input);
    defer gpa.free(result);
    try std.testing.expectEqualStrings("A\xEF\xBF\xBDB", result);
}

test "sanitizeUtf8 replaces truncated sequence with U+FFFD" {
    const gpa = std.testing.allocator;
    // 0xC2 is a 2-byte sequence start but no continuation byte follows.
    const input: []const u8 = &.{ 'A', 0xC2, 'B' };
    const result = try sanitizeUtf8(gpa, input);
    defer gpa.free(result);
    try std.testing.expectEqualStrings("A\xEF\xBF\xBDB", result);
}

test "sanitizeUtf8 handles all-invalid bytes" {
    const gpa = std.testing.allocator;
    const input: []const u8 = &.{ 0xFF, 0xFE, 0xFD };
    const result = try sanitizeUtf8(gpa, input);
    defer gpa.free(result);
    // 3 × U+FFFD = 9 bytes.
    try std.testing.expectEqual(@as(usize, 9), result.len);
    try std.testing.expectEqualStrings("\xEF\xBF\xBD\xEF\xBF\xBD\xEF\xBF\xBD", result);
}

test "manifest items clone does not consume ArrayList" {
    // Regression guard: verify that cloning items for the initial manifest
    // (gpa.alloc + @memcpy) leaves the ArrayList intact. Previously
    // toOwnedSlice was used, which consumed the ArrayList and left the
    // worker dispatch loop with zero items.
    const gpa = std.testing.allocator;
    var items = std.ArrayList(ItemResult).empty;
    defer items.deinit(gpa);

    try items.append(gpa, .{ .item = WorkItem{
        .id = "a", .title = "A", .scope = "a", .deliverables = "a", .acceptance = "a",
    }});
    try items.append(gpa, .{ .item = WorkItem{
        .id = "b", .title = "B", .scope = "b", .deliverables = "b", .acceptance = "b",
    }});
    try items.append(gpa, .{ .item = WorkItem{
        .id = "c", .title = "C", .scope = "c", .deliverables = "c", .acceptance = "c",
    }});

    // Clone (same pattern used in runCmd).
    const manifest_items = try gpa.alloc(ItemResult, items.items.len);
    defer gpa.free(manifest_items);
    @memcpy(manifest_items, items.items);

    // The ArrayList MUST still have 3 items (regression: was 0 with toOwnedSlice).
    try std.testing.expectEqual(@as(usize, 3), items.items.len);
    try std.testing.expectEqualStrings("a", items.items[0].item.id);
    try std.testing.expectEqualStrings("b", items.items[1].item.id);
    try std.testing.expectEqualStrings("c", items.items[2].item.id);

    // The clone must also have correct data.
    try std.testing.expectEqual(@as(usize, 3), manifest_items.len);
    try std.testing.expectEqualStrings("a", manifest_items[0].item.id);
}

test "blocked items counted as failed in final tally" {
    // Regression guard: .blocked items must be tallied as failures so
    // the final output numbers reconcile (approved + failed = total).
    // Previously .blocked was silently ignored.
    const gpa = std.testing.allocator;
    var items = std.ArrayList(ItemResult).empty;
    defer items.deinit(gpa);

    // 1 approved, 1 failed, 1 blocked.
    try items.append(gpa, .{ .item = WorkItem{
        .id = "ok", .title = "OK", .scope = "o", .deliverables = "o", .acceptance = "o",
    }, .status = .approved });
    try items.append(gpa, .{ .item = WorkItem{
        .id = "fail", .title = "FAIL", .scope = "f", .deliverables = "f", .acceptance = "f",
    }, .status = .failed });
    try items.append(gpa, .{ .item = WorkItem{
        .id = "blocked", .title = "BLOCKED", .scope = "b", .deliverables = "b", .acceptance = "b",
    }, .status = .blocked });

    // Replicate the counting logic from runCmd.
    var approved_count: u32 = 0;
    var failed_count: u32 = 0;
    for (items.items) |ir| {
        switch (ir.status) {
            .approved => approved_count += 1,
            .failed, .blocked => failed_count += 1,
            else => {},
        }
    }

    try std.testing.expectEqual(@as(u32, 1), approved_count);
    try std.testing.expectEqual(@as(u32, 2), failed_count); // 1 failed + 1 blocked
    try std.testing.expectEqual(items.items.len, approved_count + failed_count);
}

test "all-blocked items count as failed → fleet marked failed" {
    const gpa = std.testing.allocator;
    var items = std.ArrayList(ItemResult).empty;
    defer items.deinit(gpa);

    try items.append(gpa, .{ .item = WorkItem{
        .id = "x", .title = "X", .scope = "x", .deliverables = "x", .acceptance = "x",
    }, .status = .blocked });

    var approved_count: u32 = 0;
    var failed_count: u32 = 0;
    for (items.items) |ir| {
        switch (ir.status) {
            .approved => approved_count += 1,
            .failed, .blocked => failed_count += 1,
            else => {},
        }
    }

    try std.testing.expectEqual(@as(u32, 0), approved_count);
    try std.testing.expectEqual(@as(u32, 1), failed_count);
}
