const std = @import("std");
const config = @import("config.zig");
const engine_mod = @import("engine.zig");
const http = @import("http.zig");
const catalog = @import("catalog.zig");
const compat = @import("compat.zig");
const alloc_mod = @import("alloc.zig");
const cas_mod = @import("storage/cas.zig");

pub fn run(handle: *alloc_mod.AllocatorHandle) !void {
    const alloc = handle.allocator();
    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);
    if (args.len <= 1 or std.mem.eql(u8, args[1], "serve")) {
        var cfg = try loadConfigOrDefault(alloc);
        defer cfg.deinit(alloc);
        var eng = try engine_mod.Engine.init(alloc, cfg);
        defer eng.deinit();
        try catalog.bootstrap(alloc);
        std.debug.print("sydradb serve :{d}\n", .{cfg.http_port});
        try http.runHttp(handle, eng, cfg.http_port);
        return;
    }

    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "pgwire")) return cmdPgWire(alloc, args);
    if (std.mem.eql(u8, cmd, "ingest")) return cmdIngest(alloc, args);
    if (std.mem.eql(u8, cmd, "query")) return cmdQuery(alloc, args);
    if (std.mem.eql(u8, cmd, "compact")) return cmdCompact(alloc, args);
    if (std.mem.eql(u8, cmd, "snapshot")) return cmdSnapshot(alloc, args);
    if (std.mem.eql(u8, cmd, "restore")) return cmdRestore(alloc, args);
    if (std.mem.eql(u8, cmd, "stats")) return cmdStats(handle, alloc, args);
    if (std.mem.eql(u8, cmd, "cas")) return cmdCas(alloc, args);
}

fn loadConfigOrDefault(alloc: std.mem.Allocator) !config.Config {
    return config.load(alloc, "sydradb.toml") catch config.Config{
        .data_dir = try alloc.dupe(u8, "./data"),
        .http_port = 8080,
        .fsync = .interval,
        .flush_interval_ms = 2000,
        .memtable_max_bytes = 8 * 1024 * 1024,
        .retention_days = 0,
        .auth_token = try alloc.dupe(u8, ""),
        .enable_influx = false,
        .enable_prom = true,
        .mem_limit_bytes = 256 * 1024 * 1024,
        .cas_mode = .off,
        .metadata_read_mode = .legacy,
        .retention_ns = std.StringHashMap(u32).init(alloc),
    };
}

fn cmdPgWire(alloc: std.mem.Allocator, args: [][:0]u8) !void {
    var cfg = try loadConfigOrDefault(alloc);
    defer cfg.deinit(alloc);

    var eng = try engine_mod.Engine.init(alloc, cfg);
    defer eng.deinit();

    try catalog.bootstrap(alloc);

    const default_address = "127.0.0.1";
    const address = if (args.len >= 3)
        std.mem.sliceTo(args[2], 0)
    else
        default_address;

    var port: u16 = 6432;
    if (args.len >= 4) {
        port = std.fmt.parseInt(u16, std.mem.sliceTo(args[3], 0), 10) catch return error.Invalid;
    }

    const session_cfg = compat.wire.session.SessionConfig{};
    const server_cfg = compat.wire.server.ServerConfig{
        .address = address,
        .port = port,
        .session = session_cfg,
        .engine = eng,
    };

    std.debug.print("sydradb pgwire {s}:{d}\n", .{ server_cfg.address, server_cfg.port });
    try compat.wire.server.run(alloc, server_cfg);
}

fn cmdIngest(alloc: std.mem.Allocator, _: [][:0]u8) !void {
    var cfg = try loadConfigOrDefault(alloc);
    defer cfg.deinit(alloc);
    var eng = try engine_mod.Engine.init(alloc, cfg);
    defer eng.deinit();
    // Read NDJSON from stdin
    var stdin_file = std.fs.File.stdin();
    var stdin_buf: [4096]u8 = undefined;
    var reader_state = stdin_file.reader(&stdin_buf);
    const reader = std.Io.Reader.adaptToOldInterface(&reader_state.interface);
    var line_buf: [4096]u8 = undefined;
    var count: usize = 0;
    while (true) {
        const maybe_slice = reader.readUntilDelimiterOrEof(&line_buf, '\n') catch |err| switch (err) {
            error.StreamTooLong => return error.StreamTooLong,
            else => return err,
        };
        const slice = maybe_slice orelse break;
        const trimmed = std.mem.trim(u8, slice, " \t\r\n");
        if (trimmed.len == 0) continue;
        const line = try alloc.dupe(u8, trimmed);
        defer alloc.free(line);
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, line, .{}) catch continue;
        defer parsed.deinit();
        const obj = parsed.value.object;
        const series = obj.get("series").?.string;
        const ts: i64 = @intCast(obj.get("ts").?.integer);
        const value = obj.get("value").?.float;
        const sid = @import("types.zig").hash64(series);
        try eng.registerSeries(series, "{}", sid);
        try eng.ingest(.{ .series_id = sid, .ts = ts, .value = value, .tags_json = "{}" });
        count += 1;
    }
    std.debug.print("ingested {d} points\n", .{count});
}

fn cmdQuery(alloc: std.mem.Allocator, args: [][:0]u8) !void {
    if (args.len < 5) return error.Invalid;
    var cfg = try loadConfigOrDefault(alloc);
    defer cfg.deinit(alloc);
    var eng = try engine_mod.Engine.init(alloc, cfg);
    defer eng.deinit();
    const sid = try std.fmt.parseInt(u64, args[2], 10);
    const start_ts = try std.fmt.parseInt(i64, args[3], 10);
    const end_ts = try std.fmt.parseInt(i64, args[4], 10);
    var out = try std.array_list.Managed(@import("types.zig").Point).initCapacity(alloc, 0);
    defer out.deinit();
    try eng.queryRange(sid, start_ts, end_ts, &out);
    for (out.items) |p| std.debug.print("{d},{d}\n", .{ p.ts, p.value });
}

fn cmdCompact(alloc: std.mem.Allocator, _: [][:0]u8) !void {
    var cfg = try loadConfigOrDefault(alloc);
    defer cfg.deinit(alloc);
    var eng = try engine_mod.Engine.init(alloc, cfg);
    defer eng.deinit();
    _ = try eng.compactNow();
}

fn cmdStats(handle: *alloc_mod.AllocatorHandle, alloc: std.mem.Allocator, _: [][:0]u8) !void {
    var cfg = try loadConfigOrDefault(alloc);
    defer cfg.deinit(alloc);
    var d = try std.fs.cwd().openDir(cfg.data_dir, .{ .iterate = true });
    defer d.close();
    var it = d.iterate();
    var seg_count: usize = 0;
    while (try it.next()) |e| {
        if (e.kind == .directory and std.mem.eql(u8, e.name, "segments")) {
            var seg_dir = try d.openDir(e.name, .{ .iterate = true, .no_follow = true });
            defer seg_dir.close();
            var it2 = seg_dir.iterate();
            while (try it2.next()) |h| {
                if (h.kind == .directory) {
                    var hour_dir = try seg_dir.openDir(h.name, .{ .iterate = true });
                    defer hour_dir.close();
                    var it3 = hour_dir.iterate();
                    while (try it3.next()) |f| {
                        if (f.kind == .file) seg_count += 1;
                    }
                }
            }
        }
    }
    std.debug.print("segments_total {d}\n", .{seg_count});

    if (alloc_mod.is_small_pool) {
        const stats = handle.snapshotSmallPoolStats();
        if (stats.shard_enabled) {
            std.debug.print(
                "small_pool.shards count={d} hits={d} misses={d} deferred={d} epoch_current={d} epoch_min={d}\n",
                .{
                    stats.shard_count,
                    stats.shard_alloc_hits,
                    stats.shard_alloc_misses,
                    stats.shard_deferred_total,
                    stats.shard_current_epoch,
                    stats.shard_min_epoch,
                },
            );
        } else {
            std.debug.print(
                "small_pool.shards disabled hits={d} misses={d}\n",
                .{ stats.shard_alloc_hits, stats.shard_alloc_misses },
            );
        }
        std.debug.print(
            "small_pool.fallback allocs={d} frees={d} resizes={d} remaps={d}\n",
            .{ stats.fallback_allocs, stats.fallback_frees, stats.fallback_resizes, stats.fallback_remaps },
        );
    }
}

fn cmdSnapshot(alloc: std.mem.Allocator, args: [][:0]u8) !void {
    if (args.len < 3) return error.Invalid;
    var cfg = try loadConfigOrDefault(alloc);
    defer cfg.deinit(alloc);
    var eng = try engine_mod.Engine.init(alloc, cfg);
    defer eng.deinit();
    try eng.snapshotTo(args[2]);
}

fn cmdRestore(alloc: std.mem.Allocator, args: [][:0]u8) !void {
    if (args.len < 3) return error.Invalid;
    var cfg = try loadConfigOrDefault(alloc);
    defer cfg.deinit(alloc);
    var data_dir = try std.fs.cwd().openDir(cfg.data_dir, .{ .iterate = true });
    defer data_dir.close();
    try @import("snapshot.zig").restore(alloc, data_dir, args[2]);
}

fn cmdCas(alloc: std.mem.Allocator, args: [][:0]u8) !void {
    if (args.len < 3) return error.Invalid;

    var cfg = try loadConfigOrDefault(alloc);
    defer cfg.deinit(alloc);

    var data_dir = try std.fs.cwd().openDir(cfg.data_dir, .{ .iterate = true });
    defer data_dir.close();

    var cas = try cas_mod.CasManager.init(alloc, cfg.data_dir, cfg.fsync);
    defer cas.deinit();

    const sub = std.mem.sliceTo(args[2], 0);
    if (std.mem.eql(u8, sub, "verify")) {
        var manifest = try @import("storage/manifest.zig").Manifest.loadOrInit(alloc, data_dir);
        defer manifest.deinit();
        var tags = try @import("storage/tags.zig").TagIndex.loadOrInit(alloc, data_dir);
        defer tags.deinit();
        var series_catalog = try @import("storage/series_catalog.zig").SeriesCatalog.loadOrInit(alloc, data_dir, cfg.fsync);
        defer series_catalog.deinit();
        try cas.verifyHead(data_dir, &manifest, &tags, &series_catalog);
        std.debug.print("cas verify ok\n", .{});
        return;
    }
    if (std.mem.eql(u8, sub, "refs")) {
        const refs = try cas.listRefs();
        defer {
            for (refs) |*entry| entry.deinit(alloc);
            alloc.free(refs);
        }
        for (refs) |entry| {
            const hex = entry.id.toHex();
            std.debug.print("{s} {s}\n", .{ entry.name, hex });
        }
        return;
    }
    if (std.mem.eql(u8, sub, "log")) {
        const spec = if (args.len >= 4) std.mem.sliceTo(args[3], 0) else cas_mod.main_ref;
        const entries = try cas.loadLog(spec, 64);
        defer {
            for (entries) |*entry| entry.deinit(alloc);
            alloc.free(entries);
        }
        for (entries) |entry| {
            const hex = entry.commit_id.toHex();
            std.debug.print("{s} parents={d} ts_ms={d} reason={s}\n", .{ hex, entry.parent_count, entry.created_at_ms, entry.reason });
        }
        return;
    }
    if (std.mem.eql(u8, sub, "branch")) {
        if (args.len < 4) return error.Invalid;
        const name = std.mem.sliceTo(args[3], 0);
        const spec = if (args.len >= 5) std.mem.sliceTo(args[4], 0) else cas_mod.main_ref;
        const ref_name = try std.fmt.allocPrint(alloc, "heads/{s}", .{name});
        defer alloc.free(ref_name);
        try cas.createRef(ref_name, spec);
        return;
    }
    if (std.mem.eql(u8, sub, "tag")) {
        if (args.len < 4) return error.Invalid;
        const name = std.mem.sliceTo(args[3], 0);
        const spec = if (args.len >= 5) std.mem.sliceTo(args[4], 0) else cas_mod.main_ref;
        const ref_name = try std.fmt.allocPrint(alloc, "tags/{s}", .{name});
        defer alloc.free(ref_name);
        try cas.createRef(ref_name, spec);
        return;
    }
    if (std.mem.eql(u8, sub, "diff")) {
        if (args.len < 5) return error.Invalid;
        const lhs = std.mem.sliceTo(args[3], 0);
        const rhs = std.mem.sliceTo(args[4], 0);
        const diff = try cas.diffSnapshots(lhs, rhs);
        std.debug.print(
            "cas diff {s}..{s} segments_added={d} segments_removed={d} tags_changed={d} series_entries_changed={d} wal_added={d} wal_removed={d}\n",
            .{
                lhs,
                rhs,
                diff.segments_added,
                diff.segments_removed,
                diff.tags_changed,
                diff.series_entries_changed,
                diff.wal_chunks_added,
                diff.wal_chunks_removed,
            },
        );
        return;
    }
    if (std.mem.eql(u8, sub, "rollback")) {
        if (args.len < 4) return error.Invalid;
        const spec = std.mem.sliceTo(args[3], 0);
        try cas.rollbackMainTo(spec);
        return;
    }
    if (std.mem.eql(u8, sub, "gc")) {
        const dry_run = !(args.len >= 4 and std.mem.eql(u8, std.mem.sliceTo(args[3], 0), "--apply"));
        const result = try cas.gc(dry_run);
        std.debug.print(
            "cas gc dry_run={} reachable={d} unreachable={d} unreachable_bytes={d} deleted={d} stale_segment_files={d} stale_segment_bytes={d} stale_wal_files={d} stale_wal_bytes={d} mirror_deleted={d}\n",
            .{
                dry_run,
                result.reachable,
                result.unreachable_count,
                result.unreachable_bytes,
                result.deleted,
                result.stale_segment_files,
                result.stale_segment_bytes,
                result.stale_wal_files,
                result.stale_wal_bytes,
                result.mirror_deleted,
            },
        );
        return;
    }
    if (std.mem.eql(u8, sub, "fsck")) {
        const report = try cas.fsck(data_dir);
        std.debug.print(
            "cas fsck refs={d} reachable={d} commits={d} trees={d} blobs={d} segment_contents_checked={d} wal_contents_checked={d} missing_segment_mirrors={d} missing_wal_mirrors={d} reflog_files_checked={d} stale_reflog_files={d}\n",
            .{
                report.refs,
                report.reachable_objects,
                report.commit_objects,
                report.tree_objects,
                report.blob_objects,
                report.segment_contents_checked,
                report.wal_contents_checked,
                report.missing_segment_mirrors,
                report.missing_wal_mirrors,
                report.reflog_files_checked,
                report.stale_reflog_files,
            },
        );
        return;
    }
    if (std.mem.eql(u8, sub, "pack")) {
        const result = try cas.pack();
        std.debug.print("cas pack reachable={d} rewritten={d}\n", .{ result.reachable_objects, result.rewritten_objects });
        return;
    }
    if (std.mem.eql(u8, sub, "checkout")) {
        if (args.len < 4) return error.Invalid;
        try cas.exportSpecToLegacy(std.mem.sliceTo(args[3], 0), data_dir);
        return;
    }
    if (std.mem.eql(u8, sub, "export-legacy")) {
        const spec = if (args.len >= 4) std.mem.sliceTo(args[3], 0) else cas_mod.main_ref;
        try cas.exportSpecToLegacy(spec, data_dir);
        return;
    }
    return error.Invalid;
}
