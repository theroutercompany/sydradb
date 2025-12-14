---
sidebar_position: 2
title: tools/bench_alloc.zig
---

# `tools/bench_alloc.zig`

## Purpose

Runs a concurrent ingest workload against an in-process `engine.Engine` instance and reports:

- throughput (ops/sec)
- end-to-end ingest call latency distribution
- engine queue drain behavior
- flush statistics (counts, time, points)
- queue lock contention metrics
- allocator stats (when built with the `small_pool` allocator mode)

This tool is intended to compare allocator modes (default vs mimalloc vs small_pool) and to surface queue/flush bottlenecks.

## Imports

- `build_options` – exposes `allocator_mode` string at build time.
- `sydra_tooling` – a tooling module providing:
  - `alloc` (`src/sydra/alloc.zig`)
  - `config` (`src/sydra/config.zig`)
  - `engine` (`src/sydra/engine.zig`)
  - `types` (`src/sydra/types.zig`)

## CLI flags

Parsed by `parseArgs`:

- `--ops N` (default `200000`)
- `--concurrency N` (default `4`)
- `--series N` (default `128`)
- `--drain-timeout-ms N` (default `60000`)
  - `0` disables the timeout (wait indefinitely for queue drain).
- `--poll-ms N` (default `5`)
  - poll interval while waiting for the writer thread to drain.
- `--flush-ms N` (default `200`)
  - engine flush interval.
- `--memtable-mb N` (default `32`)
  - memtable size limit.
- `--stress-seconds N` (default `0`)
  - enables a sustained stress loop when > 0.
- `--stress-ops N` (default `10000`)
  - ops per stress batch per thread.
- `--help` / `-h`

Validation:

- Rejects `concurrency == 0`, `series == 0`.
- Rejects `total_ops == 0` unless `stress_seconds > 0`.

## Data directory lifecycle

`main` creates a per-run data directory in the current working directory:

- name pattern: `bench-data-{timestamp_ms}`

It is deleted via `deleteTree` in a `defer` block after `eng.deinit()`.

## Config construction

### `fn makeConfig(alloc, data_dir, flush_interval, memtable_max) !cfg.Config`

Builds a `cfg.Config` with:

- `data_dir` duplicated into allocator-owned memory
- `http_port = 0`
- `fsync = .none`
- `flush_interval_ms = flush_interval`
- `memtable_max_bytes = memtable_max`
- `retention_days = 0`
- `auth_token = ""` (duplicated)
- `enable_influx = false`
- `enable_prom = false`
- `mem_limit_bytes = 512 MiB`
- `retention_ns = StringHashMap(u32).init(alloc)`

The returned config must be `deinit`’d by the caller when no longer needed.

## Workload generator

### `const ProducerContext`

Per-thread parameters:

- `engine: *engine.Engine`
- `series_ids: []const types.SeriesId`
- `ops: usize`
- `series_offset: usize`
- `ts_base: i64`
- `thread_id: usize`
- `latencies: ?*std.ArrayList(u64) = null`
  - optional per-op latency sink (nanoseconds)
- `stress_result: ?*ThreadStressResult = null`

### `fn producer(ctx: ProducerContext) void`

For `ctx.ops` iterations:

1. Picks a series id:
   - `sid = series_ids[(series_offset + i) % series_ids.len]`
2. Builds a point:
   - `ts = ts_base + i`
   - `value = float(ts)`
3. Calls `eng.ingest(Engine.IngestItem{ series_id, ts, value, tags_json = "{}" })`.
4. Measures latency around the `ingest` call via `std.time.nanoTimestamp()`.
5. Writes `latency_ns` to `latencies` when provided.
6. Accumulates totals into `ThreadStressResult` when provided.

On ingest error, prints:

- `ingest error on thread {thread_id}: {errorName}`

And terminates the thread early.

## Latency statistics

### `fn percentile(sorted: []u64, ratio: f64) u64`

Computes a percentile using linear interpolation between adjacent elements in a sorted sample array.

### `fn printLatencySummary(latencies: []u64) void`

- Sorts `latencies` in-place (ascending).
- Prints `p50`, `p95`, `p99`, `p999` in microseconds.

## Drain + metrics loop

After producers join, `main` waits for the engine’s writer thread to drain:

- Reads:
  - `eng.metrics.ingest_total` (atomic)
  - `eng.queue.len()`
- Exits when:
  - `ingested >= ops_total` and `pending == 0`
- Sleeps `poll_ms` between polls.
- Times out after `drain_timeout_ms` unless timeout is disabled.

The loop also records:

- `max_pending`
- `avg_pending` (via `pending_sum / samples`)

## Output summary

`main` prints several `std.debug.print` lines, including:

- overall throughput and flush summary
- queue drain stats (pending samples, timeout flag)
- queue metrics:
  - `queue_pop_total`, `queue_wait_ns_total`
  - average wait time and average queue length
- queue lock stats:
  - average push/pop lock wait/hold times
  - contention counts

## small_pool-only reporting

When compiled with `alloc_mod.mode == "small_pool"`, the tool prints:

- shard allocator stats (if enabled): hits/misses, deferred totals, epoch range
- fallback allocator counters and size histogram
- per-bucket usage and lock timing/contended acquisition counts

It also advances/leaves an epoch before sampling stats to encourage garbage collection of deferred frees.

## Stress mode

### `fn runStress(allocator, handle, eng, series_ids, threads, contexts, stress_ops, stress_seconds) !void`

Runs for roughly `stress_seconds`, spawning repeated batches:

- Each batch spawns `threads.len` producer threads.
- Each producer runs `stress_ops` ingest calls.
- Per-thread latencies are recorded in `ThreadStressResult` (not in per-op arrays).

After each batch:

- aggregates total ops and total/max latency
- when `alloc_mod.is_small_pool`, tracks the maximum observed `shard_deferred_total`

Prints a final:

```
stress_summary batches=... total_ops=... avg_latency_us=... max_latency_us=... max_deferred=...
```

## Timing helpers

### `fn sleepMs(ms: u64) void`

Uses `std.time.sleep` if available, otherwise falls back to `std.Thread.sleep`.

