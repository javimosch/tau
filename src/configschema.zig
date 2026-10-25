//! `tau config schema` — emits the JSON Schema (draft 2020-12) for the tau
//! config file on stdout.
//!
//! The schema is generated from `configfile.FileConfig` — the same struct the
//! loader parses into and `config validate` derives its checks from — so the
//! emitted document cannot drift from the keys tau actually accepts. Adding a
//! field to FileConfig without adding schema metadata below is a compile
//! error. Semantic constraints mirror `config validate`: integer keys are
//! >= 0 (bounded by their int type), temperature >= 0, compact_threshold in
//! 0..1, provider/keys names restricted to the provider table.
//!
//! A canonical copy is checked in at `schema/tau-config.schema.json` so the
//! schema has a stable raw URL for editors (`$schema` keys, VS Code
//! `json.schemas`, etc.). The `checked-in schema file` test below pins the two
//! byte-identical — regenerate after schema changes with:
//!
//!     zig build && ./zig-out/bin/tau config schema > schema/tau-config.schema.json

const std = @import("std");
const cfgmod = @import("config.zig");
const configfile = @import("configfile.zig");
const json = @import("json.zig");

/// Stable published URL for the checked-in schema copy. `tau init` writes
/// this as the "$schema" key so editors get autocomplete out of the box.
pub const schema_url = "https://raw.githubusercontent.com/javimosch/tau/master/schema/tau-config.schema.json";

// Comptime view of the file schema (same source as configvalidate.zig).
const file_fields = @typeInfo(configfile.FileConfig).@"struct".fields;

const Kind = enum { string, boolean, integer, number, any_json };

fn fieldKind(comptime T: type) Kind {
    return switch (innerType(T)) {
        []const u8 => .string,
        bool => .boolean,
        u32, u64, usize, i32, i64 => .integer,
        f32, f64 => .number,
        else => .any_json,
    };
}

fn innerType(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .optional => |o| o.child,
        else => T,
    };
}

/// Per-key schema metadata that the field type alone can't express.
/// Every FileConfig field must have an entry — `fieldMeta` is a compile error
/// otherwise, so new keys can't ship without descriptions/constraints.
const Meta = struct {
    desc: []const u8,
    /// Numeric bounds (number kind only; integer bounds come from the type).
    min: ?f64 = null,
    max: ?f64 = null,
    /// Require a non-empty string (api_key).
    non_empty: bool = false,
    /// Enumerate the live provider table (provider field only).
    provider_enum: bool = false,
    /// Fixed string enum (mode field only).
    str_enum: ?[]const []const u8 = null,
};

fn fieldMeta(comptime name: []const u8) Meta {
    if (comptime std.mem.eql(u8, name, "provider")) return .{
        .desc = "Active provider name — selects the API endpoint and default model. TAU_ENDPOINT overrides the endpoint.",
        .provider_enum = true,
    };
    if (comptime std.mem.eql(u8, name, "model")) return .{
        .desc = "Model id, or 'provider/id' shorthand. Defaults to the provider's default model.",
    };
    if (comptime std.mem.eql(u8, name, "api_key")) return .{
        .desc = "Global API key — used only when no keys[] entry or provider env var matches. Stored in plaintext; prefer env vars.",
        .non_empty = true,
    };
    if (comptime std.mem.eql(u8, name, "keys")) return .{
        .desc = "Per-provider API keys — an entry outranks that provider's env var and the global api_key.",
    };
    if (comptime std.mem.eql(u8, name, "mode")) return .{
        .desc = "Output format for results: 'json' (agent-friendly envelopes) or 'text' (human-readable prose).",
        .str_enum = &.{ "text", "json" },
    };
    if (comptime std.mem.eql(u8, name, "stream")) return .{
        .desc = "Stream responses token-by-token (SSE).",
    };
    if (comptime std.mem.eql(u8, name, "thinking")) return .{
        .desc = "Emit reasoning/thinking chunks alongside the response.",
    };
    if (comptime std.mem.eql(u8, name, "debug")) return .{
        .desc = "Write perf stats and tool I/O diagnostics to stderr.",
    };
    if (comptime std.mem.eql(u8, name, "temperature")) return .{
        .desc = "Sampling temperature.",
        .min = 0,
    };
    if (comptime std.mem.eql(u8, name, "max_tokens")) return .{
        .desc = "Cap on output tokens per response.",
    };
    if (comptime std.mem.eql(u8, name, "timeout_ms")) return .{
        .desc = "HTTP request timeout in milliseconds.",
    };
    if (comptime std.mem.eql(u8, name, "context_window")) return .{
        .desc = "Token capacity used for the auto-compaction threshold; defaults to the provider's context window.",
    };
    if (comptime std.mem.eql(u8, name, "auto_compact")) return .{
        .desc = "Auto-compact history when estimated tokens exceed compact_threshold of context_window.",
    };
    if (comptime std.mem.eql(u8, name, "compact_threshold")) return .{
        .desc = "Fraction of context_window that triggers auto-compaction.",
        .min = 0,
        .max = 1,
    };
    if (comptime std.mem.eql(u8, name, "compact_keep_recent_tokens")) return .{
        .desc = "Recent tokens kept verbatim through compaction.",
    };
    if (comptime std.mem.eql(u8, name, "goal_max_iterations")) return .{
        .desc = "Per-run agentic loop cap in /goal mode.",
    };
    if (comptime std.mem.eql(u8, name, "goal_max_continues")) return .{
        .desc = "Cross-invocation continuation cap for goal mode.",
    };
    @compileError("configschema.zig: no schema metadata for FileConfig field '" ++ name ++ "' — add a fieldMeta entry with a description and constraints");
}

fn appendJsonStr(arena: std.mem.Allocator, b: *std.ArrayList(u8), s: []const u8) !void {
    try b.append(arena, '"');
    try json.escapeInto(arena, b, s);
    try b.append(arena, '"');
}

fn appendProviderEnum(arena: std.mem.Allocator, b: *std.ArrayList(u8)) !void {
    try b.appendSlice(arena, ", \"enum\": [");
    for (cfgmod.providers, 0..) |p, i| {
        if (i != 0) try b.appendSlice(arena, ", ");
        try appendJsonStr(arena, b, p.name);
    }
    try b.append(arena, ']');
}

/// Emit one `"<key>": { ... }` member (single line, trailing comma if !last).
fn appendFieldSchema(
    arena: std.mem.Allocator,
    b: *std.ArrayList(u8),
    comptime field: std.builtin.Type.StructField,
    comptime meta: Meta,
    last: bool,
) !void {
    const name = field.name;
    try b.appendSlice(arena, "    \"");
    try b.appendSlice(arena, name);
    try b.appendSlice(arena, "\": { ");

    switch (comptime fieldKind(field.type)) {
        .string => {
            try b.appendSlice(arena, "\"type\": \"string\"");
            if (comptime meta.provider_enum) try appendProviderEnum(arena, b);
            if (comptime meta.str_enum) |vals| {
                try b.appendSlice(arena, ", \"enum\": [");
                for (vals, 0..) |v, i| {
                    if (i != 0) try b.appendSlice(arena, ", ");
                    try appendJsonStr(arena, b, v);
                }
                try b.append(arena, ']');
            }
            if (comptime meta.non_empty) try b.appendSlice(arena, ", \"minLength\": 1");
        },
        .boolean => try b.appendSlice(arena, "\"type\": \"boolean\""),
        .integer => {
            try b.appendSlice(arena, "\"type\": \"integer\", \"minimum\": 0");
            // Mirror config validate: fields narrower than 64 bits also get a
            // maximum (e.g. u32 -> 4294967295); i64 fields stay unbounded.
            const inner = comptime innerType(field.type);
            if (comptime @typeInfo(inner).int.bits < 64) {
                try b.appendSlice(arena, try std.fmt.allocPrint(arena, ", \"maximum\": {d}", .{std.math.maxInt(inner)}));
            }
        },
        .number => {
            try b.appendSlice(arena, "\"type\": \"number\"");
            if (comptime meta.min) |m| try b.appendSlice(arena, try std.fmt.allocPrint(arena, ", \"minimum\": {d}", .{m}));
            if (comptime meta.max) |m| try b.appendSlice(arena, try std.fmt.allocPrint(arena, ", \"maximum\": {d}", .{m}));
        },
        .any_json => try b.appendSlice(arena, "\"type\": \"object\""),
    }
    try b.appendSlice(arena, ", \"description\": ");
    try appendJsonStr(arena, b, meta.desc);
    try b.appendSlice(arena, " }");
    if (!last) try b.append(arena, ',');
    try b.append(arena, '\n');
}

/// The published document: JSON Schema draft 2020-12 describing the config
/// file. Deterministic — property order follows FileConfig declaration order.
pub fn schemaJson(arena: std.mem.Allocator) ![]u8 {
    var b: std.ArrayList(u8) = .empty;
    try b.appendSlice(arena,
        \\{
        \\  "$schema": "https://json-schema.org/draft/2020-12/schema",
        \\  "$id": "
    );
    try b.appendSlice(arena, schema_url);
    try b.appendSlice(arena,
        \\",
        \\  "title": "tau configuration",
        \\  "description": "Schema for ~/.config/tau/config.json — a JSONC file (// and /* */ comments allowed). Every key is optional; `tau config validate` reports unknown keys.",
        \\  "type": "object",
        \\  "properties": {
        \\    "$schema": { "type": "string", "description": "Editor hint pointing at this schema. Written by `tau init`; accepted but ignored by the loader." },
        \\
    );
    inline for (file_fields, 0..) |f, i| {
        if (comptime std.mem.eql(u8, f.name, "keys")) {
            // Free-form object needs propertyNames/additionalProperties —
            // emit it by hand rather than the generic shape.
            try b.appendSlice(arena, "    \"keys\": { \"type\": \"object\", \"description\": ");
            try appendJsonStr(arena, &b, comptime fieldMeta("keys").desc);
            try b.appendSlice(arena, ", \"propertyNames\": { \"enum\": [");
            for (cfgmod.providers, 0..) |p, pi| {
                if (pi != 0) try b.appendSlice(arena, ", ");
                try appendJsonStr(arena, &b, p.name);
            }
            try b.appendSlice(arena, "] }, \"additionalProperties\": { \"type\": \"string\", \"minLength\": 1 } }");
            if (i != file_fields.len - 1) try b.append(arena, ',');
            try b.append(arena, '\n');
        } else {
            try appendFieldSchema(arena, &b, f, comptime fieldMeta(f.name), i == file_fields.len - 1);
        }
    }
    try b.appendSlice(arena,
        \\  },
        \\  "additionalProperties": false
        \\}
        \\
    );
    return b.toOwnedSlice(arena);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
const testing = std.testing;

fn parsedSchema(arena: std.mem.Allocator) !std.json.Value {
    const doc = try schemaJson(arena);
    return std.json.parseFromSliceLeaky(std.json.Value, arena, doc, .{});
}

test "schema: output is a valid draft 2020-12 JSON Schema object" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const doc = try schemaJson(a);
    try testing.expect(std.mem.endsWith(u8, doc, "\n"));

    const v = try parsedSchema(a);
    try testing.expect(v == .object);
    try testing.expectEqualStrings("https://json-schema.org/draft/2020-12/schema", v.object.get("$schema").?.string);
    try testing.expectEqualStrings("object", v.object.get("type").?.string);
    try testing.expect(v.object.get("additionalProperties").? == .bool);
    try testing.expect(!v.object.get("additionalProperties").?.bool);
}

test "schema: properties covers every FileConfig field plus $schema" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const v = try parsedSchema(a);
    const props = v.object.get("properties").?.object;
    inline for (file_fields) |f| {
        try testing.expect(props.get(f.name) != null);
    }
    try testing.expect(props.get("$schema") != null);
    // Exactly the fields + $schema — nothing extra sneaks in.
    try testing.expectEqual(@as(u32, file_fields.len + 1), @as(u32, @intCast(props.count())));
}

test "schema: provider enum lists every provider in the table" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const v = try parsedSchema(a);
    const provider = v.object.get("properties").?.object.get("provider").?.object;
    const en = provider.get("enum").?.array;
    try testing.expectEqual(@as(usize, cfgmod.providers.len), en.items.len);
    for (cfgmod.providers, 0..) |p, i| {
        try testing.expectEqualStrings(p.name, en.items[i].string);
    }
    // keys.propertyNames restricts key names to the same provider set.
    const keys = v.object.get("properties").?.object.get("keys").?.object;
    const kenum = keys.get("propertyNames").?.object.get("enum").?.array;
    try testing.expectEqual(@as(usize, cfgmod.providers.len), kenum.items.len);
}

test "schema: constraints mirror config validate ranges" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const props = (try parsedSchema(a)).object.get("properties").?.object;

    const temp = props.get("temperature").?.object;
    try testing.expectEqual(@as(i64, 0), temp.get("minimum").?.integer);

    const thresh = props.get("compact_threshold").?.object;
    try testing.expectEqual(@as(i64, 0), thresh.get("minimum").?.integer);
    try testing.expectEqual(@as(i64, 1), thresh.get("maximum").?.integer);

    const max_tokens = props.get("max_tokens").?.object;
    try testing.expectEqual(@as(i64, 0), max_tokens.get("minimum").?.integer);
    try testing.expectEqual(@as(i64, std.math.maxInt(u32)), max_tokens.get("maximum").?.integer);

    // i64 fields (timeout_ms) get a floor but no ceiling.
    const timeout = props.get("timeout_ms").?.object;
    try testing.expectEqual(@as(i64, 0), timeout.get("minimum").?.integer);
    try testing.expect(timeout.get("maximum") == null);

    const mode = props.get("mode").?.object;
    try testing.expectEqual(@as(usize, 2), mode.get("enum").?.array.items.len);
}

test "schema: checked-in schema file matches the emitted document" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    // zig build test runs with cwd = repo root. If this fails after a
    // FileConfig/metadata change, regenerate:
    //   zig build && ./zig-out/bin/tau config schema > schema/tau-config.schema.json
    const on_disk = std.Io.Dir.cwd().readFileAlloc(testing.io, "schema/tau-config.schema.json", a, .unlimited) catch {
        std.debug.print("schema/tau-config.schema.json missing — generate it: ./zig-out/bin/tau config schema > schema/tau-config.schema.json\n", .{});
        return error.TestFailed;
    };
    const emitted = try schemaJson(a);
    if (!std.mem.eql(u8, on_disk, emitted)) {
        std.debug.print("schema/tau-config.schema.json is stale — regenerate: ./zig-out/bin/tau config schema > schema/tau-config.schema.json\n", .{});
        return error.TestFailed;
    }
}

test "docs/config.md generated reference mirrors the schema" {
    const gpa = testing.allocator;
    const doc = try std.Io.Dir.cwd().readFileAlloc(testing.io, "docs/config.md", gpa, .unlimited);
    defer gpa.free(doc);
    // The file must declare itself generated so nobody hand-edits it.
    try testing.expect(std.mem.indexOf(u8, doc, "GENERATED FILE") != null);
    try testing.expect(std.mem.indexOf(u8, doc, "scripts/gen-config-doc.py") != null);
    inline for (file_fields) |f| {
        // Every config key must appear as a table row with its schema
        // description — regenerate docs/config.md if this fails:
        //   python3 scripts/gen-config-doc.py
        var buf: [80]u8 = undefined;
        const row = std.fmt.bufPrint(&buf, "| `{s}` |", .{f.name}) catch unreachable;
        if (std.mem.indexOf(u8, doc, row) == null) {
            std.debug.print("docs/config.md missing key row '{s}'\n", .{row});
            return error.TestUnexpectedResult;
        }
        const desc = comptime fieldMeta(f.name).desc;
        if (std.mem.indexOf(u8, doc, desc) == null) {
            std.debug.print("docs/config.md missing description for key '{s}'\n", .{f.name});
            return error.TestUnexpectedResult;
        }
    }
}
