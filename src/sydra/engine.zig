const std = @import("std");
const cfg = @import("config.zig");
const types = @import("types.zig");
const AtomicU64 = @import("atomic_util.zig").AtomicU64;
const manifest_mod = @import("storage/manifest.zig");
const market_catalog_mod = @import("storage/market_catalog.zig");
const market_runtime_mod = @import("storage/market_runtime.zig");
const metric_catalog_mod = @import("storage/metric_catalog.zig");
const object_store = @import("storage/object_store.zig");
const series_catalog_mod = @import("storage/series_catalog.zig");
const signal_events_mod = @import("storage/signal_events.zig");
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
    derived_thread: ?std.Thread = null,
    stop_flag: bool = false,
    queue: *Queue,
    cas: ?cas_mod.CasManager = null,
    market_runtime: market_runtime_mod.State,
    signal_events: signal_events_mod.Store,
    exact_series_declare_mu: std.Thread.Mutex = .{},
    derived_mu: std.Thread.Mutex = .{},
    derived_cv: std.Thread.Condition = .{},
    derived_pending: bool = false,
    derived_full_refresh: bool = false,
    derived_dirty: std.array_list.Managed(DirtyDefinitionWork),
    signal_event_mu: std.Thread.Mutex = .{},
    signal_event_cv: std.Thread.Condition = .{},
    signal_event_epoch: u64 = 0,
    tag_index_dirty: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub const SelectorLookup = union(enum) {
        by_id: types.SeriesId,
        name: []const u8,
        exact: struct {
            series: []const u8,
            tags_json: []const u8,
        },
    };

    pub const SeriesDescriptor = struct {
        series_id: types.SeriesId,
        metric: []const u8,
        labels_json: []const u8,
        first_ts: ?i64 = null,
        last_ts: ?i64 = null,
    };

    pub const PendingStats = struct {
        pending_instances: usize,
        max_lag_ns: ?i64,
    };

    const MetricSeriesGroup = struct {
        labels_json: []u8,
        series_ids: []types.SeriesId,

        fn deinit(self: *MetricSeriesGroup, alloc: std.mem.Allocator) void {
            alloc.free(self.labels_json);
            alloc.free(self.series_ids);
        }
    };

    const DirtyDefinitionWork = struct {
        namespace: []u8,
        definition_id: []u8,
        definition_version: u32,
        labels_json: []u8,
        queued_at_ns: i64,

        fn deinit(self: *DirtyDefinitionWork, alloc: std.mem.Allocator) void {
            alloc.free(self.namespace);
            alloc.free(self.definition_id);
            alloc.free(self.labels_json);
            self.* = undefined;
        }
    };

    const TradeSample = struct {
        ts: i64,
        price: f64,
        size: f64,
    };

    const QuoteSample = struct {
        ts: i64,
        bid: f64,
        ask: f64,
        bid_size: f64,
        ask_size: f64,
    };

    const BarSample = struct {
        ts: i64,
        open: f64,
        high: f64,
        low: f64,
        close: f64,
        volume: f64,
        vwap: f64,
    };

    const LabelAddition = struct {
        key: []const u8,
        value: []const u8,
    };

    pub const MetadataState = struct {
        alloc: std.mem.Allocator,
        manifest: manifest_mod.Manifest,
        tags: tags_mod.TagIndex,
        series_catalog: series_catalog_mod.SeriesCatalog,
        metric_catalog: metric_catalog_mod.MetricCatalog,
        market_catalog: market_catalog_mod.Catalog,
        cas_index: ?cas_mod.SnapshotIndex = null,
        cas_index_mu: std.Thread.Mutex = .{},

        pub fn deinit(self: *MetadataState) void {
            self.manifest.deinit();
            self.tags.deinit();
            self.series_catalog.deinit();
            self.metric_catalog.deinit();
            self.market_catalog.deinit();
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
                    return try loadFromCas(alloc, data_dir, config.fsync, cas_manager.?);
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
            var metric_catalog = try metric_catalog_mod.MetricCatalog.loadOrInit(alloc, data_dir, fsync);
            errdefer metric_catalog.deinit();
            var market_catalog = try market_catalog_mod.Catalog.loadOrInit(alloc, data_dir, fsync);
            errdefer market_catalog.deinit();
            return .{
                .alloc = alloc,
                .manifest = manifest,
                .tags = tags,
                .series_catalog = series_catalog,
                .metric_catalog = metric_catalog,
                .market_catalog = market_catalog,
                .cas_index = null,
            };
        }

        fn loadFromCas(
            alloc: std.mem.Allocator,
            data_dir: std.fs.Dir,
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
            var metric_catalog = try metricCatalogFromSnapshot(alloc, fsync, index.snapshot.metric_catalog_snapshot);
            errdefer metric_catalog.deinit();
            var market_catalog = if (index.snapshot.market_catalog_snapshot) |snapshot|
                try market_catalog_mod.Catalog.initFromSnapshot(alloc, data_dir, fsync, snapshot)
            else
                try market_catalog_mod.Catalog.loadOrInit(alloc, data_dir, fsync);
            errdefer market_catalog.deinit();
            return .{
                .alloc = alloc,
                .manifest = manifest,
                .tags = tags,
                .series_catalog = series_catalog,
                .metric_catalog = metric_catalog,
                .market_catalog = market_catalog,
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

    const MemSeriesBuffer = struct {
        points: std.array_list.Managed(types.Point),
        sorted: bool = true,
        last_ts: ?i64 = null,

        fn init(alloc: std.mem.Allocator) MemSeriesBuffer {
            return .{
                .points = std.array_list.Managed(types.Point).init(alloc),
            };
        }

        fn deinit(self: *MemSeriesBuffer) void {
            self.points.deinit();
            self.* = undefined;
        }

        fn clearRetainingCapacity(self: *MemSeriesBuffer) void {
            self.points.clearRetainingCapacity();
            self.sorted = true;
            self.last_ts = null;
        }
    };

    pub const MemTable = struct {
        alloc: std.mem.Allocator,
        series: std.AutoHashMap(types.SeriesId, MemSeriesBuffer),
        bytes: std.atomic.Value(usize),
        pub fn init(alloc: std.mem.Allocator) MemTable {
            return .{
                .alloc = alloc,
                .series = std.AutoHashMap(types.SeriesId, MemSeriesBuffer).init(alloc),
                .bytes = std.atomic.Value(usize).init(0),
            };
        }
        pub fn deinit(self: *MemTable) void {
            var it = self.series.valueIterator();
            while (it.next()) |buffer| buffer.deinit();
            self.series.deinit();
        }
    };

    pub const IngestItem = struct {
        series_id: types.SeriesId,
        ts: i64,
        value: f64,
        tags_json: []const u8,
    };

    pub const ResolvedIngestPoint = struct {
        series_id: types.SeriesId,
        ts: i64,
        value: f64,
    };

    pub const AppendBatchReceipt = struct {
        accepted_points: usize,
        queue_depth: usize,
        pending_bytes: usize,
    };

    pub const ExactSeriesDeclarationInput = struct {
        name: []const u8,
        tags_json: []const u8,
        descriptor: ?metric_catalog_mod.DescriptorInput = null,
    };

    pub const ExactSeriesCanonicalDeclarationInput = struct {
        name: []const u8,
        canonical_tags: []const u8,
        descriptor: ?metric_catalog_mod.DescriptorInput = null,
    };

    pub const ExactSeriesDeclarationStatus = enum {
        ok,
        metric_descriptor_conflict,
        series_conflict,
    };

    pub const ExactSeriesBatchDeclarationResult = struct {
        status: ExactSeriesDeclarationStatus = .ok,
        series_id: ?types.SeriesId = null,
        registration: ExactSeriesRegistration = .unchanged,
    };

    pub const ExactSeriesRegistration = enum {
        inserted,
        unchanged,
    };

    pub const ExactSeriesDeclarationResult = struct {
        series_id: types.SeriesId,
        canonical_tags: []u8,

        pub fn deinit(self: *ExactSeriesDeclarationResult, alloc: std.mem.Allocator) void {
            alloc.free(self.canonical_tags);
            self.* = undefined;
        }
    };

    const QueuedBatch = struct {
        points: []ResolvedIngestPoint,
        bytes: usize,

        fn deinit(self: *QueuedBatch, alloc: std.mem.Allocator) void {
            alloc.free(self.points);
            self.* = undefined;
        }
    };

    pub const Queue = struct {
        alloc: std.mem.Allocator,
        mu: std.Thread.Mutex = .{},
        cv: std.Thread.Condition = .{},
        buf: []QueuedBatch = &.{},
        head: usize = 0,
        count: usize = 0,
        pending_points: usize = 0,
        pending_bytes: usize = 0,
        closed: bool = false,
        metrics: *Metrics,
        const lock_wait_threshold_ns: i64 = 1_000;

        pub fn init(alloc: std.mem.Allocator, metrics: *Metrics) !*Queue {
            const q = try alloc.create(Queue);
            q.* = .{
                .alloc = alloc,
                .metrics = metrics,
            };
            return q;
        }
        pub fn deinit(self: *Queue) void {
            var idx: usize = 0;
            while (idx < self.count) : (idx += 1) {
                var batch = self.buf[self.activeIndex(idx)];
                batch.deinit(self.alloc);
            }
            if (self.buf.len != 0) self.alloc.free(self.buf);
        }
        pub fn push(self: *Queue, point: ResolvedIngestPoint) !void {
            const owned_points = try self.alloc.alloc(ResolvedIngestPoint, 1);
            errdefer self.alloc.free(owned_points);
            owned_points[0] = point;
            return self.pushOwned(.{
                .points = owned_points,
                .bytes = @sizeOf(ResolvedIngestPoint),
            });
        }
        pub fn pushBatch(self: *Queue, points: []const ResolvedIngestPoint) !void {
            if (points.len == 0) return;
            const owned_points = try self.alloc.dupe(ResolvedIngestPoint, points);
            errdefer self.alloc.free(owned_points);
            return self.pushOwned(.{
                .points = owned_points,
                .bytes = points.len * @sizeOf(ResolvedIngestPoint),
            });
        }
        fn pushOwned(self: *Queue, batch: QueuedBatch) !void {
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
            if (self.closed) {
                var rejected = batch;
                rejected.deinit(self.alloc);
                return error.Closed;
            }
            try self.ensureCapacity(self.count + 1);
            const insert_idx = if (self.buf.len == 0) 0 else (self.head + self.count) % self.buf.len;
            self.buf[insert_idx] = batch;
            self.count += 1;
            self.pending_points += batch.points.len;
            self.pending_bytes += batch.bytes;
            self.cv.signal();
        }
        pub fn pop(self: *Queue) ?QueuedBatch {
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
            while (self.count == 0 and !self.closed) {
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
            if (self.count == 0) {
                const release_ns = std.time.nanoTimestamp();
                const hold_ns = release_ns - hold_start_ns;
                _ = self.metrics.queue_pop_lock_hold_ns_total.fetchAdd(@as(u64, @intCast(hold_ns)), .monotonic);
                self.mu.unlock();
                return null;
            }
            const batch = self.buf[self.head];
            self.head = if (self.buf.len == 0) 0 else (self.head + 1) % self.buf.len;
            self.count -= 1;
            self.pending_points -= batch.points.len;
            self.pending_bytes -= batch.bytes;
            if (self.count == 0) self.head = 0;
            const release_ns = std.time.nanoTimestamp();
            const hold_ns = release_ns - hold_start_ns;
            _ = self.metrics.queue_pop_lock_hold_ns_total.fetchAdd(@as(u64, @intCast(hold_ns)), .monotonic);
            self.mu.unlock();
            return batch;
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
            return self.pending_points;
        }
        pub fn pendingBytes(self: *Queue) usize {
            self.mu.lock();
            defer self.mu.unlock();
            return self.pending_bytes;
        }
        fn activeIndex(self: *const Queue, logical_idx: usize) usize {
            return (self.head + logical_idx) % self.buf.len;
        }
        fn ensureCapacity(self: *Queue, needed: usize) !void {
            if (needed <= self.buf.len) return;
            var new_cap: usize = if (self.buf.len == 0) 8 else self.buf.len * 2;
            while (new_cap < needed) : (new_cap *= 2) {}
            const new_buf = try self.alloc.alloc(QueuedBatch, new_cap);
            if (self.count != 0) {
                for (0..self.count) |idx| {
                    new_buf[idx] = self.buf[self.activeIndex(idx)];
                }
            }
            if (self.buf.len != 0) self.alloc.free(self.buf);
            self.buf = new_buf;
            self.head = 0;
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
        drain_timeout_total: AtomicU64,
        queue_pop_total: AtomicU64,
        queue_wait_ns_total: AtomicU64,
        queue_max_len: std.atomic.Value(usize),
        queue_pending_bytes_max: std.atomic.Value(usize),
        queue_len_sum: AtomicU64,
        queue_len_samples: AtomicU64,
        maintenance_pause_active: std.atomic.Value(bool),
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
        memtable_append_ns_total: AtomicU64,
        memtable_append_failed_total: AtomicU64,
        ingest_quarantined_total: AtomicU64,
        ingest_quarantine_write_failed_total: AtomicU64,
        cas_sync_total: AtomicU64,
        cas_sync_failed_total: AtomicU64,
        cas_sync_ns_total: AtomicU64,
        cas_shadow_mismatch_total: AtomicU64,
        tag_index_save_total: AtomicU64,
        tag_index_save_skipped_total: AtomicU64,
        tag_index_save_ns_total: AtomicU64,
        local_ingest_connections_total: AtomicU64,
        local_ingest_connections_current: AtomicU64,
        local_ingest_frames_total: AtomicU64,
        local_ingest_frame_bytes_total: AtomicU64,
        local_ingest_declare_batches_total: AtomicU64,
        local_ingest_declare_total: AtomicU64,
        local_ingest_declare_ns_total: AtomicU64,
        local_ingest_append_batches_total: AtomicU64,
        local_ingest_append_points_total: AtomicU64,
        local_ingest_append_ns_total: AtomicU64,
        local_ingest_append_batch_points_max: std.atomic.Value(usize),
        local_ingest_rejected_total: AtomicU64,
        local_ingest_unknown_decl_total: AtomicU64,
        local_ingest_frame_too_large_total: AtomicU64,
        local_ingest_protocol_error_total: AtomicU64,
        exact_series_declare_metric_catalog_ns_total: AtomicU64,
        exact_series_declare_series_catalog_ns_total: AtomicU64,
        exact_series_declare_wal_registration_ns_total: AtomicU64,
        exact_series_declare_tag_index_ns_total: AtomicU64,
        exact_series_declare_inserted_total: AtomicU64,
        exact_series_declare_unchanged_total: AtomicU64,
        exact_series_declare_descriptor_conflict_total: AtomicU64,
        exact_series_declare_series_conflict_total: AtomicU64,

        pub fn init() Metrics {
            return .{
                .ingest_total = AtomicU64.init(0),
                .flush_total = AtomicU64.init(0),
                .flush_ns_total = AtomicU64.init(0),
                .flush_points_total = AtomicU64.init(0),
                .wal_append_total = AtomicU64.init(0),
                .wal_append_ns_total = AtomicU64.init(0),
                .wal_bytes_total = AtomicU64.init(0),
                .drain_timeout_total = AtomicU64.init(0),
                .queue_pop_total = AtomicU64.init(0),
                .queue_wait_ns_total = AtomicU64.init(0),
                .queue_max_len = std.atomic.Value(usize).init(0),
                .queue_pending_bytes_max = std.atomic.Value(usize).init(0),
                .queue_len_sum = AtomicU64.init(0),
                .queue_len_samples = AtomicU64.init(0),
                .maintenance_pause_active = std.atomic.Value(bool).init(false),
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
                .memtable_append_ns_total = AtomicU64.init(0),
                .memtable_append_failed_total = AtomicU64.init(0),
                .ingest_quarantined_total = AtomicU64.init(0),
                .ingest_quarantine_write_failed_total = AtomicU64.init(0),
                .cas_sync_total = AtomicU64.init(0),
                .cas_sync_failed_total = AtomicU64.init(0),
                .cas_sync_ns_total = AtomicU64.init(0),
                .cas_shadow_mismatch_total = AtomicU64.init(0),
                .tag_index_save_total = AtomicU64.init(0),
                .tag_index_save_skipped_total = AtomicU64.init(0),
                .tag_index_save_ns_total = AtomicU64.init(0),
                .local_ingest_connections_total = AtomicU64.init(0),
                .local_ingest_connections_current = AtomicU64.init(0),
                .local_ingest_frames_total = AtomicU64.init(0),
                .local_ingest_frame_bytes_total = AtomicU64.init(0),
                .local_ingest_declare_batches_total = AtomicU64.init(0),
                .local_ingest_declare_total = AtomicU64.init(0),
                .local_ingest_declare_ns_total = AtomicU64.init(0),
                .local_ingest_append_batches_total = AtomicU64.init(0),
                .local_ingest_append_points_total = AtomicU64.init(0),
                .local_ingest_append_ns_total = AtomicU64.init(0),
                .local_ingest_append_batch_points_max = std.atomic.Value(usize).init(0),
                .local_ingest_rejected_total = AtomicU64.init(0),
                .local_ingest_unknown_decl_total = AtomicU64.init(0),
                .local_ingest_frame_too_large_total = AtomicU64.init(0),
                .local_ingest_protocol_error_total = AtomicU64.init(0),
                .exact_series_declare_metric_catalog_ns_total = AtomicU64.init(0),
                .exact_series_declare_series_catalog_ns_total = AtomicU64.init(0),
                .exact_series_declare_wal_registration_ns_total = AtomicU64.init(0),
                .exact_series_declare_tag_index_ns_total = AtomicU64.init(0),
                .exact_series_declare_inserted_total = AtomicU64.init(0),
                .exact_series_declare_unchanged_total = AtomicU64.init(0),
                .exact_series_declare_descriptor_conflict_total = AtomicU64.init(0),
                .exact_series_declare_series_conflict_total = AtomicU64.init(0),
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
            .market_runtime = undefined,
            .signal_events = undefined,
            .derived_dirty = std.array_list.Managed(DirtyDefinitionWork).init(alloc),
        };
        metadata_transferred = true;
        cas_manager_transferred = true;
        errdefer {
            for (engine.derived_dirty.items) |*item| item.deinit(engine.alloc);
            engine.derived_dirty.deinit();
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
        engine.market_runtime = try market_runtime_mod.State.loadOrInit(alloc, engine.data_dir, engine.config.fsync);
        errdefer engine.market_runtime.deinit();
        engine.signal_events = try signal_events_mod.Store.loadOrInit(alloc, engine.data_dir, engine.config.fsync);
        errdefer engine.signal_events.deinit();
        if (engine.cas) |*cas| {
            _ = try cas.bootstrapIfMissingWithMarket(
                engine.data_dir,
                &engine.metadata.manifest,
                &engine.metadata.tags,
                &engine.metadata.series_catalog,
                &engine.metadata.metric_catalog,
                &engine.metadata.market_catalog,
            );
            try engine.metadata.refreshCasIndex(cas);
        }
        try engine.recover();
        engine.writer_thread = try std.Thread.spawn(.{}, writerLoop, .{engine});
        engine.derived_thread = try std.Thread.spawn(.{}, derivedLoop, .{engine});
        engine.scheduleDerivedRefresh();
        return engine;
    }

    pub fn deinit(self: *Engine) void {
        self.stop_flag = true;
        self.queue.close();
        self.derived_mu.lock();
        self.derived_pending = true;
        self.derived_mu.unlock();
        self.derived_cv.broadcast();
        if (self.writer_thread) |t| t.join();
        if (self.derived_thread) |t| t.join();
        for (self.derived_dirty.items) |*item| item.deinit(self.alloc);
        self.derived_dirty.deinit();
        self.mem.deinit();
        self.metadata.deinit();
        self.wal.close();
        self.data_dir.close();
        self.queue.deinit();
        self.alloc.destroy(self.queue);
        self.market_runtime.deinit();
        self.signal_events.deinit();
        if (self.cas) |*cas| cas.deinit();
        self.config.deinit(self.alloc);
        self.alloc.destroy(self);
    }

    pub fn snapshotTo(self: *Engine, dst_path: []const u8) !void {
        try pauseWriterForMaintenance(self);
        errdefer resumeWriterAfterMaintenance(self) catch |err| {
            std.log.err("failed to resume writer after snapshotTo: {s}", .{@errorName(err)});
        };
        const flushed = try flushMemtable(self);
        if (flushed) try self.syncCasSnapshot("snapshot-flush");
        try self.wal.file.sync();
        if (!flushed or self.cas == null) try self.ensureSnapshotBundleHead();
        try @import("snapshot.zig").snapshot(self.alloc, self.config.data_dir, dst_path, self.config.fsync);
        try resumeWriterAfterMaintenance(self);
    }

    pub fn appendResolvedPoint(self: *Engine, point: ResolvedIngestPoint) !AppendBatchReceipt {
        const one = [_]ResolvedIngestPoint{point};
        return try self.appendResolvedBatch(one[0..]);
    }

    pub fn appendResolvedBatch(self: *Engine, points: []const ResolvedIngestPoint) !AppendBatchReceipt {
        if (points.len == 0) {
            return .{
                .accepted_points = 0,
                .queue_depth = self.queue.len(),
                .pending_bytes = self.queue.pendingBytes(),
            };
        }
        const batch_bytes = points.len * @sizeOf(ResolvedIngestPoint);
        if (self.config.mem_limit_bytes != 0) {
            const queued_bytes = self.queue.pendingBytes();
            const resident_bytes = self.mem.bytes.load(.monotonic) + queued_bytes + batch_bytes;
            if (resident_bytes >= self.config.mem_limit_bytes) {
                _ = self.metrics.ingest_rejected_total.fetchAdd(1, .monotonic);
                _ = self.metrics.ingest_rejected_mem_limit_total.fetchAdd(1, .monotonic);
                return error.MemoryLimitExceeded;
            }
        }
        try self.queue.pushBatch(points);
        const len_now = self.queue.len();
        const pending_bytes_now = self.queue.pendingBytes();
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
        var current_pending_max = self.metrics.queue_pending_bytes_max.load(.monotonic);
        while (pending_bytes_now > current_pending_max) {
            if (self.metrics.queue_pending_bytes_max.cmpxchgWeak(current_pending_max, pending_bytes_now, .monotonic, .monotonic)) |prev|
                current_pending_max = prev
            else
                break;
        }
        return .{
            .accepted_points = points.len,
            .queue_depth = len_now,
            .pending_bytes = pending_bytes_now,
        };
    }

    pub fn ingest(self: *Engine, item: IngestItem) !void {
        _ = item.tags_json;
        _ = try self.appendResolvedPoint(.{
            .series_id = item.series_id,
            .ts = item.ts,
            .value = item.value,
        });
    }

    pub fn ingestBatch(self: *Engine, items: []const IngestItem) !void {
        if (items.len == 0) return;
        var points = try self.alloc.alloc(ResolvedIngestPoint, items.len);
        defer self.alloc.free(points);
        for (items, 0..) |item, idx| {
            points[idx] = .{
                .series_id = item.series_id,
                .ts = item.ts,
                .value = item.value,
            };
        }
        _ = try self.appendResolvedBatch(points);
    }

    fn writerLoop(self: *Engine) void {
        var last_flush = std.time.milliTimestamp();
        var last_sync = last_flush;
        var last_pop_ns = std.time.nanoTimestamp();
        while (true) {
            if (self.queue.pop()) |batch| {
                defer {
                    var cleanup = batch;
                    cleanup.deinit(self.alloc);
                }
                const now_ns = std.time.nanoTimestamp();
                const wait_delta = now_ns - last_pop_ns;
                _ = self.metrics.queue_pop_total.fetchAdd(@intCast(batch.points.len), .monotonic);
                if (wait_delta > 0) {
                    _ = self.metrics.queue_wait_ns_total.fetchAdd(@as(u64, @intCast(wait_delta)), .monotonic);
                }
                last_pop_ns = now_ns;
                const wal_start_ns = std.time.nanoTimestamp();
                const wal_bytes = self.wal.appendBatch(batch.points) catch |err| blk: {
                    _ = self.metrics.wal_append_failed_total.fetchAdd(@intCast(batch.points.len), .monotonic);
                    for (batch.points) |point| {
                        self.quarantineFailedIngest(point, "wal_append_batch", @errorName(err));
                    }
                    std.log.warn("wal batch append failed: {s}", .{@errorName(err)});
                    break :blk 0;
                };
                const wal_elapsed_ns: u64 = @intCast(std.time.nanoTimestamp() - wal_start_ns);
                if (wal_bytes != 0) {
                    _ = self.metrics.wal_append_total.fetchAdd(@intCast(batch.points.len), .monotonic);
                    _ = self.metrics.wal_append_ns_total.fetchAdd(wal_elapsed_ns, .monotonic);
                    _ = self.metrics.wal_bytes_total.fetchAdd(wal_bytes, .monotonic);

                    const memtable_start_ns = std.time.nanoTimestamp();
                    if (self.appendMemtableBatchGrouped(batch.points)) |_| {
                        const memtable_elapsed_ns: u64 = @intCast(std.time.nanoTimestamp() - memtable_start_ns);
                        _ = self.metrics.memtable_append_ns_total.fetchAdd(memtable_elapsed_ns, .monotonic);
                        _ = self.metrics.ingest_total.fetchAdd(@intCast(batch.points.len), .monotonic);
                    } else |err| {
                        _ = self.metrics.memtable_append_failed_total.fetchAdd(@intCast(batch.points.len), .monotonic);
                        for (batch.points) |point| {
                            self.quarantineFailedIngest(point, "memtable_append_batch", @errorName(err));
                        }
                        std.log.warn("failed to append batch to memtable: {s}", .{@errorName(err)});
                    }
                }
            } else {
                if (self.stop_flag) break;
                sleepMs(10);
            }

            const now = std.time.milliTimestamp();
            const mem_usage = self.mem.bytes.load(.monotonic);
            const queue_idle = self.queue.len() == 0;
            if (mem_usage >= self.config.memtable_max_bytes or (mem_usage != 0 and queue_idle and (now - last_flush) >= self.flush_timer_ms)) {
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
                    self.scheduleDerivedRefresh();
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

    fn scheduleDerivedRefresh(self: *Engine) void {
        self.derived_mu.lock();
        self.derived_full_refresh = true;
        self.derived_pending = true;
        self.derived_mu.unlock();
        self.derived_cv.signal();
    }

    fn scheduleDerivedDefinition(self: *Engine, namespace: []const u8, definition_id: []const u8, definition_version: u32, labels_json: []const u8) !void {
        self.derived_mu.lock();
        defer self.derived_mu.unlock();

        for (self.derived_dirty.items) |entry| {
            if (std.mem.eql(u8, entry.namespace, namespace) and
                std.mem.eql(u8, entry.definition_id, definition_id) and
                entry.definition_version == definition_version and
                std.mem.eql(u8, entry.labels_json, labels_json))
            {
                self.derived_pending = true;
                self.derived_cv.signal();
                return;
            }
        }
        try self.derived_dirty.append(.{
            .namespace = try self.alloc.dupe(u8, namespace),
            .definition_id = try self.alloc.dupe(u8, definition_id),
            .definition_version = definition_version,
            .labels_json = try self.alloc.dupe(u8, labels_json),
            .queued_at_ns = @intCast(std.time.nanoTimestamp()),
        });
        self.market_runtime.setPending(namespace, definition_id, definition_version, labels_json, true) catch {};
        self.derived_pending = true;
        self.derived_cv.signal();
    }

    pub fn scheduleDerivedMetric(self: *Engine, metric: []const u8, labels_json: []const u8) !void {
        {
            const rollups = try self.metadata.market_catalog.listRollups();
            defer {
                for (rollups) |*entry| entry.deinit(self.alloc);
                self.alloc.free(rollups);
            }
            for (rollups) |rollup| {
                if (std.mem.eql(u8, rollup.source_metric, metric)) {
                    try self.scheduleDerivedDefinition("rollup", rollup.id, rollup.version, labels_json);
                }
            }
        }
        {
            const signals = try self.metadata.market_catalog.listSignals();
            defer {
                for (signals) |*entry| entry.deinit(self.alloc);
                self.alloc.free(signals);
            }
            for (signals) |signal| {
                if (std.mem.eql(u8, signal.input_metric, metric)) {
                    try self.scheduleDerivedDefinition("signal", signal.id, signal.version, labels_json);
                }
            }
        }
    }

    fn derivedLoop(self: *Engine) void {
        while (true) {
            var full_refresh = false;
            var work_items = std.array_list.Managed(DirtyDefinitionWork).init(self.alloc);
            defer {
                for (work_items.items) |*item| item.deinit(self.alloc);
                work_items.deinit();
            }
            self.derived_mu.lock();
            while (!self.derived_pending and !self.stop_flag and !self.derived_full_refresh and self.derived_dirty.items.len == 0) {
                self.derived_cv.wait(&self.derived_mu);
            }
            const should_stop = self.stop_flag;
            full_refresh = self.derived_full_refresh;
            self.derived_full_refresh = false;
            if (full_refresh) {
                for (self.derived_dirty.items) |*item| item.deinit(self.alloc);
                self.derived_dirty.clearRetainingCapacity();
            } else if (self.derived_dirty.items.len != 0) {
                std.mem.swap(std.array_list.Managed(DirtyDefinitionWork), &work_items, &self.derived_dirty);
            }
            self.derived_pending = self.derived_full_refresh or self.derived_dirty.items.len != 0;
            self.derived_mu.unlock();
            if (should_stop) break;
            if (full_refresh or work_items.items.len == 0) {
                self.processDerivedDefinitions() catch |err| {
                    std.log.warn("derived worker failed: {s}", .{@errorName(err)});
                };
            } else {
                self.processDerivedDirtyItems(work_items.items) catch |err| {
                    std.log.warn("derived worker failed: {s}", .{@errorName(err)});
                };
            }
        }
    }

    fn processDerivedDirtyItems(self: *Engine, items: []DirtyDefinitionWork) !void {
        for (items) |item| {
            if (std.mem.eql(u8, item.namespace, "rollup")) {
                const rollups = try self.metadata.market_catalog.listRollups();
                defer {
                    for (rollups) |*entry| entry.deinit(self.alloc);
                    self.alloc.free(rollups);
                }
                for (rollups) |rollup| {
                    if (!std.mem.eql(u8, rollup.id, item.definition_id) or rollup.version != item.definition_version) continue;
                    if (self.market_runtime.isPaused("rollup", rollup.id, rollup.version)) continue;
                    const now_ts = std.time.nanoTimestamp();
                    try self.market_runtime.reportStart("rollup", rollup.id, rollup.version, @intCast(now_ts));
                    const report = self.processRollupDefinitionFiltered(rollup, item.labels_json) catch |err| blk: {
                        std.log.warn("rollup processing failed for {s}: {s}", .{ rollup.id, @errorName(err) });
                        break :blk market_runtime_mod.ProcessingReport{ .success = false, .error_message = @errorName(err) };
                    };
                    try self.market_runtime.reportResult("rollup", rollup.id, rollup.version, @intCast(std.time.nanoTimestamp()), report);
                    try self.market_runtime.setPending("rollup", rollup.id, rollup.version, item.labels_json, false);
                }
            } else if (std.mem.eql(u8, item.namespace, "signal")) {
                const signals = try self.metadata.market_catalog.listSignals();
                defer {
                    for (signals) |*entry| entry.deinit(self.alloc);
                    self.alloc.free(signals);
                }
                for (signals) |signal| {
                    if (!std.mem.eql(u8, signal.id, item.definition_id) or signal.version != item.definition_version) continue;
                    if (self.market_runtime.isPaused("signal", signal.id, signal.version)) continue;
                    const now_ts = std.time.nanoTimestamp();
                    try self.market_runtime.reportStart("signal", signal.id, signal.version, @intCast(now_ts));
                    const report = self.processSignalDefinitionFiltered(signal, item.labels_json) catch |err| blk: {
                        std.log.warn("signal processing failed for {s}: {s}", .{ signal.id, @errorName(err) });
                        break :blk market_runtime_mod.ProcessingReport{ .success = false, .error_message = @errorName(err) };
                    };
                    try self.market_runtime.reportResult("signal", signal.id, signal.version, @intCast(std.time.nanoTimestamp()), report);
                    try self.market_runtime.setPending("signal", signal.id, signal.version, item.labels_json, false);
                }
            }
        }
    }

    fn processDerivedDefinitions(self: *Engine) !void {
        const rollups = try self.metadata.market_catalog.listRollups();
        defer {
            for (rollups) |*entry| entry.deinit(self.alloc);
            self.alloc.free(rollups);
        }
        for (rollups) |rollup| {
            if (self.market_runtime.isPaused("rollup", rollup.id, rollup.version)) continue;
            const now_ts = std.time.nanoTimestamp();
            try self.market_runtime.reportStart("rollup", rollup.id, rollup.version, @intCast(now_ts));
            const report = self.processRollupDefinitionFiltered(rollup, null) catch |err| blk: {
                std.log.warn("rollup processing failed for {s}: {s}", .{ rollup.id, @errorName(err) });
                break :blk market_runtime_mod.ProcessingReport{ .success = false, .error_message = @errorName(err) };
            };
            try self.market_runtime.reportResult("rollup", rollup.id, rollup.version, @intCast(std.time.nanoTimestamp()), report);
        }

        const signals = try self.metadata.market_catalog.listSignals();
        defer {
            for (signals) |*entry| entry.deinit(self.alloc);
            self.alloc.free(signals);
        }
        for (signals) |signal| {
            if (self.market_runtime.isPaused("signal", signal.id, signal.version)) continue;
            const now_ts = std.time.nanoTimestamp();
            try self.market_runtime.reportStart("signal", signal.id, signal.version, @intCast(now_ts));
            const report = self.processSignalDefinitionFiltered(signal, null) catch |err| blk: {
                std.log.warn("signal processing failed for {s}: {s}", .{ signal.id, @errorName(err) });
                break :blk market_runtime_mod.ProcessingReport{ .success = false, .error_message = @errorName(err) };
            };
            try self.market_runtime.reportResult("signal", signal.id, signal.version, @intCast(std.time.nanoTimestamp()), report);
        }
    }

    fn processRollupDefinitionFiltered(self: *Engine, rollup: market_catalog_mod.RollupDefinition, labels_filter: ?[]const u8) !market_runtime_mod.ProcessingReport {
        return switch (rollup.transform_kind) {
            .trade_to_bar => try self.processTradeToBar(rollup, labels_filter),
            .quote_to_spread_mid => try self.processQuoteToSpreadMid(rollup, labels_filter),
            .bar_to_bar => try self.processBarToBar(rollup, labels_filter),
        };
    }

    fn makeEventId(alloc: std.mem.Allocator, metric: []const u8, labels_json: []const u8, ts: i64) ![]u8 {
        return try std.fmt.allocPrint(alloc, "{s}|{s}|{d}", .{ metric, labels_json, ts });
    }

    fn reportWithEvent(
        self: *Engine,
        rows_processed: u64,
        emissions_total: u64,
        metric: []const u8,
        labels_json: []const u8,
        ts: ?i64,
    ) !market_runtime_mod.ProcessingReport {
        if (ts) |value| {
            const event_id = try makeEventId(self.alloc, metric, labels_json, value);
            defer self.alloc.free(event_id);
            return .{
                .rows_processed = rows_processed,
                .emissions_total = emissions_total,
                .last_event_id = event_id,
                .last_output_ts = value,
            };
        }
        return .{ .rows_processed = rows_processed, .emissions_total = emissions_total };
    }

    fn processTradeToBar(self: *Engine, rollup: market_catalog_mod.RollupDefinition, labels_filter: ?[]const u8) !market_runtime_mod.ProcessingReport {
        var policy = self.latestBarPolicy(rollup.policy_id) orelse return .{};
        defer policy.deinit(self.alloc);
        const groups = try self.collectMetricSeriesGroups(rollup.source_metric, &.{ "price", "size" });
        defer self.freeMetricSeriesGroups(groups);
        if (groups.len == 0) return .{};

        const revision = try self.currentDataRevisionLabel();
        defer self.alloc.free(revision);
        const interval_text = try std.fmt.allocPrint(self.alloc, "{d}", .{policy.interval_ns});
        defer self.alloc.free(interval_text);
        const version_text = try std.fmt.allocPrint(self.alloc, "{d}", .{rollup.version});
        defer self.alloc.free(version_text);

        var rows_processed: u64 = 0;
        var emissions_total: u64 = 0;
        var last_emitted_ts: ?i64 = null;
        var last_emitted_labels: ?[]const u8 = null;
        for (groups) |group| {
            if (labels_filter) |filter| {
                if (!std.mem.eql(u8, group.labels_json, filter)) continue;
            }
            const checkpoint = self.market_runtime.getHighwater("rollup", rollup.id, rollup.version, group.labels_json) orelse std.math.minInt(i64);
            const start_ts = if (checkpoint == std.math.minInt(i64)) checkpoint else checkpoint + 1;
            const price_points = try self.querySeriesPoints(group.series_ids[0], start_ts, std.math.maxInt(i64));
            defer self.alloc.free(price_points);
            const size_points = try self.querySeriesPoints(group.series_ids[1], start_ts, std.math.maxInt(i64));
            defer self.alloc.free(size_points);
            const trades = try alignTradeSamples(self.alloc, price_points, size_points);
            defer self.alloc.free(trades);
            if (trades.len < 2) continue;
            rows_processed += @intCast(trades.len);

            const latest_bucket = bucketStart(trades[trades.len - 1].ts, policy.interval_ns);
            if (latest_bucket == std.math.minInt(i64)) continue;
            var bucket_open: ?f64 = null;
            var bucket_high: f64 = 0;
            var bucket_low: f64 = 0;
            var bucket_close: f64 = 0;
            var bucket_volume: f64 = 0;
            var bucket_notional: f64 = 0;
            var current_bucket: i64 = bucketStart(trades[0].ts, policy.interval_ns);

            const output_labels = try mergeLabelsJson(self.alloc, group.labels_json, &.{
                .{ .key = "interval", .value = interval_text },
                .{ .key = "bar_policy_id", .value = policy.id },
                .{ .key = "data_revision", .value = revision },
                .{ .key = "definition_id", .value = rollup.id },
                .{ .key = "definition_version", .value = version_text },
            });
            defer self.alloc.free(output_labels);

            var emitted_highwater: ?i64 = null;
            for (trades) |trade| {
                const trade_bucket = bucketStart(trade.ts, policy.interval_ns);
                if (trade_bucket != current_bucket) {
                    if (current_bucket < latest_bucket and bucket_open != null) {
                        try self.emitBarMetrics(rollup.target_metric, output_labels, current_bucket, bucket_open.?, bucket_high, bucket_low, bucket_close, bucket_volume, if (bucket_volume != 0) bucket_notional / bucket_volume else bucket_close, rollup.source_metric);
                        emissions_total += 6;
                        last_emitted_ts = current_bucket;
                        last_emitted_labels = group.labels_json;
                        emitted_highwater = current_bucket + policy.interval_ns - 1;
                    }
                    current_bucket = trade_bucket;
                    bucket_open = null;
                    bucket_high = 0;
                    bucket_low = 0;
                    bucket_close = 0;
                    bucket_volume = 0;
                    bucket_notional = 0;
                }
                if (bucket_open == null) {
                    bucket_open = trade.price;
                    bucket_high = trade.price;
                    bucket_low = trade.price;
                } else {
                    if (trade.price > bucket_high) bucket_high = trade.price;
                    if (trade.price < bucket_low) bucket_low = trade.price;
                }
                bucket_close = trade.price;
                bucket_volume += trade.size;
                bucket_notional += trade.price * trade.size;
            }

            if (emitted_highwater) |highwater| {
                try self.market_runtime.upsertHighwater("rollup", rollup.id, rollup.version, group.labels_json, highwater);
                try self.market_runtime.recordInstanceOutput("rollup", rollup.id, rollup.version, group.labels_json, highwater, null, null);
                try self.scheduleDerivedMetric(rollup.target_metric, output_labels);
            }
        }
        return try self.reportWithEvent(rows_processed, emissions_total, rollup.target_metric, last_emitted_labels orelse "{}", last_emitted_ts);
    }

    fn processQuoteToSpreadMid(self: *Engine, rollup: market_catalog_mod.RollupDefinition, labels_filter: ?[]const u8) !market_runtime_mod.ProcessingReport {
        const groups = try self.collectMetricSeriesGroups(rollup.source_metric, &.{ "bid", "ask", "bid_size", "ask_size" });
        defer self.freeMetricSeriesGroups(groups);
        if (groups.len == 0) return .{};

        const revision = try self.currentDataRevisionLabel();
        defer self.alloc.free(revision);
        const version_text = try std.fmt.allocPrint(self.alloc, "{d}", .{rollup.version});
        defer self.alloc.free(version_text);

        var rows_processed: u64 = 0;
        var emissions_total: u64 = 0;
        var last_emitted_ts: ?i64 = null;
        var last_emitted_labels: ?[]const u8 = null;
        for (groups) |group| {
            if (labels_filter) |filter| {
                if (!std.mem.eql(u8, group.labels_json, filter)) continue;
            }
            const checkpoint = self.market_runtime.getHighwater("rollup", rollup.id, rollup.version, group.labels_json) orelse std.math.minInt(i64);
            const start_ts = if (checkpoint == std.math.minInt(i64)) checkpoint else checkpoint + 1;
            const bid_points = try self.querySeriesPoints(group.series_ids[0], start_ts, std.math.maxInt(i64));
            defer self.alloc.free(bid_points);
            const ask_points = try self.querySeriesPoints(group.series_ids[1], start_ts, std.math.maxInt(i64));
            defer self.alloc.free(ask_points);
            const bid_size_points = try self.querySeriesPoints(group.series_ids[2], start_ts, std.math.maxInt(i64));
            defer self.alloc.free(bid_size_points);
            const ask_size_points = try self.querySeriesPoints(group.series_ids[3], start_ts, std.math.maxInt(i64));
            defer self.alloc.free(ask_size_points);
            const quotes = try alignQuoteSamples(self.alloc, bid_points, ask_points, bid_size_points, ask_size_points);
            defer self.alloc.free(quotes);
            if (quotes.len == 0) continue;
            rows_processed += @intCast(quotes.len);

            const output_labels = try mergeLabelsJson(self.alloc, group.labels_json, &.{
                .{ .key = "data_revision", .value = revision },
                .{ .key = "definition_id", .value = rollup.id },
                .{ .key = "definition_version", .value = version_text },
            });
            defer self.alloc.free(output_labels);

            for (quotes) |quote| {
                const spread_metric = try std.fmt.allocPrint(self.alloc, "{s}.spread", .{rollup.target_metric});
                try self.emitDerivedMetric(spread_metric, output_labels, quote.ts, quote.ask - quote.bid, rollup.source_metric, "spread");
                self.alloc.free(spread_metric);
                const mid_metric = try std.fmt.allocPrint(self.alloc, "{s}.mid", .{rollup.target_metric});
                try self.emitDerivedMetric(mid_metric, output_labels, quote.ts, (quote.ask + quote.bid) / 2.0, rollup.source_metric, "mid");
                self.alloc.free(mid_metric);
                emissions_total += 2;
                last_emitted_ts = quote.ts;
                last_emitted_labels = group.labels_json;
            }
            try self.market_runtime.upsertHighwater("rollup", rollup.id, rollup.version, group.labels_json, quotes[quotes.len - 1].ts);
            try self.market_runtime.recordInstanceOutput("rollup", rollup.id, rollup.version, group.labels_json, quotes[quotes.len - 1].ts, null, null);
            try self.scheduleDerivedMetric(rollup.target_metric, output_labels);
        }
        return try self.reportWithEvent(rows_processed, emissions_total, rollup.target_metric, last_emitted_labels orelse "{}", last_emitted_ts);
    }

    fn processBarToBar(self: *Engine, rollup: market_catalog_mod.RollupDefinition, labels_filter: ?[]const u8) !market_runtime_mod.ProcessingReport {
        var policy = self.latestBarPolicy(rollup.policy_id) orelse return .{};
        defer policy.deinit(self.alloc);
        const groups = try self.collectMetricSeriesGroups(rollup.source_metric, &.{ "open", "high", "low", "close", "volume", "vwap" });
        defer self.freeMetricSeriesGroups(groups);
        if (groups.len == 0) return .{};

        const revision = try self.currentDataRevisionLabel();
        defer self.alloc.free(revision);
        const interval_text = try std.fmt.allocPrint(self.alloc, "{d}", .{policy.interval_ns});
        defer self.alloc.free(interval_text);
        const version_text = try std.fmt.allocPrint(self.alloc, "{d}", .{rollup.version});
        defer self.alloc.free(version_text);

        var rows_processed: u64 = 0;
        var emissions_total: u64 = 0;
        var last_emitted_ts: ?i64 = null;
        var last_emitted_labels: ?[]const u8 = null;
        for (groups) |group| {
            if (labels_filter) |filter| {
                if (!std.mem.eql(u8, group.labels_json, filter)) continue;
            }
            const source_interval_text = try marketLabelValueFromJson(self.alloc, group.labels_json, "interval") orelse continue;
            defer self.alloc.free(source_interval_text);
            const source_interval_ns = std.fmt.parseInt(i64, source_interval_text, 10) catch continue;
            if (source_interval_ns <= 0) continue;
            if (policy.interval_ns <= source_interval_ns or @mod(policy.interval_ns, source_interval_ns) != 0) continue;
            const checkpoint = self.market_runtime.getHighwater("rollup", rollup.id, rollup.version, group.labels_json) orelse std.math.minInt(i64);
            const start_ts = if (checkpoint == std.math.minInt(i64)) checkpoint else checkpoint + 1;
            const bars = try self.queryBarSamples(group.series_ids, start_ts);
            defer self.alloc.free(bars);
            if (bars.len < 2) continue;
            rows_processed += @intCast(bars.len);
            const latest_bucket = bucketStart(bars[bars.len - 1].ts, policy.interval_ns);

            const output_labels = try mergeLabelsJson(self.alloc, group.labels_json, &.{
                .{ .key = "interval", .value = interval_text },
                .{ .key = "bar_policy_id", .value = policy.id },
                .{ .key = "data_revision", .value = revision },
                .{ .key = "definition_id", .value = rollup.id },
                .{ .key = "definition_version", .value = version_text },
            });
            defer self.alloc.free(output_labels);

            var current_bucket = bucketStart(bars[0].ts, policy.interval_ns);
            var bucket_open: ?f64 = null;
            var bucket_high: f64 = 0;
            var bucket_low: f64 = 0;
            var bucket_close: f64 = 0;
            var bucket_volume: f64 = 0;
            var bucket_notional: f64 = 0;
            var emitted_highwater: ?i64 = null;
            for (bars) |bar| {
                const next_bucket = bucketStart(bar.ts, policy.interval_ns);
                if (next_bucket != current_bucket) {
                    if (current_bucket < latest_bucket and bucket_open != null) {
                        try self.emitBarMetrics(rollup.target_metric, output_labels, current_bucket, bucket_open.?, bucket_high, bucket_low, bucket_close, bucket_volume, if (bucket_volume != 0) bucket_notional / bucket_volume else bucket_close, rollup.source_metric);
                        emissions_total += 6;
                        last_emitted_ts = current_bucket;
                        last_emitted_labels = group.labels_json;
                        emitted_highwater = current_bucket + policy.interval_ns - 1;
                    }
                    current_bucket = next_bucket;
                    bucket_open = null;
                    bucket_high = 0;
                    bucket_low = 0;
                    bucket_close = 0;
                    bucket_volume = 0;
                    bucket_notional = 0;
                }
                if (bucket_open == null) {
                    bucket_open = bar.open;
                    bucket_high = bar.high;
                    bucket_low = bar.low;
                } else {
                    if (bar.high > bucket_high) bucket_high = bar.high;
                    if (bar.low < bucket_low) bucket_low = bar.low;
                }
                bucket_close = bar.close;
                bucket_volume += bar.volume;
                bucket_notional += bar.vwap * bar.volume;
            }
            if (emitted_highwater) |highwater| {
                try self.market_runtime.upsertHighwater("rollup", rollup.id, rollup.version, group.labels_json, highwater);
                try self.market_runtime.recordInstanceOutput("rollup", rollup.id, rollup.version, group.labels_json, highwater, null, null);
                try self.scheduleDerivedMetric(rollup.target_metric, output_labels);
            }
        }
        return try self.reportWithEvent(rows_processed, emissions_total, rollup.target_metric, last_emitted_labels orelse "{}", last_emitted_ts);
    }

    fn processSignalDefinitionFiltered(self: *Engine, signal: market_catalog_mod.SignalDefinition, labels_filter: ?[]const u8) !market_runtime_mod.ProcessingReport {
        const signal_column = try signalColumnConfig(self.alloc, signal);
        defer self.alloc.free(signal_column.primary);
        if (signal_column.secondary) |secondary| {
            defer self.alloc.free(secondary);
        }

        const columns = if (signal_column.secondary != null)
            try self.alloc.dupe([]const u8, &.{ signal_column.primary, signal_column.secondary.? })
        else
            try self.alloc.dupe([]const u8, &.{signal_column.primary});
        defer self.alloc.free(columns);

        const groups = try self.collectMetricSeriesGroups(signal.input_metric, columns);
        defer self.freeMetricSeriesGroups(groups);
        if (groups.len == 0) return .{};

        const revision = try self.currentDataRevisionLabel();
        defer self.alloc.free(revision);
        const version_text = try std.fmt.allocPrint(self.alloc, "{d}", .{signal.version});
        defer self.alloc.free(version_text);

        var rows_processed: u64 = 0;
        var emissions_total: u64 = 0;
        var last_emitted_ts: ?i64 = null;
        var last_emitted_labels: ?[]const u8 = null;
        for (groups) |group| {
            if (labels_filter) |filter| {
                if (!std.mem.eql(u8, group.labels_json, filter)) continue;
            }
            const checkpoint = self.market_runtime.getHighwater("signal", signal.id, signal.version, group.labels_json) orelse std.math.minInt(i64);
            const primary_points = try self.querySeriesPoints(group.series_ids[0], std.math.minInt(i64), std.math.maxInt(i64));
            defer self.alloc.free(primary_points);
            rows_processed += @intCast(primary_points.len);
            const secondary_points = if (group.series_ids.len > 1)
                try self.querySeriesPoints(group.series_ids[1], std.math.minInt(i64), std.math.maxInt(i64))
            else
                try self.alloc.alloc(types.Point, 0);
            defer self.alloc.free(secondary_points);

            const output_labels = try mergeLabelsJson(self.alloc, group.labels_json, &.{
                .{ .key = "data_revision", .value = revision },
                .{ .key = "definition_id", .value = signal.id },
                .{ .key = "definition_version", .value = version_text },
            });
            defer self.alloc.free(output_labels);

            const output_metric = try std.fmt.allocPrint(self.alloc, "_signal.{s}", .{signal.id});
            defer self.alloc.free(output_metric);
            const signal_report = try self.emitSignalPoints(output_metric, output_labels, group.labels_json, revision, signal, primary_points, secondary_points, checkpoint);
            emissions_total += signal_report.emissions_total;
            if (signal_report.last_event_id != null) {
                last_emitted_ts = signal_report.last_output_ts orelse last_emitted_ts;
                last_emitted_labels = group.labels_json;
            }
            if (primary_points.len != 0) {
                try self.market_runtime.upsertHighwater("signal", signal.id, signal.version, group.labels_json, primary_points[primary_points.len - 1].ts);
                if (signal_report.last_output_ts) |output_ts| {
                    try self.market_runtime.recordInstanceOutput("signal", signal.id, signal.version, group.labels_json, output_ts, self.market_runtime.latestEventSequence("signal", signal.id, signal.version), null);
                } else {
                    try self.market_runtime.setPending("signal", signal.id, signal.version, group.labels_json, false);
                }
            }
        }
        return try self.reportWithEvent(rows_processed, emissions_total, signal.id, last_emitted_labels orelse "{}", last_emitted_ts);
    }

    fn emitSignalPoints(
        self: *Engine,
        output_metric: []const u8,
        output_labels: []const u8,
        raw_labels_json: []const u8,
        data_revision: []const u8,
        signal: market_catalog_mod.SignalDefinition,
        primary_points: []const types.Point,
        secondary_points: []const types.Point,
        checkpoint: i64,
    ) !market_runtime_mod.ProcessingReport {
        if (primary_points.len == 0) return .{};
        var params = try std.json.parseFromSlice(std.json.Value, self.alloc, signal.params_json, .{});
        defer params.deinit();
        const params_obj = if (params.value == .object) params.value.object else return .{};

        const primary_values = try pointValues(self.alloc, primary_points);
        defer self.alloc.free(primary_values);
        const secondary_values = try pointValues(self.alloc, secondary_points);
        defer self.alloc.free(secondary_values);

        var emissions_total: u64 = 0;
        var last_event_id: ?[]u8 = null;
        var last_output_ts: ?i64 = null;
        defer if (last_event_id) |value| self.alloc.free(value);

        switch (signal.expression_kind) {
            .ema => {
                const period = jsonParamInt(params_obj, "period", 12);
                const alpha = 2.0 / (@as(f64, @floatFromInt(period)) + 1.0);
                var ema_value = primary_values[0];
                for (primary_points, primary_values, 0..) |point, value, idx| {
                    if (idx != 0) ema_value = alpha * value + (1.0 - alpha) * ema_value;
                    if (point.ts <= checkpoint) continue;
                    try self.emitDerivedMetric(output_metric, output_labels, point.ts, ema_value, signal.input_metric, signal.expression_kind.text());
                    emissions_total += 1;
                    if (last_event_id) |event_id| self.alloc.free(event_id);
                    last_event_id = try self.recordSignalEmission(signal, raw_labels_json, data_revision, point.ts, ema_value);
                    last_output_ts = point.ts;
                }
            },
            .moving_avg => {
                const period = jsonParamInt(params_obj, "period", 20);
                var sum: f64 = 0;
                var start_idx: usize = 0;
                for (primary_points, primary_values, 0..) |point, value, idx| {
                    sum += value;
                    if (idx >= period) {
                        sum -= primary_values[start_idx];
                        start_idx += 1;
                    }
                    if (idx + 1 < period or point.ts <= checkpoint) continue;
                    const avg_value = sum / @as(f64, @floatFromInt(period));
                    try self.emitDerivedMetric(output_metric, output_labels, point.ts, avg_value, signal.input_metric, signal.expression_kind.text());
                    emissions_total += 1;
                    if (last_event_id) |event_id| self.alloc.free(event_id);
                    last_event_id = try self.recordSignalEmission(signal, raw_labels_json, data_revision, point.ts, avg_value);
                    last_output_ts = point.ts;
                }
            },
            .threshold_cross => {
                const level = jsonParamFloat(params_obj, "level", 0);
                if (primary_values.len < 2) return .{};
                var prev = primary_values[0];
                for (primary_points[1..], primary_values[1..]) |point, value| {
                    const crossed = (prev <= level and value > level) or (prev >= level and value < level);
                    prev = value;
                    if (!crossed or point.ts <= checkpoint) continue;
                    try self.emitDerivedMetric(output_metric, output_labels, point.ts, 1.0, signal.input_metric, signal.expression_kind.text());
                    emissions_total += 1;
                    if (last_event_id) |event_id| self.alloc.free(event_id);
                    last_event_id = try self.recordSignalEmission(signal, raw_labels_json, data_revision, point.ts, 1.0);
                    last_output_ts = point.ts;
                }
            },
            .spread_gt => {
                const threshold = jsonParamFloat(params_obj, "threshold", 0);
                for (primary_points, primary_values) |point, value| {
                    if (value <= threshold or point.ts <= checkpoint) continue;
                    try self.emitDerivedMetric(output_metric, output_labels, point.ts, 1.0, signal.input_metric, signal.expression_kind.text());
                    emissions_total += 1;
                    if (last_event_id) |event_id| self.alloc.free(event_id);
                    last_event_id = try self.recordSignalEmission(signal, raw_labels_json, data_revision, point.ts, 1.0);
                    last_output_ts = point.ts;
                }
            },
            .vwap_deviation => {
                if (secondary_values.len == 0) return .{};
                const threshold = jsonParamFloat(params_obj, "threshold", 0.01);
                const paired = @min(primary_values.len, secondary_values.len);
                for (0..paired) |idx| {
                    const point = primary_points[idx];
                    const price = primary_values[idx];
                    const vwap = secondary_values[idx];
                    if (point.ts <= checkpoint or vwap == 0) continue;
                    if (@abs(price - vwap) / @abs(vwap) <= threshold) continue;
                    try self.emitDerivedMetric(output_metric, output_labels, point.ts, 1.0, signal.input_metric, signal.expression_kind.text());
                    emissions_total += 1;
                    if (last_event_id) |event_id| self.alloc.free(event_id);
                    last_event_id = try self.recordSignalEmission(signal, raw_labels_json, data_revision, point.ts, 1.0);
                    last_output_ts = point.ts;
                }
            },
            .crossover, .crossunder => {
                const fast_period = jsonParamInt(params_obj, "fast_period", 12);
                const slow_period = jsonParamInt(params_obj, "slow_period", 26);
                if (primary_values.len < slow_period or slow_period <= fast_period) return .{};
                var prev_fast: ?f64 = null;
                var prev_slow: ?f64 = null;
                for (primary_points, 0..) |point, idx| {
                    if (idx + 1 < slow_period) continue;
                    const fast = avgWindow(primary_values, idx + 1 - fast_period, fast_period);
                    const slow = avgWindow(primary_values, idx + 1 - slow_period, slow_period);
                    if (prev_fast != null and prev_slow != null and point.ts > checkpoint) {
                        const crossed = if (signal.expression_kind == .crossover)
                            prev_fast.? <= prev_slow.? and fast > slow
                        else
                            prev_fast.? >= prev_slow.? and fast < slow;
                        if (crossed) {
                            try self.emitDerivedMetric(output_metric, output_labels, point.ts, 1.0, signal.input_metric, signal.expression_kind.text());
                            emissions_total += 1;
                            if (last_event_id) |event_id| self.alloc.free(event_id);
                            last_event_id = try self.recordSignalEmission(signal, raw_labels_json, data_revision, point.ts, 1.0);
                            last_output_ts = point.ts;
                        }
                    }
                    prev_fast = fast;
                    prev_slow = slow;
                }
            },
        }
        return .{
            .rows_processed = @intCast(primary_points.len),
            .emissions_total = emissions_total,
            .last_event_id = last_event_id,
            .last_output_ts = last_output_ts,
        };
    }

    fn recordSignalEmission(
        self: *Engine,
        signal: market_catalog_mod.SignalDefinition,
        raw_labels_json: []const u8,
        data_revision: []const u8,
        ts_ns: i64,
        value: f64,
    ) ![]u8 {
        var event = try self.signal_events.append(signal.id, signal.version, data_revision, raw_labels_json, ts_ns, value);
        defer event.deinit(self.alloc);
        self.signal_event_mu.lock();
        self.signal_event_epoch += 1;
        self.signal_event_mu.unlock();
        self.signal_event_cv.broadcast();
        try self.market_runtime.recordInstanceOutput("signal", signal.id, signal.version, raw_labels_json, ts_ns, event.sequence, null);
        return try self.alloc.dupe(u8, event.event_id);
    }

    fn emitBarMetrics(
        self: *Engine,
        family_metric: []const u8,
        labels_json: []const u8,
        ts: i64,
        open: f64,
        high: f64,
        low: f64,
        close: f64,
        volume: f64,
        vwap: f64,
        source_metric: []const u8,
    ) !void {
        const open_metric = try std.fmt.allocPrint(self.alloc, "{s}.open", .{family_metric});
        defer self.alloc.free(open_metric);
        try self.emitDerivedMetric(open_metric, labels_json, ts, open, source_metric, "open");
        const high_metric = try std.fmt.allocPrint(self.alloc, "{s}.high", .{family_metric});
        defer self.alloc.free(high_metric);
        try self.emitDerivedMetric(high_metric, labels_json, ts, high, source_metric, "high");
        const low_metric = try std.fmt.allocPrint(self.alloc, "{s}.low", .{family_metric});
        defer self.alloc.free(low_metric);
        try self.emitDerivedMetric(low_metric, labels_json, ts, low, source_metric, "low");
        const close_metric = try std.fmt.allocPrint(self.alloc, "{s}.close", .{family_metric});
        defer self.alloc.free(close_metric);
        try self.emitDerivedMetric(close_metric, labels_json, ts, close, source_metric, "close");
        const volume_metric = try std.fmt.allocPrint(self.alloc, "{s}.volume", .{family_metric});
        defer self.alloc.free(volume_metric);
        try self.emitDerivedMetric(volume_metric, labels_json, ts, volume, source_metric, "volume");
        const vwap_metric = try std.fmt.allocPrint(self.alloc, "{s}.vwap", .{family_metric});
        defer self.alloc.free(vwap_metric);
        try self.emitDerivedMetric(vwap_metric, labels_json, ts, vwap, source_metric, "vwap");
    }

    fn emitDerivedMetric(
        self: *Engine,
        metric: []const u8,
        labels_json: []const u8,
        ts: i64,
        value: f64,
        source_metric: []const u8,
        source_field: []const u8,
    ) !void {
        _ = try self.ingestExactMetric(metric, labels_json, ts, value, .{
            .metric = metric,
            .kind = .gauge,
            .source_metric = source_metric,
            .source_field = source_field,
        });
    }

    fn querySeriesPoints(self: *Engine, series_id: types.SeriesId, start_ts: i64, end_ts: i64) ![]types.Point {
        var points = std.array_list.Managed(types.Point).init(self.alloc);
        defer points.deinit();
        try self.queryRange(series_id, start_ts, end_ts, &points);
        return try self.alloc.dupe(types.Point, points.items);
    }

    fn queryBarSamples(self: *Engine, series_ids: []types.SeriesId, start_ts: i64) ![]BarSample {
        var columns = try self.alloc.alloc([]types.Point, series_ids.len);
        defer self.alloc.free(columns);
        for (series_ids, 0..) |series_id, idx| {
            columns[idx] = try self.querySeriesPoints(series_id, start_ts, std.math.maxInt(i64));
        }
        defer {
            for (columns) |points| self.alloc.free(points);
        }
        return try alignBarSamples(self.alloc, columns);
    }

    fn collectMetricSeriesGroups(self: *Engine, family_metric: []const u8, columns: []const []const u8) ![]MetricSeriesGroup {
        var groups = std.array_list.Managed(MetricSeriesGroup).init(self.alloc);
        errdefer {
            for (groups.items) |*group| group.deinit(self.alloc);
            groups.deinit();
        }

        self.metadata.series_catalog.mutex.lock();
        defer self.metadata.series_catalog.mutex.unlock();
        for (self.metadata.series_catalog.entries.items) |entry| {
            var column_index: ?usize = null;
            for (columns, 0..) |column, idx| {
                if (entry.series.len == family_metric.len + 1 + column.len and
                    std.mem.startsWith(u8, entry.series, family_metric) and
                    entry.series[family_metric.len] == '.' and
                    std.mem.eql(u8, entry.series[family_metric.len + 1 ..], column))
                {
                    column_index = idx;
                    break;
                }
            }
            if (column_index == null) continue;

            var group_index: ?usize = null;
            for (groups.items, 0..) |group, idx| {
                if (std.mem.eql(u8, group.labels_json, entry.canonical_tags)) {
                    group_index = idx;
                    break;
                }
            }
            if (group_index == null) {
                const series_slots = try self.alloc.alloc(types.SeriesId, columns.len);
                @memset(series_slots, 0);
                try groups.append(.{
                    .labels_json = try self.alloc.dupe(u8, entry.canonical_tags),
                    .series_ids = series_slots,
                });
                group_index = groups.items.len - 1;
            }
            groups.items[group_index.?].series_ids[column_index.?] = entry.series_id;
        }

        var filtered = std.array_list.Managed(MetricSeriesGroup).init(self.alloc);
        errdefer {
            for (filtered.items) |*group| group.deinit(self.alloc);
            filtered.deinit();
        }
        for (groups.items) |group| {
            var complete = true;
            for (group.series_ids) |series_id| {
                if (series_id == 0) {
                    complete = false;
                    break;
                }
            }
            if (complete) {
                try filtered.append(.{
                    .labels_json = try self.alloc.dupe(u8, group.labels_json),
                    .series_ids = try self.alloc.dupe(types.SeriesId, group.series_ids),
                });
            }
        }
        for (groups.items) |*group| group.deinit(self.alloc);
        groups.deinit();
        return try filtered.toOwnedSlice();
    }

    fn freeMetricSeriesGroups(self: *Engine, groups: []MetricSeriesGroup) void {
        for (groups) |*group| group.deinit(self.alloc);
        self.alloc.free(groups);
    }

    fn currentDataRevisionLabel(self: *Engine) ![]u8 {
        if (self.cas) |*cas| {
            if (try cas.refs.readHead(cas_mod.main_ref)) |head| {
                const hex = head.toHex();
                return try self.alloc.dupe(u8, hex[0..]);
            }
        }
        return try self.alloc.dupe(u8, "legacy-live");
    }

    fn validateBarPolicyInput(self: *Engine, input: market_catalog_mod.BarPolicyInput) !void {
        if (input.interval_ns <= 0) return error.InvalidBarPolicyInterval;
        var source_schema = self.marketSchema(input.source_metric) orelse return error.InvalidBarPolicySource;
        defer source_schema.deinit(self.alloc);
        if (!std.mem.eql(u8, input.source_metric, "market.trade") and !std.mem.eql(u8, input.source_metric, "market.bar")) {
            return error.InvalidBarPolicySource;
        }
        if (!stringInSlice(input.session_rule, &.{ "regular_hours", "all_sessions" })) return error.InvalidSessionRule;
        if (!stringInSlice(input.no_trade_rule, &.{ "skip_empty", "carry_forward_none" })) return error.InvalidNoTradeRule;
        if (!stringInSlice(input.halt_rule, &.{ "skip_halts", "treat_as_gap" })) return error.InvalidHaltRule;
        if (!stringInSlice(input.correction_policy, &.{ "append_only", "ignore_corrections" })) return error.InvalidCorrectionPolicy;
    }

    fn validateRollupInput(self: *Engine, input: market_catalog_mod.RollupDefinitionInput) !void {
        var policy = self.latestBarPolicy(input.policy_id) orelse return error.InvalidRollupPolicy;
        defer policy.deinit(self.alloc);
        switch (input.transform_kind) {
            .trade_to_bar => {
                if (!std.mem.eql(u8, input.source_metric, "market.trade")) return error.InvalidRollupSource;
                if (!std.mem.eql(u8, input.target_metric, "market.bar")) return error.InvalidRollupTarget;
                if (!std.mem.eql(u8, policy.source_metric, "market.trade")) return error.InvalidRollupPolicy;
            },
            .quote_to_spread_mid => {
                if (!std.mem.eql(u8, input.source_metric, "market.quote")) return error.InvalidRollupSource;
            },
            .bar_to_bar => {
                if (!std.mem.eql(u8, input.source_metric, "market.bar")) return error.InvalidRollupSource;
                if (!std.mem.eql(u8, input.target_metric, "market.bar")) return error.InvalidRollupTarget;
                if (!std.mem.eql(u8, policy.source_metric, "market.bar")) return error.InvalidRollupPolicy;
            },
        }
    }

    fn validateSignalInput(self: *Engine, input: market_catalog_mod.SignalDefinitionInput) !void {
        _ = self.marketSchema(input.input_metric) orelse {
            if (!std.mem.startsWith(u8, input.input_metric, "market.bar") and
                !std.mem.startsWith(u8, input.input_metric, "market.quote") and
                !std.mem.startsWith(u8, input.input_metric, "market.trade"))
                return error.InvalidSignalInputMetric;
            return;
        };
        if (input.policy_id) |policy_id| {
            _ = self.latestBarPolicy(policy_id) orelse return error.InvalidSignalPolicy;
        }
    }

    fn stringInSlice(value: []const u8, allowed: []const []const u8) bool {
        for (allowed) |candidate| {
            if (std.mem.eql(u8, value, candidate)) return true;
        }
        return false;
    }

    fn cachedFlushSelectorMetadata(
        self: *Engine,
        cache: *std.AutoHashMap(types.SeriesId, ?segment_mod.SelectorMetadata),
        sid: types.SeriesId,
    ) !?segment_mod.SelectorMetadataView {
        const gop = try cache.getOrPut(sid);
        if (!gop.found_existing) {
            const resolution = self.metadata.series_catalog.resolveBySeriesId(sid);
            gop.value_ptr.* = switch (resolution.status) {
                .resolved, .exact_match => .{
                    .series = try self.alloc.dupe(u8, resolution.series.?),
                    .canonical_tags = try self.alloc.dupe(u8, resolution.canonical_tags.?),
                },
                .not_found, .ambiguous => null,
            };
        }
        if (gop.value_ptr.*) |*selector| {
            return .{
                .series = selector.series,
                .canonical_tags = selector.canonical_tags,
            };
        }
        return null;
    }

    fn flushMemtable(self: *Engine) !bool {
        const start_ns = std.time.nanoTimestamp();
        var points_written: usize = 0;
        var segments_written: usize = 0;
        var manifest_entries = std.array_list.Managed(manifest_mod.AddInput).init(self.alloc);
        defer {
            for (manifest_entries.items) |entry| self.alloc.free(@constCast(entry.path));
            manifest_entries.deinit();
        }
        try manifest_entries.ensureTotalCapacity(self.mem.series.count());

        var selector_cache = std.AutoHashMap(types.SeriesId, ?segment_mod.SelectorMetadata).init(self.alloc);
        defer {
            var selector_it = selector_cache.valueIterator();
            while (selector_it.next()) |entry| {
                if (entry.*) |*selector| selector.deinit(self.alloc);
            }
            selector_cache.deinit();
        }
        try selector_cache.ensureUnusedCapacity(@intCast(self.mem.series.count()));

        // write per-series per-hour segments, batch manifest updates, then clear memtable
        var it = self.mem.series.iterator();
        while (it.next()) |entry| {
            const sid = entry.key_ptr.*;
            const buffer = entry.value_ptr;
            if (buffer.points.items.len == 0) continue;
            if (!buffer.sorted and buffer.points.items.len > 1) {
                std.sort.block(types.Point, buffer.points.items, {}, struct {
                    fn lessThan(_: void, a: types.Point, b: types.Point) bool {
                        return a.ts < b.ts;
                    }
                }.lessThan);
            }
            const selector_metadata = try self.cachedFlushSelectorMetadata(&selector_cache, sid);
            const first_hour = self.hourBucketForSeries(sid, buffer.points.items[0].ts);
            const last_hour = self.hourBucketForSeries(sid, buffer.points.items[buffer.points.items.len - 1].ts);

            if (buffer.points.items.len == 1 or first_hour == last_hour) {
                const seg_path = try segment_mod.writeSegmentWithMetadata(self.alloc, self.data_dir, sid, first_hour, buffer.points.items, selector_metadata);
                try manifest_entries.append(.{
                    .series_id = sid,
                    .hour_bucket = first_hour,
                    .start_ts = buffer.points.items[0].ts,
                    .end_ts = buffer.points.items[buffer.points.items.len - 1].ts,
                    .count = @intCast(buffer.points.items.len),
                    .path = seg_path,
                });
                points_written += buffer.points.items.len;
                segments_written += 1;
            } else {
                var start_idx: usize = 0;
                while (start_idx < buffer.points.items.len) {
                    const hour = self.hourBucketForSeries(sid, buffer.points.items[start_idx].ts);
                    var end_idx = start_idx + 1;
                    while (end_idx < buffer.points.items.len and self.hourBucketForSeries(sid, buffer.points.items[end_idx].ts) == hour) : (end_idx += 1) {}
                    const slice = buffer.points.items[start_idx..end_idx];
                    const seg_path = try segment_mod.writeSegmentWithMetadata(self.alloc, self.data_dir, sid, hour, slice, selector_metadata);
                    try manifest_entries.append(.{
                        .series_id = sid,
                        .hour_bucket = hour,
                        .start_ts = slice[0].ts,
                        .end_ts = slice[slice.len - 1].ts,
                        .count = @intCast(slice.len),
                        .path = seg_path,
                    });
                    points_written += slice.len;
                    segments_written += 1;
                    start_idx = end_idx;
                }
            }
            buffer.clearRetainingCapacity();
        }
        try self.metadata.manifest.addBatch(self.data_dir, manifest_entries.items);
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
        if (self.tag_index_dirty.swap(false, .monotonic)) {
            const tag_save_start_ns = std.time.nanoTimestamp();
            self.metadata.tags.save(self.data_dir) catch |err| {
                self.tag_index_dirty.store(true, .monotonic);
                std.log.warn("tag index save failed: {s}", .{@errorName(err)});
                return segments_written > 0;
            };
            const tag_save_elapsed_ns: u64 = @intCast(std.time.nanoTimestamp() - tag_save_start_ns);
            _ = self.metrics.tag_index_save_total.fetchAdd(1, .monotonic);
            _ = self.metrics.tag_index_save_ns_total.fetchAdd(tag_save_elapsed_ns, .monotonic);
        } else {
            _ = self.metrics.tag_index_save_skipped_total.fetchAdd(1, .monotonic);
        }
        return segments_written > 0;
    }

    fn quarantineFailedIngest(self: *Engine, item: ResolvedIngestPoint, stage: []const u8, err_name: []const u8) void {
        var payload = std.array_list.Managed(u8).init(self.alloc);
        defer payload.deinit();

        var writer = payload.writer();
        var tmp: [256]u8 = undefined;
        var adapter = writer.adaptToNewApi(&tmp);
        var iface = &adapter.new_interface;
        var jw = std.json.Stringify{ .writer = iface };

        const resolution = self.metadata.series_catalog.resolveBySeriesId(item.series_id);
        const series = resolution.series;
        const canonical_tags = resolution.canonical_tags orelse "{}";

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

    fn hourBucketForSeries(self: *Engine, sid: types.SeriesId, ts: i64) i64 {
        const resolution = self.metadata.series_catalog.resolveBySeriesId(sid);
        const divisor: i64 = if (resolution.series) |series|
            if (std.mem.startsWith(u8, series, "market.") or std.mem.startsWith(u8, series, "_signal."))
                3600 * std.time.ns_per_s
            else
                legacyHourBucketDivisor(ts)
        else
            legacyHourBucketDivisor(ts);
        return (@divTrunc(ts, divisor)) * divisor;
    }

    fn legacyHourBucketDivisor(ts: i64) i64 {
        const abs_ts: u64 = @intCast(if (ts < 0) -ts else ts);
        if (abs_ts >= 1_000_000_000_000_000) return 3600 * std.time.ns_per_s;
        if (abs_ts >= 1_000_000_000_000) return 3600 * std.time.us_per_s;
        if (abs_ts >= 1_000_000_000) return 3600 * std.time.ms_per_s;
        return 3600;
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

    pub fn declareExactSeries(self: *Engine, input: ExactSeriesDeclarationInput) !ExactSeriesDeclarationResult {
        const canonical_tags = try series_catalog_mod.canonicalizeTagsJson(self.alloc, input.tags_json);
        errdefer self.alloc.free(canonical_tags);
        const series_id = try self.declareExactSeriesCanonical(input.name, canonical_tags, input.descriptor);
        return .{
            .series_id = series_id,
            .canonical_tags = canonical_tags,
        };
    }

    pub fn registerMetricDescriptor(self: *Engine, input: metric_catalog_mod.DescriptorInput) !metric_catalog_mod.RegisterResult {
        return try self.metadata.metric_catalog.register(input);
    }

    pub fn registerMarketSchema(self: *Engine, input: market_catalog_mod.MarketSchemaInput) !market_catalog_mod.MarketSchema {
        const stored = try self.metadata.market_catalog.registerSchema(input);
        if (self.cas != null) try self.syncCasSnapshot("market-schema");
        return stored;
    }

    pub fn registerBarPolicy(self: *Engine, input: market_catalog_mod.BarPolicyInput) !market_catalog_mod.BarPolicy {
        try self.validateBarPolicyInput(input);
        const stored = try self.metadata.market_catalog.registerBarPolicy(input);
        if (self.cas != null) try self.syncCasSnapshot("bar-policy");
        return stored;
    }

    pub fn registerRollup(self: *Engine, input: market_catalog_mod.RollupDefinitionInput) !market_catalog_mod.RollupDefinition {
        try self.validateRollupInput(input);
        const stored = try self.metadata.market_catalog.registerRollup(input);
        try self.market_runtime.setStatus("rollup", stored.id, stored.version, .active);
        if (self.cas != null) try self.syncCasSnapshot("rollup-definition");
        self.scheduleDerivedRefresh();
        return stored;
    }

    pub fn registerSignal(self: *Engine, input: market_catalog_mod.SignalDefinitionInput) !market_catalog_mod.SignalDefinition {
        try self.validateSignalInput(input);
        const stored = try self.metadata.market_catalog.registerSignal(input);
        try self.market_runtime.setStatus("signal", stored.id, stored.version, .active);
        if (self.cas != null) try self.syncCasSnapshot("signal-definition");
        self.scheduleDerivedRefresh();
        return stored;
    }

    pub fn marketSchema(self: *Engine, metric: []const u8) ?market_catalog_mod.MarketSchema {
        return self.metadata.market_catalog.getSchema(metric);
    }

    pub fn listMarketSchemas(self: *Engine) ![]market_catalog_mod.MarketSchema {
        return try self.metadata.market_catalog.listSchemas();
    }

    pub fn listBarPolicies(self: *Engine) ![]market_catalog_mod.BarPolicy {
        return try self.metadata.market_catalog.listBarPolicies();
    }

    pub fn listRollups(self: *Engine) ![]market_catalog_mod.RollupDefinition {
        return try self.metadata.market_catalog.listRollups();
    }

    pub fn listSignals(self: *Engine) ![]market_catalog_mod.SignalDefinition {
        return try self.metadata.market_catalog.listSignals();
    }

    pub fn latestBarPolicy(self: *Engine, id: []const u8) ?market_catalog_mod.BarPolicy {
        return self.metadata.market_catalog.latestBarPolicyById(id);
    }

    pub fn rollupRuntime(self: *Engine, id: []const u8, version: u32) ?market_runtime_mod.DefinitionRuntime {
        return self.market_runtime.runtimeFor("rollup", id, version);
    }

    pub fn signalRuntime(self: *Engine, id: []const u8, version: u32) ?market_runtime_mod.DefinitionRuntime {
        return self.market_runtime.runtimeFor("signal", id, version);
    }

    pub fn latestRollup(self: *Engine, id: []const u8) !?market_catalog_mod.RollupDefinition {
        const rollups = try self.metadata.market_catalog.listRollups();
        defer {
            for (rollups) |*entry| entry.deinit(self.alloc);
            self.alloc.free(rollups);
        }
        var best: ?market_catalog_mod.RollupDefinition = null;
        errdefer if (best) |*entry| entry.deinit(self.alloc);
        for (rollups) |entry| {
            if (!std.mem.eql(u8, entry.id, id)) continue;
            if (best == null or entry.version > best.?.version) {
                if (best) |*existing| existing.deinit(self.alloc);
                best = try entry.clone(self.alloc);
            }
        }
        return best;
    }

    pub fn latestSignal(self: *Engine, id: []const u8) !?market_catalog_mod.SignalDefinition {
        const signals = try self.metadata.market_catalog.listSignals();
        defer {
            for (signals) |*entry| entry.deinit(self.alloc);
            self.alloc.free(signals);
        }
        var best: ?market_catalog_mod.SignalDefinition = null;
        errdefer if (best) |*entry| entry.deinit(self.alloc);
        for (signals) |entry| {
            if (!std.mem.eql(u8, entry.id, id)) continue;
            if (best == null or entry.version > best.?.version) {
                if (best) |*existing| existing.deinit(self.alloc);
                best = try entry.clone(self.alloc);
            }
        }
        return best;
    }

    pub fn pendingStatsForDefinition(self: *Engine, namespace: []const u8, definition_id: []const u8, definition_version: u32) PendingStats {
        self.derived_mu.lock();
        defer self.derived_mu.unlock();
        var pending_instances: usize = 0;
        var max_lag_ns: ?i64 = null;
        const now_ts: i64 = @intCast(std.time.nanoTimestamp());
        for (self.derived_dirty.items) |entry| {
            if (!std.mem.eql(u8, entry.namespace, namespace)) continue;
            if (!std.mem.eql(u8, entry.definition_id, definition_id)) continue;
            if (entry.definition_version != definition_version) continue;
            pending_instances += 1;
            const lag: i64 = now_ts - entry.queued_at_ns;
            if (max_lag_ns == null or lag > max_lag_ns.?) max_lag_ns = lag;
        }
        return .{ .pending_instances = pending_instances, .max_lag_ns = max_lag_ns };
    }

    pub fn latestCheckpointTs(self: *Engine, namespace: []const u8, definition_id: []const u8, definition_version: u32) ?i64 {
        return self.market_runtime.latestCheckpointTs(namespace, definition_id, definition_version);
    }

    pub fn latestEventSequence(self: *Engine, namespace: []const u8, definition_id: []const u8, definition_version: u32) ?u64 {
        return self.market_runtime.latestEventSequence(namespace, definition_id, definition_version);
    }

    pub fn listSignalEvents(
        self: *Engine,
        definition_id: []const u8,
        definition_version: ?u32,
        after_sequence: ?u64,
        start_ts_ns: ?i64,
        end_ts_ns: ?i64,
        limit: usize,
    ) ![]signal_events_mod.Event {
        return try self.signal_events.listAfter(definition_id, definition_version, after_sequence, start_ts_ns, end_ts_ns, limit);
    }

    pub fn currentSignalEventEpoch(self: *Engine) u64 {
        self.signal_event_mu.lock();
        defer self.signal_event_mu.unlock();
        return self.signal_event_epoch;
    }

    pub fn waitForSignalEvents(self: *Engine, previous_epoch: u64, timeout_ns: u64) u64 {
        self.signal_event_mu.lock();
        defer self.signal_event_mu.unlock();
        if (self.signal_event_epoch == previous_epoch and !self.stop_flag) {
            self.signal_event_cv.timedWait(&self.signal_event_mu, timeout_ns) catch {};
        }
        return self.signal_event_epoch;
    }

    pub fn pauseRollup(self: *Engine, id: []const u8) !void {
        const rollups = try self.metadata.market_catalog.listRollups();
        defer {
            for (rollups) |*entry| entry.deinit(self.alloc);
            self.alloc.free(rollups);
        }
        for (rollups) |rollup| {
            if (std.mem.eql(u8, rollup.id, id)) try self.market_runtime.setStatus("rollup", rollup.id, rollup.version, .paused);
        }
    }

    pub fn resumeRollup(self: *Engine, id: []const u8) !void {
        const rollups = try self.metadata.market_catalog.listRollups();
        defer {
            for (rollups) |*entry| entry.deinit(self.alloc);
            self.alloc.free(rollups);
        }
        for (rollups) |rollup| {
            if (std.mem.eql(u8, rollup.id, id)) try self.market_runtime.setStatus("rollup", rollup.id, rollup.version, .active);
        }
        self.scheduleDerivedRefresh();
    }

    pub fn pauseSignal(self: *Engine, id: []const u8) !void {
        const signals = try self.metadata.market_catalog.listSignals();
        defer {
            for (signals) |*entry| entry.deinit(self.alloc);
            self.alloc.free(signals);
        }
        for (signals) |signal| {
            if (std.mem.eql(u8, signal.id, id)) try self.market_runtime.setStatus("signal", signal.id, signal.version, .paused);
        }
    }

    pub fn resumeSignal(self: *Engine, id: []const u8) !void {
        const signals = try self.metadata.market_catalog.listSignals();
        defer {
            for (signals) |*entry| entry.deinit(self.alloc);
            self.alloc.free(signals);
        }
        for (signals) |signal| {
            if (std.mem.eql(u8, signal.id, id)) try self.market_runtime.setStatus("signal", signal.id, signal.version, .active);
        }
        self.scheduleDerivedRefresh();
    }

    pub fn deleteRollup(self: *Engine, id: []const u8) !bool {
        const deleted = try self.metadata.market_catalog.deleteRollup(id);
        if (!deleted) return false;
        try self.market_runtime.deleteDefinition("rollup", id, null);
        if (self.cas != null) try self.syncCasSnapshot("rollup-delete");
        return true;
    }

    pub fn deleteSignal(self: *Engine, id: []const u8) !bool {
        const deleted = try self.metadata.market_catalog.deleteSignal(id);
        if (!deleted) return false;
        try self.market_runtime.deleteDefinition("signal", id, null);
        if (self.cas != null) try self.syncCasSnapshot("signal-delete");
        return true;
    }

    pub fn ingestExactMetric(
        self: *Engine,
        metric: []const u8,
        tags_json: []const u8,
        ts: i64,
        value: f64,
        descriptor: ?metric_catalog_mod.DescriptorInput,
    ) !types.SeriesId {
        var declared = try self.declareExactSeries(.{
            .name = metric,
            .tags_json = tags_json,
            .descriptor = descriptor,
        });
        defer declared.deinit(self.alloc);
        _ = try self.appendResolvedPoint(.{
            .series_id = declared.series_id,
            .ts = ts,
            .value = value,
        });
        return declared.series_id;
    }

    pub fn metricDescriptor(self: *Engine, metric: []const u8) ?metric_catalog_mod.Descriptor {
        return self.metadata.metric_catalog.get(metric);
    }

    pub fn metricKindOrDefault(self: *Engine, metric: []const u8) metric_catalog_mod.MetricKind {
        if (self.metricDescriptor(metric)) |descriptor| {
            if (descriptor.kind) |kind| return kind;
        }
        return .gauge;
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

    pub fn seriesDescriptorsForMetric(
        self: *Engine,
        alloc: std.mem.Allocator,
        metric: []const u8,
        labels_value: ?std.json.Value,
        op_and: bool,
        limit: ?usize,
    ) ![]SeriesDescriptor {
        var matches = std.AutoHashMap(types.SeriesId, void).init(alloc);
        defer matches.deinit();

        if (labels_value) |labels| {
            var ids = try self.collectMatchingSeriesIds(alloc, labels, op_and);
            defer ids.deinit();
            for (ids.items) |sid| try matches.put(sid, {});
        }

        var descriptors = std.array_list.Managed(SeriesDescriptor).init(alloc);
        errdefer descriptors.deinit();

        self.metadata.series_catalog.mutex.lock();
        defer self.metadata.series_catalog.mutex.unlock();

        for (self.metadata.series_catalog.entries.items) |entry| {
            if (!std.mem.eql(u8, entry.series, metric)) continue;
            if (labels_value != null and !matches.contains(entry.series_id)) continue;
            const bounds = self.seriesTimeBounds(entry.series_id);
            try descriptors.append(.{
                .series_id = entry.series_id,
                .metric = entry.series,
                .labels_json = entry.canonical_tags,
                .first_ts = bounds.first_ts,
                .last_ts = bounds.last_ts,
            });
            if (limit) |bounded| {
                if (descriptors.items.len >= bounded) break;
            }
        }

        return try descriptors.toOwnedSlice();
    }

    pub fn seriesTimeBounds(self: *Engine, series_id: types.SeriesId) struct { first_ts: ?i64, last_ts: ?i64 } {
        var first_ts: ?i64 = null;
        var last_ts: ?i64 = null;

        for (self.metadata.manifest.entries.items) |entry| {
            if (entry.series_id != series_id) continue;
            if (first_ts == null or entry.start_ts < first_ts.?) first_ts = entry.start_ts;
            if (last_ts == null or entry.end_ts > last_ts.?) last_ts = entry.end_ts;
        }

        if (self.mem.series.get(series_id)) |buffer| {
            for (buffer.points.items) |point| {
                if (first_ts == null or point.ts < first_ts.?) first_ts = point.ts;
                if (last_ts == null or point.ts > last_ts.?) last_ts = point.ts;
            }
        }

        return .{ .first_ts = first_ts, .last_ts = last_ts };
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
        var dirty = false;
        var scratch = std.array_list.Managed(u8).init(self.alloc);
        defer scratch.deinit();

        if (self.noteSimpleStringTags(series_id, tags, &scratch, &dirty) catch false) {
            if (dirty) self.tag_index_dirty.store(true, .monotonic);
            return;
        }

        // Fallback for non-canonical or non-string tag payloads.
        var parsed = std.json.parseFromSlice(std.json.Value, self.alloc, tags, .{}) catch return;
        defer parsed.deinit();
        if (parsed.value != .object) return;
        var it = parsed.value.object.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.* == .string) {
                scratch.clearRetainingCapacity();
                scratch.appendSlice(e.key_ptr.*) catch continue;
                scratch.append('=') catch continue;
                scratch.appendSlice(e.value_ptr.string) catch continue;
                const inserted = self.metadata.tags.add(scratch.items, series_id) catch |err| {
                    std.log.warn("tag index add failed: {s}", .{@errorName(err)});
                    continue;
                };
                dirty = dirty or inserted;
            }
        }
        if (dirty) self.tag_index_dirty.store(true, .monotonic);
    }

    fn noteTagsBatch(
        self: *Engine,
        inputs: []const ExactSeriesCanonicalDeclarationInput,
        results: []const ExactSeriesBatchDeclarationResult,
    ) !void {
        var dirty = false;
        var scratch = std.array_list.Managed(u8).init(self.alloc);
        defer scratch.deinit();
        for (inputs, results) |input, result| {
            if (result.status != .ok or result.registration != .inserted) continue;
            const series_id = result.series_id orelse continue;
            if (try self.noteSimpleStringTags(series_id, input.canonical_tags, &scratch, &dirty)) {
                continue;
            }

            var parsed = std.json.parseFromSlice(std.json.Value, self.alloc, input.canonical_tags, .{}) catch continue;
            if (parsed.value != .object) {
                parsed.deinit();
                continue;
            }
            var json_it = parsed.value.object.iterator();
            while (json_it.next()) |tag_entry| {
                if (tag_entry.value_ptr.* != .string) continue;
                scratch.clearRetainingCapacity();
                scratch.appendSlice(tag_entry.key_ptr.*) catch continue;
                scratch.append('=') catch continue;
                scratch.appendSlice(tag_entry.value_ptr.string) catch continue;
                const inserted = self.metadata.tags.add(scratch.items, series_id) catch |err| {
                    std.log.warn("tag index add failed: {s}", .{@errorName(err)});
                    continue;
                };
                dirty = dirty or inserted;
            }
            parsed.deinit();
        }

        if (dirty) self.tag_index_dirty.store(true, .monotonic);
    }

    fn noteSimpleStringTags(
        self: *Engine,
        series_id: types.SeriesId,
        tags: []const u8,
        scratch: *std.array_list.Managed(u8),
        dirty: *bool,
    ) !bool {
        const trimmed = std.mem.trim(u8, tags, " \t\r\n");
        if (trimmed.len < 2 or trimmed[0] != '{' or trimmed[trimmed.len - 1] != '}') return false;
        if (trimmed.len == 2) return true;

        var offset: usize = 1;
        while (offset < trimmed.len - 1) {
            const key = scanSimpleJsonString(trimmed, &offset) orelse return false;
            if (offset >= trimmed.len - 1 or trimmed[offset] != ':') return false;
            offset += 1;
            const value = scanSimpleJsonString(trimmed, &offset) orelse return false;

            scratch.clearRetainingCapacity();
            try scratch.ensureTotalCapacity(key.len + 1 + value.len);
            try scratch.appendSlice(key);
            try scratch.append('=');
            try scratch.appendSlice(value);

            const inserted = self.metadata.tags.add(scratch.items, series_id) catch |err| {
                std.log.warn("tag index add failed: {s}", .{@errorName(err)});
                if (offset == trimmed.len - 1) return true;
                if (trimmed[offset] != ',') return false;
                offset += 1;
                continue;
            };
            dirty.* = dirty.* or inserted;

            if (offset == trimmed.len - 1) return true;
            if (trimmed[offset] != ',') return false;
            offset += 1;
        }
        return offset == trimmed.len - 1;
    }

    fn scanSimpleJsonString(json: []const u8, offset: *usize) ?[]const u8 {
        if (offset.* >= json.len or json[offset.*] != '"') return null;
        offset.* += 1;
        const start = offset.*;
        while (offset.* < json.len) : (offset.* += 1) {
            const ch = json[offset.*];
            switch (ch) {
                '"' => {
                    const value = json[start..offset.*];
                    offset.* += 1;
                    return value;
                },
                '\\' => return null,
                0...31 => return null,
                else => {},
            }
        }
        return null;
    }

    fn appendMemtablePoint(self: *Engine, sid: types.SeriesId, ts: i64, value: f64) !void {
        const gop = try self.mem.series.getOrPut(sid);
        if (!gop.found_existing) {
            gop.value_ptr.* = MemSeriesBuffer.init(self.alloc);
        }
        if (gop.value_ptr.last_ts) |last_ts| {
            if (ts < last_ts) gop.value_ptr.sorted = false;
        }
        try gop.value_ptr.points.append(.{ .ts = ts, .value = value });
        if (gop.value_ptr.last_ts == null or ts > gop.value_ptr.last_ts.?) {
            gop.value_ptr.last_ts = ts;
        }
        _ = self.mem.bytes.fetchAdd(@sizeOf(types.Point), .monotonic);
    }

    fn appendMemtableBatchGrouped(self: *Engine, points: []ResolvedIngestPoint) !void {
        if (points.len == 0) return;

        std.sort.block(ResolvedIngestPoint, points, {}, struct {
            fn lessThan(_: void, a: ResolvedIngestPoint, b: ResolvedIngestPoint) bool {
                if (a.series_id != b.series_id) return a.series_id < b.series_id;
                return a.ts < b.ts;
            }
        }.lessThan);

        var start: usize = 0;
        while (start < points.len) {
            const sid = points[start].series_id;
            var end = start + 1;
            while (end < points.len and points[end].series_id == sid) : (end += 1) {}

            const gop = try self.mem.series.getOrPut(sid);
            if (!gop.found_existing) {
                gop.value_ptr.* = MemSeriesBuffer.init(self.alloc);
            }
            try gop.value_ptr.points.ensureUnusedCapacity(end - start);
            start = end;
        }

        start = 0;
        while (start < points.len) {
            const sid = points[start].series_id;
            var end = start + 1;
            while (end < points.len and points[end].series_id == sid) : (end += 1) {}

            const buffer = self.mem.series.getPtr(sid).?;
            if (buffer.last_ts) |last_ts| {
                if (points[start].ts < last_ts) buffer.sorted = false;
            }
            var last_ts = buffer.last_ts;
            for (points[start..end]) |point| {
                buffer.points.appendAssumeCapacity(.{ .ts = point.ts, .value = point.value });
                if (last_ts == null or point.ts > last_ts.?) last_ts = point.ts;
            }
            buffer.last_ts = last_ts;
            start = end;
        }

        _ = self.mem.bytes.fetchAdd(points.len * @sizeOf(types.Point), .monotonic);
    }

    pub fn verifyCasState(self: *Engine) !void {
        if (self.cas) |*cas| {
            return try cas.verifyHeadMatchesLegacyWithMarket(
                self.data_dir,
                &self.metadata.manifest,
                &self.metadata.tags,
                &self.metadata.series_catalog,
                &self.metadata.metric_catalog,
                &self.metadata.market_catalog,
            );
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

    pub fn flushAndDrain(self: *Engine, timeout_ms: u64) !bool {
        const flushed = try self.flushNow();
        try self.waitForDrained(timeout_ms);
        return flushed;
    }

    pub fn waitForDrained(self: *Engine, timeout_ms: u64) WaitError!void {
        const deadline: i64 = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
        while (true) {
            if (self.queue.len() == 0 and self.mem.bytes.load(.monotonic) == 0) {
                if (self.cas != null) {
                    self.verifyCasState() catch {
                        if (std.time.milliTimestamp() >= deadline) break;
                        sleepMs(1);
                        continue;
                    };
                }
                return;
            }
            if (std.time.milliTimestamp() >= deadline) break;
            sleepMs(1);
        }
        _ = self.metrics.drain_timeout_total.fetchAdd(1, .monotonic);
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
        try pauseWriterForMaintenance(self);
        errdefer resumeWriterAfterMaintenance(self) catch |err| {
            std.log.err("failed to resume writer after compaction: {s}", .{@errorName(err)});
        };
        _ = try flushMemtable(self);
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
        try resumeWriterAfterMaintenance(self);
        return changed;
    }

    fn syncCasSnapshot(self: *Engine, reason: []const u8) !void {
        if (self.cas) |*cas| {
            const start_ns = std.time.nanoTimestamp();
            errdefer _ = self.metrics.cas_sync_failed_total.fetchAdd(1, .monotonic);
            _ = try cas.syncLegacySnapshotWithMarket(
                self.data_dir,
                &self.metadata.manifest,
                &self.metadata.tags,
                &self.metadata.series_catalog,
                &self.metadata.metric_catalog,
                &self.metadata.market_catalog,
                reason,
            );
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
                _ = try cas.bootstrapIfMissingWithMarket(
                    self.data_dir,
                    &self.metadata.manifest,
                    &self.metadata.tags,
                    &self.metadata.series_catalog,
                    &self.metadata.metric_catalog,
                    &self.metadata.market_catalog,
                );
            } else {
                _ = try cas.syncLegacySnapshotWithMarket(
                    self.data_dir,
                    &self.metadata.manifest,
                    &self.metadata.tags,
                    &self.metadata.series_catalog,
                    &self.metadata.metric_catalog,
                    &self.metadata.market_catalog,
                    "snapshot",
                );
            }
            try self.metadata.refreshCasIndex(cas);
            return;
        }

        var temp = try cas_mod.CasManager.init(self.alloc, self.config.data_dir, self.config.fsync);
        defer temp.deinit();
        if (try temp.refs.readHead(cas_mod.main_ref) == null) {
            _ = try temp.bootstrapIfMissingWithMarket(
                self.data_dir,
                &self.metadata.manifest,
                &self.metadata.tags,
                &self.metadata.series_catalog,
                &self.metadata.metric_catalog,
                &self.metadata.market_catalog,
            );
        } else {
            _ = try temp.syncLegacySnapshotWithMarket(
                self.data_dir,
                &self.metadata.manifest,
                &self.metadata.tags,
                &self.metadata.series_catalog,
                &self.metadata.metric_catalog,
                &self.metadata.market_catalog,
                "snapshot",
            );
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

    fn descriptorInputsEquivalent(
        lhs: metric_catalog_mod.DescriptorInput,
        rhs: metric_catalog_mod.DescriptorInput,
    ) bool {
        return lhs.kind == rhs.kind and
            std.mem.eql(u8, lhs.metric, rhs.metric) and
            optionalBytesEqualNormalized(lhs.unit, rhs.unit) and
            optionalBytesEqualNormalized(lhs.description, rhs.description) and
            optionalBytesEqualNormalized(lhs.source_metric, rhs.source_metric) and
            optionalBytesEqualNormalized(lhs.source_field, rhs.source_field);
    }

    fn optionalBytesEqualNormalized(lhs: ?[]const u8, rhs: ?[]const u8) bool {
        return optionalBytesNormalized(lhs) == null and optionalBytesNormalized(rhs) == null or
            (optionalBytesNormalized(lhs) != null and optionalBytesNormalized(rhs) != null and
            std.mem.eql(u8, optionalBytesNormalized(lhs).?, optionalBytesNormalized(rhs).?));
    }

    fn optionalBytesNormalized(value: ?[]const u8) ?[]const u8 {
        if (value) |slice| {
            const trimmed = std.mem.trim(u8, slice, " \t\r\n");
            if (trimmed.len != 0) return trimmed;
        }
        return null;
    }

    pub fn declareExactSeriesCanonicalBatch(
        self: *Engine,
        inputs: []const ExactSeriesCanonicalDeclarationInput,
        results: []ExactSeriesBatchDeclarationResult,
    ) !void {
        std.debug.assert(inputs.len == results.len);
        if (inputs.len == 0) return;

        self.exact_series_declare_mu.lock();
        defer self.exact_series_declare_mu.unlock();

        for (results) |*result| {
            result.* = .{};
        }

        const descriptor_phase_start_ns = std.time.nanoTimestamp();
        const descriptor_slots = try self.alloc.alloc(?usize, inputs.len);
        defer self.alloc.free(descriptor_slots);
        @memset(descriptor_slots, null);

        var descriptor_inputs = std.array_list.Managed(metric_catalog_mod.DescriptorInput).init(self.alloc);
        defer descriptor_inputs.deinit();
        try descriptor_inputs.ensureTotalCapacity(inputs.len);
        var descriptor_unique_by_metric = std.StringHashMap(usize).init(self.alloc);
        defer descriptor_unique_by_metric.deinit();

        for (inputs, 0..) |input, idx| {
            const descriptor = input.descriptor orelse continue;
            if (results[idx].status != .ok) continue;

            if (descriptor_unique_by_metric.get(descriptor.metric)) |existing_slot| {
                const existing_descriptor = descriptor_inputs.items[existing_slot];
                if (descriptorInputsEquivalent(existing_descriptor, descriptor)) {
                    descriptor_slots[idx] = existing_slot;
                } else {
                    results[idx].status = .metric_descriptor_conflict;
                }
                continue;
            }

            try descriptor_inputs.append(descriptor);
            descriptor_slots[idx] = descriptor_inputs.items.len - 1;
            try descriptor_unique_by_metric.put(descriptor.metric, descriptor_inputs.items.len - 1);
        }

        if (descriptor_inputs.items.len != 0) {
            const descriptor_results = try self.alloc.alloc(metric_catalog_mod.BatchRegisterResult, descriptor_inputs.items.len);
            defer self.alloc.free(descriptor_results);

            try self.metadata.metric_catalog.registerBatch(descriptor_inputs.items, descriptor_results);
            for (descriptor_slots, 0..) |slot, idx| {
                const descriptor_slot = slot orelse continue;
                if (descriptor_results[descriptor_slot] == .conflict) {
                    results[idx].status = .metric_descriptor_conflict;
                }
            }
        }
        _ = self.metrics.exact_series_declare_metric_catalog_ns_total.fetchAdd(
            @intCast(std.time.nanoTimestamp() - descriptor_phase_start_ns),
            .monotonic,
        );

        const series_phase_start_ns = std.time.nanoTimestamp();
        const series_slots = try self.alloc.alloc(?usize, inputs.len);
        defer self.alloc.free(series_slots);
        @memset(series_slots, null);

        var unique_series_inputs = std.array_list.Managed(series_catalog_mod.CanonicalRegisterInput).init(self.alloc);
        defer unique_series_inputs.deinit();
        try unique_series_inputs.ensureTotalCapacity(inputs.len);
        var unique_series_owner_indices = std.array_list.Managed(usize).init(self.alloc);
        defer unique_series_owner_indices.deinit();
        try unique_series_owner_indices.ensureTotalCapacity(inputs.len);
        var unique_series_by_id = std.AutoHashMap(types.SeriesId, usize).init(self.alloc);
        defer unique_series_by_id.deinit();

        for (inputs, 0..) |input, idx| {
            if (results[idx].status != .ok) continue;
            const series_id = types.seriesIdFrom(input.name, input.canonical_tags);

            if (unique_series_by_id.get(series_id)) |existing_slot| {
                const existing = unique_series_inputs.items[existing_slot];
                if (std.mem.eql(u8, existing.series, input.name) and std.mem.eql(u8, existing.canonical_tags, input.canonical_tags)) {
                    series_slots[idx] = existing_slot;
                } else {
                    results[idx].status = .series_conflict;
                }
                continue;
            }

            try unique_series_inputs.append(.{
                .series = input.name,
                .canonical_tags = input.canonical_tags,
                .series_id = series_id,
            });
            try unique_series_owner_indices.append(idx);
            series_slots[idx] = unique_series_inputs.items.len - 1;
            try unique_series_by_id.put(series_id, unique_series_inputs.items.len - 1);
        }

        var series_results: []series_catalog_mod.RegisterBatchResult = &.{};
        defer if (series_results.len != 0) self.alloc.free(series_results);
        var wal_registrations = std.array_list.Managed(series_catalog_mod.PendingWalRegistration).init(self.alloc);
        defer wal_registrations.deinit();

        if (unique_series_inputs.items.len != 0) {
            series_results = try self.alloc.alloc(series_catalog_mod.RegisterBatchResult, unique_series_inputs.items.len);
            try self.metadata.series_catalog.registerCanonicalBatch(unique_series_inputs.items, series_results, &wal_registrations);
        }
        _ = self.metrics.exact_series_declare_series_catalog_ns_total.fetchAdd(
            @intCast(std.time.nanoTimestamp() - series_phase_start_ns),
            .monotonic,
        );

        const wal_phase_start_ns = std.time.nanoTimestamp();
        if (wal_registrations.items.len != 0) {
            _ = try self.wal.appendSeriesRegistrationBatch(wal_registrations.items);
        }
        _ = self.metrics.exact_series_declare_wal_registration_ns_total.fetchAdd(
            @intCast(std.time.nanoTimestamp() - wal_phase_start_ns),
            .monotonic,
        );

        for (series_slots, 0..) |slot, idx| {
            const series_slot = slot orelse continue;
            if (results[idx].status != .ok) continue;

            const series_id = unique_series_inputs.items[series_slot].series_id;
            const owner_idx = unique_series_owner_indices.items[series_slot];
            results[idx] = switch (series_results[series_slot]) {
                .inserted => .{
                    .status = .ok,
                    .series_id = series_id,
                    .registration = if (idx == owner_idx) .inserted else .unchanged,
                },
                .unchanged => .{
                    .status = .ok,
                    .series_id = series_id,
                    .registration = .unchanged,
                },
                .conflict => .{
                    .status = .series_conflict,
                    .series_id = null,
                    .registration = .unchanged,
                },
            };
        }

        const tag_phase_start_ns = std.time.nanoTimestamp();
        try self.noteTagsBatch(inputs, results);
        _ = self.metrics.exact_series_declare_tag_index_ns_total.fetchAdd(
            @intCast(std.time.nanoTimestamp() - tag_phase_start_ns),
            .monotonic,
        );

        var inserted_total: u64 = 0;
        var unchanged_total: u64 = 0;
        var descriptor_conflict_total: u64 = 0;
        var series_conflict_total: u64 = 0;
        for (results) |result| {
            switch (result.status) {
                .ok => switch (result.registration) {
                    .inserted => inserted_total += 1,
                    .unchanged => unchanged_total += 1,
                },
                .metric_descriptor_conflict => descriptor_conflict_total += 1,
                .series_conflict => series_conflict_total += 1,
            }
        }
        _ = self.metrics.exact_series_declare_inserted_total.fetchAdd(inserted_total, .monotonic);
        _ = self.metrics.exact_series_declare_unchanged_total.fetchAdd(unchanged_total, .monotonic);
        _ = self.metrics.exact_series_declare_descriptor_conflict_total.fetchAdd(descriptor_conflict_total, .monotonic);
        _ = self.metrics.exact_series_declare_series_conflict_total.fetchAdd(series_conflict_total, .monotonic);
    }

    pub fn declareExactSeriesCanonical(
        self: *Engine,
        name: []const u8,
        canonical_tags: []const u8,
        descriptor: ?metric_catalog_mod.DescriptorInput,
    ) !types.SeriesId {
        var result: [1]ExactSeriesBatchDeclarationResult = undefined;
        try self.declareExactSeriesCanonicalBatch(&.{
            .{
                .name = name,
                .canonical_tags = canonical_tags,
                .descriptor = descriptor,
            },
        }, result[0..]);
        return switch (result[0].status) {
            .ok => result[0].series_id.?,
            .metric_descriptor_conflict => error.MetricDescriptorConflict,
            .series_conflict => error.SeriesIdConflict,
        };
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
            _ = try tags.add(entry.key, series_id);
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

fn metricCatalogFromSnapshot(
    alloc: std.mem.Allocator,
    fsync: cfg.FsyncPolicy,
    snapshot: cas_mod.MetricCatalogSnapshot,
) !metric_catalog_mod.MetricCatalog {
    var catalog = metric_catalog_mod.MetricCatalog.initEmpty(alloc, fsync);
    errdefer catalog.deinit();

    for (snapshot.entries) |entry| {
        _ = try catalog.register(.{
            .metric = entry.metric,
            .kind = entry.kind,
            .unit = entry.unit,
            .description = entry.description,
            .source_metric = entry.source_metric,
            .source_field = entry.source_field,
        });
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
    while (true) {
        if (engine.metadata.manifest.entries.items.len >= expected_entries and engine.mem.bytes.load(.monotonic) == 0 and engine.queue.len() == 0) {
            if (engine.cas != null) {
                engine.verifyCasState() catch {
                    if (std.time.milliTimestamp() >= deadline) break;
                    sleepMs(10);
                    continue;
                };
            }
            return;
        }
        if (std.time.milliTimestamp() >= deadline) break;
        sleepMs(10);
    }
    return waitError.Timeout;
}

fn waitForQueueEmpty(engine: *Engine, timeout_ms: u64) waitError!void {
    const deadline: i64 = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
    while (true) {
        if (engine.queue.len() == 0) return;
        if (std.time.milliTimestamp() >= deadline) break;
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
    self.metrics.maintenance_pause_active.store(true, .monotonic);
}

fn resumeWriterAfterMaintenance(self: *Engine) !void {
    self.stop_flag = false;
    self.queue.reopen();
    if (self.writer_thread == null) {
        self.writer_thread = try std.Thread.spawn(.{}, Engine.writerLoop, .{self});
    }
    self.metrics.maintenance_pause_active.store(false, .monotonic);
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
        const hour = self.hourBucketForSeries(series_id, points[start_idx].ts);
        var end_idx = start_idx + 1;
        while (end_idx < points.len and self.hourBucketForSeries(series_id, points[end_idx].ts) == hour) : (end_idx += 1) {}
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

fn testConfig(talloc: std.mem.Allocator, data_path: []const u8) !cfg.Config {
    return .{
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
}

test "engine queue wraps around and preserves order" {
    const talloc = std.testing.allocator;
    var metrics = Engine.Metrics.init();
    const queue = try Engine.Queue.init(talloc, &metrics);
    defer {
        queue.deinit();
        talloc.destroy(queue);
    }

    try queue.push(.{ .series_id = 1, .ts = 1, .value = 1 });
    try queue.push(.{ .series_id = 2, .ts = 2, .value = 2 });
    try queue.push(.{ .series_id = 3, .ts = 3, .value = 3 });

    var first = queue.pop().?;
    defer first.deinit(talloc);
    var second = queue.pop().?;
    defer second.deinit(talloc);
    try std.testing.expectEqual(@as(types.SeriesId, 1), first.points[0].series_id);
    try std.testing.expectEqual(@as(types.SeriesId, 2), second.points[0].series_id);

    try queue.push(.{ .series_id = 4, .ts = 4, .value = 4 });
    try queue.push(.{ .series_id = 5, .ts = 5, .value = 5 });

    var third = queue.pop().?;
    defer third.deinit(talloc);
    var fourth = queue.pop().?;
    defer fourth.deinit(talloc);
    var fifth = queue.pop().?;
    defer fifth.deinit(talloc);

    try std.testing.expectEqual(@as(types.SeriesId, 3), third.points[0].series_id);
    try std.testing.expectEqual(@as(types.SeriesId, 4), fourth.points[0].series_id);
    try std.testing.expectEqual(@as(types.SeriesId, 5), fifth.points[0].series_id);
    try std.testing.expectEqual(@as(usize, 0), queue.len());
    try std.testing.expectEqual(@as(usize, 0), queue.pendingBytes());
}

test "engine exact-series declaration is idempotent and indexes tags once" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/declare-once", .{tmp.sub_path});
    defer talloc.free(data_path);

    const config = try testConfig(talloc, data_path);
    var engine = try Engine.init(talloc, config);
    defer engine.deinit();

    var first = try engine.declareExactSeries(.{
        .name = "svc.req",
        .tags_json = "{\"b\":\"2\",\"a\":\"1\"}",
        .descriptor = .{
            .metric = "svc.req",
            .kind = .counter,
            .unit = "requests",
        },
    });
    defer first.deinit(talloc);

    const second_sid = try engine.declareExactSeriesCanonical("svc.req", first.canonical_tags, .{
        .metric = "svc.req",
        .kind = .counter,
        .unit = "requests",
    });
    try std.testing.expectEqual(first.series_id, second_sid);
    try std.testing.expectEqualStrings("{\"a\":\"1\",\"b\":\"2\"}", first.canonical_tags);

    _ = try engine.appendResolvedBatch(&.{
        .{ .series_id = first.series_id, .ts = 10, .value = 1.0 },
        .{ .series_id = first.series_id, .ts = 20, .value = 2.0 },
    });
    _ = try engine.flushAndDrain(1_000);

    const matches_a = engine.metadata.tags.get("a=1");
    const matches_b = engine.metadata.tags.get("b=2");
    try std.testing.expectEqual(@as(usize, 1), matches_a.len);
    try std.testing.expectEqual(@as(usize, 1), matches_b.len);
    try std.testing.expectEqual(first.series_id, matches_a[0]);
    try std.testing.expectEqual(first.series_id, matches_b[0]);

    const descriptor = engine.metricDescriptor("svc.req").?;
    try std.testing.expectEqual(metric_catalog_mod.MetricKind.counter, descriptor.kind.?);
    try std.testing.expectEqualStrings("requests", descriptor.unit.?);
}

test "engine batch exact-series declaration preserves per-entry conflicts and successes" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/declare-batch", .{tmp.sub_path});
    defer talloc.free(data_path);

    var engine = try Engine.init(talloc, try testConfig(talloc, data_path));
    defer engine.deinit();

    const conflicting_sid = types.seriesIdFrom("svc.conflict", "{}");
    try engine.registerSeriesInternal("svc.other", "{}", conflicting_sid, true);

    const inputs = [_]Engine.ExactSeriesCanonicalDeclarationInput{
        .{
            .name = "svc.batch",
            .canonical_tags = "{\"host\":\"a\"}",
            .descriptor = .{ .metric = "svc.batch", .kind = .counter },
        },
        .{
            .name = "svc.batch",
            .canonical_tags = "{\"host\":\"b\"}",
            .descriptor = .{ .metric = "svc.batch", .kind = .counter },
        },
        .{
            .name = "svc.batch",
            .canonical_tags = "{\"host\":\"c\"}",
            .descriptor = .{ .metric = "svc.batch", .kind = .gauge },
        },
        .{
            .name = "svc.conflict",
            .canonical_tags = "{}",
            .descriptor = null,
        },
    };
    var results: [inputs.len]Engine.ExactSeriesBatchDeclarationResult = undefined;
    try engine.declareExactSeriesCanonicalBatch(&inputs, results[0..]);

    try std.testing.expectEqual(Engine.ExactSeriesDeclarationStatus.ok, results[0].status);
    try std.testing.expectEqual(Engine.ExactSeriesDeclarationStatus.ok, results[1].status);
    try std.testing.expectEqual(Engine.ExactSeriesDeclarationStatus.metric_descriptor_conflict, results[2].status);
    try std.testing.expectEqual(Engine.ExactSeriesDeclarationStatus.series_conflict, results[3].status);
    try std.testing.expectEqual(types.seriesIdFrom("svc.batch", "{\"host\":\"a\"}"), results[0].series_id.?);
    try std.testing.expectEqual(types.seriesIdFrom("svc.batch", "{\"host\":\"b\"}"), results[1].series_id.?);

    const host_a = engine.metadata.tags.get("host=a");
    const host_b = engine.metadata.tags.get("host=b");
    const host_c = engine.metadata.tags.get("host=c");
    try std.testing.expectEqual(@as(usize, 1), host_a.len);
    try std.testing.expectEqual(@as(usize, 1), host_b.len);
    try std.testing.expectEqual(@as(usize, 0), host_c.len);
    try std.testing.expectEqual(results[0].series_id.?, host_a[0]);
    try std.testing.expectEqual(results[1].series_id.?, host_b[0]);
}

test "engine appendResolvedBatch rejects atomically when memory limit is exceeded" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/mem-limit", .{tmp.sub_path});
    defer talloc.free(data_path);

    var config = try testConfig(talloc, data_path);
    config.mem_limit_bytes = @sizeOf(Engine.ResolvedIngestPoint) * 2;
    var engine = try Engine.init(talloc, config);
    defer engine.deinit();

    const sid = try engine.declareExactSeriesCanonical("svc.limit", "{}", null);
    try std.testing.expectError(error.MemoryLimitExceeded, engine.appendResolvedBatch(&.{
        .{ .series_id = sid, .ts = 1, .value = 1.0 },
        .{ .series_id = sid, .ts = 2, .value = 2.0 },
    }));
    try std.testing.expectEqual(@as(usize, 0), engine.queue.len());
    try std.testing.expectEqual(@as(usize, 0), engine.queue.pendingBytes());

    var results = std.array_list.Managed(types.Point).init(talloc);
    defer results.deinit();
    try engine.queryRange(sid, 0, 10, &results);
    try std.testing.expectEqual(@as(usize, 0), results.items.len);
}

test "engine flushAndDrain is a queryable barrier and zero timeout succeeds when already drained" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/flush-and-drain", .{tmp.sub_path});
    defer talloc.free(data_path);

    var engine = try Engine.init(talloc, try testConfig(talloc, data_path));
    defer engine.deinit();

    const sid = try engine.declareExactSeriesCanonical("svc.flush", "{}", null);
    _ = try engine.appendResolvedPoint(.{ .series_id = sid, .ts = 7, .value = 3.5 });
    try std.testing.expect(try engine.flushAndDrain(1_000));
    try std.testing.expect(!(try engine.flushAndDrain(0)));

    var results = std.array_list.Managed(types.Point).init(talloc);
    defer results.deinit();
    try engine.queryRange(sid, 0, 10, &results);
    try std.testing.expectEqual(@as(usize, 1), results.items.len);
    try std.testing.expectEqual(@as(i64, 7), results.items[0].ts);
    try std.testing.expectApproxEqAbs(@as(f64, 3.5), results.items[0].value, 1e-9);
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

test "scheduleDerivedMetric tracks exact definition instances" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/derived-instance-queue", .{tmp.sub_path});
    defer talloc.free(data_path);

    const cfg_local = cfg.Config{
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

    var engine = try Engine.init(talloc, cfg_local);
    defer engine.deinit();

    var trade_policy = try engine.registerBarPolicy(.{
        .id = "trade-1m",
        .source_metric = "market.trade",
        .interval_ns = 60 * std.time.ns_per_s,
        .session_rule = "regular_hours",
        .no_trade_rule = "carry_forward_none",
        .halt_rule = "skip_halts",
        .correction_policy = "append_only",
        .trade_filter = null,
    });
    defer trade_policy.deinit(talloc);

    var bar_policy = try engine.registerBarPolicy(.{
        .id = "bar-5m",
        .source_metric = "market.bar",
        .interval_ns = 300 * std.time.ns_per_s,
        .session_rule = "regular_hours",
        .no_trade_rule = "carry_forward_none",
        .halt_rule = "skip_halts",
        .correction_policy = "append_only",
        .trade_filter = null,
    });
    defer bar_policy.deinit(talloc);

    var rollup = try engine.registerRollup(.{
        .id = "bars-1m",
        .source_metric = "market.trade",
        .target_metric = "market.bar",
        .policy_id = "trade-1m",
        .transform_kind = .trade_to_bar,
    });
    defer rollup.deinit(talloc);

    var rollup2 = try engine.registerRollup(.{
        .id = "bars-5m",
        .source_metric = "market.bar",
        .target_metric = "market.bar",
        .policy_id = "bar-5m",
        .transform_kind = .bar_to_bar,
    });
    defer rollup2.deinit(talloc);

    var signal = try engine.registerSignal(.{
        .id = "ema-fast",
        .input_metric = "market.bar",
        .policy_id = "bar-5m",
        .expression_kind = .ema,
        .params_json = "{\"period\":12}",
        .emit_rule = "on_close",
    });
    defer signal.deinit(talloc);

    const trade_labels = try @import("storage/series_catalog.zig").canonicalizeTagsJson(talloc, "{\"symbol\":\"AAPL\",\"venue\":\"XNAS\"}");
    defer talloc.free(trade_labels);
    try engine.scheduleDerivedMetric("market.trade", trade_labels);

    const trade_pending = engine.pendingStatsForDefinition("rollup", "bars-1m", rollup.version);
    try std.testing.expectEqual(@as(usize, 1), trade_pending.pending_instances);
    try std.testing.expect(trade_pending.max_lag_ns != null);
    try std.testing.expectEqual(@as(usize, 0), engine.pendingStatsForDefinition("rollup", "bars-5m", rollup2.version).pending_instances);
    try std.testing.expectEqual(@as(usize, 0), engine.pendingStatsForDefinition("signal", "ema-fast", signal.version).pending_instances);

    const bar_labels = try @import("storage/series_catalog.zig").canonicalizeTagsJson(talloc, "{\"bar_policy_id\":\"bar-5m\",\"data_revision\":\"legacy-live\",\"definition_id\":\"bars-1m\",\"definition_version\":\"1\",\"interval\":\"60000000000\",\"symbol\":\"AAPL\",\"venue\":\"XNAS\"}");
    defer talloc.free(bar_labels);
    try engine.scheduleDerivedMetric("market.bar", bar_labels);
    try std.testing.expectEqual(@as(usize, 1), engine.pendingStatsForDefinition("rollup", "bars-5m", rollup2.version).pending_instances);
    try std.testing.expectEqual(@as(usize, 1), engine.pendingStatsForDefinition("signal", "ema-fast", signal.version).pending_instances);
}

const SignalColumnConfig = struct {
    primary: []u8,
    secondary: ?[]u8 = null,
};

fn signalColumnConfig(alloc: std.mem.Allocator, signal: market_catalog_mod.SignalDefinition) !SignalColumnConfig {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, signal.params_json, .{});
    defer parsed.deinit();
    const obj = if (parsed.value == .object) parsed.value.object else return .{ .primary = try alloc.dupe(u8, "close") };
    return switch (signal.expression_kind) {
        .ema, .moving_avg, .threshold_cross, .crossover, .crossunder => .{
            .primary = try alloc.dupe(u8, jsonParamString(obj, "column", "close")),
        },
        .spread_gt => .{
            .primary = try alloc.dupe(u8, jsonParamString(obj, "column", "spread")),
        },
        .vwap_deviation => .{
            .primary = try alloc.dupe(u8, jsonParamString(obj, "price_column", "close")),
            .secondary = try alloc.dupe(u8, jsonParamString(obj, "vwap_column", "vwap")),
        },
    };
}

fn jsonParamString(obj: std.json.ObjectMap, key: []const u8, default: []const u8) []const u8 {
    if (obj.get(key)) |value| {
        if (value == .string) return value.string;
    }
    return default;
}

fn jsonParamInt(obj: std.json.ObjectMap, key: []const u8, default: usize) usize {
    if (obj.get(key)) |value| {
        return switch (value) {
            .integer => |int| @max(@as(usize, 1), @as(usize, @intCast(int))),
            else => default,
        };
    }
    return default;
}

fn jsonParamFloat(obj: std.json.ObjectMap, key: []const u8, default: f64) f64 {
    if (obj.get(key)) |value| {
        return switch (value) {
            .float => value.float,
            .integer => @floatFromInt(value.integer),
            else => default,
        };
    }
    return default;
}

fn marketLabelValueFromJson(alloc: std.mem.Allocator, labels_json: []const u8, key: []const u8) !?[]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, labels_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    if (parsed.value.object.get(key)) |value| {
        if (value == .string) return try alloc.dupe(u8, value.string);
    }
    return null;
}

fn pointValues(alloc: std.mem.Allocator, points: []const types.Point) ![]f64 {
    const values = try alloc.alloc(f64, points.len);
    for (points, 0..) |point, idx| values[idx] = point.value;
    return values;
}

fn avgWindow(values: []const f64, start: usize, len: usize) f64 {
    var sum: f64 = 0;
    for (values[start .. start + len]) |value| sum += value;
    return sum / @as(f64, @floatFromInt(len));
}

fn bucketStart(ts: i64, interval_ns: i64) i64 {
    return (@divTrunc(ts, interval_ns)) * interval_ns;
}

fn alignTradeSamples(alloc: std.mem.Allocator, price_points: []const types.Point, size_points: []const types.Point) ![]Engine.TradeSample {
    var out = std.array_list.Managed(Engine.TradeSample).init(alloc);
    errdefer out.deinit();
    var i: usize = 0;
    var j: usize = 0;
    while (i < price_points.len and j < size_points.len) {
        const price_point = price_points[i];
        const size_point = size_points[j];
        if (price_point.ts == size_point.ts) {
            try out.append(.{ .ts = price_point.ts, .price = price_point.value, .size = size_point.value });
            i += 1;
            j += 1;
        } else if (price_point.ts < size_point.ts) {
            i += 1;
        } else {
            j += 1;
        }
    }
    return try out.toOwnedSlice();
}

fn alignQuoteSamples(
    alloc: std.mem.Allocator,
    bid_points: []const types.Point,
    ask_points: []const types.Point,
    bid_size_points: []const types.Point,
    ask_size_points: []const types.Point,
) ![]Engine.QuoteSample {
    const count = @min(@min(bid_points.len, ask_points.len), @min(bid_size_points.len, ask_size_points.len));
    var out = std.array_list.Managed(Engine.QuoteSample).init(alloc);
    errdefer out.deinit();
    for (0..count) |idx| {
        const ts = bid_points[idx].ts;
        if (ask_points[idx].ts != ts or bid_size_points[idx].ts != ts or ask_size_points[idx].ts != ts) continue;
        try out.append(.{
            .ts = ts,
            .bid = bid_points[idx].value,
            .ask = ask_points[idx].value,
            .bid_size = bid_size_points[idx].value,
            .ask_size = ask_size_points[idx].value,
        });
    }
    return try out.toOwnedSlice();
}

fn alignBarSamples(alloc: std.mem.Allocator, columns: []const []types.Point) ![]Engine.BarSample {
    if (columns.len < 6) return try alloc.alloc(Engine.BarSample, 0);
    const count = @min(@min(columns[0].len, columns[1].len), @min(columns[2].len, @min(columns[3].len, @min(columns[4].len, columns[5].len))));
    var out = std.array_list.Managed(Engine.BarSample).init(alloc);
    errdefer out.deinit();
    for (0..count) |idx| {
        const ts = columns[0][idx].ts;
        if (columns[1][idx].ts != ts or columns[2][idx].ts != ts or columns[3][idx].ts != ts or columns[4][idx].ts != ts or columns[5][idx].ts != ts) continue;
        try out.append(.{
            .ts = ts,
            .open = columns[0][idx].value,
            .high = columns[1][idx].value,
            .low = columns[2][idx].value,
            .close = columns[3][idx].value,
            .volume = columns[4][idx].value,
            .vwap = columns[5][idx].value,
        });
    }
    return try out.toOwnedSlice();
}

fn mergeLabelsJson(alloc: std.mem.Allocator, base_labels_json: []const u8, additions: []const Engine.LabelAddition) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, base_labels_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidTagsJson;

    var buffer = std.array_list.Managed(u8).init(alloc);
    defer buffer.deinit();
    var writer = buffer.writer();
    var tmp: [512]u8 = undefined;
    var adapter = writer.adaptToNewApi(&tmp);
    var iface = &adapter.new_interface;
    var jw = std.json.Stringify{ .writer = iface };
    try jw.beginObject();

    var keys = std.array_list.Managed([]const u8).init(alloc);
    defer keys.deinit();
    var it = parsed.value.object.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .string) continue;
        try keys.append(entry.key_ptr.*);
    }
    for (additions) |addition| {
        var exists = false;
        for (keys.items) |key| {
            if (std.mem.eql(u8, key, addition.key)) {
                exists = true;
                break;
            }
        }
        if (!exists) try keys.append(addition.key);
    }
    std.sort.block([]const u8, keys.items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lessThan);

    for (keys.items) |key| {
        try jw.objectField(key);
        var overridden = false;
        for (additions) |addition| {
            if (std.mem.eql(u8, addition.key, key)) {
                try jw.write(addition.value);
                overridden = true;
                break;
            }
        }
        if (!overridden) try jw.write(parsed.value.object.get(key).?.string);
    }
    try jw.endObject();
    try iface.flush();
    if (adapter.err) |err| return err;
    return try buffer.toOwnedSlice();
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

test "engine replays rotated WAL files and current tail across metadata modes" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/wal-rotation-recovery", .{tmp.sub_path});
    defer talloc.free(data_path);

    const raw_tags = "{\"rack\":\"r2\",\"host\":\"b\"}";
    const canonical_tags = "{\"host\":\"b\",\"rack\":\"r2\"}";
    const sid = types.seriesIdFrom("wal.rotate.series", raw_tags);

    try std.fs.cwd().makePath(data_path);
    var data_dir = try std.fs.cwd().openDir(data_path, .{ .iterate = true });
    defer data_dir.close();

    var wal = try wal_mod.WAL.open(talloc, data_dir, .none);
    _ = try wal.appendSeriesRegistration(sid, "wal.rotate.series", canonical_tags);
    _ = try wal.append(sid, 1_000, 10.0);
    _ = try wal.append(sid, 1_050, 11.0);
    wal.bytes_written = 64 * 1024 * 1024;
    try wal.rotateIfNeeded();
    _ = try wal.append(sid, 2_000, 20.0);
    _ = try wal.append(sid, 2_050, 21.0);
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
        try std.testing.expectEqual(@as(usize, 4), results.items.len);
        try std.testing.expectEqual(@as(i64, 1_000), results.items[0].ts);
        try std.testing.expectApproxEqAbs(@as(f64, 10.0), results.items[0].value, 1e-9);
        try std.testing.expectEqual(@as(i64, 1_050), results.items[1].ts);
        try std.testing.expectApproxEqAbs(@as(f64, 11.0), results.items[1].value, 1e-9);
        try std.testing.expectEqual(@as(i64, 2_000), results.items[2].ts);
        try std.testing.expectApproxEqAbs(@as(f64, 20.0), results.items[2].value, 1e-9);
        try std.testing.expectEqual(@as(i64, 2_050), results.items[3].ts);
        try std.testing.expectApproxEqAbs(@as(f64, 21.0), results.items[3].value, 1e-9);

        try std.testing.expectEqual(sid, switch (engine.resolveUniqueSeriesName("wal.rotate.series")) {
            .resolved => |resolved| resolved,
            else => return error.TestUnexpectedResult,
        });
        try std.testing.expectEqual(sid, switch (try engine.resolveExactSeries("wal.rotate.series", raw_tags)) {
            .resolved => |resolved| resolved,
            else => return error.TestUnexpectedResult,
        });
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
    var metric_catalog = try metric_catalog_mod.MetricCatalog.loadOrInit(talloc, data_dir, .none);
    defer metric_catalog.deinit();

    var cas_manager = try cas_mod.CasManager.init(talloc, data_path, .none);
    defer cas_manager.deinit();
    _ = try cas_manager.bootstrapIfMissing(data_dir, &manifest, &tags, &series_catalog, &metric_catalog);

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

test "engine surfaces drain timeouts and maintenance pause state" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/drain-timeout", .{tmp.sub_path});
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

    try pauseWriterForMaintenance(engine);
    try std.testing.expectEqual(true, engine.metrics.maintenance_pause_active.load(.monotonic));

    engine.queue.mu.lock();
    try engine.queue.buf.append(.{
        .series_id = types.hash64("drain.timeout.series"),
        .ts = 10,
        .value = 1.0,
        .tags_json = try talloc.dupe(u8, "{}"),
    });
    engine.queue.mu.unlock();

    try std.testing.expectError(WaitError.Timeout, engine.waitForDrained(1));
    try std.testing.expectEqual(@as(u64, 1), engine.metrics.drain_timeout_total.load(.monotonic));
    try resumeWriterAfterMaintenance(engine);
    try std.testing.expectEqual(false, engine.metrics.maintenance_pause_active.load(.monotonic));
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
        try std.testing.expect(engine.writer_thread != null);
        try std.testing.expectEqual(false, engine.metrics.maintenance_pause_active.load(.monotonic));
        try engine.ingest(.{ .series_id = sid, .ts = 1_010, .value = 12.0, .tags_json = "{}" });
        try engine.waitForQueryablePoints(talloc, sid, 3, 1_000);
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
        try std.testing.expect(engine.writer_thread != null);
        try std.testing.expectEqual(false, engine.metrics.maintenance_pause_active.load(.monotonic));
        try engine.ingest(.{ .series_id = sid, .ts = 2_000, .value = 3.0, .tags_json = "{}" });
        try engine.waitForQueryablePoints(talloc, sid, 3, 1_000);
        try std.testing.expectEqual(@as(usize, 1), engine.metadata.manifest.entries.items.len);

        var results = std.array_list.Managed(types.Point).init(talloc);
        defer results.deinit();
        try engine.queryRange(sid, 0, 10_000, &results);
        try std.testing.expectEqual(@as(usize, 3), results.items.len);
        try std.testing.expectEqual(@as(i64, 1_000), results.items[0].ts);
        try std.testing.expectApproxEqAbs(@as(f64, 2.0), results.items[1].value, 1e-9);
        try std.testing.expectApproxEqAbs(@as(f64, 3.0), results.items[2].value, 1e-9);
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
