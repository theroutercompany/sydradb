const std = @import("std");
const Engine = @import("engine.zig").Engine;
const types = @import("types.zig");
const config = @import("config.zig");
const compat = @import("compat.zig");
const query_exec = @import("query/exec.zig");
const plan = @import("query/plan.zig");
const query_executor = @import("query/executor.zig");
const query_value = @import("query/value.zig");
const query_functions = @import("query/functions.zig");
const alloc_mod = @import("alloc.zig");

pub fn runHttp(handle: *alloc_mod.AllocatorHandle, eng: *Engine, port: u16) !void {
    var address = try std.net.Address.parseIp4("0.0.0.0", port);
    var server = try address.listen(.{ .reuse_address = true });
    defer server.deinit();

    while (true) {
        const connection = server.accept() catch |err| switch (err) {
            error.ConnectionResetByPeer, error.ConnectionAborted => continue,
            else => return err,
        };
        const worker = std.Thread.spawn(.{}, connectionWorker, .{ handle, eng, connection }) catch |spawn_err| {
            std.log.err("http spawn failed: {s}", .{@errorName(spawn_err)});
            connection.stream.close();
            continue;
        };
        worker.detach();
    }
}

fn connectionWorker(handle: *alloc_mod.AllocatorHandle, eng: *Engine, connection: std.net.Server.Connection) void {
    const alloc = std.heap.c_allocator;
    handleConnection(handle, alloc, eng, connection) catch |err| switch (err) {
        error.HttpConnectionClosing, error.HttpRequestTruncated => {},
        else => std.log.warn("http connection error: {s}", .{@errorName(err)}),
    };
}

fn handleConnection(handle: *alloc_mod.AllocatorHandle, alloc: std.mem.Allocator, eng: *Engine, connection: std.net.Server.Connection) !void {
    defer connection.stream.close();

    var in_buf: [4096]u8 = undefined;
    var out_buf: [4096]u8 = undefined;
    var reader_state = connection.stream.reader(&in_buf);
    var writer_state = connection.stream.writer(&out_buf);
    var http_server = std.http.Server.init(reader_state.interface(), writer_state.interface());

    while (true) {
        var req = http_server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing, error.HttpRequestTruncated => return,
            else => return err,
        };
        handleRequest(handle, alloc, eng, &req) catch |err| switch (err) {
            error.HttpExpectationFailed => {
                _ = req.respond("expectation failed", .{ .status = .expectation_failed, .keep_alive = false }) catch {};
                return;
            },
            else => return err,
        };
    }
}

fn handleRequest(handle: *alloc_mod.AllocatorHandle, alloc: std.mem.Allocator, eng: *Engine, req: *std.http.Server.Request) !void {
    const target = req.head.target;
    var path = target;
    var query: []const u8 = "";
    if (std.mem.indexOfScalar(u8, target, '?')) |idx| {
        path = target[0..idx];
        if (idx + 1 < target.len) query = target[idx + 1 ..];
    }
    const method = req.head.method;

    if (std.mem.startsWith(u8, path, "/api/") and eng.config.auth_token.len != 0) {
        const maybe_auth = findHeader(req, "authorization");
        if (maybe_auth) |auth| {
            if (!(std.mem.startsWith(u8, auth, "Bearer ") and std.mem.eql(u8, auth[7..], eng.config.auth_token))) {
                try req.respond("unauthorized", .{ .status = .unauthorized, .keep_alive = false });
                return;
            }
        } else {
            try req.respond("unauthorized", .{ .status = .unauthorized, .keep_alive = false });
            return;
        }
    }

    if (std.mem.eql(u8, path, "/metrics") and method == .GET) {
        return try handleMetrics(alloc, eng, req);
    }
    if (std.mem.eql(u8, path, "/debug/compat/stats") and method == .GET) {
        return try handleCompatStats(req);
    }
    if (std.mem.eql(u8, path, "/debug/compat/catalog") and method == .GET) {
        return try handleCompatCatalog(alloc, req);
    }
    if (std.mem.eql(u8, path, "/debug/alloc/stats") and method == .GET) {
        return try handleAllocStats(handle, req);
    }
    if (std.mem.eql(u8, path, "/status") and method == .GET) {
        return try handleStatus(req);
    }
    if (std.mem.eql(u8, path, "/api/v1/ingest") and method == .POST) {
        return try handleIngest(alloc, eng, req);
    }
    if (std.mem.eql(u8, path, "/api/v1/query/range") and method == .POST) {
        return try handleQuery(alloc, eng, req);
    }
    if (std.mem.eql(u8, path, "/api/v1/query/range") and method == .GET) {
        return try handleQueryGet(alloc, eng, req, query);
    }
    if (std.mem.eql(u8, path, "/api/v1/query/find") and method == .POST) {
        return try handleFind(alloc, eng, req);
    }
    if (std.mem.eql(u8, path, "/api/v1/sydraql") and method == .POST) {
        return try handleSydraql(alloc, eng, req);
    }

    try req.respond("not found", .{ .status = .not_found });
}

fn handleAllocStats(handle: *alloc_mod.AllocatorHandle, req: *std.http.Server.Request) !void {
    if (!alloc_mod.is_small_pool) {
        try req.respond("allocator mode does not expose small_pool stats", .{ .status = .not_found });
        return;
    }

    const stats = handle.snapshotSmallPoolStats();
    var send_buf: [512]u8 = undefined;
    var response = try req.respondStreaming(&send_buf, .{
        .respond_options = .{ .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} },
    });
    errdefer response.end() catch {};

    var writer = response.writer;
    var jw = std.json.Stringify{ .writer = &writer };
    try jw.beginObject();
    try jw.objectField("allocator_mode");
    try jw.write(alloc_mod.mode);
    try jw.objectField("small_pool");
    try jw.beginObject();
    try jw.objectField("shard_enabled");
    try jw.write(stats.shard_enabled);
    try jw.objectField("shard_count");
    try jw.write(stats.shard_count);
    try jw.objectField("shard_alloc_hits");
    try jw.write(stats.shard_alloc_hits);
    try jw.objectField("shard_alloc_misses");
    try jw.write(stats.shard_alloc_misses);
    try jw.objectField("shard_deferred_total");
    try jw.write(stats.shard_deferred_total);
    try jw.objectField("shard_epoch_current");
    try jw.write(stats.shard_current_epoch);
    try jw.objectField("shard_epoch_min");
    try jw.write(stats.shard_min_epoch);

    try jw.objectField("fallback");
    try jw.beginObject();
    try jw.objectField("allocs");
    try jw.write(stats.fallback_allocs);
    try jw.objectField("frees");
    try jw.write(stats.fallback_frees);
    try jw.objectField("resizes");
    try jw.write(stats.fallback_resizes);
    try jw.objectField("remaps");
    try jw.write(stats.fallback_remaps);
    try jw.objectField("size_buckets");
    try jw.beginArray();
    inline for (stats.fallback_size_buckets, 0..) |count, idx| {
        try jw.beginObject();
        try jw.objectField("count");
        try jw.write(count);
        try jw.objectField("upper_bound");
        if (stats.fallback_size_bounds[idx]) |bound| {
            try jw.write(bound);
        } else {
            try jw.writeNull();
        }
        try jw.endObject();
    }
    try jw.endArray();
    try jw.endObject(); // fallback

    try jw.objectField("buckets");
    try jw.beginArray();
    inline for (stats.buckets) |bucket| {
        try jw.beginObject();
        try jw.objectField("size");
        try jw.write(bucket.size);
        try jw.objectField("alloc_size");
        try jw.write(bucket.alloc_size);
        try jw.objectField("allocations");
        try jw.write(bucket.allocations);
        try jw.objectField("in_use");
        try jw.write(bucket.in_use);
        try jw.objectField("high_water");
        try jw.write(bucket.high_water);
        try jw.objectField("refills");
        try jw.write(bucket.refills);
        try jw.objectField("slabs");
        try jw.write(bucket.slabs);
        try jw.objectField("free_nodes");
        try jw.write(bucket.free_nodes);
        try jw.objectField("lock_wait_ns_total");
        try jw.write(bucket.lock_wait_ns_total);
        try jw.objectField("lock_hold_ns_total");
        try jw.write(bucket.lock_hold_ns_total);
        try jw.objectField("lock_acquisitions");
        try jw.write(bucket.lock_acquisitions);
        try jw.objectField("lock_contention");
        try jw.write(bucket.lock_contention);
        try jw.endObject();
    }
    try jw.endArray();
    try jw.endObject(); // small_pool
    try jw.endObject();
    try response.end();
}
fn handleSydraql(alloc: std.mem.Allocator, eng: *Engine, req: *std.http.Server.Request) !void {
    var body_buf: [1024]u8 = undefined;
    const body_reader = req.readerExpectNone(&body_buf);
    const content_len = req.head.content_length orelse {
        return respondJsonError(alloc, req, .length_required, "length required");
    };
    if (content_len > 256 * 1024) {
        return respondJsonError(alloc, req, .payload_too_large, "payload too large");
    }

    const len: usize = @intCast(content_len);
    const body_slice = try body_reader.*.take(len);
    const body = try alloc.dupe(u8, body_slice);
    defer alloc.free(body);

    const sydraql = std.mem.trim(u8, body, " \t\r\n");
    if (sydraql.len == 0) {
        return respondJsonError(alloc, req, .bad_request, "query required");
    }

    const start_time = std.time.microTimestamp();
    var cursor = query_exec.execute(alloc, eng, sydraql) catch |err| {
        return respondExecutionError(alloc, req, err);
    };
    defer cursor.deinit();

    var send_buf: [1024]u8 = undefined;
    var response = try req.respondStreaming(&send_buf, .{
        .respond_options = .{
            .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        },
    });
    errdefer response.end() catch {};

    var writer = response.writer;
    var jw = std.json.Stringify{ .writer = &writer };

    try jw.beginObject();
    try jw.objectField("columns");
    try jw.beginArray();
    const default_type = query_functions.Type.init(.value, true);
    for (cursor.columns) |col| {
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(col.name);
        try jw.objectField("type");
        try jw.write(query_functions.displayName(default_type));
        try jw.objectField("nullable");
        try jw.write(default_type.nullable);
        try jw.endObject();
    }
    try jw.endArray();
    try jw.objectField("rows");
    try jw.beginArray();
    var row_count: usize = 0;
    while (try cursor.next()) |row| {
        try jw.beginArray();
        for (row.values) |cell| {
            try writeJsonValue(&jw, cell);
        }
        try jw.endArray();
        row_count += 1;
    }
    try jw.endArray();
    const op_stats = try cursor.collectOperatorStats(alloc);
    defer alloc.free(op_stats);
    var rows_scanned: u64 = 0;
    for (op_stats) |stat| {
        if (std.ascii.eqlIgnoreCase(stat.name, "scan")) {
            rows_scanned += stat.rows_out;
        }
    }
    cursor.stats.rows_emitted = @as(u64, @intCast(row_count));
    cursor.stats.rows_scanned = rows_scanned;
    const elapsed_us_signed = std.time.microTimestamp() - start_time;
    const elapsed_us = @as(u64, @intCast(elapsed_us_signed));
    try writeStatsObject(&jw, row_count, elapsed_us, &cursor.stats, op_stats, cursor.columns);
    try jw.endObject();

    try response.end();
}

fn respondExecutionError(alloc: std.mem.Allocator, req: *std.http.Server.Request, err: query_exec.ExecuteError) !void {
    const status: std.http.Status = switch (err) {
        error.OutOfMemory => .internal_server_error,
        error.UnsupportedPlan,
        error.UnsupportedExpression,
        error.UnsupportedAggregate,
        error.ValidationFailed,
        => .bad_request,
        else => .bad_request,
    };
    return respondJsonError(alloc, req, status, @errorName(err));
}

fn respondJsonError(
    alloc: std.mem.Allocator,
    req: *std.http.Server.Request,
    status: std.http.Status,
    message: []const u8,
) !void {
    const payload = try std.fmt.allocPrint(alloc, "{{\"error\":\"{s}\"}}", .{message});
    defer alloc.free(payload);
    const headers = [_]std.http.Header{.{ .name = "Content-Type", .value = "application/json" }};
    try req.respond(payload, .{ .status = status, .keep_alive = false, .extra_headers = &headers });
}

fn writeJsonValue(jw: *std.json.Stringify, value: query_value.Value) !void {
    switch (value) {
        .null => try jw.write(null),
        .boolean => |b| try jw.write(b),
        .integer => |i| try jw.write(i),
        .float => |f| try jw.write(f),
        .string => |s| try jw.write(s),
    }
}

fn writeStatsObject(
    jw: *std.json.Stringify,
    stream_rows: usize,
    stream_us: u64,
    stats: *const query_executor.ExecutionStats,
    operators: []const query_executor.OperatorStats,
    columns: []const plan.ColumnInfo,
) !void {
    try jw.objectField("stats");
    try jw.beginObject();
    try jw.objectField("stream_rows");
    try jw.write(stream_rows);
    try jw.objectField("stream_ms");
    try jw.write(usToMs(stream_us));
    try jw.objectField("parse_ms");
    try jw.write(usToMs(stats.parse_us));
    try jw.objectField("validate_ms");
    try jw.write(usToMs(stats.validate_us));
    try jw.objectField("optimize_ms");
    try jw.write(usToMs(stats.optimize_us));
    try jw.objectField("physical_ms");
    try jw.write(usToMs(stats.physical_us));
    try jw.objectField("pipeline_ms");
    try jw.write(usToMs(stats.pipeline_us));
    try jw.objectField("rows_emitted");
    try jw.write(stats.rows_emitted);
    try jw.objectField("rows_scanned");
    try jw.write(stats.rows_scanned);
    if (stats.trace_id.len != 0) {
        try jw.objectField("trace_id");
        try jw.write(stats.trace_id);
    }
    try jw.objectField("schema");
    try jw.beginArray();
    const default_type = query_functions.Type.init(.value, true);
    for (columns) |col| {
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(col.name);
        try jw.objectField("type");
        try jw.write(query_functions.displayName(default_type));
        try jw.objectField("nullable");
        try jw.write(default_type.nullable);
        try jw.endObject();
    }
    try jw.endArray();
    try jw.objectField("operators");
    try jw.beginArray();
    for (operators) |op| {
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(op.name);
        try jw.objectField("rows_out");
        try jw.write(op.rows_out);
        try jw.objectField("elapsed_ms");
        try jw.write(usToMs(op.elapsed_us));
        try jw.endObject();
    }
    try jw.endArray();
    try jw.endObject();
}

fn usToMs(value: u64) f64 {
    return @as(f64, @floatFromInt(value)) / 1000.0;
}

fn findHeader(req: *std.http.Server.Request, name: []const u8) ?[]const u8 {
    var it = req.iterateHeaders();
    while (it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
    }
    return null;
}

test "writeStatsObject emits operator metrics" {
    const alloc = std.testing.allocator;
    var buffer = std.ArrayList(u8).init(alloc);
    defer buffer.deinit();
    var writer = buffer.writer();
    var jw = std.json.Stringify{ .writer = &writer };

    try jw.beginObject();
    var stats = query_executor.ExecutionStats{
        .parse_us = 100,
        .validate_us = 200,
        .optimize_us = 300,
        .physical_us = 400,
        .pipeline_us = 500,
        .trace_id = "",
        .rows_emitted = 5,
        .rows_scanned = 5,
    };
    const ops = [_]query_executor.OperatorStats{
        .{ .name = "scan", .elapsed_us = 2000, .rows_out = 5 },
    };
    const ast = @import("query/ast.zig");
    const common = @import("query/common.zig");
    const expr = try alloc.create(ast.Expr);
    defer alloc.destroy(expr);
    expr.* = .{ .literal = .{
        .value = .null,
        .span = common.Span.init(0, 0),
    } };
    const columns = [_]plan.ColumnInfo{
        .{ .name = "value", .expr = expr },
    };
    try writeStatsObject(&jw, 5, 5000, &stats, &ops, columns[0..]);
    try jw.endObject();

    const json = buffer.items;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"operators\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"rows_out\":5") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"scan\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"schema\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"nullable\":true") != null);
}

fn handleMetrics(alloc: std.mem.Allocator, eng: *Engine, req: *std.http.Server.Request) !void {
    const ingest_total = eng.metrics.ingest_total.load(.monotonic);
    const flush_total = eng.metrics.flush_total.load(.monotonic);
    const flush_ns_total = eng.metrics.flush_ns_total.load(.monotonic);
    const flush_points_total = eng.metrics.flush_points_total.load(.monotonic);
    const wal_bytes_total = eng.metrics.wal_bytes_total.load(.monotonic);
    const queue_depth = eng.queue.len();
    const memtable_bytes = eng.mem.bytes.load(.monotonic);
    const flush_seconds_total = @as(f64, @floatFromInt(flush_ns_total)) / 1_000_000_000.0;

    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();
    var writer = buf.writer();

    try writer.writeAll("# HELP sydradb_up 1 if server is up\n# TYPE sydradb_up gauge\nsydradb_up 1\n");
    try writer.print("# HELP sydradb_ingest_total Total ingested points since start\n# TYPE sydradb_ingest_total counter\nsydradb_ingest_total {d}\n", .{ingest_total});
    try writer.print("# HELP sydradb_flush_total Total flush operations\n# TYPE sydradb_flush_total counter\nsydradb_flush_total {d}\n", .{flush_total});
    try writer.print("# HELP sydradb_flush_seconds_total Aggregate flush duration in seconds\n# TYPE sydradb_flush_seconds_total counter\nsydradb_flush_seconds_total {d:.6}\n", .{flush_seconds_total});
    try writer.print("# HELP sydradb_flush_points_total Total points flushed to disk\n# TYPE sydradb_flush_points_total counter\nsydradb_flush_points_total {d}\n", .{flush_points_total});
    try writer.print("# HELP sydradb_wal_bytes_total Total bytes written to WAL\n# TYPE sydradb_wal_bytes_total counter\nsydradb_wal_bytes_total {d}\n", .{wal_bytes_total});
    try writer.print("# HELP sydradb_queue_depth Current ingest queue depth\n# TYPE sydradb_queue_depth gauge\nsydradb_queue_depth {d}\n", .{queue_depth});
    try writer.print("# HELP sydradb_memtable_bytes Current memtable size in bytes\n# TYPE sydradb_memtable_bytes gauge\nsydradb_memtable_bytes {d}\n", .{memtable_bytes});

    const headers = [_]std.http.Header{.{ .name = "Content-Type", .value = "text/plain; version=0.0.4" }};
    try req.respond(buf.items, .{ .extra_headers = &headers });
}

fn handleCompatStats(req: *std.http.Server.Request) !void {
    const snap = compat.stats.global().snapshot();
    var buf: [128]u8 = undefined;
    const body = try std.fmt.bufPrint(
        &buf,
        "{{\"translations\":{d},\"fallbacks\":{d},\"cache_hits\":{d}}}",
        .{ snap.translations, snap.fallbacks, snap.cache_hits },
    );
    const headers = [_]std.http.Header{.{ .name = "Content-Type", .value = "application/json" }};
    try req.respond(body, .{ .extra_headers = &headers });
}

fn handleCompatCatalog(alloc: std.mem.Allocator, req: *std.http.Server.Request) !void {
    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();

    var jw_writer = buf.writer();
    var jw_buffer: [512]u8 = undefined;
    var jw_adapter = jw_writer.adaptToNewApi(&jw_buffer);
    var jw_iface = &jw_adapter.new_interface;
    var jw = std.json.Stringify{ .writer = jw_iface };
    try jw.beginObject();

    const store = compat.catalog.global();

    try jw.objectField("namespaces");
    try jw.beginArray();
    for (store.namespaces()) |ns| {
        try jw.beginObject();
        try jw.objectField("oid");
        try jw.write(ns.oid);
        try jw.objectField("name");
        try jw.write(ns.nspname);
        try jw.endObject();
    }
    try jw.endArray();

    try jw.objectField("classes");
    try jw.beginArray();
    for (store.classes()) |cls| {
        try jw.beginObject();
        try jw.objectField("oid");
        try jw.write(cls.oid);
        try jw.objectField("name");
        try jw.write(cls.relname);
        try jw.objectField("namespace");
        try jw.write(cls.relnamespace);
        const kind_buf = [_]u8{cls.relkind};
        try jw.objectField("kind");
        try jw.write(kind_buf[0..]);
        const pers_buf = [_]u8{cls.relpersistence};
        try jw.objectField("persistence");
        try jw.write(pers_buf[0..]);
        try jw.objectField("tuples");
        try jw.write(cls.reltuples);
        try jw.objectField("has_pkey");
        try jw.write(cls.relhaspkey);
        try jw.objectField("is_partition");
        try jw.write(cls.relispartition);
        try jw.objectField("toast_oid");
        try jw.write(cls.reltoastrelid);
        try jw.endObject();
    }
    try jw.endArray();

    try jw.objectField("attributes");
    try jw.beginArray();
    for (store.attributes()) |attr| {
        try jw.beginObject();
        try jw.objectField("rel_oid");
        try jw.write(attr.attrelid);
        try jw.objectField("name");
        try jw.write(attr.attname);
        try jw.objectField("type_oid");
        try jw.write(attr.atttypid);
        try jw.objectField("attnum");
        try jw.write(attr.attnum);
        try jw.objectField("not_null");
        try jw.write(attr.attnotnull);
        try jw.objectField("has_default");
        try jw.write(attr.atthasdef);
        try jw.objectField("is_dropped");
        try jw.write(attr.attisdropped);
        try jw.objectField("len");
        try jw.write(attr.attlen);
        try jw.objectField("typmod");
        try jw.write(attr.atttypmod);
        const identity_buf = [_]u8{attr.attidentity};
        try jw.objectField("identity");
        try jw.write(identity_buf[0..]);
        const generated_buf = [_]u8{attr.attgenerated};
        try jw.objectField("generated");
        try jw.write(generated_buf[0..]);
        try jw.objectField("dims");
        try jw.write(attr.attndims);
        try jw.endObject();
    }
    try jw.endArray();

    try jw.objectField("types");
    try jw.beginArray();
    for (store.types()) |ty| {
        try jw.beginObject();
        try jw.objectField("oid");
        try jw.write(ty.oid);
        try jw.objectField("name");
        try jw.write(ty.typname);
        try jw.objectField("namespace");
        try jw.write(ty.typnamespace);
        try jw.objectField("len");
        try jw.write(ty.typlen);
        try jw.objectField("byval");
        try jw.write(ty.typbyval);
        const type_buf = [_]u8{ty.typtype};
        try jw.objectField("type");
        try jw.write(type_buf[0..]);
        try jw.objectField("category");
        const cat_buf = [_]u8{ty.typcategory};
        try jw.write(cat_buf[0..]);
        try jw.objectField("delim");
        const delim_buf = [_]u8{ty.typdelim};
        try jw.write(delim_buf[0..]);
        try jw.objectField("elem");
        try jw.write(ty.typelem);
        try jw.objectField("array");
        try jw.write(ty.typarray);
        try jw.objectField("basetype");
        try jw.write(ty.typbasetype);
        try jw.objectField("collation");
        try jw.write(ty.typcollation);
        try jw.objectField("input");
        try jw.write(ty.typinput);
        try jw.objectField("output");
        try jw.write(ty.typoutput);
        try jw.endObject();
    }
    try jw.endArray();

    try jw.endObject();
    try jw_iface.flush();
    if (jw_adapter.err) |write_err| return write_err;

    const headers = [_]std.http.Header{.{ .name = "Content-Type", .value = "application/json" }};
    try req.respond(buf.items, .{ .extra_headers = &headers });
}

fn handleStatus(req: *std.http.Server.Request) !void {
    const headers = [_]std.http.Header{.{ .name = "Content-Type", .value = "application/json" }};
    try req.respond("{\"status\":\"ok\"}", .{ .extra_headers = &headers });
}

const default_tags_json = "{}";

const TagsJson = struct {
    value: []const u8,
    owned: ?[]u8 = null,
};

fn extractTagsJson(alloc: std.mem.Allocator, maybe_value: ?std.json.Value) !TagsJson {
    if (maybe_value) |val| {
        if (val == .object) {
            var list = std.array_list.Managed(u8).init(alloc);
            errdefer list.deinit();
            var writer = list.writer();
            var tmp: [128]u8 = undefined;
            var adapter = writer.adaptToNewApi(&tmp);
            var iface = &adapter.new_interface;
            var stream = std.json.Stringify{ .writer = iface };
            try stream.write(val);
            try iface.flush();
            if (adapter.err) |write_err| return write_err;
            const owned = try list.toOwnedSlice();
            return .{ .value = owned, .owned = owned };
        }
    }
    return .{ .value = default_tags_json };
}

fn handleIngest(alloc: std.mem.Allocator, eng: *Engine, req: *std.http.Server.Request) !void {
    var body_buf: [4096]u8 = undefined;
    const body_reader = req.readerExpectNone(&body_buf);
    var count: usize = 0;

    while (true) {
        const slice = body_reader.*.takeDelimiterExclusive('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                _ = req.respond("line too long", .{ .status = .payload_too_large, .keep_alive = false }) catch {};
                return;
            },
            error.EndOfStream => break,
            else => return err,
        };
        const trimmed = std.mem.trim(u8, slice, " \t\r\n");
        if (trimmed.len == 0) continue;

        const line = try alloc.dupe(u8, trimmed);
        if (line.len == 0) continue;
        defer alloc.free(line);

        var parsed = std.json.parseFromSlice(std.json.Value, alloc, line, .{}) catch continue;
        defer parsed.deinit();
        const obj = parsed.value.object;
        const series = obj.get("series").?.string;
        const ts: i64 = @intCast(obj.get("ts").?.integer);
        const value: f64 = if (obj.get("value")) |v| switch (v) {
            .float => v.float,
            .integer => @floatFromInt(v.integer),
            else => 0,
        } else blk: {
            if (obj.get("fields")) |fields_val| {
                if (fields_val == .object) {
                    var it = fields_val.object.iterator();
                    while (it.next()) |e| switch (e.value_ptr.*) {
                        .float => break :blk e.value_ptr.float,
                        .integer => break :blk @floatFromInt(e.value_ptr.integer),
                        else => {},
                    };
                }
            }
            break :blk 0;
        };
        const tags = try extractTagsJson(alloc, obj.get("tags"));
        defer if (tags.owned) |buf| alloc.free(buf);
        const sid = types.seriesIdFrom(series, tags.value);
        try eng.ingest(.{ .series_id = sid, .ts = ts, .value = value, .tags_json = try alloc.dupe(u8, tags.value) });
        eng.noteTags(sid, tags.value);
        count += 1;
    }

    var buf: [64]u8 = undefined;
    const body = try std.fmt.bufPrint(&buf, "{{\"ingested\":{d}}}", .{count});
    const headers = [_]std.http.Header{.{ .name = "Content-Type", .value = "application/json" }};
    try req.respond(body, .{ .extra_headers = &headers });
}

fn handleQuery(alloc: std.mem.Allocator, eng: *Engine, req: *std.http.Server.Request) !void {
    var body_buf: [1024]u8 = undefined;
    const body_reader = req.readerExpectNone(&body_buf);
    const content_len = req.head.content_length orelse {
        try req.respond("length required", .{ .status = .length_required, .keep_alive = false });
        return;
    };
    if (content_len > 1024 * 64) {
        try req.respond("payload too large", .{ .status = .payload_too_large, .keep_alive = false });
        return;
    }
    const alloc_len: usize = @intCast(content_len);
    const body_slice = try body_reader.*.take(alloc_len);
    const body = try alloc.dupe(u8, body_slice);
    defer alloc.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    var series_id: ?types.SeriesId = null;
    if (obj.get("series_id")) |v| {
        series_id = @intCast(v.integer);
    } else if (obj.get("series")) |v| {
        const tags = try extractTagsJson(alloc, obj.get("tags"));
        defer if (tags.owned) |buf| alloc.free(buf);
        series_id = types.seriesIdFrom(v.string, tags.value);
    }
    const start_val = obj.get("start") orelse {
        try req.respond("missing start", .{ .status = .bad_request, .keep_alive = false });
        return;
    };
    const end_val = obj.get("end") orelse {
        try req.respond("missing end", .{ .status = .bad_request, .keep_alive = false });
        return;
    };
    const start_ts: i64 = @intCast(start_val.integer);
    const end_ts: i64 = @intCast(end_val.integer);
    const sid = series_id orelse {
        try req.respond("missing series identifier", .{ .status = .bad_request, .keep_alive = false });
        return;
    };
    try queryAndRespond(alloc, eng, req, sid, start_ts, end_ts);
}

fn handleQueryGet(alloc: std.mem.Allocator, eng: *Engine, req: *std.http.Server.Request, query: []const u8) !void {
    if (query.len == 0) {
        try req.respond("missing query parameters", .{ .status = .bad_request, .keep_alive = false });
        return;
    }
    var series_opt: ?[]const u8 = null;
    var series_id_opt: ?types.SeriesId = null;
    var tags_opt: ?[]const u8 = null;
    var start_opt: ?i64 = null;
    var end_opt: ?i64 = null;
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        if (pair.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const key = pair[0..eq];
        const value = pair[eq + 1 ..];
        if (std.mem.eql(u8, key, "series_id")) {
            series_id_opt = std.fmt.parseInt(types.SeriesId, value, 10) catch {
                try req.respond("invalid series_id", .{ .status = .bad_request, .keep_alive = false });
                return;
            };
        } else if (std.mem.eql(u8, key, "series")) {
            series_opt = value;
        } else if (std.mem.eql(u8, key, "tags")) {
            tags_opt = value;
        } else if (std.mem.eql(u8, key, "start")) {
            start_opt = std.fmt.parseInt(i64, value, 10) catch null;
        } else if (std.mem.eql(u8, key, "end")) {
            end_opt = std.fmt.parseInt(i64, value, 10) catch null;
        }
    }
    const sid = series_id_opt orelse (if (series_opt) |name| types.seriesIdFrom(name, tags_opt orelse default_tags_json) else null) orelse {
        try req.respond("missing series or series_id", .{ .status = .bad_request, .keep_alive = false });
        return;
    };
    const start_ts = start_opt orelse {
        try req.respond("missing start", .{ .status = .bad_request, .keep_alive = false });
        return;
    };
    const end_ts = end_opt orelse {
        try req.respond("missing end", .{ .status = .bad_request, .keep_alive = false });
        return;
    };
    try queryAndRespond(alloc, eng, req, sid, start_ts, end_ts);
}

fn queryAndRespond(alloc: std.mem.Allocator, eng: *Engine, req: *std.http.Server.Request, sid: types.SeriesId, start_ts: i64, end_ts: i64) !void {
    var points = try std.array_list.Managed(types.Point).initCapacity(alloc, 0);
    defer points.deinit();
    try eng.queryRange(sid, start_ts, end_ts, &points);
    try respondPoints(req, points.items);
}

fn respondPoints(req: *std.http.Server.Request, points: []const types.Point) !void {
    var send_buffer: [1024]u8 = undefined;
    var response = try req.respondStreaming(&send_buffer, .{
        .respond_options = .{
            .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        },
    });
    errdefer response.end() catch {};

    const resp_writer = &response.writer;
    try resp_writer.writeAll("[");
    var first = true;
    for (points) |pnt| {
        if (!first) try resp_writer.writeAll(",");
        first = false;
        try resp_writer.print("{{\"ts\":{d},\"value\":{d}}}", .{ pnt.ts, pnt.value });
    }
    try resp_writer.writeAll("]");
    try response.end();
}

fn handleFind(alloc: std.mem.Allocator, eng: *Engine, req: *std.http.Server.Request) !void {
    var body_buf: [1024]u8 = undefined;
    const body_reader = req.readerExpectNone(&body_buf);
    const content_len = req.head.content_length orelse {
        try req.respond("length required", .{ .status = .length_required, .keep_alive = false });
        return;
    };
    if (content_len > 64 * 1024) {
        try req.respond("payload too large", .{ .status = .payload_too_large, .keep_alive = false });
        return;
    }
    const alloc_len: usize = @intCast(content_len);
    const body_slice = try body_reader.*.take(alloc_len);
    const body = try alloc.dupe(u8, body_slice);
    defer alloc.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    var op_and = true;
    if (obj.get("op")) |v| {
        if (v == .string and std.ascii.eqlIgnoreCase(v.string, "or")) op_and = false;
    }
    var sets = try std.array_list.Managed([]const u64).initCapacity(alloc, 0);
    defer sets.deinit();
    if (obj.get("tags")) |t| {
        if (t == .object) {
            var it = t.object.iterator();
            while (it.next()) |e| {
                const key = std.fmt.allocPrint(alloc, "{s}={s}", .{ e.key_ptr.*, e.value_ptr.string }) catch continue;
                defer alloc.free(key);
                try sets.append(eng.tags.get(key));
            }
        }
    }
    var result = std.AutoHashMap(u64, void).init(alloc);
    defer result.deinit();
    var first = true;
    for (sets.items) |arr| {
        if (first) {
            for (arr) |sid| result.put(sid, {}) catch {};
            first = false;
            continue;
        }
        if (op_and) {
            var it = result.iterator();
            while (it.next()) |entry| {
                var found = false;
                for (arr) |sid| {
                    if (sid == entry.key_ptr.*) {
                        found = true;
                        break;
                    }
                }
                if (!found) _ = result.remove(entry.key_ptr.*);
            }
        } else {
            for (arr) |sid| result.put(sid, {}) catch {};
        }
    }

    var send_buffer: [512]u8 = undefined;
    var response = try req.respondStreaming(&send_buffer, .{
        .respond_options = .{
            .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        },
    });
    errdefer response.end() catch {};

    const resp_writer = &response.writer;
    try resp_writer.writeAll("[");
    var it2 = result.keyIterator();
    var first2 = true;
    while (it2.next()) |k| {
        if (!first2) try resp_writer.writeAll(",");
        first2 = false;
        try resp_writer.print("{d}", .{k.*});
    }
    try resp_writer.writeAll("]");
    try response.end();
}
