const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const is015 = builtin.zig_version.major == 0 and builtin.zig_version.minor >= 15;

    const exe = if (is015) blk: {
        const root_mod = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize });
        break :blk b.addExecutable(.{ .name = "sydradb", .root_module = root_mod });
    } else blk: {
        break :blk b.addExecutable(.{ .name = "sydradb", .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize });
    };

    b.installArtifact(exe);
    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run sydraDB").dependOn(&run_cmd.step);

    const unit_tests = if (is015) blk2: {
        const root_mod = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize });
        break :blk2 b.addTest(.{ .root_module = root_mod });
    } else blk2: {
        break :blk2 b.addTest(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize });
    };

    const test_run = b.addRunArtifact(unit_tests);
    b.step("test", "Run tests").dependOn(&test_run.step);
}
