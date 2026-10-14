const std = @import("std");

/// Short hash of HEAD baked into the binary ("-dirty" when the worktree has
/// uncommitted changes). Falls back to "unknown" outside a git checkout —
/// e.g. release tarballs — so the build never fails over metadata. Success is
/// judged by stdout, not the exit code: rev-parse prints nothing to stdout
/// when HEAD can't be resolved, and a short hash is all hex digits.
fn gitCommit(b: *std.Build) []const u8 {
    var code: u8 = undefined;
    const out = b.runAllowFail(&.{ "git", "rev-parse", "--short", "HEAD" }, &code, .ignore) catch return "unknown";
    const commit = std.mem.trim(u8, out, " \t\r\n");
    if (commit.len == 0) return "unknown";
    for (commit) |c| {
        if (!std.ascii.isHex(c)) return "unknown";
    }
    const status = b.runAllowFail(&.{ "git", "status", "--porcelain" }, &code, .ignore) catch return commit;
    const dirty = std.mem.trim(u8, status, " \t\r\n").len > 0;
    return if (dirty) b.fmt("{s}-dirty", .{commit}) else commit;
}

/// `YYYY-MM-DDTHH:MM:SSZ` build stamp. SOURCE_DATE_EPOCH (reproducible-builds
/// convention) wins so release binaries stay byte-identical; otherwise the
/// wall-clock build time is embedded.
fn buildDate(b: *std.Build) []const u8 {
    const epoch_secs: u64 = blk: {
        if (b.graph.environ_map.get("SOURCE_DATE_EPOCH")) |raw| {
            if (std.fmt.parseInt(u64, std.mem.trim(u8, raw, " \t\r\n"), 10)) |s| break :blk s else |_| {}
        }
        break :blk @intCast(@max(std.Io.Timestamp.now(b.graph.io, .real).toSeconds(), 0));
    };
    const es = std.time.epoch.EpochSeconds{ .secs = epoch_secs };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return b.fmt("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        yd.year,                md.month.numeric(),       md.day_index + 1,
        ds.getHoursIntoDay(),   ds.getMinutesIntoHour(),  ds.getSecondsIntoMinute(),
    });
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Use --release flag or fall back to Debug
    const optimize = b.standardOptimizeOption(.{});

    // Build metadata surfaced by `tau version --verbose`, the `tau doctor`
    // report/verdict, and the --debug log header. Target triple and zig
    // version come from `builtin` at comptime; commit/date are captured here.
    const buildinfo = b.addOptions();
    buildinfo.addOption([]const u8, "git_commit", gitCommit(b));
    buildinfo.addOption([]const u8, "build_date", buildDate(b));
    const buildinfo_module = buildinfo.createModule();

    const exe = b.addExecutable(.{
        .name = "tau",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Add llm module for provider abstraction
    const llm_module = b.createModule(.{
        .root_source_file = b.path("src/llm/provider.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("llm", llm_module);

    // Add tools module
    const tools_module = b.createModule(.{
        .root_source_file = b.path("src/tools/registry.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("tools", tools_module);

    // Embed the shipped shell-completion scripts into the binary so `tau
    // setup` can install them without depending on a source checkout.
    // completions/ stays the single source of truth.
    const wf = b.addWriteFiles();
    const completions_module = b.createModule(.{
        .root_source_file = wf.add("completions.zig",
            \\pub const bash = @embedFile("tau.bash");
            \\pub const zsh = @embedFile("_tau");
            \\pub const fish = @embedFile("tau.fish");
            \\pub const pwsh = @embedFile("tau.ps1");
            \\
        ),
        .target = target,
        .optimize = optimize,
    });
    _ = wf.addCopyFile(b.path("completions/tau.bash"), "tau.bash");
    _ = wf.addCopyFile(b.path("completions/_tau"), "_tau");
    _ = wf.addCopyFile(b.path("completions/tau.fish"), "tau.fish");
    _ = wf.addCopyFile(b.path("completions/tau.ps1"), "tau.ps1");
    exe.root_module.addImport("completions", completions_module);
    exe.root_module.addImport("build_options", buildinfo_module);

    b.installArtifact(exe);

    // zig build run — run directly
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run tau");
    run_step.dependOn(&run_cmd.step);

    // zig build test — run unit tests
    const exe_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe_tests.root_module.addImport("completions", completions_module);
    exe_tests.root_module.addImport("build_options", buildinfo_module);
    const run_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}