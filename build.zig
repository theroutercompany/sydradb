const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const is015 = builtin.zig_version.major == 0 and builtin.zig_version.minor >= 15;
    const allocator_mode_str = b.option([]const u8, "allocator-mode", "Allocator strategy (default: mimalloc): default | mimalloc | small_pool") orelse "mimalloc";
    const allocator_shards = b.option(u32, "allocator-shards", "Number of shard allocators for small_pool (0 disables sharding)") orelse 0;
    const use_mimalloc = std.mem.eql(u8, allocator_mode_str, "mimalloc");
    const use_small_pool = std.mem.eql(u8, allocator_mode_str, "small_pool");
    if (use_mimalloc and use_small_pool) @panic("allocator-mode 'mimalloc' and 'small_pool' are mutually exclusive");

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "allocator_mode", allocator_mode_str);
    build_options.addOption(u32, "allocator_shards", allocator_shards);
    const build_options_module = build_options.createModule();

    const mimalloc_include = b.path("vendor/mimalloc/include");
    const mimalloc_src_dir = b.path("vendor/mimalloc/src");
    const mimalloc_c_file = b.path("vendor/mimalloc/src/static.c");
    const mimalloc_flags = &.{ "-DMI_STATIC_LIB", "-DMIMALLOC_STATIC_LIB", "-DMI_SEE_AS_DLL=0", "-Ivendor/mimalloc/include", "-Ivendor/mimalloc/src" };

    const exe = if (is015) blk: {
        const root_mod = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize });
        root_mod.addImport("build_options", build_options_module);
        if (use_mimalloc) {
            root_mod.addIncludePath(mimalloc_include);
            root_mod.addIncludePath(mimalloc_src_dir);
        }
        break :blk b.addExecutable(.{ .name = "sydradb", .root_module = root_mod });
    } else blk: {
        const exe_inner = b.addExecutable(.{ .name = "sydradb", .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize });
        exe_inner.root_module.addImport("build_options", build_options_module);
        if (use_mimalloc) {
            exe_inner.addIncludePath(mimalloc_include);
            exe_inner.addIncludePath(mimalloc_src_dir);
        }
        break :blk exe_inner;
    };
    const os_tag = target.result.os.tag;

    if (use_mimalloc) {
        exe.addCSourceFile(.{ .file = mimalloc_c_file, .flags = mimalloc_flags });
        exe.linkLibC();
        exe.linkSystemLibrary("pthread");
    } else {
        exe.linkLibC();
        if (os_tag == .linux) exe.linkSystemLibrary("pthread");
    }

    b.installArtifact(exe);
    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run sydraDB").dependOn(&run_cmd.step);

    const unit_tests = if (is015) blk2: {
        const root_mod = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize });
        root_mod.addImport("build_options", build_options_module);
        if (use_mimalloc) {
            root_mod.addIncludePath(mimalloc_include);
            root_mod.addIncludePath(mimalloc_src_dir);
        }
        break :blk2 b.addTest(.{ .root_module = root_mod });
    } else blk2: {
        const test_step = b.addTest(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize });
        test_step.root_module.addImport("build_options", build_options_module);
        if (use_mimalloc) {
            test_step.addIncludePath(mimalloc_include);
            test_step.addIncludePath(mimalloc_src_dir);
            test_step.addCSourceFile(.{ .file = mimalloc_c_file, .flags = mimalloc_flags });
            test_step.linkLibC();
            test_step.linkSystemLibrary("pthread");
        }
        break :blk2 test_step;
    };
    if (use_mimalloc and is015) {
        unit_tests.addCSourceFile(.{ .file = mimalloc_c_file, .flags = mimalloc_flags });
        unit_tests.linkLibC();
        unit_tests.linkSystemLibrary("pthread");
    } else if (!use_mimalloc) {
        unit_tests.linkLibC();
        if (os_tag == .linux) unit_tests.linkSystemLibrary("pthread");
    }

    const test_run = b.addRunArtifact(unit_tests);
    b.step("test", "Run tests").dependOn(&test_run.step);

    const pgwire_tests = if (is015) blk3: {
        const mod = b.createModule(.{ .root_source_file = b.path("src/sydra/compat/wire/server.zig"), .target = target, .optimize = optimize });
        mod.addImport("build_options", build_options_module);
        if (use_mimalloc) {
            mod.addIncludePath(mimalloc_include);
            mod.addIncludePath(mimalloc_src_dir);
        }
        break :blk3 b.addTest(.{ .root_module = mod });
    } else blk3: {
        const compat_step = b.addTest(.{ .root_source_file = b.path("src/sydra/compat/wire/server.zig"), .target = target, .optimize = optimize });
        compat_step.root_module.addImport("build_options", build_options_module);
        if (use_mimalloc) {
            compat_step.addIncludePath(mimalloc_include);
            compat_step.addIncludePath(mimalloc_src_dir);
            compat_step.addCSourceFile(.{ .file = mimalloc_c_file, .flags = mimalloc_flags });
            compat_step.linkLibC();
            compat_step.linkSystemLibrary("pthread");
        }
        break :blk3 compat_step;
    };
    if (use_mimalloc and is015) {
        pgwire_tests.addCSourceFile(.{ .file = mimalloc_c_file, .flags = mimalloc_flags });
        pgwire_tests.linkLibC();
        pgwire_tests.linkSystemLibrary("pthread");
    } else if (!use_mimalloc) {
        pgwire_tests.linkLibC();
        if (os_tag == .linux) pgwire_tests.linkSystemLibrary("pthread");
    }

    const pgwire_run = b.addRunArtifact(pgwire_tests);
    b.step("compat-wire-test", "Run PostgreSQL wire compatibility tests").dependOn(&pgwire_run.step);

    const tooling_module = blk_init: {
        const mod = b.createModule(.{ .root_source_file = b.path("src/sydra/tooling.zig"), .target = target, .optimize = optimize });
        mod.addImport("build_options", build_options_module);
        if (use_mimalloc) {
            mod.addIncludePath(mimalloc_include);
            mod.addIncludePath(mimalloc_src_dir);
        }
        break :blk_init mod;
    };

    const bench_exe = if (is015) blk4: {
        const root_mod = b.createModule(.{ .root_source_file = b.path("tools/bench_alloc.zig"), .target = target, .optimize = optimize });
        root_mod.addImport("build_options", build_options_module);
        root_mod.addImport("sydra_tooling", tooling_module);
        if (use_mimalloc) {
            root_mod.addIncludePath(mimalloc_include);
            root_mod.addIncludePath(mimalloc_src_dir);
        }
        break :blk4 b.addExecutable(.{ .name = "bench_alloc", .root_module = root_mod });
    } else blk4: {
        const exe_inner = b.addExecutable(.{ .name = "bench_alloc", .root_source_file = b.path("tools/bench_alloc.zig"), .target = target, .optimize = optimize });
        exe_inner.root_module.addImport("build_options", build_options_module);
        exe_inner.root_module.addImport("sydra_tooling", tooling_module);
        if (use_mimalloc) {
            exe_inner.addIncludePath(mimalloc_include);
            exe_inner.addIncludePath(mimalloc_src_dir);
            exe_inner.addCSourceFile(.{ .file = mimalloc_c_file, .flags = mimalloc_flags });
            exe_inner.linkLibC();
            exe_inner.linkSystemLibrary("pthread");
        }
        break :blk4 exe_inner;
    };

    if (use_mimalloc and is015) {
        bench_exe.addCSourceFile(.{ .file = mimalloc_c_file, .flags = mimalloc_flags });
        bench_exe.linkLibC();
        bench_exe.linkSystemLibrary("pthread");
    } else if (!use_mimalloc) {
        bench_exe.linkLibC();
        if (os_tag == .linux) bench_exe.linkSystemLibrary("pthread");
    }

    const bench_run = b.addRunArtifact(bench_exe);
    if (b.args) |args| bench_run.addArgs(args);
    b.step("bench-alloc", "Run allocator ingest benchmark").dependOn(&bench_run.step);
}
