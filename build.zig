const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Use --release flag or fall back to Debug
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "pizig",
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

    b.installArtifact(exe);

    // zig build run — run directly
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run pizig");
    run_step.dependOn(&run_cmd.step);

    // zig build test — run unit tests
    const exe_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}