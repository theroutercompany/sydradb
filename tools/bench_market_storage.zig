const std = @import("std");
const sydra = @import("sydra_tooling");
const cfg = sydra.config;
const Engine = sydra.engine.Engine;
const types = sydra.types;

const output_schema_version: u32 = 2;
const default_rows: usize = 1_024;
const default_query_iterations: usize = 5;
const default_batch_rows: usize = 256;
const label_sets = [_][]const u8{
    "{\"symbol\":\"AAPL\",\"venue\":\"XNAS\"}",
    "{\"symbol\":\"MSFT\",\"venue\":\"XNAS\"}",
    "{\"symbol\":\"NVDA\",\"venue\":\"XNAS\"}",
    "{\"symbol\":\"AMD\",\"venue\":\"XNAS\"}",
};

const trade_columns = [_][]const u8{ "price", "size" };
const trade_selected_columns = [_][]const u8{"price"};
const quote_columns = [_][]const u8{ "bid", "ask", "bid_size", "ask_size" };
const quote_selected_columns = [_][]const u8{ "bid", "ask" };
const synthetic_columns = [_][]const u8{ "c0", "c1", "c2", "c3", "c4", "c5", "c6", "c7" };
const synthetic_selected_columns = [_][]const u8{ "c0", "c7" };

const Scenario = struct {
    name: []const u8,
    metric: []const u8,
    ordered_columns: []const []const u8,
    selected_columns: []const []const u8,
};

const scenarios = [_]Scenario{
    .{
        .name = "trade",
        .metric = "market.trade",
        .ordered_columns = trade_columns[0..],
        .selected_columns = trade_selected_columns[0..],
    },
    .{
        .name = "quote",
        .metric = "market.quote",
        .ordered_columns = quote_columns[0..],
        .selected_columns = quote_selected_columns[0..],
    },
    .{
        .name = "synthetic_8",
        .metric = "bench.market.synthetic_8",
        .ordered_columns = synthetic_columns[0..],
        .selected_columns = synthetic_selected_columns[0..],
    },
};

const CliOptions = struct {
    selected_scenario: ?[]u8 = null,
    rows: usize = default_rows,
    query_iterations: usize = default_query_iterations,
    batch_rows: usize = default_batch_rows,
    fsync_policy: cfg.FsyncPolicy = .none,
    assert_smoke: bool = false,

    fn deinit(self: *CliOptions, alloc: std.mem.Allocator) void {
        if (self.selected_scenario) |value| alloc.free(value);
        self.* = undefined;
    }
};

const QueryMetrics = struct {
    latency_p50_ns: u64,
    latency_p95_ns: u64,
    returned_points: u64,
    returned_point_bytes_estimate: u64,
};

const BenchmarkMetrics = struct {
    enqueue_elapsed_ns: u64,
    ingest_or_drain_elapsed_ns: u64,
    ingest_or_drain_logical_rows_per_second: f64,
    enqueue_logical_rows_per_second: f64,
    physical_writes: u64,
    expected_physical_writes: u64,
    wal_bytes: u64,
    wal_payload_bytes: u64,
    segment_bytes: u64,
    storage_bytes: u64,
    peak_resident_estimate_bytes: u64,
    query: QueryMetrics,
};

fn makeConfig(
    alloc: std.mem.Allocator,
    data_dir: []const u8,
    fsync_policy: cfg.FsyncPolicy,
) !cfg.Config {
    return .{
        .data_dir = try alloc.dupe(u8, data_dir),
        .http_port = 0,
        .fsync = fsync_policy,
        .flush_interval_ms = 25,
        .memtable_max_bytes = 8 * 1024 * 1024,
        .retention_days = 0,
        .auth_token = try alloc.dupe(u8, ""),
        .enable_influx = false,
        .enable_prom = false,
        .mem_limit_bytes = 512 * 1024 * 1024,
        .cas_mode = .off,
        .metadata_read_mode = .legacy,
        .query_compiler_mode = .compiled,
        .market_storage_mode = .fanout_v1,
        .market_storage_read_mode = .fanout,
        .retention_ns = std.StringHashMap(u32).init(alloc),
    };
}

fn parseFsyncPolicy(value: []const u8) !cfg.FsyncPolicy {
    if (std.mem.eql(u8, value, "none")) return .none;
    if (std.mem.eql(u8, value, "interval")) return .interval;
    if (std.mem.eql(u8, value, "always")) return .always;
    return error.InvalidFsyncPolicy;
}

fn parseArgs(alloc: std.mem.Allocator) !CliOptions {
    var args = try std.process.argsWithAllocator(alloc);
    defer args.deinit();
    _ = args.next();

    var options: CliOptions = .{};
    errdefer options.deinit(alloc);

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--scenario")) {
            if (options.selected_scenario != null) return error.InvalidArgs;
            options.selected_scenario = try alloc.dupe(u8, args.next() orelse return error.InvalidArgs);
        } else if (std.mem.eql(u8, arg, "--rows")) {
            options.rows = try std.fmt.parseInt(usize, args.next() orelse return error.InvalidArgs, 10);
        } else if (std.mem.eql(u8, arg, "--query-iterations")) {
            options.query_iterations = try std.fmt.parseInt(usize, args.next() orelse return error.InvalidArgs, 10);
        } else if (std.mem.eql(u8, arg, "--batch-rows")) {
            options.batch_rows = try std.fmt.parseInt(usize, args.next() orelse return error.InvalidArgs, 10);
        } else if (std.mem.eql(u8, arg, "--fsync")) {
            options.fsync_policy = try parseFsyncPolicy(args.next() orelse return error.InvalidArgs);
        } else if (std.mem.eql(u8, arg, "--assert-smoke")) {
            options.assert_smoke = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print(
                \\Usage: bench_market_storage [--scenario trade|quote|synthetic_8]
                \\                            [--rows N] [--query-iterations N] [--batch-rows N]
                \\                            [--fsync none|interval|always]
                \\
                \\Emits one schema-versioned JSON object per scenario on stdout.
                \\
            , .{});
            std.process.exit(0);
        } else {
            return error.InvalidArgs;
        }
    }

    if (options.rows == 0 or options.query_iterations == 0 or options.batch_rows == 0) {
        return error.InvalidArgs;
    }
    if (options.batch_rows > options.rows) options.batch_rows = options.rows;
    return options;
}

fn scenarioMatches(selected: ?[]const u8, scenario: Scenario) bool {
    const value = selected orelse return true;
    return std.mem.eql(u8, value, scenario.name);
}

fn columnIndex(scenario: Scenario, selected: []const u8) !usize {
    for (scenario.ordered_columns, 0..) |column, idx| {
        if (std.mem.eql(u8, column, selected)) return idx;
    }
    return error.InvalidScenario;
}

fn seriesIndex(scenario: Scenario, label_idx: usize, column_idx: usize) usize {
    return label_idx * scenario.ordered_columns.len + column_idx;
}

fn registerFanoutSeries(
    alloc: std.mem.Allocator,
    engine: *Engine,
    scenario: Scenario,
) ![]types.SeriesId {
    var stored_schema = try engine.registerMarketSchema(.{
        .metric = scenario.metric,
        .ordered_columns = scenario.ordered_columns,
        .required_labels = &.{ "symbol", "venue" },
        .storage_mapping = .fanout_v1,
    });
    defer stored_schema.deinit(engine.alloc);

    const ids = try alloc.alloc(types.SeriesId, label_sets.len * scenario.ordered_columns.len);
    errdefer alloc.free(ids);

    for (scenario.ordered_columns, 0..) |column, column_idx| {
        const metric = try std.fmt.allocPrint(alloc, "{s}.{s}", .{ scenario.metric, column });
        defer alloc.free(metric);
        _ = try engine.registerMetricDescriptor(.{
            .metric = metric,
            .kind = .gauge,
            .source_metric = scenario.metric,
            .source_field = column,
        });
        for (label_sets, 0..) |labels_json, label_idx| {
            const id = types.seriesIdFrom(metric, labels_json);
            try engine.registerSeries(metric, labels_json, id);
            ids[seriesIndex(scenario, label_idx, column_idx)] = id;
        }
    }
    return ids;
}

fn valueFor(row_idx: usize, column_idx: usize) f64 {
    const integral = 100 + column_idx * 10 + (row_idx % 997);
    return @as(f64, @floatFromInt(integral)) + 0.125;
}

fn ingestFanoutRows(
    alloc: std.mem.Allocator,
    engine: *Engine,
    scenario: Scenario,
    series_ids: []const types.SeriesId,
    rows: usize,
    batch_rows: usize,
) !struct { enqueue_elapsed_ns: u64, ingest_or_drain_elapsed_ns: u64 } {
    const max_batch_points = try std.math.mul(usize, batch_rows, scenario.ordered_columns.len);
    const batch = try alloc.alloc(Engine.IngestItem, max_batch_points);
    defer alloc.free(batch);

    const start_ns = std.time.nanoTimestamp();
    var batch_len: usize = 0;
    for (0..rows) |row_idx| {
        const label_idx = row_idx % label_sets.len;
        const ts_ns = 1_700_000_000_000_000_000 +
            @as(i64, @intCast(row_idx / label_sets.len)) * std.time.ns_per_ms;
        for (scenario.ordered_columns, 0..) |_, column_idx| {
            batch[batch_len] = .{
                .series_id = series_ids[seriesIndex(scenario, label_idx, column_idx)],
                .ts = ts_ns,
                .value = valueFor(row_idx, column_idx),
                .tags_json = label_sets[label_idx],
            };
            batch_len += 1;
        }
        if (batch_len == batch.len) {
            try engine.ingestBatch(batch);
            batch_len = 0;
        }
    }
    if (batch_len != 0) try engine.ingestBatch(batch[0..batch_len]);
    const enqueue_end_ns = std.time.nanoTimestamp();

    _ = try engine.flushAndDrain(120_000);
    try engine.waitForDrained(120_000);
    const ingest_or_drain_end_ns = std.time.nanoTimestamp();
    return .{
        .enqueue_elapsed_ns = @intCast(enqueue_end_ns - start_ns),
        .ingest_or_drain_elapsed_ns = @intCast(ingest_or_drain_end_ns - start_ns),
    };
}

fn runProjectedQuery(
    alloc: std.mem.Allocator,
    engine: *Engine,
    scenario: Scenario,
    series_ids: []const types.SeriesId,
) !u64 {
    var returned_points: u64 = 0;
    var points = std.array_list.Managed(types.Point).init(alloc);
    defer points.deinit();

    for (scenario.selected_columns) |selected| {
        const column_idx = try columnIndex(scenario, selected);
        for (label_sets, 0..) |_, label_idx| {
            points.clearRetainingCapacity();
            try engine.queryRange(
                series_ids[seriesIndex(scenario, label_idx, column_idx)],
                std.math.minInt(i64),
                std.math.maxInt(i64),
                &points,
            );
            returned_points += @intCast(points.items.len);
        }
    }
    return returned_points;
}

fn percentile(sorted: []const u64, ratio: f64) u64 {
    if (sorted.len == 0) return 0;
    const max_index = sorted.len - 1;
    const position = ratio * @as(f64, @floatFromInt(max_index));
    const lower: usize = @intFromFloat(@floor(position));
    const upper = @min(lower + 1, max_index);
    if (lower == upper) return sorted[lower];
    const weight = position - @floor(position);
    return @intFromFloat(
        @as(f64, @floatFromInt(sorted[lower])) * (1.0 - weight) +
            @as(f64, @floatFromInt(sorted[upper])) * weight,
    );
}

fn measureQueries(
    alloc: std.mem.Allocator,
    engine: *Engine,
    scenario: Scenario,
    series_ids: []const types.SeriesId,
    rows: usize,
    iterations: usize,
) !QueryMetrics {
    const expected_points = try std.math.mul(u64, @intCast(rows), @intCast(scenario.selected_columns.len));

    const warm_points = try runProjectedQuery(alloc, engine, scenario, series_ids);
    if (warm_points != expected_points) return error.BenchmarkQueryMismatch;

    const latencies = try alloc.alloc(u64, iterations);
    defer alloc.free(latencies);
    var returned_points: u64 = 0;
    for (latencies) |*latency| {
        const start_ns = std.time.nanoTimestamp();
        returned_points = try runProjectedQuery(alloc, engine, scenario, series_ids);
        latency.* = @intCast(std.time.nanoTimestamp() - start_ns);
        if (returned_points != expected_points) return error.BenchmarkQueryMismatch;
    }
    std.sort.block(u64, latencies, {}, std.sort.asc(u64));
    return .{
        .latency_p50_ns = percentile(latencies, 0.50),
        .latency_p95_ns = percentile(latencies, 0.95),
        .returned_points = returned_points,
        .returned_point_bytes_estimate = returned_points * @sizeOf(types.Point),
    };
}

fn directorySizeRecursive(dir: std.fs.Dir) !u64 {
    var total: u64 = 0;
    var it = dir.iterate();
    while (try it.next()) |entry| {
        switch (entry.kind) {
            .file => {
                const stat = try dir.statFile(entry.name);
                total += stat.size;
            },
            .directory => {
                var child = try dir.openDir(entry.name, .{ .iterate = true });
                defer child.close();
                total += try directorySizeRecursive(child);
            },
            else => {},
        }
    }
    return total;
}

fn directorySize(data_path: []const u8, relative_path: []const u8) !u64 {
    var root = try std.fs.cwd().openDir(data_path, .{ .iterate = true });
    defer root.close();
    var dir = root.openDir(relative_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    defer dir.close();
    return try directorySizeRecursive(dir);
}

fn rowsPerSecond(rows: usize, elapsed_ns: u64) f64 {
    if (elapsed_ns == 0) return 0;
    return @as(f64, @floatFromInt(rows)) * @as(f64, std.time.ns_per_s) /
        @as(f64, @floatFromInt(elapsed_ns));
}

fn writeStringArray(jw: *std.json.Stringify, values: []const []const u8) !void {
    try jw.beginArray();
    for (values) |value| try jw.write(value);
    try jw.endArray();
}

fn assertSmokeOutput(
    alloc: std.mem.Allocator,
    output: []const u8,
    fsync_policy: cfg.FsyncPolicy,
) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, output, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidBenchmarkOutput;
    const root = parsed.value.object;

    const schema_version = root.get("schema_version") orelse return error.InvalidBenchmarkOutput;
    if (schema_version != .integer or schema_version.integer != output_schema_version) {
        return error.InvalidBenchmarkOutput;
    }

    const durability = root.get("durability") orelse return error.InvalidBenchmarkOutput;
    if (durability != .object) return error.InvalidBenchmarkOutput;
    const emitted_policy = durability.object.get("fsync_policy") orelse return error.InvalidBenchmarkOutput;
    if (emitted_policy != .string or !std.mem.eql(u8, emitted_policy.string, @tagName(fsync_policy))) {
        return error.InvalidBenchmarkOutput;
    }

    const metrics = root.get("metrics") orelse return error.InvalidBenchmarkOutput;
    if (metrics != .object) return error.InvalidBenchmarkOutput;
    const physical_writes = metrics.object.get("physical_writes") orelse return error.InvalidBenchmarkOutput;
    const expected_writes = metrics.object.get("expected_physical_writes") orelse return error.InvalidBenchmarkOutput;
    const wal_bytes = metrics.object.get("wal_bytes") orelse return error.InvalidBenchmarkOutput;
    const segment_bytes = metrics.object.get("segment_bytes") orelse return error.InvalidBenchmarkOutput;
    const storage_bytes = metrics.object.get("storage_bytes") orelse return error.InvalidBenchmarkOutput;
    if (physical_writes != .integer or expected_writes != .integer or
        physical_writes.integer != expected_writes.integer or
        wal_bytes != .integer or segment_bytes != .integer or storage_bytes != .integer or
        storage_bytes.integer != wal_bytes.integer + segment_bytes.integer)
    {
        return error.InvalidBenchmarkOutput;
    }

    const elapsed = metrics.object.get("ingest_or_drain_elapsed_ns") orelse return error.InvalidBenchmarkOutput;
    if (elapsed != .integer or elapsed.integer <= 0) return error.InvalidBenchmarkOutput;
    const bytes_decoded = metrics.object.get("bytes_decoded") orelse return error.InvalidBenchmarkOutput;
    if (bytes_decoded != .null) return error.InvalidBenchmarkOutput;

    const durable_elapsed = metrics.object.get("durable_elapsed_ns");
    if (fsync_policy == .always) {
        if (durable_elapsed == null or durable_elapsed.? != .integer or durable_elapsed.?.integer <= 0) {
            return error.InvalidBenchmarkOutput;
        }
    } else if (durable_elapsed != null) {
        return error.InvalidBenchmarkOutput;
    }
}

fn emitResult(
    alloc: std.mem.Allocator,
    scenario: Scenario,
    rows: usize,
    query_iterations: usize,
    batch_rows: usize,
    fsync_policy: cfg.FsyncPolicy,
    smoke_assertions: bool,
    metrics: BenchmarkMetrics,
) !void {
    var output = std.array_list.Managed(u8).init(alloc);
    defer output.deinit();
    var writer = output.writer();
    var scratch: [1024]u8 = undefined;
    var adapter = writer.adaptToNewApi(&scratch);
    const iface = &adapter.new_interface;
    var jw = std.json.Stringify{ .writer = iface };

    try jw.beginObject();
    try jw.objectField("schema_version");
    try jw.write(output_schema_version);
    try jw.objectField("suite");
    try jw.write("bench-market-storage");
    try jw.objectField("scenario");
    try jw.write(scenario.name);
    try jw.objectField("storage_mode");
    try jw.write("fanout_v1");

    try jw.objectField("durability");
    try jw.beginObject();
    try jw.objectField("fsync_policy");
    try jw.write(@tagName(fsync_policy));
    try jw.objectField("completion_scope");
    try jw.write(if (fsync_policy == .always) "durable_fsync_always" else "ingest_or_drain");
    try jw.endObject();

    try jw.objectField("dataset");
    try jw.beginObject();
    try jw.objectField("logical_rows");
    try jw.write(rows);
    try jw.objectField("label_series");
    try jw.write(label_sets.len);
    try jw.objectField("ordered_columns");
    try writeStringArray(&jw, scenario.ordered_columns);
    try jw.objectField("selected_columns");
    try writeStringArray(&jw, scenario.selected_columns);
    try jw.objectField("batch_rows");
    try jw.write(batch_rows);
    try jw.endObject();

    try jw.objectField("metrics");
    try jw.beginObject();
    try jw.objectField("logical_rows_per_second");
    try jw.write(metrics.ingest_or_drain_logical_rows_per_second);
    try jw.objectField("ingest_or_drain_logical_rows_per_second");
    try jw.write(metrics.ingest_or_drain_logical_rows_per_second);
    try jw.objectField("enqueue_logical_rows_per_second");
    try jw.write(metrics.enqueue_logical_rows_per_second);
    try jw.objectField("enqueue_elapsed_ns");
    try jw.write(metrics.enqueue_elapsed_ns);
    try jw.objectField("ingest_or_drain_elapsed_ns");
    try jw.write(metrics.ingest_or_drain_elapsed_ns);
    if (fsync_policy == .always) {
        try jw.objectField("durable_elapsed_ns");
        try jw.write(metrics.ingest_or_drain_elapsed_ns);
        try jw.objectField("durable_logical_rows_per_second");
        try jw.write(metrics.ingest_or_drain_logical_rows_per_second);
    }
    try jw.objectField("physical_writes");
    try jw.write(metrics.physical_writes);
    try jw.objectField("expected_physical_writes");
    try jw.write(metrics.expected_physical_writes);
    try jw.objectField("wal_bytes");
    try jw.write(metrics.wal_bytes);
    try jw.objectField("wal_payload_bytes");
    try jw.write(metrics.wal_payload_bytes);
    try jw.objectField("segment_bytes");
    try jw.write(metrics.segment_bytes);
    try jw.objectField("storage_bytes");
    try jw.write(metrics.storage_bytes);
    try jw.objectField("query_latency_p50_ns");
    try jw.write(metrics.query.latency_p50_ns);
    try jw.objectField("query_latency_p95_ns");
    try jw.write(metrics.query.latency_p95_ns);
    try jw.objectField("query_iterations");
    try jw.write(query_iterations);
    try jw.objectField("query_returned_points");
    try jw.write(metrics.query.returned_points);
    try jw.objectField("bytes_decoded");
    try jw.write(null);
    try jw.objectField("returned_point_bytes_estimate");
    try jw.write(metrics.query.returned_point_bytes_estimate);
    try jw.objectField("peak_resident_estimate_bytes");
    try jw.write(metrics.peak_resident_estimate_bytes);
    try jw.endObject();

    try jw.objectField("measurement");
    try jw.beginObject();
    try jw.objectField("throughput_scope");
    try jw.write(if (fsync_policy == .always) "durable_fsync_always" else "ingest_or_drain");
    try jw.objectField("logical_rows_per_second_compatibility_alias");
    try jw.write("ingest_or_drain_logical_rows_per_second");
    try jw.objectField("query_path");
    try jw.write("direct_engine_fanout_projection");
    try jw.objectField("wal_bytes_source");
    try jw.write("sum of regular files beneath the generated wal directory");
    try jw.objectField("wal_payload_bytes_source");
    try jw.write("engine WAL append byte counter");
    try jw.objectField("query_warmups");
    try jw.write(@as(u8, 1));
    try jw.objectField("bytes_decoded_observable");
    try jw.write(false);
    try jw.objectField("returned_point_bytes_estimate_definition");
    try jw.write("selected scalar points multiplied by sizeof(types.Point)");
    try jw.objectField("peak_resident_estimate_source");
    try jw.write("memtable limit plus observed queue pending-byte high-water");
    try jw.endObject();

    try jw.endObject();
    try iface.flush();
    if (adapter.err) |err| return err;
    if (smoke_assertions) try assertSmokeOutput(alloc, output.items, fsync_policy);

    var stdout = std.fs.File.stdout();
    try stdout.writeAll(output.items);
    try stdout.writeAll("\n");
}

fn runScenario(
    alloc: std.mem.Allocator,
    scenario: Scenario,
    options: CliOptions,
) !void {
    const data_path = try std.fmt.allocPrint(
        alloc,
        ".zig-cache/tmp/bench-market-storage-{s}-{d}",
        .{ scenario.name, std.time.nanoTimestamp() },
    );
    defer alloc.free(data_path);
    defer std.fs.cwd().deleteTree(data_path) catch {};

    const config = try makeConfig(alloc, data_path, options.fsync_policy);
    const memtable_limit = config.memtable_max_bytes;
    const engine = try Engine.init(alloc, config);
    defer engine.deinit();

    const series_ids = try registerFanoutSeries(alloc, engine, scenario);
    defer alloc.free(series_ids);

    const timings = try ingestFanoutRows(
        alloc,
        engine,
        scenario,
        series_ids,
        options.rows,
        options.batch_rows,
    );
    const expected_writes = try std.math.mul(u64, @intCast(options.rows), @intCast(scenario.ordered_columns.len));
    const physical_writes = engine.metrics.ingest_total.load(.monotonic);
    if (physical_writes != expected_writes) return error.BenchmarkIngestMismatch;

    const query = try measureQueries(
        alloc,
        engine,
        scenario,
        series_ids,
        options.rows,
        options.query_iterations,
    );
    const queue_peak: u64 = @intCast(engine.metrics.queue_pending_bytes_max.load(.monotonic));
    const resident_estimate = @min(
        @as(u64, @intCast(engine.config.mem_limit_bytes)),
        @as(u64, @intCast(memtable_limit)) + queue_peak,
    );
    const wal_bytes = try directorySize(data_path, "wal");
    const segment_bytes = try directorySize(data_path, "segments");

    try emitResult(
        alloc,
        scenario,
        options.rows,
        options.query_iterations,
        options.batch_rows,
        options.fsync_policy,
        options.assert_smoke,
        .{
            .enqueue_elapsed_ns = timings.enqueue_elapsed_ns,
            .ingest_or_drain_elapsed_ns = timings.ingest_or_drain_elapsed_ns,
            .ingest_or_drain_logical_rows_per_second = rowsPerSecond(options.rows, timings.ingest_or_drain_elapsed_ns),
            .enqueue_logical_rows_per_second = rowsPerSecond(options.rows, timings.enqueue_elapsed_ns),
            .physical_writes = physical_writes,
            .expected_physical_writes = expected_writes,
            .wal_bytes = wal_bytes,
            .wal_payload_bytes = engine.metrics.wal_bytes_total.load(.monotonic),
            .segment_bytes = segment_bytes,
            .storage_bytes = wal_bytes + segment_bytes,
            .peak_resident_estimate_bytes = resident_estimate,
            .query = query,
        },
    );
}

pub fn main() !void {
    const alloc = std.heap.c_allocator;
    var options = try parseArgs(alloc);
    defer options.deinit(alloc);

    var ran = false;
    for (scenarios) |scenario| {
        if (!scenarioMatches(options.selected_scenario, scenario)) continue;
        ran = true;
        try runScenario(alloc, scenario, options);
    }
    if (!ran) return error.UnknownScenario;
}
