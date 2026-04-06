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

    const demo_smoke = b.step("demo-smoke", "Run alpha demo and CLI ingest smoke checks");
    const cli_ingest_smoke_step = b.step("cli-ingest-smoke", "Run CLI ingest regression smoke");
    const repo_root = b.path(".");

    const cli_ingest_smoke = b.addSystemCommand(&.{
        "bash",
        "-lc",
        "tmpdir=$(mktemp -d \"${TMPDIR:-/tmp}/sydra-cli-ingest.XXXXXX\") && trap 'rm -rf \"$tmpdir\"' EXIT && cat >\"$tmpdir/sydradb.toml\" <<'EOF'\n" ++ "data_dir = \"./data\"\n" ++ "http_port = 0\n" ++ "fsync = \"none\"\n" ++ "flush_interval_ms = 25\n" ++ "memtable_max_bytes = 32768\n" ++ "mem_limit_bytes = 268435456\n" ++ "auth_token = \"\"\n" ++ "enable_influx = false\n" ++ "enable_prom = false\n" ++ "cas_mode = \"dual_write\"\n" ++ "metadata_read_mode = \"primary\"\n" ++ "query_compiler_mode = \"compiled\"\n" ++ "retention_days = 0\n" ++ "EOF\n" ++ "(cd \"$tmpdir\" && printf '{\"series\":\"smoke.cli\",\"ts\":10,\"value\":1.0}\\n{\"series\":\"smoke.cli\",\"ts\":20,\"value\":2.0}\\n' | \"$1\" ingest >/dev/null)",
        "cli-ingest-smoke",
    });
    cli_ingest_smoke.addArtifactArg(exe);
    cli_ingest_smoke.setCwd(repo_root);
    cli_ingest_smoke.step.dependOn(b.getInstallStep());
    cli_ingest_smoke_step.dependOn(&cli_ingest_smoke.step);
    demo_smoke.dependOn(&cli_ingest_smoke.step);

    const quickstart_smoke = b.addSystemCommand(&.{ "bash", "-lc", "SYDRADB_BIN=\"$1\" bash demos/demo-quickstart.sh", "demo-quickstart" });
    quickstart_smoke.addArtifactArg(exe);
    quickstart_smoke.setCwd(repo_root);
    quickstart_smoke.step.dependOn(b.getInstallStep());
    demo_smoke.dependOn(&quickstart_smoke.step);

    const sydraql_smoke = b.addSystemCommand(&.{ "bash", "-lc", "SYDRADB_BIN=\"$1\" bash demos/demo-sydraql-compiled.sh", "demo-sydraql-compiled" });
    sydraql_smoke.addArtifactArg(exe);
    sydraql_smoke.setCwd(repo_root);
    sydraql_smoke.step.dependOn(b.getInstallStep());
    demo_smoke.dependOn(&sydraql_smoke.step);

    const cas_smoke = b.addSystemCommand(&.{ "bash", "-lc", "SYDRADB_BIN=\"$1\" bash demos/demo-cas-lifecycle.sh", "demo-cas-lifecycle" });
    cas_smoke.addArtifactArg(exe);
    cas_smoke.setCwd(repo_root);
    cas_smoke.step.dependOn(b.getInstallStep());
    demo_smoke.dependOn(&cas_smoke.step);

    const pgwire_smoke = b.addSystemCommand(&.{ "bash", "-lc", "SYDRADB_BIN=\"$1\" bash demos/demo-pgwire-preview.sh", "demo-pgwire-preview" });
    pgwire_smoke.addArtifactArg(exe);
    pgwire_smoke.setCwd(repo_root);
    pgwire_smoke.step.dependOn(b.getInstallStep());
    demo_smoke.dependOn(&pgwire_smoke.step);

    const local_ingest_socket_smoke = b.addSystemCommand(&.{ "bash", "-lc", "SYDRADB_BIN=\"$1\" bash demos/demo-local-ingest-socket.sh", "demo-local-ingest-socket" });
    local_ingest_socket_smoke.addArtifactArg(exe);
    local_ingest_socket_smoke.setCwd(repo_root);
    local_ingest_socket_smoke.step.dependOn(b.getInstallStep());
    demo_smoke.dependOn(&local_ingest_socket_smoke.step);

    const combined_http_socket_smoke = b.addSystemCommand(&.{ "bash", "-lc", "SYDRADB_BIN=\"$1\" bash demos/demo-combined-http-socket.sh", "demo-combined-http-socket" });
    combined_http_socket_smoke.addArtifactArg(exe);
    combined_http_socket_smoke.setCwd(repo_root);
    combined_http_socket_smoke.step.dependOn(b.getInstallStep());
    demo_smoke.dependOn(&combined_http_socket_smoke.step);

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
        const mod = b.createModule(.{ .root_source_file = b.path("src/compat_wire_tests.zig"), .target = target, .optimize = optimize });
        mod.addImport("build_options", build_options_module);
        if (use_mimalloc) {
            mod.addIncludePath(mimalloc_include);
            mod.addIncludePath(mimalloc_src_dir);
        }
        break :blk3 b.addTest(.{ .root_module = mod, .filters = &.{"sydra.compat.wire"} });
    } else blk3: {
        const compat_step = b.addTest(.{ .root_source_file = b.path("src/compat_wire_tests.zig"), .target = target, .optimize = optimize, .filters = &.{"sydra.compat.wire"} });
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
    const bench_smoke = b.step("bench-smoke", "Run allocator, sydraQL, and CAS benchmark smoke scenarios");
    bench_smoke.dependOn(&bench_run.step);

    const bench_sydraql_exe = if (is015) blk5: {
        const root_mod = b.createModule(.{ .root_source_file = b.path("tools/bench_sydraql.zig"), .target = target, .optimize = optimize });
        root_mod.addImport("build_options", build_options_module);
        root_mod.addImport("sydra_tooling", tooling_module);
        if (use_mimalloc) {
            root_mod.addIncludePath(mimalloc_include);
            root_mod.addIncludePath(mimalloc_src_dir);
        }
        break :blk5 b.addExecutable(.{ .name = "bench_sydraql", .root_module = root_mod });
    } else blk5: {
        const exe_inner = b.addExecutable(.{ .name = "bench_sydraql", .root_source_file = b.path("tools/bench_sydraql.zig"), .target = target, .optimize = optimize });
        exe_inner.root_module.addImport("build_options", build_options_module);
        exe_inner.root_module.addImport("sydra_tooling", tooling_module);
        if (use_mimalloc) {
            exe_inner.addIncludePath(mimalloc_include);
            exe_inner.addIncludePath(mimalloc_src_dir);
            exe_inner.addCSourceFile(.{ .file = mimalloc_c_file, .flags = mimalloc_flags });
            exe_inner.linkLibC();
            exe_inner.linkSystemLibrary("pthread");
        }
        break :blk5 exe_inner;
    };

    if (use_mimalloc and is015) {
        bench_sydraql_exe.addCSourceFile(.{ .file = mimalloc_c_file, .flags = mimalloc_flags });
        bench_sydraql_exe.linkLibC();
        bench_sydraql_exe.linkSystemLibrary("pthread");
    } else if (!use_mimalloc) {
        bench_sydraql_exe.linkLibC();
        if (os_tag == .linux) bench_sydraql_exe.linkSystemLibrary("pthread");
    }

    const bench_sydraql_run = b.addRunArtifact(bench_sydraql_exe);
    if (b.args) |args| bench_sydraql_run.addArgs(args);
    b.step("bench-sydraql", "Run compiled SydraQL benchmark scenarios").dependOn(&bench_sydraql_run.step);
    bench_smoke.dependOn(&bench_sydraql_run.step);

    const bench_cas_exe = if (is015) blk6: {
        const root_mod = b.createModule(.{ .root_source_file = b.path("tools/bench_cas.zig"), .target = target, .optimize = optimize });
        root_mod.addImport("build_options", build_options_module);
        root_mod.addImport("sydra_tooling", tooling_module);
        if (use_mimalloc) {
            root_mod.addIncludePath(mimalloc_include);
            root_mod.addIncludePath(mimalloc_src_dir);
        }
        break :blk6 b.addExecutable(.{ .name = "bench_cas", .root_module = root_mod });
    } else blk6: {
        const exe_inner = b.addExecutable(.{ .name = "bench_cas", .root_source_file = b.path("tools/bench_cas.zig"), .target = target, .optimize = optimize });
        exe_inner.root_module.addImport("build_options", build_options_module);
        exe_inner.root_module.addImport("sydra_tooling", tooling_module);
        if (use_mimalloc) {
            exe_inner.addIncludePath(mimalloc_include);
            exe_inner.addIncludePath(mimalloc_src_dir);
            exe_inner.addCSourceFile(.{ .file = mimalloc_c_file, .flags = mimalloc_flags });
            exe_inner.linkLibC();
            exe_inner.linkSystemLibrary("pthread");
        }
        break :blk6 exe_inner;
    };

    if (use_mimalloc and is015) {
        bench_cas_exe.addCSourceFile(.{ .file = mimalloc_c_file, .flags = mimalloc_flags });
        bench_cas_exe.linkLibC();
        bench_cas_exe.linkSystemLibrary("pthread");
    } else if (!use_mimalloc) {
        bench_cas_exe.linkLibC();
        if (os_tag == .linux) bench_cas_exe.linkSystemLibrary("pthread");
    }

    const bench_cas_run = b.addRunArtifact(bench_cas_exe);
    if (b.args) |args| bench_cas_run.addArgs(args);
    b.step("bench-cas", "Run CAS bundle maintenance and local transfer benchmarks").dependOn(&bench_cas_run.step);
    bench_smoke.dependOn(&bench_cas_run.step);

    const bench_transport_exe = if (is015) blk7: {
        const root_mod = b.createModule(.{ .root_source_file = b.path("tools/bench_ingest_transport.zig"), .target = target, .optimize = optimize });
        root_mod.addImport("build_options", build_options_module);
        root_mod.addImport("sydra_tooling", tooling_module);
        if (use_mimalloc) {
            root_mod.addIncludePath(mimalloc_include);
            root_mod.addIncludePath(mimalloc_src_dir);
        }
        break :blk7 b.addExecutable(.{ .name = "bench_ingest_transport", .root_module = root_mod });
    } else blk7: {
        const exe_inner = b.addExecutable(.{ .name = "bench_ingest_transport", .root_source_file = b.path("tools/bench_ingest_transport.zig"), .target = target, .optimize = optimize });
        exe_inner.root_module.addImport("build_options", build_options_module);
        exe_inner.root_module.addImport("sydra_tooling", tooling_module);
        if (use_mimalloc) {
            exe_inner.addIncludePath(mimalloc_include);
            exe_inner.addIncludePath(mimalloc_src_dir);
            exe_inner.addCSourceFile(.{ .file = mimalloc_c_file, .flags = mimalloc_flags });
            exe_inner.linkLibC();
            exe_inner.linkSystemLibrary("pthread");
        }
        break :blk7 exe_inner;
    };

    if (use_mimalloc and is015) {
        bench_transport_exe.addCSourceFile(.{ .file = mimalloc_c_file, .flags = mimalloc_flags });
        bench_transport_exe.linkLibC();
        bench_transport_exe.linkSystemLibrary("pthread");
    } else if (!use_mimalloc) {
        bench_transport_exe.linkLibC();
        if (os_tag == .linux) bench_transport_exe.linkSystemLibrary("pthread");
    }

    const bench_transport_run = b.addRunArtifact(bench_transport_exe);
    bench_transport_run.step.dependOn(b.getInstallStep());
    if (b.args) |args| bench_transport_run.addArgs(args);
    b.step("bench-ingest-transport", "Run same-host ingest transport benchmark scenarios").dependOn(&bench_transport_run.step);

    const bench_transport_smoke_run = b.addRunArtifact(bench_transport_exe);
    bench_transport_smoke_run.step.dependOn(b.getInstallStep());
    bench_transport_smoke_run.addArgs(&.{ "--scenario", "one_hot_one_writer" });
    bench_smoke.dependOn(&bench_transport_smoke_run.step);
}
