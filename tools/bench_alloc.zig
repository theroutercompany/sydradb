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
    drain_timeout_ms: usize,
    poll_ms: u32,
    flush_interval_ms: u32,
    memtable_max_bytes: usize,
} {
    var args = try std.process.argsWithAllocator(alloc);
    defer args.deinit();
    _ = args.next(); // skip executable name

    var total_ops: usize = 200_000;
    var concurrency: usize = 4;
    var series: usize = 128;
    var drain_timeout_ms: usize = 60_000;
    var poll_ms: u32 = 5;
    var flush_interval_ms: u32 = 200;
    var memtable_mb: usize = 32;

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
        } else if (std.mem.eql(u8, arg, "--drain-timeout-ms")) {
            if (args.next()) |val| {
                drain_timeout_ms = try std.fmt.parseInt(usize, val, 10);
            } else return error.InvalidArgs;
        } else if (std.mem.eql(u8, arg, "--poll-ms")) {
            if (args.next()) |val| {
                poll_ms = try std.fmt.parseInt(u32, val, 10);
            } else return error.InvalidArgs;
        } else if (std.mem.eql(u8, arg, "--flush-ms")) {
            if (args.next()) |val| {
                flush_interval_ms = try std.fmt.parseInt(u32, val, 10);
            } else return error.InvalidArgs;
        } else if (std.mem.eql(u8, arg, "--memtable-mb")) {
            if (args.next()) |val| {
                memtable_mb = try std.fmt.parseInt(usize, val, 10);
            } else return error.InvalidArgs;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print(
                "Usage: bench_alloc [--ops N] [--concurrency N] [--series N] [--drain-timeout-ms N] [--poll-ms N] [--flush-ms N] [--memtable-mb N]\n",
                .{},
            );
            std.process.exit(0);
        }
    }

    if (concurrency == 0 or series == 0 or total_ops == 0) return error.InvalidArgs;
    const memtable_max_bytes = memtable_mb * 1024 * 1024;
    return .{
        .ops = total_ops,
        .concurrency = concurrency,
        .series = series,
        .drain_timeout_ms = drain_timeout_ms,
        .poll_ms = poll_ms,
        .flush_interval_ms = flush_interval_ms,
        .memtable_max_bytes = memtable_max_bytes,
    };
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

    var config = try makeConfig(alloc, dir_name, arg_state.flush_interval_ms, arg_state.memtable_max_bytes);
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
    const timeout_ns: ?i128 = if (arg_state.drain_timeout_ms == 0)
        null
    else
        @as(i128, @intCast(arg_state.drain_timeout_ms)) * std.time.ns_per_ms;
    const wait_start = std.time.nanoTimestamp();
    var samples: usize = 0;
    var max_pending: usize = 0;
    var pending_sum: u128 = 0;
    var timed_out = false;
    while (true) {
        const ingested = eng.metrics.ingest_total.load(.monotonic);
        const pending = eng.queue.len();
        samples += 1;
        pending_sum += pending;
        if (pending > max_pending) max_pending = pending;
        if (ingested >= target_total and pending == 0) break;
        if (timeout_ns) |limit_ns| {
            if (@as(i128, std.time.nanoTimestamp()) - wait_start > limit_ns) {
                timed_out = true;
                break;
            }
        }
        sleepMs(arg_state.poll_ms);
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

    const queue_avg = if (samples > 0) @as(f64, @floatFromInt(pending_sum)) / @as(f64, @floatFromInt(samples)) else 0.0;
    const pending_end = eng.queue.len();

    const flush_total = final_flushes;
    const flush_ns_total = eng.metrics.flush_ns_total.load(.monotonic);
    const flush_points_total = eng.metrics.flush_points_total.load(.monotonic);
    const avg_flush_ms = if (flush_total > 0)
        (@as(f64, @floatFromInt(flush_ns_total)) / @as(f64, std.time.ns_per_ms)) / @as(f64, @floatFromInt(flush_total))
    else
        0.0;
    const avg_flush_points = if (flush_total > 0)
        @as(f64, @floatFromInt(flush_points_total)) / @as(f64, @floatFromInt(flush_total))
    else
        0.0;
    const queue_pop_total = eng.metrics.queue_pop_total.load(.monotonic);
    const queue_wait_ns_total = eng.metrics.queue_wait_ns_total.load(.monotonic);
    const queue_len_sum = eng.metrics.queue_len_sum.load(.monotonic);
    const queue_len_samples = eng.metrics.queue_len_samples.load(.monotonic);
    const queue_max_len = eng.metrics.queue_max_len.load(.monotonic);
    const queue_push_lock_wait_ns_total = eng.metrics.queue_push_lock_wait_ns_total.load(.monotonic);
    const queue_push_lock_hold_ns_total = eng.metrics.queue_push_lock_hold_ns_total.load(.monotonic);
    const queue_push_lock_acquisitions = eng.metrics.queue_push_lock_acquisitions.load(.monotonic);
    const queue_push_lock_contention = eng.metrics.queue_push_lock_contention.load(.monotonic);
    const queue_pop_lock_wait_ns_total = eng.metrics.queue_pop_lock_wait_ns_total.load(.monotonic);
    const queue_pop_lock_hold_ns_total = eng.metrics.queue_pop_lock_hold_ns_total.load(.monotonic);
    const queue_pop_lock_acquisitions = eng.metrics.queue_pop_lock_acquisitions.load(.monotonic);
    const queue_pop_lock_contention = eng.metrics.queue_pop_lock_contention.load(.monotonic);
    const avg_queue_wait_ms = if (queue_pop_total > 0)
        (@as(f64, @floatFromInt(queue_wait_ns_total)) / @as(f64, std.time.ns_per_ms)) / @as(f64, @floatFromInt(queue_pop_total))
    else
        0.0;
    const avg_queue_len = if (queue_len_samples > 0)
        @as(f64, @floatFromInt(queue_len_sum)) / @as(f64, @floatFromInt(queue_len_samples))
    else
        0.0;

    std.debug.print(
        "allocator_mode={s} ops={d} concurrency={d} series={d} produce_ms={d:.3} wait_ms={d:.3} total_ms={d:.3} throughput={d:.2} ops/s ingested={d} flushes={d} avg_flush_ms={d:.3} avg_flush_points={d:.1}\n",
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
            avg_flush_ms,
            avg_flush_points,
        },
    );
    std.debug.print(
        "queue_stats max_pending={d} avg_pending={d:.1} samples={d} pending_end={d} timed_out={s}\n",
        .{ max_pending, queue_avg, samples, pending_end, if (timed_out) "true" else "false" },
    );
    std.debug.print(
        "queue_metrics pops={d} avg_wait_ms={d:.3} avg_len={d:.1} max_len={d}\n",
        .{ queue_pop_total, avg_queue_wait_ms, avg_queue_len, queue_max_len },
    );

    const avg_push_wait_us = if (queue_push_lock_acquisitions > 0)
        (@as(f64, @floatFromInt(queue_push_lock_wait_ns_total)) / 1000.0) / @as(f64, @floatFromInt(queue_push_lock_acquisitions))
    else
        0.0;
    const avg_push_hold_us = if (queue_push_lock_acquisitions > 0)
        (@as(f64, @floatFromInt(queue_push_lock_hold_ns_total)) / 1000.0) / @as(f64, @floatFromInt(queue_push_lock_acquisitions))
    else
        0.0;
    const avg_pop_wait_us = if (queue_pop_lock_acquisitions > 0)
        (@as(f64, @floatFromInt(queue_pop_lock_wait_ns_total)) / 1000.0) / @as(f64, @floatFromInt(queue_pop_lock_acquisitions))
    else
        0.0;
    const avg_pop_hold_us = if (queue_pop_lock_acquisitions > 0)
        (@as(f64, @floatFromInt(queue_pop_lock_hold_ns_total)) / 1000.0) / @as(f64, @floatFromInt(queue_pop_lock_acquisitions))
    else
        0.0;
    std.debug.print(
        "queue_locks push_avg_wait_us={d:.3} push_avg_hold_us={d:.3} push_contention={d} pop_avg_wait_us={d:.3} pop_avg_hold_us={d:.3} pop_contention={d}\n",
        .{
            avg_push_wait_us,
            avg_push_hold_us,
            queue_push_lock_contention,
            avg_pop_wait_us,
            avg_pop_hold_us,
            queue_pop_lock_contention,
        },
    );

    if (comptime std.mem.eql(u8, alloc_mod.mode, "small_pool")) {
        if (allocator_handle.advanceEpoch()) |epoch| {
            allocator_handle.leaveEpoch(epoch);
        }
        const pool_stats = allocator_handle.snapshotSmallPoolStats();
        if (pool_stats.shard_enabled) {
            std.debug.print(
                "  shards enabled count={d} hits={d} misses={d} deferred={d} epoch_current={d} epoch_min={d}\n",
                .{
                    pool_stats.shard_count,
                    pool_stats.shard_alloc_hits,
                    pool_stats.shard_alloc_misses,
                    pool_stats.shard_deferred_total,
                    pool_stats.shard_current_epoch,
                    pool_stats.shard_min_epoch,
                },
            );
        } else {
            std.debug.print(
                "  shards disabled hits={d} misses={d}\n",
                .{ pool_stats.shard_alloc_hits, pool_stats.shard_alloc_misses },
            );
        }
        std.debug.print(
            "small_pool fallback_allocs={d} fallback_frees={d} fallback_resizes={d} fallback_remaps={d}\n",
            .{ pool_stats.fallback_allocs, pool_stats.fallback_frees, pool_stats.fallback_resizes, pool_stats.fallback_remaps },
        );
        std.debug.print("  fallback_size_buckets:\n", .{});
        inline for (pool_stats.fallback_size_buckets, 0..) |count, bucket_i| {
            const upper = pool_stats.fallback_size_bounds[bucket_i];
            if (upper) |bound| {
                std.debug.print("    <= {d:>5}B : {d}\n", .{ bound, count });
            } else {
                const last = pool_stats.fallback_size_bounds[pool_stats.fallback_size_bounds.len - 2].?;
                std.debug.print("    >  {d:>5}B : {d}\n", .{ last, count });
            }
        }
        for (pool_stats.buckets) |bucket| {
            const lock_acq = bucket.lock_acquisitions;
            const avg_wait_us_bucket = if (lock_acq > 0)
                (@as(f64, @floatFromInt(bucket.lock_wait_ns_total)) / 1000.0) / @as(f64, @floatFromInt(lock_acq))
            else
                0.0;
            const avg_hold_us_bucket = if (lock_acq > 0)
                (@as(f64, @floatFromInt(bucket.lock_hold_ns_total)) / 1000.0) / @as(f64, @floatFromInt(lock_acq))
            else
                0.0;
            std.debug.print(
                "  bucket size={d} alloc_size={d} allocations={d} in_use={d} high_water={d} refills={d} slabs={d} free={d} avg_wait_us={d:.3} avg_hold_us={d:.3} contention={d}\n",
                .{
                    bucket.size,
                    bucket.alloc_size,
                    bucket.allocations,
                    bucket.in_use,
                    bucket.high_water,
                    bucket.refills,
                    bucket.slabs,
                    bucket.free_nodes,
                    avg_wait_us_bucket,
                    avg_hold_us_bucket,
                    bucket.lock_contention,
                },
            );
        }
    }

    if (timed_out) {
        std.debug.print("warning: writer drain timed out after {d} ms\n", .{arg_state.drain_timeout_ms});
    }
}
