const std = @import("std");
const Engine = @import("engine.zig").Engine;
const types = @import("types.zig");
const config = @import("config.zig");
const compat = @import("compat.zig");
const cas_mod = @import("storage/cas.zig");
const annotations_mod = @import("storage/annotations.zig");
const metric_catalog_mod = @import("storage/metric_catalog.zig");
const query_exec = @import("query/exec.zig");
const compiler_diagnostics = @import("query/compiler/diagnostics.zig");
const query_common = @import("query/common.zig");
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
    var http_server = std.http.Server.init(reader_state.interface(), &writer_state.interface);

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
                try respondJsonError(alloc, req, .unauthorized, "unauthorized", "unauthorized");
                return;
            }
        } else {
            try respondJsonError(alloc, req, .unauthorized, "unauthorized", "unauthorized");
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
        return try handleStatus(alloc, eng, req);
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
    if (std.mem.eql(u8, path, "/api/v1/metrics/find") and method == .POST) {
        return try handleMetricsFind(alloc, eng, req);
    }
    if (std.mem.eql(u8, path, "/api/v1/series/find") and method == .POST) {
        return try handleSeriesFind(alloc, eng, req);
    }
    if (std.mem.eql(u8, path, "/api/v1/labels/values") and method == .POST) {
        return try handleLabelValues(alloc, eng, req);
    }
    if (std.mem.eql(u8, path, "/api/v1/metrics/health") and method == .POST) {
        return try handleMetricsHealth(alloc, eng, req);
    }
    if (std.mem.eql(u8, path, "/api/v1/query/compare") and method == .POST) {
        return try handleQueryCompare(alloc, eng, req);
    }
    if (std.mem.eql(u8, path, "/api/v1/annotations/write") and method == .POST) {
        return try handleAnnotationWrite(alloc, eng, req);
    }
    if (std.mem.eql(u8, path, "/api/v1/annotations/query") and method == .POST) {
        return try handleAnnotationQuery(alloc, eng, req);
    }
    if (std.mem.eql(u8, path, "/api/v1/sydraql") and method == .POST) {
        return try handleSydraql(alloc, eng, req);
    }

    if (std.mem.startsWith(u8, path, "/api/")) {
        try respondJsonError(alloc, req, .not_found, "not_found", "not found");
        return;
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

    var jw = std.json.Stringify{ .writer = &response.writer };
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
            try jw.write(null);
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
        return respondJsonError(alloc, req, .length_required, "length_required", "length required");
    };
    if (content_len > 256 * 1024) {
        return respondJsonError(alloc, req, .payload_too_large, "payload_too_large", "payload too large");
    }

    const len: usize = @intCast(content_len);
    const body_slice = try body_reader.*.take(len);
    const body = try alloc.dupe(u8, body_slice);
    defer alloc.free(body);

    const sydraql = std.mem.trim(u8, body, " \t\r\n");
    if (sydraql.len == 0) {
        return respondJsonError(alloc, req, .bad_request, "query_required", "query required");
    }
    query_common.validateQueryTextLimit(sydraql) catch {
        return respondJsonError(alloc, req, .payload_too_large, "query_too_large", query_common.query_text_too_large_message);
    };

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

    var jw = std.json.Stringify{ .writer = &response.writer };

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
    if (cursor.selectorStats()) |selector_stats| {
        cursor.stats.selector_mode = selector_stats.mode;
        cursor.stats.selected_series_count = selector_stats.selected_series_count;
    }
    const elapsed_us_signed = std.time.microTimestamp() - start_time;
    const elapsed_us = @as(u64, @intCast(elapsed_us_signed));
    try writeStatsObject(&jw, row_count, elapsed_us, &cursor.stats, op_stats, cursor.columns);
    try jw.endObject();
    try response.end();
}

const ExecutionErrorContract = struct {
    status: std.http.Status,
    code: []const u8,
    message: []const u8,
};

fn executionErrorContract(err: query_exec.ExecuteError) ExecutionErrorContract {
    if (compiler_diagnostics.fromCompileError(err)) |reason| {
        return switch (reason) {
            .series_not_found => .{
                .status = .not_found,
                .code = compiler_diagnostics.reasonName(reason),
                .message = compiler_diagnostics.diagnosticMessage(reason),
            },
            .ambiguous_selector => .{
                .status = .conflict,
                .code = compiler_diagnostics.reasonName(reason),
                .message = compiler_diagnostics.diagnosticMessage(reason),
            },
            .shadow_mismatch => .{
                .status = .service_unavailable,
                .code = compiler_diagnostics.reasonName(reason),
                .message = compiler_diagnostics.diagnosticMessage(reason),
            },
            else => .{
                .status = .bad_request,
                .code = compiler_diagnostics.reasonName(reason),
                .message = compiler_diagnostics.diagnosticMessage(reason),
            },
        };
    }

    return switch (err) {
        error.OutOfMemory => .{
            .status = .internal_server_error,
            .code = "out_of_memory",
            .message = "out of memory",
        },
        error.InvalidLiteral,
        error.UnterminatedString,
        error.UnexpectedToken,
        error.UnexpectedStatement,
        error.UnexpectedExpression,
        error.UnterminatedParenthesis,
        error.InvalidNumber,
        error.InvalidDuration,
        error.InvalidTimestamp,
        => .{
            .status = .bad_request,
            .code = "parse_failed",
            .message = @errorName(err),
        },
        error.ValidationFailed => .{
            .status = .bad_request,
            .code = "validation_failed",
            .message = "validation failed",
        },
        error.CasShadowMismatch => .{
            .status = .service_unavailable,
            .code = "shadow_mismatch",
            .message = @errorName(err),
        },
        else => .{
            .status = .bad_request,
            .code = "execution_error",
            .message = @errorName(err),
        },
    };
}

fn respondExecutionError(alloc: std.mem.Allocator, req: *std.http.Server.Request, err: query_exec.ExecuteError) !void {
    const contract = executionErrorContract(err);
    return respondJsonError(alloc, req, contract.status, contract.code, contract.message);
}

const StatusSnapshot = struct {
    cas_mode: []const u8,
    metadata_read_mode: []const u8,
    query_compiler_mode: []const u8,
    compatibility_debt: cas_mod.CompatibilityDebtReport,
    queue_depth: usize,
    memtable_bytes: usize,
    flush_total: u64,
    flush_points_total: u64,
    flush_seconds_total: f64,
    wal_append_total: u64,
    wal_append_seconds_total: f64,
    ingest_total: u64,
    ingest_rejected_total: u64,
    ingest_rejected_mem_limit_total: u64,
    wal_bytes_total: u64,
    wal_append_failed_total: u64,
    memtable_append_failed_total: u64,
    ingest_quarantined_total: u64,
    ingest_quarantine_write_failed_total: u64,
    cas_sync_total: u64,
    cas_sync_failed_total: u64,
    cas_sync_seconds_total: f64,
    query_compile_attempts_total: u64,
    query_compile_success_total: u64,
    query_compile_fallback_total: u64,
    query_compile_unsupported_total: u64,
    query_compile_series_not_found_total: u64,
    query_compile_ambiguous_selector_total: u64,
    query_compile_shadow_mismatch_total: u64,
    cas_shadow_mismatch_total: u64,
};

fn buildStatusSnapshot(eng: *Engine) StatusSnapshot {
    const compatibility_debt = eng.currentCompatibilityDebt() catch cas_mod.CompatibilityDebtReport{};
    return .{
        .cas_mode = @tagName(eng.config.cas_mode),
        .metadata_read_mode = @tagName(eng.config.metadata_read_mode),
        .query_compiler_mode = @tagName(eng.config.query_compiler_mode),
        .compatibility_debt = compatibility_debt,
        .queue_depth = eng.queue.len(),
        .memtable_bytes = eng.mem.bytes.load(.monotonic),
        .flush_total = eng.metrics.flush_total.load(.monotonic),
        .flush_points_total = eng.metrics.flush_points_total.load(.monotonic),
        .flush_seconds_total = @as(f64, @floatFromInt(eng.metrics.flush_ns_total.load(.monotonic))) / 1_000_000_000.0,
        .wal_append_total = eng.metrics.wal_append_total.load(.monotonic),
        .wal_append_seconds_total = @as(f64, @floatFromInt(eng.metrics.wal_append_ns_total.load(.monotonic))) / 1_000_000_000.0,
        .ingest_total = eng.metrics.ingest_total.load(.monotonic),
        .ingest_rejected_total = eng.metrics.ingest_rejected_total.load(.monotonic),
        .ingest_rejected_mem_limit_total = eng.metrics.ingest_rejected_mem_limit_total.load(.monotonic),
        .wal_bytes_total = eng.metrics.wal_bytes_total.load(.monotonic),
        .wal_append_failed_total = eng.metrics.wal_append_failed_total.load(.monotonic),
        .memtable_append_failed_total = eng.metrics.memtable_append_failed_total.load(.monotonic),
        .ingest_quarantined_total = eng.metrics.ingest_quarantined_total.load(.monotonic),
        .ingest_quarantine_write_failed_total = eng.metrics.ingest_quarantine_write_failed_total.load(.monotonic),
        .cas_sync_total = eng.metrics.cas_sync_total.load(.monotonic),
        .cas_sync_failed_total = eng.metrics.cas_sync_failed_total.load(.monotonic),
        .cas_sync_seconds_total = @as(f64, @floatFromInt(eng.metrics.cas_sync_ns_total.load(.monotonic))) / 1_000_000_000.0,
        .query_compile_attempts_total = eng.metrics.query_compile_attempts_total.load(.monotonic),
        .query_compile_success_total = eng.metrics.query_compile_success_total.load(.monotonic),
        .query_compile_fallback_total = eng.metrics.query_compile_fallback_total.load(.monotonic),
        .query_compile_unsupported_total = eng.metrics.query_compile_unsupported_total.load(.monotonic),
        .query_compile_series_not_found_total = eng.metrics.query_compile_series_not_found_total.load(.monotonic),
        .query_compile_ambiguous_selector_total = eng.metrics.query_compile_ambiguous_selector_total.load(.monotonic),
        .query_compile_shadow_mismatch_total = eng.metrics.query_compile_shadow_mismatch_total.load(.monotonic),
        .cas_shadow_mismatch_total = eng.metrics.cas_shadow_mismatch_total.load(.monotonic),
    };
}

fn buildJsonErrorPayload(
    alloc: std.mem.Allocator,
    status: std.http.Status,
    code: []const u8,
    message: []const u8,
) ![]u8 {
    var payload = std.array_list.Managed(u8).init(alloc);
    errdefer payload.deinit();
    var writer = payload.writer();
    var tmp: [128]u8 = undefined;
    var adapter = writer.adaptToNewApi(&tmp);
    var iface = &adapter.new_interface;
    var jw = std.json.Stringify{ .writer = iface };
    try jw.beginObject();
    try jw.objectField("error");
    try jw.write(message);
    try jw.objectField("code");
    try jw.write(code);
    try jw.objectField("status");
    try jw.write(@intFromEnum(status));
    try jw.endObject();
    try iface.flush();
    if (adapter.err) |write_err| return write_err;
    return try payload.toOwnedSlice();
}

fn writeStatusPayload(jw: *std.json.Stringify, snapshot: StatusSnapshot) !void {
    try jw.beginObject();
    try jw.objectField("status");
    try jw.write("ok");
    try jw.objectField("cas_mode");
    try jw.write(snapshot.cas_mode);
    try jw.objectField("metadata_read_mode");
    try jw.write(snapshot.metadata_read_mode);
    try jw.objectField("query_compiler_mode");
    try jw.write(snapshot.query_compiler_mode);
    try jw.objectField("compatibility_debt");
    try jw.beginObject();
    try jw.objectField("legacy_segment_descriptors");
    try jw.write(snapshot.compatibility_debt.legacy_segment_descriptors);
    try jw.objectField("legacy_wal_descriptors");
    try jw.write(snapshot.compatibility_debt.legacy_wal_descriptors);
    try jw.objectField("loose_refs_present");
    try jw.write(snapshot.compatibility_debt.loose_refs_present);
    try jw.endObject();

    try jw.objectField("runtime");
    try jw.beginObject();
    try jw.objectField("queue_depth");
    try jw.write(snapshot.queue_depth);
    try jw.objectField("memtable_bytes");
    try jw.write(snapshot.memtable_bytes);
    try jw.objectField("flush_total");
    try jw.write(snapshot.flush_total);
    try jw.objectField("flush_points_total");
    try jw.write(snapshot.flush_points_total);
    try jw.objectField("flush_seconds_total");
    try jw.write(snapshot.flush_seconds_total);
    try jw.objectField("wal_append_total");
    try jw.write(snapshot.wal_append_total);
    try jw.objectField("wal_append_seconds_total");
    try jw.write(snapshot.wal_append_seconds_total);
    try jw.objectField("ingest_total");
    try jw.write(snapshot.ingest_total);
    try jw.objectField("ingest_rejected_total");
    try jw.write(snapshot.ingest_rejected_total);
    try jw.objectField("ingest_rejected_mem_limit_total");
    try jw.write(snapshot.ingest_rejected_mem_limit_total);
    try jw.objectField("wal_bytes_total");
    try jw.write(snapshot.wal_bytes_total);
    try jw.objectField("wal_append_failed_total");
    try jw.write(snapshot.wal_append_failed_total);
    try jw.objectField("memtable_append_failed_total");
    try jw.write(snapshot.memtable_append_failed_total);
    try jw.objectField("ingest_quarantined_total");
    try jw.write(snapshot.ingest_quarantined_total);
    try jw.objectField("ingest_quarantine_write_failed_total");
    try jw.write(snapshot.ingest_quarantine_write_failed_total);
    try jw.objectField("cas_sync_total");
    try jw.write(snapshot.cas_sync_total);
    try jw.objectField("cas_sync_failed_total");
    try jw.write(snapshot.cas_sync_failed_total);
    try jw.objectField("cas_sync_seconds_total");
    try jw.write(snapshot.cas_sync_seconds_total);
    try jw.objectField("query_compile_attempts_total");
    try jw.write(snapshot.query_compile_attempts_total);
    try jw.objectField("query_compile_success_total");
    try jw.write(snapshot.query_compile_success_total);
    try jw.objectField("query_compile_fallback_total");
    try jw.write(snapshot.query_compile_fallback_total);
    try jw.objectField("query_compile_unsupported_total");
    try jw.write(snapshot.query_compile_unsupported_total);
    try jw.objectField("query_compile_series_not_found_total");
    try jw.write(snapshot.query_compile_series_not_found_total);
    try jw.objectField("query_compile_ambiguous_selector_total");
    try jw.write(snapshot.query_compile_ambiguous_selector_total);
    try jw.objectField("query_compile_shadow_mismatch_total");
    try jw.write(snapshot.query_compile_shadow_mismatch_total);
    try jw.objectField("cas_shadow_mismatch_total");
    try jw.write(snapshot.cas_shadow_mismatch_total);
    try jw.endObject();

    try jw.endObject();
}

fn buildStatusPayload(alloc: std.mem.Allocator, snapshot: StatusSnapshot) ![]u8 {
    var payload = std.array_list.Managed(u8).init(alloc);
    errdefer payload.deinit();
    var writer = payload.writer();
    var tmp: [256]u8 = undefined;
    var adapter = writer.adaptToNewApi(&tmp);
    var iface = &adapter.new_interface;
    var jw = std.json.Stringify{ .writer = iface };
    try writeStatusPayload(&jw, snapshot);
    try iface.flush();
    if (adapter.err) |write_err| return write_err;
    return try payload.toOwnedSlice();
}

fn respondJsonError(
    alloc: std.mem.Allocator,
    req: *std.http.Server.Request,
    status: std.http.Status,
    code: []const u8,
    message: []const u8,
) !void {
    const payload = try buildJsonErrorPayload(alloc, status, code, message);
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
    try jw.objectField("bind_ms");
    try jw.write(usToMs(stats.bind_us));
    try jw.objectField("compile_ms");
    try jw.write(usToMs(stats.compile_us));
    try jw.objectField("logical_ms");
    try jw.write(usToMs(stats.logical_us));
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
    try jw.objectField("execution_mode");
    try jw.write(stats.execution_mode);
    try jw.objectField("legacy_fallback");
    try jw.write(stats.legacy_fallback);
    if (stats.selector_mode.len != 0) {
        try jw.objectField("selector_mode");
        try jw.write(stats.selector_mode);
        try jw.objectField("selected_series_count");
        try jw.write(stats.selected_series_count);
    }
    if (stats.fallback_reason.len != 0) {
        try jw.objectField("fallback_reason");
        try jw.write(stats.fallback_reason);
    }
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
    var buffer = std.array_list.Managed(u8).init(alloc);
    defer buffer.deinit();
    var writer = buffer.writer();
    var tmp: [512]u8 = undefined;
    var adapter = writer.adaptToNewApi(&tmp);
    var jw = std.json.Stringify{ .writer = &adapter.new_interface };

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
    try adapter.new_interface.flush();
    if (adapter.err) |err| return err;

    const json = buffer.items;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"operators\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"rows_out\":5") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"scan\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"schema\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"nullable\":true") != null);
}

test "buildJsonErrorPayload emits structured contract" {
    const alloc = std.testing.allocator;
    const payload = try buildJsonErrorPayload(alloc, .service_unavailable, "ingest_backpressure", "ingest backpressure: memory limit exceeded");
    defer alloc.free(payload);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, payload, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("ingest backpressure: memory limit exceeded", obj.get("error").?.string);
    try std.testing.expectEqualStrings("ingest_backpressure", obj.get("code").?.string);
    try std.testing.expectEqual(@as(i64, 503), obj.get("status").?.integer);
}

test "executionErrorContract distinguishes parse validation and unsupported failures" {
    const parse_contract = executionErrorContract(error.UnexpectedToken);
    try std.testing.expectEqual(std.http.Status.bad_request, parse_contract.status);
    try std.testing.expectEqualStrings("parse_failed", parse_contract.code);
    try std.testing.expectEqualStrings("UnexpectedToken", parse_contract.message);

    const validation_contract = executionErrorContract(error.ValidationFailed);
    try std.testing.expectEqual(std.http.Status.bad_request, validation_contract.status);
    try std.testing.expectEqualStrings("validation_failed", validation_contract.code);

    const unsupported_contract = executionErrorContract(error.UnsupportedFunction);
    try std.testing.expectEqual(std.http.Status.bad_request, unsupported_contract.status);
    try std.testing.expectEqualStrings("unsupported_function", unsupported_contract.code);
    try std.testing.expectEqualStrings(compiler_diagnostics.diagnosticMessage(.unsupported_function), unsupported_contract.message);

    const missing_series_contract = executionErrorContract(error.SeriesNotFound);
    try std.testing.expectEqual(std.http.Status.not_found, missing_series_contract.status);
    try std.testing.expectEqualStrings("series_not_found", missing_series_contract.code);

    const ambiguous_contract = executionErrorContract(error.AmbiguousSelector);
    try std.testing.expectEqual(std.http.Status.conflict, ambiguous_contract.status);
    try std.testing.expectEqualStrings("ambiguous_selector", ambiguous_contract.code);

    const shadow_contract = executionErrorContract(error.ShadowMismatch);
    try std.testing.expectEqual(std.http.Status.service_unavailable, shadow_contract.status);
    try std.testing.expectEqualStrings("shadow_mismatch", shadow_contract.code);
}

test "sydraql query text limit uses stable error payload" {
    const alloc = std.testing.allocator;
    const payload = try buildJsonErrorPayload(alloc, .payload_too_large, "query_too_large", query_common.query_text_too_large_message);
    defer alloc.free(payload);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, payload, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("query_too_large", obj.get("code").?.string);
    try std.testing.expectEqualStrings(query_common.query_text_too_large_message, obj.get("error").?.string);
    try std.testing.expectEqual(@as(i64, 413), obj.get("status").?.integer);
}

test "buildStatusPayload emits extended runtime counters" {
    const alloc = std.testing.allocator;
    const payload = try buildStatusPayload(alloc, .{
        .cas_mode = "dual_write",
        .metadata_read_mode = "primary",
        .query_compiler_mode = "compiled",
        .compatibility_debt = .{
            .legacy_segment_descriptors = 2,
            .legacy_wal_descriptors = 1,
            .loose_refs_present = 3,
        },
        .queue_depth = 2,
        .memtable_bytes = 4096,
        .flush_total = 3,
        .flush_points_total = 17,
        .flush_seconds_total = 0.125,
        .wal_append_total = 11,
        .wal_append_seconds_total = 0.02,
        .ingest_total = 42,
        .ingest_rejected_total = 4,
        .ingest_rejected_mem_limit_total = 4,
        .wal_bytes_total = 2048,
        .wal_append_failed_total = 1,
        .memtable_append_failed_total = 2,
        .ingest_quarantined_total = 3,
        .ingest_quarantine_write_failed_total = 4,
        .cas_sync_total = 5,
        .cas_sync_failed_total = 1,
        .cas_sync_seconds_total = 0.25,
        .query_compile_attempts_total = 9,
        .query_compile_success_total = 6,
        .query_compile_fallback_total = 3,
        .query_compile_unsupported_total = 2,
        .query_compile_series_not_found_total = 1,
        .query_compile_ambiguous_selector_total = 1,
        .query_compile_shadow_mismatch_total = 1,
        .cas_shadow_mismatch_total = 5,
    });
    defer alloc.free(payload);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, payload, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    try std.testing.expectEqualStrings("ok", root.get("status").?.string);
    try std.testing.expectEqualStrings("dual_write", root.get("cas_mode").?.string);
    try std.testing.expectEqualStrings("primary", root.get("metadata_read_mode").?.string);
    try std.testing.expectEqualStrings("compiled", root.get("query_compiler_mode").?.string);
    const compatibility_debt = root.get("compatibility_debt").?.object;
    try std.testing.expectEqual(@as(i64, 2), compatibility_debt.get("legacy_segment_descriptors").?.integer);
    try std.testing.expectEqual(@as(i64, 1), compatibility_debt.get("legacy_wal_descriptors").?.integer);
    try std.testing.expectEqual(@as(i64, 3), compatibility_debt.get("loose_refs_present").?.integer);

    const runtime = root.get("runtime").?.object;
    try std.testing.expectEqual(@as(i64, 2), runtime.get("queue_depth").?.integer);
    try std.testing.expectEqual(@as(i64, 4096), runtime.get("memtable_bytes").?.integer);
    try std.testing.expectEqual(@as(i64, 17), runtime.get("flush_points_total").?.integer);
    try std.testing.expectApproxEqAbs(@as(f64, 0.125), runtime.get("flush_seconds_total").?.float, 0.0001);
    try std.testing.expectEqual(@as(i64, 11), runtime.get("wal_append_total").?.integer);
    try std.testing.expectApproxEqAbs(@as(f64, 0.02), runtime.get("wal_append_seconds_total").?.float, 0.0001);
    try std.testing.expectEqual(@as(i64, 2048), runtime.get("wal_bytes_total").?.integer);
    try std.testing.expectEqual(@as(i64, 1), runtime.get("wal_append_failed_total").?.integer);
    try std.testing.expectEqual(@as(i64, 2), runtime.get("memtable_append_failed_total").?.integer);
    try std.testing.expectEqual(@as(i64, 3), runtime.get("ingest_quarantined_total").?.integer);
    try std.testing.expectEqual(@as(i64, 4), runtime.get("ingest_quarantine_write_failed_total").?.integer);
    try std.testing.expectEqual(@as(i64, 5), runtime.get("cas_sync_total").?.integer);
    try std.testing.expectEqual(@as(i64, 1), runtime.get("cas_sync_failed_total").?.integer);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), runtime.get("cas_sync_seconds_total").?.float, 0.0001);
    try std.testing.expectEqual(@as(i64, 9), runtime.get("query_compile_attempts_total").?.integer);
    try std.testing.expectEqual(@as(i64, 1), runtime.get("query_compile_shadow_mismatch_total").?.integer);
    try std.testing.expectEqual(@as(i64, 5), runtime.get("cas_shadow_mismatch_total").?.integer);
}

fn handleMetrics(alloc: std.mem.Allocator, eng: *Engine, req: *std.http.Server.Request) !void {
    const compatibility_debt = eng.currentCompatibilityDebt() catch cas_mod.CompatibilityDebtReport{};
    const ingest_total = eng.metrics.ingest_total.load(.monotonic);
    const ingest_rejected_total = eng.metrics.ingest_rejected_total.load(.monotonic);
    const ingest_rejected_mem_limit_total = eng.metrics.ingest_rejected_mem_limit_total.load(.monotonic);
    const flush_total = eng.metrics.flush_total.load(.monotonic);
    const flush_ns_total = eng.metrics.flush_ns_total.load(.monotonic);
    const flush_points_total = eng.metrics.flush_points_total.load(.monotonic);
    const wal_append_total = eng.metrics.wal_append_total.load(.monotonic);
    const wal_append_seconds_total = @as(f64, @floatFromInt(eng.metrics.wal_append_ns_total.load(.monotonic))) / 1_000_000_000.0;
    const wal_bytes_total = eng.metrics.wal_bytes_total.load(.monotonic);
    const wal_append_failed_total = eng.metrics.wal_append_failed_total.load(.monotonic);
    const memtable_append_failed_total = eng.metrics.memtable_append_failed_total.load(.monotonic);
    const ingest_quarantined_total = eng.metrics.ingest_quarantined_total.load(.monotonic);
    const ingest_quarantine_write_failed_total = eng.metrics.ingest_quarantine_write_failed_total.load(.monotonic);
    const cas_sync_total = eng.metrics.cas_sync_total.load(.monotonic);
    const cas_sync_failed_total = eng.metrics.cas_sync_failed_total.load(.monotonic);
    const cas_sync_seconds_total = @as(f64, @floatFromInt(eng.metrics.cas_sync_ns_total.load(.monotonic))) / 1_000_000_000.0;
    const query_compile_attempts_total = eng.metrics.query_compile_attempts_total.load(.monotonic);
    const query_compile_success_total = eng.metrics.query_compile_success_total.load(.monotonic);
    const query_compile_fallback_total = eng.metrics.query_compile_fallback_total.load(.monotonic);
    const query_compile_unsupported_total = eng.metrics.query_compile_unsupported_total.load(.monotonic);
    const query_compile_series_not_found_total = eng.metrics.query_compile_series_not_found_total.load(.monotonic);
    const query_compile_ambiguous_selector_total = eng.metrics.query_compile_ambiguous_selector_total.load(.monotonic);
    const query_compile_shadow_mismatch_total = eng.metrics.query_compile_shadow_mismatch_total.load(.monotonic);
    const cas_shadow_mismatch_total = eng.metrics.cas_shadow_mismatch_total.load(.monotonic);
    const queue_depth = eng.queue.len();
    const memtable_bytes = eng.mem.bytes.load(.monotonic);
    const flush_seconds_total = @as(f64, @floatFromInt(flush_ns_total)) / 1_000_000_000.0;

    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();
    var writer = buf.writer();

    try writer.writeAll("# HELP sydradb_up 1 if server is up\n# TYPE sydradb_up gauge\nsydradb_up 1\n");
    try writer.print("# HELP sydradb_ingest_total Total ingested points since start\n# TYPE sydradb_ingest_total counter\nsydradb_ingest_total {d}\n", .{ingest_total});
    try writer.print("# HELP sydradb_ingest_rejected_total Total ingest requests rejected before queueing\n# TYPE sydradb_ingest_rejected_total counter\nsydradb_ingest_rejected_total {d}\n", .{ingest_rejected_total});
    try writer.print("# HELP sydradb_ingest_rejected_mem_limit_total Total ingest requests rejected due to mem_limit_bytes\n# TYPE sydradb_ingest_rejected_mem_limit_total counter\nsydradb_ingest_rejected_mem_limit_total {d}\n", .{ingest_rejected_mem_limit_total});
    try writer.print("# HELP sydradb_flush_total Total flush operations\n# TYPE sydradb_flush_total counter\nsydradb_flush_total {d}\n", .{flush_total});
    try writer.print("# HELP sydradb_flush_seconds_total Aggregate flush duration in seconds\n# TYPE sydradb_flush_seconds_total counter\nsydradb_flush_seconds_total {d:.6}\n", .{flush_seconds_total});
    try writer.print("# HELP sydradb_flush_points_total Total points flushed to disk\n# TYPE sydradb_flush_points_total counter\nsydradb_flush_points_total {d}\n", .{flush_points_total});
    try writer.print("# HELP sydradb_wal_append_total Total WAL append operations performed by the writer loop\n# TYPE sydradb_wal_append_total counter\nsydradb_wal_append_total {d}\n", .{wal_append_total});
    try writer.print("# HELP sydradb_wal_append_seconds_total Aggregate WAL append duration in seconds\n# TYPE sydradb_wal_append_seconds_total counter\nsydradb_wal_append_seconds_total {d:.6}\n", .{wal_append_seconds_total});
    try writer.print("# HELP sydradb_wal_bytes_total Total bytes written to WAL\n# TYPE sydradb_wal_bytes_total counter\nsydradb_wal_bytes_total {d}\n", .{wal_bytes_total});
    try writer.print("# HELP sydradb_wal_append_failed_total Total WAL append failures observed by the writer loop\n# TYPE sydradb_wal_append_failed_total counter\nsydradb_wal_append_failed_total {d}\n", .{wal_append_failed_total});
    try writer.print("# HELP sydradb_memtable_append_failed_total Total memtable append failures observed by the writer loop\n# TYPE sydradb_memtable_append_failed_total counter\nsydradb_memtable_append_failed_total {d}\n", .{memtable_append_failed_total});
    try writer.print("# HELP sydradb_ingest_quarantined_total Total ingest records written to quarantine after writer-loop failures\n# TYPE sydradb_ingest_quarantined_total counter\nsydradb_ingest_quarantined_total {d}\n", .{ingest_quarantined_total});
    try writer.print("# HELP sydradb_ingest_quarantine_write_failed_total Total failures while writing ingest quarantine records\n# TYPE sydradb_ingest_quarantine_write_failed_total counter\nsydradb_ingest_quarantine_write_failed_total {d}\n", .{ingest_quarantine_write_failed_total});
    try writer.print("# HELP sydradb_cas_sync_total Total CAS snapshot sync operations completed by the engine\n# TYPE sydradb_cas_sync_total counter\nsydradb_cas_sync_total {d}\n", .{cas_sync_total});
    try writer.print("# HELP sydradb_cas_sync_failed_total Total CAS snapshot sync operations that failed\n# TYPE sydradb_cas_sync_failed_total counter\nsydradb_cas_sync_failed_total {d}\n", .{cas_sync_failed_total});
    try writer.print("# HELP sydradb_cas_sync_seconds_total Aggregate CAS snapshot sync duration in seconds\n# TYPE sydradb_cas_sync_seconds_total counter\nsydradb_cas_sync_seconds_total {d:.6}\n", .{cas_sync_seconds_total});
    try writer.print("# HELP sydradb_compatibility_debt_legacy_segment_descriptors Current legacy segment descriptors still referenced by CAS metadata\n# TYPE sydradb_compatibility_debt_legacy_segment_descriptors gauge\nsydradb_compatibility_debt_legacy_segment_descriptors {d}\n", .{compatibility_debt.legacy_segment_descriptors});
    try writer.print("# HELP sydradb_compatibility_debt_legacy_wal_descriptors Current legacy WAL descriptors still referenced by CAS metadata\n# TYPE sydradb_compatibility_debt_legacy_wal_descriptors gauge\nsydradb_compatibility_debt_legacy_wal_descriptors {d}\n", .{compatibility_debt.legacy_wal_descriptors});
    try writer.print("# HELP sydradb_compatibility_debt_loose_refs_present Current loose refs still present alongside reftable metadata\n# TYPE sydradb_compatibility_debt_loose_refs_present gauge\nsydradb_compatibility_debt_loose_refs_present {d}\n", .{compatibility_debt.loose_refs_present});
    try writer.print("# HELP sydradb_query_compile_attempts_total Total compiled query attempts\n# TYPE sydradb_query_compile_attempts_total counter\nsydradb_query_compile_attempts_total {d}\n", .{query_compile_attempts_total});
    try writer.print("# HELP sydradb_query_compile_success_total Total compiled query lowerings that succeeded\n# TYPE sydradb_query_compile_success_total counter\nsydradb_query_compile_success_total {d}\n", .{query_compile_success_total});
    try writer.print("# HELP sydradb_query_compile_fallback_total Total query compiler fallbacks\n# TYPE sydradb_query_compile_fallback_total counter\nsydradb_query_compile_fallback_total {d}\n", .{query_compile_fallback_total});
    try writer.print("# HELP sydradb_query_compile_unsupported_total Total query compiler fallbacks caused by unsupported shapes\n# TYPE sydradb_query_compile_unsupported_total counter\nsydradb_query_compile_unsupported_total {d}\n", .{query_compile_unsupported_total});
    try writer.print("# HELP sydradb_query_compile_series_not_found_total Total query compiler fallbacks caused by unresolved selectors\n# TYPE sydradb_query_compile_series_not_found_total counter\nsydradb_query_compile_series_not_found_total {d}\n", .{query_compile_series_not_found_total});
    try writer.print("# HELP sydradb_query_compile_ambiguous_selector_total Total query compiler fallbacks caused by ambiguous selectors\n# TYPE sydradb_query_compile_ambiguous_selector_total counter\nsydradb_query_compile_ambiguous_selector_total {d}\n", .{query_compile_ambiguous_selector_total});
    try writer.print("# HELP sydradb_query_compile_shadow_mismatch_total Total query compiler fallbacks caused by shadow mismatches\n# TYPE sydradb_query_compile_shadow_mismatch_total counter\nsydradb_query_compile_shadow_mismatch_total {d}\n", .{query_compile_shadow_mismatch_total});
    try writer.print("# HELP sydradb_cas_shadow_mismatch_total Total CAS shadow mismatches observed in runtime verification paths\n# TYPE sydradb_cas_shadow_mismatch_total counter\nsydradb_cas_shadow_mismatch_total {d}\n", .{cas_shadow_mismatch_total});
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

fn handleStatus(alloc: std.mem.Allocator, eng: *Engine, req: *std.http.Server.Request) !void {
    const payload = try buildStatusPayload(alloc, buildStatusSnapshot(eng));
    defer alloc.free(payload);
    const headers = [_]std.http.Header{.{ .name = "Content-Type", .value = "application/json" }};
    try req.respond(payload, .{ .extra_headers = &headers });
}

const default_tags_json = "{}";

const ParsedIngestMetric = struct {
    series: []u8,
    value: f64,
    descriptor: ?metric_catalog_mod.Descriptor = null,

    fn deinit(self: *ParsedIngestMetric, alloc: std.mem.Allocator) void {
        alloc.free(self.series);
        if (self.descriptor) |*descriptor| descriptor.deinit(alloc);
        self.* = undefined;
    }
};

pub const ParsedIngestLine = struct {
    ts: i64,
    tags_json: []u8,
    writes: []ParsedIngestMetric,

    pub fn deinit(self: ParsedIngestLine, alloc: std.mem.Allocator) void {
        alloc.free(self.tags_json);
        for (self.writes) |*write| write.deinit(alloc);
        alloc.free(self.writes);
    }
};

const TagsJson = struct {
    value: []const u8,
    owned: ?[]u8 = null,
};

pub fn parseIngestLine(alloc: std.mem.Allocator, raw_line: []const u8) !ParsedIngestLine {
    const trimmed = std.mem.trim(u8, raw_line, " \t\r\n");
    if (trimmed.len == 0) return error.EmptyLine;

    const line = try alloc.dupe(u8, trimmed);
    defer alloc.free(line);

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, line, .{}) catch return error.InvalidRecord;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidRecord;

    const obj = parsed.value.object;
    const ts_value = obj.get("ts") orelse return error.MissingTimestamp;
    if (ts_value != .integer) return error.InvalidTimestamp;

    if (obj.get("metric")) |metric_value| {
        if (metric_value != .string) return error.InvalidMetric;
        const labels = try extractTagsJson(alloc, obj.get("labels"));
        errdefer if (labels.owned) |owned| alloc.free(owned);

        var writes = std.array_list.Managed(ParsedIngestMetric).init(alloc);
        errdefer {
            for (writes.items) |*write| write.deinit(alloc);
            writes.deinit();
        }

        const kind = try parseMetricKind(obj.get("kind"));
        const unit = try dupOptionalJsonString(alloc, obj.get("unit"));
        defer if (unit) |value| alloc.free(value);
        const description = try dupOptionalJsonString(alloc, obj.get("description"));
        defer if (description) |value| alloc.free(value);

        if (obj.get("value")) |value_node| {
            try writes.append(try buildParsedIngestMetric(
                alloc,
                metric_value.string,
                try numericValue(value_node),
                .{
                    .metric = metric_value.string,
                    .kind = kind,
                    .unit = unit,
                    .description = description,
                },
            ));
        }

        if (obj.get("fields")) |fields_value| {
            if (fields_value != .object) return error.InvalidTelemetryFields;
            var it = fields_value.object.iterator();
            while (it.next()) |entry| {
                const field_value = switch (entry.value_ptr.*) {
                    .float => entry.value_ptr.float,
                    .integer => @as(f64, @floatFromInt(entry.value_ptr.integer)),
                    else => return error.TelemetryFieldsMustBeNumeric,
                };
                const derived_metric = try std.fmt.allocPrint(alloc, "{s}.{s}", .{ metric_value.string, entry.key_ptr.* });
                defer alloc.free(derived_metric);
                try writes.append(try buildParsedIngestMetric(
                    alloc,
                    derived_metric,
                    field_value,
                    .{
                        .metric = derived_metric,
                        .kind = kind,
                        .unit = unit,
                        .description = description,
                        .source_metric = metric_value.string,
                        .source_field = entry.key_ptr.*,
                    },
                ));
            }
        }

        if (writes.items.len == 0) return error.MissingMetricValue;

        return .{
            .ts = @intCast(ts_value.integer),
            .tags_json = if (labels.owned) |owned| owned else try alloc.dupe(u8, default_tags_json),
            .writes = try writes.toOwnedSlice(),
        };
    }

    const series_value = obj.get("series") orelse return error.MissingSeries;
    if (series_value != .string) return error.InvalidSeries;

    const tags = try extractTagsJson(alloc, obj.get("tags"));
    var writes = std.array_list.Managed(ParsedIngestMetric).init(alloc);
    errdefer {
        for (writes.items) |*write| write.deinit(alloc);
        writes.deinit();
    }
    try writes.append(.{
        .series = try alloc.dupe(u8, series_value.string),
        .value = firstNumericValue(obj),
        .descriptor = null,
    });
    return .{
        .ts = @intCast(ts_value.integer),
        .tags_json = if (tags.owned) |owned| owned else try alloc.dupe(u8, default_tags_json),
        .writes = try writes.toOwnedSlice(),
    };
}

pub fn applyIngestLine(eng: *Engine, parsed: ParsedIngestLine) !types.SeriesId {
    var first_sid: ?types.SeriesId = null;
    for (parsed.writes) |write| {
        if (write.descriptor) |descriptor| {
            _ = try eng.registerMetricDescriptor(.{
                .metric = descriptor.metric,
                .kind = descriptor.kind,
                .unit = descriptor.unit,
                .description = descriptor.description,
                .source_metric = descriptor.source_metric,
                .source_field = descriptor.source_field,
            });
        }

        const sid = types.seriesIdFrom(write.series, parsed.tags_json);
        try eng.registerSeries(write.series, parsed.tags_json, sid);
        try eng.ingest(.{
            .series_id = sid,
            .ts = parsed.ts,
            .value = write.value,
            .tags_json = parsed.tags_json,
        });
        eng.noteTags(sid, parsed.tags_json);
        if (first_sid == null) first_sid = sid;
    }
    return first_sid orelse 0;
}

fn buildParsedIngestMetric(
    alloc: std.mem.Allocator,
    metric: []const u8,
    value: f64,
    descriptor_input: metric_catalog_mod.DescriptorInput,
) !ParsedIngestMetric {
    return .{
        .series = try alloc.dupe(u8, metric),
        .value = value,
        .descriptor = .{
            .metric = try alloc.dupe(u8, descriptor_input.metric),
            .kind = descriptor_input.kind,
            .unit = try dupOptionalBytes(alloc, descriptor_input.unit),
            .description = try dupOptionalBytes(alloc, descriptor_input.description),
            .source_metric = try dupOptionalBytes(alloc, descriptor_input.source_metric),
            .source_field = try dupOptionalBytes(alloc, descriptor_input.source_field),
        },
    };
}

fn parseMetricKind(maybe_value: ?std.json.Value) !?metric_catalog_mod.MetricKind {
    if (maybe_value) |value| {
        if (value != .string) return error.InvalidMetricKind;
        return metric_catalog_mod.MetricKind.parse(value.string) orelse return error.InvalidMetricKind;
    }
    return null;
}

fn dupOptionalJsonString(alloc: std.mem.Allocator, maybe_value: ?std.json.Value) !?[]const u8 {
    if (maybe_value) |value| {
        if (value != .string) return error.InvalidMetricMetadata;
        if (value.string.len == 0) return null;
        return try alloc.dupe(u8, value.string);
    }
    return null;
}

fn dupOptionalBytes(alloc: std.mem.Allocator, maybe_value: ?[]const u8) !?[]const u8 {
    if (maybe_value) |value| return try alloc.dupe(u8, value);
    return null;
}

fn numericValue(value: std.json.Value) !f64 {
    return switch (value) {
        .float => value.float,
        .integer => @floatFromInt(value.integer),
        else => error.InvalidMetricValue,
    };
}

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

fn firstNumericValue(obj: std.json.ObjectMap) f64 {
    if (obj.get("value")) |value| {
        return switch (value) {
            .float => value.float,
            .integer => @floatFromInt(value.integer),
            else => 0,
        };
    }

    if (obj.get("fields")) |fields_value| {
        if (fields_value == .object) {
            var it = fields_value.object.iterator();
            while (it.next()) |entry| {
                switch (entry.value_ptr.*) {
                    .float => return entry.value_ptr.float,
                    .integer => return @floatFromInt(entry.value_ptr.integer),
                    else => {},
                }
            }
        }
    }

    return 0;
}

fn collectMatchingSeriesIds(
    alloc: std.mem.Allocator,
    eng: *Engine,
    tags_value: std.json.Value,
    op_and: bool,
) !std.array_list.Managed(types.SeriesId) {
    return try eng.collectMatchingSeriesIds(alloc, tags_value, op_and);
}

fn handleIngest(alloc: std.mem.Allocator, eng: *Engine, req: *std.http.Server.Request) !void {
    var body_buf: [4096]u8 = undefined;
    const body_reader = req.readerExpectNone(&body_buf);
    var count: usize = 0;

    while (true) {
        const slice = body_reader.*.takeDelimiterExclusive('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                _ = respondJsonError(alloc, req, .payload_too_large, "line_too_long", "line too long") catch {};
                return;
            },
            error.EndOfStream => break,
            else => return err,
        };
        const parsed = parseIngestLine(alloc, slice) catch |err| switch (err) {
            error.EmptyLine,
            error.InvalidRecord,
            error.MissingSeries,
            error.MissingTimestamp,
            error.InvalidSeries,
            error.InvalidTimestamp,
            => continue,
            error.InvalidMetric,
            error.InvalidMetricKind,
            error.InvalidMetricMetadata,
            error.InvalidMetricValue,
            error.InvalidTelemetryFields,
            error.TelemetryFieldsMustBeNumeric,
            error.MissingMetricValue,
            => {
                _ = respondJsonError(alloc, req, .bad_request, "invalid_telemetry_record", @errorName(err)) catch {};
                return;
            },
            else => return err,
        };
        defer parsed.deinit(alloc);

        _ = applyIngestLine(eng, parsed) catch |err| switch (err) {
            error.MemoryLimitExceeded => {
                return respondJsonError(alloc, req, .service_unavailable, "ingest_backpressure", "ingest backpressure: memory limit exceeded");
            },
            error.MetricDescriptorConflict => {
                return respondJsonError(alloc, req, .conflict, "metric_descriptor_conflict", "metric descriptor conflict");
            },
            else => return err,
        };
        count += 1;
    }

    var buf: [64]u8 = undefined;
    const body = try std.fmt.bufPrint(&buf, "{{\"ingested\":{d}}}", .{count});
    const headers = [_]std.http.Header{.{ .name = "Content-Type", .value = "application/json" }};
    try req.respond(body, .{ .extra_headers = &headers });
}

test "parseIngestLine mirrors HTTP numeric and tags behavior" {
    const alloc = std.testing.allocator;
    const parsed = try parseIngestLine(alloc, "{\"series\":\"weather.room1\",\"ts\":10,\"fields\":{\"reading\":24,\"ignored\":\"x\"},\"tags\":{\"rack\":\"r1\",\"host\":\"web\"}}");
    defer parsed.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), parsed.writes.len);
    try std.testing.expectEqualStrings("weather.room1", parsed.writes[0].series);
    try std.testing.expectEqual(@as(i64, 10), parsed.ts);
    try std.testing.expectApproxEqAbs(@as(f64, 24), parsed.writes[0].value, 1e-9);
    try std.testing.expectEqualStrings("{\"rack\":\"r1\",\"host\":\"web\"}", parsed.tags_json);
}

test "parseIngestLine accepts explicit integer values" {
    const alloc = std.testing.allocator;
    const parsed = try parseIngestLine(alloc, "{\"series\":\"weather.room1\",\"ts\":20,\"value\":3}");
    defer parsed.deinit(alloc);

    try std.testing.expectEqual(@as(i64, 20), parsed.ts);
    try std.testing.expectEqual(@as(usize, 1), parsed.writes.len);
    try std.testing.expectApproxEqAbs(@as(f64, 3), parsed.writes[0].value, 1e-9);
    try std.testing.expectEqualStrings("{}", parsed.tags_json);
}

test "parseIngestLine fans out telemetry fields into sibling metrics" {
    const alloc = std.testing.allocator;
    const parsed = try parseIngestLine(alloc, "{\"metric\":\"system.cpu\",\"ts\":30,\"value\":0.5,\"fields\":{\"user\":0.3,\"system\":0.2},\"labels\":{\"host\":\"web-1\"},\"kind\":\"gauge\",\"unit\":\"ratio\"}");
    defer parsed.deinit(alloc);

    try std.testing.expectEqual(@as(i64, 30), parsed.ts);
    try std.testing.expectEqual(@as(usize, 3), parsed.writes.len);
    try std.testing.expectEqualStrings("system.cpu", parsed.writes[0].series);
    try std.testing.expectEqualStrings("system.cpu.user", parsed.writes[1].series);
    try std.testing.expectEqualStrings("system.cpu.system", parsed.writes[2].series);
    try std.testing.expectEqualStrings("{\"host\":\"web-1\"}", parsed.tags_json);
}

fn handleQuery(alloc: std.mem.Allocator, eng: *Engine, req: *std.http.Server.Request) !void {
    var body_buf: [1024]u8 = undefined;
    const body_reader = req.readerExpectNone(&body_buf);
    const content_len = req.head.content_length orelse {
        return respondJsonError(alloc, req, .length_required, "length_required", "length required");
    };
    if (content_len > 1024 * 64) {
        return respondJsonError(alloc, req, .payload_too_large, "payload_too_large", "payload too large");
    }
    const alloc_len: usize = @intCast(content_len);
    const body_slice = try body_reader.*.take(alloc_len);
    const body = try alloc.dupe(u8, body_slice);
    defer alloc.free(body);

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch {
        return respondJsonError(alloc, req, .bad_request, "invalid_json", "invalid json");
    };
    defer parsed.deinit();
    const obj = parsed.value.object;
    const tags_value = obj.get("tags");
    const labels_value = obj.get("labels");
    var op_and = true;
    if (obj.get("op")) |v| {
        if (v == .string and std.ascii.eqlIgnoreCase(v.string, "or")) op_and = false;
    }
    var series_id: ?types.SeriesId = null;
    if (obj.get("series_id")) |v| {
        series_id = @intCast(v.integer);
    } else if (obj.get("metric")) |v| {
        if (v != .string) return respondJsonError(alloc, req, .bad_request, "invalid_metric", "invalid metric");
        if (labels_value) |labels| {
            const labels_json = try extractTagsJson(alloc, labels);
            defer if (labels_json.owned) |buf| alloc.free(buf);
            series_id = try resolveExactSeriesId(eng, v.string, labels_json.value);
        } else {
            series_id = try resolveUniqueSeriesId(eng, v.string);
        }
    } else if (obj.get("series")) |v| {
        if (v != .string) return respondJsonError(alloc, req, .bad_request, "invalid_series", "invalid series");
        if (tags_value) |tags_json| {
            const tags = try extractTagsJson(alloc, tags_json);
            defer if (tags.owned) |buf| alloc.free(buf);
            series_id = try resolveExactSeriesId(eng, v.string, tags.value);
        } else {
            series_id = try resolveUniqueSeriesId(eng, v.string);
        }
    }
    const start_val = obj.get("start") orelse {
        return respondJsonError(alloc, req, .bad_request, "missing_start", "missing start");
    };
    const end_val = obj.get("end") orelse {
        return respondJsonError(alloc, req, .bad_request, "missing_end", "missing end");
    };
    const start_ts: i64 = @intCast(start_val.integer);
    const end_ts: i64 = @intCast(end_val.integer);
    const sid = series_id orelse {
        if (labels_value) |label_selector| {
            return queryByTagsAndRespond(alloc, eng, req, label_selector, op_and, start_ts, end_ts);
        }
        if (tags_value) |tag_selector| {
            return queryByTagsAndRespond(alloc, eng, req, tag_selector, op_and, start_ts, end_ts);
        }
        return respondJsonError(alloc, req, .bad_request, "missing_series_identifier", "missing series identifier");
    };
    if (sid == null_series_id) return respondPoints(req, &.{});
    try queryAndRespond(alloc, eng, req, sid, start_ts, end_ts);
}

fn handleQueryGet(alloc: std.mem.Allocator, eng: *Engine, req: *std.http.Server.Request, query: []const u8) !void {
    if (query.len == 0) {
        return respondJsonError(alloc, req, .bad_request, "missing_query_parameters", "missing query parameters");
    }
    var metric_opt: ?[]const u8 = null;
    var series_opt: ?[]const u8 = null;
    var series_id_opt: ?types.SeriesId = null;
    var labels_opt: ?[]const u8 = null;
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
                return respondJsonError(alloc, req, .bad_request, "invalid_series_id", "invalid series_id");
            };
        } else if (std.mem.eql(u8, key, "metric")) {
            metric_opt = value;
        } else if (std.mem.eql(u8, key, "series")) {
            series_opt = value;
        } else if (std.mem.eql(u8, key, "labels")) {
            labels_opt = value;
        } else if (std.mem.eql(u8, key, "tags")) {
            tags_opt = value;
        } else if (std.mem.eql(u8, key, "start")) {
            start_opt = std.fmt.parseInt(i64, value, 10) catch null;
        } else if (std.mem.eql(u8, key, "end")) {
            end_opt = std.fmt.parseInt(i64, value, 10) catch null;
        }
    }
    const sid = series_id_opt orelse
        (if (metric_opt) |name|
            (if (labels_opt) |labels|
                try resolveExactSeriesId(eng, name, labels)
            else
                try resolveUniqueSeriesId(eng, name))
        else if (series_opt) |name|
            (if (tags_opt) |tags|
                try resolveExactSeriesId(eng, name, tags)
            else
                try resolveUniqueSeriesId(eng, name))
        else
            null) orelse {
        return respondJsonError(alloc, req, .bad_request, "missing_series", "missing series or series_id");
    };
    const start_ts = start_opt orelse {
        return respondJsonError(alloc, req, .bad_request, "missing_start", "missing start");
    };
    const end_ts = end_opt orelse {
        return respondJsonError(alloc, req, .bad_request, "missing_end", "missing end");
    };
    if (sid == null_series_id) return respondPoints(req, &.{});
    try queryAndRespond(alloc, eng, req, sid, start_ts, end_ts);
}

const null_series_id = std.math.maxInt(types.SeriesId);

fn resolveUniqueSeriesId(eng: *Engine, name: []const u8) !?types.SeriesId {
    const resolution = try eng.resolveSelector(.{ .name = name });
    return switch (resolution.status) {
        .resolved, .exact_match => resolution.series_id.?,
        .not_found, .ambiguous => null,
    };
}

fn resolveExactSeriesId(eng: *Engine, name: []const u8, labels_json: []const u8) !?types.SeriesId {
    const resolution = try eng.resolveSelector(.{ .exact = .{ .series = name, .tags_json = labels_json } });
    return switch (resolution.status) {
        .resolved, .exact_match => resolution.series_id.?,
        .not_found, .ambiguous => null_series_id,
    };
}

fn queryAndRespond(alloc: std.mem.Allocator, eng: *Engine, req: *std.http.Server.Request, sid: types.SeriesId, start_ts: i64, end_ts: i64) !void {
    var points = try std.array_list.Managed(types.Point).initCapacity(alloc, 0);
    defer points.deinit();
    try eng.queryRange(sid, start_ts, end_ts, &points);
    try respondPoints(req, points.items);
}

fn queryByTagsAndRespond(
    alloc: std.mem.Allocator,
    eng: *Engine,
    req: *std.http.Server.Request,
    tags_value: std.json.Value,
    op_and: bool,
    start_ts: i64,
    end_ts: i64,
) !void {
    var series_ids = try collectMatchingSeriesIds(alloc, eng, tags_value, op_and);
    defer series_ids.deinit();

    var send_buffer: [1024]u8 = undefined;
    var response = try req.respondStreaming(&send_buffer, .{
        .respond_options = .{
            .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        },
    });
    errdefer response.end() catch {};

    const resp_writer = &response.writer;
    try resp_writer.writeAll("{\"series\":[");
    var first_series = true;
    for (series_ids.items) |sid| {
        var points = std.array_list.Managed(types.Point).init(alloc);
        defer points.deinit();
        try eng.queryRange(sid, start_ts, end_ts, &points);

        if (!first_series) try resp_writer.writeAll(",");
        first_series = false;
        try resp_writer.print("{{\"series_id\":{d},\"points\":[", .{sid});
        var first_point = true;
        for (points.items) |pnt| {
            if (!first_point) try resp_writer.writeAll(",");
            first_point = false;
            try resp_writer.print("{{\"ts\":{d},\"value\":{d}}}", .{ pnt.ts, pnt.value });
        }
        try resp_writer.writeAll("]}");
    }
    try resp_writer.writeAll("]}");
    try response.end();
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
        return respondJsonError(alloc, req, .length_required, "length_required", "length required");
    };
    if (content_len > 64 * 1024) {
        return respondJsonError(alloc, req, .payload_too_large, "payload_too_large", "payload too large");
    }
    const alloc_len: usize = @intCast(content_len);
    const body_slice = try body_reader.*.take(alloc_len);
    const body = try alloc.dupe(u8, body_slice);
    defer alloc.free(body);

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch {
        return respondJsonError(alloc, req, .bad_request, "invalid_json", "invalid json");
    };
    defer parsed.deinit();
    const obj = parsed.value.object;
    var op_and = true;
    if (obj.get("op")) |v| {
        if (v == .string and std.ascii.eqlIgnoreCase(v.string, "or")) op_and = false;
    }
    var result = if (obj.get("tags")) |t|
        try collectMatchingSeriesIds(alloc, eng, t, op_and)
    else
        std.array_list.Managed(types.SeriesId).init(alloc);
    defer result.deinit();

    var send_buffer: [512]u8 = undefined;
    var response = try req.respondStreaming(&send_buffer, .{
        .respond_options = .{
            .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        },
    });
    errdefer response.end() catch {};

    const resp_writer = &response.writer;
    try resp_writer.writeAll("[");
    var first2 = true;
    for (result.items) |sid| {
        if (!first2) try resp_writer.writeAll(",");
        first2 = false;
        try resp_writer.print("{d}", .{sid});
    }
    try resp_writer.writeAll("]");
    try response.end();
}

fn handleMetricsFind(alloc: std.mem.Allocator, eng: *Engine, req: *std.http.Server.Request) !void {
    var parsed = readJsonBody(alloc, req, 64 * 1024) catch |err| switch (err) {
        error.LengthRequired => return respondJsonError(alloc, req, .length_required, "length_required", "length required"),
        error.PayloadTooLarge => return respondJsonError(alloc, req, .payload_too_large, "payload_too_large", "payload too large"),
        else => return respondJsonError(alloc, req, .bad_request, "invalid_json", "invalid json"),
    };
    defer parsed.deinit(alloc);
    const obj = parsed.parsed.value.object;

    const prefix = if (obj.get("prefix")) |value|
        if (value == .string) value.string else return respondJsonError(alloc, req, .bad_request, "invalid_prefix", "invalid prefix")
    else
        "";
    const labels_value = obj.get("labels");
    const limit = if (obj.get("limit")) |value|
        if (value == .integer and value.integer >= 0) @as(usize, @intCast(value.integer)) else return respondJsonError(alloc, req, .bad_request, "invalid_limit", "invalid limit")
    else
        null;

    var unique = std.StringHashMap(void).init(alloc);
    defer {
        var it = unique.iterator();
        while (it.next()) |entry| alloc.free(entry.key_ptr.*);
        unique.deinit();
    }
    var metrics = std.array_list.Managed([]const u8).init(alloc);
    defer {
        for (metrics.items) |metric| alloc.free(metric);
        metrics.deinit();
    }

    self_collect_metrics: {
        eng.metadata.series_catalog.mutex.lock();
        defer eng.metadata.series_catalog.mutex.unlock();
        for (eng.metadata.series_catalog.entries.items) |entry| {
            if (prefix.len != 0 and !std.mem.startsWith(u8, entry.series, prefix)) continue;
            if (unique.contains(entry.series)) continue;
            if (labels_value) |labels| {
                const descriptor_matches = descriptorMatchesLabels(entry.canonical_tags, labels, true) catch false;
                if (!descriptor_matches) continue;
            }
            const owned_metric = try alloc.dupe(u8, entry.series);
            errdefer alloc.free(owned_metric);
            try unique.put(owned_metric, {});
            try metrics.append(owned_metric);
            if (limit) |bounded| {
                if (metrics.items.len >= bounded) break :self_collect_metrics;
            }
        }
    }

    std.sort.block([]const u8, metrics.items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lessThan);

    var send_buffer: [1024]u8 = undefined;
    var response = try req.respondStreaming(&send_buffer, .{
        .respond_options = .{
            .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        },
    });
    errdefer response.end() catch {};

    var jw = std.json.Stringify{ .writer = &response.writer };
    try jw.beginArray();
    for (metrics.items) |metric| {
        const series = try eng.seriesDescriptorsForMetric(alloc, metric, labels_value, true, null);
        defer alloc.free(series);
        const descriptor = eng.metricDescriptor(metric);
        const label_keys = try collectLabelKeysForSeries(alloc, series);
        defer freeOwnedStrings(alloc, label_keys);
        const bounds = combineSeriesBounds(series);

        try jw.beginObject();
        try jw.objectField("metric");
        try jw.write(metric);
        try jw.objectField("kind");
        try jw.write(if (descriptor) |desc|
            if (desc.kind) |kind| kind.text() else metric_catalog_mod.MetricKind.gauge.text()
        else
            metric_catalog_mod.MetricKind.gauge.text());
        if (descriptor) |desc| {
            if (desc.unit) |unit| {
                try jw.objectField("unit");
                try jw.write(unit);
            }
            if (desc.description) |description| {
                try jw.objectField("description");
                try jw.write(description);
            }
        }
        try jw.objectField("series_count");
        try jw.write(series.len);
        try jw.objectField("label_keys");
        try jw.beginArray();
        for (label_keys) |key| try jw.write(key);
        try jw.endArray();
        try jw.objectField("first_ts");
        if (bounds.first_ts) |first_ts| try jw.write(first_ts) else try jw.write(null);
        try jw.objectField("last_ts");
        if (bounds.last_ts) |last_ts| try jw.write(last_ts) else try jw.write(null);
        try jw.endObject();
    }
    try jw.endArray();
    try response.end();
}

fn handleSeriesFind(alloc: std.mem.Allocator, eng: *Engine, req: *std.http.Server.Request) !void {
    var parsed = readJsonBody(alloc, req, 64 * 1024) catch |err| switch (err) {
        error.LengthRequired => return respondJsonError(alloc, req, .length_required, "length_required", "length required"),
        error.PayloadTooLarge => return respondJsonError(alloc, req, .payload_too_large, "payload_too_large", "payload too large"),
        else => return respondJsonError(alloc, req, .bad_request, "invalid_json", "invalid json"),
    };
    defer parsed.deinit(alloc);
    const obj = parsed.parsed.value.object;

    const metric_value = obj.get("metric") orelse {
        return respondJsonError(alloc, req, .bad_request, "missing_metric", "missing metric");
    };
    if (metric_value != .string) {
        return respondJsonError(alloc, req, .bad_request, "invalid_metric", "invalid metric");
    }
    const labels_value = obj.get("labels");
    var op_and = true;
    if (obj.get("op")) |value| {
        if (value == .string and std.ascii.eqlIgnoreCase(value.string, "or")) op_and = false;
    }
    const limit = if (obj.get("limit")) |value|
        if (value == .integer and value.integer >= 0) @as(usize, @intCast(value.integer)) else return respondJsonError(alloc, req, .bad_request, "invalid_limit", "invalid limit")
    else
        null;

    const series = try eng.seriesDescriptorsForMetric(alloc, metric_value.string, labels_value, op_and, limit);
    defer alloc.free(series);

    var send_buffer: [1024]u8 = undefined;
    var response = try req.respondStreaming(&send_buffer, .{
        .respond_options = .{
            .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        },
    });
    errdefer response.end() catch {};

    var jw = std.json.Stringify{ .writer = &response.writer };
    try jw.beginArray();
    for (series) |descriptor| {
        try jw.beginObject();
        try jw.objectField("series_id");
        try jw.write(descriptor.series_id);
        try jw.objectField("metric");
        try jw.write(descriptor.metric);
        try jw.objectField("labels");
        try writeCanonicalJsonObject(&jw, descriptor.labels_json);
        try jw.objectField("first_ts");
        if (descriptor.first_ts) |first_ts| try jw.write(first_ts) else try jw.write(null);
        try jw.objectField("last_ts");
        if (descriptor.last_ts) |last_ts| try jw.write(last_ts) else try jw.write(null);
        try jw.endObject();
    }
    try jw.endArray();
    try response.end();
}

fn handleLabelValues(alloc: std.mem.Allocator, eng: *Engine, req: *std.http.Server.Request) !void {
    var parsed = readJsonBody(alloc, req, 64 * 1024) catch |err| switch (err) {
        error.LengthRequired => return respondJsonError(alloc, req, .length_required, "length_required", "length required"),
        error.PayloadTooLarge => return respondJsonError(alloc, req, .payload_too_large, "payload_too_large", "payload too large"),
        else => return respondJsonError(alloc, req, .bad_request, "invalid_json", "invalid json"),
    };
    defer parsed.deinit(alloc);
    const obj = parsed.parsed.value.object;

    const key_value = obj.get("key") orelse return respondJsonError(alloc, req, .bad_request, "missing_key", "missing key");
    if (key_value != .string) return respondJsonError(alloc, req, .bad_request, "invalid_key", "invalid key");
    const metric = if (obj.get("metric")) |value|
        if (value == .string) value.string else return respondJsonError(alloc, req, .bad_request, "invalid_metric", "invalid metric")
    else
        null;
    const prefix = if (obj.get("prefix")) |value|
        if (value == .string) value.string else return respondJsonError(alloc, req, .bad_request, "invalid_prefix", "invalid prefix")
    else
        "";
    const limit = if (obj.get("limit")) |value|
        if (value == .integer and value.integer >= 0) @as(usize, @intCast(value.integer)) else return respondJsonError(alloc, req, .bad_request, "invalid_limit", "invalid limit")
    else
        null;

    var values = std.StringHashMap(void).init(alloc);
    defer {
        var it = values.iterator();
        while (it.next()) |entry| alloc.free(entry.key_ptr.*);
        values.deinit();
    }
    var ordered = std.array_list.Managed([]const u8).init(alloc);
    defer {
        for (ordered.items) |value| alloc.free(value);
        ordered.deinit();
    }

    eng.metadata.series_catalog.mutex.lock();
    defer eng.metadata.series_catalog.mutex.unlock();
    for (eng.metadata.series_catalog.entries.items) |entry| {
        if (metric) |metric_name| {
            if (!std.mem.eql(u8, entry.series, metric_name)) continue;
        }
        const maybe_value = extractLabelValue(entry.canonical_tags, key_value.string) catch null;
        if (maybe_value == null) continue;
        const value = maybe_value.?;
        if (prefix.len != 0 and !std.mem.startsWith(u8, value, prefix)) continue;
        if (values.contains(value)) continue;
        const owned = try alloc.dupe(u8, value);
        errdefer alloc.free(owned);
        try values.put(owned, {});
        try ordered.append(owned);
        if (limit) |bounded| {
            if (ordered.items.len >= bounded) break;
        }
    }

    std.sort.block([]const u8, ordered.items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lessThan);

    var send_buffer: [512]u8 = undefined;
    var response = try req.respondStreaming(&send_buffer, .{
        .respond_options = .{
            .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        },
    });
    errdefer response.end() catch {};
    var jw = std.json.Stringify{ .writer = &response.writer };
    try jw.beginObject();
    try jw.objectField("values");
    try jw.beginArray();
    for (ordered.items) |value| try jw.write(value);
    try jw.endArray();
    try jw.endObject();
    try response.end();
}

fn handleMetricsHealth(alloc: std.mem.Allocator, eng: *Engine, req: *std.http.Server.Request) !void {
    var parsed = readJsonBody(alloc, req, 64 * 1024) catch |err| switch (err) {
        error.LengthRequired => return respondJsonError(alloc, req, .length_required, "length_required", "length required"),
        error.PayloadTooLarge => return respondJsonError(alloc, req, .payload_too_large, "payload_too_large", "payload too large"),
        else => return respondJsonError(alloc, req, .bad_request, "invalid_json", "invalid json"),
    };
    defer parsed.deinit(alloc);
    const obj = parsed.parsed.value.object;

    const prefix = if (obj.get("prefix")) |value|
        if (value == .string) value.string else return respondJsonError(alloc, req, .bad_request, "invalid_prefix", "invalid prefix")
    else
        "";
    const labels_value = obj.get("labels");
    if (labels_value) |labels| {
        if (labels != .object) return respondJsonError(alloc, req, .bad_request, "invalid_labels", "invalid labels");
    }
    const inactive_before_ts = if (obj.get("inactive_before_ts")) |value|
        if (value == .integer) value.integer else return respondJsonError(alloc, req, .bad_request, "invalid_inactive_before_ts", "invalid inactive_before_ts")
    else
        null;
    const limit = if (obj.get("limit")) |value|
        if (value == .integer and value.integer >= 0) @as(usize, @intCast(value.integer)) else return respondJsonError(alloc, req, .bad_request, "invalid_limit", "invalid limit")
    else
        null;

    var unique = std.StringHashMap(void).init(alloc);
    defer {
        var it = unique.iterator();
        while (it.next()) |entry| alloc.free(entry.key_ptr.*);
        unique.deinit();
    }
    var metrics = std.array_list.Managed([]const u8).init(alloc);
    defer {
        for (metrics.items) |metric| alloc.free(metric);
        metrics.deinit();
    }

    collect_metrics: {
        eng.metadata.series_catalog.mutex.lock();
        defer eng.metadata.series_catalog.mutex.unlock();
        for (eng.metadata.series_catalog.entries.items) |entry| {
            if (prefix.len != 0 and !std.mem.startsWith(u8, entry.series, prefix)) continue;
            if (unique.contains(entry.series)) continue;
            if (labels_value) |labels| {
                const descriptor_matches = descriptorMatchesLabels(entry.canonical_tags, labels, true) catch false;
                if (!descriptor_matches) continue;
            }
            const owned_metric = try alloc.dupe(u8, entry.series);
            errdefer alloc.free(owned_metric);
            try unique.put(owned_metric, {});
            try metrics.append(owned_metric);
            if (limit) |bounded| {
                if (metrics.items.len >= bounded) break :collect_metrics;
            }
        }
    }

    std.sort.block([]const u8, metrics.items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lessThan);

    var send_buffer: [1024]u8 = undefined;
    var response = try req.respondStreaming(&send_buffer, .{
        .respond_options = .{
            .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        },
    });
    errdefer response.end() catch {};

    var jw = std.json.Stringify{ .writer = &response.writer };
    try jw.beginArray();
    for (metrics.items) |metric| {
        const series = try eng.seriesDescriptorsForMetric(alloc, metric, labels_value, true, null);
        defer alloc.free(series);
        const descriptor = eng.metricDescriptor(metric);
        const label_keys = try collectLabelKeysForSeries(alloc, series);
        defer freeOwnedStrings(alloc, label_keys);
        const bounds = combineSeriesBounds(series);

        var inactive_series_count: usize = 0;
        if (inactive_before_ts) |cutoff| {
            for (series) |descriptor_item| {
                if (descriptor_item.last_ts == null or descriptor_item.last_ts.? < cutoff) inactive_series_count += 1;
            }
        }

        try jw.beginObject();
        try jw.objectField("metric");
        try jw.write(metric);
        try jw.objectField("kind");
        try jw.write(if (descriptor) |desc|
            if (desc.kind) |kind| kind.text() else metric_catalog_mod.MetricKind.gauge.text()
        else
            metric_catalog_mod.MetricKind.gauge.text());
        try jw.objectField("series_count");
        try jw.write(series.len);
        try jw.objectField("inactive_series_count");
        try jw.write(inactive_series_count);
        try jw.objectField("inactive");
        try jw.write(if (inactive_before_ts) |cutoff|
            bounds.last_ts == null or bounds.last_ts.? < cutoff
        else
            false);
        try jw.objectField("label_keys");
        try jw.beginArray();
        for (label_keys) |key| try jw.write(key);
        try jw.endArray();
        try jw.objectField("missing_metadata");
        try jw.beginArray();
        if (descriptor == null or descriptor.?.kind == null) try jw.write("kind");
        if (descriptor == null or descriptor.?.unit == null) try jw.write("unit");
        if (descriptor == null or descriptor.?.description == null) try jw.write("description");
        try jw.endArray();
        try jw.objectField("first_ts");
        if (bounds.first_ts) |first_ts| try jw.write(first_ts) else try jw.write(null);
        try jw.objectField("last_ts");
        if (bounds.last_ts) |last_ts| try jw.write(last_ts) else try jw.write(null);
        try jw.endObject();
    }
    try jw.endArray();
    try response.end();
}

fn handleQueryCompare(alloc: std.mem.Allocator, eng: *Engine, req: *std.http.Server.Request) !void {
    var parsed = readJsonBody(alloc, req, 64 * 1024) catch |err| switch (err) {
        error.LengthRequired => return respondJsonError(alloc, req, .length_required, "length_required", "length required"),
        error.PayloadTooLarge => return respondJsonError(alloc, req, .payload_too_large, "payload_too_large", "payload too large"),
        else => return respondJsonError(alloc, req, .bad_request, "invalid_json", "invalid json"),
    };
    defer parsed.deinit(alloc);
    const obj = parsed.parsed.value.object;

    const aggregate_value = obj.get("aggregate") orelse {
        return respondJsonError(alloc, req, .bad_request, "missing_aggregate", "missing aggregate");
    };
    if (aggregate_value != .string) {
        return respondJsonError(alloc, req, .bad_request, "invalid_aggregate", "invalid aggregate");
    }
    const aggregate = aggregate_value.string;
    const start_value = obj.get("start") orelse return respondJsonError(alloc, req, .bad_request, "missing_start", "missing start");
    const end_value = obj.get("end") orelse return respondJsonError(alloc, req, .bad_request, "missing_end", "missing end");
    const baseline_start_value = obj.get("baseline_start") orelse return respondJsonError(alloc, req, .bad_request, "missing_baseline_start", "missing baseline_start");
    const baseline_end_value = obj.get("baseline_end") orelse return respondJsonError(alloc, req, .bad_request, "missing_baseline_end", "missing baseline_end");
    if (start_value != .integer or end_value != .integer or baseline_start_value != .integer or baseline_end_value != .integer) {
        return respondJsonError(alloc, req, .bad_request, "invalid_time_range", "invalid time range");
    }

    const labels_value = obj.get("labels");
    if (labels_value) |labels| {
        if (labels != .object) return respondJsonError(alloc, req, .bad_request, "invalid_labels", "invalid labels");
    }
    const tags_value = obj.get("tags");
    if (tags_value) |tags| {
        if (tags != .object) return respondJsonError(alloc, req, .bad_request, "invalid_tags", "invalid tags");
    }

    const start_ts: i64 = @intCast(start_value.integer);
    const end_ts: i64 = @intCast(end_value.integer);
    const baseline_start_ts: i64 = @intCast(baseline_start_value.integer);
    const baseline_end_ts: i64 = @intCast(baseline_end_value.integer);
    if (end_ts < start_ts or baseline_end_ts < baseline_start_ts) {
        return respondJsonError(alloc, req, .bad_request, "invalid_time_range", "invalid time range");
    }

    const sid = if (obj.get("series_id")) |value|
        if (value == .integer and value.integer >= 0)
            @as(types.SeriesId, @intCast(value.integer))
        else
            return respondJsonError(alloc, req, .bad_request, "invalid_series_id", "invalid series_id")
    else if (obj.get("metric")) |metric_value|
        if (metric_value == .string) blk: {
            const labels_json = try extractTagsJson(alloc, labels_value);
            defer if (labels_json.owned) |owned| alloc.free(owned);
            break :blk if (labels_value != null)
                try resolveExactSeriesId(eng, metric_value.string, labels_json.value)
            else
                try resolveUniqueSeriesId(eng, metric_value.string);
        } else return respondJsonError(alloc, req, .bad_request, "invalid_metric", "invalid metric")
    else if (obj.get("series")) |series_value|
        if (series_value == .string) blk: {
            const tags_json = try extractTagsJson(alloc, tags_value);
            defer if (tags_json.owned) |owned| alloc.free(owned);
            break :blk if (tags_value != null)
                try resolveExactSeriesId(eng, series_value.string, tags_json.value)
            else
                try resolveUniqueSeriesId(eng, series_value.string);
        } else return respondJsonError(alloc, req, .bad_request, "invalid_series", "invalid series")
    else
        null;

    const resolved_sid = sid orelse {
        return respondJsonError(alloc, req, .not_found, "series_not_resolved", "series not found or ambiguous");
    };
    if (resolved_sid == null_series_id) {
        return respondJsonError(alloc, req, .not_found, "series_not_found", "series not found");
    }

    const resolution = try eng.resolveSelector(.{ .by_id = resolved_sid });
    const metric_name: ?[]const u8 = if (resolution.series) |metric|
        metric
    else if (obj.get("metric")) |metric_value|
        if (metric_value == .string) metric_value.string else null
    else if (obj.get("series")) |series_value|
        if (series_value == .string) series_value.string else null
    else
        null;
    const metric_kind = if (metric_name) |metric| eng.metricKindOrDefault(metric) else metric_catalog_mod.MetricKind.gauge;

    var current_points = std.array_list.Managed(types.Point).init(alloc);
    defer current_points.deinit();
    try eng.queryRange(resolved_sid, start_ts, end_ts, &current_points);

    var baseline_points = std.array_list.Managed(types.Point).init(alloc);
    defer baseline_points.deinit();
    try eng.queryRange(resolved_sid, baseline_start_ts, baseline_end_ts, &baseline_points);

    const current_value = aggregatePointsForCompare(current_points.items, aggregate, metric_kind) catch {
        return respondJsonError(alloc, req, .bad_request, "invalid_aggregate", "invalid aggregate");
    };
    const baseline_value = aggregatePointsForCompare(baseline_points.items, aggregate, metric_kind) catch {
        return respondJsonError(alloc, req, .bad_request, "invalid_aggregate", "invalid aggregate");
    };

    var send_buffer: [1024]u8 = undefined;
    var response = try req.respondStreaming(&send_buffer, .{
        .respond_options = .{
            .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        },
    });
    errdefer response.end() catch {};

    var jw = std.json.Stringify{ .writer = &response.writer };
    try jw.beginObject();
    try jw.objectField("series_id");
    try jw.write(resolved_sid);
    if (metric_name) |metric| {
        try jw.objectField("metric");
        try jw.write(metric);
    }
    if (resolution.canonical_tags) |labels_json| {
        try jw.objectField("labels");
        try writeCanonicalJsonObject(&jw, labels_json);
    }
    try jw.objectField("aggregate");
    try jw.write(aggregate);
    try jw.objectField("metric_kind");
    try jw.write(metric_kind.text());

    try jw.objectField("current");
    try jw.beginObject();
    try jw.objectField("start");
    try jw.write(start_ts);
    try jw.objectField("end");
    try jw.write(end_ts);
    try jw.objectField("samples");
    try jw.write(current_points.items.len);
    try jw.objectField("value");
    if (current_value) |value| try jw.write(value) else try jw.write(null);
    try jw.endObject();

    try jw.objectField("baseline");
    try jw.beginObject();
    try jw.objectField("start");
    try jw.write(baseline_start_ts);
    try jw.objectField("end");
    try jw.write(baseline_end_ts);
    try jw.objectField("samples");
    try jw.write(baseline_points.items.len);
    try jw.objectField("value");
    if (baseline_value) |value| try jw.write(value) else try jw.write(null);
    try jw.endObject();

    try jw.objectField("change_abs");
    if (current_value != null and baseline_value != null) {
        try jw.write(current_value.? - baseline_value.?);
    } else {
        try jw.write(null);
    }
    try jw.objectField("change_pct");
    if (percentChange(current_value, baseline_value)) |value| try jw.write(value) else try jw.write(null);
    try jw.endObject();
    try response.end();
}

fn handleAnnotationWrite(alloc: std.mem.Allocator, eng: *Engine, req: *std.http.Server.Request) !void {
    var parsed = readJsonBody(alloc, req, 64 * 1024) catch |err| switch (err) {
        error.LengthRequired => return respondJsonError(alloc, req, .length_required, "length_required", "length required"),
        error.PayloadTooLarge => return respondJsonError(alloc, req, .payload_too_large, "payload_too_large", "payload too large"),
        else => return respondJsonError(alloc, req, .bad_request, "invalid_json", "invalid json"),
    };
    defer parsed.deinit(alloc);
    const obj = parsed.parsed.value.object;

    const kind_value = obj.get("kind") orelse return respondJsonError(alloc, req, .bad_request, "missing_kind", "missing kind");
    const title_value = obj.get("title") orelse return respondJsonError(alloc, req, .bad_request, "missing_title", "missing title");
    const start_value = obj.get("start") orelse return respondJsonError(alloc, req, .bad_request, "missing_start", "missing start");
    if (kind_value != .string or title_value != .string or start_value != .integer) {
        return respondJsonError(alloc, req, .bad_request, "invalid_annotation", "invalid annotation");
    }
    if (obj.get("labels")) |labels| {
        if (labels != .object) return respondJsonError(alloc, req, .bad_request, "invalid_labels", "invalid labels");
    }

    const start_ts: i64 = @intCast(start_value.integer);
    const end_ts: i64 = if (obj.get("end")) |value|
        if (value == .integer) @intCast(value.integer) else return respondJsonError(alloc, req, .bad_request, "invalid_end", "invalid end")
    else
        start_ts;
    if (end_ts < start_ts) return respondJsonError(alloc, req, .bad_request, "invalid_time_range", "invalid time range");

    const labels_json = try extractTagsJson(alloc, obj.get("labels"));
    defer if (labels_json.owned) |owned| alloc.free(owned);

    var entry = annotations_mod.append(alloc, eng.data_dir, .{
        .kind = kind_value.string,
        .title = title_value.string,
        .message = if (obj.get("message")) |message|
            if (message == .string) message.string else return respondJsonError(alloc, req, .bad_request, "invalid_message", "invalid message")
        else
            null,
        .metric = if (obj.get("metric")) |metric|
            if (metric == .string) metric.string else return respondJsonError(alloc, req, .bad_request, "invalid_metric", "invalid metric")
        else
            null,
        .start_ts = start_ts,
        .end_ts = end_ts,
        .labels_json = labels_json.value,
    }) catch |err| switch (err) {
        else => return respondJsonError(alloc, req, .internal_server_error, "annotation_write_failed", @errorName(err)),
    };
    defer entry.deinit(alloc);

    var send_buffer: [512]u8 = undefined;
    var response = try req.respondStreaming(&send_buffer, .{
        .respond_options = .{
            .status = .created,
            .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        },
    });
    errdefer response.end() catch {};
    var jw = std.json.Stringify{ .writer = &response.writer };
    try writeAnnotationEntry(&jw, entry);
    try response.end();
}

fn handleAnnotationQuery(alloc: std.mem.Allocator, eng: *Engine, req: *std.http.Server.Request) !void {
    var parsed = readJsonBody(alloc, req, 64 * 1024) catch |err| switch (err) {
        error.LengthRequired => return respondJsonError(alloc, req, .length_required, "length_required", "length required"),
        error.PayloadTooLarge => return respondJsonError(alloc, req, .payload_too_large, "payload_too_large", "payload too large"),
        else => return respondJsonError(alloc, req, .bad_request, "invalid_json", "invalid json"),
    };
    defer parsed.deinit(alloc);
    const obj = parsed.parsed.value.object;

    const labels_value = obj.get("labels");
    if (labels_value) |labels| {
        if (labels != .object) return respondJsonError(alloc, req, .bad_request, "invalid_labels", "invalid labels");
    }
    var op_and = true;
    if (obj.get("op")) |value| {
        if (value == .string and std.ascii.eqlIgnoreCase(value.string, "or")) op_and = false;
    }
    const limit = if (obj.get("limit")) |value|
        if (value == .integer and value.integer >= 0) @as(usize, @intCast(value.integer)) else return respondJsonError(alloc, req, .bad_request, "invalid_limit", "invalid limit")
    else
        null;

    const entries = annotations_mod.query(alloc, eng.data_dir, .{
        .start_ts = if (obj.get("start")) |value|
            if (value == .integer) value.integer else return respondJsonError(alloc, req, .bad_request, "invalid_start", "invalid start")
        else
            null,
        .end_ts = if (obj.get("end")) |value|
            if (value == .integer) value.integer else return respondJsonError(alloc, req, .bad_request, "invalid_end", "invalid end")
        else
            null,
        .kind = if (obj.get("kind")) |value|
            if (value == .string) value.string else return respondJsonError(alloc, req, .bad_request, "invalid_kind", "invalid kind")
        else
            null,
        .metric = if (obj.get("metric")) |value|
            if (value == .string) value.string else return respondJsonError(alloc, req, .bad_request, "invalid_metric", "invalid metric")
        else
            null,
        .limit = null,
    }) catch |err| switch (err) {
        else => return respondJsonError(alloc, req, .internal_server_error, "annotation_query_failed", @errorName(err)),
    };
    defer {
        for (entries) |*entry| entry.deinit(alloc);
        alloc.free(entries);
    }

    var send_buffer: [1024]u8 = undefined;
    var response = try req.respondStreaming(&send_buffer, .{
        .respond_options = .{
            .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        },
    });
    errdefer response.end() catch {};

    var jw = std.json.Stringify{ .writer = &response.writer };
    try jw.beginArray();
    var emitted: usize = 0;
    for (entries) |entry| {
        if (labels_value) |labels| {
            const matches = descriptorMatchesLabels(entry.labels_json, labels, op_and) catch false;
            if (!matches) continue;
        }
        try writeAnnotationEntry(&jw, entry);
        emitted += 1;
        if (limit) |bounded| {
            if (emitted >= bounded) break;
        }
    }
    try jw.endArray();
    try response.end();
}

const OwnedJsonBody = struct {
    body: []u8,
    parsed: std.json.Parsed(std.json.Value),

    fn deinit(self: *OwnedJsonBody, alloc: std.mem.Allocator) void {
        self.parsed.deinit();
        alloc.free(self.body);
    }
};

fn readJsonBody(alloc: std.mem.Allocator, req: *std.http.Server.Request, max_len: usize) !OwnedJsonBody {
    var body_buf: [2048]u8 = undefined;
    const body_reader = req.readerExpectNone(&body_buf);
    const content_len = req.head.content_length orelse return error.LengthRequired;
    if (content_len > max_len) return error.PayloadTooLarge;
    const alloc_len: usize = @intCast(content_len);
    const body_slice = try body_reader.*.take(alloc_len);
    const body = try alloc.dupe(u8, body_slice);
    errdefer alloc.free(body);
    return .{
        .body = body,
        .parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{}),
    };
}

fn writeCanonicalJsonObject(jw: *std.json.Stringify, json_text: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.heap.c_allocator, json_text, .{});
    defer parsed.deinit();
    try jw.write(parsed.value);
}

fn descriptorMatchesLabels(labels_json: []const u8, expected: std.json.Value, op_and: bool) !bool {
    if (expected != .object) return false;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.heap.c_allocator, labels_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return false;

    var saw_constraint = false;
    var matched_any = false;
    var it = expected.object.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .string) continue;
        saw_constraint = true;
        const actual = parsed.value.object.get(entry.key_ptr.*) orelse {
            if (op_and) return false;
            continue;
        };
        const matched = actual == .string and std.mem.eql(u8, actual.string, entry.value_ptr.string);
        if (op_and and !matched) return false;
        if (!op_and and matched) matched_any = true;
    }
    if (!saw_constraint) return true;
    return if (op_and) true else matched_any;
}

fn collectLabelKeysForSeries(alloc: std.mem.Allocator, series: []const Engine.SeriesDescriptor) ![][]const u8 {
    var set = std.StringHashMap(void).init(alloc);
    defer set.deinit();
    var keys = std.array_list.Managed([]const u8).init(alloc);
    errdefer freeOwnedStrings(alloc, keys.items);
    errdefer keys.deinit();

    for (series) |descriptor| {
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, descriptor.labels_json, .{});
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        var it = parsed.value.object.iterator();
        while (it.next()) |entry| {
            if (set.contains(entry.key_ptr.*)) continue;
            const owned = try alloc.dupe(u8, entry.key_ptr.*);
            errdefer alloc.free(owned);
            try set.put(owned, {});
            try keys.append(owned);
        }
    }

    std.sort.block([]const u8, keys.items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lessThan);
    return try keys.toOwnedSlice();
}

fn freeOwnedStrings(alloc: std.mem.Allocator, strings: []const []const u8) void {
    for (strings) |value| alloc.free(value);
}

fn combineSeriesBounds(series: []const Engine.SeriesDescriptor) struct { first_ts: ?i64, last_ts: ?i64 } {
    var first_ts: ?i64 = null;
    var last_ts: ?i64 = null;
    for (series) |descriptor| {
        if (descriptor.first_ts) |value| {
            if (first_ts == null or value < first_ts.?) first_ts = value;
        }
        if (descriptor.last_ts) |value| {
            if (last_ts == null or value > last_ts.?) last_ts = value;
        }
    }
    return .{ .first_ts = first_ts, .last_ts = last_ts };
}

fn extractLabelValue(labels_json: []const u8, key: []const u8) !?[]const u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.heap.c_allocator, labels_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const value = parsed.value.object.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn writeAnnotationEntry(jw: *std.json.Stringify, entry: annotations_mod.Entry) !void {
    try jw.beginObject();
    try jw.objectField("id");
    try jw.write(entry.id);
    try jw.objectField("kind");
    try jw.write(entry.kind);
    try jw.objectField("title");
    try jw.write(entry.title);
    if (entry.message) |message| {
        try jw.objectField("message");
        try jw.write(message);
    }
    if (entry.metric) |metric| {
        try jw.objectField("metric");
        try jw.write(metric);
    }
    try jw.objectField("start");
    try jw.write(entry.start_ts);
    try jw.objectField("end");
    try jw.write(entry.end_ts);
    try jw.objectField("labels");
    try writeCanonicalJsonObject(jw, entry.labels_json);
    try jw.endObject();
}

fn aggregatePointsForCompare(
    points: []const types.Point,
    aggregate: []const u8,
    metric_kind: metric_catalog_mod.MetricKind,
) !?f64 {
    if (points.len == 0) return null;

    if (std.ascii.eqlIgnoreCase(aggregate, "last")) return points[points.len - 1].value;
    if (std.ascii.eqlIgnoreCase(aggregate, "count")) return @as(f64, @floatFromInt(points.len));
    if (std.ascii.eqlIgnoreCase(aggregate, "sum")) {
        var total: f64 = 0;
        for (points) |point| total += point.value;
        return total;
    }
    if (std.ascii.eqlIgnoreCase(aggregate, "avg")) {
        var total: f64 = 0;
        for (points) |point| total += point.value;
        return total / @as(f64, @floatFromInt(points.len));
    }
    if (std.ascii.eqlIgnoreCase(aggregate, "min")) {
        var minimum = points[0].value;
        for (points[1..]) |point| {
            if (point.value < minimum) minimum = point.value;
        }
        return minimum;
    }
    if (std.ascii.eqlIgnoreCase(aggregate, "max")) {
        var maximum = points[0].value;
        for (points[1..]) |point| {
            if (point.value > maximum) maximum = point.value;
        }
        return maximum;
    }
    if (std.ascii.eqlIgnoreCase(aggregate, "delta")) {
        return switch (metric_kind) {
            .counter => resetAwareDelta(points),
            .gauge => points[points.len - 1].value - points[0].value,
        };
    }
    return error.UnsupportedCompareAggregate;
}

fn resetAwareDelta(points: []const types.Point) f64 {
    if (points.len == 0) return 0;
    var total: f64 = 0;
    var prev = points[0].value;
    for (points[1..]) |point| {
        if (point.value >= prev) {
            total += point.value - prev;
        } else {
            total += point.value;
        }
        prev = point.value;
    }
    return total;
}

fn percentChange(current: ?f64, baseline: ?f64) ?f64 {
    if (current == null or baseline == null or baseline.? == 0) return null;
    return ((current.? - baseline.?) / baseline.?) * 100.0;
}
