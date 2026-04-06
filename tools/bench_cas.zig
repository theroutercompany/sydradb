const std = @import("std");
const sydra = @import("sydra_tooling");
const cas_mod = sydra.cas;
const cfg = sydra.config;
const engine_mod = sydra.engine;
const manifest_mod = sydra.manifest;
const series_catalog_mod = sydra.series_catalog;
const tags_mod = sydra.tags;
const types = sydra.types;

fn sleepMs(ms: u64) void {
    if (@hasDecl(std.time, "sleep")) {
        std.time.sleep(ms * std.time.ns_per_ms);
    } else {
        std.Thread.sleep(ms * std.time.ns_per_ms);
    }
}

fn microsToMillis(value: u64) f64 {
    return @as(f64, @floatFromInt(value)) / 1000.0;
}

fn makeConfig(
    alloc: std.mem.Allocator,
    data_dir: []const u8,
    cas_mode: cfg.CasMode,
    metadata_read_mode: cfg.MetadataReadMode,
) !cfg.Config {
    return .{
        .data_dir = try alloc.dupe(u8, data_dir),
        .http_port = 0,
        .fsync = .none,
        .flush_interval_ms = 25,
        .memtable_max_bytes = 16 * 1024,
        .retention_days = 0,
        .auth_token = try alloc.dupe(u8, ""),
        .enable_influx = false,
        .enable_prom = false,
        .mem_limit_bytes = 512 * 1024 * 1024,
        .cas_mode = cas_mode,
        .metadata_read_mode = metadata_read_mode,
        .query_compiler_mode = .compiled,
        .retention_ns = std.StringHashMap(u32).init(alloc),
    };
}

fn waitForQueueEmpty(engine: *engine_mod.Engine, timeout_ms: u64) !void {
    const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
    while (std.time.milliTimestamp() < deadline) {
        if (engine.queue.len() == 0) return;
        sleepMs(10);
    }
    return error.Timeout;
}

fn seedRepo(
    alloc: std.mem.Allocator,
    data_path: []const u8,
    series_count: usize,
    points_per_series: usize,
    ts_offset: i64,
) !void {
    const config = try makeConfig(alloc, data_path, .off, .legacy);
    var engine = try engine_mod.Engine.init(alloc, config);

    var series_idx: usize = 0;
    while (series_idx < series_count) : (series_idx += 1) {
        const series_name = try std.fmt.allocPrint(alloc, "cas.bench.{d}", .{series_idx});
        defer alloc.free(series_name);
        const tags_json = switch (series_idx % 3) {
            0 => "{\"service\":\"web\"}",
            1 => "{\"service\":\"api\"}",
            else => "{\"service\":\"db\"}",
        };
        const sid = types.seriesIdFrom(series_name, tags_json);
        try engine.registerSeries(series_name, tags_json, sid);

        var point_idx: usize = 0;
        while (point_idx < points_per_series) : (point_idx += 1) {
            try engine.ingest(.{
                .series_id = sid,
                .ts = ts_offset + @as(i64, @intCast(series_idx * 10_000 + point_idx * 60)),
                .value = @as(f64, @floatFromInt((series_idx + point_idx) % 97)),
                .tags_json = tags_json,
            });
        }
    }

    try waitForQueueEmpty(engine, 10_000);
    engine.deinit();

    var data_dir = try std.fs.cwd().openDir(data_path, .{ .iterate = true });
    defer data_dir.close();
    data_dir.deleteFile("wal/current.wal") catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn bootstrapHead(alloc: std.mem.Allocator, cas: *cas_mod.CasManager, data_dir: std.fs.Dir) !void {
    var manifest = try manifest_mod.Manifest.loadOrInit(alloc, data_dir);
    defer manifest.deinit();
    var tags = try tags_mod.TagIndex.loadOrInit(alloc, data_dir);
    defer tags.deinit();
    var series_catalog = try series_catalog_mod.SeriesCatalog.loadOrInit(alloc, data_dir, .none);
    defer series_catalog.deinit();
    _ = try cas.bootstrapIfMissing(data_dir, &manifest, &tags, &series_catalog);
}

fn runFreshPrimaryScenario(alloc: std.mem.Allocator) !void {
    const data_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/bench-cas-fresh-{d}", .{std.time.nanoTimestamp()});
    defer alloc.free(data_path);
    const bundle_path = try std.fmt.allocPrint(alloc, "{s}-bundle", .{data_path});
    defer alloc.free(bundle_path);
    const restore_path = try std.fmt.allocPrint(alloc, "{s}-restore", .{data_path});
    defer alloc.free(restore_path);

    try seedRepo(alloc, data_path, 32, 64, 0);

    var data_dir = try std.fs.cwd().openDir(data_path, .{ .iterate = true });
    defer data_dir.close();
    var cas = try cas_mod.CasManager.init(alloc, data_path, .none);
    defer cas.deinit();
    try bootstrapHead(alloc, &cas, data_dir);
    _ = try cas.upgradeRepository(data_dir);

    const bundle_create_start = std.time.microTimestamp();
    const created = try cas_mod.createBundle(alloc, data_path, bundle_path, .none, null);
    const bundle_create_end = std.time.microTimestamp();

    const bundle_verify_start = std.time.microTimestamp();
    const verified = try cas_mod.verifyBundle(alloc, bundle_path);
    const bundle_verify_end = std.time.microTimestamp();

    const bundle_apply_start = std.time.microTimestamp();
    const applied = try cas_mod.applyBundle(alloc, bundle_path, restore_path, .none);
    const bundle_apply_end = std.time.microTimestamp();

    const fsck_start = std.time.microTimestamp();
    const fsck = try cas.fsck(data_dir, .{});
    const fsck_end = std.time.microTimestamp();

    std.debug.print(
        "fresh_primary bundle_create_ms={d:.3} bundle_verify_ms={d:.3} bundle_apply_ms={d:.3} fsck_ms={d:.3} refs={d}/{d}/{d} objects={d}/{d}/{d} packs={d}/{d}/{d} reftable_files={d}/{d}/{d} reachable={d}\n",
        .{
            microsToMillis(@as(u64, @intCast(bundle_create_end - bundle_create_start))),
            microsToMillis(@as(u64, @intCast(bundle_verify_end - bundle_verify_start))),
            microsToMillis(@as(u64, @intCast(bundle_apply_end - bundle_apply_start))),
            microsToMillis(@as(u64, @intCast(fsck_end - fsck_start))),
            created.ref_count,
            verified.ref_count,
            applied.ref_count,
            created.object_count,
            verified.object_count,
            applied.object_count,
            created.pack_count,
            verified.pack_count,
            applied.pack_count,
            created.reftable_file_count,
            verified.reftable_file_count,
            applied.reftable_file_count,
            fsck.reachable_objects,
        },
    );
}

fn runPackedLocalScenario(alloc: std.mem.Allocator) !void {
    const source_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/bench-cas-packed-{d}", .{std.time.nanoTimestamp()});
    defer alloc.free(source_path);
    const clone_path = try std.fmt.allocPrint(alloc, "{s}-clone", .{source_path});
    defer alloc.free(clone_path);
    const fetch_path = try std.fmt.allocPrint(alloc, "{s}-fetch", .{source_path});
    defer alloc.free(fetch_path);

    try seedRepo(alloc, source_path, 64, 64, 0);

    var pack_start: i64 = 0;
    var pack_end: i64 = 0;
    var clone_start: i64 = 0;
    var clone_end: i64 = 0;
    var fetch_start: i64 = 0;
    var fetch_end: i64 = 0;
    var pack_result: cas_mod.PackResult = undefined;
    var cloned: cas_mod.BundleResult = undefined;
    var fetched: cas_mod.LocalExchangeResult = undefined;

    {
        var source_dir = try std.fs.cwd().openDir(source_path, .{ .iterate = true });
        defer source_dir.close();
        var source = try cas_mod.CasManager.init(alloc, source_path, .none);
        defer source.deinit();
        try bootstrapHead(alloc, &source, source_dir);
        _ = try source.upgradeRepository(source_dir);

        pack_start = std.time.microTimestamp();
        pack_result = try source.pack();
        pack_end = std.time.microTimestamp();

        clone_start = std.time.microTimestamp();
        cloned = try cas_mod.cloneLocalRepository(alloc, source_path, clone_path, .none);
        clone_end = std.time.microTimestamp();

        fetch_start = std.time.microTimestamp();
        fetched = try cas_mod.fetchLocalRepositoryWithOptions(alloc, source_path, fetch_path, .none, .{ .materialize = true });
        fetch_end = std.time.microTimestamp();
    }

    const push_start = std.time.microTimestamp();
    const pushed = try cas_mod.pushLocalRepositoryWithOptions(alloc, source_path, clone_path, .none, .{});
    const push_end = std.time.microTimestamp();

    std.debug.print(
        "packed_local pack_ms={d:.3} clone_ms={d:.3} fetch_ms={d:.3} push_ms={d:.3} rewritten={d} clone_refs={d} clone_packs={d} clone_reftable_files={d} fetch_refs={d} fetch_borrowed={d} push_refs={d} push_borrowed={d}\n",
        .{
            microsToMillis(@as(u64, @intCast(pack_end - pack_start))),
            microsToMillis(@as(u64, @intCast(clone_end - clone_start))),
            microsToMillis(@as(u64, @intCast(fetch_end - fetch_start))),
            microsToMillis(@as(u64, @intCast(push_end - push_start))),
            pack_result.rewritten_objects,
            cloned.ref_count,
            cloned.pack_count,
            cloned.reftable_file_count,
            fetched.ref_count,
            fetched.borrowed_repositories,
            pushed.ref_count,
            pushed.borrowed_repositories,
        },
    );
}

fn runMigratedLegacyScenario(alloc: std.mem.Allocator) !void {
    const legacy_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/bench-cas-legacy-{d}", .{std.time.nanoTimestamp()});
    defer alloc.free(legacy_path);

    try seedRepo(alloc, legacy_path, 24, 48, 5_000_000);

    var data_dir = try std.fs.cwd().openDir(legacy_path, .{ .iterate = true });
    defer data_dir.close();
    var cas = try cas_mod.CasManager.init(alloc, legacy_path, .none);
    defer cas.deinit();
    try bootstrapHead(alloc, &cas, data_dir);

    const upgrade_start = std.time.microTimestamp();
    const upgraded = try cas.upgradeRepository(data_dir);
    const upgrade_end = std.time.microTimestamp();

    const vacuum_start = std.time.microTimestamp();
    const vacuum = try cas.vacuumWithPolicy(data_dir, .{
        .repair_side_indexes = true,
        .prune_grace_ms = 0,
    });
    const vacuum_end = std.time.microTimestamp();

    const fsck_start = std.time.microTimestamp();
    const fsck = try cas.fsck(data_dir, .{});
    const fsck_end = std.time.microTimestamp();

    std.debug.print(
        "migrated_legacy upgrade_ms={d:.3} vacuum_ms={d:.3} fsck_ms={d:.3} normalized_commits={d} reachable={d} rewritten={d} unreachable={d} pruned={d} deleted={d} legacy_segment_debt={d} legacy_wal_debt={d}\n",
        .{
            microsToMillis(@as(u64, @intCast(upgrade_end - upgrade_start))),
            microsToMillis(@as(u64, @intCast(vacuum_end - vacuum_start))),
            microsToMillis(@as(u64, @intCast(fsck_end - fsck_start))),
            upgraded.normalized_commits,
            vacuum.pack.reachable_objects,
            vacuum.pack.rewritten_objects,
            vacuum.gc.unreachable_count,
            vacuum.gc.pruned_count,
            vacuum.gc.deleted,
            fsck.compatibility_debt.legacy_segment_descriptors,
            fsck.compatibility_debt.legacy_wal_descriptors,
        },
    );
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    try runFreshPrimaryScenario(alloc);
    try runPackedLocalScenario(alloc);
    try runMigratedLegacyScenario(alloc);
}
