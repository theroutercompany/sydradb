const std = @import("std");
const Engine = @import("engine.zig").Engine;
const types = @import("types.zig");
const config = @import("config.zig");
const compat = @import("compat.zig");
const cas_mod = @import("storage/cas.zig");
const annotations_mod = @import("storage/annotations.zig");
const market_catalog_mod = @import("storage/market_catalog.zig");
const market_runtime_mod = @import("storage/market_runtime.zig");
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
    if (std.mem.eql(u8, path, "/api/v1/market/schema/register") and method == .POST) {
        return try handleMarketSchemaRegister(alloc, eng, req);
    }
    if (std.mem.eql(u8, path, "/api/v1/market/schemas") and method == .GET) {
        return try handleMarketSchemaList(alloc, eng, req);
    }
    if (std.mem.startsWith(u8, path, "/api/v1/market/schema/") and method == .GET) {
        return try handleMarketSchemaGet(alloc, eng, req, path["/api/v1/market/schema/".len..]);
    }
    if (std.mem.eql(u8, path, "/api/v1/market/ingest") and method == .POST) {
        return try handleMarketIngest(alloc, eng, req);
    }
    if (std.mem.eql(u8, path, "/api/v1/market/query") and method == .POST) {
        return try handleMarketQuery(alloc, eng, req);
    }
    if (std.mem.eql(u8, path, "/api/v1/bar-policies/register") and method == .POST) {
        return try handleBarPolicyRegister(alloc, eng, req);
    }
    if (std.mem.eql(u8, path, "/api/v1/bar-policies") and method == .GET) {
        return try handleBarPolicyList(alloc, eng, req);
    }
    if (std.mem.eql(u8, path, "/api/v1/rollups/register") and method == .POST) {
        return try handleRollupRegister(alloc, eng, req);
    }
    if (std.mem.eql(u8, path, "/api/v1/rollups") and method == .GET) {
        return try handleRollupList(alloc, eng, req);
    }
    if (std.mem.startsWith(u8, path, "/api/v1/rollups/")) {
        return try handleRollupAction(alloc, eng, req, method, path["/api/v1/rollups/".len..]);
    }
    if (std.mem.eql(u8, path, "/api/v1/signals/register") and method == .POST) {
        return try handleSignalRegister(alloc, eng, req);
    }
    if (std.mem.eql(u8, path, "/api/v1/signals") and method == .GET) {
        return try handleSignalList(alloc, eng, req);
    }
    if (std.mem.eql(u8, path, "/api/v1/signals/history") and method == .GET) {
        return try handleSignalHistory(alloc, eng, req, query);
    }
    if (std.mem.startsWith(u8, path, "/api/v1/signals/") and !std.mem.eql(u8, path, "/api/v1/signals/subscribe")) {
        return try handleSignalAction(alloc, eng, req, method, path["/api/v1/signals/".len..]);
    }
    if (std.mem.eql(u8, path, "/api/v1/signals/subscribe") and method == .GET) {
        return try handleSignalSubscribe(alloc, eng, req, query);
    }
    if (std.mem.eql(u8, path, "/api/v1/cas/refs") and method == .GET) {
        return try handleCasRefs(alloc, eng, req);
    }
    if (std.mem.eql(u8, path, "/api/v1/cas/commits") and method == .GET) {
        return try handleCasCommits(alloc, eng, req, query);
    }
    if (std.mem.eql(u8, path, "/api/v1/cas/log") and method == .GET) {
        return try handleCasLog(alloc, eng, req, query);
    }
    if (std.mem.eql(u8, path, "/api/v1/cas/diff") and method == .GET) {
        return try handleCasDiff(alloc, eng, req, query);
    }
    if (std.mem.eql(u8, path, "/api/v1/analysis/markout") and method == .POST) {
        return try handleAnalysisMarkout(alloc, eng, req);
    }
    if (std.mem.eql(u8, path, "/api/v1/analysis/slippage") and method == .POST) {
        return try handleAnalysisSlippage(alloc, eng, req);
    }
    if (std.mem.eql(u8, path, "/api/v1/analysis/quote-quality") and method == .POST) {
        return try handleAnalysisQuoteQuality(alloc, eng, req);
    }
    if (std.mem.eql(u8, path, "/api/v1/analysis/catalog") and method == .GET) {
        return try handleAnalysisCatalog(req);
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
    maintenance_pause_active: bool,
    memtable_bytes: usize,
    drain_timeout_total: u64,
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
        .maintenance_pause_active = eng.metrics.maintenance_pause_active.load(.monotonic),
        .memtable_bytes = eng.mem.bytes.load(.monotonic),
        .drain_timeout_total = eng.metrics.drain_timeout_total.load(.monotonic),
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
    try jw.objectField("maintenance_pause_active");
    try jw.write(snapshot.maintenance_pause_active);
    try jw.objectField("memtable_bytes");
    try jw.write(snapshot.memtable_bytes);
    try jw.objectField("drain_timeout_total");
    try jw.write(snapshot.drain_timeout_total);
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
        .maintenance_pause_active = true,
        .memtable_bytes = 4096,
        .drain_timeout_total = 6,
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
    try std.testing.expectEqual(true, runtime.get("maintenance_pause_active").?.bool);
    try std.testing.expectEqual(@as(i64, 4096), runtime.get("memtable_bytes").?.integer);
    try std.testing.expectEqual(@as(i64, 6), runtime.get("drain_timeout_total").?.integer);
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
    const drain_timeout_total = eng.metrics.drain_timeout_total.load(.monotonic);
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
    const maintenance_pause_active = eng.metrics.maintenance_pause_active.load(.monotonic);
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
    try writer.print("# HELP sydradb_drain_timeout_total Total waitForDrained calls that timed out before the engine became queryable\n# TYPE sydradb_drain_timeout_total counter\nsydradb_drain_timeout_total {d}\n", .{drain_timeout_total});
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
    try writer.print("# HELP sydradb_maintenance_pause_active 1 when the writer loop is paused for maintenance, 0 otherwise\n# TYPE sydradb_maintenance_pause_active gauge\nsydradb_maintenance_pause_active {d}\n", .{@intFromBool(maintenance_pause_active)});
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

fn handleMarketSchemaRegister(alloc: std.mem.Allocator, eng: *Engine, req: *std.http.Server.Request) !void {
    var parsed = readJsonBody(alloc, req, 64 * 1024) catch |err| switch (err) {
        error.LengthRequired => return respondJsonError(alloc, req, .length_required, "length_required", "length required"),
        error.PayloadTooLarge => return respondJsonError(alloc, req, .payload_too_large, "payload_too_large", "payload too large"),
        else => return respondJsonError(alloc, req, .bad_request, "invalid_json", "invalid json"),
    };
    defer parsed.deinit(alloc);
    const obj = parsed.parsed.value.object;

    const metric_value = obj.get("metric") orelse return respondJsonError(alloc, req, .bad_request, "missing_metric", "missing metric");
    const columns_value = obj.get("ordered_columns") orelse return respondJsonError(alloc, req, .bad_request, "missing_ordered_columns", "missing ordered_columns");
    const labels_value = obj.get("required_labels") orelse return respondJsonError(alloc, req, .bad_request, "missing_required_labels", "missing required_labels");
    if (metric_value != .string or columns_value != .array or labels_value != .array) {
        return respondJsonError(alloc, req, .bad_request, "invalid_market_schema", "invalid market schema");
    }

    const ordered_columns = try jsonStringArrayConst(alloc, columns_value);
    defer alloc.free(ordered_columns);
    const required_labels = try jsonStringArrayConst(alloc, labels_value);
    defer alloc.free(required_labels);
    const storage_mapping = if (obj.get("storage_mapping")) |value|
        if (value == .string)
            market_catalog_mod.StorageMapping.parse(value.string) orelse return respondJsonError(alloc, req, .bad_request, "invalid_storage_mapping", "invalid storage_mapping")
        else
            return respondJsonError(alloc, req, .bad_request, "invalid_storage_mapping", "invalid storage_mapping")
    else
        market_catalog_mod.StorageMapping.fanout_v1;

    var stored = eng.registerMarketSchema(.{
        .metric = metric_value.string,
        .ordered_columns = ordered_columns,
        .required_labels = required_labels,
        .storage_mapping = storage_mapping,
    }) catch |err| switch (err) {
        error.MarketSchemaConflict => return respondJsonError(alloc, req, .conflict, "market_schema_conflict", "market schema conflict"),
        else => return respondJsonError(alloc, req, .internal_server_error, "market_schema_register_failed", @errorName(err)),
    };
    defer stored.deinit(alloc);

    var send_buffer: [1024]u8 = undefined;
    var response = try req.respondStreaming(&send_buffer, .{
        .respond_options = .{
            .status = .created,
            .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        },
    });
    errdefer response.end() catch {};
    var jw = std.json.Stringify{ .writer = &response.writer };
    try market_catalog_mod.writeSchema(&jw, stored);
    try response.end();
}

fn handleMarketSchemaList(alloc: std.mem.Allocator, eng: *Engine, req: *std.http.Server.Request) !void {
    const schemas = try eng.listMarketSchemas();
    defer {
        for (schemas) |*entry| entry.deinit(alloc);
        alloc.free(schemas);
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
    for (schemas) |entry| try market_catalog_mod.writeSchema(&jw, entry);
    try jw.endArray();
    try response.end();
}

fn handleMarketSchemaGet(alloc: std.mem.Allocator, eng: *Engine, req: *std.http.Server.Request, metric: []const u8) !void {
    var stored = eng.marketSchema(metric) orelse return respondJsonError(alloc, req, .not_found, "market_schema_not_found", "market schema not found");
    defer stored.deinit(alloc);

    var send_buffer: [512]u8 = undefined;
    var response = try req.respondStreaming(&send_buffer, .{
        .respond_options = .{
            .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        },
    });
    errdefer response.end() catch {};
    var jw = std.json.Stringify{ .writer = &response.writer };
    try market_catalog_mod.writeSchema(&jw, stored);
    try response.end();
}

fn handleBarPolicyRegister(alloc: std.mem.Allocator, eng: *Engine, req: *std.http.Server.Request) !void {
    var parsed = readJsonBody(alloc, req, 64 * 1024) catch |err| switch (err) {
        error.LengthRequired => return respondJsonError(alloc, req, .length_required, "length_required", "length required"),
        error.PayloadTooLarge => return respondJsonError(alloc, req, .payload_too_large, "payload_too_large", "payload too large"),
        else => return respondJsonError(alloc, req, .bad_request, "invalid_json", "invalid json"),
    };
    defer parsed.deinit(alloc);
    const obj = parsed.parsed.value.object;

    const id_value = obj.get("id") orelse return respondJsonError(alloc, req, .bad_request, "missing_id", "missing id");
    const source_value = obj.get("source_metric") orelse return respondJsonError(alloc, req, .bad_request, "missing_source_metric", "missing source_metric");
    const interval_value = obj.get("interval_ns") orelse return respondJsonError(alloc, req, .bad_request, "missing_interval_ns", "missing interval_ns");
    const session_value = obj.get("session_rule") orelse return respondJsonError(alloc, req, .bad_request, "missing_session_rule", "missing session_rule");
    const no_trade_value = obj.get("no_trade_rule") orelse return respondJsonError(alloc, req, .bad_request, "missing_no_trade_rule", "missing no_trade_rule");
    const halt_value = obj.get("halt_rule") orelse return respondJsonError(alloc, req, .bad_request, "missing_halt_rule", "missing halt_rule");
    const correction_value = obj.get("correction_policy") orelse return respondJsonError(alloc, req, .bad_request, "missing_correction_policy", "missing correction_policy");
    if (id_value != .string or source_value != .string or interval_value != .integer or session_value != .string or no_trade_value != .string or halt_value != .string or correction_value != .string) {
        return respondJsonError(alloc, req, .bad_request, "invalid_bar_policy", "invalid bar policy");
    }

    var stored = try eng.registerBarPolicy(.{
        .id = id_value.string,
        .source_metric = source_value.string,
        .interval_ns = interval_value.integer,
        .session_rule = session_value.string,
        .no_trade_rule = no_trade_value.string,
        .halt_rule = halt_value.string,
        .correction_policy = correction_value.string,
        .trade_filter = if (obj.get("trade_filter")) |value| if (value == .string) value.string else null else null,
    });
    defer stored.deinit(alloc);

    var send_buffer: [1024]u8 = undefined;
    var response = try req.respondStreaming(&send_buffer, .{
        .respond_options = .{
            .status = .created,
            .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        },
    });
    errdefer response.end() catch {};
    var jw = std.json.Stringify{ .writer = &response.writer };
    try market_catalog_mod.writeBarPolicy(&jw, stored);
    try response.end();
}

fn handleBarPolicyList(alloc: std.mem.Allocator, eng: *Engine, req: *std.http.Server.Request) !void {
    const entries = try eng.listBarPolicies();
    defer {
        for (entries) |*entry| entry.deinit(alloc);
        alloc.free(entries);
    }
    var send_buffer: [1024]u8 = undefined;
    var response = try req.respondStreaming(&send_buffer, .{
        .respond_options = .{ .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} },
    });
    errdefer response.end() catch {};
    var jw = std.json.Stringify{ .writer = &response.writer };
    try jw.beginArray();
    for (entries) |entry| try market_catalog_mod.writeBarPolicy(&jw, entry);
    try jw.endArray();
    try response.end();
}

fn handleRollupRegister(alloc: std.mem.Allocator, eng: *Engine, req: *std.http.Server.Request) !void {
    var parsed = readJsonBody(alloc, req, 64 * 1024) catch |err| switch (err) {
        error.LengthRequired => return respondJsonError(alloc, req, .length_required, "length_required", "length required"),
        error.PayloadTooLarge => return respondJsonError(alloc, req, .payload_too_large, "payload_too_large", "payload too large"),
        else => return respondJsonError(alloc, req, .bad_request, "invalid_json", "invalid json"),
    };
    defer parsed.deinit(alloc);
    const obj = parsed.parsed.value.object;
    const id_value = obj.get("id") orelse return respondJsonError(alloc, req, .bad_request, "missing_id", "missing id");
    const source_value = obj.get("source_metric") orelse return respondJsonError(alloc, req, .bad_request, "missing_source_metric", "missing source_metric");
    const target_value = obj.get("target_metric") orelse return respondJsonError(alloc, req, .bad_request, "missing_target_metric", "missing target_metric");
    const policy_value = obj.get("policy_id") orelse return respondJsonError(alloc, req, .bad_request, "missing_policy_id", "missing policy_id");
    const kind_value = obj.get("transform_kind") orelse return respondJsonError(alloc, req, .bad_request, "missing_transform_kind", "missing transform_kind");
    if (id_value != .string or source_value != .string or target_value != .string or policy_value != .string or kind_value != .string) {
        return respondJsonError(alloc, req, .bad_request, "invalid_rollup_definition", "invalid rollup definition");
    }
    const transform_kind = market_catalog_mod.RollupTransformKind.parse(kind_value.string) orelse return respondJsonError(alloc, req, .bad_request, "invalid_transform_kind", "invalid transform_kind");
    var stored = try eng.registerRollup(.{
        .id = id_value.string,
        .source_metric = source_value.string,
        .target_metric = target_value.string,
        .policy_id = policy_value.string,
        .transform_kind = transform_kind,
    });
    defer stored.deinit(alloc);

    var send_buffer: [1024]u8 = undefined;
    var response = try req.respondStreaming(&send_buffer, .{
        .respond_options = .{
            .status = .created,
            .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        },
    });
    errdefer response.end() catch {};
    var jw = std.json.Stringify{ .writer = &response.writer };
    try market_catalog_mod.writeRollup(&jw, stored);
    try response.end();
}

fn handleRollupList(alloc: std.mem.Allocator, eng: *Engine, req: *std.http.Server.Request) !void {
    const entries = try eng.listRollups();
    defer {
        for (entries) |*entry| entry.deinit(alloc);
        alloc.free(entries);
    }
    var send_buffer: [1024]u8 = undefined;
    var response = try req.respondStreaming(&send_buffer, .{
        .respond_options = .{ .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} },
    });
    errdefer response.end() catch {};
    var jw = std.json.Stringify{ .writer = &response.writer };
    try jw.beginArray();
    for (entries) |entry| {
        var runtime = eng.rollupRuntime(entry.id, entry.version);
        defer if (runtime) |*value| value.deinit(alloc);
        try writeRollupWithRuntimeAndStats(&jw, eng, entry, runtime);
    }
    try jw.endArray();
    try response.end();
}

fn handleSignalRegister(alloc: std.mem.Allocator, eng: *Engine, req: *std.http.Server.Request) !void {
    var parsed = readJsonBody(alloc, req, 64 * 1024) catch |err| switch (err) {
        error.LengthRequired => return respondJsonError(alloc, req, .length_required, "length_required", "length required"),
        error.PayloadTooLarge => return respondJsonError(alloc, req, .payload_too_large, "payload_too_large", "payload too large"),
        else => return respondJsonError(alloc, req, .bad_request, "invalid_json", "invalid json"),
    };
    defer parsed.deinit(alloc);
    const obj = parsed.parsed.value.object;
    const id_value = obj.get("id") orelse return respondJsonError(alloc, req, .bad_request, "missing_id", "missing id");
    const input_value = obj.get("input_metric") orelse return respondJsonError(alloc, req, .bad_request, "missing_input_metric", "missing input_metric");
    const expression_value = obj.get("expression_kind") orelse return respondJsonError(alloc, req, .bad_request, "missing_expression_kind", "missing expression_kind");
    const params_value = obj.get("params") orelse return respondJsonError(alloc, req, .bad_request, "missing_params", "missing params");
    const emit_value = obj.get("emit_rule") orelse return respondJsonError(alloc, req, .bad_request, "missing_emit_rule", "missing emit_rule");
    if (id_value != .string or input_value != .string or expression_value != .string or emit_value != .string) {
        return respondJsonError(alloc, req, .bad_request, "invalid_signal_definition", "invalid signal definition");
    }
    const expression_kind = market_catalog_mod.SignalExpressionKind.parse(expression_value.string) orelse return respondJsonError(alloc, req, .bad_request, "invalid_expression_kind", "invalid expression_kind");
    const params_json = try stringifyJsonValue(alloc, params_value);
    defer alloc.free(params_json);
    var stored = try eng.registerSignal(.{
        .id = id_value.string,
        .input_metric = input_value.string,
        .policy_id = if (obj.get("policy_id")) |value| if (value == .string) value.string else null else null,
        .expression_kind = expression_kind,
        .params_json = params_json,
        .emit_rule = emit_value.string,
    });
    defer stored.deinit(alloc);

    var send_buffer: [1024]u8 = undefined;
    var response = try req.respondStreaming(&send_buffer, .{
        .respond_options = .{
            .status = .created,
            .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        },
    });
    errdefer response.end() catch {};
    var jw = std.json.Stringify{ .writer = &response.writer };
    try market_catalog_mod.writeSignal(&jw, stored);
    try response.end();
}

fn handleSignalList(alloc: std.mem.Allocator, eng: *Engine, req: *std.http.Server.Request) !void {
    const entries = try eng.listSignals();
    defer {
        for (entries) |*entry| entry.deinit(alloc);
        alloc.free(entries);
    }
    var send_buffer: [1024]u8 = undefined;
    var response = try req.respondStreaming(&send_buffer, .{
        .respond_options = .{ .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} },
    });
    errdefer response.end() catch {};
    var jw = std.json.Stringify{ .writer = &response.writer };
    try jw.beginArray();
    for (entries) |entry| {
        var runtime = eng.signalRuntime(entry.id, entry.version);
        defer if (runtime) |*value| value.deinit(alloc);
        try writeSignalWithRuntimeAndStats(&jw, eng, entry, runtime);
    }
    try jw.endArray();
    try response.end();
}

fn handleRollupAction(
    alloc: std.mem.Allocator,
    eng: *Engine,
    req: *std.http.Server.Request,
    method: std.http.Method,
    remainder: []const u8,
) !void {
    if (method == .GET and std.mem.indexOfScalar(u8, remainder, '/') != null) {
        return respondJsonError(alloc, req, .not_found, "not_found", "not found");
    }
    if (method == .GET) {
        return try handleRollupDetail(alloc, eng, req, remainder);
    }
    if (std.mem.endsWith(u8, remainder, "/pause") and method == .POST) {
        const id = remainder[0 .. remainder.len - "/pause".len];
        try eng.pauseRollup(id);
        return try respondActionOk(req, "paused");
    }
    if (std.mem.endsWith(u8, remainder, "/resume") and method == .POST) {
        const id = remainder[0 .. remainder.len - "/resume".len];
        try eng.resumeRollup(id);
        return try respondActionOk(req, "active");
    }
    if (method == .DELETE) {
        const deleted = try eng.deleteRollup(remainder);
        if (!deleted) return respondJsonError(alloc, req, .not_found, "rollup_not_found", "rollup not found");
        return try respondActionOk(req, "deleted");
    }
    return respondJsonError(alloc, req, .not_found, "not_found", "not found");
}

fn handleSignalAction(
    alloc: std.mem.Allocator,
    eng: *Engine,
    req: *std.http.Server.Request,
    method: std.http.Method,
    remainder: []const u8,
) !void {
    if (method == .GET and std.mem.indexOfScalar(u8, remainder, '/') != null) {
        return respondJsonError(alloc, req, .not_found, "not_found", "not found");
    }
    if (method == .GET) {
        return try handleSignalDetail(alloc, eng, req, remainder);
    }
    if (std.mem.endsWith(u8, remainder, "/pause") and method == .POST) {
        const id = remainder[0 .. remainder.len - "/pause".len];
        try eng.pauseSignal(id);
        return try respondActionOk(req, "paused");
    }
    if (std.mem.endsWith(u8, remainder, "/resume") and method == .POST) {
        const id = remainder[0 .. remainder.len - "/resume".len];
        try eng.resumeSignal(id);
        return try respondActionOk(req, "active");
    }
    if (method == .DELETE) {
        const deleted = try eng.deleteSignal(remainder);
        if (!deleted) return respondJsonError(alloc, req, .not_found, "signal_not_found", "signal not found");
        return try respondActionOk(req, "deleted");
    }
    return respondJsonError(alloc, req, .not_found, "not_found", "not found");
}

fn handleRollupDetail(alloc: std.mem.Allocator, eng: *Engine, req: *std.http.Server.Request, id: []const u8) !void {
    var entry = try eng.latestRollup(id) orelse return respondJsonError(alloc, req, .not_found, "rollup_not_found", "rollup not found");
    defer entry.deinit(alloc);
    var runtime = eng.rollupRuntime(entry.id, entry.version);
    defer if (runtime) |*value| value.deinit(alloc);

    var send_buffer: [1024]u8 = undefined;
    var response = try req.respondStreaming(&send_buffer, .{
        .respond_options = .{ .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} },
    });
    errdefer response.end() catch {};
    var jw = std.json.Stringify{ .writer = &response.writer };
    try writeRollupWithRuntimeAndStats(&jw, eng, entry, runtime);
    try response.end();
}

fn handleSignalDetail(alloc: std.mem.Allocator, eng: *Engine, req: *std.http.Server.Request, id: []const u8) !void {
    var entry = try eng.latestSignal(id) orelse return respondJsonError(alloc, req, .not_found, "signal_not_found", "signal not found");
    defer entry.deinit(alloc);
    var runtime = eng.signalRuntime(entry.id, entry.version);
    defer if (runtime) |*value| value.deinit(alloc);

    var send_buffer: [1024]u8 = undefined;
    var response = try req.respondStreaming(&send_buffer, .{
        .respond_options = .{ .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} },
    });
    errdefer response.end() catch {};
    var jw = std.json.Stringify{ .writer = &response.writer };
    try writeSignalWithRuntimeAndStats(&jw, eng, entry, runtime);
    try response.end();
}

fn respondActionOk(req: *std.http.Server.Request, status_text: []const u8) !void {
    var send_buffer: [256]u8 = undefined;
    var response = try req.respondStreaming(&send_buffer, .{
        .respond_options = .{ .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} },
    });
    errdefer response.end() catch {};
    var jw = std.json.Stringify{ .writer = &response.writer };
    try jw.beginObject();
    try jw.objectField("status");
    try jw.write(status_text);
    try jw.endObject();
    try response.end();
}

fn writeRollupWithRuntime(
    jw: *std.json.Stringify,
    entry: market_catalog_mod.RollupDefinition,
    runtime: ?market_runtime_mod.DefinitionRuntime,
) !void {
    try writeRollupWithRuntimeAndStats(jw, null, entry, runtime);
}

fn writeRollupWithRuntimeAndStats(
    jw: *std.json.Stringify,
    eng: ?*Engine,
    entry: market_catalog_mod.RollupDefinition,
    runtime: ?market_runtime_mod.DefinitionRuntime,
) !void {
    try jw.beginObject();
    try jw.objectField("id");
    try jw.write(entry.id);
    try jw.objectField("version");
    try jw.write(entry.version);
    try jw.objectField("source_metric");
    try jw.write(entry.source_metric);
    try jw.objectField("target_metric");
    try jw.write(entry.target_metric);
    try jw.objectField("policy_id");
    try jw.write(entry.policy_id);
    try jw.objectField("transform_kind");
    try jw.write(entry.transform_kind.text());
    try jw.objectField("runtime");
    try writeRuntimeState(jw, runtime, if (eng) |engine| engine.pendingStatsForMetric(entry.source_metric) else .{ .pending_instances = 0, .max_lag_ns = null });
    try jw.endObject();
}

fn writeSignalWithRuntime(
    jw: *std.json.Stringify,
    entry: market_catalog_mod.SignalDefinition,
    runtime: ?market_runtime_mod.DefinitionRuntime,
) !void {
    try writeSignalWithRuntimeAndStats(jw, null, entry, runtime);
}

fn writeSignalWithRuntimeAndStats(
    jw: *std.json.Stringify,
    eng: ?*Engine,
    entry: market_catalog_mod.SignalDefinition,
    runtime: ?market_runtime_mod.DefinitionRuntime,
) !void {
    try jw.beginObject();
    try jw.objectField("id");
    try jw.write(entry.id);
    try jw.objectField("version");
    try jw.write(entry.version);
    try jw.objectField("input_metric");
    try jw.write(entry.input_metric);
    if (entry.policy_id) |value| {
        try jw.objectField("policy_id");
        try jw.write(value);
    }
    try jw.objectField("expression_kind");
    try jw.write(entry.expression_kind.text());
    try jw.objectField("params_json");
    try jw.write(entry.params_json);
    try jw.objectField("emit_rule");
    try jw.write(entry.emit_rule);
    try jw.objectField("runtime");
    try writeRuntimeState(jw, runtime, if (eng) |engine| engine.pendingStatsForMetric(entry.input_metric) else .{ .pending_instances = 0, .max_lag_ns = null });
    try jw.endObject();
}

fn writeRuntimeState(
    jw: *std.json.Stringify,
    runtime: ?market_runtime_mod.DefinitionRuntime,
    pending_stats: Engine.PendingStats,
) !void {
    try jw.beginObject();
    if (runtime) |value| {
        try jw.objectField("status");
        try jw.write(value.status.text());
        try jw.objectField("last_run_ts");
        if (value.last_run_ts) |ts| try jw.write(ts) else try jw.write(null);
        try jw.objectField("last_success_ts");
        if (value.last_success_ts) |ts| try jw.write(ts) else try jw.write(null);
        try jw.objectField("last_error");
        if (value.last_error) |err_text| try jw.write(err_text) else try jw.write(null);
        try jw.objectField("rows_processed");
        try jw.write(value.rows_processed);
        try jw.objectField("emissions_total");
        try jw.write(value.emissions_total);
        try jw.objectField("last_event_id");
        if (value.last_event_id) |event_id| try jw.write(event_id) else try jw.write(null);
    } else {
        try jw.objectField("status");
        try jw.write("active");
        try jw.objectField("last_run_ts");
        try jw.write(null);
        try jw.objectField("last_success_ts");
        try jw.write(null);
        try jw.objectField("last_error");
        try jw.write(null);
        try jw.objectField("rows_processed");
        try jw.write(@as(u64, 0));
        try jw.objectField("emissions_total");
        try jw.write(@as(u64, 0));
        try jw.objectField("last_event_id");
        try jw.write(null);
    }
    try jw.objectField("pending_instances");
    try jw.write(pending_stats.pending_instances);
    try jw.objectField("max_lag_ns");
    if (pending_stats.max_lag_ns) |lag| try jw.write(lag) else try jw.write(null);
    try jw.endObject();
}

fn handleMarketIngest(alloc: std.mem.Allocator, eng: *Engine, req: *std.http.Server.Request) !void {
    var body_buf: [4096]u8 = undefined;
    const body_reader = req.readerExpectNone(&body_buf);
    var rows: usize = 0;
    var writes: usize = 0;

    while (true) {
        const slice = body_reader.*.takeDelimiterExclusive('\n') catch |err| switch (err) {
            error.StreamTooLong => return respondJsonError(alloc, req, .payload_too_large, "line_too_long", "line too long"),
            error.EndOfStream => break,
            else => return err,
        };
        const trimmed = std.mem.trim(u8, slice, " \t\r\n");
        if (trimmed.len == 0) continue;

        var parsed = std.json.parseFromSlice(std.json.Value, alloc, trimmed, .{}) catch {
            return respondJsonError(alloc, req, .bad_request, "invalid_market_record", "invalid market record");
        };
        defer parsed.deinit();
        if (parsed.value != .object) return respondJsonError(alloc, req, .bad_request, "invalid_market_record", "invalid market record");
        const obj = parsed.value.object;

        const metric_value = obj.get("metric") orelse return respondJsonError(alloc, req, .bad_request, "missing_metric", "missing metric");
        const ts_value = obj.get("ts_ns") orelse return respondJsonError(alloc, req, .bad_request, "missing_ts_ns", "missing ts_ns");
        const columns_value = obj.get("columns") orelse return respondJsonError(alloc, req, .bad_request, "missing_columns", "missing columns");
        const labels_value = obj.get("labels") orelse return respondJsonError(alloc, req, .bad_request, "missing_labels", "missing labels");
        if (metric_value != .string or ts_value != .integer or columns_value != .object or labels_value != .object) {
            return respondJsonError(alloc, req, .bad_request, "invalid_market_record", "invalid market record");
        }

        var schema = eng.marketSchema(metric_value.string) orelse return respondJsonError(alloc, req, .not_found, "market_schema_not_found", "market schema not found");
        defer schema.deinit(alloc);
        if (!marketLabelsSatisfySchema(labels_value, schema)) {
            return respondJsonError(alloc, req, .bad_request, "invalid_market_labels", "invalid market labels");
        }
        if (!marketColumnsMatchSchema(columns_value, schema)) {
            return respondJsonError(alloc, req, .bad_request, "invalid_market_columns", "invalid market columns");
        }

        const labels_json = try extractTagsJson(alloc, labels_value);
        defer if (labels_json.owned) |owned| alloc.free(owned);
        const batch = try alloc.alloc(Engine.IngestItem, schema.ordered_columns.len);
        defer alloc.free(batch);
        var batch_len: usize = 0;
        for (schema.ordered_columns) |column| {
            const value = numericValue(columns_value.object.get(column).?) catch return respondJsonError(alloc, req, .bad_request, "invalid_market_columns", "invalid market columns");
            const derived_metric = try std.fmt.allocPrint(alloc, "{s}.{s}", .{ metric_value.string, column });
            defer alloc.free(derived_metric);
            _ = try eng.registerMetricDescriptor(.{
                .metric = derived_metric,
                .kind = .gauge,
                .source_metric = metric_value.string,
                .source_field = column,
            });
            const sid = types.seriesIdFrom(derived_metric, labels_json.value);
            try eng.registerSeries(derived_metric, labels_json.value, sid);
            batch[batch_len] = .{
                .series_id = sid,
                .ts = ts_value.integer,
                .value = value,
                .tags_json = labels_json.value,
            };
            batch_len += 1;
            writes += 1;
        }
        try eng.ingestBatch(batch[0..batch_len]);
        for (batch[0..batch_len]) |item| eng.noteTags(item.series_id, labels_json.value);
        try eng.scheduleDerivedMetric(metric_value.string, labels_json.value);
        rows += 1;
    }

    var send_buffer: [256]u8 = undefined;
    var response = try req.respondStreaming(&send_buffer, .{
        .respond_options = .{ .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} },
    });
    errdefer response.end() catch {};
    var jw = std.json.Stringify{ .writer = &response.writer };
    try jw.beginObject();
    try jw.objectField("rows");
    try jw.write(rows);
    try jw.objectField("writes");
    try jw.write(writes);
    try jw.endObject();
    try response.end();
}

fn handleMarketQuery(alloc: std.mem.Allocator, eng: *Engine, req: *std.http.Server.Request) !void {
    var parsed = readJsonBody(alloc, req, 64 * 1024) catch |err| switch (err) {
        error.LengthRequired => return respondJsonError(alloc, req, .length_required, "length_required", "length required"),
        error.PayloadTooLarge => return respondJsonError(alloc, req, .payload_too_large, "payload_too_large", "payload too large"),
        else => return respondJsonError(alloc, req, .bad_request, "invalid_json", "invalid json"),
    };
    defer parsed.deinit(alloc);
    if (parsed.parsed.value != .object) return respondJsonError(alloc, req, .bad_request, "invalid_market_query", "invalid market query");
    const obj = parsed.parsed.value.object;
    const metric = jsonRequiredString(obj, "metric") orelse return respondJsonError(alloc, req, .bad_request, "missing_metric", "missing metric");
    const labels = obj.get("labels") orelse return respondJsonError(alloc, req, .bad_request, "missing_labels", "missing labels");
    if (labels != .object) return respondJsonError(alloc, req, .bad_request, "invalid_labels", "invalid labels");
    const start_ts_ns = jsonRequiredInt(obj, "start_ts_ns") orelse return respondJsonError(alloc, req, .bad_request, "missing_start_ts_ns", "missing start_ts_ns");
    const end_ts_ns = jsonRequiredInt(obj, "end_ts_ns") orelse return respondJsonError(alloc, req, .bad_request, "missing_end_ts_ns", "missing end_ts_ns");
    const revision = if (obj.get("revision")) |value| if (value == .string) value.string else null else null;
    const requested_columns = if (obj.get("columns")) |value| try jsonStringArrayConst(alloc, value) else null;
    defer if (requested_columns) |columns| alloc.free(columns);

    const rows = try queryMarketRows(alloc, eng, metric, labels, start_ts_ns, end_ts_ns, requested_columns, revision);
    defer freeMarketQueryRows(alloc, rows);
    const revision_label = try resolvedRevisionLabel(alloc, eng, revision);
    defer alloc.free(revision_label);

    var send_buffer: [1024]u8 = undefined;
    var response = try req.respondStreaming(&send_buffer, .{
        .respond_options = .{ .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} },
    });
    errdefer response.end() catch {};
    var jw = std.json.Stringify{ .writer = &response.writer };
    try jw.beginObject();
    try jw.objectField("metric");
    try jw.write(metric);
    try jw.objectField("data_revision");
    try jw.write(revision_label);
    try jw.objectField("rows");
    try jw.beginArray();
    for (rows) |row| try writeMarketQueryRow(&jw, row);
    try jw.endArray();
    try jw.endObject();
    try response.end();
}

fn handleSignalHistory(alloc: std.mem.Allocator, eng: *Engine, req: *std.http.Server.Request, query: []const u8) !void {
    const name = queryParam(query, "name") orelse return respondJsonError(alloc, req, .bad_request, "missing_name", "missing name");
    const start_ts_ns = if (queryParam(query, "start_ts_ns")) |value| std.fmt.parseInt(i64, value, 10) catch return respondJsonError(alloc, req, .bad_request, "invalid_start_ts_ns", "invalid start_ts_ns") else std.math.minInt(i64);
    const end_ts_ns = if (queryParam(query, "end_ts_ns")) |value| std.fmt.parseInt(i64, value, 10) catch return respondJsonError(alloc, req, .bad_request, "invalid_end_ts_ns", "invalid end_ts_ns") else std.math.maxInt(i64);
    const revision = queryParam(query, "revision");
    var signal = try eng.latestSignal(name) orelse return respondJsonError(alloc, req, .not_found, "signal_not_found", "signal not found");
    defer signal.deinit(alloc);
    const rows = try querySignalHistoryRows(alloc, eng, signal.id, signal.version, start_ts_ns, end_ts_ns, revision);
    defer freeSignalHistoryRows(alloc, rows);

    var send_buffer: [1024]u8 = undefined;
    var response = try req.respondStreaming(&send_buffer, .{
        .respond_options = .{ .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} },
    });
    errdefer response.end() catch {};
    var jw = std.json.Stringify{ .writer = &response.writer };
    try jw.beginObject();
    try jw.objectField("name");
    try jw.write(signal.id);
    try jw.objectField("definition_version");
    try jw.write(signal.version);
    try jw.objectField("rows");
    try jw.beginArray();
    for (rows) |row| try writeSignalHistoryRow(&jw, row);
    try jw.endArray();
    try jw.endObject();
    try response.end();
}

fn handleAnalysisCatalog(req: *std.http.Server.Request) !void {
    var send_buffer: [768]u8 = undefined;
    var response = try req.respondStreaming(&send_buffer, .{
        .respond_options = .{ .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} },
    });
    errdefer response.end() catch {};
    var jw = std.json.Stringify{ .writer = &response.writer };
    try jw.beginObject();
    try jw.objectField("group_by");
    try jw.write(&[_][]const u8{ "none", "venue", "symbol" });
    try jw.objectField("execution_side");
    try jw.write(&[_][]const u8{ "auto", "buy", "sell" });
    try jw.objectField("entry_price_source");
    try jw.write(&[_][]const u8{ "trade", "mid" });
    try jw.objectField("benchmark_source");
    try jw.write(&[_][]const u8{ "mid", "trade" });
    try jw.endObject();
    try response.end();
}

fn handleCasRefs(alloc: std.mem.Allocator, eng: *Engine, req: *std.http.Server.Request) !void {
    var cas = eng.cas orelse return respondJsonError(alloc, req, .not_found, "cas_disabled", "cas disabled");
    const refs = try cas.listRefs();
    defer {
        for (refs) |*entry| entry.deinit(alloc);
        alloc.free(refs);
    }
    var send_buffer: [1024]u8 = undefined;
    var response = try req.respondStreaming(&send_buffer, .{
        .respond_options = .{ .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} },
    });
    errdefer response.end() catch {};
    var jw = std.json.Stringify{ .writer = &response.writer };
    try jw.beginArray();
    for (refs) |entry| {
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(entry.name);
        try jw.objectField("id");
        const hex = entry.id.toHex();
        try jw.write(hex[0..]);
        try jw.endObject();
    }
    try jw.endArray();
    try response.end();
}

fn handleCasCommits(alloc: std.mem.Allocator, eng: *Engine, req: *std.http.Server.Request, query: []const u8) !void {
    return try handleCasLog(alloc, eng, req, query);
}

fn handleCasLog(alloc: std.mem.Allocator, eng: *Engine, req: *std.http.Server.Request, query: []const u8) !void {
    var cas = eng.cas orelse return respondJsonError(alloc, req, .not_found, "cas_disabled", "cas disabled");
    const spec = queryParam(query, "spec") orelse cas_mod.main_ref;
    const limit = if (queryParam(query, "limit")) |value| std.fmt.parseInt(usize, value, 10) catch 32 else 32;
    const entries = try cas.loadLog(spec, limit);
    defer {
        for (entries) |*entry| entry.deinit(alloc);
        alloc.free(entries);
    }

    var send_buffer: [1024]u8 = undefined;
    var response = try req.respondStreaming(&send_buffer, .{
        .respond_options = .{ .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} },
    });
    errdefer response.end() catch {};
    var jw = std.json.Stringify{ .writer = &response.writer };
    try jw.beginArray();
    for (entries) |entry| {
        try jw.beginObject();
        try jw.objectField("commit_id");
        const hex = entry.commit_id.toHex();
        try jw.write(hex[0..]);
        try jw.objectField("created_at_ms");
        try jw.write(entry.created_at_ms);
        try jw.objectField("reason");
        try jw.write(entry.reason);
        try jw.objectField("parent_count");
        try jw.write(entry.parent_count);
        try jw.endObject();
    }
    try jw.endArray();
    try response.end();
}

fn handleCasDiff(alloc: std.mem.Allocator, eng: *Engine, req: *std.http.Server.Request, query: []const u8) !void {
    var cas = eng.cas orelse return respondJsonError(alloc, req, .not_found, "cas_disabled", "cas disabled");
    const lhs = queryParam(query, "lhs") orelse return respondJsonError(alloc, req, .bad_request, "missing_lhs", "missing lhs");
    const rhs = queryParam(query, "rhs") orelse return respondJsonError(alloc, req, .bad_request, "missing_rhs", "missing rhs");
    const diff = try cas.diffSnapshots(lhs, rhs);

    var send_buffer: [512]u8 = undefined;
    var response = try req.respondStreaming(&send_buffer, .{
        .respond_options = .{ .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} },
    });
    errdefer response.end() catch {};
    var jw = std.json.Stringify{ .writer = &response.writer };
    try jw.beginObject();
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
    try response.end();
}

fn handleSignalSubscribe(alloc: std.mem.Allocator, eng: *Engine, req: *std.http.Server.Request, query: []const u8) !void {
    const name = queryParam(query, "name") orelse return respondJsonError(alloc, req, .bad_request, "missing_name", "missing name");
    var signal = try eng.latestSignal(name) orelse return respondJsonError(alloc, req, .not_found, "signal_not_found", "signal not found");
    defer signal.deinit(alloc);
    const after_sequence = if (findHeader(req, "last-event-id")) |value|
        eventIdSequence(value)
    else if (queryParam(query, "after_sequence")) |value|
        std.fmt.parseInt(u64, value, 10) catch 0
    else
        0;

    var send_buffer: [1024]u8 = undefined;
    var response = try req.respondStreaming(&send_buffer, .{
        .respond_options = .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/event-stream" },
                .{ .name = "Cache-Control", .value = "no-cache" },
            },
        },
    });
    errdefer response.end() catch {};

    var last_seen_sequence = after_sequence;
    var last_epoch = eng.currentSignalEventEpoch();
    while (true) {
        const events = eng.listSignalEvents(signal.id, signal.version, last_seen_sequence, null, null, 512) catch |err| switch (err) {
            else => {
                std.log.warn("signal subscribe event lookup failed: {s}", .{@errorName(err)});
                break;
            },
        };
        defer {
            for (events) |*event| event.deinit(alloc);
            alloc.free(events);
        }

        if (events.len != 0) {
            for (events) |event| {
                try response.writer.writeAll("id: ");
                try response.writer.writeAll(event.event_id);
                try response.writer.writeAll("\n");
                try response.writer.writeAll("event: signal\n");
                try response.writer.writeAll("data: ");
                try writeSignalEventPayload(&response.writer, event);
                try response.writer.writeAll("\n\n");
                last_seen_sequence = event.sequence;
            }
            last_epoch = eng.currentSignalEventEpoch();
            continue;
        }
        _ = eng.waitForSignalEvents(last_epoch, std.time.ns_per_s);
        const next_epoch = eng.currentSignalEventEpoch();
        if (next_epoch == last_epoch) try response.writer.writeAll(": keep-alive\n\n");
        last_epoch = next_epoch;
    }
    try response.end();
}

fn eventIdSequence(event_id: []const u8) u64 {
    var parts = std.mem.splitScalar(u8, event_id, '/');
    _ = parts.next() orelse return 0;
    _ = parts.next() orelse return 0;
    _ = parts.next() orelse return 0;
    const sequence_text = parts.next() orelse return 0;
    return std.fmt.parseInt(u64, sequence_text, 10) catch 0;
}

fn handleAnalysisMarkout(alloc: std.mem.Allocator, eng: *Engine, req: *std.http.Server.Request) !void {
    var parsed = readJsonBody(alloc, req, 64 * 1024) catch |err| switch (err) {
        error.LengthRequired => return respondJsonError(alloc, req, .length_required, "length_required", "length required"),
        error.PayloadTooLarge => return respondJsonError(alloc, req, .payload_too_large, "payload_too_large", "payload too large"),
        else => return respondJsonError(alloc, req, .bad_request, "invalid_json", "invalid json"),
    };
    defer parsed.deinit(alloc);
    const obj = parsed.parsed.value.object;
    const symbol = jsonRequiredString(obj, "symbol") orelse return respondJsonError(alloc, req, .bad_request, "missing_symbol", "missing symbol");
    const venue = jsonRequiredString(obj, "venue") orelse return respondJsonError(alloc, req, .bad_request, "missing_venue", "missing venue");
    const start_ts = jsonRequiredInt(obj, "start_ts_ns") orelse jsonRequiredInt(obj, "start") orelse return respondJsonError(alloc, req, .bad_request, "missing_start_ts_ns", "missing start_ts_ns");
    const end_ts = jsonRequiredInt(obj, "end_ts_ns") orelse jsonRequiredInt(obj, "end") orelse return respondJsonError(alloc, req, .bad_request, "missing_end_ts_ns", "missing end_ts_ns");
    const single_horizon_ns = if (obj.get("horizon_ns")) |value| if (value == .integer) value.integer else return respondJsonError(alloc, req, .bad_request, "invalid_horizon_ns", "invalid horizon_ns") else null;
    const horizons_ns = if (obj.get("horizons_ns")) |value|
        try jsonIntArray(alloc, value)
    else if (single_horizon_ns) |value|
        try alloc.dupe(i64, &.{value})
    else
        return respondJsonError(alloc, req, .bad_request, "missing_horizon_ns", "missing horizon_ns");
    defer alloc.free(horizons_ns);
    const revision = if (obj.get("revision")) |value| if (value == .string) value.string else null else null;
    const signal_name = if (obj.get("signal_name")) |value| if (value == .string) value.string else null else null;
    const bar_policy_id = if (obj.get("bar_policy_id")) |value| if (value == .string) value.string else null else null;
    const group_by = if (obj.get("group_by")) |value|
        if (value == .string and (std.mem.eql(u8, value.string, "none") or std.mem.eql(u8, value.string, "venue") or std.mem.eql(u8, value.string, "symbol")))
            value.string
        else
            return respondJsonError(alloc, req, .bad_request, "invalid_group_by", "invalid group_by")
    else
        "none";
    const labels_json = try canonicalLabelsForMarket(alloc, symbol, venue, null, null);
    defer alloc.free(labels_json);

    var max_horizon: i64 = 0;
    for (horizons_ns) |horizon| {
        if (horizon > max_horizon) max_horizon = horizon;
    }
    const prices = try queryMetricPoints(alloc, eng, "market.trade.price", labels_json, start_ts, end_ts + max_horizon, revision);
    defer alloc.free(prices);
    var signal_version: ?u32 = null;
    const signal_rows = if (signal_name) |signal_id| blk: {
        var signal = try eng.latestSignal(signal_id) orelse return respondJsonError(alloc, req, .not_found, "signal_not_found", "signal not found");
        defer signal.deinit(alloc);
        signal_version = signal.version;
        break :blk try querySignalHistoryRows(alloc, eng, signal_id, signal.version, start_ts, end_ts, revision);
    } else try alloc.alloc(SignalHistoryRow, 0);
    defer if (signal_name != null) freeSignalHistoryRows(alloc, signal_rows) else alloc.free(signal_rows);

    var send_buffer: [1024]u8 = undefined;
    var response = try req.respondStreaming(&send_buffer, .{
        .respond_options = .{ .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} },
    });
    errdefer response.end() catch {};
    var jw = std.json.Stringify{ .writer = &response.writer };
    try jw.beginObject();
    try jw.objectField("analysis");
    try jw.write("markout");
    try jw.objectField("data_revision");
    const revision_label = try resolvedRevisionLabel(alloc, eng, revision);
    defer alloc.free(revision_label);
    try jw.write(revision_label);
    try jw.objectField("group_by");
    try jw.write(group_by);
    try jw.objectField("definition_refs");
    try jw.beginArray();
    if (signal_name) |value| {
        try jw.beginObject();
        try jw.objectField("kind");
        try jw.write("signal");
        try jw.objectField("id");
        try jw.write(value);
        try jw.objectField("version");
        try jw.write(signal_version.?);
        try jw.endObject();
    }
    if (bar_policy_id) |value| {
        var policy = eng.latestBarPolicy(value) orelse return respondJsonError(alloc, req, .not_found, "bar_policy_not_found", "bar policy not found");
        defer policy.deinit(alloc);
        try jw.beginObject();
        try jw.objectField("kind");
        try jw.write("bar_policy");
        try jw.objectField("id");
        try jw.write(value);
        try jw.objectField("version");
        try jw.write(policy.version);
        try jw.endObject();
    }
    try jw.endArray();
    if (bar_policy_id) |value| {
        try jw.objectField("bar_policy_id");
        try jw.write(value);
    }
    try jw.objectField("groups");
    try jw.beginArray();
    try jw.beginObject();
    try jw.objectField("key");
    try jw.beginObject();
    try jw.objectField("symbol");
    try jw.write(symbol);
    try jw.objectField("venue");
    try jw.write(venue);
    try jw.endObject();
    try jw.objectField("horizons");
    try jw.beginArray();
    for (horizons_ns) |horizon_ns| {
        var count: usize = 0;
        var total: f64 = 0;
        var dropped: usize = 0;
        var future_idx: usize = 0;
        if (signal_name) |_| {
            for (signal_rows) |row| {
                if (row.ts_ns < start_ts or row.ts_ns > end_ts) continue;
                while (future_idx < prices.len and prices[future_idx].ts < row.ts_ns + horizon_ns) : (future_idx += 1) {}
                if (future_idx >= prices.len) {
                    dropped += 1;
                    continue;
                }
                const entry_idx = findPriceIndexAtOrAfter(prices, row.ts_ns) orelse {
                    dropped += 1;
                    continue;
                };
                total += prices[future_idx].value - prices[entry_idx].value;
                count += 1;
            }
        } else {
            for (prices) |point| {
                if (point.ts < start_ts or point.ts > end_ts) continue;
                while (future_idx < prices.len and prices[future_idx].ts < point.ts + horizon_ns) : (future_idx += 1) {}
                if (future_idx >= prices.len) {
                    dropped += 1;
                    continue;
                }
                total += prices[future_idx].value - point.value;
                count += 1;
            }
        }
        try jw.beginObject();
        try jw.objectField("horizon_ns");
        try jw.write(horizon_ns);
        try jw.objectField("sample_count");
        try jw.write(count);
        try jw.objectField("dropped_samples");
        try jw.write(dropped);
        try jw.objectField("dropped_reasons");
        try jw.beginArray();
        if (dropped != 0) try jw.write("missing_future_price");
        try jw.endArray();
        try jw.objectField("value");
        if (count != 0) try jw.write(total / @as(f64, @floatFromInt(count))) else try jw.write(null);
        try jw.endObject();
    }
    try jw.endArray();
    try jw.endObject();
    try jw.endArray();
    try jw.endObject();
    try response.end();
}

fn handleAnalysisSlippage(alloc: std.mem.Allocator, eng: *Engine, req: *std.http.Server.Request) !void {
    var parsed = readJsonBody(alloc, req, 64 * 1024) catch |err| switch (err) {
        error.LengthRequired => return respondJsonError(alloc, req, .length_required, "length_required", "length required"),
        error.PayloadTooLarge => return respondJsonError(alloc, req, .payload_too_large, "payload_too_large", "payload too large"),
        else => return respondJsonError(alloc, req, .bad_request, "invalid_json", "invalid json"),
    };
    defer parsed.deinit(alloc);
    const obj = parsed.parsed.value.object;
    const symbol = jsonRequiredString(obj, "symbol") orelse return respondJsonError(alloc, req, .bad_request, "missing_symbol", "missing symbol");
    const venue = jsonRequiredString(obj, "venue") orelse return respondJsonError(alloc, req, .bad_request, "missing_venue", "missing venue");
    const start_ts = jsonRequiredInt(obj, "start_ts_ns") orelse jsonRequiredInt(obj, "start") orelse return respondJsonError(alloc, req, .bad_request, "missing_start_ts_ns", "missing start_ts_ns");
    const end_ts = jsonRequiredInt(obj, "end_ts_ns") orelse jsonRequiredInt(obj, "end") orelse return respondJsonError(alloc, req, .bad_request, "missing_end_ts_ns", "missing end_ts_ns");
    const revision = if (obj.get("revision")) |value| if (value == .string) value.string else null else null;
    const execution_side = if (obj.get("execution_side")) |value| if (value == .string) value.string else "auto" else "auto";
    const entry_price_source = if (obj.get("entry_price_source")) |value| if (value == .string) value.string else "trade" else "trade";
    const benchmark_source = if (obj.get("benchmark_source")) |value| if (value == .string) value.string else "mid" else "mid";
    const group_by = if (obj.get("group_by")) |value|
        if (value == .string and (std.mem.eql(u8, value.string, "none") or std.mem.eql(u8, value.string, "venue") or std.mem.eql(u8, value.string, "symbol")))
            value.string
        else
            return respondJsonError(alloc, req, .bad_request, "invalid_group_by", "invalid group_by")
    else
        "none";
    const labels_json = try canonicalLabelsForMarket(alloc, symbol, venue, null, null);
    defer alloc.free(labels_json);

    const trades = try queryMetricPoints(alloc, eng, "market.trade.price", labels_json, start_ts, end_ts, revision);
    defer alloc.free(trades);
    const bids = try queryMetricPoints(alloc, eng, "market.quote.bid", labels_json, start_ts, end_ts, revision);
    defer alloc.free(bids);
    const asks = try queryMetricPoints(alloc, eng, "market.quote.ask", labels_json, start_ts, end_ts, revision);
    defer alloc.free(asks);

    var bid_idx: usize = 0;
    var ask_idx: usize = 0;
    var signed_total: f64 = 0;
    var abs_total: f64 = 0;
    var spread_capture_total: f64 = 0;
    var count: usize = 0;
    var dropped_samples: usize = 0;
    for (trades) |trade| {
        while (bid_idx + 1 < bids.len and bids[bid_idx + 1].ts <= trade.ts) : (bid_idx += 1) {}
        while (ask_idx + 1 < asks.len and asks[ask_idx + 1].ts <= trade.ts) : (ask_idx += 1) {}
        if (bids.len == 0 or asks.len == 0) {
            dropped_samples += 1;
            break;
        }
        const mid = (bids[bid_idx].value + asks[ask_idx].value) / 2.0;
        const entry_price = if (std.mem.eql(u8, entry_price_source, "trade")) trade.value else mid;
        const benchmark_price = if (std.mem.eql(u8, benchmark_source, "mid")) mid else trade.value;
        var slip = entry_price - benchmark_price;
        if (std.mem.eql(u8, execution_side, "sell")) slip = -slip;
        signed_total += slip;
        abs_total += @abs(slip);
        spread_capture_total += -slip;
        count += 1;
    }

    var send_buffer: [512]u8 = undefined;
    var response = try req.respondStreaming(&send_buffer, .{
        .respond_options = .{ .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} },
    });
    errdefer response.end() catch {};
    var jw = std.json.Stringify{ .writer = &response.writer };
    try jw.beginObject();
    try jw.objectField("analysis");
    try jw.write("slippage");
    try jw.objectField("data_revision");
    const revision_label = try resolvedRevisionLabel(alloc, eng, revision);
    defer alloc.free(revision_label);
    try jw.write(revision_label);
    try jw.objectField("group_by");
    try jw.write(group_by);
    try jw.objectField("definition_refs");
    try jw.beginArray();
    try jw.endArray();
    try jw.objectField("groups");
    try jw.beginArray();
    try jw.beginObject();
    try jw.objectField("key");
    try jw.beginObject();
    try jw.objectField("symbol");
    try jw.write(symbol);
    try jw.objectField("venue");
    try jw.write(venue);
    try jw.endObject();
    try jw.objectField("sample_count");
    try jw.write(count);
    try jw.objectField("dropped_samples");
    try jw.write(dropped_samples);
    try jw.objectField("dropped_reasons");
    try jw.beginArray();
    if (dropped_samples != 0) try jw.write("missing_quote_benchmark");
    try jw.endArray();
    try jw.objectField("execution_side");
    try jw.write(execution_side);
    try jw.objectField("entry_price_source");
    try jw.write(entry_price_source);
    try jw.objectField("benchmark_source");
    try jw.write(benchmark_source);
    try jw.objectField("signed_avg");
    if (count != 0) try jw.write(signed_total / @as(f64, @floatFromInt(count))) else try jw.write(null);
    try jw.objectField("abs_avg");
    if (count != 0) try jw.write(abs_total / @as(f64, @floatFromInt(count))) else try jw.write(null);
    try jw.objectField("spread_capture_avg");
    if (count != 0) try jw.write(spread_capture_total / @as(f64, @floatFromInt(count))) else try jw.write(null);
    try jw.endObject();
    try jw.endArray();
    try jw.endObject();
    try response.end();
}

fn handleAnalysisQuoteQuality(alloc: std.mem.Allocator, eng: *Engine, req: *std.http.Server.Request) !void {
    var parsed = readJsonBody(alloc, req, 64 * 1024) catch |err| switch (err) {
        error.LengthRequired => return respondJsonError(alloc, req, .length_required, "length_required", "length required"),
        error.PayloadTooLarge => return respondJsonError(alloc, req, .payload_too_large, "payload_too_large", "payload too large"),
        else => return respondJsonError(alloc, req, .bad_request, "invalid_json", "invalid json"),
    };
    defer parsed.deinit(alloc);
    const obj = parsed.parsed.value.object;
    const symbol = jsonRequiredString(obj, "symbol") orelse return respondJsonError(alloc, req, .bad_request, "missing_symbol", "missing symbol");
    const venue = jsonRequiredString(obj, "venue") orelse return respondJsonError(alloc, req, .bad_request, "missing_venue", "missing venue");
    const start_ts = jsonRequiredInt(obj, "start_ts_ns") orelse jsonRequiredInt(obj, "start") orelse return respondJsonError(alloc, req, .bad_request, "missing_start_ts_ns", "missing start_ts_ns");
    const end_ts = jsonRequiredInt(obj, "end_ts_ns") orelse jsonRequiredInt(obj, "end") orelse return respondJsonError(alloc, req, .bad_request, "missing_end_ts_ns", "missing end_ts_ns");
    const stale_after_ns = if (obj.get("stale_after_ns")) |value| if (value == .integer) value.integer else 5 * std.time.ns_per_s else 5 * std.time.ns_per_s;
    const revision = if (obj.get("revision")) |value| if (value == .string) value.string else null else null;
    const group_by = if (obj.get("group_by")) |value|
        if (value == .string and (std.mem.eql(u8, value.string, "none") or std.mem.eql(u8, value.string, "venue") or std.mem.eql(u8, value.string, "symbol")))
            value.string
        else
            return respondJsonError(alloc, req, .bad_request, "invalid_group_by", "invalid group_by")
    else
        "none";
    const labels_json = try canonicalLabelsForMarket(alloc, symbol, venue, null, null);
    defer alloc.free(labels_json);

    const bids = try queryMetricPoints(alloc, eng, "market.quote.bid", labels_json, start_ts, end_ts, revision);
    defer alloc.free(bids);
    const asks = try queryMetricPoints(alloc, eng, "market.quote.ask", labels_json, start_ts, end_ts, revision);
    defer alloc.free(asks);
    const paired = @min(bids.len, asks.len);
    var avg_spread_total: f64 = 0;
    var stale_count: usize = 0;
    var crossed_count: usize = 0;
    var locked_count: usize = 0;
    var dropped_samples: usize = 0;
    for (0..paired) |idx| {
        if (bids[idx].ts != asks[idx].ts) {
            dropped_samples += 1;
            continue;
        }
        const spread = asks[idx].value - bids[idx].value;
        avg_spread_total += spread;
        if (spread < 0) crossed_count += 1;
        if (spread == 0) locked_count += 1;
        if (idx > 0 and bids[idx].value == bids[idx - 1].value and asks[idx].value == asks[idx - 1].value and (bids[idx].ts - bids[idx - 1].ts) > stale_after_ns) {
            stale_count += 1;
        }
    }
    var send_buffer: [768]u8 = undefined;
    var response = try req.respondStreaming(&send_buffer, .{
        .respond_options = .{ .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} },
    });
    errdefer response.end() catch {};
    var jw = std.json.Stringify{ .writer = &response.writer };
    try jw.beginObject();
    try jw.objectField("analysis");
    try jw.write("quote-quality");
    try jw.objectField("data_revision");
    const revision_label = try resolvedRevisionLabel(alloc, eng, revision);
    defer alloc.free(revision_label);
    try jw.write(revision_label);
    try jw.objectField("group_by");
    try jw.write(group_by);
    try jw.objectField("definition_refs");
    try jw.beginArray();
    try jw.endArray();
    try jw.objectField("groups");
    try jw.beginArray();
    try jw.beginObject();
    try jw.objectField("key");
    try jw.beginObject();
    try jw.objectField("symbol");
    try jw.write(symbol);
    try jw.objectField("venue");
    try jw.write(venue);
    try jw.endObject();
    try jw.objectField("sample_count");
    try jw.write(paired);
    try jw.objectField("dropped_samples");
    try jw.write(dropped_samples);
    try jw.objectField("dropped_reasons");
    try jw.beginArray();
    if (dropped_samples != 0) try jw.write("unpaired_quote_samples");
    try jw.endArray();
    try jw.objectField("avg_spread");
    if (paired != 0) try jw.write(avg_spread_total / @as(f64, @floatFromInt(paired))) else try jw.write(null);
    try jw.objectField("stale_count");
    try jw.write(stale_count);
    try jw.objectField("crossed_count");
    try jw.write(crossed_count);
    try jw.objectField("locked_count");
    try jw.write(locked_count);
    try jw.endObject();
    try jw.endArray();
    try jw.endObject();
    try response.end();
}

fn jsonStringArrayConst(alloc: std.mem.Allocator, value: std.json.Value) ![][]const u8 {
    if (value != .array) return error.InvalidCharacter;
    const out = try alloc.alloc([]const u8, value.array.items.len);
    errdefer alloc.free(out);
    for (value.array.items, 0..) |item, idx| {
        if (item != .string) return error.InvalidCharacter;
        out[idx] = item.string;
    }
    return out;
}

fn stringifyJsonValue(alloc: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var buffer = std.array_list.Managed(u8).init(alloc);
    errdefer buffer.deinit();
    var writer = buffer.writer();
    var tmp: [512]u8 = undefined;
    var adapter = writer.adaptToNewApi(&tmp);
    var iface = &adapter.new_interface;
    var jw = std.json.Stringify{ .writer = iface };
    try jw.write(value);
    try iface.flush();
    if (adapter.err) |err| return err;
    return try buffer.toOwnedSlice();
}

fn marketLabelsSatisfySchema(labels_value: std.json.Value, schema: market_catalog_mod.MarketSchema) bool {
    if (labels_value != .object) return false;
    for (schema.required_labels) |label| {
        const value = labels_value.object.get(label) orelse return false;
        if (value != .string) return false;
    }
    return true;
}

fn marketColumnsMatchSchema(columns_value: std.json.Value, schema: market_catalog_mod.MarketSchema) bool {
    if (columns_value != .object) return false;
    if (columns_value.object.count() != schema.ordered_columns.len) return false;
    for (schema.ordered_columns) |column| {
        const value = columns_value.object.get(column) orelse return false;
        if (value != .integer and value != .float) return false;
    }
    return true;
}

fn queryParam(query: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], name)) return pair[eq + 1 ..];
    }
    return null;
}

fn jsonRequiredString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    if (obj.get(key)) |value| if (value == .string) return value.string;
    return null;
}

fn jsonRequiredInt(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    if (obj.get(key)) |value| if (value == .integer) return value.integer;
    return null;
}

fn jsonIntArray(alloc: std.mem.Allocator, value: std.json.Value) ![]i64 {
    if (value != .array) return error.InvalidCharacter;
    const out = try alloc.alloc(i64, value.array.items.len);
    errdefer alloc.free(out);
    for (value.array.items, 0..) |item, idx| {
        if (item != .integer) return error.InvalidCharacter;
        out[idx] = item.integer;
    }
    return out;
}

const QuerySeriesDescriptor = struct {
    series_id: types.SeriesId,
    metric: []u8,
    labels_json: []u8,

    fn deinit(self: *QuerySeriesDescriptor, alloc: std.mem.Allocator) void {
        alloc.free(self.metric);
        alloc.free(self.labels_json);
        self.* = undefined;
    }
};

const ClientLabelInfo = struct {
    labels_json: []u8,
    data_revision: ?[]u8 = null,
    definition_id: ?[]u8 = null,
    definition_version: ?[]u8 = null,

    fn deinit(self: *ClientLabelInfo, alloc: std.mem.Allocator) void {
        alloc.free(self.labels_json);
        if (self.data_revision) |value| alloc.free(value);
        if (self.definition_id) |value| alloc.free(value);
        if (self.definition_version) |value| alloc.free(value);
        self.* = undefined;
    }
};

const MarketQueryRow = struct {
    ts_ns: i64,
    columns_json: []u8,
    labels_json: []u8,
    data_revision: []u8,

    fn deinit(self: *MarketQueryRow, alloc: std.mem.Allocator) void {
        alloc.free(self.columns_json);
        alloc.free(self.labels_json);
        alloc.free(self.data_revision);
        self.* = undefined;
    }
};

const SignalHistoryRow = struct {
    ts_ns: i64,
    value: f64,
    labels_json: []u8,
    data_revision: []u8,
    definition_id: []u8,
    definition_version: u32,

    fn deinit(self: *SignalHistoryRow, alloc: std.mem.Allocator) void {
        alloc.free(self.labels_json);
        alloc.free(self.data_revision);
        alloc.free(self.definition_id);
        self.* = undefined;
    }
};

fn freeMarketQueryRows(alloc: std.mem.Allocator, rows: []MarketQueryRow) void {
    for (rows) |*row| row.deinit(alloc);
    alloc.free(rows);
}

fn freeSignalHistoryRows(alloc: std.mem.Allocator, rows: []SignalHistoryRow) void {
    for (rows) |*row| row.deinit(alloc);
    alloc.free(rows);
}

fn writeMarketQueryRow(jw: *std.json.Stringify, row: MarketQueryRow) !void {
    try jw.beginObject();
    try jw.objectField("ts_ns");
    try jw.write(row.ts_ns);
    try jw.objectField("columns");
    try writeCanonicalJsonObject(jw, row.columns_json);
    try jw.objectField("labels");
    try writeCanonicalJsonObject(jw, row.labels_json);
    try jw.objectField("data_revision");
    try jw.write(row.data_revision);
    try jw.endObject();
}

fn writeSignalHistoryRow(jw: *std.json.Stringify, row: SignalHistoryRow) !void {
    try jw.beginObject();
    try jw.objectField("ts_ns");
    try jw.write(row.ts_ns);
    try jw.objectField("value");
    try jw.write(row.value);
    try jw.objectField("labels");
    try writeCanonicalJsonObject(jw, row.labels_json);
    try jw.objectField("data_revision");
    try jw.write(row.data_revision);
    try jw.objectField("definition_id");
    try jw.write(row.definition_id);
    try jw.objectField("definition_version");
    try jw.write(row.definition_version);
    try jw.endObject();
}

fn writeSignalEventPayload(writer: anytype, event: anytype) !void {
    var jw = std.json.Stringify{ .writer = writer };
    try jw.beginObject();
    try jw.objectField("event_id");
    try jw.write(event.event_id);
    try jw.objectField("definition_id");
    try jw.write(event.definition_id);
    try jw.objectField("definition_version");
    try jw.write(event.definition_version);
    try jw.objectField("data_revision");
    try jw.write(event.data_revision);
    try jw.objectField("labels");
    var info = try extractClientLabelInfo(std.heap.c_allocator, event.labels_json);
    defer info.deinit(std.heap.c_allocator);
    try writeCanonicalJsonObject(&jw, info.labels_json);
    try jw.objectField("ts_ns");
    try jw.write(event.ts_ns);
    try jw.objectField("value");
    try jw.write(event.value);
    try jw.endObject();
}

fn queryMarketRows(
    alloc: std.mem.Allocator,
    eng: *Engine,
    metric: []const u8,
    labels_value: std.json.Value,
    start_ts_ns: i64,
    end_ts_ns: i64,
    requested_columns: ?[][]const u8,
    revision: ?[]const u8,
) ![]MarketQueryRow {
    var schema = eng.marketSchema(metric) orelse return error.MarketSchemaNotFound;
    defer schema.deinit(alloc);

    const columns = if (requested_columns) |value| blk: {
        for (value) |column| {
            var found = false;
            for (schema.ordered_columns) |allowed| {
                if (std.mem.eql(u8, column, allowed)) {
                    found = true;
                    break;
                }
            }
            if (!found) return error.InvalidMarketColumns;
        }
        break :blk value;
    } else blk: {
        var all_columns = try alloc.alloc([]const u8, schema.ordered_columns.len);
        for (schema.ordered_columns, 0..) |column, idx| all_columns[idx] = column;
        break :blk all_columns;
    };
    defer if (requested_columns == null) alloc.free(columns);

    var snapshot_index: ?cas_mod.SnapshotIndex = null;
    if (revision) |spec| {
        var cas = eng.cas orelse return error.CasDisabled;
        const snapshot = try cas.loadSnapshotForSpec(spec);
        snapshot_index = cas_mod.SnapshotIndex.init(alloc, &cas.store, snapshot);
    }
    defer if (snapshot_index) |*index| index.deinit();

    var descriptor_sets = try alloc.alloc([]QuerySeriesDescriptor, columns.len);
    defer {
        for (descriptor_sets) |set| {
            for (set) |*entry| entry.deinit(alloc);
            alloc.free(set);
        }
        alloc.free(descriptor_sets);
    }

    for (columns, 0..) |column, idx| {
        const metric_name = try std.fmt.allocPrint(alloc, "{s}.{s}", .{ metric, column });
        defer alloc.free(metric_name);
        descriptor_sets[idx] = try querySeriesDescriptors(alloc, eng, snapshot_index, metric_name, labels_value, revision);
    }
    if (descriptor_sets.len == 0 or descriptor_sets[0].len == 0) return try alloc.alloc(MarketQueryRow, 0);

    const default_revision = try resolvedRevisionLabel(alloc, eng, revision);
    defer alloc.free(default_revision);

    var rows = std.array_list.Managed(MarketQueryRow).init(alloc);
    errdefer freeMarketQueryRows(alloc, rows.items);
    for (descriptor_sets[0]) |anchor| {
        var info = try extractClientLabelInfo(alloc, anchor.labels_json);
        defer info.deinit(alloc);

        var series_ids = try alloc.alloc(types.SeriesId, columns.len);
        defer alloc.free(series_ids);
        series_ids[0] = anchor.series_id;
        var complete = true;
        for (columns[1..], 1..) |_, column_idx| {
            const match = findDescriptorByLabels(descriptor_sets[column_idx], anchor.labels_json) orelse {
                complete = false;
                break;
            };
            series_ids[column_idx] = match.series_id;
        }
        if (!complete) continue;

        var column_points = try alloc.alloc([]types.Point, columns.len);
        defer {
            for (column_points) |points| alloc.free(points);
            alloc.free(column_points);
        }
        for (series_ids, 0..) |sid, idx| {
            column_points[idx] = try queryPointsForSeriesId(alloc, eng, snapshot_index, sid, start_ts_ns, end_ts_ns);
        }
        if (column_points[0].len == 0) continue;

        var offsets = try alloc.alloc(usize, columns.len);
        defer alloc.free(offsets);
        @memset(offsets, 0);
        var values = try alloc.alloc(f64, columns.len);
        defer alloc.free(values);

        for (column_points[0]) |anchor_point| {
            values[0] = anchor_point.value;
            var row_complete = true;
            for (1..columns.len) |column_idx| {
                while (offsets[column_idx] < column_points[column_idx].len and column_points[column_idx][offsets[column_idx]].ts < anchor_point.ts) : (offsets[column_idx] += 1) {}
                if (offsets[column_idx] >= column_points[column_idx].len or column_points[column_idx][offsets[column_idx]].ts != anchor_point.ts) {
                    row_complete = false;
                    break;
                }
                values[column_idx] = column_points[column_idx][offsets[column_idx]].value;
            }
            if (!row_complete) continue;
            try rows.append(.{
                .ts_ns = anchor_point.ts,
                .columns_json = try buildColumnsJson(alloc, columns, values),
                .labels_json = try alloc.dupe(u8, info.labels_json),
                .data_revision = try alloc.dupe(u8, info.data_revision orelse default_revision),
            });
        }
    }
    std.sort.block(MarketQueryRow, rows.items, {}, struct {
        fn lessThan(_: void, lhs: MarketQueryRow, rhs: MarketQueryRow) bool {
            if (lhs.ts_ns != rhs.ts_ns) return lhs.ts_ns < rhs.ts_ns;
            return std.mem.lessThan(u8, lhs.labels_json, rhs.labels_json);
        }
    }.lessThan);
    return try rows.toOwnedSlice();
}

fn querySignalHistoryRows(
    alloc: std.mem.Allocator,
    eng: *Engine,
    definition_id: []const u8,
    definition_version: u32,
    start_ts_ns: i64,
    end_ts_ns: i64,
    revision: ?[]const u8,
) ![]SignalHistoryRow {
    const metric = try std.fmt.allocPrint(alloc, "_signal.{s}", .{definition_id});
    defer alloc.free(metric);

    var snapshot_index: ?cas_mod.SnapshotIndex = null;
    if (revision) |spec| {
        var cas = eng.cas orelse return error.CasDisabled;
        const snapshot = try cas.loadSnapshotForSpec(spec);
        snapshot_index = cas_mod.SnapshotIndex.init(alloc, &cas.store, snapshot);
    }
    defer if (snapshot_index) |*index| index.deinit();

    var all_labels = std.json.Value{ .object = std.json.ObjectMap.init(alloc) };
    defer all_labels.object.deinit();
    const descriptors = try querySeriesDescriptors(alloc, eng, snapshot_index, metric, all_labels, revision);
    defer {
        for (descriptors) |*entry| entry.deinit(alloc);
        alloc.free(descriptors);
    }

    const default_revision = try resolvedRevisionLabel(alloc, eng, revision);
    defer alloc.free(default_revision);

    var rows = std.array_list.Managed(SignalHistoryRow).init(alloc);
    errdefer freeSignalHistoryRows(alloc, rows.items);
    for (descriptors) |descriptor| {
        var info = try extractClientLabelInfo(alloc, descriptor.labels_json);
        defer info.deinit(alloc);
        const points = try queryPointsForSeriesId(alloc, eng, snapshot_index, descriptor.series_id, start_ts_ns, end_ts_ns);
        defer alloc.free(points);
        for (points) |point| {
            try rows.append(.{
                .ts_ns = point.ts,
                .value = point.value,
                .labels_json = try alloc.dupe(u8, info.labels_json),
                .data_revision = try alloc.dupe(u8, info.data_revision orelse default_revision),
                .definition_id = try alloc.dupe(u8, info.definition_id orelse definition_id),
                .definition_version = if (info.definition_version) |value| std.fmt.parseInt(u32, value, 10) catch definition_version else definition_version,
            });
        }
    }
    std.sort.block(SignalHistoryRow, rows.items, {}, struct {
        fn lessThan(_: void, lhs: SignalHistoryRow, rhs: SignalHistoryRow) bool {
            if (lhs.ts_ns != rhs.ts_ns) return lhs.ts_ns < rhs.ts_ns;
            return std.mem.lessThan(u8, lhs.labels_json, rhs.labels_json);
        }
    }.lessThan);
    return try rows.toOwnedSlice();
}

fn buildColumnsJson(alloc: std.mem.Allocator, columns: []const []const u8, values: []const f64) ![]u8 {
    var buffer = std.array_list.Managed(u8).init(alloc);
    errdefer buffer.deinit();
    var writer = buffer.writer();
    var tmp: [256]u8 = undefined;
    var adapter = writer.adaptToNewApi(&tmp);
    var iface = &adapter.new_interface;
    var jw = std.json.Stringify{ .writer = iface };
    try jw.beginObject();
    for (columns, 0..) |column, idx| {
        try jw.objectField(column);
        try jw.write(values[idx]);
    }
    try jw.endObject();
    try iface.flush();
    if (adapter.err) |err| return err;
    return try buffer.toOwnedSlice();
}

fn findDescriptorByLabels(descriptors: []const QuerySeriesDescriptor, labels_json: []const u8) ?QuerySeriesDescriptor {
    for (descriptors) |descriptor| {
        if (std.mem.eql(u8, descriptor.labels_json, labels_json)) return descriptor;
    }
    return null;
}

fn querySeriesDescriptors(
    alloc: std.mem.Allocator,
    eng: *Engine,
    snapshot_index: ?cas_mod.SnapshotIndex,
    metric: []const u8,
    labels_value: std.json.Value,
    revision: ?[]const u8,
) ![]QuerySeriesDescriptor {
    var descriptors = std.array_list.Managed(QuerySeriesDescriptor).init(alloc);
    errdefer {
        for (descriptors.items) |*entry| entry.deinit(alloc);
        descriptors.deinit();
    }

    if (snapshot_index) |index| {
        for (index.snapshot.series_catalog_snapshot.entries) |entry| {
            if (!std.mem.eql(u8, entry.series, metric)) continue;
            if (labels_value == .object and labels_value.object.count() != 0 and !(try descriptorMatchesLabels(entry.canonical_tags, labels_value, true))) continue;
            try descriptors.append(.{
                .series_id = entry.series_id,
                .metric = try alloc.dupe(u8, entry.series),
                .labels_json = try alloc.dupe(u8, entry.canonical_tags),
            });
        }
    } else {
        const live = try eng.seriesDescriptorsForMetric(alloc, metric, labels_value, true, null);
        defer alloc.free(live);
        for (live) |entry| {
            try descriptors.append(.{
                .series_id = entry.series_id,
                .metric = try alloc.dupe(u8, entry.metric),
                .labels_json = try alloc.dupe(u8, entry.labels_json),
            });
        }
    }

    const current_revision = if (revision) |value|
        try resolvedRevisionLabel(alloc, eng, value)
    else
        try resolvedRevisionLabel(alloc, eng, null);
    defer alloc.free(current_revision);

    var saw_revision = false;
    for (descriptors.items) |descriptor| {
        const revision_value = try labelValueFromJson(alloc, descriptor.labels_json, "data_revision");
        defer if (revision_value) |value| alloc.free(value);
        if (revision_value != null) {
            saw_revision = true;
            break;
        }
    }
    if (!saw_revision) return try descriptors.toOwnedSlice();

    var filtered = std.array_list.Managed(QuerySeriesDescriptor).init(alloc);
    errdefer {
        for (filtered.items) |*entry| entry.deinit(alloc);
        filtered.deinit();
    }
    for (descriptors.items) |*descriptor| {
        const revision_value = try labelValueFromJson(alloc, descriptor.labels_json, "data_revision");
        defer if (revision_value) |value| alloc.free(value);
        if (revision_value == null or !std.mem.eql(u8, revision_value.?, current_revision)) {
            descriptor.deinit(alloc);
            continue;
        }
        try filtered.append(descriptor.*);
        descriptor.* = undefined;
    }
    descriptors.deinit();
    return try filtered.toOwnedSlice();
}

fn queryPointsForSeriesId(
    alloc: std.mem.Allocator,
    eng: *Engine,
    snapshot_index: ?cas_mod.SnapshotIndex,
    series_id: types.SeriesId,
    start_ts_ns: i64,
    end_ts_ns: i64,
) ![]types.Point {
    var points = std.array_list.Managed(types.Point).init(alloc);
    defer points.deinit();
    if (snapshot_index) |*index| {
        try index.queryRange(alloc, eng.data_dir, series_id, start_ts_ns, end_ts_ns, &points);
    } else {
        try eng.queryRange(series_id, start_ts_ns, end_ts_ns, &points);
    }
    return try alloc.dupe(types.Point, points.items);
}

fn extractClientLabelInfo(alloc: std.mem.Allocator, labels_json: []const u8) !ClientLabelInfo {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, labels_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return .{ .labels_json = try alloc.dupe(u8, "{}") };
    const obj = parsed.value.object;

    var keys = std.array_list.Managed([]const u8).init(alloc);
    defer keys.deinit();
    var info = ClientLabelInfo{ .labels_json = undefined };
    errdefer info.deinit(alloc);

    var it = obj.iterator();
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "data_revision")) {
            if (entry.value_ptr.* == .string) info.data_revision = try alloc.dupe(u8, entry.value_ptr.string);
            continue;
        }
        if (std.mem.eql(u8, entry.key_ptr.*, "definition_id")) {
            if (entry.value_ptr.* == .string) info.definition_id = try alloc.dupe(u8, entry.value_ptr.string);
            continue;
        }
        if (std.mem.eql(u8, entry.key_ptr.*, "definition_version")) {
            if (entry.value_ptr.* == .string) info.definition_version = try alloc.dupe(u8, entry.value_ptr.string);
            continue;
        }
        try keys.append(entry.key_ptr.*);
    }
    std.sort.block([]const u8, keys.items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lessThan);

    var buffer = std.array_list.Managed(u8).init(alloc);
    errdefer buffer.deinit();
    var writer = buffer.writer();
    var tmp: [256]u8 = undefined;
    var adapter = writer.adaptToNewApi(&tmp);
    var iface = &adapter.new_interface;
    var jw = std.json.Stringify{ .writer = iface };
    try jw.beginObject();
    for (keys.items) |key| {
        try jw.objectField(key);
        try jw.write(obj.get(key).?);
    }
    try jw.endObject();
    try iface.flush();
    if (adapter.err) |err| return err;
    info.labels_json = try buffer.toOwnedSlice();
    return info;
}

fn labelValueFromJson(alloc: std.mem.Allocator, labels_json: []const u8, key: []const u8) !?[]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, labels_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    if (parsed.value.object.get(key)) |value| {
        if (value == .string) return try alloc.dupe(u8, value.string);
    }
    return null;
}

fn findPriceIndexAtOrAfter(points: []const types.Point, ts_ns: i64) ?usize {
    for (points, 0..) |point, idx| {
        if (point.ts >= ts_ns) return idx;
    }
    return null;
}

fn canonicalLabelsForMarket(
    alloc: std.mem.Allocator,
    symbol: []const u8,
    venue: []const u8,
    interval: ?[]const u8,
    bar_policy_id: ?[]const u8,
) ![]u8 {
    var buffer = std.array_list.Managed(u8).init(alloc);
    defer buffer.deinit();
    var writer = buffer.writer();
    try writer.writeAll("{");
    try writer.print("\"symbol\":\"{s}\",\"venue\":\"{s}\"", .{ symbol, venue });
    if (interval) |value| try writer.print(",\"interval\":\"{s}\"", .{value});
    if (bar_policy_id) |value| try writer.print(",\"bar_policy_id\":\"{s}\"", .{value});
    try writer.writeAll("}");
    return try @import("storage/series_catalog.zig").canonicalizeTagsJson(alloc, buffer.items);
}

fn queryMetricPoints(
    alloc: std.mem.Allocator,
    eng: *Engine,
    metric: []const u8,
    labels_json: []const u8,
    start_ts: i64,
    end_ts: i64,
    revision: ?[]const u8,
) ![]types.Point {
    if (revision) |spec| {
        var cas = eng.cas orelse return error.CasDisabled;
        const snapshot = try cas.loadSnapshotForSpec(spec);
        var index = cas_mod.SnapshotIndex.init(alloc, &cas.store, snapshot);
        defer index.deinit();
        const resolution = try index.resolveExactSeriesDetailed(metric, labels_json);
        if (resolution.status == .not_found or resolution.series_id == null) return try alloc.alloc(types.Point, 0);
        var points = std.array_list.Managed(types.Point).init(alloc);
        defer points.deinit();
        try index.queryRange(alloc, eng.data_dir, resolution.series_id.?, start_ts, end_ts, &points);
        return try alloc.dupe(types.Point, points.items);
    }
    const sid = try resolveExactSeriesId(eng, metric, labels_json) orelse return try alloc.alloc(types.Point, 0);
    if (sid == null_series_id) return try alloc.alloc(types.Point, 0);
    var points = std.array_list.Managed(types.Point).init(alloc);
    defer points.deinit();
    try eng.queryRange(sid, start_ts, end_ts, &points);
    return try alloc.dupe(types.Point, points.items);
}

fn resolvedRevisionLabel(alloc: std.mem.Allocator, eng: *Engine, revision: ?[]const u8) ![]u8 {
    if (revision) |spec| {
        if (eng.cas) |*cas| {
            const id = try cas.resolveCommitSpec(spec);
            const hex = id.toHex();
            return try alloc.dupe(u8, hex[0..]);
        }
    }
    if (eng.cas) |*cas| {
        if (try cas.refs.readHead(cas_mod.main_ref)) |head| {
            const hex = head.toHex();
            return try alloc.dupe(u8, hex[0..]);
        }
    }
    return try alloc.dupe(u8, "legacy-live");
}

fn respondAnalysisResult(
    alloc: std.mem.Allocator,
    eng: *Engine,
    req: *std.http.Server.Request,
    name: []const u8,
    revision: ?[]const u8,
    samples: usize,
    value: ?f64,
) !void {
    var send_buffer: [512]u8 = undefined;
    var response = try req.respondStreaming(&send_buffer, .{
        .respond_options = .{ .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} },
    });
    errdefer response.end() catch {};
    var jw = std.json.Stringify{ .writer = &response.writer };
    try jw.beginObject();
    try jw.objectField("analysis");
    try jw.write(name);
    try jw.objectField("data_revision");
    const revision_label = try resolvedRevisionLabel(alloc, eng, revision);
    defer alloc.free(revision_label);
    try jw.write(revision_label);
    try jw.objectField("samples");
    try jw.write(samples);
    try jw.objectField("value");
    if (value) |numeric| try jw.write(numeric) else try jw.write(null);
    try jw.endObject();
    try response.end();
}

fn respondQuoteQualityResult(
    alloc: std.mem.Allocator,
    eng: *Engine,
    req: *std.http.Server.Request,
    revision: ?[]const u8,
    samples: usize,
    spread_total: f64,
    stale_count: usize,
    crossed_count: usize,
    locked_count: usize,
    dropped_samples: usize,
) !void {
    var send_buffer: [768]u8 = undefined;
    var response = try req.respondStreaming(&send_buffer, .{
        .respond_options = .{ .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} },
    });
    errdefer response.end() catch {};
    var jw = std.json.Stringify{ .writer = &response.writer };
    try jw.beginObject();
    try jw.objectField("analysis");
    try jw.write("quote-quality");
    try jw.objectField("data_revision");
    const revision_label = try resolvedRevisionLabel(alloc, eng, revision);
    defer alloc.free(revision_label);
    try jw.write(revision_label);
    try jw.objectField("samples");
    try jw.write(samples);
    try jw.objectField("dropped_samples");
    try jw.write(dropped_samples);
    try jw.objectField("avg_spread");
    if (samples != 0) try jw.write(spread_total / @as(f64, @floatFromInt(samples))) else try jw.write(null);
    try jw.objectField("stale_count");
    try jw.write(stale_count);
    try jw.objectField("crossed_count");
    try jw.write(crossed_count);
    try jw.objectField("locked_count");
    try jw.write(locked_count);
    try jw.endObject();
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
