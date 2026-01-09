const std = @import("std");
const cfg = @import("config.zig");
const types = @import("types.zig");
const AtomicU64 = @import("atomic_util.zig").AtomicU64;
const manifest_mod = @import("storage/manifest.zig");
const wal_mod = @import("storage/wal.zig");
const segment_mod = @import("storage/segment.zig");
const tags_mod = @import("storage/tags.zig");
const retention = @import("storage/retention.zig");

fn sleepMs(ms: u64) void {
    if (@hasDecl(std.time, "sleep")) {
        std.time.sleep(ms * std.time.ns_per_ms);
    } else {
        std.Thread.sleep(ms * std.time.ns_per_ms);
    }
}

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

    pub const MemTable = struct {
        alloc: std.mem.Allocator,
        series: std.AutoHashMap(types.SeriesId, std.array_list.Managed(types.Point)),
        bytes: std.atomic.Value(usize),
        pub fn init(alloc: std.mem.Allocator) MemTable {
            return .{
                .alloc = alloc,
                .series = std.AutoHashMap(types.SeriesId, std.array_list.Managed(types.Point)).init(alloc),
                .bytes = std.atomic.Value(usize).init(0),
            };
        }
        pub fn deinit(self: *MemTable) void {
            var it = self.series.valueIterator();
            while (it.next()) |lst| lst.deinit();
            self.series.deinit();
        }
    };

    pub const IngestItem = struct {
        series_id: types.SeriesId,
        ts: i64,
        value: f64,
        // raw tags json for future tag index updates
        tags_json: []const u8,
    };

    pub const Queue = struct {
        alloc: std.mem.Allocator,
        mu: std.Thread.Mutex = .{},
        cv: std.Thread.Condition = .{},
        buf: std.array_list.Managed(IngestItem),
        closed: bool = false,
        metrics: *Metrics,
        const lock_wait_threshold_ns: i64 = 1_000;

        pub fn init(alloc: std.mem.Allocator, metrics: *Metrics) !*Queue {
            const q = try alloc.create(Queue);
            q.* = .{
                .alloc = alloc,
                .buf = try std.array_list.Managed(IngestItem).initCapacity(alloc, 0),
                .metrics = metrics,
            };
            return q;
        }
        pub fn deinit(self: *Queue) void {
            self.buf.deinit();
        }
        pub fn push(self: *Queue, item: IngestItem) !void {
            const wait_start = std.time.nanoTimestamp();
            self.mu.lock();
            const acquired_ns = std.time.nanoTimestamp();
            const wait_ns = acquired_ns - wait_start;
            _ = self.metrics.queue_push_lock_acquisitions.fetchAdd(1, .monotonic);
            if (wait_ns > lock_wait_threshold_ns) {
                _ = self.metrics.queue_push_lock_wait_ns_total.fetchAdd(@as(u64, @intCast(wait_ns)), .monotonic);
                _ = self.metrics.queue_push_lock_contention.fetchAdd(1, .monotonic);
            }
            defer {
                const release_ns = std.time.nanoTimestamp();
                const hold_ns = release_ns - acquired_ns;
                _ = self.metrics.queue_push_lock_hold_ns_total.fetchAdd(@as(u64, @intCast(hold_ns)), .monotonic);
                self.mu.unlock();
            }
            if (self.closed) return error.Closed;
            try self.buf.append(item);
            self.cv.signal();
        }
        pub fn pop(self: *Queue) ?IngestItem {
            const lock_begin = std.time.nanoTimestamp();
            self.mu.lock();
            var acquired_ns = std.time.nanoTimestamp();
            var wait_ns = acquired_ns - lock_begin;
            _ = self.metrics.queue_pop_lock_acquisitions.fetchAdd(1, .monotonic);
            if (wait_ns > lock_wait_threshold_ns) {
                _ = self.metrics.queue_pop_lock_wait_ns_total.fetchAdd(@as(u64, @intCast(wait_ns)), .monotonic);
                _ = self.metrics.queue_pop_lock_contention.fetchAdd(1, .monotonic);
            }
            var hold_start_ns = acquired_ns;
            while (self.buf.items.len == 0 and !self.closed) {
                const before_wait_ns = std.time.nanoTimestamp();
                const hold_ns = before_wait_ns - hold_start_ns;
                _ = self.metrics.queue_pop_lock_hold_ns_total.fetchAdd(@as(u64, @intCast(hold_ns)), .monotonic);
                self.cv.timedWait(&self.mu, std.time.ns_per_ms * 100) catch break;
                acquired_ns = std.time.nanoTimestamp();
                wait_ns = acquired_ns - before_wait_ns;
                if (wait_ns > lock_wait_threshold_ns) {
                    _ = self.metrics.queue_pop_lock_wait_ns_total.fetchAdd(@as(u64, @intCast(wait_ns)), .monotonic);
                    _ = self.metrics.queue_pop_lock_contention.fetchAdd(1, .monotonic);
                }
                hold_start_ns = acquired_ns;
            }
            if (self.buf.items.len == 0) {
                const release_ns = std.time.nanoTimestamp();
                const hold_ns = release_ns - hold_start_ns;
                _ = self.metrics.queue_pop_lock_hold_ns_total.fetchAdd(@as(u64, @intCast(hold_ns)), .monotonic);
                self.mu.unlock();
                return null;
            }
            const point = self.buf.orderedRemove(0);
            const release_ns = std.time.nanoTimestamp();
            const hold_ns = release_ns - hold_start_ns;
            _ = self.metrics.queue_pop_lock_hold_ns_total.fetchAdd(@as(u64, @intCast(hold_ns)), .monotonic);
            self.mu.unlock();
            return point;
        }
        pub fn close(self: *Queue) void {
            self.mu.lock();
            self.closed = true;
            self.mu.unlock();
            self.cv.broadcast();
        }
        pub fn len(self: *Queue) usize {
            self.mu.lock();
            defer self.mu.unlock();
            return self.buf.items.len;
        }
    };

    pub const Metrics = struct {
        ingest_total: AtomicU64,
        flush_total: AtomicU64,
        flush_ns_total: AtomicU64,
        flush_points_total: AtomicU64,
        wal_bytes_total: AtomicU64,
        queue_pop_total: AtomicU64,
        queue_wait_ns_total: AtomicU64,
        queue_max_len: std.atomic.Value(usize),
        queue_len_sum: AtomicU64,
        queue_len_samples: AtomicU64,
        queue_push_lock_wait_ns_total: AtomicU64,
        queue_push_lock_hold_ns_total: AtomicU64,
        queue_push_lock_acquisitions: AtomicU64,
        queue_push_lock_contention: AtomicU64,
        queue_pop_lock_wait_ns_total: AtomicU64,
        queue_pop_lock_hold_ns_total: AtomicU64,
        queue_pop_lock_acquisitions: AtomicU64,
        queue_pop_lock_contention: AtomicU64,

        pub fn init() Metrics {
            return .{
                .ingest_total = AtomicU64.init(0),
                .flush_total = AtomicU64.init(0),
                .flush_ns_total = AtomicU64.init(0),
                .flush_points_total = AtomicU64.init(0),
                .wal_bytes_total = AtomicU64.init(0),
                .queue_pop_total = AtomicU64.init(0),
                .queue_wait_ns_total = AtomicU64.init(0),
                .queue_max_len = std.atomic.Value(usize).init(0),
                .queue_len_sum = AtomicU64.init(0),
                .queue_len_samples = AtomicU64.init(0),
                .queue_push_lock_wait_ns_total = AtomicU64.init(0),
                .queue_push_lock_hold_ns_total = AtomicU64.init(0),
                .queue_push_lock_acquisitions = AtomicU64.init(0),
                .queue_push_lock_contention = AtomicU64.init(0),
                .queue_pop_lock_wait_ns_total = AtomicU64.init(0),
                .queue_pop_lock_hold_ns_total = AtomicU64.init(0),
                .queue_pop_lock_acquisitions = AtomicU64.init(0),
                .queue_pop_lock_contention = AtomicU64.init(0),
            };
        }
    };

    pub fn init(alloc: std.mem.Allocator, config: cfg.Config) !*Engine {
        std.fs.cwd().makePath(config.data_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        const data_dir = try std.fs.cwd().openDir(config.data_dir, .{ .iterate = true });
        const wal = try wal_mod.WAL.open(alloc, data_dir, config.fsync);
        var engine = try alloc.create(Engine);
        errdefer alloc.destroy(engine);
        engine.* = .{
            .alloc = alloc,
            .config = config,
            .data_dir = data_dir,
            .wal = wal,
            .mem = MemTable.init(alloc),
            .manifest = try manifest_mod.Manifest.loadOrInit(alloc, data_dir),
            .tags = try tags_mod.TagIndex.loadOrInit(alloc, data_dir),
            .flush_timer_ms = config.flush_interval_ms,
            .metrics = Metrics.init(),
            .queue = undefined,
        };
        errdefer {
            engine.mem.deinit();
            engine.manifest.deinit();
            engine.tags.deinit();
            engine.wal.close();
            engine.data_dir.close();
            engine.config.deinit(engine.alloc);
        }
        engine.queue = try Queue.init(alloc, &engine.metrics);
        errdefer {
            engine.queue.deinit();
            engine.alloc.destroy(engine.queue);
        }
        try engine.recover();
        engine.writer_thread = try std.Thread.spawn(.{}, writerLoop, .{engine});
        return engine;
    }

    pub fn deinit(self: *Engine) void {
        self.stop_flag = true;
        self.queue.close();
        if (self.writer_thread) |t| t.join();
        self.mem.deinit();
        self.manifest.deinit();
        self.tags.deinit();
        self.wal.close();
        self.data_dir.close();
        self.queue.deinit();
        self.alloc.destroy(self.queue);
        self.config.deinit(self.alloc);
        self.alloc.destroy(self);
    }

    pub fn ingest(self: *Engine, item: IngestItem) !void {
        try self.queue.push(item);
        const len_now = self.queue.len();
        const len_now_u64: u64 = @intCast(len_now);
        _ = self.metrics.queue_len_sum.fetchAdd(len_now_u64, .monotonic);
        _ = self.metrics.queue_len_samples.fetchAdd(1, .monotonic);
        var current_max = self.metrics.queue_max_len.load(.monotonic);
        while (len_now > current_max) {
            if (self.metrics.queue_max_len.cmpxchgWeak(current_max, len_now, .monotonic, .monotonic)) |prev|
                current_max = prev
            else
                break;
        }
    }

    fn writerLoop(self: *Engine) void {
        var last_flush = std.time.milliTimestamp();
        var last_sync = last_flush;
        var last_pop_ns = std.time.nanoTimestamp();
        while (!self.stop_flag) {
            if (self.queue.pop()) |it| {
                const now_ns = std.time.nanoTimestamp();
                const wait_delta = now_ns - last_pop_ns;
                _ = self.metrics.queue_pop_total.fetchAdd(1, .monotonic);
                if (wait_delta > 0) {
                    _ = self.metrics.queue_wait_ns_total.fetchAdd(@as(u64, @intCast(wait_delta)), .monotonic);
                }
                last_pop_ns = now_ns;
                // WAL append
                const wal_bytes = self.wal.append(it.series_id, it.ts, it.value) catch 0;
                if (wal_bytes != 0) {
                    const wal_bytes_u64: u64 = @intCast(wal_bytes);
                    _ = self.metrics.wal_bytes_total.fetchAdd(wal_bytes_u64, .monotonic);
                }
                // Memtable insert
                if (self.appendMemtablePoint(it.series_id, it.ts, it.value)) |_| {
                    _ = self.metrics.ingest_total.fetchAdd(1, .monotonic);
                } else |err| {
                    std.log.warn("failed to append to memtable: {s}", .{@errorName(err)});
                    continue;
                }
            } else sleepMs(10);

            const now = std.time.milliTimestamp();
            const mem_usage = self.mem.bytes.load(.monotonic);
            if (mem_usage >= self.config.memtable_max_bytes or (now - last_flush) >= self.flush_timer_ms) {
                flushMemtable(self) catch |err| {
                    std.log.warn("memtable flush failed: {s}", .{@errorName(err)});
                };
                last_flush = now;
                // apply retention best-effort after flush
                retention.apply(self.data_dir, &self.manifest, self.config.retention_days) catch |err| {
                    std.log.warn("retention apply failed: {s}", .{@errorName(err)});
                };
            }
            // fsync policy: interval
            if (self.config.fsync == .interval and (now - last_sync) >= self.flush_timer_ms) {
                self.wal.file.sync() catch |err| {
                    std.log.warn("wal sync failed: {s}", .{@errorName(err)});
                };
                last_sync = now;
            }
        }
        // final flush
        flushMemtable(self) catch |err| {
            std.log.warn("final memtable flush failed: {s}", .{@errorName(err)});
        };
    }

    fn flushMemtable(self: *Engine) !void {
        const start_ns = std.time.nanoTimestamp();
        var points_written: usize = 0;
        var segments_written: usize = 0;
        // write per-series per-hour segments, update manifest, then clear memtable
        var it = self.mem.series.iterator();
        while (it.next()) |entry| {
            const sid = entry.key_ptr.*;
            const arr_ptr = entry.value_ptr;
            if (arr_ptr.*.items.len == 0) continue;
            std.sort.block(types.Point, arr_ptr.*.items, {}, struct {
                fn lessThan(_: void, a: types.Point, b: types.Point) bool {
                    return a.ts < b.ts;
                }
            }.lessThan);
            // Partition by hour (UTC)
            var start_idx: usize = 0;
            while (start_idx < arr_ptr.*.items.len) {
                const hour = hourBucket(arr_ptr.*.items[start_idx].ts);
                var end_idx = start_idx + 1;
                while (end_idx < arr_ptr.*.items.len and hourBucket(arr_ptr.*.items[end_idx].ts) == hour) : (end_idx += 1) {}
                const slice = arr_ptr.*.items[start_idx..end_idx];
                // write segment
                const seg_path = try segment_mod.writeSegment(self.alloc, self.data_dir, sid, hour, slice);
                const c: u32 = @intCast(slice.len);
                try self.manifest.add(self.data_dir, sid, hour, slice[0].ts, slice[slice.len - 1].ts, c, seg_path);
                self.alloc.free(seg_path);
                points_written += slice.len;
                segments_written += 1;
                start_idx = end_idx;
            }
            arr_ptr.*.clearRetainingCapacity();
        }
        self.mem.bytes.store(0, .monotonic);
        if (segments_written > 0) {
            const duration_ns_i128 = std.time.nanoTimestamp() - start_ns;
            const duration_ns: u64 = @intCast(duration_ns_i128);
            const points_u64: u64 = @intCast(points_written);
            _ = self.metrics.flush_total.fetchAdd(1, .monotonic);
            _ = self.metrics.flush_ns_total.fetchAdd(duration_ns, .monotonic);
            _ = self.metrics.flush_points_total.fetchAdd(points_u64, .monotonic);
            const duration_ms = if (std.time.ns_per_ms == 0) 0 else duration_ns / std.time.ns_per_ms;
            std.log.info("flush completed: segments={d} points={d} duration_ms={d}", .{ segments_written, points_written, duration_ms });
        }
        // rotate WAL optionally
        self.wal.rotateIfNeeded() catch |err| {
            std.log.warn("wal rotation failed: {s}", .{@errorName(err)});
        };
        // persist tag index snapshot (best-effort)
        self.tags.save(self.data_dir) catch |err| {
            std.log.warn("tag index save failed: {s}", .{@errorName(err)});
        };
    }

    fn hourBucket(ts: i64) i64 {
        const secs_per_hour: i64 = 3600;
        return (@divTrunc(ts, secs_per_hour)) * secs_per_hour;
    }

    pub fn queryRange(self: *Engine, series_id: types.SeriesId, start_ts: i64, end_ts: i64, out: *std.array_list.Managed(types.Point)) !void {
        try segment_mod.queryRange(self.alloc, self.data_dir, &self.manifest, series_id, start_ts, end_ts, out);
    }

    pub fn noteTags(self: *Engine, series_id: types.SeriesId, tags: []const u8) void {
        // tags is expected to be a JSON object; we parse and update tag→series mapping
        var parsed = std.json.parseFromSlice(std.json.Value, self.alloc, tags, .{}) catch return;
        defer parsed.deinit();
        if (parsed.value != .object) return;
        var it = parsed.value.object.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.* == .string) {
                const key = std.fmt.allocPrint(self.alloc, "{s}={s}", .{ e.key_ptr.*, e.value_ptr.string }) catch continue;
                defer self.alloc.free(key);
                self.tags.add(key, series_id) catch |err| {
                    std.log.warn("tag index add failed: {s}", .{@errorName(err)});
                };
            }
        }
    }

    fn appendMemtablePoint(self: *Engine, sid: types.SeriesId, ts: i64, value: f64) !void {
        const gop = try self.mem.series.getOrPut(sid);
        if (!gop.found_existing) {
            gop.value_ptr.* = std.array_list.Managed(types.Point).init(self.alloc);
        }
        try gop.value_ptr.*.append(.{ .ts = ts, .value = value });
        _ = self.mem.bytes.fetchAdd(@sizeOf(types.Point), .monotonic);
    }

    fn recover(self: *Engine) !void {
        var highwater = std.AutoHashMap(types.SeriesId, i64).init(self.alloc);
        defer highwater.deinit();

        for (self.manifest.entries.items) |entry| {
            const gop = try highwater.getOrPut(entry.series_id);
            if (!gop.found_existing or entry.end_ts > gop.value_ptr.*) {
                gop.value_ptr.* = entry.end_ts;
            }
        }

        var ctx = struct {
            engine: *Engine,
            highwater: *std.AutoHashMap(types.SeriesId, i64),
            pub fn onRecord(self_ctx: *@This(), series_id: types.SeriesId, ts: i64, value: f64) !void {
                if (self_ctx.highwater.getPtr(series_id)) |ptr| {
                    if (ts <= ptr.*) return;
                }
                try self_ctx.engine.appendMemtablePoint(series_id, ts, value);
                if (self_ctx.highwater.getPtr(series_id)) |ptr| {
                    if (ts > ptr.*) ptr.* = ts;
                } else {
                    try self_ctx.highwater.put(series_id, ts);
                }
            }
        }{ .engine = self, .highwater = &highwater };

        try self.wal.replay(self.alloc, &ctx);
        if (self.mem.bytes.load(.monotonic) > 0) {
            try flushMemtable(self);
        }
    }
};

const waitError = error{Timeout};

fn waitForFlush(engine: *Engine, expected_entries: usize, timeout_ms: u64) waitError!void {
    const deadline: i64 = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
    while (std.time.milliTimestamp() < deadline) {
        if (engine.manifest.entries.items.len >= expected_entries and engine.mem.bytes.load(.monotonic) == 0)
            return;
        sleepMs(10);
    }
    return waitError.Timeout;
}

test "engine ingests, flushes, and queries range" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/data", .{tmp.sub_path});
    defer talloc.free(data_path);

    const config = cfg.Config{
        .data_dir = try talloc.dupe(u8, data_path),
        .http_port = 0,
        .fsync = .none,
        .flush_interval_ms = 5,
        .memtable_max_bytes = 512,
        .retention_days = 0,
        .auth_token = try talloc.dupe(u8, ""),
        .enable_influx = false,
        .enable_prom = false,
        .mem_limit_bytes = 1024 * 1024,
        .retention_ns = std.StringHashMap(u32).init(talloc),
    };

    var engine = try Engine.init(talloc, config);
    defer engine.deinit();

    const sid = types.hash64("cpu.total");
    try engine.ingest(.{ .series_id = sid, .ts = 1_000, .value = 1.5, .tags_json = "{}" });
    try engine.ingest(.{ .series_id = sid, .ts = 1_500, .value = 2.25, .tags_json = "{}" });
    engine.noteTags(sid, "{\"host\":\"a\"}");

    try waitForFlush(engine, 1, 1_000);

    var results = std.array_list.Managed(types.Point).init(talloc);
    defer results.deinit();
    try engine.queryRange(sid, 0, 10_000, &results);
    try std.testing.expectEqual(@as(usize, 2), results.items.len);
    try std.testing.expectEqual(@as(i64, 1_000), results.items[0].ts);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), results.items[0].value, 1e-9);
    try std.testing.expectEqual(@as(i64, 1_500), results.items[1].ts);

    const matches = engine.tags.get("host=a");
    try std.testing.expectEqual(@as(usize, 1), matches.len);
    try std.testing.expectEqual(sid, matches[0]);
}

test "engine replays wal on startup" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/data", .{tmp.sub_path});
    defer talloc.free(data_path);

    const sid = types.hash64("sensor.temp");

    {
        try std.fs.cwd().makePath(data_path);
        var data_dir = try std.fs.cwd().openDir(data_path, .{ .iterate = true });
        defer data_dir.close();
        var wal = try wal_mod.WAL.open(talloc, data_dir, .none);
        _ = try wal.append(sid, 1_000, 42.0);
        _ = try wal.append(sid, 1_050, 43.5);
        wal.close();
    }

    const config = cfg.Config{
        .data_dir = try talloc.dupe(u8, data_path),
        .http_port = 0,
        .fsync = .none,
        .flush_interval_ms = 100,
        .memtable_max_bytes = 1024,
        .retention_days = 0,
        .auth_token = try talloc.dupe(u8, ""),
        .enable_influx = false,
        .enable_prom = false,
        .mem_limit_bytes = 1024 * 1024,
        .retention_ns = std.StringHashMap(u32).init(talloc),
    };

    var engine = try Engine.init(talloc, config);
    defer engine.deinit();

    var results = std.array_list.Managed(types.Point).init(talloc);
    defer results.deinit();
    try engine.queryRange(sid, 0, 10_000, &results);
    try std.testing.expectEqual(@as(usize, 2), results.items.len);
    try std.testing.expectEqual(@as(i64, 1_000), results.items[0].ts);
    try std.testing.expectApproxEqAbs(@as(f64, 42.0), results.items[0].value, 1e-9);
    try std.testing.expectEqual(@as(i64, 1_050), results.items[1].ts);
}

test "engine metrics track ingest and flush" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/data", .{tmp.sub_path});
    defer talloc.free(data_path);

    const config = cfg.Config{
        .data_dir = try talloc.dupe(u8, data_path),
        .http_port = 0,
        .fsync = .none,
        .flush_interval_ms = 5,
        .memtable_max_bytes = 512,
        .retention_days = 0,
        .auth_token = try talloc.dupe(u8, ""),
        .enable_influx = false,
        .enable_prom = false,
        .mem_limit_bytes = 1024 * 1024,
        .retention_ns = std.StringHashMap(u32).init(talloc),
    };

    var engine = try Engine.init(talloc, config);
    defer engine.deinit();

    const sid = types.hash64("metrics.series");
    try engine.ingest(.{ .series_id = sid, .ts = 10, .value = 1.0, .tags_json = "{}" });
    try engine.ingest(.{ .series_id = sid, .ts = 20, .value = 2.0, .tags_json = "{}" });
    try engine.ingest(.{ .series_id = sid, .ts = 30, .value = 3.0, .tags_json = "{}" });

    try waitForFlush(engine, 1, 1_000);

    const ingest_total = engine.metrics.ingest_total.load(.monotonic);
    try std.testing.expectEqual(@as(u64, 3), ingest_total);
    const flush_total = engine.metrics.flush_total.load(.monotonic);
    try std.testing.expectEqual(@as(u64, 1), flush_total);
    const flush_points = engine.metrics.flush_points_total.load(.monotonic);
    try std.testing.expectEqual(@as(u64, 3), flush_points);
    const wal_bytes = engine.metrics.wal_bytes_total.load(.monotonic);
    try std.testing.expect(wal_bytes > 0);
    const flush_ns = engine.metrics.flush_ns_total.load(.monotonic);
    try std.testing.expect(flush_ns > 0);
}
