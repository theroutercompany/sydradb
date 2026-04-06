const std = @import("std");
const config = @import("config.zig");
const engine_mod = @import("engine.zig");
const http = @import("http.zig");
const catalog = @import("catalog.zig");
const compat = @import("compat.zig");
const alloc_mod = @import("alloc.zig");
const cas_mod = @import("storage/cas.zig");
const object_store = @import("storage/object_store.zig");

const cas_json_schema_version: u32 = 1;

fn printInteractiveBanner(comptime fmt: []const u8, args: anytype) void {
    if (std.fs.File.stderr().isTty()) {
        std.debug.print(fmt, args);
    }
}

fn printStdout(alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const msg = try std.fmt.allocPrint(alloc, fmt, args);
    defer alloc.free(msg);
    var stdout = std.fs.File.stdout();
    try stdout.writeAll(msg);
}

pub fn run(handle: *alloc_mod.AllocatorHandle) !void {
    const alloc = handle.allocator();
    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);
    if (args.len <= 1 or std.mem.eql(u8, args[1], "serve")) {
        var cfg = try loadConfigOrDefault(alloc);
        var eng = try initOwnedEngine(alloc, &cfg);
        defer eng.deinit();
        try catalog.bootstrap(alloc);
        printInteractiveBanner("sydradb serve :{d}\n", .{eng.config.http_port});
        try http.runHttp(handle, eng, eng.config.http_port);
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
    return loadConfigOrDefaultForPaths(alloc, "sydradb.toml", "./data");
}

fn initOwnedEngine(alloc: std.mem.Allocator, cfg_ptr: *config.Config) !*engine_mod.Engine {
    errdefer cfg_ptr.deinit(alloc);
    const engine = try engine_mod.Engine.init(alloc, cfg_ptr.*);
    cfg_ptr.* = undefined;
    return engine;
}

fn loadConfigOrDefaultForPaths(
    alloc: std.mem.Allocator,
    config_path: []const u8,
    default_data_dir: []const u8,
) !config.Config {
    return config.load(alloc, config_path) catch {
        const defaults = try cas_mod.recommendedStartupDefaults(std.fs.cwd(), default_data_dir);
        return config.Config{
            .data_dir = try alloc.dupe(u8, default_data_dir),
            .http_port = 8080,
            .fsync = .interval,
            .flush_interval_ms = 2000,
            .memtable_max_bytes = 8 * 1024 * 1024,
            .retention_days = 0,
            .auth_token = try alloc.dupe(u8, ""),
            .enable_influx = false,
            .enable_prom = true,
            .mem_limit_bytes = 256 * 1024 * 1024,
            .cas_mode = defaults.cas_mode,
            .metadata_read_mode = defaults.metadata_read_mode,
            .query_compiler_mode = .compiled,
            .retention_ns = std.StringHashMap(u32).init(alloc),
        };
    };
}

fn cmdPgWire(alloc: std.mem.Allocator, args: [][:0]u8) !void {
    var cfg = try loadConfigOrDefault(alloc);
    var eng = try initOwnedEngine(alloc, &cfg);
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

    printInteractiveBanner("sydradb pgwire {s}:{d}\n", .{ server_cfg.address, server_cfg.port });
    try compat.wire.server.run(alloc, server_cfg);
}

fn cmdIngest(alloc: std.mem.Allocator, _: [][:0]u8) !void {
    var cfg = try loadConfigOrDefault(alloc);
    var eng = try initOwnedEngine(alloc, &cfg);
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
        const parsed = http.parseIngestLine(alloc, slice) catch |err| switch (err) {
            error.EmptyLine,
            error.InvalidRecord,
            error.MissingSeries,
            error.MissingTimestamp,
            error.InvalidSeries,
            error.InvalidTimestamp,
            => continue,
            else => return err,
        };
        defer parsed.deinit(alloc);
        _ = try http.applyIngestLine(eng, parsed);
        count += 1;
    }
    _ = try eng.flushNow();
    try eng.waitForDrained(1_000);
    printInteractiveBanner("ingested {d} points\n", .{count});
}

fn cmdQuery(alloc: std.mem.Allocator, args: [][:0]u8) !void {
    if (args.len < 5) return error.Invalid;
    var cfg = try loadConfigOrDefault(alloc);
    var eng = try initOwnedEngine(alloc, &cfg);
    defer eng.deinit();
    const sid = try std.fmt.parseInt(u64, args[2], 10);
    const start_ts = try std.fmt.parseInt(i64, args[3], 10);
    const end_ts = try std.fmt.parseInt(i64, args[4], 10);
    var out = try std.array_list.Managed(@import("types.zig").Point).initCapacity(alloc, 0);
    defer out.deinit();
    try eng.queryRange(sid, start_ts, end_ts, &out);
    for (out.items) |p| try printStdout(alloc, "{d},{d}\n", .{ p.ts, p.value });
}

fn cmdCompact(alloc: std.mem.Allocator, _: [][:0]u8) !void {
    var cfg = try loadConfigOrDefault(alloc);
    var eng = try initOwnedEngine(alloc, &cfg);
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
    try printStdout(alloc, "segments_total {d}\n", .{seg_count});

    if (alloc_mod.is_small_pool) {
        const stats = handle.snapshotSmallPoolStats();
        if (stats.shard_enabled) {
            try printStdout(
                alloc,
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
            try printStdout(
                alloc,
                "small_pool.shards disabled hits={d} misses={d}\n",
                .{ stats.shard_alloc_hits, stats.shard_alloc_misses },
            );
        }
        try printStdout(
            alloc,
            "small_pool.fallback allocs={d} frees={d} resizes={d} remaps={d}\n",
            .{ stats.fallback_allocs, stats.fallback_frees, stats.fallback_resizes, stats.fallback_remaps },
        );
    }
}

fn cmdSnapshot(alloc: std.mem.Allocator, args: [][:0]u8) !void {
    if (args.len < 3) return error.Invalid;
    var cfg = try loadConfigOrDefault(alloc);
    var eng = try initOwnedEngine(alloc, &cfg);
    defer eng.deinit();
    try eng.snapshotTo(args[2]);
}

fn cmdRestore(alloc: std.mem.Allocator, args: [][:0]u8) !void {
    if (args.len < 3) return error.Invalid;
    var cfg = try loadConfigOrDefault(alloc);
    defer cfg.deinit(alloc);
    try @import("snapshot.zig").restore(alloc, cfg.data_dir, args[2], cfg.fsync);
}

fn writeJsonBufferToStdout(bytes: []const u8) !void {
    var stdout = std.fs.File.stdout();
    try stdout.writeAll(bytes);
    try stdout.writeAll("\n");
}

fn beginCasJsonEnvelope(jw: *std.json.Stringify, command: []const u8, action: ?[]const u8) !void {
    try jw.beginObject();
    try jw.objectField("schema_version");
    try jw.write(cas_json_schema_version);
    try jw.objectField("command");
    try jw.write(command);
    if (action) |value| {
        try jw.objectField("action");
        try jw.write(value);
    }
}

fn writeObjectIdHex(jw: *std.json.Stringify, id: object_store.ObjectId) !void {
    const hex = id.toHex();
    try jw.write(hex[0..]);
}

fn writeOptionalObjectIdHex(jw: *std.json.Stringify, id: ?object_store.ObjectId) !void {
    if (id) |value| {
        try writeObjectIdHex(jw, value);
    } else {
        try jw.write(null);
    }
}

fn writeCompatibilityDebtJson(jw: *std.json.Stringify, report: cas_mod.CompatibilityDebtReport) !void {
    try jw.objectField("compatibility_debt");
    try jw.beginObject();
    try jw.objectField("legacy_segment_descriptors");
    try jw.write(report.legacy_segment_descriptors);
    try jw.objectField("legacy_wal_descriptors");
    try jw.write(report.legacy_wal_descriptors);
    try jw.objectField("loose_refs_present");
    try jw.write(report.loose_refs_present);
    try jw.endObject();
}

fn writeRepairReportJson(jw: *std.json.Stringify, report: cas_mod.RepairReport) !void {
    try jw.objectField("repair");
    try jw.beginObject();
    try jw.objectField("pack_sidecars_rebuilt");
    try jw.write(report.pack_sidecars_rebuilt);
    try jw.objectField("side_indexes_rebuilt");
    try jw.write(report.side_indexes_rebuilt);
    try jw.objectField("reftable_state_rebuilt");
    try jw.write(report.reftable_state_rebuilt);
    try jw.objectField("reftable_tables_list_rebuilt");
    try jw.write(report.reftable_tables_list_rebuilt);
    try jw.endObject();
}

fn writeExpiryReportJson(jw: *std.json.Stringify, report: cas_mod.ExpiryReport) !void {
    try jw.objectField("expiry");
    try jw.beginObject();
    try jw.objectField("reflog_entries_expired");
    try jw.write(report.reflog_entries_expired);
    try jw.objectField("checkpoint_refs_expired");
    try jw.write(report.checkpoint_refs_expired);
    try jw.objectField("borrowed_packs_materialized");
    try jw.write(report.borrowed_packs_materialized);
    try jw.endObject();
}

fn writeCasRefsJson(alloc: std.mem.Allocator, refs: []const cas_mod.RefEntry) !void {
    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();
    var writer = buf.writer();
    var tmp: [512]u8 = undefined;
    var adapter = writer.adaptToNewApi(&tmp);
    var iface = &adapter.new_interface;
    var jw = std.json.Stringify{ .writer = iface };
    try beginCasJsonEnvelope(&jw, "refs", null);
    try jw.objectField("entries");
    try jw.beginArray();
    for (refs) |entry| {
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(entry.name);
        try jw.objectField("id");
        try writeObjectIdHex(&jw, entry.id);
        try jw.endObject();
    }
    try jw.endArray();
    try jw.endObject();
    try iface.flush();
    if (adapter.err) |err| return err;
    try writeJsonBufferToStdout(buf.items);
}

fn writeCasLogJson(alloc: std.mem.Allocator, spec: []const u8, entries: []const cas_mod.LogEntry) !void {
    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();
    var writer = buf.writer();
    var tmp: [512]u8 = undefined;
    var adapter = writer.adaptToNewApi(&tmp);
    var iface = &adapter.new_interface;
    var jw = std.json.Stringify{ .writer = iface };
    try beginCasJsonEnvelope(&jw, "log", null);
    try jw.objectField("spec");
    try jw.write(spec);
    try jw.objectField("entries");
    try jw.beginArray();
    for (entries) |entry| {
        try jw.beginObject();
        try jw.objectField("commit_id");
        try writeObjectIdHex(&jw, entry.commit_id);
        try jw.objectField("created_at_ms");
        try jw.write(entry.created_at_ms);
        try jw.objectField("reason");
        try jw.write(entry.reason);
        try jw.objectField("parent_count");
        try jw.write(entry.parent_count);
        try jw.endObject();
    }
    try jw.endArray();
    try jw.endObject();
    try iface.flush();
    if (adapter.err) |err| return err;
    try writeJsonBufferToStdout(buf.items);
}

fn writeCasReflogJson(alloc: std.mem.Allocator, ref_name: []const u8, limit: usize, entries: []const cas_mod.ReflogEntry) !void {
    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();
    var writer = buf.writer();
    var tmp: [512]u8 = undefined;
    var adapter = writer.adaptToNewApi(&tmp);
    var iface = &adapter.new_interface;
    var jw = std.json.Stringify{ .writer = iface };
    try beginCasJsonEnvelope(&jw, "reflog", null);
    try jw.objectField("ref");
    try jw.write(ref_name);
    try jw.objectField("limit");
    try jw.write(limit);
    try jw.objectField("entries");
    try jw.beginArray();
    for (entries) |entry| {
        try jw.beginObject();
        try jw.objectField("ref_name");
        try jw.write(entry.ref_name);
        try jw.objectField("old_id");
        try writeOptionalObjectIdHex(&jw, entry.old_id);
        try jw.objectField("new_id");
        try writeObjectIdHex(&jw, entry.new_id);
        try jw.objectField("timestamp_ms");
        try jw.write(entry.timestamp_ms);
        try jw.objectField("reason");
        try jw.write(entry.reason);
        try jw.endObject();
    }
    try jw.endArray();
    try jw.endObject();
    try iface.flush();
    if (adapter.err) |err| return err;
    try writeJsonBufferToStdout(buf.items);
}

fn writeCasDiffJson(alloc: std.mem.Allocator, lhs: []const u8, rhs: []const u8, diff: cas_mod.SnapshotDiff) !void {
    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();
    var writer = buf.writer();
    var tmp: [512]u8 = undefined;
    var adapter = writer.adaptToNewApi(&tmp);
    var iface = &adapter.new_interface;
    var jw = std.json.Stringify{ .writer = iface };
    try beginCasJsonEnvelope(&jw, "diff", null);
    try jw.objectField("lhs");
    try jw.write(lhs);
    try jw.objectField("rhs");
    try jw.write(rhs);
    try jw.objectField("segments_added");
    try jw.write(diff.segments_added);
    try jw.objectField("segments_removed");
    try jw.write(diff.segments_removed);
    try jw.objectField("tags_changed");
    try jw.write(diff.tags_changed);
    try jw.objectField("series_entries_changed");
    try jw.write(diff.series_entries_changed);
    try jw.objectField("wal_chunks_added");
    try jw.write(diff.wal_chunks_added);
    try jw.objectField("wal_chunks_removed");
    try jw.write(diff.wal_chunks_removed);
    try jw.endObject();
    try iface.flush();
    if (adapter.err) |err| return err;
    try writeJsonBufferToStdout(buf.items);
}

fn writeCasBundleJson(alloc: std.mem.Allocator, command: []const u8, action: ?[]const u8, result: cas_mod.BundleResult) !void {
    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();
    var writer = buf.writer();
    var tmp: [512]u8 = undefined;
    var adapter = writer.adaptToNewApi(&tmp);
    var iface = &adapter.new_interface;
    var jw = std.json.Stringify{ .writer = iface };
    try beginCasJsonEnvelope(&jw, command, action);
    try jw.objectField("ref_count");
    try jw.write(result.ref_count);
    try jw.objectField("prerequisite_count");
    try jw.write(result.prerequisite_count);
    try jw.objectField("object_count");
    try jw.write(result.object_count);
    try jw.objectField("pack_count");
    try jw.write(result.pack_count);
    try jw.objectField("reftable_file_count");
    try jw.write(result.reftable_file_count);
    try jw.endObject();
    try iface.flush();
    if (adapter.err) |err| return err;
    try writeJsonBufferToStdout(buf.items);
}

fn writeCasLocalExchangeJson(alloc: std.mem.Allocator, command: []const u8, result: cas_mod.LocalExchangeResult) !void {
    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();
    var writer = buf.writer();
    var tmp: [512]u8 = undefined;
    var adapter = writer.adaptToNewApi(&tmp);
    var iface = &adapter.new_interface;
    var jw = std.json.Stringify{ .writer = iface };
    try beginCasJsonEnvelope(&jw, command, null);
    try jw.objectField("repository_id");
    const repo_hex = result.repository_id.toHex();
    try jw.write(repo_hex[0..]);
    try jw.objectField("ref_count");
    try jw.write(result.ref_count);
    try jw.objectField("borrowed_repositories");
    try jw.write(result.borrowed_repositories);
    try jw.endObject();
    try iface.flush();
    if (adapter.err) |err| return err;
    try writeJsonBufferToStdout(buf.items);
}

fn writeCasPackJson(alloc: std.mem.Allocator, result: cas_mod.PackResult) !void {
    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();
    var writer = buf.writer();
    var tmp: [512]u8 = undefined;
    var adapter = writer.adaptToNewApi(&tmp);
    var iface = &adapter.new_interface;
    var jw = std.json.Stringify{ .writer = iface };
    try beginCasJsonEnvelope(&jw, "pack", null);
    try jw.objectField("reachable_objects");
    try jw.write(result.reachable_objects);
    try jw.objectField("rewritten_objects");
    try jw.write(result.rewritten_objects);
    try jw.endObject();
    try iface.flush();
    if (adapter.err) |err| return err;
    try writeJsonBufferToStdout(buf.items);
}

fn writeCasGcJson(alloc: std.mem.Allocator, options: cas_mod.GcOptions, result: cas_mod.GcResult) !void {
    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();
    var writer = buf.writer();
    var tmp: [512]u8 = undefined;
    var adapter = writer.adaptToNewApi(&tmp);
    var iface = &adapter.new_interface;
    var jw = std.json.Stringify{ .writer = iface };
    try beginCasJsonEnvelope(&jw, "gc", null);
    try jw.objectField("dry_run");
    try jw.write(options.dry_run);
    try jw.objectField("include_reflogs");
    try jw.write(options.include_reflogs);
    try jw.objectField("grace_period_ms");
    try jw.write(options.grace_period_ms);
    try jw.objectField("reachable");
    try jw.write(result.reachable);
    try jw.objectField("unreachable_count");
    try jw.write(result.unreachable_count);
    try jw.objectField("unreachable_bytes");
    try jw.write(result.unreachable_bytes);
    try jw.objectField("reflog_protected");
    try jw.write(result.reflog_protected);
    try jw.objectField("quarantined_count");
    try jw.write(result.quarantined_count);
    try jw.objectField("quarantined_bytes");
    try jw.write(result.quarantined_bytes);
    try jw.objectField("pruned_count");
    try jw.write(result.pruned_count);
    try jw.objectField("pruned_bytes");
    try jw.write(result.pruned_bytes);
    try jw.objectField("deleted");
    try jw.write(result.deleted);
    try jw.objectField("stale_segment_files");
    try jw.write(result.stale_segment_files);
    try jw.objectField("stale_segment_bytes");
    try jw.write(result.stale_segment_bytes);
    try jw.objectField("stale_wal_files");
    try jw.write(result.stale_wal_files);
    try jw.objectField("stale_wal_bytes");
    try jw.write(result.stale_wal_bytes);
    try jw.objectField("mirror_deleted");
    try jw.write(result.mirror_deleted);
    try jw.endObject();
    try iface.flush();
    if (adapter.err) |err| return err;
    try writeJsonBufferToStdout(buf.items);
}

fn writeCasFsckJson(
    alloc: std.mem.Allocator,
    options: cas_mod.FsckOptions,
    repair_enabled: bool,
    repair_report: cas_mod.RepairReport,
    report: cas_mod.FsckReport,
) !void {
    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();
    var writer = buf.writer();
    var tmp: [512]u8 = undefined;
    var adapter = writer.adaptToNewApi(&tmp);
    var iface = &adapter.new_interface;
    var jw = std.json.Stringify{ .writer = iface };
    try beginCasJsonEnvelope(&jw, "fsck", null);
    try jw.objectField("mode");
    try jw.write(if (options.mode == .connectivity_only) "connectivity-only" else "full");
    try jw.objectField("include_reflogs");
    try jw.write(options.include_reflogs);
    try jw.objectField("write_lost_found");
    try jw.write(options.write_lost_found);
    try jw.objectField("repair_enabled");
    try jw.write(repair_enabled);
    try jw.objectField("refs");
    try jw.write(report.refs);
    try jw.objectField("reachable_objects");
    try jw.write(report.reachable_objects);
    try jw.objectField("reflog_heads");
    try jw.write(report.reflog_heads);
    try jw.objectField("reflog_protected_objects");
    try jw.write(report.reflog_protected_objects);
    try jw.objectField("commit_objects");
    try jw.write(report.commit_objects);
    try jw.objectField("tree_objects");
    try jw.write(report.tree_objects);
    try jw.objectField("blob_objects");
    try jw.write(report.blob_objects);
    try jw.objectField("commit_graph_entries_checked");
    try jw.write(report.commit_graph_entries_checked);
    try jw.objectField("segment_contents_checked");
    try jw.write(report.segment_contents_checked);
    try jw.objectField("wal_contents_checked");
    try jw.write(report.wal_contents_checked);
    try jw.objectField("missing_segment_mirrors");
    try jw.write(report.missing_segment_mirrors);
    try jw.objectField("missing_wal_mirrors");
    try jw.write(report.missing_wal_mirrors);
    try jw.objectField("reflog_files_checked");
    try jw.write(report.reflog_files_checked);
    try jw.objectField("stale_reflog_files");
    try jw.write(report.stale_reflog_files);
    try jw.objectField("dangling_objects");
    try jw.write(report.dangling_objects);
    try jw.objectField("lost_found_objects");
    try jw.write(report.lost_found_objects);
    try writeCompatibilityDebtJson(&jw, report.compatibility_debt);
    try writeRepairReportJson(&jw, repair_report);
    try jw.endObject();
    try iface.flush();
    if (adapter.err) |err| return err;
    try writeJsonBufferToStdout(buf.items);
}

fn writeCasUpgradeJson(alloc: std.mem.Allocator, result: cas_mod.UpgradeResult) !void {
    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();
    var writer = buf.writer();
    var tmp: [512]u8 = undefined;
    var adapter = writer.adaptToNewApi(&tmp);
    var iface = &adapter.new_interface;
    var jw = std.json.Stringify{ .writer = iface };
    try beginCasJsonEnvelope(&jw, "upgrade", null);
    try jw.objectField("migrated_reftable");
    try jw.write(result.migrated_reftable);
    try jw.objectField("format_version");
    try jw.write(result.format_version);
    try jw.objectField("ref_backend");
    try jw.write(if (result.ref_backend == .reftable) "reftable" else "loose");
    try jw.objectField("reachable_objects");
    try jw.write(result.reachable_objects);
    try jw.objectField("rewritten_objects");
    try jw.write(result.rewritten_objects);
    try jw.objectField("normalized_commits");
    try jw.write(result.normalized_commits);
    try writeCompatibilityDebtJson(&jw, result.compatibility_debt);
    try jw.endObject();
    try iface.flush();
    if (adapter.err) |err| return err;
    try writeJsonBufferToStdout(buf.items);
}

fn writeCasVacuumJson(alloc: std.mem.Allocator, result: cas_mod.VacuumResult) !void {
    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();
    var writer = buf.writer();
    var tmp: [512]u8 = undefined;
    var adapter = writer.adaptToNewApi(&tmp);
    var iface = &adapter.new_interface;
    var jw = std.json.Stringify{ .writer = iface };
    try beginCasJsonEnvelope(&jw, "vacuum", null);
    try jw.objectField("fsck");
    try jw.beginObject();
    try jw.objectField("refs");
    try jw.write(result.fsck.refs);
    try jw.objectField("reachable_objects");
    try jw.write(result.fsck.reachable_objects);
    try jw.objectField("dangling_objects");
    try jw.write(result.fsck.dangling_objects);
    try writeCompatibilityDebtJson(&jw, result.fsck.compatibility_debt);
    try jw.endObject();
    try writeRepairReportJson(&jw, result.repair);
    try writeExpiryReportJson(&jw, result.expiry);
    try jw.objectField("pack");
    try jw.beginObject();
    try jw.objectField("reachable_objects");
    try jw.write(result.pack.reachable_objects);
    try jw.objectField("rewritten_objects");
    try jw.write(result.pack.rewritten_objects);
    try jw.endObject();
    try jw.objectField("gc");
    try jw.beginObject();
    try jw.objectField("reachable");
    try jw.write(result.gc.reachable);
    try jw.objectField("unreachable_count");
    try jw.write(result.gc.unreachable_count);
    try jw.objectField("pruned_count");
    try jw.write(result.gc.pruned_count);
    try jw.objectField("deleted");
    try jw.write(result.gc.deleted);
    try jw.endObject();
    try jw.endObject();
    try iface.flush();
    if (adapter.err) |err| return err;
    try writeJsonBufferToStdout(buf.items);
}

fn cmdCas(alloc: std.mem.Allocator, args: [][:0]u8) !void {
    if (args.len < 3) return error.Invalid;

    var cfg = try loadConfigOrDefault(alloc);
    defer cfg.deinit(alloc);

    var json_output = false;
    var arg_start: usize = 2;
    if (args.len >= 4 and std.mem.eql(u8, std.mem.sliceTo(args[2], 0), "--json")) {
        json_output = true;
        arg_start = 3;
    }
    if (args.len <= arg_start) return error.Invalid;

    const rest = args[arg_start..];
    const sub = std.mem.sliceTo(rest[0], 0);
    if (std.mem.eql(u8, sub, "clone")) {
        if (rest.len < 3) return error.Invalid;
        var options = cas_mod.LocalCloneOptions{};
        if (rest.len >= 4) {
            if (!std.mem.eql(u8, std.mem.sliceTo(rest[3], 0), "--borrow")) return error.Invalid;
            options.borrow = true;
        }
        const result = try cas_mod.cloneLocalRepositoryWithOptions(
            alloc,
            std.mem.sliceTo(rest[1], 0),
            std.mem.sliceTo(rest[2], 0),
            cfg.fsync,
            options,
        );
        if (json_output) {
            const bundle_result = cas_mod.BundleResult{
                .ref_count = result.ref_count,
                .prerequisite_count = result.prerequisite_count,
                .object_count = result.object_count,
                .pack_count = result.pack_count,
                .reftable_file_count = result.reftable_file_count,
            };
            try writeCasBundleJson(alloc, "clone", null, bundle_result);
        } else {
            try printStdout(
                alloc,
                "cas clone refs={d} prerequisites={d} objects={d} packs={d} reftable_files={d}\n",
                .{ result.ref_count, result.prerequisite_count, result.object_count, result.pack_count, result.reftable_file_count },
            );
        }
        return;
    }
    if (std.mem.eql(u8, sub, "fetch-local")) {
        if (rest.len < 2) return error.Invalid;
        var options = cas_mod.LocalFetchOptions{};
        if (rest.len >= 3) {
            if (!std.mem.eql(u8, std.mem.sliceTo(rest[2], 0), "--materialize")) return error.Invalid;
            options.materialize = true;
        }
        const result = try cas_mod.fetchLocalRepositoryWithOptions(alloc, std.mem.sliceTo(rest[1], 0), cfg.data_dir, cfg.fsync, options);
        if (json_output) {
            try writeCasLocalExchangeJson(alloc, "fetch-local", result);
        } else {
            const repo_hex = result.repository_id.toHex();
            try printStdout(
                alloc,
                "cas fetch-local repository={s} refs={d} borrowed_repositories={d}\n",
                .{ repo_hex, result.ref_count, result.borrowed_repositories },
            );
        }
        return;
    }
    if (std.mem.eql(u8, sub, "push-local")) {
        if (rest.len < 2) return error.Invalid;
        var options = cas_mod.LocalPushOptions{};
        if (rest.len >= 3) {
            if (!std.mem.eql(u8, std.mem.sliceTo(rest[2], 0), "--borrow")) return error.Invalid;
            options.borrow = true;
        }
        const result = try cas_mod.pushLocalRepositoryWithOptions(alloc, cfg.data_dir, std.mem.sliceTo(rest[1], 0), cfg.fsync, options);
        if (json_output) {
            try writeCasLocalExchangeJson(alloc, "push-local", result);
        } else {
            const repo_hex = result.repository_id.toHex();
            try printStdout(
                alloc,
                "cas push-local repository={s} refs={d} borrowed_repositories={d}\n",
                .{ repo_hex, result.ref_count, result.borrowed_repositories },
            );
        }
        return;
    }
    if (std.mem.eql(u8, sub, "verify-bundle")) {
        if (rest.len < 2) return error.Invalid;
        const result = try cas_mod.verifyBundle(alloc, std.mem.sliceTo(rest[1], 0));
        if (json_output) {
            try writeCasBundleJson(alloc, "verify-bundle", null, result);
        } else {
            try printStdout(
                alloc,
                "cas verify-bundle refs={d} prerequisites={d} objects={d} packs={d} reftable_files={d}\n",
                .{ result.ref_count, result.prerequisite_count, result.object_count, result.pack_count, result.reftable_file_count },
            );
        }
        return;
    }
    if (std.mem.eql(u8, sub, "bundle")) {
        if (rest.len < 3) return error.Invalid;
        const action = std.mem.sliceTo(rest[1], 0);
        if (std.mem.eql(u8, action, "create")) {
            const dst = std.mem.sliceTo(rest[2], 0);
            var since_spec: ?[]const u8 = null;
            if (rest.len >= 5) {
                if (!std.mem.eql(u8, std.mem.sliceTo(rest[3], 0), "--since")) return error.Invalid;
                since_spec = std.mem.sliceTo(rest[4], 0);
            } else if (rest.len == 4) {
                return error.Invalid;
            }
            const result = try cas_mod.createBundle(alloc, cfg.data_dir, dst, cfg.fsync, since_spec);
            if (json_output) {
                try writeCasBundleJson(alloc, "bundle", "create", result);
            } else {
                try printStdout(
                    alloc,
                    "cas bundle create refs={d} prerequisites={d} objects={d} packs={d} reftable_files={d}\n",
                    .{ result.ref_count, result.prerequisite_count, result.object_count, result.pack_count, result.reftable_file_count },
                );
            }
            return;
        }
        if (std.mem.eql(u8, action, "verify")) {
            const result = try cas_mod.verifyBundle(alloc, std.mem.sliceTo(rest[2], 0));
            if (json_output) {
                try writeCasBundleJson(alloc, "bundle", "verify", result);
            } else {
                try printStdout(
                    alloc,
                    "cas bundle verify refs={d} prerequisites={d} objects={d} packs={d} reftable_files={d}\n",
                    .{ result.ref_count, result.prerequisite_count, result.object_count, result.pack_count, result.reftable_file_count },
                );
            }
            return;
        }
        if (std.mem.eql(u8, action, "apply")) {
            const result = try cas_mod.applyBundle(alloc, std.mem.sliceTo(rest[2], 0), cfg.data_dir, cfg.fsync);
            if (json_output) {
                try writeCasBundleJson(alloc, "bundle", "apply", result);
            } else {
                try printStdout(
                    alloc,
                    "cas bundle apply refs={d} prerequisites={d} objects={d} packs={d} reftable_files={d}\n",
                    .{ result.ref_count, result.prerequisite_count, result.object_count, result.pack_count, result.reftable_file_count },
                );
            }
            return;
        }
        return error.Invalid;
    }

    var data_dir = try std.fs.cwd().openDir(cfg.data_dir, .{ .iterate = true });
    defer data_dir.close();

    var cas = try cas_mod.CasManager.init(alloc, cfg.data_dir, cfg.fsync);
    defer cas.deinit();

    if (std.mem.eql(u8, sub, "verify")) {
        var manifest = try @import("storage/manifest.zig").Manifest.loadOrInit(alloc, data_dir);
        defer manifest.deinit();
        var tags = try @import("storage/tags.zig").TagIndex.loadOrInit(alloc, data_dir);
        defer tags.deinit();
        var series_catalog = try @import("storage/series_catalog.zig").SeriesCatalog.loadOrInit(alloc, data_dir, cfg.fsync);
        defer series_catalog.deinit();
        var metric_catalog = try @import("storage/metric_catalog.zig").MetricCatalog.loadOrInit(alloc, data_dir, cfg.fsync);
        defer metric_catalog.deinit();
        try cas.verifyHead(data_dir, &manifest, &tags, &series_catalog, &metric_catalog);
        if (json_output) {
            try writeJsonBufferToStdout("{\"schema_version\":1,\"command\":\"verify\",\"ok\":true}");
        } else {
            try printStdout(alloc, "cas verify ok\n", .{});
        }
        return;
    }
    if (std.mem.eql(u8, sub, "refs")) {
        const refs = try cas.listRefs();
        defer {
            for (refs) |*entry| entry.deinit(alloc);
            alloc.free(refs);
        }
        if (json_output) {
            try writeCasRefsJson(alloc, refs);
        } else {
            for (refs) |entry| {
                const hex = entry.id.toHex();
                try printStdout(alloc, "{s} {s}\n", .{ entry.name, hex });
            }
        }
        return;
    }
    if (std.mem.eql(u8, sub, "head")) {
        if (rest.len >= 2) {
            const target = std.mem.sliceTo(rest[1], 0);
            if (try cas.refs.readHead(target) == null) return error.RefNotFound;
            try cas.writeHeadSymRef(target);
        }
        const head = try cas.readHeadSymRef() orelse try alloc.dupe(u8, cas_mod.main_ref);
        defer alloc.free(head);
        if (json_output) {
            var json_buf = std.array_list.Managed(u8).init(alloc);
            defer json_buf.deinit();
            var writer = json_buf.writer();
            var tmp: [256]u8 = undefined;
            var adapter = writer.adaptToNewApi(&tmp);
            var iface = &adapter.new_interface;
            var jw = std.json.Stringify{ .writer = iface };
            try beginCasJsonEnvelope(&jw, "head", null);
            try jw.objectField("target");
            try jw.write(head);
            try jw.endObject();
            try iface.flush();
            if (adapter.err) |err| return err;
            try writeJsonBufferToStdout(json_buf.items);
        } else {
            try printStdout(alloc, "cas head {s}\n", .{head});
        }
        return;
    }
    if (std.mem.eql(u8, sub, "log")) {
        const spec = if (rest.len >= 2) std.mem.sliceTo(rest[1], 0) else cas_mod.main_ref;
        const entries = try cas.loadLog(spec, 64);
        defer {
            for (entries) |*entry| entry.deinit(alloc);
            alloc.free(entries);
        }
        if (json_output) {
            try writeCasLogJson(alloc, spec, entries);
        } else {
            for (entries) |entry| {
                const hex = entry.commit_id.toHex();
                try printStdout(alloc, "{s} parents={d} ts_ms={d} reason={s}\n", .{ hex, entry.parent_count, entry.created_at_ms, entry.reason });
            }
        }
        return;
    }
    if (std.mem.eql(u8, sub, "branch")) {
        if (rest.len < 2) return error.Invalid;
        const name = std.mem.sliceTo(rest[1], 0);
        const spec = if (rest.len >= 3) std.mem.sliceTo(rest[2], 0) else cas_mod.main_ref;
        const ref_name = try std.fmt.allocPrint(alloc, "heads/{s}", .{name});
        defer alloc.free(ref_name);
        try cas.createRef(ref_name, spec);
        return;
    }
    if (std.mem.eql(u8, sub, "tag")) {
        if (rest.len < 2) return error.Invalid;
        const name = std.mem.sliceTo(rest[1], 0);
        const spec = if (rest.len >= 3) std.mem.sliceTo(rest[2], 0) else cas_mod.main_ref;
        const ref_name = try std.fmt.allocPrint(alloc, "tags/{s}", .{name});
        defer alloc.free(ref_name);
        try cas.createRef(ref_name, spec);
        return;
    }
    if (std.mem.eql(u8, sub, "delete-ref")) {
        if (rest.len < 2) return error.Invalid;
        try cas.deleteRef(std.mem.sliceTo(rest[1], 0));
        return;
    }
    if (std.mem.eql(u8, sub, "rename-ref")) {
        if (rest.len < 3) return error.Invalid;
        try cas.renameRef(std.mem.sliceTo(rest[1], 0), std.mem.sliceTo(rest[2], 0));
        return;
    }
    if (std.mem.eql(u8, sub, "reflog")) {
        if (rest.len < 2) return error.Invalid;
        const limit = if (rest.len >= 3) try std.fmt.parseInt(usize, std.mem.sliceTo(rest[2], 0), 10) else 32;
        const ref_name = std.mem.sliceTo(rest[1], 0);
        const entries = try cas.loadReflog(ref_name, limit);
        defer {
            for (entries) |*entry| entry.deinit(alloc);
            alloc.free(entries);
        }
        if (json_output) {
            try writeCasReflogJson(alloc, ref_name, limit, entries);
        } else {
            for (entries) |entry| {
                const old_hex = if (entry.old_id) |id| id.toHex() else [_]u8{'0'} ** 64;
                const new_hex = entry.new_id.toHex();
                try printStdout(alloc, "{d} {s} {s} {s}\n", .{ entry.timestamp_ms, old_hex, new_hex, entry.reason });
            }
        }
        return;
    }
    if (std.mem.eql(u8, sub, "diff")) {
        if (rest.len < 3) return error.Invalid;
        const lhs = std.mem.sliceTo(rest[1], 0);
        const rhs = std.mem.sliceTo(rest[2], 0);
        const diff = try cas.diffSnapshots(lhs, rhs);
        if (json_output) {
            try writeCasDiffJson(alloc, lhs, rhs, diff);
        } else {
            try printStdout(
                alloc,
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
        }
        return;
    }
    if (std.mem.eql(u8, sub, "rollback")) {
        if (rest.len < 2) return error.Invalid;
        const spec = std.mem.sliceTo(rest[1], 0);
        try cas.rollbackMainTo(spec);
        return;
    }
    if (std.mem.eql(u8, sub, "migrate-reftable")) {
        try cas.migrateToReftable(data_dir);
        if (json_output) {
            try writeJsonBufferToStdout("{\"schema_version\":1,\"command\":\"migrate-reftable\",\"backend\":\"reftable\"}");
        } else {
            try printStdout(alloc, "cas migrate-reftable backend=reftable\n", .{});
        }
        return;
    }
    if (std.mem.eql(u8, sub, "upgrade")) {
        const result = try cas.upgradeRepository(data_dir);
        if (json_output) {
            try writeCasUpgradeJson(alloc, result);
        } else {
            try printStdout(
                alloc,
                "cas upgrade migrated_reftable={} format_version={d} ref_backend={s} reachable={d} rewritten={d} normalized_commits={d} compatibility_legacy_segments={d} compatibility_legacy_wal={d} compatibility_loose_refs={d}\n",
                .{
                    result.migrated_reftable,
                    result.format_version,
                    if (result.ref_backend == .reftable) "reftable" else "loose",
                    result.reachable_objects,
                    result.rewritten_objects,
                    result.normalized_commits,
                    result.compatibility_debt.legacy_segment_descriptors,
                    result.compatibility_debt.legacy_wal_descriptors,
                    result.compatibility_debt.loose_refs_present,
                },
            );
        }
        return;
    }
    if (std.mem.eql(u8, sub, "expire")) {
        var policy = cas_mod.MaintenancePolicy{};
        var idx: usize = 1;
        while (idx < rest.len) : (idx += 1) {
            const arg = std.mem.sliceTo(rest[idx], 0);
            if (std.mem.eql(u8, arg, "--materialize-borrowed")) {
                policy.materialize_borrowed_packs = true;
            } else if (std.mem.eql(u8, arg, "--reflog-expiry-ms")) {
                idx += 1;
                if (idx >= rest.len) return error.Invalid;
                policy.reflog_expiry_ms = try std.fmt.parseInt(i64, std.mem.sliceTo(rest[idx], 0), 10);
            } else if (std.mem.eql(u8, arg, "--checkpoint-expiry-ms")) {
                idx += 1;
                if (idx >= rest.len) return error.Invalid;
                policy.checkpoint_expiry_ms = try std.fmt.parseInt(i64, std.mem.sliceTo(rest[idx], 0), 10);
            } else {
                return error.Invalid;
            }
        }
        const result = try cas.expire(data_dir, policy);
        if (json_output) {
            var json_buf = std.array_list.Managed(u8).init(alloc);
            defer json_buf.deinit();
            var writer = json_buf.writer();
            var tmp: [256]u8 = undefined;
            var adapter = writer.adaptToNewApi(&tmp);
            var iface = &adapter.new_interface;
            var jw = std.json.Stringify{ .writer = iface };
            try beginCasJsonEnvelope(&jw, "expire", null);
            try writeExpiryReportJson(&jw, result);
            try jw.endObject();
            try iface.flush();
            if (adapter.err) |err| return err;
            try writeJsonBufferToStdout(json_buf.items);
        } else {
            try printStdout(
                alloc,
                "cas expire reflog_entries_expired={d} checkpoint_refs_expired={d} borrowed_packs_materialized={d}\n",
                .{
                    result.reflog_entries_expired,
                    result.checkpoint_refs_expired,
                    result.borrowed_packs_materialized,
                },
            );
        }
        return;
    }
    if (std.mem.eql(u8, sub, "prune")) {
        var options = cas_mod.PruneOptions{};
        var idx: usize = 1;
        while (idx < rest.len) : (idx += 1) {
            const arg = std.mem.sliceTo(rest[idx], 0);
            if (std.mem.eql(u8, arg, "--dry-run")) {
                options.dry_run = true;
            } else if (std.mem.eql(u8, arg, "--grace-ms")) {
                idx += 1;
                if (idx >= rest.len) return error.Invalid;
                options.grace_period_ms = try std.fmt.parseInt(i64, std.mem.sliceTo(rest[idx], 0), 10);
            } else {
                return error.Invalid;
            }
        }
        const result = try cas.prune(options);
        if (json_output) {
            var json_buf = std.array_list.Managed(u8).init(alloc);
            defer json_buf.deinit();
            var writer = json_buf.writer();
            var tmp: [256]u8 = undefined;
            var adapter = writer.adaptToNewApi(&tmp);
            var iface = &adapter.new_interface;
            var jw = std.json.Stringify{ .writer = iface };
            try beginCasJsonEnvelope(&jw, "prune", null);
            try jw.objectField("dry_run");
            try jw.write(options.dry_run);
            try jw.objectField("grace_period_ms");
            try jw.write(options.grace_period_ms);
            try jw.objectField("pruned_count");
            try jw.write(result.pruned_count);
            try jw.objectField("pruned_bytes");
            try jw.write(result.pruned_bytes);
            try jw.objectField("stale_segment_files");
            try jw.write(result.stale_segment_files);
            try jw.objectField("stale_segment_bytes");
            try jw.write(result.stale_segment_bytes);
            try jw.objectField("stale_wal_files");
            try jw.write(result.stale_wal_files);
            try jw.objectField("stale_wal_bytes");
            try jw.write(result.stale_wal_bytes);
            try jw.objectField("mirror_deleted");
            try jw.write(result.mirror_deleted);
            try jw.endObject();
            try iface.flush();
            if (adapter.err) |err| return err;
            try writeJsonBufferToStdout(json_buf.items);
        } else {
            try printStdout(
                alloc,
                "cas prune dry_run={} pruned={d} pruned_bytes={d} stale_segment_files={d} stale_segment_bytes={d} stale_wal_files={d} stale_wal_bytes={d} mirror_deleted={d}\n",
                .{
                    options.dry_run,
                    result.pruned_count,
                    result.pruned_bytes,
                    result.stale_segment_files,
                    result.stale_segment_bytes,
                    result.stale_wal_files,
                    result.stale_wal_bytes,
                    result.mirror_deleted,
                },
            );
        }
        return;
    }
    if (std.mem.eql(u8, sub, "vacuum")) {
        var policy = cas_mod.MaintenancePolicy{};
        var idx: usize = 1;
        while (idx < rest.len) : (idx += 1) {
            const arg = std.mem.sliceTo(rest[idx], 0);
            if (std.mem.eql(u8, arg, "--repair")) {
                policy.repair_side_indexes = true;
            } else if (std.mem.eql(u8, arg, "--materialize-borrowed")) {
                policy.materialize_borrowed_packs = true;
            } else if (std.mem.eql(u8, arg, "--reflog-expiry-ms")) {
                idx += 1;
                if (idx >= rest.len) return error.Invalid;
                policy.reflog_expiry_ms = try std.fmt.parseInt(i64, std.mem.sliceTo(rest[idx], 0), 10);
            } else if (std.mem.eql(u8, arg, "--checkpoint-expiry-ms")) {
                idx += 1;
                if (idx >= rest.len) return error.Invalid;
                policy.checkpoint_expiry_ms = try std.fmt.parseInt(i64, std.mem.sliceTo(rest[idx], 0), 10);
            } else if (std.mem.eql(u8, arg, "--prune-grace-ms")) {
                idx += 1;
                if (idx >= rest.len) return error.Invalid;
                policy.prune_grace_ms = try std.fmt.parseInt(i64, std.mem.sliceTo(rest[idx], 0), 10);
            } else {
                return error.Invalid;
            }
        }
        const result = try cas.vacuumWithPolicy(data_dir, policy);
        if (json_output) {
            try writeCasVacuumJson(alloc, result);
        } else {
            try printStdout(
                alloc,
                "cas vacuum reachable={d} rewritten={d} unreachable={d} pruned={d} deleted={d} repaired_side_indexes={} pack_sidecars_rebuilt={d} reflog_entries_expired={d} checkpoint_refs_expired={d} borrowed_packs_materialized={d}\n",
                .{
                    result.pack.reachable_objects,
                    result.pack.rewritten_objects,
                    result.gc.unreachable_count,
                    result.gc.pruned_count,
                    result.gc.deleted,
                    result.repair.side_indexes_rebuilt,
                    result.repair.pack_sidecars_rebuilt,
                    result.expiry.reflog_entries_expired,
                    result.expiry.checkpoint_refs_expired,
                    result.expiry.borrowed_packs_materialized,
                },
            );
        }
        return;
    }
    if (std.mem.eql(u8, sub, "gc")) {
        var options = cas_mod.GcOptions{};
        var idx: usize = 1;
        while (idx < rest.len) : (idx += 1) {
            const arg = std.mem.sliceTo(rest[idx], 0);
            if (std.mem.eql(u8, arg, "--apply")) {
                options.dry_run = false;
            } else if (std.mem.eql(u8, arg, "--no-reflogs")) {
                options.include_reflogs = false;
            } else if (std.mem.eql(u8, arg, "--grace-ms")) {
                idx += 1;
                if (idx >= rest.len) return error.Invalid;
                options.grace_period_ms = try std.fmt.parseInt(i64, std.mem.sliceTo(rest[idx], 0), 10);
            } else {
                return error.Invalid;
            }
        }
        const result = try cas.gc(options);
        if (json_output) {
            try writeCasGcJson(alloc, options, result);
        } else {
            try printStdout(
                alloc,
                "cas gc dry_run={} reachable={d} unreachable={d} unreachable_bytes={d} reflog_protected={d} quarantined={d} quarantined_bytes={d} pruned={d} pruned_bytes={d} deleted={d} stale_segment_files={d} stale_segment_bytes={d} stale_wal_files={d} stale_wal_bytes={d} mirror_deleted={d}\n",
                .{
                    options.dry_run,
                    result.reachable,
                    result.unreachable_count,
                    result.unreachable_bytes,
                    result.reflog_protected,
                    result.quarantined_count,
                    result.quarantined_bytes,
                    result.pruned_count,
                    result.pruned_bytes,
                    result.deleted,
                    result.stale_segment_files,
                    result.stale_segment_bytes,
                    result.stale_wal_files,
                    result.stale_wal_bytes,
                    result.mirror_deleted,
                },
            );
        }
        return;
    }
    if (std.mem.eql(u8, sub, "fsck")) {
        var options = cas_mod.FsckOptions{};
        var repair = false;
        for (rest[1..]) |raw| {
            const arg = std.mem.sliceTo(raw, 0);
            if (std.mem.eql(u8, arg, "--connectivity-only")) {
                options.mode = .connectivity_only;
            } else if (std.mem.eql(u8, arg, "--no-reflogs")) {
                options.include_reflogs = false;
            } else if (std.mem.eql(u8, arg, "--lost-found")) {
                options.write_lost_found = true;
            } else if (std.mem.eql(u8, arg, "--repair")) {
                repair = true;
            } else {
                return error.Invalid;
            }
        }
        const repair_report = if (repair)
            try cas.repairRepository(data_dir, .{})
        else
            cas_mod.RepairReport{};
        const report = try cas.fsck(data_dir, options);
        if (json_output) {
            try writeCasFsckJson(alloc, options, repair, repair_report, report);
        } else {
            try printStdout(
                alloc,
                "cas fsck mode={s} repair={} refs={d} reachable={d} reflog_heads={d} reflog_protected={d} commits={d} trees={d} blobs={d} dangling={d} lost_found={d} commit_graph_entries_checked={d} segment_contents_checked={d} wal_contents_checked={d} missing_segment_mirrors={d} missing_wal_mirrors={d} reflog_files_checked={d} stale_reflog_files={d} compatibility_legacy_segments={d} compatibility_legacy_wal={d} compatibility_loose_refs={d} repaired_side_indexes={} pack_sidecars_rebuilt={d} reftable_state_rebuilt={} reftable_tables_list_rebuilt={}\n",
                .{
                    if (options.mode == .connectivity_only) "connectivity-only" else "full",
                    repair,
                    report.refs,
                    report.reachable_objects,
                    report.reflog_heads,
                    report.reflog_protected_objects,
                    report.commit_objects,
                    report.tree_objects,
                    report.blob_objects,
                    report.dangling_objects,
                    report.lost_found_objects,
                    report.commit_graph_entries_checked,
                    report.segment_contents_checked,
                    report.wal_contents_checked,
                    report.missing_segment_mirrors,
                    report.missing_wal_mirrors,
                    report.reflog_files_checked,
                    report.stale_reflog_files,
                    report.compatibility_debt.legacy_segment_descriptors,
                    report.compatibility_debt.legacy_wal_descriptors,
                    report.compatibility_debt.loose_refs_present,
                    repair_report.side_indexes_rebuilt,
                    repair_report.pack_sidecars_rebuilt,
                    repair_report.reftable_state_rebuilt,
                    repair_report.reftable_tables_list_rebuilt,
                },
            );
        }
        return;
    }
    if (std.mem.eql(u8, sub, "pack")) {
        const result = try cas.pack();
        if (json_output) {
            try writeCasPackJson(alloc, result);
        } else {
            try printStdout(alloc, "cas pack reachable={d} rewritten={d}\n", .{ result.reachable_objects, result.rewritten_objects });
        }
        return;
    }
    if (std.mem.eql(u8, sub, "checkout")) {
        if (rest.len < 2) return error.Invalid;
        try cas.exportSpecToLegacy(std.mem.sliceTo(rest[1], 0), data_dir);
        return;
    }
    if (std.mem.eql(u8, sub, "export-legacy")) {
        const spec = if (rest.len >= 2) std.mem.sliceTo(rest[1], 0) else cas_mod.main_ref;
        try cas.exportSpecToLegacy(spec, data_dir);
        return;
    }
    return error.Invalid;
}

test "loadConfigOrDefault prefers primary defaults for fresh repositories" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const config_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/missing.toml", .{tmp.sub_path});
    defer alloc.free(config_path);
    const data_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/fresh-data", .{tmp.sub_path});
    defer alloc.free(data_path);

    var cfg = try loadConfigOrDefaultForPaths(alloc, config_path, data_path);
    defer cfg.deinit(alloc);

    try std.testing.expectEqual(config.CasMode.dual_write, cfg.cas_mode);
    try std.testing.expectEqual(config.MetadataReadMode.primary, cfg.metadata_read_mode);
}

test "loadConfigOrDefault preserves legacy defaults for existing legacy repositories" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_rel = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/legacy-data", .{tmp.sub_path});
    defer alloc.free(data_rel);
    try std.fs.cwd().makePath(data_rel);
    var data_dir = try std.fs.cwd().openDir(data_rel, .{ .iterate = true });
    defer data_dir.close();
    try data_dir.writeFile(.{ .sub_path = "MANIFEST", .data = "", .flags = .{} });

    const config_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/missing.toml", .{tmp.sub_path});
    defer alloc.free(config_path);

    var cfg = try loadConfigOrDefaultForPaths(alloc, config_path, data_rel);
    defer cfg.deinit(alloc);

    try std.testing.expectEqual(config.CasMode.off, cfg.cas_mode);
    try std.testing.expectEqual(config.MetadataReadMode.legacy, cfg.metadata_read_mode);
}

test "loadConfigOrDefault prefers primary defaults for migrated reftable repositories" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_rel = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/reftable-data", .{tmp.sub_path});
    defer alloc.free(data_rel);
    var cas = try cas_mod.CasManager.init(alloc, data_rel, .none);
    defer cas.deinit();

    const config_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/missing.toml", .{tmp.sub_path});
    defer alloc.free(config_path);

    var cfg = try loadConfigOrDefaultForPaths(alloc, config_path, data_rel);
    defer cfg.deinit(alloc);

    try std.testing.expectEqual(config.CasMode.dual_write, cfg.cas_mode);
    try std.testing.expectEqual(config.MetadataReadMode.primary, cfg.metadata_read_mode);
}
