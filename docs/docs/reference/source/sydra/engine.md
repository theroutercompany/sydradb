---
sidebar_position: 5
title: src/sydra/engine.zig
---

# `src/sydra/engine.zig`

## Purpose

Core ingest/query engine:

- Accepts ingest items via an in-memory queue
- Appends every ingested point to a WAL for crash safety
- Buffers points in an in-memory memtable
- Flushes memtable into on-disk per-series, per-hour segments and updates the manifest
- Serves range queries by delegating to the segment/query layer
- Maintains a simple tag index for tag→series lookups

## Key imports and dependencies

- `src/sydra/config.zig` – runtime configuration
- `src/sydra/types.zig` – `SeriesId`, `Point`
- `src/sydra/storage/wal.zig` – write-ahead log
- `src/sydra/storage/segment.zig` – segment writer + range query implementation
- `src/sydra/storage/manifest.zig` – segment manifest persisted on disk
- `src/sydra/storage/tags.zig` – tag index
- `src/sydra/storage/retention.zig` – retention pass (segment deletion)

## Public API (Engine)

### `pub const Engine = struct { ... }`

Important fields:

- `config: cfg.Config` – owned config (freed on `deinit`)
- `data_dir: std.fs.Dir` – open handle to `config.data_dir`
- `wal: wal_mod.WAL` – append-only durability log
- `mem: MemTable` – in-memory buffer (`SeriesId` → `[]Point`)
- `manifest: manifest_mod.Manifest` – tracked segments
- `tags: tags_mod.TagIndex` – tag→series index
- `metrics: Metrics` – atomic counters used by `/metrics`
- `queue: *Queue` – ingest work queue processed by the writer thread
- `writer_thread: ?std.Thread` – background writer
- `stop_flag: bool` – shutdown coordination

```zig title="Engine struct fields (excerpt)"
pub const Engine = struct {
    alloc: std.mem.Allocator,
    config: cfg.Config,
    data_dir: std.fs.Dir,
    wal: wal_mod.WAL,
    mem: MemTable,
    manifest: manifest_mod.Manifest,
    tags: tags_mod.TagIndex,
    flush_timer_ms: u32,
    metrics: Metrics,
    writer_thread: ?std.Thread = null,
    stop_flag: bool = false,
    queue: *Queue,
    // ...
};
```

#### `pub fn init(alloc: std.mem.Allocator, config: cfg.Config) !*Engine`

Creates an engine instance:

1. Ensures `config.data_dir` exists (`makePath`).
2. Opens the directory and the WAL (`WAL.open(..., config.fsync)`).
3. Loads or initializes:
   - the manifest (`Manifest.loadOrInit`)
   - the tag index (`TagIndex.loadOrInit`)
4. Allocates the ingest queue (`Queue.init`).
5. Calls `recover()` to replay the WAL and flush recovered points.
6. Spawns the background writer thread (`writerLoop`).

```zig title="Engine.init happy-path (excerpt)"
pub fn init(alloc: std.mem.Allocator, config: cfg.Config) !*Engine {
    std.fs.cwd().makePath(config.data_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const data_dir = try std.fs.cwd().openDir(config.data_dir, .{ .iterate = true });
    const wal = try wal_mod.WAL.open(alloc, data_dir, config.fsync);

    // allocate Engine, load manifest/tags, create queue, recover, spawn writer thread
    // ...
}
```

#### `pub fn deinit(self: *Engine) void`

Stops the writer thread and releases resources:

- Sets `stop_flag`, closes the queue, joins the writer thread.
- Deinitializes memtable, manifest, tag index, WAL, queue.
- Closes `data_dir`.
- Frees owned config allocations.

#### `pub fn ingest(self: *Engine, item: IngestItem) !void`

Enqueues an ingest item and updates queue length metrics (`queue_len_sum`, `queue_len_samples`, `queue_max_len`).

The actual WAL append + memtable insert happens asynchronously in `writerLoop`.

```zig title="Ingest enqueue + queue depth metrics (excerpt)"
pub fn ingest(self: *Engine, item: IngestItem) !void {
    try self.queue.push(item);

    const len_now = self.queue.len();
    const len_now_u64: u64 = @intCast(len_now);
    _ = self.metrics.queue_len_sum.fetchAdd(len_now_u64, .monotonic);
    _ = self.metrics.queue_len_samples.fetchAdd(1, .monotonic);

    // update queue_max_len using a cmpxchgWeak loop
    // ...
}
```

#### `pub fn queryRange(self: *Engine, series_id: types.SeriesId, start_ts: i64, end_ts: i64, out: *Managed(Point)) !void`

Delegates range querying to `segment_mod.queryRange(...)` using the manifest and on-disk data directory.

```zig title="Range query delegate (excerpt)"
pub fn queryRange(
    self: *Engine,
    series_id: types.SeriesId,
    start_ts: i64,
    end_ts: i64,
    out: *std.array_list.Managed(types.Point),
) !void {
    try segment_mod.queryRange(self.alloc, self.data_dir, &self.manifest, series_id, start_ts, end_ts, out);
}
```

#### `pub fn noteTags(self: *Engine, series_id: types.SeriesId, tags: []const u8) void`

Updates the tag index by parsing `tags` as a JSON object string:

- For each string-valued field `{k: v}`, it adds a mapping for the key `"{k}={v}"` → `series_id`.

This is used by HTTP ingest (`/api/v1/ingest`) to populate the tag lookup surface (`/api/v1/query/find`).

## Nested public types

### `pub const MemTable`

- Stores `SeriesId` → `Managed(Point)` arrays.
- Tracks approximate memory usage via `bytes: atomic(usize)` (incremented by `@sizeOf(Point)` per appended point).

### `pub const IngestItem`

Fields:

- `series_id: SeriesId`
- `ts: i64`
- `value: f64`
- `tags_json: []const u8` – currently carried through the queue but not consumed by `writerLoop`

### `pub const Queue`

A mutex+condition-variable queue for ingest items.

Notable behavior:

- `push` appends and signals the CV.
- `pop` waits (timed) until there is an item or the queue is closed, then returns FIFO via `orderedRemove(0)`.
- Records lock contention/hold metrics around push/pop operations.
- `close` marks closed and broadcasts to wake waiting threads.

### `pub const Metrics`

Atomic counters used for observability, including:

- ingest/flush counters (`ingest_total`, `flush_total`, `flush_points_total`, `flush_ns_total`)
- WAL bytes (`wal_bytes_total`)
- queue depth / latency aggregates
- queue lock contention diagnostics

## Internal flow (high level)

### Writer thread (`writerLoop`)

For each popped ingest item:

1. Appends `(series_id, ts, value)` to the WAL.
2. Appends `(ts, value)` to the memtable for `series_id`.
3. On flush triggers (time or size), calls `flushMemtable`:
   - Writes per-series per-hour segments
   - Updates manifest
   - Rotates WAL (best-effort)
   - Saves tag index snapshot (best-effort)
   - Applies retention (`retention.apply(..., config.retention_days)`) best-effort

### Recovery (`recover`)

On startup:

- Builds a per-series “highwater” map from the manifest end timestamps.
- Replays WAL records, only applying points newer than the manifest highwater.
- Flushes recovered points to segments.

## Tests

Inline tests cover:

- ingest → flush → range query (`test "engine ingests, flushes, and queries range"`)
- WAL replay on startup (`test "engine replays wal on startup"`)
- metrics tracking (`test "engine metrics track ingest and flush"`)
