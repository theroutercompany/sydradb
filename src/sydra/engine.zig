const std = @import("std");
const cfg = @import("config.zig");
const types = @import("types.zig");
const AtomicU64 = @import("atomic_util.zig").AtomicU64;
const manifest_mod = @import("storage/manifest.zig");
const object_store = @import("storage/object_store.zig");
const series_catalog_mod = @import("storage/series_catalog.zig");
const wal_mod = @import("storage/wal.zig");
const segment_mod = @import("storage/segment.zig");
const tags_mod = @import("storage/tags.zig");
const retention = @import("storage/retention.zig");
const cas_mod = @import("storage/cas.zig");
const query_ast = @import("query/ast.zig");
const query_expression = @import("query/expression.zig");
const query_plan = @import("query/plan.zig");

fn sleepMs(ms: u64) void {
    if (@hasDecl(std.time, "sleep")) {
        std.Thread.sleep(ms * std.time.ns_per_ms);
    } else {
        std.Thread.sleep(ms * std.time.ns_per_ms);
    }
}

const failed_ingest_quarantine_dir = "quarantine";
const failed_ingest_quarantine_path = "quarantine/failed_ingest.jsonl";

pub const Engine = struct {
    alloc: std.mem.Allocator,
    config: cfg.Config,
    data_dir: std.fs.Dir,
    wal: wal_mod.WAL,
    mem: MemTable,
    metadata: MetadataState,
    flush_timer_ms: u32,
    metrics: Metrics,
    writer_thread: ?std.Thread = null,
    stop_flag: bool = false,
    queue: *Queue,
    cas: ?cas_mod.CasManager = null,

    pub const SelectorLookup = union(enum) {
        by_id: types.SeriesId,
        name: []const u8,
        exact: struct {
            series: []const u8,
            tags_json: []const u8,
        },
    };

    pub const MetadataState = struct {
        alloc: std.mem.Allocator,
        manifest: manifest_mod.Manifest,
        tags: tags_mod.TagIndex,
        series_catalog: series_catalog_mod.SeriesCatalog,
        cas_index: ?cas_mod.SnapshotIndex = null,
        cas_index_mu: std.Thread.Mutex = .{},

        pub fn deinit(self: *MetadataState) void {
            self.manifest.deinit();
            self.tags.deinit();
            self.series_catalog.deinit();
            self.cas_index_mu.lock();
            defer self.cas_index_mu.unlock();
            if (self.cas_index) |*index| {
                index.deinit();
                self.cas_index = null;
            }
        }

        pub fn load(
            alloc: std.mem.Allocator,
            data_dir: std.fs.Dir,
            config: cfg.Config,
            wal: *wal_mod.WAL,
            cas_manager: ?*cas_mod.CasManager,
        ) !MetadataState {
            if (config.metadata_read_mode == .primary and cas_manager != null) {
                if (try cas_manager.?.refs.readHead(cas_mod.main_ref) != null) {
                    return try loadFromCas(alloc, config.fsync, cas_manager.?);
                }
            }
            return try loadFromLegacy(alloc, data_dir, config.fsync, wal, cas_manager);
        }

        pub fn refreshCasIndex(self: *MetadataState, cas: *cas_mod.CasManager) !void {
            var next = try cas.loadHeadIndex();
            errdefer next.deinit();

            self.cas_index_mu.lock();
            defer self.cas_index_mu.unlock();
            if (self.cas_index) |*index| index.deinit();
            self.cas_index = next;
        }

        pub fn refreshCasIndexIfStale(self: *MetadataState, cas: *cas_mod.CasManager) !void {
            self.cas_index_mu.lock();
            defer self.cas_index_mu.unlock();

            const head = try cas.refs.readHead(cas_mod.main_ref) orelse {
                if (self.cas_index) |*index| {
                    index.deinit();
                    self.cas_index = null;
                }
                return;
            };
            if (self.cas_index) |*index| {
                if (index.snapshot.commit_id.eql(head)) return;
            }

            var next = try cas.loadHeadIndex();
            errdefer next.deinit();
            if (self.cas_index) |*index| index.deinit();
            self.cas_index = next;
        }

        fn legacyView(self: *MetadataState) MetadataView {
            return .{ .legacy = self };
        }

        pub fn queryRangeFromCas(
            self: *MetadataState,
            alloc: std.mem.Allocator,
            data_dir: std.fs.Dir,
            series_id: types.SeriesId,
            start_ts: i64,
            end_ts: i64,
            out: *std.array_list.Managed(types.Point),
        ) !bool {
            self.cas_index_mu.lock();
            defer self.cas_index_mu.unlock();
            if (self.cas_index) |*index| {
                try index.queryRange(alloc, data_dir, series_id, start_ts, end_ts, out);
                return true;
            }
            return false;
        }

        pub fn resolveBySeriesIdFromCas(self: *MetadataState, series_id: types.SeriesId) ?series_catalog_mod.Resolution {
            self.cas_index_mu.lock();
            defer self.cas_index_mu.unlock();
            if (self.cas_index) |*index| return index.resolveBySeriesId(series_id);
            return null;
        }

        pub fn resolveUniqueSeriesNameDetailedFromCas(self: *MetadataState, series: []const u8) ?series_catalog_mod.Resolution {
            self.cas_index_mu.lock();
            defer self.cas_index_mu.unlock();
            if (self.cas_index) |*index| return index.resolveUniqueSeriesNameDetailed(series);
            return null;
        }

        pub fn resolveExactSeriesDetailedFromCas(
            self: *MetadataState,
            series: []const u8,
            tags_json: []const u8,
        ) !?series_catalog_mod.Resolution {
            self.cas_index_mu.lock();
            defer self.cas_index_mu.unlock();
            if (self.cas_index) |*index| return try index.resolveExactSeriesDetailed(series, tags_json);
            return null;
        }

        pub fn collectMatchingSeriesIdsFromCas(
            self: *MetadataState,
            alloc: std.mem.Allocator,
            tags_value: std.json.Value,
            op_and: bool,
        ) !?std.array_list.Managed(types.SeriesId) {
            self.cas_index_mu.lock();
            defer self.cas_index_mu.unlock();
            if (self.cas_index) |*index| return try collectMatchingSeriesIdsFromSnapshotIndex(alloc, index, tags_value, op_and);
            return null;
        }

        pub fn hasCasIndex(self: *MetadataState) bool {
            self.cas_index_mu.lock();
            defer self.cas_index_mu.unlock();
            return self.cas_index != null;
        }

        fn loadFromLegacy(
            alloc: std.mem.Allocator,
            data_dir: std.fs.Dir,
            fsync: cfg.FsyncPolicy,
            wal: *wal_mod.WAL,
            cas_manager: ?*cas_mod.CasManager,
        ) !MetadataState {
            var manifest = try manifest_mod.Manifest.loadOrInit(alloc, data_dir);
            errdefer manifest.deinit();
            var tags = try tags_mod.TagIndex.loadOrInit(alloc, data_dir);
            errdefer tags.deinit();
            var series_catalog = try loadSeriesCatalogWithRepair(alloc, data_dir, fsync, &manifest, wal, cas_manager);
            errdefer series_catalog.deinit();
            return .{
                .alloc = alloc,
                .manifest = manifest,
                .tags = tags,
                .series_catalog = series_catalog,
                .cas_index = null,
            };
        }

        fn loadFromCas(
            alloc: std.mem.Allocator,
            fsync: cfg.FsyncPolicy,
            cas_manager: *cas_mod.CasManager,
        ) !MetadataState {
            var index = try cas_manager.loadHeadIndex();
            errdefer index.deinit();
            var manifest = try manifestFromSnapshot(alloc, index.snapshot.segment_descriptors);
            errdefer manifest.deinit();
            var tags = try tagIndexFromSnapshot(alloc, index.snapshot.tag_snapshot);
            errdefer tags.deinit();
            var series_catalog = try seriesCatalogFromSnapshot(alloc, fsync, index.snapshot.series_catalog_snapshot);
            errdefer series_catalog.deinit();
            return .{
                .alloc = alloc,
                .manifest = manifest,
                .tags = tags,
                .series_catalog = series_catalog,
                .cas_index = index,
            };
        }
    };

    const MetadataView = union(enum) {
        legacy: *MetadataState,
        cas: *cas_mod.SnapshotIndex,

        fn queryRange(self: @This(), alloc: std.mem.Allocator, data_dir: std.fs.Dir, series_id: types.SeriesId, start_ts: i64, end_ts: i64, out: *std.array_list.Managed(types.Point)) !void {
            switch (self) {
                .legacy => |metadata| try segment_mod.queryRange(alloc, data_dir, &metadata.manifest, series_id, start_ts, end_ts, out),
                .cas => |index| try index.queryRange(alloc, data_dir, series_id, start_ts, end_ts, out),
            }
        }

        fn tagMatches(self: @This(), key: []const u8) []const types.SeriesId {
            return switch (self) {
                .legacy => |metadata| metadata.tags.get(key),
                .cas => |index| index.tagMatches(key),
            };
        }

        fn resolveUniqueSeriesName(self: @This(), series: []const u8) series_catalog_mod.Match {
            return self.resolveUniqueSeriesNameDetailed(series).toMatch();
        }

        fn resolveUniqueSeriesNameDetailed(self: @This(), series: []const u8) series_catalog_mod.Resolution {
            return switch (self) {
                .legacy => |metadata| metadata.series_catalog.resolveUniqueNameDetailed(series),
                .cas => |index| index.resolveUniqueSeriesNameDetailed(series),
            };
        }

        fn resolveExactSeries(self: @This(), series: []const u8, tags_json: []const u8) !series_catalog_mod.Match {
            return (try self.resolveExactSeriesDetailed(series, tags_json)).toMatch();
        }

        fn resolveExactSeriesDetailed(self: @This(), series: []const u8, tags_json: []const u8) !series_catalog_mod.Resolution {
            return switch (self) {
                .legacy => |metadata| try metadata.series_catalog.resolveExactDetailed(series, tags_json),
                .cas => |index| try index.resolveExactSeriesDetailed(series, tags_json),
            };
        }

        fn resolveBySeriesId(self: @This(), series_id: types.SeriesId) series_catalog_mod.Resolution {
            return switch (self) {
                .legacy => |metadata| metadata.series_catalog.resolveBySeriesId(series_id),
                .cas => |index| index.resolveBySeriesId(series_id),
            };
        }
    };

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
        // Queue-owned copy of the canonical tags JSON kept for parity across
        // async ingest entrypoints.
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
            for (self.buf.items) |item| self.alloc.free(item.tags_json);
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
            const owned_tags = try self.alloc.dupe(u8, item.tags_json);
            errdefer self.alloc.free(owned_tags);
            try self.buf.append(.{
                .series_id = item.series_id,
                .ts = item.ts,
                .value = item.value,
                .tags_json = owned_tags,
            });
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
        pub fn reopen(self: *Queue) void {
            self.mu.lock();
            self.closed = false;
            self.mu.unlock();
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
        wal_append_total: AtomicU64,
        wal_append_ns_total: AtomicU64,
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
        query_compile_attempts_total: AtomicU64,
        query_compile_success_total: AtomicU64,
        query_compile_fallback_total: AtomicU64,
        query_compile_unsupported_total: AtomicU64,
        query_compile_series_not_found_total: AtomicU64,
        query_compile_ambiguous_selector_total: AtomicU64,
        query_compile_shadow_mismatch_total: AtomicU64,
        ingest_rejected_total: AtomicU64,
        ingest_rejected_mem_limit_total: AtomicU64,
        wal_append_failed_total: AtomicU64,
        memtable_append_failed_total: AtomicU64,
        ingest_quarantined_total: AtomicU64,
        ingest_quarantine_write_failed_total: AtomicU64,
        cas_sync_total: AtomicU64,
        cas_sync_failed_total: AtomicU64,
        cas_sync_ns_total: AtomicU64,
        cas_shadow_mismatch_total: AtomicU64,

        pub fn init() Metrics {
            return .{
                .ingest_total = AtomicU64.init(0),
                .flush_total = AtomicU64.init(0),
                .flush_ns_total = AtomicU64.init(0),
                .flush_points_total = AtomicU64.init(0),
                .wal_append_total = AtomicU64.init(0),
                .wal_append_ns_total = AtomicU64.init(0),
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
                .query_compile_attempts_total = AtomicU64.init(0),
                .query_compile_success_total = AtomicU64.init(0),
                .query_compile_fallback_total = AtomicU64.init(0),
                .query_compile_unsupported_total = AtomicU64.init(0),
                .query_compile_series_not_found_total = AtomicU64.init(0),
                .query_compile_ambiguous_selector_total = AtomicU64.init(0),
                .query_compile_shadow_mismatch_total = AtomicU64.init(0),
                .ingest_rejected_total = AtomicU64.init(0),
                .ingest_rejected_mem_limit_total = AtomicU64.init(0),
                .wal_append_failed_total = AtomicU64.init(0),
                .memtable_append_failed_total = AtomicU64.init(0),
                .ingest_quarantined_total = AtomicU64.init(0),
                .ingest_quarantine_write_failed_total = AtomicU64.init(0),
                .cas_sync_total = AtomicU64.init(0),
                .cas_sync_failed_total = AtomicU64.init(0),
                .cas_sync_ns_total = AtomicU64.init(0),
                .cas_shadow_mismatch_total = AtomicU64.init(0),
            };
        }
    };

    pub fn init(alloc: std.mem.Allocator, config: cfg.Config) !*Engine {
        if (config.metadata_read_mode != .legacy and config.cas_mode == .off) {
            return error.CasReadModeRequiresCas;
        }
        std.fs.cwd().makePath(config.data_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        const data_dir = try std.fs.cwd().openDir(config.data_dir, .{ .iterate = true });
        var cas_manager: ?cas_mod.CasManager = null;
        var cas_manager_transferred = false;
        errdefer if (!cas_manager_transferred) {
            if (cas_manager) |*cas| cas.deinit();
        };
        if (config.cas_mode == .dual_write) {
            cas_manager = try cas_mod.CasManager.init(alloc, config.data_dir, config.fsync);
        }
        var wal = try wal_mod.WAL.open(alloc, data_dir, config.fsync);
        var metadata = try MetadataState.load(alloc, data_dir, config, &wal, if (cas_manager) |*cas| cas else null);
        var metadata_transferred = false;
        errdefer if (!metadata_transferred) metadata.deinit();

        var engine = try alloc.create(Engine);
        errdefer alloc.destroy(engine);
        engine.* = .{
            .alloc = alloc,
            .config = config,
            .data_dir = data_dir,
            .wal = wal,
            .mem = MemTable.init(alloc),
            .metadata = metadata,
            .flush_timer_ms = config.flush_interval_ms,
            .metrics = Metrics.init(),
            .queue = undefined,
            .cas = cas_manager,
        };
        metadata_transferred = true;
        cas_manager_transferred = true;
        errdefer {
            engine.mem.deinit();
            engine.metadata.deinit();
            engine.wal.close();
            engine.data_dir.close();
            engine.config.deinit(engine.alloc);
        }
        engine.queue = try Queue.init(alloc, &engine.metrics);
        errdefer {
            engine.queue.deinit();
            engine.alloc.destroy(engine.queue);
        }
        if (engine.cas) |*cas| {
            _ = try cas.bootstrapIfMissing(engine.data_dir, &engine.metadata.manifest, &engine.metadata.tags, &engine.metadata.series_catalog);
            try engine.metadata.refreshCasIndex(cas);
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
        self.metadata.deinit();
        self.wal.close();
        self.data_dir.close();
        self.queue.deinit();
        self.alloc.destroy(self.queue);
        if (self.cas) |*cas| cas.deinit();
        self.config.deinit(self.alloc);
        self.alloc.destroy(self);
    }

    pub fn snapshotTo(self: *Engine, dst_path: []const u8) !void {
        try waitForQueueEmpty(self, 5_000);
        self.stop_flag = true;
        self.queue.close();
        if (self.writer_thread) |t| {
            t.join();
            self.writer_thread = null;
        }
        const flushed = try flushMemtable(self);
        if (flushed) try self.syncCasSnapshot("snapshot-flush");
        try self.wal.file.sync();
        if (!flushed or self.cas == null) try self.ensureSnapshotBundleHead();
        try @import("snapshot.zig").snapshot(self.alloc, self.config.data_dir, dst_path, self.config.fsync);
    }

    pub fn ingest(self: *Engine, item: IngestItem) !void {
        if (self.config.mem_limit_bytes != 0) {
            const queued_bytes = self.queue.len() * @sizeOf(IngestItem);
            const resident_bytes = self.mem.bytes.load(.monotonic) + queued_bytes;
            if (resident_bytes >= self.config.mem_limit_bytes) {
                _ = self.metrics.ingest_rejected_total.fetchAdd(1, .monotonic);
                _ = self.metrics.ingest_rejected_mem_limit_total.fetchAdd(1, .monotonic);
                return error.MemoryLimitExceeded;
            }
        }
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
        while (true) {
            if (self.queue.pop()) |it| {
                defer self.alloc.free(it.tags_json);
                const now_ns = std.time.nanoTimestamp();
                const wait_delta = now_ns - last_pop_ns;
                _ = self.metrics.queue_pop_total.fetchAdd(1, .monotonic);
                if (wait_delta > 0) {
                    _ = self.metrics.queue_wait_ns_total.fetchAdd(@as(u64, @intCast(wait_delta)), .monotonic);
                }
                last_pop_ns = now_ns;
                // WAL append
                const wal_start_ns = std.time.nanoTimestamp();
                const wal_bytes = self.wal.append(it.series_id, it.ts, it.value) catch |err| blk: {
                    _ = self.metrics.wal_append_failed_total.fetchAdd(1, .monotonic);
                    self.quarantineFailedIngest(it, "wal_append", @errorName(err));
                    std.log.warn("wal append failed: {s}", .{@errorName(err)});
                    break :blk 0;
                };
                const wal_elapsed_ns_i128 = std.time.nanoTimestamp() - wal_start_ns;
                const wal_elapsed_ns: u64 = @intCast(wal_elapsed_ns_i128);
                _ = self.metrics.wal_append_total.fetchAdd(1, .monotonic);
                _ = self.metrics.wal_append_ns_total.fetchAdd(wal_elapsed_ns, .monotonic);
                if (wal_bytes != 0) {
                    const wal_bytes_u64: u64 = @intCast(wal_bytes);
                    _ = self.metrics.wal_bytes_total.fetchAdd(wal_bytes_u64, .monotonic);
                }
                // Memtable insert
                if (self.appendMemtablePoint(it.series_id, it.ts, it.value)) |_| {
                    _ = self.metrics.ingest_total.fetchAdd(1, .monotonic);
                } else |err| {
                    _ = self.metrics.memtable_append_failed_total.fetchAdd(1, .monotonic);
                    self.quarantineFailedIngest(it, "memtable_append", @errorName(err));
                    std.log.warn("failed to append to memtable: {s}", .{@errorName(err)});
                    continue;
                }
            } else {
                if (self.stop_flag) break;
                sleepMs(10);
            }

            const now = std.time.milliTimestamp();
            const mem_usage = self.mem.bytes.load(.monotonic);
            if (mem_usage >= self.config.memtable_max_bytes or (now - last_flush) >= self.flush_timer_ms) {
                const flushed = flushMemtable(self) catch |err| blk: {
                    std.log.warn("memtable flush failed: {s}", .{@errorName(err)});
                    break :blk false;
                };
                last_flush = now;
                // apply retention best-effort after flush
                const retention_changed = retention.applyWithResult(self.data_dir, &self.metadata.manifest, self.config.retention_days) catch |err| blk: {
                    std.log.warn("retention apply failed: {s}", .{@errorName(err)});
                    break :blk false;
                };
                if (flushed or retention_changed) {
                    if (retention_changed) {
                        self.createMaintenanceCheckpoint("retention") catch |err| {
                            std.log.warn("retention checkpoint failed: {s}", .{@errorName(err)});
                        };
                    }
                    const reason = if (flushed and retention_changed)
                        "flush+retention"
                    else if (flushed)
                        "flush"
                    else
                        "retention";
                    self.syncCasSnapshot(reason) catch |err| {
                        std.log.warn("cas sync failed: {s}", .{@errorName(err)});
                    };
                }
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
        const flushed = flushMemtable(self) catch |err| blk: {
            std.log.warn("final memtable flush failed: {s}", .{@errorName(err)});
            break :blk false;
        };
        if (flushed) {
            self.syncCasSnapshot("shutdown-flush") catch |err| {
                std.log.warn("cas sync failed: {s}", .{@errorName(err)});
            };
        }
    }

    fn flushMemtable(self: *Engine) !bool {
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
                const selector_resolution = self.metadata.series_catalog.resolveBySeriesId(sid);
                const selector_metadata = switch (selector_resolution.status) {
                    .resolved, .exact_match => segment_mod.SelectorMetadataView{
                        .series = selector_resolution.series.?,
                        .canonical_tags = selector_resolution.canonical_tags.?,
                    },
                    .not_found, .ambiguous => null,
                };
                const seg_path = try segment_mod.writeSegmentWithMetadata(self.alloc, self.data_dir, sid, hour, slice, selector_metadata);
                const c: u32 = @intCast(slice.len);
                try self.metadata.manifest.add(self.data_dir, sid, hour, slice[0].ts, slice[slice.len - 1].ts, c, seg_path);
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
        self.metadata.tags.save(self.data_dir) catch |err| {
            std.log.warn("tag index save failed: {s}", .{@errorName(err)});
        };
        return segments_written > 0;
    }

    fn quarantineFailedIngest(self: *Engine, item: IngestItem, stage: []const u8, err_name: []const u8) void {
        var payload = std.array_list.Managed(u8).init(self.alloc);
        defer payload.deinit();

        var writer = payload.writer();
        var tmp: [256]u8 = undefined;
        var adapter = writer.adaptToNewApi(&tmp);
        var iface = &adapter.new_interface;
        var jw = std.json.Stringify{ .writer = iface };

        const resolution = self.metadata.series_catalog.resolveBySeriesId(item.series_id);
        const series = resolution.series;
        const canonical_tags = resolution.canonical_tags orelse item.tags_json;

        jw.beginObject() catch |err| {
            _ = self.metrics.ingest_quarantine_write_failed_total.fetchAdd(1, .monotonic);
            std.log.warn("failed to build ingest quarantine payload: {s}", .{@errorName(err)});
            return;
        };
        jw.objectField("series_id") catch |err| {
            _ = self.metrics.ingest_quarantine_write_failed_total.fetchAdd(1, .monotonic);
            std.log.warn("failed to build ingest quarantine payload: {s}", .{@errorName(err)});
            return;
        };
        jw.write(item.series_id) catch |err| {
            _ = self.metrics.ingest_quarantine_write_failed_total.fetchAdd(1, .monotonic);
            std.log.warn("failed to build ingest quarantine payload: {s}", .{@errorName(err)});
            return;
        };
        jw.objectField("series") catch |err| {
            _ = self.metrics.ingest_quarantine_write_failed_total.fetchAdd(1, .monotonic);
            std.log.warn("failed to build ingest quarantine payload: {s}", .{@errorName(err)});
            return;
        };
        if (series) |name| {
            jw.write(name) catch |err| {
                _ = self.metrics.ingest_quarantine_write_failed_total.fetchAdd(1, .monotonic);
                std.log.warn("failed to build ingest quarantine payload: {s}", .{@errorName(err)});
                return;
            };
        } else {
            jw.write(null) catch |err| {
                _ = self.metrics.ingest_quarantine_write_failed_total.fetchAdd(1, .monotonic);
                std.log.warn("failed to build ingest quarantine payload: {s}", .{@errorName(err)});
                return;
            };
        }
        jw.objectField("ts") catch |err| {
            _ = self.metrics.ingest_quarantine_write_failed_total.fetchAdd(1, .monotonic);
            std.log.warn("failed to build ingest quarantine payload: {s}", .{@errorName(err)});
            return;
        };
        jw.write(item.ts) catch |err| {
            _ = self.metrics.ingest_quarantine_write_failed_total.fetchAdd(1, .monotonic);
            std.log.warn("failed to build ingest quarantine payload: {s}", .{@errorName(err)});
            return;
        };
        jw.objectField("value") catch |err| {
            _ = self.metrics.ingest_quarantine_write_failed_total.fetchAdd(1, .monotonic);
            std.log.warn("failed to build ingest quarantine payload: {s}", .{@errorName(err)});
            return;
        };
        jw.write(item.value) catch |err| {
            _ = self.metrics.ingest_quarantine_write_failed_total.fetchAdd(1, .monotonic);
            std.log.warn("failed to build ingest quarantine payload: {s}", .{@errorName(err)});
            return;
        };
        jw.objectField("tags_json") catch |err| {
            _ = self.metrics.ingest_quarantine_write_failed_total.fetchAdd(1, .monotonic);
            std.log.warn("failed to build ingest quarantine payload: {s}", .{@errorName(err)});
            return;
        };
        jw.write(canonical_tags) catch |err| {
            _ = self.metrics.ingest_quarantine_write_failed_total.fetchAdd(1, .monotonic);
            std.log.warn("failed to build ingest quarantine payload: {s}", .{@errorName(err)});
            return;
        };
        jw.objectField("stage") catch |err| {
            _ = self.metrics.ingest_quarantine_write_failed_total.fetchAdd(1, .monotonic);
            std.log.warn("failed to build ingest quarantine payload: {s}", .{@errorName(err)});
            return;
        };
        jw.write(stage) catch |err| {
            _ = self.metrics.ingest_quarantine_write_failed_total.fetchAdd(1, .monotonic);
            std.log.warn("failed to build ingest quarantine payload: {s}", .{@errorName(err)});
            return;
        };
        jw.objectField("error") catch |err| {
            _ = self.metrics.ingest_quarantine_write_failed_total.fetchAdd(1, .monotonic);
            std.log.warn("failed to build ingest quarantine payload: {s}", .{@errorName(err)});
            return;
        };
        jw.write(err_name) catch |err| {
            _ = self.metrics.ingest_quarantine_write_failed_total.fetchAdd(1, .monotonic);
            std.log.warn("failed to build ingest quarantine payload: {s}", .{@errorName(err)});
            return;
        };
        jw.endObject() catch |err| {
            _ = self.metrics.ingest_quarantine_write_failed_total.fetchAdd(1, .monotonic);
            std.log.warn("failed to build ingest quarantine payload: {s}", .{@errorName(err)});
            return;
        };
        iface.flush() catch |err| {
            _ = self.metrics.ingest_quarantine_write_failed_total.fetchAdd(1, .monotonic);
            std.log.warn("failed to build ingest quarantine payload: {s}", .{@errorName(err)});
            return;
        };
        if (adapter.err) |err| {
            _ = self.metrics.ingest_quarantine_write_failed_total.fetchAdd(1, .monotonic);
            std.log.warn("failed to build ingest quarantine payload: {s}", .{@errorName(err)});
            return;
        }

        self.data_dir.makePath(failed_ingest_quarantine_dir) catch |err| {
            _ = self.metrics.ingest_quarantine_write_failed_total.fetchAdd(1, .monotonic);
            std.log.warn("failed to create ingest quarantine dir: {s}", .{@errorName(err)});
            return;
        };

        var file = self.data_dir.createFile(failed_ingest_quarantine_path, .{ .read = true, .truncate = false }) catch |err| {
            _ = self.metrics.ingest_quarantine_write_failed_total.fetchAdd(1, .monotonic);
            std.log.warn("failed to open ingest quarantine file: {s}", .{@errorName(err)});
            return;
        };
        defer file.close();

        file.seekFromEnd(0) catch |err| {
            _ = self.metrics.ingest_quarantine_write_failed_total.fetchAdd(1, .monotonic);
            std.log.warn("failed to seek ingest quarantine file: {s}", .{@errorName(err)});
            return;
        };
        file.writeAll(payload.items) catch |err| {
            _ = self.metrics.ingest_quarantine_write_failed_total.fetchAdd(1, .monotonic);
            std.log.warn("failed to write ingest quarantine payload: {s}", .{@errorName(err)});
            return;
        };
        file.writeAll("\n") catch |err| {
            _ = self.metrics.ingest_quarantine_write_failed_total.fetchAdd(1, .monotonic);
            std.log.warn("failed to write ingest quarantine payload: {s}", .{@errorName(err)});
            return;
        };

        _ = self.metrics.ingest_quarantined_total.fetchAdd(1, .monotonic);
    }

    fn hourBucket(ts: i64) i64 {
        const secs_per_hour: i64 = 3600;
        return (@divTrunc(ts, secs_per_hour)) * secs_per_hour;
    }

    pub fn queryRange(self: *Engine, series_id: types.SeriesId, start_ts: i64, end_ts: i64, out: *std.array_list.Managed(types.Point)) !void {
        const legacy_view = self.metadata.legacyView();
        switch (self.config.metadata_read_mode) {
            .legacy => try legacy_view.queryRange(self.alloc, self.data_dir, series_id, start_ts, end_ts, out),
            .shadow => {
                try legacy_view.queryRange(self.alloc, self.data_dir, series_id, start_ts, end_ts, out);
                var cas_points = std.array_list.Managed(types.Point).init(self.alloc);
                defer cas_points.deinit();
                if (try self.metadata.queryRangeFromCas(self.alloc, self.data_dir, series_id, start_ts, end_ts, &cas_points)) {
                    verifyPointsMatch(out.items, cas_points.items) catch {
                        self.recordCasShadowMismatch();
                        std.log.warn("cas shadow mismatch: queryRange series_id={d}", .{series_id});
                    };
                }
            },
            .primary => {
                if (!try self.metadata.queryRangeFromCas(self.alloc, self.data_dir, series_id, start_ts, end_ts, out)) {
                    try legacy_view.queryRange(self.alloc, self.data_dir, series_id, start_ts, end_ts, out);
                }
            },
        }
    }

    pub fn registerSeries(self: *Engine, series: []const u8, tags: []const u8, series_id: types.SeriesId) !void {
        try self.registerSeriesInternal(series, tags, series_id, true);
    }

    pub fn resolveSelector(self: *Engine, lookup: SelectorLookup) !series_catalog_mod.Resolution {
        const legacy_view = self.metadata.legacyView();
        switch (lookup) {
            .by_id => |series_id| {
                const legacy = legacy_view.resolveBySeriesId(series_id);
                return switch (self.config.metadata_read_mode) {
                    .legacy => legacy,
                    .shadow => blk: {
                        if (self.metadata.resolveBySeriesIdFromCas(series_id)) |cas_resolution| {
                            if (!resolutionsEqual(legacy, cas_resolution)) {
                                self.recordCasShadowMismatch();
                                std.log.warn("cas shadow mismatch: resolveBySeriesId series_id={d}", .{series_id});
                            }
                        }
                        break :blk legacy;
                    },
                    .primary => self.metadata.resolveBySeriesIdFromCas(series_id) orelse legacy,
                };
            },
            .name => |series| {
                const legacy = legacy_view.resolveUniqueSeriesNameDetailed(series);
                return switch (self.config.metadata_read_mode) {
                    .legacy => legacy,
                    .shadow => blk: {
                        if (self.metadata.resolveUniqueSeriesNameDetailedFromCas(series)) |cas_resolution| {
                            if (!resolutionsEqual(legacy, cas_resolution)) {
                                self.recordCasShadowMismatch();
                                std.log.warn("cas shadow mismatch: resolveUniqueSeriesName series='{s}'", .{series});
                            }
                        }
                        break :blk legacy;
                    },
                    .primary => self.metadata.resolveUniqueSeriesNameDetailedFromCas(series) orelse legacy,
                };
            },
            .exact => |exact| {
                const legacy = try legacy_view.resolveExactSeriesDetailed(exact.series, exact.tags_json);
                return switch (self.config.metadata_read_mode) {
                    .legacy => legacy,
                    .shadow => blk: {
                        if (try self.metadata.resolveExactSeriesDetailedFromCas(exact.series, exact.tags_json)) |cas_resolution| {
                            if (!resolutionsEqual(legacy, cas_resolution)) {
                                self.recordCasShadowMismatch();
                                std.log.warn("cas shadow mismatch: resolveExactSeries series='{s}'", .{exact.series});
                            }
                        }
                        break :blk legacy;
                    },
                    .primary => if (try self.metadata.resolveExactSeriesDetailedFromCas(exact.series, exact.tags_json)) |cas_resolution| cas_resolution else legacy,
                };
            },
        }
    }

    pub fn resolveUniqueSeriesName(self: *Engine, series: []const u8) series_catalog_mod.Match {
        return (self.resolveSelector(.{ .name = series }) catch return .not_found).toMatch();
    }

    pub fn resolveExactSeries(self: *Engine, series: []const u8, tags_json: []const u8) !series_catalog_mod.Match {
        return (try self.resolveSelector(.{ .exact = .{ .series = series, .tags_json = tags_json } })).toMatch();
    }

    pub fn currentCompatibilityDebt(self: *Engine) !cas_mod.CompatibilityDebtReport {
        var report = cas_mod.CompatibilityDebtReport{};
        self.metadata.cas_index_mu.lock();
        if (self.metadata.cas_index) |*index| {
            report = index.compatibilityDebt();
        }
        self.metadata.cas_index_mu.unlock();

        if (self.cas) |*cas| {
            if (cas.format.version >= cas_mod.current_repository_format_version and cas.format.ref_backend == .reftable) {
                report.loose_refs_present = try cas.refs.countLooseRefs(self.alloc);
            }
        }
        return report;
    }

    pub fn deleteWhere(self: *Engine, series_id: types.SeriesId, predicate: ?*const query_ast.Expr) !usize {
        try pauseWriterForMaintenance(self);
        defer resumeWriterAfterMaintenance(self) catch |err| {
            std.log.err("failed to resume writer after delete maintenance: {s}", .{@errorName(err)});
        };

        _ = try flushMemtable(self);

        var existing = std.array_list.Managed(types.Point).init(self.alloc);
        defer existing.deinit();
        try self.queryRange(series_id, std.math.minInt(i64), std.math.maxInt(i64), &existing);
        if (existing.items.len == 0) return 0;

        var survivors = std.array_list.Managed(types.Point).init(self.alloc);
        defer survivors.deinit();

        var deleted_count: usize = 0;
        for (existing.items) |point| {
            if (predicate) |expr| {
                if (try deletePredicateMatches(expr, point)) {
                    deleted_count += 1;
                } else {
                    try survivors.append(point);
                }
            } else {
                deleted_count += 1;
            }
        }

        if (deleted_count == 0) return 0;

        try rewriteSeriesPoints(self, series_id, survivors.items);
        try self.wal.reset();
        if (self.cas != null) {
            try self.syncCasSnapshot("delete");
        }
        return deleted_count;
    }

    pub fn collectMatchingSeriesIds(self: *Engine, alloc: std.mem.Allocator, tags_value: std.json.Value, op_and: bool) !std.array_list.Managed(types.SeriesId) {
        const legacy_view = self.metadata.legacyView();
        switch (self.config.metadata_read_mode) {
            .legacy => return try collectMatchingSeriesIdsFromView(alloc, legacy_view, tags_value, op_and),
            .shadow => {
                var legacy = try collectMatchingSeriesIdsFromView(alloc, legacy_view, tags_value, op_and);
                errdefer legacy.deinit();
                if (try self.metadata.collectMatchingSeriesIdsFromCas(alloc, tags_value, op_and)) |cas_ids| {
                    var cas_ids_mut = cas_ids;
                    defer cas_ids_mut.deinit();
                    verifySeriesIdsMatch(legacy.items, cas_ids_mut.items) catch {
                        self.recordCasShadowMismatch();
                        std.log.warn("cas shadow mismatch: collectMatchingSeriesIds", .{});
                    };
                }
                return legacy;
            },
            .primary => {
                if (try self.metadata.collectMatchingSeriesIdsFromCas(alloc, tags_value, op_and)) |cas_ids| return cas_ids;
                return try collectMatchingSeriesIdsFromView(alloc, legacy_view, tags_value, op_and);
            },
        }
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
                self.metadata.tags.add(key, series_id) catch |err| {
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

    pub fn verifyCasState(self: *Engine) !void {
        if (self.cas) |*cas| {
            return try cas.verifyHeadMatchesLegacy(self.data_dir, &self.metadata.manifest, &self.metadata.tags, &self.metadata.series_catalog);
        }
        return error.CasDisabled;
    }

    pub fn flushNow(self: *Engine) !bool {
        try pauseWriterForMaintenance(self);
        errdefer resumeWriterAfterMaintenance(self) catch |err| {
            std.log.err("failed to resume writer after flushNow: {s}", .{@errorName(err)});
        };

        const flushed = try flushMemtable(self);
        if (flushed) try self.syncCasSnapshot("manual-flush");
        try self.wal.file.sync();
        try resumeWriterAfterMaintenance(self);
        return flushed;
    }

    pub fn waitForDrained(self: *Engine, timeout_ms: u64) WaitError!void {
        const deadline: i64 = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
        while (std.time.milliTimestamp() < deadline) {
            if (self.queue.len() == 0 and self.mem.bytes.load(.monotonic) == 0) {
                if (self.cas != null) {
                    self.verifyCasState() catch {
                        sleepMs(10);
                        continue;
                    };
                }
                return;
            }
            sleepMs(10);
        }
        return WaitError.Timeout;
    }

    pub fn waitForQueryablePoints(
        self: *Engine,
        allocator: std.mem.Allocator,
        series_id: types.SeriesId,
        expected_count: usize,
        timeout_ms: u64,
    ) !void {
        const deadline_ns = std.time.nanoTimestamp() + @as(i128, @intCast(timeout_ms)) * std.time.ns_per_ms;
        while (std.time.nanoTimestamp() <= deadline_ns) {
            var points = std.array_list.Managed(types.Point).init(allocator);
            defer points.deinit();

            try self.queryRange(series_id, std.math.minInt(i64), std.math.maxInt(i64), &points);
            if (points.items.len >= expected_count) return;
            std.Thread.sleep(5 * std.time.ns_per_ms);
        }
        return WaitError.Timeout;
    }

    pub fn compactNow(self: *Engine) !bool {
        if (self.cas) |*cas| {
            try self.metadata.refreshCasIndexIfStale(cas);
        }
        const changed = if (self.cas != null and self.metadata.hasCasIndex())
            try compactCasBackedSegments(self)
        else
            try @import("storage/compact.zig").compactAllWithResult(self.alloc, self.data_dir, &self.metadata.manifest);
        if (changed) {
            try self.createMaintenanceCheckpoint("compaction");
            try self.syncCasSnapshot("compaction");
        }
        return changed;
    }

    fn syncCasSnapshot(self: *Engine, reason: []const u8) !void {
        if (self.cas) |*cas| {
            const start_ns = std.time.nanoTimestamp();
            errdefer _ = self.metrics.cas_sync_failed_total.fetchAdd(1, .monotonic);
            _ = try cas.syncLegacySnapshot(self.data_dir, &self.metadata.manifest, &self.metadata.tags, &self.metadata.series_catalog, reason);
            try self.metadata.refreshCasIndex(cas);
            const elapsed_ns_i128 = std.time.nanoTimestamp() - start_ns;
            const elapsed_ns: u64 = @intCast(elapsed_ns_i128);
            _ = self.metrics.cas_sync_total.fetchAdd(1, .monotonic);
            _ = self.metrics.cas_sync_ns_total.fetchAdd(elapsed_ns, .monotonic);
        }
    }

    fn ensureSnapshotBundleHead(self: *Engine) !void {
        if (self.cas) |*cas| {
            if (try cas.refs.readHead(cas_mod.main_ref) == null) {
                _ = try cas.bootstrapIfMissing(self.data_dir, &self.metadata.manifest, &self.metadata.tags, &self.metadata.series_catalog);
            } else {
                _ = try cas.syncLegacySnapshot(self.data_dir, &self.metadata.manifest, &self.metadata.tags, &self.metadata.series_catalog, "snapshot");
            }
            try self.metadata.refreshCasIndex(cas);
            return;
        }

        var temp = try cas_mod.CasManager.init(self.alloc, self.config.data_dir, self.config.fsync);
        defer temp.deinit();
        if (try temp.refs.readHead(cas_mod.main_ref) == null) {
            _ = try temp.bootstrapIfMissing(self.data_dir, &self.metadata.manifest, &self.metadata.tags, &self.metadata.series_catalog);
        } else {
            _ = try temp.syncLegacySnapshot(self.data_dir, &self.metadata.manifest, &self.metadata.tags, &self.metadata.series_catalog, "snapshot");
        }
    }

    fn createMaintenanceCheckpoint(self: *Engine, prefix: []const u8) !void {
        if (self.cas) |*cas| {
            const ref_name = try cas.createCheckpoint(prefix) orelse return;
            self.alloc.free(ref_name);
        }
    }

    fn recordCasShadowMismatch(self: *Engine) void {
        _ = self.metrics.cas_shadow_mismatch_total.fetchAdd(1, .monotonic);
    }

    fn recover(self: *Engine) !void {
        var highwater = std.AutoHashMap(types.SeriesId, i64).init(self.alloc);
        defer highwater.deinit();

        {
            self.metadata.cas_index_mu.lock();
            defer self.metadata.cas_index_mu.unlock();
            if (self.metadata.cas_index) |*index| {
                if (index.snapshot.checkpoint_state.highwaters.len != 0) {
                    try collectCheckpointHighwater(&highwater, index.snapshot.checkpoint_state.highwaters);
                } else {
                    try collectSegmentHighwater(&highwater, index.snapshot.segment_descriptors);
                }
            } else {
                try collectSegmentHighwater(&highwater, self.metadata.manifest.entries.items);
            }
        }

        var ctx = struct {
            engine: *Engine,
            highwater: *std.AutoHashMap(types.SeriesId, i64),
            pub fn onSeriesRegistration(self_ctx: *@This(), series_id: types.SeriesId, series: []const u8, canonical_tags: []const u8) !void {
                try self_ctx.engine.registerSeriesInternal(series, canonical_tags, series_id, false);
            }
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

        if (try self.replayRecoveryWalFromCas(&ctx)) {
            // CAS snapshot replay handled above, including any explicit live WAL tail.
        } else if (try self.recoveryWalFiles()) |files| {
            defer wal_mod.freeWalFiles(self.alloc, files);
            try self.wal.replayFiles(self.alloc, files, &ctx);
        } else {
            try self.wal.replay(self.alloc, &ctx);
        }
        if (self.mem.bytes.load(.monotonic) > 0) {
            const flushed = try flushMemtable(self);
            if (flushed) try self.syncCasSnapshot("recovery-flush");
        }
    }

    fn registerSeriesInternal(self: *Engine, series: []const u8, tags: []const u8, series_id: types.SeriesId, record_wal: bool) !void {
        const inserted = try self.metadata.series_catalog.register(series, tags, series_id);
        if (!inserted or !record_wal) return;

        const resolution = self.metadata.series_catalog.resolveBySeriesId(series_id);
        const series_name = resolution.series orelse series;
        const canonical_tags = resolution.canonical_tags orelse tags;
        _ = try self.wal.appendSeriesRegistration(series_id, series_name, canonical_tags);
    }

    fn collectSegmentHighwater(highwater: *std.AutoHashMap(types.SeriesId, i64), entries: anytype) !void {
        for (entries) |entry| {
            const gop = try highwater.getOrPut(entry.series_id);
            if (!gop.found_existing or entry.end_ts > gop.value_ptr.*) {
                gop.value_ptr.* = entry.end_ts;
            }
        }
    }

    fn collectCheckpointHighwater(highwater: *std.AutoHashMap(types.SeriesId, i64), entries: []const cas_mod.CheckpointSeriesHighwater) !void {
        for (entries) |entry| {
            const gop = try highwater.getOrPut(entry.series_id);
            if (!gop.found_existing or entry.highwater_ts > gop.value_ptr.*) {
                gop.value_ptr.* = entry.highwater_ts;
            }
        }
    }

    fn replayRecoveryWalFromCas(self: *Engine, ctx: anytype) !bool {
        self.metadata.cas_index_mu.lock();
        defer self.metadata.cas_index_mu.unlock();
        const index = if (self.metadata.cas_index) |*snapshot_index| snapshot_index else return false;
        const cas = if (self.cas) |*cas_manager| cas_manager else return false;

        if (index.snapshot.checkpoint_state.wal_entries.len != 0) {
            for (index.snapshot.checkpoint_state.wal_entries) |checkpoint_entry| {
                const entry = findWalEntry(index.snapshot.wal_index.entries, checkpoint_entry.name) orelse continue;
                try self.replayCapturedWalEntry(&cas.store, entry, checkpoint_entry.captured_bytes, ctx);
            }
        } else {
            for (index.snapshot.wal_index.entries) |entry| {
                try self.replayCapturedWalEntry(&cas.store, entry, entry.captured_bytes, ctx);
            }
        }

        const live = try wal_mod.listWalFiles(self.alloc, self.data_dir);
        defer wal_mod.freeWalFiles(self.alloc, live);
        for (live) |name| {
            if (findWalEntry(index.snapshot.wal_index.entries, name)) |entry| {
                if (!entry.mutable) continue;

                const path = try std.fmt.allocPrint(self.alloc, "wal/{s}", .{name});
                defer self.alloc.free(path);
                const stat = self.data_dir.statFile(path) catch |err| switch (err) {
                    error.FileNotFound => continue,
                    else => return err,
                };

                if (entry.journalRoot()) |journal_root| {
                    if (stat.size > entry.captured_bytes and try wal_mod.journalPrefixMatchesFile(self.alloc, self.data_dir, &cas.store, path, journal_root, entry.captured_bytes)) {
                        try self.wal.replayFileFromOffset(self.alloc, name, entry.captured_bytes, ctx);
                        continue;
                    }
                    if (stat.size == entry.captured_bytes and try wal_mod.journalPrefixMatchesFile(self.alloc, self.data_dir, &cas.store, path, journal_root, entry.captured_bytes)) {
                        continue;
                    }
                }

                if (entry.contentRef()) |content| {
                    switch (content) {
                        .blob => |content_id| {
                            if (stat.size > entry.captured_bytes and try wal_mod.ContentPrefixComparator.blobObjectMatchesFile(self.alloc, self.data_dir, &cas.store, path, content_id)) {
                                try self.wal.replayFileFromOffset(self.alloc, name, entry.captured_bytes, ctx);
                                continue;
                            }

                            if (stat.size == entry.captured_bytes and try wal_mod.ContentPrefixComparator.blobObjectMatchesFile(self.alloc, self.data_dir, &cas.store, path, content_id)) {
                                continue;
                            }
                        },
                        .extent_tree => |tree| {
                            if (stat.size > entry.captured_bytes and try wal_mod.ContentPrefixComparator.extentTreeMatchesFile(self.alloc, self.data_dir, &cas.store, path, tree)) {
                                try self.wal.replayFileFromOffset(self.alloc, name, entry.captured_bytes, ctx);
                                continue;
                            }
                            if (stat.size == entry.captured_bytes and try wal_mod.ContentPrefixComparator.extentTreeMatchesFile(self.alloc, self.data_dir, &cas.store, path, tree)) {
                                continue;
                            }
                        },
                    }
                }
            } else if (!std.mem.eql(u8, name, "current.wal") and containsWalName(index.snapshot.wal_index.entries, name)) {
                continue;
            }
            const single = [_][]const u8{name};
            try self.wal.replayFiles(self.alloc, single[0..], ctx);
        }
        return true;
    }

    fn replayCapturedWalEntry(self: *Engine, store: *object_store.ObjectStore, entry: cas_mod.WalChunkDescriptor, captured_bytes: u64, ctx: anytype) !void {
        if (entry.journalRoot()) |journal_root| {
            try wal_mod.replayJournalRoot(self.alloc, store, journal_root, captured_bytes, ctx);
            return;
        }

        if (entry.contentRef()) |content| {
            switch (content) {
                .blob => |content_id| try wal_mod.replayBlobObject(self.alloc, store, content_id, ctx),
                .extent_tree => |tree| try wal_mod.replayExtentTree(self.alloc, store, tree, ctx),
            }
            return;
        }

        if (entry.mirrorName().len != 0) {
            const single = [_][]const u8{entry.mirrorName()};
            try self.wal.replayFiles(self.alloc, single[0..], ctx);
        }
    }

    fn recoveryWalFiles(self: *Engine) !?[][]u8 {
        self.metadata.cas_index_mu.lock();
        defer self.metadata.cas_index_mu.unlock();
        const index = if (self.metadata.cas_index) |*snapshot_index| snapshot_index else return null;
        var files = std.array_list.Managed([]u8).init(self.alloc);
        errdefer {
            for (files.items) |name| self.alloc.free(name);
            files.deinit();
        }

        for (index.snapshot.wal_index.entries) |entry| {
            try files.append(try self.alloc.dupe(u8, entry.mirrorName()));
        }

        const live = try wal_mod.listWalFiles(self.alloc, self.data_dir);
        defer wal_mod.freeWalFiles(self.alloc, live);
        for (live) |name| {
            if (!containsString(files.items, name)) {
                try files.append(try self.alloc.dupe(u8, name));
            }
        }
        return try files.toOwnedSlice();
    }
};

fn containsWalName(entries: []const cas_mod.WalChunkDescriptor, needle: []const u8) bool {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.mirrorName(), needle)) return true;
    }
    return false;
}

fn findWalEntry(entries: []const cas_mod.WalChunkDescriptor, needle: []const u8) ?cas_mod.WalChunkDescriptor {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.mirrorName(), needle)) return entry;
    }
    return null;
}

const CompactibleDescriptorGroup = struct {
    series_id: types.SeriesId,
    hour_bucket: i64,
    indices: []usize,
};

fn compactCasBackedSegments(engine: *Engine) !bool {
    engine.metadata.cas_index_mu.lock();
    defer engine.metadata.cas_index_mu.unlock();
    const snapshot_index = engine.metadata.cas_index orelse return false;
    const store = &(engine.cas orelse return false).store;
    var changed_any = false;

    const groups = try collectCompactibleDescriptorGroups(engine.alloc, snapshot_index.snapshot.segment_descriptors);
    defer {
        for (groups) |group| engine.alloc.free(group.indices);
        engine.alloc.free(groups);
    }

    for (groups) |group| {
        try compactDescriptorGroup(engine, store, snapshot_index.snapshot.segment_descriptors, group);
        changed_any = true;
    }

    if (changed_any) {
        try engine.metadata.manifest.rewriteCheckpoint(engine.data_dir);
    }
    return changed_any;
}

fn collectCompactibleDescriptorGroups(
    alloc: std.mem.Allocator,
    descriptors: []const cas_mod.SegmentDescriptor,
) ![]CompactibleDescriptorGroup {
    var groups = std.array_list.Managed(CompactibleDescriptorGroup).init(alloc);
    errdefer {
        for (groups.items) |group| alloc.free(group.indices);
        groups.deinit();
    }

    descriptor_loop: for (descriptors, 0..) |descriptor, idx| {
        for (descriptors[0..idx]) |prior| {
            if (prior.series_id == descriptor.series_id and prior.hour_bucket == descriptor.hour_bucket) {
                continue :descriptor_loop;
            }
        }

        var indices = std.array_list.Managed(usize).init(alloc);
        errdefer indices.deinit();
        try indices.append(idx);

        var j = idx + 1;
        while (j < descriptors.len) : (j += 1) {
            const other = descriptors[j];
            if (other.series_id == descriptor.series_id and other.hour_bucket == descriptor.hour_bucket) {
                try indices.append(j);
            }
        }

        if (indices.items.len > 1) {
            try groups.append(.{
                .series_id = descriptor.series_id,
                .hour_bucket = descriptor.hour_bucket,
                .indices = try indices.toOwnedSlice(),
            });
            continue;
        }
        indices.deinit();
    }
    return try groups.toOwnedSlice();
}

fn compactDescriptorGroup(
    engine: *Engine,
    store: *object_store.ObjectStore,
    descriptors: []const cas_mod.SegmentDescriptor,
    group: CompactibleDescriptorGroup,
) !void {
    var all = std.array_list.Managed(types.Point).init(engine.alloc);
    defer all.deinit();

    for (group.indices) |descriptor_index| {
        const descriptor = descriptors[descriptor_index];
        try segment_mod.appendDescriptorPoints(engine.alloc, engine.data_dir, store, descriptor, &all);
    }

    std.sort.block(types.Point, all.items, {}, struct {
        fn lessThan(_: void, lhs: types.Point, rhs: types.Point) bool {
            return lhs.ts < rhs.ts;
        }
    }.lessThan);

    var dedup = try engine.alloc.alloc(types.Point, all.items.len);
    defer engine.alloc.free(dedup);

    var dedup_len: usize = 0;
    for (all.items) |point| {
        if (dedup_len == 0 or dedup[dedup_len - 1].ts != point.ts) {
            dedup[dedup_len] = point;
            dedup_len += 1;
        } else {
            dedup[dedup_len - 1] = point;
        }
    }

    const compacted = dedup[0..dedup_len];
    const selector_resolution = engine.metadata.series_catalog.resolveBySeriesId(group.series_id);
    const selector_metadata = switch (selector_resolution.status) {
        .resolved, .exact_match => segment_mod.SelectorMetadataView{
            .series = selector_resolution.series.?,
            .canonical_tags = selector_resolution.canonical_tags.?,
        },
        .not_found, .ambiguous => null,
    };
    const new_path = try segment_mod.writeSegmentWithMetadata(engine.alloc, engine.data_dir, group.series_id, group.hour_bucket, compacted, selector_metadata);
    defer engine.alloc.free(new_path);

    for (group.indices) |descriptor_index| {
        const descriptor = descriptors[descriptor_index];
        if (descriptor.mirrorPath().len != 0) {
            engine.data_dir.deleteFile(descriptor.mirrorPath()) catch {};
        }
    }

    var rebuilt = std.ArrayListUnmanaged(manifest_mod.Entry){};
    errdefer rebuilt.deinit(engine.alloc);

    var matched_descriptor_count: usize = 0;
    for (engine.metadata.manifest.entries.items) |entry| {
        if (findMatchingDescriptorIndex(descriptors, group.indices, entry) != null) {
            matched_descriptor_count += 1;
            engine.alloc.free(entry.path);
            continue;
        }
        try rebuilt.append(engine.alloc, entry);
    }

    if (matched_descriptor_count != group.indices.len) {
        return error.CasCompactionManifestMismatch;
    }

    try rebuilt.append(engine.alloc, .{
        .series_id = group.series_id,
        .hour_bucket = group.hour_bucket,
        .start_ts = compacted[0].ts,
        .end_ts = compacted[compacted.len - 1].ts,
        .count = @intCast(compacted.len),
        .path = try engine.alloc.dupe(u8, new_path),
    });

    engine.metadata.manifest.entries.deinit(engine.alloc);
    engine.metadata.manifest.entries = rebuilt;
}

fn findMatchingDescriptorIndex(
    descriptors: []const cas_mod.SegmentDescriptor,
    candidate_indices: []const usize,
    entry: manifest_mod.Entry,
) ?usize {
    for (candidate_indices) |descriptor_index| {
        const descriptor = descriptors[descriptor_index];
        if (descriptor.series_id != entry.series_id) continue;
        if (descriptor.hour_bucket != entry.hour_bucket) continue;
        if (descriptor.start_ts != entry.start_ts) continue;
        if (descriptor.end_ts != entry.end_ts) continue;
        if (descriptor.count != entry.count) continue;
        if (!std.mem.eql(u8, descriptor.mirrorPath(), entry.path)) continue;
        return descriptor_index;
    }
    return null;
}

fn manifestFromSnapshot(alloc: std.mem.Allocator, descriptors: []const cas_mod.SegmentDescriptor) !manifest_mod.Manifest {
    var manifest = manifest_mod.Manifest{ .alloc = alloc, .entries = .{} };
    errdefer manifest.deinit();

    for (descriptors) |descriptor| {
        const mirror_path = descriptor.mirrorPath();
        if (mirror_path.len == 0) continue;
        try manifest.entries.append(alloc, .{
            .series_id = descriptor.series_id,
            .hour_bucket = descriptor.hour_bucket,
            .start_ts = descriptor.start_ts,
            .end_ts = descriptor.end_ts,
            .count = descriptor.count,
            .path = try alloc.dupe(u8, mirror_path),
        });
    }
    return manifest;
}

fn tagIndexFromSnapshot(alloc: std.mem.Allocator, snapshot: cas_mod.TagSnapshot) !tags_mod.TagIndex {
    var tags = tags_mod.TagIndex{
        .alloc = alloc,
        .map = std.StringHashMap(std.ArrayListUnmanaged(types.SeriesId)).init(alloc),
    };
    errdefer tags.deinit();

    for (snapshot.entries) |entry| {
        for (entry.series_ids) |series_id| {
            try tags.add(entry.key, series_id);
        }
    }
    return tags;
}

fn seriesCatalogFromSnapshot(
    alloc: std.mem.Allocator,
    fsync: cfg.FsyncPolicy,
    snapshot: cas_mod.SeriesCatalogSnapshot,
) !series_catalog_mod.SeriesCatalog {
    var catalog = series_catalog_mod.SeriesCatalog.initEmpty(alloc, fsync);
    errdefer catalog.deinit();

    for (snapshot.entries) |entry| {
        _ = try catalog.register(entry.series, entry.canonical_tags, entry.series_id);
    }
    return catalog;
}

fn collectMatchingSeriesIdsFromView(
    alloc: std.mem.Allocator,
    view: Engine.MetadataView,
    tags_value: std.json.Value,
    op_and: bool,
) !std.array_list.Managed(types.SeriesId) {
    var result = std.AutoHashMap(types.SeriesId, void).init(alloc);
    defer result.deinit();

    if (tags_value != .object) {
        return std.array_list.Managed(types.SeriesId).init(alloc);
    }

    var saw_constraint = false;
    var it = tags_value.object.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .string) continue;
        const key = try std.fmt.allocPrint(alloc, "{s}={s}", .{ entry.key_ptr.*, entry.value_ptr.string });
        defer alloc.free(key);
        const matches = view.tagMatches(key);
        if (!saw_constraint) {
            for (matches) |sid| try result.put(sid, {});
            saw_constraint = true;
            continue;
        }
        if (op_and) {
            var result_it = result.iterator();
            while (result_it.next()) |match| {
                var found = false;
                for (matches) |sid| {
                    if (sid == match.key_ptr.*) {
                        found = true;
                        break;
                    }
                }
                if (!found) _ = result.remove(match.key_ptr.*);
            }
        } else {
            for (matches) |sid| try result.put(sid, {});
        }
    }

    var ids = std.array_list.Managed(types.SeriesId).init(alloc);
    errdefer ids.deinit();
    var key_it = result.keyIterator();
    while (key_it.next()) |sid| {
        try ids.append(sid.*);
    }
    std.sort.block(types.SeriesId, ids.items, {}, struct {
        fn lessThan(_: void, a: types.SeriesId, b: types.SeriesId) bool {
            return a < b;
        }
    }.lessThan);
    return ids;
}

fn collectMatchingSeriesIdsFromSnapshotIndex(
    alloc: std.mem.Allocator,
    index: *const cas_mod.SnapshotIndex,
    tags_value: std.json.Value,
    op_and: bool,
) !std.array_list.Managed(types.SeriesId) {
    var result = std.AutoHashMap(types.SeriesId, void).init(alloc);
    defer result.deinit();

    if (tags_value != .object) {
        return std.array_list.Managed(types.SeriesId).init(alloc);
    }

    var saw_constraint = false;
    var it = tags_value.object.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .string) continue;
        const key = try std.fmt.allocPrint(alloc, "{s}={s}", .{ entry.key_ptr.*, entry.value_ptr.string });
        defer alloc.free(key);
        const matches = index.tagMatches(key);
        if (!saw_constraint) {
            for (matches) |sid| try result.put(sid, {});
            saw_constraint = true;
            continue;
        }
        if (op_and) {
            var result_it = result.iterator();
            while (result_it.next()) |match| {
                var found = false;
                for (matches) |sid| {
                    if (sid == match.key_ptr.*) {
                        found = true;
                        break;
                    }
                }
                if (!found) _ = result.remove(match.key_ptr.*);
            }
        } else {
            for (matches) |sid| try result.put(sid, {});
        }
    }

    var ids = std.array_list.Managed(types.SeriesId).init(alloc);
    errdefer ids.deinit();
    var key_it = result.keyIterator();
    while (key_it.next()) |sid| {
        try ids.append(sid.*);
    }
    std.sort.block(types.SeriesId, ids.items, {}, struct {
        fn lessThan(_: void, a: types.SeriesId, b: types.SeriesId) bool {
            return a < b;
        }
    }.lessThan);
    return ids;
}

fn verifyPointsMatch(lhs: []const types.Point, rhs: []const types.Point) !void {
    if (lhs.len != rhs.len) return error.CasShadowMismatch;
    for (lhs, rhs) |left, right| {
        if (left.ts != right.ts or left.value != right.value) return error.CasShadowMismatch;
    }
}

fn verifySeriesIdsMatch(lhs: []const types.SeriesId, rhs: []const types.SeriesId) !void {
    if (!std.mem.eql(types.SeriesId, lhs, rhs)) return error.CasShadowMismatch;
}

fn resolutionsEqual(lhs: series_catalog_mod.Resolution, rhs: series_catalog_mod.Resolution) bool {
    if (lhs.status != rhs.status) return false;
    if (lhs.series_id != rhs.series_id) return false;
    if (!optionalStringsEqual(lhs.series, rhs.series)) return false;
    if (!optionalStringsEqual(lhs.canonical_tags, rhs.canonical_tags)) return false;
    return true;
}

fn optionalStringsEqual(lhs: ?[]const u8, rhs: ?[]const u8) bool {
    if (lhs == null and rhs == null) return true;
    if (lhs == null or rhs == null) return false;
    return std.mem.eql(u8, lhs.?, rhs.?);
}

fn containsString(items: []const []u8, needle: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

fn loadSeriesCatalogWithRepair(
    alloc: std.mem.Allocator,
    data_dir: std.fs.Dir,
    fsync: cfg.FsyncPolicy,
    manifest: *const manifest_mod.Manifest,
    wal: *wal_mod.WAL,
    cas_manager: ?*cas_mod.CasManager,
) !series_catalog_mod.SeriesCatalog {
    return series_catalog_mod.SeriesCatalog.loadOrInit(alloc, data_dir, fsync) catch |err| switch (err) {
        error.FileNotFound,
        error.InvalidSeriesCatalog,
        error.SeriesIdConflict,
        error.InvalidCharacter,
        error.InvalidNumber,
        error.SyntaxError,
        error.UnexpectedToken,
        error.UnexpectedEndOfInput,
        error.BufferUnderrun,
        error.ValueTooLong,
        error.LengthMismatch,
        error.UnknownField,
        error.MissingField,
        error.DuplicateField,
        => blk: {
            try rebuildSeriesCatalogOnDisk(alloc, data_dir, fsync, manifest, wal, cas_manager);
            break :blk try series_catalog_mod.SeriesCatalog.loadOrInit(alloc, data_dir, fsync);
        },
        else => return err,
    };
}

fn rebuildSeriesCatalogOnDisk(
    alloc: std.mem.Allocator,
    data_dir: std.fs.Dir,
    fsync: cfg.FsyncPolicy,
    manifest: *const manifest_mod.Manifest,
    wal: *wal_mod.WAL,
    cas_manager: ?*cas_mod.CasManager,
) !void {
    var entries = std.array_list.Managed(series_catalog_mod.RebuildEntry).init(alloc);
    defer {
        for (entries.items) |entry| {
            alloc.free(@constCast(entry.series));
            alloc.free(@constCast(entry.canonical_tags));
        }
        entries.deinit();
    }

    var series_ids = std.AutoHashMap(types.SeriesId, usize).init(alloc);
    defer series_ids.deinit();

    if (cas_manager) |cas| {
        var snapshot_index = cas.loadHeadIndex() catch |err| switch (err) {
            error.CasHeadMissing => null,
            else => return err,
        };
        if (snapshot_index) |*index| {
            defer index.deinit();
            for (index.snapshot.series_catalog_snapshot.entries) |entry| {
                try appendRebuildEntry(alloc, &entries, &series_ids, entry.series, entry.canonical_tags, entry.series_id);
            }
            try series_catalog_mod.SeriesCatalog.rebuild(alloc, data_dir, fsync, entries.items);
            return;
        }
    }

    for (manifest.entries.items) |entry| {
        var metadata = try segment_mod.inspectMetadata(alloc, data_dir, entry.path);
        defer metadata.deinit(alloc);
        if (metadata.selector) |selector| {
            try appendRebuildEntry(alloc, &entries, &series_ids, selector.series, selector.canonical_tags, entry.series_id);
        }
    }

    var ctx = struct {
        alloc: std.mem.Allocator,
        entries: *std.array_list.Managed(series_catalog_mod.RebuildEntry),
        series_ids: *std.AutoHashMap(types.SeriesId, usize),

        pub fn onSeriesRegistration(self: *@This(), series_id: types.SeriesId, series: []const u8, canonical_tags: []const u8) !void {
            try appendRebuildEntry(self.alloc, self.entries, self.series_ids, series, canonical_tags, series_id);
        }

        pub fn onRecord(_: *@This(), _: types.SeriesId, _: i64, _: f64) !void {}
    }{
        .alloc = alloc,
        .entries = &entries,
        .series_ids = &series_ids,
    };
    try wal.replay(alloc, &ctx);

    try series_catalog_mod.SeriesCatalog.rebuild(alloc, data_dir, fsync, entries.items);
}

fn appendRebuildEntry(
    alloc: std.mem.Allocator,
    entries: *std.array_list.Managed(series_catalog_mod.RebuildEntry),
    series_ids: *std.AutoHashMap(types.SeriesId, usize),
    series: []const u8,
    canonical_tags: []const u8,
    series_id: types.SeriesId,
) !void {
    if (series_ids.get(series_id)) |idx| {
        const existing = entries.items[idx];
        if (std.mem.eql(u8, existing.series, series) and std.mem.eql(u8, existing.canonical_tags, canonical_tags)) {
            return;
        }
        return error.SeriesIdConflict;
    }

    try entries.append(.{
        .series = try alloc.dupe(u8, series),
        .canonical_tags = try alloc.dupe(u8, canonical_tags),
        .series_id = series_id,
    });
    try series_ids.put(series_id, entries.items.len - 1);
}

const waitError = error{Timeout};
pub const WaitError = waitError;

fn waitForFlush(engine: *Engine, expected_entries: usize, timeout_ms: u64) waitError!void {
    const deadline: i64 = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
    while (std.time.milliTimestamp() < deadline) {
        if (engine.metadata.manifest.entries.items.len >= expected_entries and engine.mem.bytes.load(.monotonic) == 0 and engine.queue.len() == 0) {
            if (engine.cas != null) {
                engine.verifyCasState() catch {
                    sleepMs(10);
                    continue;
                };
            }
            return;
        }
        sleepMs(10);
    }
    return waitError.Timeout;
}

fn waitForQueueEmpty(engine: *Engine, timeout_ms: u64) waitError!void {
    const deadline: i64 = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
    while (std.time.milliTimestamp() < deadline) {
        if (engine.queue.len() == 0) return;
        sleepMs(10);
    }
    return waitError.Timeout;
}

fn pauseWriterForMaintenance(self: *Engine) !void {
    try waitForQueueEmpty(self, 5_000);
    self.stop_flag = true;
    self.queue.close();
    if (self.writer_thread) |thread| {
        thread.join();
        self.writer_thread = null;
    }
}

fn resumeWriterAfterMaintenance(self: *Engine) !void {
    self.stop_flag = false;
    self.queue.reopen();
    if (self.writer_thread == null) {
        self.writer_thread = try std.Thread.spawn(.{}, Engine.writerLoop, .{self});
    }
}

fn deletePredicateMatches(expr: *const query_ast.Expr, point: types.Point) !bool {
    const time_expr = query_ast.Expr{
        .identifier = .{ .value = "time", .quoted = false, .span = .{ .start = 0, .end = 0 } },
    };
    const value_expr = query_ast.Expr{
        .identifier = .{ .value = "value", .quoted = false, .span = .{ .start = 0, .end = 0 } },
    };
    const schema = [_]query_plan.ColumnInfo{
        .{ .name = "time", .expr = &time_expr },
        .{ .name = "value", .expr = &value_expr },
    };
    const values = [_]query_expression.Value{
        .{ .integer = point.ts },
        .{ .float = point.value },
    };
    const ctx = query_expression.RowContext{
        .schema = &schema,
        .values = &values,
    };
    return try query_expression.evaluateRowBoolean(expr, &ctx);
}

fn rewriteSeriesPoints(self: *Engine, series_id: types.SeriesId, points: []types.Point) !void {
    std.sort.block(types.Point, points, {}, struct {
        fn lessThan(_: void, lhs: types.Point, rhs: types.Point) bool {
            return lhs.ts < rhs.ts;
        }
    }.lessThan);

    const selector_resolution = self.metadata.series_catalog.resolveBySeriesId(series_id);
    const selector_metadata = switch (selector_resolution.status) {
        .resolved, .exact_match => segment_mod.SelectorMetadataView{
            .series = selector_resolution.series.?,
            .canonical_tags = selector_resolution.canonical_tags.?,
        },
        .not_found, .ambiguous => null,
    };

    var rebuilt = std.ArrayListUnmanaged(manifest_mod.Entry){};
    errdefer {
        for (rebuilt.items) |entry| self.alloc.free(entry.path);
        rebuilt.deinit(self.alloc);
    }

    for (self.metadata.manifest.entries.items) |entry| {
        if (entry.series_id == series_id) {
            self.data_dir.deleteFile(entry.path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
        } else {
            try rebuilt.append(self.alloc, .{
                .series_id = entry.series_id,
                .hour_bucket = entry.hour_bucket,
                .start_ts = entry.start_ts,
                .end_ts = entry.end_ts,
                .count = entry.count,
                .path = try self.alloc.dupe(u8, entry.path),
            });
        }
    }

    for (self.metadata.manifest.entries.items) |entry| {
        self.alloc.free(entry.path);
    }
    self.metadata.manifest.entries.deinit(self.alloc);

    var start_idx: usize = 0;
    while (start_idx < points.len) {
        const hour = Engine.hourBucket(points[start_idx].ts);
        var end_idx = start_idx + 1;
        while (end_idx < points.len and Engine.hourBucket(points[end_idx].ts) == hour) : (end_idx += 1) {}
        const slice = points[start_idx..end_idx];
        const seg_path = try segment_mod.writeSegmentWithMetadata(
            self.alloc,
            self.data_dir,
            series_id,
            hour,
            slice,
            selector_metadata,
        );
        defer self.alloc.free(seg_path);
        try rebuilt.append(self.alloc, .{
            .series_id = series_id,
            .hour_bucket = hour,
            .start_ts = slice[0].ts,
            .end_ts = slice[slice.len - 1].ts,
            .count = @intCast(slice.len),
            .path = try self.alloc.dupe(u8, seg_path),
        });
        start_idx = end_idx;
    }

    self.metadata.manifest.entries = rebuilt;
    try self.metadata.manifest.rewriteCheckpoint(self.data_dir);
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
        .cas_mode = .off,
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

    const matches = engine.metadata.tags.get("host=a");
    try std.testing.expectEqual(@as(usize, 1), matches.len);
    try std.testing.expectEqual(sid, matches[0]);
}

test "engine deleteWhere rewrites series data and resets wal" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/delete-where", .{tmp.sub_path});
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
        .cas_mode = .off,
        .retention_ns = std.StringHashMap(u32).init(talloc),
    };

    var engine = try Engine.init(talloc, config);
    defer engine.deinit();

    const sid = types.hash64("delete.range");
    try engine.registerSeries("delete.range", "{}", sid);
    try engine.ingest(.{ .series_id = sid, .ts = 10, .value = 1.0, .tags_json = "{}" });
    try engine.ingest(.{ .series_id = sid, .ts = 20, .value = 2.0, .tags_json = "{}" });
    try engine.ingest(.{ .series_id = sid, .ts = 30, .value = 3.0, .tags_json = "{}" });
    try waitForFlush(engine, 1, 1_000);

    const time_expr = query_ast.Expr{
        .identifier = .{ .value = "time", .quoted = false, .span = .{ .start = 0, .end = 0 } },
    };
    const cutoff_expr = query_ast.Expr{
        .literal = .{ .value = .{ .integer = 20 }, .span = .{ .start = 0, .end = 0 } },
    };
    const predicate = query_ast.Expr{
        .binary = .{
            .op = .greater_equal,
            .left = &time_expr,
            .right = &cutoff_expr,
            .span = .{ .start = 0, .end = 0 },
        },
    };

    try std.testing.expectEqual(@as(usize, 2), try engine.deleteWhere(sid, &predicate));

    var results = std.array_list.Managed(types.Point).init(talloc);
    defer results.deinit();
    try engine.queryRange(sid, 0, 10_000, &results);
    try std.testing.expectEqual(@as(usize, 1), results.items.len);
    try std.testing.expectEqual(@as(i64, 10), results.items[0].ts);

    const wal_files = try wal_mod.listWalFiles(talloc, engine.data_dir);
    defer wal_mod.freeWalFiles(talloc, wal_files);
    try std.testing.expectEqual(@as(usize, 1), wal_files.len);
    try std.testing.expectEqualStrings("current.wal", wal_files[0]);
    const wal_stat = try engine.data_dir.statFile("wal/current.wal");
    try std.testing.expectEqual(@as(u64, 0), wal_stat.size);

    try engine.ingest(.{ .series_id = sid, .ts = 40, .value = 4.0, .tags_json = "{}" });
    try waitForFlush(engine, 2, 1_000);

    var resumed = std.array_list.Managed(types.Point).init(talloc);
    defer resumed.deinit();
    try engine.queryRange(sid, 0, 10_000, &resumed);
    try std.testing.expectEqual(@as(usize, 2), resumed.items.len);
    try std.testing.expectEqual(@as(i64, 40), resumed.items[1].ts);
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
        .cas_mode = .dual_write,
        .metadata_read_mode = .primary,
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
    try engine.verifyCasState();
}

test "engine replays WAL registrations and points consistently across metadata modes" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/wal-mode-recovery", .{tmp.sub_path});
    defer talloc.free(data_path);

    const raw_tags = "{\"rack\":\"r1\",\"host\":\"a\"}";
    const canonical_tags = "{\"host\":\"a\",\"rack\":\"r1\"}";
    const sid = types.seriesIdFrom("wal.mode.series", raw_tags);

    try std.fs.cwd().makePath(data_path);
    var data_dir = try std.fs.cwd().openDir(data_path, .{ .iterate = true });
    defer data_dir.close();

    var wal = try wal_mod.WAL.open(talloc, data_dir, .none);
    _ = try wal.appendSeriesRegistration(sid, "wal.mode.series", canonical_tags);
    _ = try wal.append(sid, 1_000, 42.0);
    _ = try wal.append(sid, 1_050, 43.5);
    wal.close();

    const modes = [_]cfg.MetadataReadMode{ .legacy, .shadow, .primary };
    for (modes) |mode| {
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
            .cas_mode = .dual_write,
            .metadata_read_mode = mode,
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
        try std.testing.expectApproxEqAbs(@as(f64, 43.5), results.items[1].value, 1e-9);

        try std.testing.expectEqual(sid, switch (engine.resolveUniqueSeriesName("wal.mode.series")) {
            .resolved => |resolved| resolved,
            else => return error.TestUnexpectedResult,
        });
        try std.testing.expectEqual(sid, switch (try engine.resolveExactSeries("wal.mode.series", raw_tags)) {
            .resolved => |resolved| resolved,
            else => return error.TestUnexpectedResult,
        });

        const by_id = try engine.resolveSelector(.{ .by_id = sid });
        try std.testing.expectEqual(series_catalog_mod.ResolutionStatus.resolved, by_id.status);
        try std.testing.expectEqualStrings("wal.mode.series", by_id.series.?);
        try std.testing.expectEqualStrings(canonical_tags, by_id.canonical_tags.?);
        try std.testing.expectEqual(@as(u64, 0), engine.metrics.cas_shadow_mismatch_total.load(.monotonic));
        try engine.verifyCasState();
    }
}

test "engine replays only the uncaptured current wal tail after CAS snapshot recovery" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/wal-tail-recovery", .{tmp.sub_path});
    defer talloc.free(data_path);

    const sid = types.hash64("wal.tail.series");

    try std.fs.cwd().makePath(data_path);
    var data_dir = try std.fs.cwd().openDir(data_path, .{ .iterate = true });
    defer data_dir.close();

    var wal = try wal_mod.WAL.open(talloc, data_dir, .none);
    defer wal.close();
    _ = try wal.append(sid, 1_000, 10.0);

    var manifest = manifest_mod.Manifest{ .alloc = talloc, .entries = .{} };
    defer manifest.deinit();
    var tags = tags_mod.TagIndex{ .alloc = talloc, .map = std.StringHashMap(std.ArrayListUnmanaged(types.SeriesId)).init(talloc) };
    defer tags.deinit();
    var series_catalog = try series_catalog_mod.SeriesCatalog.loadOrInit(talloc, data_dir, .none);
    defer series_catalog.deinit();

    var cas_manager = try cas_mod.CasManager.init(talloc, data_path, .none);
    defer cas_manager.deinit();
    _ = try cas_manager.bootstrapIfMissing(data_dir, &manifest, &tags, &series_catalog);

    _ = try wal.append(sid, 2_000, 20.0);

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
        .cas_mode = .dual_write,
        .metadata_read_mode = .primary,
        .retention_ns = std.StringHashMap(u32).init(talloc),
    };

    var engine = try Engine.init(talloc, config);
    defer engine.deinit();

    var results = std.array_list.Managed(types.Point).init(talloc);
    defer results.deinit();
    try engine.queryRange(sid, 0, 10_000, &results);
    try std.testing.expectEqual(@as(usize, 2), results.items.len);
    try std.testing.expectEqual(@as(i64, 1_000), results.items[0].ts);
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), results.items[0].value, 1e-9);
    try std.testing.expectEqual(@as(i64, 2_000), results.items[1].ts);
    try std.testing.expectApproxEqAbs(@as(f64, 20.0), results.items[1].value, 1e-9);
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
        .cas_mode = .off,
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
    const wal_append_total = engine.metrics.wal_append_total.load(.monotonic);
    try std.testing.expectEqual(@as(u64, 3), wal_append_total);
    const wal_bytes = engine.metrics.wal_bytes_total.load(.monotonic);
    try std.testing.expect(wal_bytes > 0);
    const wal_append_ns = engine.metrics.wal_append_ns_total.load(.monotonic);
    try std.testing.expect(wal_append_ns > 0);
    const flush_ns = engine.metrics.flush_ns_total.load(.monotonic);
    try std.testing.expect(flush_ns > 0);
}

test "engine records CAS sync metrics after dual-write flush" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/cas-sync-metrics", .{tmp.sub_path});
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
        .cas_mode = .dual_write,
        .metadata_read_mode = .primary,
        .retention_ns = std.StringHashMap(u32).init(talloc),
    };

    var engine = try Engine.init(talloc, config);
    defer engine.deinit();

    const sid = types.hash64("cas.sync.metrics");
    try engine.registerSeries("cas.sync.metrics", "{}", sid);
    try engine.ingest(.{ .series_id = sid, .ts = 10, .value = 1.0, .tags_json = "{}" });
    try waitForFlush(engine, 1, 1_000);

    try std.testing.expect(engine.metrics.cas_sync_total.load(.monotonic) > 0);
    try std.testing.expectEqual(@as(u64, 0), engine.metrics.cas_sync_failed_total.load(.monotonic));
    try std.testing.expect(engine.metrics.cas_sync_ns_total.load(.monotonic) > 0);
}

test "engine quarantines failed ingest payloads with selector metadata" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/quarantine-data", .{tmp.sub_path});
    defer talloc.free(data_path);
    const input_tags = "{\"rack\":\"r1\",\"host\":\"a\"}";
    const sid = types.seriesIdFrom("quarantine.series", input_tags);

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
        .cas_mode = .off,
        .retention_ns = std.StringHashMap(u32).init(talloc),
    };

    var engine = try Engine.init(talloc, config);
    defer engine.deinit();

    try engine.registerSeries("quarantine.series", input_tags, sid);
    engine.quarantineFailedIngest(.{
        .series_id = sid,
        .ts = 123,
        .value = 4.5,
        .tags_json = input_tags,
    }, "wal_append", "SyntheticFailure");

    try std.testing.expectEqual(@as(u64, 1), engine.metrics.ingest_quarantined_total.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 0), engine.metrics.ingest_quarantine_write_failed_total.load(.monotonic));

    var data_dir = try std.fs.cwd().openDir(data_path, .{ .iterate = true });
    defer data_dir.close();

    var quarantine_file = try data_dir.openFile(failed_ingest_quarantine_path, .{});
    defer quarantine_file.close();
    const contents = try quarantine_file.readToEndAlloc(talloc, 4096);
    defer talloc.free(contents);

    var parsed = try std.json.parseFromSlice(std.json.Value, talloc, std.mem.trim(u8, contents, "\r\n"), .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    try std.testing.expectEqual(@as(i64, @intCast(sid)), obj.get("series_id").?.integer);
    try std.testing.expectEqualStrings("quarantine.series", obj.get("series").?.string);
    try std.testing.expectEqual(@as(i64, 123), obj.get("ts").?.integer);
    try std.testing.expectApproxEqAbs(@as(f64, 4.5), obj.get("value").?.float, 1e-9);
    try std.testing.expectEqualStrings("{\"host\":\"a\",\"rack\":\"r1\"}", obj.get("tags_json").?.string);
    try std.testing.expectEqualStrings("wal_append", obj.get("stage").?.string);
    try std.testing.expectEqualStrings("SyntheticFailure", obj.get("error").?.string);
}

test "engine writer loop drains queued ingests during shutdown" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/shutdown-drain", .{tmp.sub_path});
    defer talloc.free(data_path);

    const config = cfg.Config{
        .data_dir = try talloc.dupe(u8, data_path),
        .http_port = 0,
        .fsync = .none,
        .flush_interval_ms = 60_000,
        .memtable_max_bytes = 1024 * 1024,
        .retention_days = 0,
        .auth_token = try talloc.dupe(u8, ""),
        .enable_influx = false,
        .enable_prom = false,
        .mem_limit_bytes = 1024 * 1024,
        .cas_mode = .off,
        .retention_ns = std.StringHashMap(u32).init(talloc),
    };

    var engine = try Engine.init(talloc, config);
    defer engine.deinit();

    const sid = types.hash64("shutdown.drain.series");
    try pauseWriterForMaintenance(engine);
    engine.queue.reopen();
    try engine.ingest(.{ .series_id = sid, .ts = 10, .value = 1.0, .tags_json = "{}" });
    try engine.ingest(.{ .series_id = sid, .ts = 20, .value = 2.0, .tags_json = "{}" });
    engine.stop_flag = true;
    engine.queue.close();

    engine.writerLoop();

    var results = std.array_list.Managed(types.Point).init(talloc);
    defer results.deinit();
    try engine.queryRange(sid, 0, 10_000, &results);
    try std.testing.expectEqual(@as(usize, 2), results.items.len);
    try std.testing.expectEqual(@as(i64, 10), results.items[0].ts);
    try std.testing.expectEqual(@as(i64, 20), results.items[1].ts);
}

test "engine snapshotTo captures a restorable CAS bundle" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/data", .{tmp.sub_path});
    defer talloc.free(data_path);
    const snapshot_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/snapshot", .{tmp.sub_path});
    defer talloc.free(snapshot_path);
    const restore_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/restore", .{tmp.sub_path});
    defer talloc.free(restore_path);

    const sid = types.hash64("snapshot.series");

    {
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
            .cas_mode = .dual_write,
            .retention_ns = std.StringHashMap(u32).init(talloc),
        };

        var engine = try Engine.init(talloc, config);
        defer engine.deinit();

        try engine.registerSeries("snapshot.series", "{}", sid);
        try engine.ingest(.{ .series_id = sid, .ts = 1_000, .value = 10.0, .tags_json = "{}" });
        try engine.ingest(.{ .series_id = sid, .ts = 1_005, .value = 11.0, .tags_json = "{}" });
        engine.noteTags(sid, "{\"host\":\"snapshot\"}");

        try engine.snapshotTo(snapshot_path);
    }

    {
        try std.fs.cwd().makePath(restore_path);
        try @import("snapshot.zig").restore(talloc, restore_path, snapshot_path, .none);

        var restore_dir = try std.fs.cwd().openDir(restore_path, .{ .iterate = true });
        defer restore_dir.close();
        try std.testing.expectError(error.FileNotFound, restore_dir.statFile("MANIFEST"));
        try std.testing.expectError(error.FileNotFound, restore_dir.statFile("tags.json"));
        try std.testing.expectError(error.FileNotFound, restore_dir.statFile("series_catalog.jsonl"));

        const restored_cfg = cfg.Config{
            .data_dir = try talloc.dupe(u8, restore_path),
            .http_port = 0,
            .fsync = .none,
            .flush_interval_ms = 5,
            .memtable_max_bytes = 512,
            .retention_days = 0,
            .auth_token = try talloc.dupe(u8, ""),
            .enable_influx = false,
            .enable_prom = false,
            .mem_limit_bytes = 1024 * 1024,
            .cas_mode = .dual_write,
            .metadata_read_mode = .primary,
            .retention_ns = std.StringHashMap(u32).init(talloc),
        };

        var restored = try Engine.init(talloc, restored_cfg);
        defer restored.deinit();

        var results = std.array_list.Managed(types.Point).init(talloc);
        defer results.deinit();
        try restored.queryRange(sid, 0, 10_000, &results);
        try std.testing.expectEqual(@as(usize, 2), results.items.len);
        try std.testing.expectEqual(@as(i64, 1_000), results.items[0].ts);
        try std.testing.expectApproxEqAbs(@as(f64, 10.0), results.items[0].value, 1e-9);
        try std.testing.expectEqual(@as(i64, 1_005), results.items[1].ts);

        const matches = restored.metadata.tags.get("host=snapshot");
        try std.testing.expectEqual(@as(usize, 1), matches.len);
        try std.testing.expectEqual(sid, matches[0]);
        switch (restored.resolveUniqueSeriesName("snapshot.series")) {
            .resolved => |resolved| try std.testing.expectEqual(sid, resolved),
            else => return error.TestUnexpectedResult,
        }
    }
}

test "engine primary metadata mode boots from CAS metadata alone" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/primary-data", .{tmp.sub_path});
    defer talloc.free(data_path);
    const sid = types.hash64("primary.series");

    {
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
            .cas_mode = .dual_write,
            .retention_ns = std.StringHashMap(u32).init(talloc),
        };

        var engine = try Engine.init(talloc, config);
        defer engine.deinit();

        try engine.registerSeries("primary.series", "{}", sid);
        try engine.ingest(.{ .series_id = sid, .ts = 1_000, .value = 5.0, .tags_json = "{}" });
        engine.noteTags(sid, "{\"host\":\"primary\"}");
        try waitForFlush(engine, 1, 1_000);
        try engine.verifyCasState();
    }

    {
        var data_dir = try std.fs.cwd().openDir(data_path, .{ .iterate = true });
        defer data_dir.close();
        data_dir.deleteFile("MANIFEST") catch {};
        data_dir.deleteFile("tags.json") catch {};
        data_dir.deleteFile("series_catalog.jsonl") catch {};
    }

    {
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
            .cas_mode = .dual_write,
            .metadata_read_mode = .primary,
            .retention_ns = std.StringHashMap(u32).init(talloc),
        };

        var engine = try Engine.init(talloc, config);
        defer engine.deinit();

        var boot_dir = try std.fs.cwd().openDir(data_path, .{ .iterate = true });
        defer boot_dir.close();
        try std.testing.expectError(error.FileNotFound, boot_dir.statFile("MANIFEST"));
        try std.testing.expectError(error.FileNotFound, boot_dir.statFile("tags.json"));
        try std.testing.expectError(error.FileNotFound, boot_dir.statFile("series_catalog.jsonl"));

        var results = std.array_list.Managed(types.Point).init(talloc);
        defer results.deinit();
        try engine.queryRange(sid, 0, 10_000, &results);
        try std.testing.expectEqual(@as(usize, 1), results.items.len);
        try std.testing.expectApproxEqAbs(@as(f64, 5.0), results.items[0].value, 1e-9);

        var parsed = try std.json.parseFromSlice(std.json.Value, talloc, "{\"host\":\"primary\"}", .{});
        defer parsed.deinit();
        const matches = try engine.collectMatchingSeriesIds(talloc, parsed.value, true);
        defer matches.deinit();
        try std.testing.expectEqual(@as(usize, 1), matches.items.len);
        try std.testing.expectEqual(sid, matches.items[0]);
        switch (engine.resolveUniqueSeriesName("primary.series")) {
            .resolved => |resolved| try std.testing.expectEqual(sid, resolved),
            else => return error.TestUnexpectedResult,
        }

        try std.testing.expectError(error.FileNotFound, boot_dir.statFile("MANIFEST"));
        try std.testing.expectError(error.FileNotFound, boot_dir.statFile("tags.json"));
        try std.testing.expectError(error.FileNotFound, boot_dir.statFile("series_catalog.jsonl"));
    }
}

test "engine primary mode can query from CAS-owned segment content without mirrors" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/cas-segment-data", .{tmp.sub_path});
    defer talloc.free(data_path);
    const sid = types.hash64("cas.segment.series");

    {
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
            .cas_mode = .dual_write,
            .retention_ns = std.StringHashMap(u32).init(talloc),
        };

        var engine = try Engine.init(talloc, config);
        defer engine.deinit();

        try engine.registerSeries("cas.segment.series", "{}", sid);
        try engine.ingest(.{ .series_id = sid, .ts = 2_000, .value = 9.5, .tags_json = "{}" });
        try waitForFlush(engine, 1, 1_000);
        try engine.verifyCasState();
    }

    {
        var data_dir = try std.fs.cwd().openDir(data_path, .{ .iterate = true });
        defer data_dir.close();
        data_dir.deleteTree("segments") catch {};
        data_dir.deleteFile("MANIFEST") catch {};
        data_dir.deleteFile("tags.json") catch {};
        data_dir.deleteFile("series_catalog.jsonl") catch {};
    }

    {
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
            .cas_mode = .dual_write,
            .metadata_read_mode = .primary,
            .retention_ns = std.StringHashMap(u32).init(talloc),
        };

        var engine = try Engine.init(talloc, config);
        defer engine.deinit();

        var results = std.array_list.Managed(types.Point).init(talloc);
        defer results.deinit();
        try engine.queryRange(sid, 0, 10_000, &results);
        try std.testing.expectEqual(@as(usize, 1), results.items.len);
        try std.testing.expectEqual(@as(i64, 2_000), results.items[0].ts);
        try std.testing.expectApproxEqAbs(@as(f64, 9.5), results.items[0].value, 1e-9);
    }
}

test "engine primary mode compacts from CAS-backed segment descriptors without source mirrors" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/cas-compact-data", .{tmp.sub_path});
    defer talloc.free(data_path);
    const sid = types.hash64("cas.compact.series");

    {
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
            .cas_mode = .dual_write,
            .retention_ns = std.StringHashMap(u32).init(talloc),
        };

        var engine = try Engine.init(talloc, config);
        defer engine.deinit();

        try engine.registerSeries("cas.compact.series", "{}", sid);
        try engine.ingest(.{ .series_id = sid, .ts = 1_000, .value = 1.0, .tags_json = "{}" });
        try waitForFlush(engine, 1, 1_000);
        try engine.ingest(.{ .series_id = sid, .ts = 1_500, .value = 2.0, .tags_json = "{}" });
        try waitForFlush(engine, 2, 1_000);
        try engine.verifyCasState();
    }

    {
        var data_dir = try std.fs.cwd().openDir(data_path, .{ .iterate = true });
        defer data_dir.close();
        data_dir.deleteTree("segments") catch {};
        data_dir.deleteFile("MANIFEST") catch {};
        data_dir.deleteFile("tags.json") catch {};
        data_dir.deleteFile("series_catalog.jsonl") catch {};
    }

    {
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
            .cas_mode = .dual_write,
            .metadata_read_mode = .primary,
            .retention_ns = std.StringHashMap(u32).init(talloc),
        };

        var engine = try Engine.init(talloc, config);
        defer engine.deinit();

        try std.testing.expect(try engine.compactNow());
        try std.testing.expectEqual(@as(usize, 1), engine.metadata.manifest.entries.items.len);

        var results = std.array_list.Managed(types.Point).init(talloc);
        defer results.deinit();
        try engine.queryRange(sid, 0, 10_000, &results);
        try std.testing.expectEqual(@as(usize, 2), results.items.len);
        try std.testing.expectEqual(@as(i64, 1_000), results.items[0].ts);
        try std.testing.expectApproxEqAbs(@as(f64, 2.0), results.items[1].value, 1e-9);
    }
}

test "engine compaction creates a maintenance checkpoint ref" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/compaction-checkpoint", .{tmp.sub_path});
    defer talloc.free(data_path);
    const sid = types.hash64("compaction.checkpoint.series");

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
        .cas_mode = .dual_write,
        .retention_ns = std.StringHashMap(u32).init(talloc),
    };

    var engine = try Engine.init(talloc, config);
    defer engine.deinit();

    try engine.registerSeries("compaction.checkpoint.series", "{}", sid);
    try engine.ingest(.{ .series_id = sid, .ts = 1_000, .value = 1.0, .tags_json = "{}" });
    try waitForFlush(engine, 1, 1_000);
    try engine.ingest(.{ .series_id = sid, .ts = 1_500, .value = 2.0, .tags_json = "{}" });
    try waitForFlush(engine, 2, 1_000);

    try std.testing.expect(try engine.compactNow());

    const refs = try engine.cas.?.listRefs();
    defer {
        for (refs) |*entry| entry.deinit(talloc);
        talloc.free(refs);
    }

    var saw_checkpoint = false;
    for (refs) |entry| {
        if (std.mem.startsWith(u8, entry.name, "checkpoints/compaction-")) {
            saw_checkpoint = true;
            break;
        }
    }
    try std.testing.expect(saw_checkpoint);
}

test "engine serializes cas index refresh during concurrent compaction syncs" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/compaction-refresh-race", .{tmp.sub_path});
    defer talloc.free(data_path);
    const sid = types.hash64("compaction.refresh.race");

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
        .cas_mode = .dual_write,
        .metadata_read_mode = .primary,
        .retention_ns = std.StringHashMap(u32).init(talloc),
    };

    var engine = try Engine.init(talloc, config);
    defer engine.deinit();

    try engine.registerSeries("compaction.refresh.race", "{}", sid);
    try engine.ingest(.{ .series_id = sid, .ts = 1_000, .value = 1.0, .tags_json = "{}" });
    try waitForFlush(engine, 1, 1_000);
    try engine.ingest(.{ .series_id = sid, .ts = 1_500, .value = 2.0, .tags_json = "{}" });
    try waitForFlush(engine, 2, 1_000);
    try std.testing.expect(try engine.compactNow());

    const SyncWorker = struct {
        engine: *Engine,
        cas: *cas_mod.CasManager,
        failure_mu: std.Thread.Mutex = .{},
        failure: ?anyerror = null,

        fn run(self: *@This()) void {
            var idx: usize = 0;
            while (idx < 32) : (idx += 1) {
                self.engine.metadata.refreshCasIndex(self.cas) catch |err| {
                    self.failure_mu.lock();
                    defer self.failure_mu.unlock();
                    self.failure = err;
                    return;
                };
                sleepMs(1);
            }
        }
    };

    var worker = SyncWorker{ .engine = engine, .cas = &(engine.cas orelse return error.CasDisabled) };
    const thread = try std.Thread.spawn(.{}, SyncWorker.run, .{&worker});
    var thread_joined = false;
    defer if (!thread_joined) thread.join();

    var attempts: usize = 0;
    while (attempts < 32) : (attempts += 1) {
        _ = try worker.cas.syncLegacySnapshot(
            engine.data_dir,
            &engine.metadata.manifest,
            &engine.metadata.tags,
            &engine.metadata.series_catalog,
            "concurrent-compaction-sync",
        );
        try engine.metadata.refreshCasIndexIfStale(worker.cas);
        sleepMs(1);
    }

    thread.join();
    thread_joined = true;
    worker.failure_mu.lock();
    const worker_failure = worker.failure;
    worker.failure_mu.unlock();
    if (worker_failure) |err| return err;
    try engine.verifyCasState();
}

test "engine resolveSelector surfaces metadata for by-id and exact lookups" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/selector-data", .{tmp.sub_path});
    defer talloc.free(data_path);
    const sid = types.seriesIdFrom("selector.series", "{\"rack\":\"r1\",\"host\":\"a\"}");

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
        .cas_mode = .off,
        .retention_ns = std.StringHashMap(u32).init(talloc),
    };

    var engine = try Engine.init(talloc, config);
    defer engine.deinit();

    try engine.registerSeries("selector.series", "{\"rack\":\"r1\",\"host\":\"a\"}", sid);

    const by_id = try engine.resolveSelector(.{ .by_id = sid });
    try std.testing.expectEqual(series_catalog_mod.ResolutionStatus.resolved, by_id.status);
    try std.testing.expectEqual(sid, by_id.series_id.?);
    try std.testing.expectEqualStrings("selector.series", by_id.series.?);
    try std.testing.expectEqualStrings("{\"host\":\"a\",\"rack\":\"r1\"}", by_id.canonical_tags.?);

    const exact = try engine.resolveSelector(.{ .exact = .{
        .series = "selector.series",
        .tags_json = "{\"host\":\"a\",\"rack\":\"r1\"}",
    } });
    try std.testing.expectEqual(series_catalog_mod.ResolutionStatus.exact_match, exact.status);
    try std.testing.expectEqual(sid, exact.series_id.?);
}

test "engine selector resolution stays deterministic across legacy shadow and primary modes" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/selector-parity-data", .{tmp.sub_path});
    defer talloc.free(data_path);

    const tags_a = "{\"rack\":\"r1\",\"host\":\"a\"}";
    const tags_b = "{\"rack\":\"r2\",\"host\":\"b\"}";
    const canonical_tags_a = "{\"host\":\"a\",\"rack\":\"r1\"}";
    const canonical_tags_b = "{\"host\":\"b\",\"rack\":\"r2\"}";
    const sid_a = types.seriesIdFrom("parity.series", tags_a);
    const sid_b = types.seriesIdFrom("parity.series", tags_b);

    {
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
            .cas_mode = .dual_write,
            .retention_ns = std.StringHashMap(u32).init(talloc),
        };

        var engine = try Engine.init(talloc, config);
        defer engine.deinit();

        try engine.registerSeries("parity.series", tags_a, sid_a);
        try engine.ingest(.{ .series_id = sid_a, .ts = 10, .value = 1.0, .tags_json = tags_a });
        try engine.registerSeries("parity.series", tags_b, sid_b);
        try engine.ingest(.{ .series_id = sid_b, .ts = 20, .value = 2.0, .tags_json = tags_b });
        try waitForFlush(engine, 1, 1_000);
        try engine.verifyCasState();
    }

    const modes = [_]cfg.MetadataReadMode{ .legacy, .shadow, .primary };
    for (modes) |mode| {
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
            .cas_mode = .dual_write,
            .metadata_read_mode = mode,
            .retention_ns = std.StringHashMap(u32).init(talloc),
        };

        var engine = try Engine.init(talloc, config);
        defer engine.deinit();

        try std.testing.expect(engine.resolveUniqueSeriesName("parity.series") == .ambiguous);

        try std.testing.expectEqual(sid_a, switch (try engine.resolveExactSeries("parity.series", tags_a)) {
            .resolved => |resolved| resolved,
            else => return error.TestUnexpectedResult,
        });
        try std.testing.expectEqual(sid_b, switch (try engine.resolveExactSeries("parity.series", canonical_tags_b)) {
            .resolved => |resolved| resolved,
            else => return error.TestUnexpectedResult,
        });
        try std.testing.expect((try engine.resolveExactSeries("parity.series", "{\"host\":\"missing\"}")) == .not_found);

        const by_id = try engine.resolveSelector(.{ .by_id = sid_a });
        try std.testing.expectEqual(series_catalog_mod.ResolutionStatus.resolved, by_id.status);
        try std.testing.expectEqualStrings("parity.series", by_id.series.?);
        try std.testing.expectEqualStrings(canonical_tags_a, by_id.canonical_tags.?);

        var parsed = try std.json.parseFromSlice(std.json.Value, talloc, "{\"host\":\"a\"}", .{});
        defer parsed.deinit();
        var matches = try engine.collectMatchingSeriesIds(talloc, parsed.value, true);
        defer matches.deinit();
        try std.testing.expectEqual(@as(usize, 1), matches.items.len);
        try std.testing.expectEqual(sid_a, matches.items[0]);
    }
}

test "engine rebuilds missing series catalog from segment metadata and wal registrations" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/repair-data", .{tmp.sub_path});
    defer talloc.free(data_path);
    const flushed_tags = "{\"host\":\"a\"}";
    const wal_tags = "{\"host\":\"b\"}";
    const flushed_sid = types.seriesIdFrom("repair.flush", flushed_tags);
    const wal_sid = types.seriesIdFrom("repair.live", wal_tags);

    {
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
            .cas_mode = .off,
            .retention_ns = std.StringHashMap(u32).init(talloc),
        };

        var engine = try Engine.init(talloc, config);
        defer engine.deinit();

        try engine.registerSeries("repair.flush", flushed_tags, flushed_sid);
        try engine.ingest(.{ .series_id = flushed_sid, .ts = 1_000, .value = 1.0, .tags_json = flushed_tags });
        try waitForFlush(engine, 1, 1_000);

        try engine.registerSeries("repair.live", wal_tags, wal_sid);
        try engine.ingest(.{ .series_id = wal_sid, .ts = 2_000, .value = 2.0, .tags_json = wal_tags });
        try waitForQueueEmpty(engine, 1_000);
    }

    {
        var data_dir = try std.fs.cwd().openDir(data_path, .{ .iterate = true });
        defer data_dir.close();
        try data_dir.deleteFile("series_catalog.jsonl");
    }

    {
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
            .cas_mode = .off,
            .retention_ns = std.StringHashMap(u32).init(talloc),
        };

        var engine = try Engine.init(talloc, config);
        defer engine.deinit();

        try std.testing.expectEqual(flushed_sid, switch (engine.resolveUniqueSeriesName("repair.flush")) {
            .resolved => |sid| sid,
            else => return error.TestUnexpectedResult,
        });
        try std.testing.expectEqual(wal_sid, switch (engine.resolveUniqueSeriesName("repair.live")) {
            .resolved => |sid| sid,
            else => return error.TestUnexpectedResult,
        });

        var flushed_points = std.array_list.Managed(types.Point).init(talloc);
        defer flushed_points.deinit();
        try engine.queryRange(flushed_sid, 0, 10_000, &flushed_points);
        try std.testing.expectEqual(@as(usize, 1), flushed_points.items.len);

        var wal_points = std.array_list.Managed(types.Point).init(talloc);
        defer wal_points.deinit();
        try engine.queryRange(wal_sid, 0, 10_000, &wal_points);
        try std.testing.expectEqual(@as(usize, 1), wal_points.items.len);
        try std.testing.expectApproxEqAbs(@as(f64, 2.0), wal_points.items[0].value, 1e-9);
    }
}

test "engine dual-write creates a parent-linked CAS commit chain" {
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
        .cas_mode = .dual_write,
        .retention_ns = std.StringHashMap(u32).init(talloc),
    };

    var engine = try Engine.init(talloc, config);
    defer engine.deinit();

    try engine.verifyCasState();

    const initial_head = try engine.cas.?.refs.readHead(cas_mod.main_ref) orelse return error.MissingCasHead;
    const sid = types.hash64("cas.chain");
    try engine.ingest(.{ .series_id = sid, .ts = 1_000, .value = 10.0, .tags_json = "{}" });
    try engine.ingest(.{ .series_id = sid, .ts = 1_005, .value = 11.0, .tags_json = "{}" });
    engine.noteTags(sid, "{\"host\":\"cas\"}");

    try waitForFlush(engine, 1, 1_000);
    try engine.verifyCasState();

    const next_head = try engine.cas.?.refs.readHead(cas_mod.main_ref) orelse return error.MissingCasHead;
    try std.testing.expect(!initial_head.eql(next_head));

    var reader = cas_mod.CommitReader{ .alloc = talloc, .store = &engine.cas.?.store, .refs = &engine.cas.?.refs };
    var snapshot = try reader.loadHeadSnapshot();
    defer snapshot.deinit(talloc);

    try std.testing.expectEqual(@as(usize, 1), snapshot.commit.parents.len);
    try std.testing.expect(snapshot.commit.parents[0].eql(initial_head));
    try std.testing.expectEqual(@as(usize, 1), snapshot.segment_descriptors.len);
    try std.testing.expectEqual(@as(usize, 1), snapshot.tag_snapshot.entries.len);
}
