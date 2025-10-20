const std = @import("std");
const build_options = @import("build_options");
const sydra = @import("sydra_tooling");
const alloc_mod = sydra.alloc;
const cfg = sydra.config;
const engine = sydra.engine;
const types = sydra.types;

fn sleepMs(ms: u64) void {
    if (@hasDecl(std.time, "sleep")) {
        std.time.sleep(ms * std.time.ns_per_ms);
    } else {
        std.Thread.sleep(ms * std.time.ns_per_ms);
    }
}

fn makeConfig(alloc: std.mem.Allocator, data_dir: []const u8, flush_interval: u32, memtable_max: usize) !cfg.Config {
    const dir_copy = try alloc.dupe(u8, data_dir);
    errdefer alloc.free(dir_copy);
    const token_copy = try alloc.dupe(u8, "");
    errdefer alloc.free(token_copy);
    return cfg.Config{
        .data_dir = dir_copy,
        .http_port = 0,
        .fsync = .none,
        .flush_interval_ms = flush_interval,
        .memtable_max_bytes = memtable_max,
        .retention_days = 0,
        .auth_token = token_copy,
        .enable_influx = false,
        .enable_prom = false,
        .mem_limit_bytes = 512 * 1024 * 1024,
        .retention_ns = std.StringHashMap(u32).init(alloc),
    };
}

const ProducerContext = struct {
    engine: *engine.Engine,
    series_ids: []const types.SeriesId,
    ops: usize,
    series_offset: usize,
    ts_base: i64,
    thread_id: usize,
};

fn producer(ctx: ProducerContext) void {
    const eng = ctx.engine;
    const series = ctx.series_ids;
    if (ctx.ops == 0) return;
    var i: usize = 0;
    while (i < ctx.ops) : (i += 1) {
        const sid = series[(ctx.series_offset + i) % series.len];
        const ts = ctx.ts_base + @as(i64, @intCast(i));
        const val = @as(f64, @floatFromInt(ts));
        const item = engine.Engine.IngestItem{
            .series_id = sid,
            .ts = ts,
            .value = val,
            .tags_json = "{}",
        };
        if (eng.ingest(item)) |_| {} else |err| {
            std.debug.print("ingest error on thread {d}: {s}\n", .{ ctx.thread_id, @errorName(err) });
            return;
        }
    }
}

fn parseArgs(alloc: std.mem.Allocator) !struct {
    ops: usize,
    concurrency: usize,
    series: usize,
} {
    var args = try std.process.argsWithAllocator(alloc);
    defer args.deinit();
    _ = args.next(); // skip executable name

    var total_ops: usize = 200_000;
    var concurrency: usize = 4;
    var series: usize = 128;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--ops")) {
            if (args.next()) |val| {
                total_ops = try std.fmt.parseInt(usize, val, 10);
            } else return error.InvalidArgs;
        } else if (std.mem.eql(u8, arg, "--concurrency")) {
            if (args.next()) |val| {
                concurrency = try std.fmt.parseInt(usize, val, 10);
            } else return error.InvalidArgs;
        } else if (std.mem.eql(u8, arg, "--series")) {
            if (args.next()) |val| {
                series = try std.fmt.parseInt(usize, val, 10);
            } else return error.InvalidArgs;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print(
                "Usage: bench_alloc [--ops N] [--concurrency N] [--series N]\n",
                .{},
            );
            std.process.exit(0);
        }
    }

    if (concurrency == 0 or series == 0 or total_ops == 0) return error.InvalidArgs;
    return .{ .ops = total_ops, .concurrency = concurrency, .series = series };
}

pub fn main() !void {
    var arena_backing = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_backing.deinit();
    const arg_state = try parseArgs(arena_backing.allocator());

    var allocator_handle = alloc_mod.AllocatorHandle.init();
    defer allocator_handle.deinit();
    const alloc = allocator_handle.allocator();

    // Prepare data directory
    var path_buf: [128]u8 = undefined;
    const timestamp = std.time.milliTimestamp();
    const dir_name = try std.fmt.bufPrint(&path_buf, "bench-data-{d}", .{timestamp});
    try std.fs.cwd().makePath(dir_name);

    var config = try makeConfig(alloc, dir_name, 50, 4 * 1024 * 1024);
    var config_guard = true;
    defer if (config_guard) config.deinit(alloc);

    var eng = try engine.Engine.init(alloc, config);
    config_guard = false;
    defer {
        eng.deinit();
        std.fs.cwd().deleteTree(dir_name) catch {};
    }

    // Precompute series IDs
    var series_ids = try alloc.alloc(types.SeriesId, arg_state.series);
    defer alloc.free(series_ids);
    var idx: usize = 0;
    while (idx < series_ids.len) : (idx += 1) {
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "series-{d}", .{idx});
        series_ids[idx] = types.hash64(name);
    }

    const thread_count = arg_state.concurrency;
    var threads = try alloc.alloc(std.Thread, thread_count);
    defer alloc.free(threads);
    var contexts = try alloc.alloc(ProducerContext, thread_count);
    defer alloc.free(contexts);

    const ops_total = arg_state.ops;
    const base_ops = ops_total / thread_count;
    const remainder = ops_total % thread_count;
    var series_offset: usize = 0;
    var ts_base: i64 = 0;

    const start_ns = std.time.nanoTimestamp();
    var thread_idx: usize = 0;
    while (thread_idx < thread_count) : (thread_idx += 1) {
        const extra = if (thread_idx < remainder) @as(usize, 1) else 0;
        const ops = base_ops + extra;
        contexts[thread_idx] = .{
            .engine = eng,
            .series_ids = series_ids,
            .ops = ops,
            .series_offset = series_offset,
            .ts_base = ts_base,
            .thread_id = thread_idx,
        };
        threads[thread_idx] = try std.Thread.spawn(.{}, producer, .{contexts[thread_idx]});
        series_offset += ops;
        ts_base += @as(i64, @intCast(ops)) << 4;
    }

    // Join producers
    var i: usize = thread_count;
    while (i > 0) : (i -= 1) {
        threads[i - 1].join();
    }
    const produce_done_ns = std.time.nanoTimestamp();

    // Wait for writer thread to drain queue and update metrics
    const target_total: u64 = @intCast(ops_total);
    const timeout_ns: i128 = 30 * std.time.ns_per_s;
    const wait_start = std.time.nanoTimestamp();
    while (true) {
        const ingested = eng.metrics.ingest_total.load(.monotonic);
        const pending = eng.queue.len();
        if (ingested >= target_total and pending == 0) break;
        if (@as(i128, std.time.nanoTimestamp()) - wait_start > timeout_ns) {
            std.debug.print(
                "warning: timeout waiting for writer thread (ingested={d}, pending={d})\n",
                .{ ingested, pending },
            );
            break;
        }
        sleepMs(1);
    }
    const end_ns = std.time.nanoTimestamp();

    const produce_ns = produce_done_ns - start_ns;
    const total_ns = end_ns - start_ns;
    const wait_ns = end_ns - produce_done_ns;
    const produce_ms = @as(f64, @floatFromInt(produce_ns)) / 1_000_000.0;
    const wait_ms = @as(f64, @floatFromInt(wait_ns)) / 1_000_000.0;
    const total_ms = @as(f64, @floatFromInt(total_ns)) / 1_000_000.0;
    const throughput =
        @as(f64, @floatFromInt(ops_total)) / (@as(f64, @floatFromInt(total_ns)) / @as(f64, std.time.ns_per_s));

    const final_ingested = eng.metrics.ingest_total.load(.monotonic);
    const final_flushes = eng.metrics.flush_total.load(.monotonic);

    std.debug.print(
        "allocator_mode={s} ops={d} concurrency={d} series={d} produce_ms={d:.3} wait_ms={d:.3} total_ms={d:.3} throughput={d:.2} ops/s ingested={d} flushes={d}\n",
        .{
            build_options.allocator_mode,
            ops_total,
            thread_count,
            series_ids.len,
            produce_ms,
            wait_ms,
            total_ms,
            throughput,
            final_ingested,
            final_flushes,
        },
    );
}
