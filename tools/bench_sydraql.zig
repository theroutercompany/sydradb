const std = @import("std");
const sydra = @import("sydra_tooling");
const cfg = sydra.config;
const engine_mod = sydra.engine;
const types = sydra.types;
const query_exec = sydra.query_exec;

const Scenario = struct {
    name: []const u8,
    query: []const u8,
};

fn sleepMs(ms: u64) void {
    if (@hasDecl(std.time, "sleep")) {
        std.time.sleep(ms * std.time.ns_per_ms);
    } else {
        std.Thread.sleep(ms * std.time.ns_per_ms);
    }
}

fn makeConfig(alloc: std.mem.Allocator, data_dir: []const u8) !cfg.Config {
    return .{
        .data_dir = try alloc.dupe(u8, data_dir),
        .http_port = 0,
        .fsync = .none,
        .flush_interval_ms = 25,
        .memtable_max_bytes = 32 * 1024,
        .retention_days = 0,
        .auth_token = try alloc.dupe(u8, ""),
        .enable_influx = false,
        .enable_prom = false,
        .mem_limit_bytes = 512 * 1024 * 1024,
        .cas_mode = .off,
        .metadata_read_mode = .legacy,
        .query_compiler_mode = .compiled,
        .retention_ns = std.StringHashMap(u32).init(alloc),
    };
}

fn ingestSeries(
    alloc: std.mem.Allocator,
    engine: *engine_mod.Engine,
    series: []const u8,
    tags_json: []const u8,
    points_per_series: usize,
    ts_base: i64,
    value_base: f64,
) !void {
    const sid = types.seriesIdFrom(series, tags_json);
    try engine.registerSeries(series, tags_json, sid);

    var idx: usize = 0;
    while (idx < points_per_series) : (idx += 1) {
        try engine.ingest(.{
            .series_id = sid,
            .ts = ts_base + @as(i64, @intCast(idx * 60)),
            .value = value_base + @as(f64, @floatFromInt(idx % 11)),
            .tags_json = tags_json,
        });
    }

    _ = alloc;
}

fn seedDataset(
    alloc: std.mem.Allocator,
    engine: *engine_mod.Engine,
    total_series: usize,
    points_per_series: usize,
) !void {
    if (total_series < 2) return error.InvalidArgs;

    try ingestSeries(alloc, engine, "weather.room1", "{}", points_per_series, 0, 20.0);
    try ingestSeries(alloc, engine, "tagged.room1", "{\"host\":\"web\",\"rack\":\"r1\"}", points_per_series, 0, 40.0);

    var extra_idx: usize = 0;
    while (extra_idx + 2 < total_series) : (extra_idx += 1) {
        const series_name = try std.fmt.allocPrint(alloc, "bench.load.{d}", .{extra_idx});
        defer alloc.free(series_name);
        const tags_json = switch (extra_idx % 3) {
            0 => "{\"service\":\"web\"}",
            1 => "{\"service\":\"api\"}",
            else => "{\"service\":\"db\"}",
        };
        try ingestSeries(alloc, engine, series_name, tags_json, 1, @as(i64, @intCast(extra_idx * 300)), 100.0);
    }
}

fn runScenario(
    alloc: std.mem.Allocator,
    engine: *engine_mod.Engine,
    total_series: usize,
    iterations: usize,
    scenario: Scenario,
) !void {
    var total_elapsed_us: u128 = 0;
    var total_rows: u64 = 0;
    var total_rows_scanned: u64 = 0;
    var fallback_count: usize = 0;
    var last_parse_us: u64 = 0;
    var last_validate_us: u64 = 0;
    var last_bind_us: u64 = 0;
    var last_compile_us: u64 = 0;
    var last_logical_us: u64 = 0;
    var last_optimize_us: u64 = 0;
    var last_physical_us: u64 = 0;
    var last_pipeline_us: u64 = 0;
    var fallback_reason: []u8 = &[_]u8{};
    defer if (fallback_reason.len != 0) alloc.free(fallback_reason);

    var idx: usize = 0;
    while (idx < iterations) : (idx += 1) {
        const start_us = std.time.microTimestamp();
        var cursor = try query_exec.execute(alloc, engine, scenario.query);
        defer cursor.deinit();

        var rows_this_run: u64 = 0;
        while (try cursor.next()) |_| {
            rows_this_run += 1;
        }

        const op_stats = try cursor.collectOperatorStats(alloc);
        defer alloc.free(op_stats);

        var rows_scanned: u64 = 0;
        for (op_stats) |stat| {
            if (std.ascii.eqlIgnoreCase(stat.name, "scan")) rows_scanned += stat.rows_out;
        }

        const end_us = std.time.microTimestamp();
        total_elapsed_us += @as(u128, @intCast(end_us - start_us));
        total_rows += rows_this_run;
        total_rows_scanned += rows_scanned;
        if (cursor.stats.legacy_fallback) fallback_count += 1;

        if (fallback_reason.len != 0) alloc.free(fallback_reason);
        fallback_reason = if (cursor.stats.fallback_reason.len == 0)
            &[_]u8{}
        else
            try alloc.dupe(u8, cursor.stats.fallback_reason);

        last_parse_us = cursor.stats.parse_us;
        last_validate_us = cursor.stats.validate_us;
        last_bind_us = cursor.stats.bind_us;
        last_compile_us = cursor.stats.compile_us;
        last_logical_us = cursor.stats.logical_us;
        last_optimize_us = cursor.stats.optimize_us;
        last_physical_us = cursor.stats.physical_us;
        last_pipeline_us = cursor.stats.pipeline_us;
    }

    const avg_elapsed_us = if (iterations == 0) 0 else @as(u64, @intCast(total_elapsed_us / iterations));
    const avg_rows = if (iterations == 0) 0 else total_rows / iterations;
    const avg_rows_scanned = if (iterations == 0) 0 else total_rows_scanned / iterations;

    std.debug.print(
        "scenario={s} dataset_series={d} iterations={d} avg_elapsed_ms={d:.3} avg_rows={d} avg_rows_scanned={d} parse_ms={d:.3} validate_ms={d:.3} bind_ms={d:.3} compile_ms={d:.3} logical_ms={d:.3} optimize_ms={d:.3} physical_ms={d:.3} pipeline_ms={d:.3} fallback_count={d} fallback_reason={s}\n",
        .{
            scenario.name,
            total_series,
            iterations,
            microsToMillis(avg_elapsed_us),
            avg_rows,
            avg_rows_scanned,
            microsToMillis(last_parse_us),
            microsToMillis(last_validate_us),
            microsToMillis(last_bind_us),
            microsToMillis(last_compile_us),
            microsToMillis(last_logical_us),
            microsToMillis(last_optimize_us),
            microsToMillis(last_physical_us),
            microsToMillis(last_pipeline_us),
            fallback_count,
            if (fallback_reason.len == 0) "none" else fallback_reason,
        },
    );
}

fn microsToMillis(value: u64) f64 {
    return @as(f64, @floatFromInt(value)) / 1000.0;
}

fn parseArgs(alloc: std.mem.Allocator) !struct {
    points_per_series: usize,
    iterations: usize,
} {
    var args = try std.process.argsWithAllocator(alloc);
    defer args.deinit();
    _ = args.next();

    var points_per_series: usize = 32;
    var iterations: usize = 5;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--points-per-series")) {
            points_per_series = try std.fmt.parseInt(usize, args.next() orelse return error.InvalidArgs, 10);
        } else if (std.mem.eql(u8, arg, "--iterations")) {
            iterations = try std.fmt.parseInt(usize, args.next() orelse return error.InvalidArgs, 10);
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print("Usage: bench_sydraql [--points-per-series N] [--iterations N]\n", .{});
            std.process.exit(0);
        }
    }

    return .{
        .points_per_series = points_per_series,
        .iterations = iterations,
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const options = try parseArgs(alloc);
    const scenarios = [_]Scenario{
        .{ .name = "constant", .query = "select 1" },
        .{ .name = "raw_scan_limit", .query = "select time, value from weather.room1 where time >= 0 order by time limit 10" },
        .{ .name = "grouped_aggregate", .query = "select avg(value) from weather.room1 where time >= 0 group by time_bucket(60, time)" },
        .{ .name = "selector_tag_read", .query = "select tag.host as host, avg(value) as avg_value from tagged.room1 where tag.host = 'web' group by tag.host" },
        .{ .name = "unsupported_fallback", .query = "select time_bucket(60, time) as bucket, avg(value) as avg_value from weather.room1 where time >= 0 group by time_bucket(60, time) fill(linear) order by bucket desc" },
    };
    const cardinalities = [_]usize{ 2, 100, 10_000 };

    for (cardinalities) |total_series| {
        const data_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/bench-sydraql-{d}-{d}", .{ total_series, std.time.nanoTimestamp() });
        defer alloc.free(data_path);

        const config = try makeConfig(alloc, data_path);
        var engine = try engine_mod.Engine.init(alloc, config);
        defer engine.deinit();

        const ingest_start = std.time.microTimestamp();
        try seedDataset(alloc, engine, total_series, options.points_per_series);
        try engine.waitForDrained(5_000);
        const ingest_end = std.time.microTimestamp();

        std.debug.print(
            "dataset series={d} points_per_series={d} ingest_ms={d:.3} ingested={d} flushes={d} wal_bytes={d}\n",
            .{
                total_series,
                options.points_per_series,
                microsToMillis(@as(u64, @intCast(ingest_end - ingest_start))),
                engine.metrics.ingest_total.load(.monotonic),
                engine.metrics.flush_total.load(.monotonic),
                engine.metrics.wal_bytes_total.load(.monotonic),
            },
        );

        for (scenarios) |scenario| {
            try runScenario(alloc, engine, total_series, options.iterations, scenario);
        }
    }
}
