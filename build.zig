const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create module for this SDK
    const mod = b.addModule("yahoo_fantasy_sdk", .{
        .root_source_file = b.path("root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add tests
    const tests = b.addTest(.{
        .root_module = mod,
    });

    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
