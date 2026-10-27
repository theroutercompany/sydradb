const std = @import("std");
const cfg = @import("config.zig");
const types = @import("types.zig");
const AtomicU64 = @import("atomic_util.zig").AtomicU64;
const crash_injection = @import("storage/crash_injection.zig");
const manifest_mod = @import("storage/manifest.zig");
const market_catalog_mod = @import("storage/market_catalog.zig");
const market_compact_mod = @import("storage/market_compact.zig");
const market_identity_mod = @import("storage/market_identity.zig");
const market_manifest_mod = @import("storage/market_manifest.zig");
const market_memtable_mod = @import("storage/market_memtable.zig");
const market_migration_mod = @import("storage/market_migration.zig");
const market_reader_mod = @import("storage/market_reader.zig");
const market_runtime_mod = @import("storage/market_runtime.zig");
const market_segment_mod = @import("storage/market_segment.zig");
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

fn recoverInterruptedMarketPromotionFiles(
    alloc: std.mem.Allocator,
    data_path: []const u8,
    fsync: cfg.FsyncPolicy,
) !bool {
    var data_dir = std.fs.cwd().openDir(data_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer data_dir.close();

    var state = try market_migration_mod.MigrationState.loadOrInit(alloc, data_dir);
    defer state.deinit();
    if (state.phase != .promoting) return false;

    var cas = try cas_mod.CasManager.init(alloc, data_path, fsync);
    defer cas.deinit();
    _ = try cas.promoteFormatForNativeMarket();

    var catalog = try market_catalog_mod.Catalog.loadOrInit(alloc, data_dir, fsync);
    defer catalog.deinit();
    _ = try catalog.promoteAllSchemasToNative();
    return true;
}

const failed_ingest_quarantine_dir = "quarantine";
const failed_ingest_quarantine_path = "quarantine/failed_ingest.jsonl";

pub const Engine = struct {
    alloc: std.mem.Allocator,
    config: cfg.Config,
    data_dir: std.fs.Dir,
    repository_format: cas_mod.RepositoryFormat,
    wal: wal_mod.WAL,
    mem: MemTable,
    market_mem: market_memtable_mod.MarketMemtable,
    market_manifest: market_manifest_mod.Manifest,
    market_mem_allocated_bytes: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    market_mem_resident_bytes: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    next_market_write_sequence: u64 = 1,
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
    market_data_mu: std.Thread.Mutex = .{},
    tag_index_dirty: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    drain_mu: std.Thread.Mutex = .{},
    drain_cv: std.Thread.Condition = .{},
    drain_generation: u64 = 0,
    queue_empty_generation: u64 = 0,
    flush_generation: u64 = 0,
    flush_in_progress: bool = false,
    flush_requested: bool = false,
    flush_publication_error: ?anyerror = null,
    market_writer_fault: ?MarketWriterFault = null,

    const MarketWriterFault = enum {
        wal_append,
        native_apply_after_fanout,
    };

    pub const SelectorLookup = union(enum) {
        by_id: types.SeriesId,
        name: []const u8,
        exact: struct {
            series: []const u8,
            tags_json: []const u8,
        },
    };

    pub const SimpleSelectorLookup = union(enum) {
        by_id: types.SeriesId,
        name: []const u8,
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
        has_market_identity: bool = false,

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
            new_catalog_builtin_mapping: market_catalog_mod.StorageMapping,
        ) !MetadataState {
            if (config.metadata_read_mode == .primary and cas_manager != null) {
                if (try cas_manager.?.refs.readHead(cas_mod.main_ref) != null) {
                    return try loadFromCas(alloc, data_dir, config.fsync, cas_manager.?);
                }
            }
            return try loadFromLegacy(
                alloc,
                data_dir,
                config.fsync,
                wal,
                cas_manager,
                new_catalog_builtin_mapping,
            );
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

        /// Copies snapshot-backed strings before releasing cas_index_mu.
        pub fn resolveSimpleSelectorOwnedFromCas(
            self: *MetadataState,
            allocator: std.mem.Allocator,
            lookup: SimpleSelectorLookup,
        ) std.mem.Allocator.Error!?series_catalog_mod.Resolution {
            self.cas_index_mu.lock();
            defer self.cas_index_mu.unlock();
            if (self.cas_index) |*index| {
                const resolution = switch (lookup) {
                    .by_id => |series_id| index.resolveBySeriesId(series_id),
                    .name => |series| index.resolveUniqueSeriesNameDetailed(series),
                };
                return try cloneSelectorResolution(allocator, resolution);
            }
            return null;
        }

        pub fn simpleSelectorMatchesFromCas(
            self: *MetadataState,
            lookup: SimpleSelectorLookup,
            expected: series_catalog_mod.Resolution,
        ) ?bool {
            self.cas_index_mu.lock();
            defer self.cas_index_mu.unlock();
            if (self.cas_index) |*index| {
                const resolution = switch (lookup) {
                    .by_id => |series_id| index.resolveBySeriesId(series_id),
                    .name => |series| index.resolveUniqueSeriesNameDetailed(series),
                };
                return resolutionsEqual(expected, resolution);
            }
            return null;
        }

        pub fn exactSelectorMatchesFromCas(
            self: *MetadataState,
            series: []const u8,
            tags_json: []const u8,
            expected: series_catalog_mod.Resolution,
        ) !?bool {
            self.cas_index_mu.lock();
            defer self.cas_index_mu.unlock();
            if (self.cas_index) |*index| {
                const resolution = try index.resolveExactSeriesDetailed(series, tags_json);
                return resolutionsEqual(expected, resolution);
            }
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
            new_catalog_builtin_mapping: market_catalog_mod.StorageMapping,
        ) !MetadataState {
            var manifest = try manifest_mod.Manifest.loadOrInit(alloc, data_dir);
            errdefer manifest.deinit();
            var tags = try tags_mod.TagIndex.loadOrInit(alloc, data_dir);
            errdefer tags.deinit();
            var series_catalog = try loadSeriesCatalogWithRepair(alloc, data_dir, fsync, &manifest, wal, cas_manager);
            errdefer series_catalog.deinit();
            var metric_catalog = try metric_catalog_mod.MetricCatalog.loadOrInit(alloc, data_dir, fsync);
            errdefer metric_catalog.deinit();
            var market_catalog = try market_catalog_mod.Catalog.loadOrInitWithOptions(
                alloc,
                data_dir,
                fsync,
                .{ .new_catalog_builtin_mapping = new_catalog_builtin_mapping },
            );
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

    pub const MarketStorageWriteMode = enum {
        fanout_v1,
        dual_write_v1,
        native_v1,
    };

    pub const MarketIngestInput = struct {
        metric: []const u8,
        labels_json: []const u8,
        ts_ns: i64,
        values: []const f64,
    };

    pub const MarketIngestReceipt = struct {
        /// A receipt is returned only after the ordered writer has appended the
        /// batch to the WAL and applied it to the live memtable(s). With
        /// `fsync=always`, the WAL append has also completed its file sync.
        /// `interval` acknowledges after append and remains vulnerable until
        /// the next configured interval sync; `none` delegates persistence to
        /// the operating system and provides no bounded crash window.
        accepted_rows: usize,
        storage_mode: MarketStorageWriteMode,
        native_rows: usize,
        fanout_writes: usize,
        queue_depth: usize,
        pending_bytes: usize,
    };

    pub const MarketQueryRequest = struct {
        metric: []const u8,
        label_filter_json: ?[]const u8 = null,
        start_ts_ns: i64,
        end_ts_ns: i64,
        /// Empty selects every schema column in stored order.
        requested_columns: []const []const u8 = &.{},
        /// A CAS commit, ref, or other revision spec accepted by CasManager.
        revision: ?[]const u8 = null,
    };

    pub const MarketQueryStats = struct {
        storage_mode: []const u8,
        series_scanned: u64 = 0,
        blocks_scanned: u64 = 0,
        blocks_pruned: u64 = 0,
        columns_read: u64 = 0,
        bytes_decoded: u64 = 0,
        shadow_mismatches: u64 = 0,
    };

    pub const MarketQueryRow = struct {
        market_series_id: market_identity_mod.MarketSeriesId,
        metric: []u8,
        canonical_labels: []u8,
        ts_ns: i64,
        values: []f64,

        pub fn deinit(self: *MarketQueryRow, alloc: std.mem.Allocator) void {
            alloc.free(self.metric);
            alloc.free(self.canonical_labels);
            alloc.free(self.values);
            self.* = undefined;
        }
    };

    pub const MarketQueryResult = struct {
        allocator: std.mem.Allocator,
        metric: []u8,
        requested_columns: [][]u8,
        rows: []MarketQueryRow,
        stats: MarketQueryStats,

        pub fn deinit(self: *MarketQueryResult) void {
            self.allocator.free(self.metric);
            for (self.requested_columns) |column| self.allocator.free(column);
            self.allocator.free(self.requested_columns);
            for (self.rows) |*row| row.deinit(self.allocator);
            self.allocator.free(self.rows);
            self.* = undefined;
        }
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

    const PreparedStringTagPair = struct {
        label: []const u8,
        value: []const u8,
    };

    const PreparedExactSeriesCanonicalDeclarationInput = struct {
        name: []const u8,
        canonical_tags: []const u8,
        selector_key: []const u8,
        series_id: types.SeriesId,
        descriptor: ?metric_catalog_mod.DescriptorInput = null,
        tag_pairs: []PreparedStringTagPair,
        tag_pairs_owned: bool = false,

        fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
            alloc.free(self.selector_key);
            if (self.tag_pairs_owned) {
                for (self.tag_pairs) |pair| {
                    alloc.free(@constCast(pair.label));
                    alloc.free(@constCast(pair.value));
                }
            }
            alloc.free(self.tag_pairs);
            self.* = undefined;
        }
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

    fn addQueuedBytes(total: *usize, amount: usize) !void {
        total.* = std.math.add(usize, total.*, amount) catch return error.ResidentByteOverflow;
    }

    fn mulQueuedBytes(count: usize, size: usize) !usize {
        return std.math.mul(usize, count, size) catch return error.ResidentByteOverflow;
    }

    const MarketBatchCompletion = struct {
        alloc: std.mem.Allocator,
        refs: std.atomic.Value(usize) = std.atomic.Value(usize).init(1),
        mu: std.Thread.Mutex = .{},
        cv: std.Thread.Condition = .{},
        done: bool = false,
        failure: ?anyerror = null,

        fn create(alloc: std.mem.Allocator) !*MarketBatchCompletion {
            const completion = try alloc.create(MarketBatchCompletion);
            completion.* = .{ .alloc = alloc };
            return completion;
        }

        fn retain(self: *MarketBatchCompletion) void {
            _ = self.refs.fetchAdd(1, .monotonic);
        }

        fn release(self: *MarketBatchCompletion) void {
            if (self.refs.fetchSub(1, .acq_rel) == 1) {
                self.alloc.destroy(self);
            }
        }

        fn complete(self: *MarketBatchCompletion, failure: ?anyerror) void {
            self.mu.lock();
            if (!self.done) {
                self.failure = failure;
                self.done = true;
                self.cv.broadcast();
            }
            self.mu.unlock();
        }

        fn wait(self: *MarketBatchCompletion) !void {
            self.mu.lock();
            defer self.mu.unlock();
            while (!self.done) self.cv.wait(&self.mu);
            if (self.failure) |failure| return failure;
        }
    };

    const QueuedMarketRow = struct {
        market_series_id: market_identity_mod.MarketSeriesId,
        schema_digest: market_identity_mod.SchemaDigest,
        metric: []u8,
        canonical_labels: []u8,
        ts_ns: i64,
        values: []f64,

        fn deinit(self: *QueuedMarketRow, alloc: std.mem.Allocator) void {
            alloc.free(self.metric);
            alloc.free(self.canonical_labels);
            alloc.free(self.values);
            self.* = undefined;
        }

        fn payloadBytes(self: QueuedMarketRow) !usize {
            var total: usize = 0;
            try addQueuedBytes(&total, self.metric.len);
            try addQueuedBytes(&total, self.canonical_labels.len);
            try addQueuedBytes(&total, try mulQueuedBytes(self.values.len, @sizeOf(f64)));
            return total;
        }
    };

    const QueuedMarketBatch = struct {
        rows: []QueuedMarketRow,
        mode: MarketStorageWriteMode,
        fanout_series_ids: [][]types.SeriesId,
        fanout_values: [][]f64,
        completion: ?*MarketBatchCompletion = null,

        fn deinit(self: *QueuedMarketBatch, alloc: std.mem.Allocator) void {
            for (self.rows) |*row| row.deinit(alloc);
            alloc.free(self.rows);
            for (self.fanout_series_ids) |series_ids| alloc.free(series_ids);
            alloc.free(self.fanout_series_ids);
            for (self.fanout_values) |values| alloc.free(values);
            alloc.free(self.fanout_values);
            if (self.completion) |completion| {
                completion.complete(error.Closed);
                completion.release();
            }
            self.* = undefined;
        }

        fn queuedBytes(self: QueuedMarketBatch) !usize {
            var total: usize = @sizeOf(QueuedMarketBatch);
            try addQueuedBytes(&total, try mulQueuedBytes(self.rows.len, @sizeOf(QueuedMarketRow)));
            try addQueuedBytes(&total, try mulQueuedBytes(self.fanout_series_ids.len, @sizeOf([]types.SeriesId)));
            try addQueuedBytes(&total, try mulQueuedBytes(self.fanout_values.len, @sizeOf([]f64)));
            for (self.rows) |row| try addQueuedBytes(&total, try row.payloadBytes());
            for (self.fanout_series_ids) |series_ids| {
                try addQueuedBytes(&total, try mulQueuedBytes(series_ids.len, @sizeOf(types.SeriesId)));
            }
            for (self.fanout_values) |values| {
                try addQueuedBytes(&total, try mulQueuedBytes(values.len, @sizeOf(f64)));
            }
            return total;
        }
    };

    const QueuedPayload = union(enum) {
        scalar: []ResolvedIngestPoint,
        market: QueuedMarketBatch,

        fn len(self: QueuedPayload) usize {
            return switch (self) {
                .scalar => |points| points.len,
                .market => |batch| batch.rows.len,
            };
        }
    };

    const QueuedBatch = struct {
        payload: QueuedPayload,
        bytes: usize,

        fn deinit(self: *QueuedBatch, alloc: std.mem.Allocator) void {
            switch (self.payload) {
                .scalar => |points| alloc.free(points),
                .market => |*batch| batch.deinit(alloc),
            }
            self.* = undefined;
        }
    };

    const FanoutMemtableCheckpoint = struct {
        series_id: types.SeriesId,
        existed: bool,
        old_len: usize,
        old_sorted: bool,
        old_last_ts: ?i64,
    };

    const MarketReplayRegistration = struct {
        schema_digest: market_identity_mod.SchemaDigest,
        metric: []u8,
        canonical_labels: []u8,
        column_count: usize,

        fn deinit(self: *MarketReplayRegistration, alloc: std.mem.Allocator) void {
            alloc.free(self.metric);
            alloc.free(self.canonical_labels);
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
        in_flight_batches: usize = 0,
        closed: bool = false,
        wake_requested: bool = false,
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
                .payload = .{ .scalar = owned_points },
                .bytes = @sizeOf(ResolvedIngestPoint),
            });
        }
        pub fn pushBatch(self: *Queue, points: []const ResolvedIngestPoint) !void {
            if (points.len == 0) return;
            const owned_points = try self.alloc.dupe(ResolvedIngestPoint, points);
            errdefer self.alloc.free(owned_points);
            return self.pushOwned(.{
                .payload = .{ .scalar = owned_points },
                .bytes = points.len * @sizeOf(ResolvedIngestPoint),
            });
        }
        fn pushMarketBatch(self: *Queue, batch: QueuedMarketBatch, bytes: usize) !void {
            return self.pushOwned(.{
                .payload = .{ .market = batch },
                .bytes = bytes,
            });
        }
        fn beginMarketPushReservation(self: *Queue, row_count: usize, bytes: usize) !void {
            self.mu.lock();
            errdefer self.mu.unlock();
            if (self.closed) return error.Closed;
            try self.ensureCapacity(self.count + 1);
            _ = std.math.add(usize, self.pending_points, row_count) catch return error.ResidentByteOverflow;
            _ = std.math.add(usize, self.pending_bytes, bytes) catch return error.ResidentByteOverflow;
        }
        fn cancelMarketPushReservation(self: *Queue) void {
            self.mu.unlock();
        }
        fn commitMarketPushReservation(self: *Queue, batch: QueuedMarketBatch, bytes: usize) void {
            std.debug.assert(!self.closed);
            std.debug.assert(self.count < self.buf.len);
            const insert_idx = (self.head + self.count) % self.buf.len;
            self.buf[insert_idx] = .{
                .payload = .{ .market = batch },
                .bytes = bytes,
            };
            self.count += 1;
            self.pending_points += batch.rows.len;
            self.pending_bytes += bytes;
            self.cv.signal();
            self.mu.unlock();
        }
        fn reserveOne(self: *Queue) !void {
            self.mu.lock();
            defer self.mu.unlock();
            if (self.closed) return error.Closed;
            try self.ensureCapacity(self.count + 1);
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
            const next_pending_points = std.math.add(usize, self.pending_points, batch.payload.len()) catch return error.ResidentByteOverflow;
            const next_pending_bytes = std.math.add(usize, self.pending_bytes, batch.bytes) catch return error.ResidentByteOverflow;
            const insert_idx = if (self.buf.len == 0) 0 else (self.head + self.count) % self.buf.len;
            self.buf[insert_idx] = batch;
            self.count += 1;
            self.pending_points = next_pending_points;
            self.pending_bytes = next_pending_bytes;
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
            while (self.count == 0 and !self.closed and !self.wake_requested) {
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
                self.wake_requested = false;
                const release_ns = std.time.nanoTimestamp();
                const hold_ns = release_ns - hold_start_ns;
                _ = self.metrics.queue_pop_lock_hold_ns_total.fetchAdd(@as(u64, @intCast(hold_ns)), .monotonic);
                self.mu.unlock();
                return null;
            }
            const batch = self.buf[self.head];
            self.head = if (self.buf.len == 0) 0 else (self.head + 1) % self.buf.len;
            self.count -= 1;
            self.pending_points -= batch.payload.len();
            self.pending_bytes -= batch.bytes;
            self.in_flight_batches += 1;
            self.wake_requested = false;
            if (self.count == 0) self.head = 0;
            const release_ns = std.time.nanoTimestamp();
            const hold_ns = release_ns - hold_start_ns;
            _ = self.metrics.queue_pop_lock_hold_ns_total.fetchAdd(@as(u64, @intCast(hold_ns)), .monotonic);
            self.mu.unlock();
            return batch;
        }
        pub fn completeBatch(self: *Queue) void {
            self.mu.lock();
            std.debug.assert(self.in_flight_batches > 0);
            self.in_flight_batches -= 1;
            self.mu.unlock();
        }
        pub fn isDrained(self: *Queue) bool {
            self.mu.lock();
            defer self.mu.unlock();
            return self.pending_points == 0 and self.in_flight_batches == 0;
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
            self.wake_requested = false;
            self.mu.unlock();
        }
        fn wake(self: *Queue) void {
            self.mu.lock();
            self.wake_requested = true;
            self.cv.signal();
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
        market_shadow_mismatch_total: AtomicU64,
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
        exact_series_declare_selector_key_ns_total: AtomicU64,
        exact_series_declare_tag_pairs_total: AtomicU64,
        exact_series_declare_inserted_total: AtomicU64,
        exact_series_declare_unchanged_total: AtomicU64,
        exact_series_declare_descriptor_conflict_total: AtomicU64,
        exact_series_declare_series_conflict_total: AtomicU64,
        flush_queue_drain_wait_ns_total: AtomicU64,
        flush_manifest_ns_total: AtomicU64,
        flush_segment_write_ns_total: AtomicU64,
        flush_selector_metadata_ns_total: AtomicU64,
        flush_segments_written_total: AtomicU64,
        flush_series_buckets_total: AtomicU64,
        flush_hour_slices_total: AtomicU64,

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
                .market_shadow_mismatch_total = AtomicU64.init(0),
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
                .exact_series_declare_selector_key_ns_total = AtomicU64.init(0),
                .exact_series_declare_tag_pairs_total = AtomicU64.init(0),
                .exact_series_declare_inserted_total = AtomicU64.init(0),
                .exact_series_declare_unchanged_total = AtomicU64.init(0),
                .exact_series_declare_descriptor_conflict_total = AtomicU64.init(0),
                .exact_series_declare_series_conflict_total = AtomicU64.init(0),
                .flush_queue_drain_wait_ns_total = AtomicU64.init(0),
                .flush_manifest_ns_total = AtomicU64.init(0),
                .flush_segment_write_ns_total = AtomicU64.init(0),
                .flush_selector_metadata_ns_total = AtomicU64.init(0),
                .flush_segments_written_total = AtomicU64.init(0),
                .flush_series_buckets_total = AtomicU64.init(0),
                .flush_hour_slices_total = AtomicU64.init(0),
            };
        }
    };

    pub fn init(alloc: std.mem.Allocator, config: cfg.Config) !*Engine {
        if (config.metadata_read_mode != .legacy and config.cas_mode == .off) {
            return error.CasReadModeRequiresCas;
        }
        var repository_probe = try cas_mod.probeOrInitRepositoryFormatWithState(
            alloc,
            config.data_dir,
            config.fsync,
        );
        if (try recoverInterruptedMarketPromotionFiles(
            alloc,
            config.data_dir,
            config.fsync,
        )) {
            repository_probe = try cas_mod.probeOrInitRepositoryFormatWithState(
                alloc,
                config.data_dir,
                config.fsync,
            );
        }
        try validateConfiguredMarketStorage(config, repository_probe.format);

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
        var metadata = try MetadataState.load(
            alloc,
            data_dir,
            config,
            &wal,
            if (cas_manager) |*cas| cas else null,
            if (repository_probe.fresh_repository and
                repository_probe.format.version == cas_mod.current_repository_format_version)
                .native_v1
            else
                .fanout_v1,
        );
        var metadata_transferred = false;
        errdefer if (!metadata_transferred) metadata.deinit();
        var market_manifest = try market_manifest_mod.Manifest.loadOrEmpty(alloc, data_dir);
        var market_manifest_transferred = false;
        errdefer if (!market_manifest_transferred) market_manifest.deinit();

        var engine = try alloc.create(Engine);
        errdefer alloc.destroy(engine);
        engine.* = .{
            .alloc = alloc,
            .config = config,
            .data_dir = data_dir,
            .repository_format = repository_probe.format,
            .wal = wal,
            .mem = MemTable.init(alloc),
            .market_mem = market_memtable_mod.MarketMemtable.init(alloc),
            .market_manifest = market_manifest,
            .market_mem_allocated_bytes = std.atomic.Value(usize).init(0),
            .market_mem_resident_bytes = std.atomic.Value(usize).init(0),
            .next_market_write_sequence = 1,
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
        market_manifest_transferred = true;
        cas_manager_transferred = true;
        errdefer {
            for (engine.derived_dirty.items) |*item| item.deinit(engine.alloc);
            engine.derived_dirty.deinit();
            engine.market_manifest.deinit();
            engine.market_mem.deinit();
            engine.mem.deinit();
            engine.metadata.deinit();
            engine.wal.close();
            if (engine.cas) |*cas| cas.deinit();
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
            _ = try cas.bootstrapIfMissingWithNativeMarket(
                engine.data_dir,
                &engine.metadata.manifest,
                &engine.metadata.tags,
                &engine.metadata.series_catalog,
                &engine.metadata.metric_catalog,
                &engine.metadata.market_catalog,
                &engine.market_manifest,
            );
            try engine.metadata.refreshCasIndex(cas);
        }
        try engine.recover();
        try engine.finalizeInterruptedMarketPromotion();
        engine.writer_thread = try std.Thread.spawn(.{}, writerLoop, .{engine});
        engine.derived_thread = try std.Thread.spawn(.{}, derivedLoop, .{engine});
        engine.scheduleDerivedRefresh();
        return engine;
    }

    fn finalizeInterruptedMarketPromotion(self: *Engine) !void {
        var state = try market_migration_mod.MigrationState.loadOrInit(
            self.alloc,
            self.data_dir,
        );
        defer state.deinit();
        if (state.phase != .promoting) return;
        if (self.repository_format.version != cas_mod.current_repository_format_version) {
            return error.RepositoryFormatMismatch;
        }

        if (self.cas) |*cas| {
            _ = try cas.syncLegacySnapshotWithNativeMarket(
                self.data_dir,
                &self.metadata.manifest,
                &self.metadata.tags,
                &self.metadata.series_catalog,
                &self.metadata.metric_catalog,
                &self.metadata.market_catalog,
                &self.market_manifest,
                "market-storage-promotion-recovery",
            );
            try cas.verifyHeadMatchesLegacyWithNativeMarket(
                self.data_dir,
                &self.metadata.manifest,
                &self.metadata.tags,
                &self.metadata.series_catalog,
                &self.metadata.metric_catalog,
                &self.metadata.market_catalog,
                &self.market_manifest,
            );
            try self.metadata.refreshCasIndex(cas);
        } else {
            var cas = try cas_mod.CasManager.init(
                self.alloc,
                self.config.data_dir,
                self.config.fsync,
            );
            defer cas.deinit();
            _ = try cas.syncLegacySnapshotWithNativeMarket(
                self.data_dir,
                &self.metadata.manifest,
                &self.metadata.tags,
                &self.metadata.series_catalog,
                &self.metadata.metric_catalog,
                &self.metadata.market_catalog,
                &self.market_manifest,
                "market-storage-promotion-recovery",
            );
            try cas.verifyHeadMatchesLegacyWithNativeMarket(
                self.data_dir,
                &self.metadata.manifest,
                &self.metadata.tags,
                &self.metadata.series_catalog,
                &self.metadata.metric_catalog,
                &self.metadata.market_catalog,
                &self.market_manifest,
            );
        }

        _ = try state.advance(.promoted);
        try state.saveAtomically(self.data_dir);
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
        self.market_manifest.deinit();
        self.market_mem.deinit();
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
        try self.wal.sync();
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
            const resident_bytes = self.admissionMemtableBytes() + queued_bytes + batch_bytes;
            if (resident_bytes >= self.config.mem_limit_bytes) {
                _ = self.metrics.ingest_rejected_total.fetchAdd(1, .monotonic);
                _ = self.metrics.ingest_rejected_mem_limit_total.fetchAdd(1, .monotonic);
                return error.MemoryLimitExceeded;
            }
        }
        try self.queue.pushBatch(points);
        self.noteQueueBecameNonEmpty();
        self.recordQueueSample();
        const len_now = self.queue.len();
        const pending_bytes_now = self.queue.pendingBytes();
        return .{
            .accepted_points = points.len,
            .queue_depth = len_now,
            .pending_bytes = pending_bytes_now,
        };
    }

    fn recordQueueSample(self: *Engine) void {
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
    }

    fn liveMemtableBytes(self: *Engine) usize {
        return self.mem.bytes.load(.monotonic) + self.market_mem_resident_bytes.load(.monotonic);
    }

    fn admissionMemtableBytes(self: *Engine) usize {
        return self.mem.bytes.load(.monotonic) + self.market_mem_allocated_bytes.load(.monotonic);
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

    pub fn ingestMarketBatch(self: *Engine, rows: []const MarketIngestInput) !MarketIngestReceipt {
        return try self.appendMarketRows(rows);
    }

    pub fn appendMarketRows(self: *Engine, rows: []const MarketIngestInput) !MarketIngestReceipt {
        if (rows.len == 0) {
            return .{
                .accepted_rows = 0,
                .storage_mode = .fanout_v1,
                .native_rows = 0,
                .fanout_writes = 0,
                .queue_depth = self.queue.len(),
                .pending_bytes = self.queue.pendingBytes(),
            };
        }

        var preflight_schemas = try self.alloc.alloc(market_catalog_mod.MarketSchema, rows.len);
        var preflight_schema_count: usize = 0;
        defer {
            for (preflight_schemas[0..preflight_schema_count]) |*schema| schema.deinit(self.alloc);
            self.alloc.free(preflight_schemas);
        }
        var preflight_labels = try self.alloc.alloc([]u8, rows.len);
        var preflight_label_count: usize = 0;
        defer {
            for (preflight_labels[0..preflight_label_count]) |labels| self.alloc.free(labels);
            self.alloc.free(preflight_labels);
        }
        const preflight_modes = try self.alloc.alloc(MarketStorageWriteMode, rows.len);
        defer self.alloc.free(preflight_modes);
        const preflight_market_registrations = try self.alloc.alloc(market_catalog_mod.MarketSeriesRegistrationInput, rows.len);
        defer self.alloc.free(preflight_market_registrations);

        var resolved_mode: ?MarketStorageWriteMode = null;
        var preflight_queued_bytes: usize = @sizeOf(QueuedMarketBatch);
        try addQueuedBytes(&preflight_queued_bytes, try mulQueuedBytes(rows.len, @sizeOf(QueuedMarketRow)));
        try addQueuedBytes(&preflight_queued_bytes, try mulQueuedBytes(rows.len, @sizeOf([]types.SeriesId)));
        try addQueuedBytes(&preflight_queued_bytes, try mulQueuedBytes(rows.len, @sizeOf([]f64)));
        var fanout_declaration_count: usize = 0;
        for (rows, 0..) |row, row_idx| {
            var schema = self.marketSchema(row.metric) orelse return error.UnknownMarketSchema;
            errdefer schema.deinit(self.alloc);
            try market_identity_mod.validateValueShape(schema.ordered_columns.len, row.values.len);

            const canonical_labels = try market_identity_mod.canonicalizeLabels(self.alloc, row.labels_json);
            errdefer self.alloc.free(canonical_labels);
            try market_identity_mod.validateRequiredLabels(
                self.alloc,
                canonical_labels,
                schema.required_labels,
            );

            const mode = try self.resolveMarketWriteMode(schema);
            if (resolved_mode) |previous| {
                if (previous != mode) return error.MixedMarketStorageModes;
            } else {
                resolved_mode = mode;
            }
            const value_bytes = std.math.mul(usize, row.values.len, @sizeOf(f64)) catch return error.ResidentByteOverflow;
            try addQueuedBytes(&preflight_queued_bytes, row.metric.len);
            try addQueuedBytes(&preflight_queued_bytes, canonical_labels.len);
            try addQueuedBytes(&preflight_queued_bytes, value_bytes);
            const needs_fanout = mode == .fanout_v1 or mode == .dual_write_v1;
            if (needs_fanout) {
                fanout_declaration_count = std.math.add(usize, fanout_declaration_count, schema.ordered_columns.len) catch return error.ResidentByteOverflow;
                try addQueuedBytes(&preflight_queued_bytes, try mulQueuedBytes(schema.ordered_columns.len, @sizeOf(types.SeriesId)));
                try addQueuedBytes(&preflight_queued_bytes, value_bytes);
            }

            preflight_schemas[row_idx] = schema;
            preflight_schema_count += 1;
            preflight_labels[row_idx] = canonical_labels;
            preflight_label_count += 1;
            preflight_modes[row_idx] = mode;
            preflight_market_registrations[row_idx] = .{
                .series_id = market_identity_mod.seriesId(row.metric, canonical_labels),
                .metric = row.metric,
                .canonical_labels = canonical_labels,
            };
        }

        const mode = resolved_mode orelse .fanout_v1;
        if (self.config.mem_limit_bytes != 0) {
            const queued_payload_bytes = if (mode == .fanout_v1)
                try mulQueuedBytes(fanout_declaration_count, @sizeOf(ResolvedIngestPoint))
            else
                preflight_queued_bytes;
            var resident_bytes = self.admissionMemtableBytes();
            try addQueuedBytes(&resident_bytes, self.queue.pendingBytes());
            try addQueuedBytes(&resident_bytes, queued_payload_bytes);
            if (resident_bytes >= self.config.mem_limit_bytes) {
                _ = self.metrics.ingest_rejected_total.fetchAdd(1, .monotonic);
                _ = self.metrics.ingest_rejected_mem_limit_total.fetchAdd(1, .monotonic);
                return error.MemoryLimitExceeded;
            }
        }

        var fanout_points = std.array_list.Managed(ResolvedIngestPoint).init(self.alloc);
        defer fanout_points.deinit();

        var queued_rows = try self.alloc.alloc(QueuedMarketRow, rows.len);
        var queued_rows_initialized: usize = 0;
        var queued_rows_owned = true;
        errdefer if (queued_rows_owned) {
            for (queued_rows[0..queued_rows_initialized]) |*row| row.deinit(self.alloc);
            self.alloc.free(queued_rows);
        };

        var fanout_series_ids = try self.alloc.alloc([]types.SeriesId, rows.len);
        var fanout_series_ids_initialized: usize = 0;
        var fanout_series_ids_owned = true;
        errdefer if (fanout_series_ids_owned) {
            for (fanout_series_ids[0..fanout_series_ids_initialized]) |series_ids| self.alloc.free(series_ids);
            self.alloc.free(fanout_series_ids);
        };

        var fanout_values = try self.alloc.alloc([]f64, rows.len);
        var fanout_values_initialized: usize = 0;
        var fanout_values_owned = true;
        errdefer if (fanout_values_owned) {
            for (fanout_values[0..fanout_values_initialized]) |values| self.alloc.free(values);
            self.alloc.free(fanout_values);
        };

        var queued_bytes: usize = 0;
        var native_rows: usize = 0;
        var fanout_writes: usize = 0;

        for (rows, 0..) |row, row_idx| {
            const schema = preflight_schemas[row_idx];
            const row_mode = preflight_modes[row_idx];

            const needs_native = row_mode == .native_v1 or row_mode == .dual_write_v1;
            const needs_fanout = row_mode == .fanout_v1 or row_mode == .dual_write_v1;

            const metric_copy = try self.alloc.dupe(u8, row.metric);
            errdefer self.alloc.free(metric_copy);
            const labels_copy = try self.alloc.dupe(u8, preflight_labels[row_idx]);
            errdefer self.alloc.free(labels_copy);
            const value_copy = try self.alloc.dupe(f64, row.values);
            errdefer self.alloc.free(value_copy);

            queued_rows[row_idx] = .{
                .market_series_id = preflight_market_registrations[row_idx].series_id,
                .schema_digest = schema.digest(),
                .metric = metric_copy,
                .canonical_labels = labels_copy,
                .ts_ns = row.ts_ns,
                .values = value_copy,
            };
            queued_rows_initialized += 1;
            queued_bytes = try std.math.add(usize, queued_bytes, try queued_rows[row_idx].payloadBytes());
            if (needs_native) native_rows += 1;

            const series_ids = try self.alloc.alloc(types.SeriesId, if (needs_fanout) schema.ordered_columns.len else 0);
            fanout_series_ids[row_idx] = series_ids;
            fanout_series_ids_initialized += 1;
            const values = try self.alloc.dupe(f64, if (needs_fanout) row.values else &[_]f64{});
            fanout_values[row_idx] = values;
            fanout_values_initialized += 1;
        }

        const fanout_declarations = try self.alloc.alloc(ExactSeriesCanonicalDeclarationInput, fanout_declaration_count);
        defer self.alloc.free(fanout_declarations);
        const fanout_metric_names = try self.alloc.alloc([]u8, fanout_declaration_count);
        var fanout_metric_name_count: usize = 0;
        defer {
            for (fanout_metric_names[0..fanout_metric_name_count]) |name| self.alloc.free(name);
            self.alloc.free(fanout_metric_names);
        }
        const fanout_results = try self.alloc.alloc(ExactSeriesBatchDeclarationResult, fanout_declaration_count);
        defer self.alloc.free(fanout_results);

        var fanout_declaration_idx: usize = 0;
        for (rows, 0..) |row, row_idx| {
            const schema = preflight_schemas[row_idx];
            const row_mode = preflight_modes[row_idx];
            const needs_fanout = row_mode == .fanout_v1 or row_mode == .dual_write_v1;
            if (!needs_fanout) continue;
            for (schema.ordered_columns) |column| {
                const derived_metric = try std.fmt.allocPrint(self.alloc, "{s}.{s}", .{ row.metric, column });
                fanout_metric_names[fanout_metric_name_count] = derived_metric;
                fanout_metric_name_count += 1;
                fanout_declarations[fanout_declaration_idx] = .{
                    .name = derived_metric,
                    .canonical_tags = preflight_labels[row_idx],
                    .descriptor = .{
                        .metric = derived_metric,
                        .kind = .gauge,
                        .source_metric = row.metric,
                        .source_field = column,
                    },
                };
                fanout_declaration_idx += 1;
            }
        }
        std.debug.assert(fanout_declaration_idx == fanout_declaration_count);

        try fanout_points.ensureTotalCapacity(fanout_declaration_count);
        try self.preflightMarketFanoutDeclarations(fanout_declarations);
        const reserved_market_batch = QueuedMarketBatch{
            .rows = queued_rows,
            .mode = mode,
            .fanout_series_ids = fanout_series_ids,
            .fanout_values = fanout_values,
        };
        const batch_queued_bytes = try reserved_market_batch.queuedBytes();
        const completion = if (mode == .fanout_v1)
            null
        else
            try MarketBatchCompletion.create(self.alloc);
        defer if (completion) |pending| pending.release();
        var market_queue_reserved = false;
        defer if (market_queue_reserved) self.queue.cancelMarketPushReservation();
        if (mode != .fanout_v1) {
            try self.queue.beginMarketPushReservation(rows.len, batch_queued_bytes);
            market_queue_reserved = true;
        }

        const market_identities = try self.metadata.market_catalog.registerCanonicalMarketSeriesBatch(preflight_market_registrations);
        defer {
            for (market_identities) |*identity| identity.deinit(self.alloc);
            self.alloc.free(market_identities);
        }
        for (market_identities, queued_rows[0..queued_rows_initialized]) |identity, queued| {
            if (identity.series_id != queued.market_series_id) return error.MarketSeriesIdMismatch;
            if (!std.mem.eql(u8, identity.schema_digest[0..], queued.schema_digest[0..])) return error.MarketSchemaConflict;
            if (!std.mem.eql(u8, identity.metric, queued.metric)) return error.MarketSeriesConflict;
            if (!std.mem.eql(u8, identity.canonical_labels, queued.canonical_labels)) return error.MarketSeriesConflict;
        }

        if (fanout_declaration_count != 0) {
            try self.declareExactSeriesCanonicalBatch(fanout_declarations, fanout_results);
            for (fanout_results) |result| {
                switch (result.status) {
                    .ok => {},
                    .metric_descriptor_conflict => return error.MetricDescriptorConflict,
                    .series_conflict => return error.SeriesIdConflict,
                }
            }

            fanout_declaration_idx = 0;
            for (rows, 0..) |row, row_idx| {
                const schema = preflight_schemas[row_idx];
                const row_mode = preflight_modes[row_idx];
                const needs_fanout = row_mode == .fanout_v1 or row_mode == .dual_write_v1;
                if (!needs_fanout) continue;
                for (schema.ordered_columns, 0..) |_, column_idx| {
                    const series_id = fanout_results[fanout_declaration_idx].series_id orelse return error.SeriesIdConflict;
                    fanout_series_ids[row_idx][column_idx] = series_id;
                    if (row_mode == .fanout_v1) {
                        fanout_points.appendAssumeCapacity(.{
                            .series_id = series_id,
                            .ts = row.ts_ns,
                            .value = row.values[column_idx],
                        });
                    }
                    fanout_declaration_idx += 1;
                }
            }
            fanout_writes = fanout_declaration_count;
        }

        if (mode == .fanout_v1) {
            _ = try self.appendResolvedBatch(fanout_points.items);
            for (queued_rows[0..queued_rows_initialized]) |*queued| queued.deinit(self.alloc);
            self.alloc.free(queued_rows);
            queued_rows_initialized = 0;
            queued_rows_owned = false;
            for (fanout_series_ids[0..fanout_series_ids_initialized]) |series_ids| self.alloc.free(series_ids);
            self.alloc.free(fanout_series_ids);
            fanout_series_ids_initialized = 0;
            fanout_series_ids_owned = false;
            for (fanout_values[0..fanout_values_initialized]) |values| self.alloc.free(values);
            self.alloc.free(fanout_values);
            fanout_values_initialized = 0;
            fanout_values_owned = false;
            return .{
                .accepted_rows = rows.len,
                .storage_mode = mode,
                .native_rows = 0,
                .fanout_writes = fanout_writes,
                .queue_depth = self.queue.len(),
                .pending_bytes = self.queue.pendingBytes(),
            };
        }

        completion.?.retain();
        const batch = QueuedMarketBatch{
            .rows = queued_rows,
            .mode = mode,
            .fanout_series_ids = fanout_series_ids,
            .fanout_values = fanout_values,
            .completion = completion.?,
        };
        std.debug.assert(batch_queued_bytes >= queued_bytes);
        queued_rows_initialized = 0;
        queued_rows_owned = false;
        fanout_series_ids_initialized = 0;
        fanout_series_ids_owned = false;
        fanout_values_initialized = 0;
        fanout_values_owned = false;
        self.queue.commitMarketPushReservation(batch, batch_queued_bytes);
        market_queue_reserved = false;
        self.noteQueueBecameNonEmpty();
        self.recordQueueSample();
        try completion.?.wait();
        return .{
            .accepted_rows = rows.len,
            .storage_mode = mode,
            .native_rows = native_rows,
            .fanout_writes = fanout_writes,
            .queue_depth = self.queue.len(),
            .pending_bytes = self.queue.pendingBytes(),
        };
    }

    fn preflightMarketFanoutDeclarations(
        self: *Engine,
        declarations: []const ExactSeriesCanonicalDeclarationInput,
    ) !void {
        if (declarations.len == 0) return;

        var unique_descriptors = std.StringHashMap(metric_catalog_mod.DescriptorInput).init(self.alloc);
        defer unique_descriptors.deinit();
        var unique_series = std.AutoHashMap(types.SeriesId, usize).init(self.alloc);
        defer unique_series.deinit();

        for (declarations, 0..) |declaration, idx| {
            if (declaration.descriptor) |descriptor| {
                if (unique_descriptors.get(descriptor.metric)) |existing| {
                    if (!descriptorInputsEquivalent(existing, descriptor)) return error.MetricDescriptorConflict;
                } else {
                    if (self.metadata.metric_catalog.get(descriptor.metric)) |existing_descriptor| {
                        if (metricDescriptorWouldConflict(existing_descriptor, descriptor)) {
                            return error.MetricDescriptorConflict;
                        }
                    }
                    try unique_descriptors.put(descriptor.metric, descriptor);
                }
            }

            const series_id = types.seriesIdFrom(declaration.name, declaration.canonical_tags);
            if (unique_series.get(series_id)) |existing_idx| {
                const existing = declarations[existing_idx];
                if (!std.mem.eql(u8, existing.name, declaration.name) or
                    !std.mem.eql(u8, existing.canonical_tags, declaration.canonical_tags))
                {
                    return error.SeriesIdConflict;
                }
            } else {
                const existing = self.metadata.series_catalog.resolveBySeriesId(series_id);
                switch (existing.status) {
                    .not_found => {},
                    .resolved, .exact_match => {
                        const existing_series = existing.series orelse return error.SeriesIdConflict;
                        const existing_tags = existing.canonical_tags orelse return error.SeriesIdConflict;
                        if (!std.mem.eql(u8, existing_series, declaration.name) or
                            !std.mem.eql(u8, existing_tags, declaration.canonical_tags))
                        {
                            return error.SeriesIdConflict;
                        }
                    },
                    .ambiguous => return error.SeriesIdConflict,
                }
                try unique_series.put(series_id, idx);
            }
        }
    }

    fn metricDescriptorWouldConflict(
        existing: metric_catalog_mod.Descriptor,
        incoming: metric_catalog_mod.DescriptorInput,
    ) bool {
        if (incoming.kind) |kind| {
            if (existing.kind) |current| {
                if (current != kind) return true;
            }
        }
        if (optionalFieldWouldConflict(existing.unit, incoming.unit)) return true;
        if (optionalFieldWouldConflict(existing.description, incoming.description)) return true;
        if (optionalFieldWouldConflict(existing.source_metric, incoming.source_metric)) return true;
        if (optionalFieldWouldConflict(existing.source_field, incoming.source_field)) return true;
        return false;
    }

    fn optionalFieldWouldConflict(existing: ?[]const u8, incoming: ?[]const u8) bool {
        const normalized = optionalBytesNormalized(incoming);
        if (normalized == null) return false;
        if (existing) |current| return !std.mem.eql(u8, current, normalized.?);
        return false;
    }

    fn noteTagsBatchForSeries(self: *Engine, series_ids: []const types.SeriesId, canonical_labels: []const u8) !void {
        for (series_ids) |series_id| self.noteTags(series_id, canonical_labels);
    }

    fn resolveMarketWriteMode(self: *Engine, schema: market_catalog_mod.MarketSchema) !MarketStorageWriteMode {
        const mode: MarketStorageWriteMode = switch (self.config.market_storage_mode) {
            .fanout_v1 => .fanout_v1,
            .dual_write_v1 => .dual_write_v1,
            .native_v1 => .native_v1,
            .auto => switch (schema.storage_mapping) {
                .fanout_v1 => .fanout_v1,
                .native_v1 => .native_v1,
            },
        };
        if (mode == .dual_write_v1 or mode == .native_v1) {
            try self.requireRepositoryFormat4ForNativeMarket();
        }
        return mode;
    }

    fn marketSchemaRegistrationMapping(
        self: *Engine,
        input: market_catalog_mod.MarketSchemaInput,
        explicit_storage_mapping: ?market_catalog_mod.StorageMapping,
    ) !market_catalog_mod.StorageMapping {
        if (self.marketSchema(input.metric)) |existing| {
            var owned_existing = existing;
            defer owned_existing.deinit(self.alloc);
            if (explicit_storage_mapping) |requested| {
                if (requested != existing.storage_mapping) return error.MarketSchemaConflict;
            }
            return existing.storage_mapping;
        }
        if (explicit_storage_mapping) |requested| {
            if (requested == .native_v1) try self.requireRepositoryFormat4ForNativeMarket();
            return requested;
        }
        return switch (self.config.market_storage_mode) {
            .fanout_v1 => .fanout_v1,
            .dual_write_v1, .native_v1 => blk: {
                try self.requireRepositoryFormat4ForNativeMarket();
                break :blk .native_v1;
            },
            // A new schema has no stored mapping yet. Format 4 repositories
            // select the native default once at registration, after which
            // `auto` follows that persisted schema mapping on every write.
            .auto => if (self.repository_format.version < cas_mod.current_repository_format_version)
                .fanout_v1
            else blk: {
                try self.requireRepositoryFormat4ForNativeMarket();
                break :blk .native_v1;
            },
        };
    }

    fn marketSchemaInputWithMapping(
        input: market_catalog_mod.MarketSchemaInput,
        storage_mapping: market_catalog_mod.StorageMapping,
    ) market_catalog_mod.MarketSchemaInput {
        return .{
            .metric = input.metric,
            .ordered_columns = input.ordered_columns,
            .required_labels = input.required_labels,
            .storage_mapping = storage_mapping,
        };
    }

    fn requireRepositoryFormat4ForNativeMarket(self: *Engine) !void {
        if (self.repository_format.version != cas_mod.current_repository_format_version) {
            return error.RepositoryFormatMismatch;
        }
        const cas = if (self.cas) |*manager| manager else return error.NativeMarketRequiresCas;
        if (cas.format.version != self.repository_format.version) return error.RepositoryFormatMismatch;
    }

    fn validateConfiguredMarketStorage(config: cfg.Config, repository_format: cas_mod.RepositoryFormat) !void {
        switch (config.market_storage_mode) {
            .auto, .fanout_v1 => {},
            .dual_write_v1, .native_v1 => {
                if (repository_format.version != cas_mod.current_repository_format_version) {
                    return error.RepositoryFormatMismatch;
                }
                if (config.cas_mode != .dual_write) return error.NativeMarketRequiresCas;
            },
        }
    }

    fn noteDrainStateChange(self: *Engine) void {
        self.drain_mu.lock();
        self.drain_generation += 1;
        self.drain_mu.unlock();
        self.drain_cv.broadcast();
    }

    fn noteQueueBecameNonEmpty(self: *Engine) void {
        self.drain_mu.lock();
        self.drain_generation += 1;
        self.drain_mu.unlock();
        self.drain_cv.broadcast();
    }

    fn noteQueueMaybeEmpty(self: *Engine) void {
        if (!self.queue.isDrained()) return;
        self.drain_mu.lock();
        self.queue_empty_generation += 1;
        self.drain_generation += 1;
        self.drain_mu.unlock();
        self.drain_cv.broadcast();
    }

    fn requestFlush(self: *Engine) u64 {
        self.drain_mu.lock();
        defer self.drain_mu.unlock();
        self.flush_requested = true;
        self.drain_generation += 1;
        return self.flush_generation;
    }

    fn takeFlushRequested(self: *Engine) bool {
        self.drain_mu.lock();
        defer self.drain_mu.unlock();
        const requested = self.flush_requested;
        self.flush_requested = false;
        return requested;
    }

    fn flushRequested(self: *Engine) bool {
        self.drain_mu.lock();
        defer self.drain_mu.unlock();
        return self.flush_requested;
    }

    fn beginFlush(self: *Engine) void {
        self.drain_mu.lock();
        self.flush_in_progress = true;
        self.flush_publication_error = null;
        self.drain_generation += 1;
        self.drain_mu.unlock();
        self.drain_cv.broadcast();
    }

    fn recordFlushPublicationError(self: *Engine, err: anyerror) void {
        self.drain_mu.lock();
        if (self.flush_publication_error == null) self.flush_publication_error = err;
        self.drain_generation += 1;
        self.drain_mu.unlock();
        self.drain_cv.broadcast();
    }

    fn endFlush(self: *Engine) void {
        self.drain_mu.lock();
        self.flush_in_progress = false;
        self.flush_generation += 1;
        self.drain_generation += 1;
        self.drain_mu.unlock();
        self.drain_cv.broadcast();
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
                _ = self.metrics.queue_pop_total.fetchAdd(@intCast(batch.payload.len()), .monotonic);
                if (wait_delta > 0) {
                    _ = self.metrics.queue_wait_ns_total.fetchAdd(@as(u64, @intCast(wait_delta)), .monotonic);
                }
                last_pop_ns = now_ns;
                {
                    defer {
                        self.queue.completeBatch();
                        self.noteQueueMaybeEmpty();
                    }
                    switch (batch.payload) {
                        .scalar => |points| {
                            const wal_start_ns = std.time.nanoTimestamp();
                            const wal_bytes = self.wal.appendBatch(points) catch |err| blk: {
                                _ = self.metrics.wal_append_failed_total.fetchAdd(@intCast(points.len), .monotonic);
                                for (points) |point| {
                                    self.quarantineFailedIngest(point, "wal_append_batch", @errorName(err));
                                }
                                std.log.warn("wal batch append failed: {s}", .{@errorName(err)});
                                break :blk 0;
                            };
                            const wal_elapsed_ns: u64 = @intCast(std.time.nanoTimestamp() - wal_start_ns);
                            if (wal_bytes != 0) {
                                _ = self.metrics.wal_append_total.fetchAdd(@intCast(points.len), .monotonic);
                                _ = self.metrics.wal_append_ns_total.fetchAdd(wal_elapsed_ns, .monotonic);
                                _ = self.metrics.wal_bytes_total.fetchAdd(wal_bytes, .monotonic);

                                const memtable_start_ns = std.time.nanoTimestamp();
                                self.market_data_mu.lock();
                                defer self.market_data_mu.unlock();
                                if (self.appendMemtableBatchGrouped(points)) |_| {
                                    const memtable_elapsed_ns: u64 = @intCast(std.time.nanoTimestamp() - memtable_start_ns);
                                    _ = self.metrics.memtable_append_ns_total.fetchAdd(memtable_elapsed_ns, .monotonic);
                                    _ = self.metrics.ingest_total.fetchAdd(@intCast(points.len), .monotonic);
                                    self.noteDrainStateChange();
                                } else |err| {
                                    _ = self.metrics.memtable_append_failed_total.fetchAdd(@intCast(points.len), .monotonic);
                                    for (points) |point| {
                                        self.quarantineFailedIngest(point, "memtable_append_batch", @errorName(err));
                                    }
                                    std.log.warn("failed to append batch to memtable: {s}", .{@errorName(err)});
                                }
                            }
                        },
                        .market => |*market_batch| {
                            if (self.processQueuedMarketBatch(market_batch)) |_| {
                                if (market_batch.completion) |completion| completion.complete(null);
                            } else |err| {
                                _ = self.metrics.wal_append_failed_total.fetchAdd(@intCast(market_batch.rows.len), .monotonic);
                                std.log.warn("market batch processing failed: {s}", .{@errorName(err)});
                                if (market_batch.completion) |completion| completion.complete(err);
                            }
                        },
                    }
                }
            } else {
                if (self.stop_flag) break;
                self.noteQueueMaybeEmpty();
            }

            const now = std.time.milliTimestamp();
            const mem_usage = self.liveMemtableBytes();
            const queue_idle = self.queue.isDrained();
            const force_flush = self.flushRequested();
            if (queue_idle and mem_usage == 0 and force_flush) {
                _ = self.takeFlushRequested();
                self.noteDrainStateChange();
            }
            if (mem_usage >= self.config.memtable_max_bytes or (mem_usage != 0 and queue_idle and ((now - last_flush) >= self.flush_timer_ms or force_flush))) {
                self.beginFlush();
                const flushed = flushMemtable(self) catch |err| blk: {
                    self.recordFlushPublicationError(err);
                    std.log.warn("memtable flush failed: {s}", .{@errorName(err)});
                    break :blk false;
                };
                _ = self.takeFlushRequested();
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
                        self.recordFlushPublicationError(err);
                        std.log.warn("cas sync failed: {s}", .{@errorName(err)});
                    };
                    self.scheduleDerivedRefresh();
                }
                // A configured CAS snapshot is part of the flush publication
                // boundary. Drain waiters must not verify the repository while
                // that snapshot and its in-memory index are still advancing.
                self.endFlush();
                self.noteQueueMaybeEmpty();
            }
            // fsync policy: interval
            if (self.config.fsync == .interval and (now - last_sync) >= self.flush_timer_ms) {
                self.wal.sync() catch |err| {
                    std.log.warn("wal sync failed: {s}", .{@errorName(err)});
                };
                last_sync = now;
            }
        }
        // final flush
        self.beginFlush();
        const flushed = flushMemtable(self) catch |err| blk: {
            self.recordFlushPublicationError(err);
            std.log.warn("final memtable flush failed: {s}", .{@errorName(err)});
            break :blk false;
        };
        if (flushed) {
            self.syncCasSnapshot("shutdown-flush") catch |err| {
                self.recordFlushPublicationError(err);
                std.log.warn("cas sync failed: {s}", .{@errorName(err)});
            };
        }
        self.endFlush();
        self.noteQueueMaybeEmpty();
    }

    fn processQueuedMarketBatch(self: *Engine, batch: *const QueuedMarketBatch) !void {
        if (batch.rows.len == 0) return;

        var registrations = try self.alloc.alloc(wal_mod.MarketSeriesRegistrationAppend, batch.rows.len);
        defer self.alloc.free(registrations);
        var wal_rows = try self.alloc.alloc(wal_mod.MarketRowAppend, batch.rows.len);
        defer self.alloc.free(wal_rows);
        var mem_rows = try self.alloc.alloc(market_memtable_mod.MarketRowInput, batch.rows.len);
        defer self.alloc.free(mem_rows);

        var registration_count: usize = 0;
        for (batch.rows, 0..) |row, idx| {
            var registration_seen = false;
            for (registrations[0..registration_count]) |registration| {
                if (registration.market_series_id == row.market_series_id) {
                    registration_seen = true;
                    break;
                }
            }
            if (!registration_seen) {
                registrations[registration_count] = .{
                    .market_series_id = row.market_series_id,
                    .schema_digest = row.schema_digest,
                    .metric = row.metric,
                    .canonical_labels = row.canonical_labels,
                };
                registration_count += 1;
            }
            const sequence = self.next_market_write_sequence;
            self.next_market_write_sequence = std.math.add(u64, self.next_market_write_sequence, 1) catch return error.MarketWriteSequenceOverflow;
            wal_rows[idx] = .{
                .market_series_id = row.market_series_id,
                .write_sequence = sequence,
                .ts_ns = row.ts_ns,
                .values = row.values,
            };
            mem_rows[idx] = .{
                .market_series_id = row.market_series_id,
                .metric = row.metric,
                .canonical_labels = row.canonical_labels,
                .schema_digest = row.schema_digest,
                .ts_ns = row.ts_ns,
                .write_sequence = sequence,
                .values = row.values,
            };
        }

        var fanout_points: []ResolvedIngestPoint = &.{};
        defer if (fanout_points.len != 0) self.alloc.free(fanout_points);
        var fanout_checkpoints: []FanoutMemtableCheckpoint = &.{};
        defer if (fanout_checkpoints.len != 0) self.alloc.free(fanout_checkpoints);
        if (batch.mode == .dual_write_v1) {
            fanout_points = try self.flattenMarketFanoutPoints(batch);
            std.sort.block(ResolvedIngestPoint, fanout_points, {}, struct {
                fn lessThan(_: void, a: ResolvedIngestPoint, b: ResolvedIngestPoint) bool {
                    if (a.series_id != b.series_id) return a.series_id < b.series_id;
                    return a.ts < b.ts;
                }
            }.lessThan);
            fanout_checkpoints = try self.captureFanoutMemtableCheckpoints(fanout_points);
        }

        if (self.market_writer_fault == .wal_append) return error.InjectedMarketWalAppendFailure;
        const wal_start_ns = std.time.nanoTimestamp();
        const registration_bytes = try self.wal.appendMarketSeriesRegistrationBatch(
            registrations[0..registration_count],
        );
        crash_injection.hit(.after_registration);
        const row_bytes = try self.wal.appendMarketRowBatch(wal_rows);
        crash_injection.hit(.after_wal_append);
        const wal_elapsed_ns: u64 = @intCast(std.time.nanoTimestamp() - wal_start_ns);
        _ = self.metrics.wal_append_total.fetchAdd(@intCast(batch.rows.len), .monotonic);
        _ = self.metrics.wal_append_ns_total.fetchAdd(wal_elapsed_ns, .monotonic);
        _ = self.metrics.wal_bytes_total.fetchAdd(registration_bytes + row_bytes, .monotonic);

        const memtable_start_ns = std.time.nanoTimestamp();
        self.market_data_mu.lock();
        defer self.market_data_mu.unlock();
        var fanout_applied = false;
        errdefer if (fanout_applied) self.rollbackFanoutMemtable(fanout_checkpoints, fanout_points.len);
        if (batch.mode == .dual_write_v1) {
            try self.appendMemtableBatchGrouped(fanout_points);
            fanout_applied = true;
            if (self.market_writer_fault == .native_apply_after_fanout) {
                return error.InjectedNativeMarketApplyFailure;
            }
        }
        try self.market_mem.appendBatch(mem_rows);
        crash_injection.hit(.after_memtable_append);
        fanout_applied = false;
        self.market_mem_allocated_bytes.store(self.market_mem.allocatedBytes(), .monotonic);
        self.market_mem_resident_bytes.store(self.market_mem.residentBytes(), .monotonic);
        _ = self.metrics.memtable_append_ns_total.fetchAdd(@intCast(std.time.nanoTimestamp() - memtable_start_ns), .monotonic);
        _ = self.metrics.ingest_total.fetchAdd(@intCast(batch.rows.len), .monotonic);

        self.noteDrainStateChange();
    }

    fn captureFanoutMemtableCheckpoints(
        self: *Engine,
        sorted_points: []const ResolvedIngestPoint,
    ) ![]FanoutMemtableCheckpoint {
        if (sorted_points.len == 0) return try self.alloc.alloc(FanoutMemtableCheckpoint, 0);
        const checkpoints = try self.alloc.alloc(FanoutMemtableCheckpoint, sorted_points.len);
        errdefer self.alloc.free(checkpoints);

        var checkpoint_count: usize = 0;
        var start: usize = 0;
        while (start < sorted_points.len) {
            const series_id = sorted_points[start].series_id;
            var end = start + 1;
            while (end < sorted_points.len and sorted_points[end].series_id == series_id) : (end += 1) {}
            if (self.mem.series.getPtr(series_id)) |buffer| {
                checkpoints[checkpoint_count] = .{
                    .series_id = series_id,
                    .existed = true,
                    .old_len = buffer.points.items.len,
                    .old_sorted = buffer.sorted,
                    .old_last_ts = buffer.last_ts,
                };
            } else {
                checkpoints[checkpoint_count] = .{
                    .series_id = series_id,
                    .existed = false,
                    .old_len = 0,
                    .old_sorted = true,
                    .old_last_ts = null,
                };
            }
            checkpoint_count += 1;
            start = end;
        }
        return try self.alloc.realloc(checkpoints, checkpoint_count);
    }

    fn rollbackFanoutMemtable(
        self: *Engine,
        checkpoints: []const FanoutMemtableCheckpoint,
        appended_points: usize,
    ) void {
        for (checkpoints) |checkpoint| {
            if (!checkpoint.existed) {
                if (self.mem.series.getPtr(checkpoint.series_id)) |buffer| buffer.deinit();
                _ = self.mem.series.remove(checkpoint.series_id);
                continue;
            }
            const buffer = self.mem.series.getPtr(checkpoint.series_id) orelse continue;
            std.debug.assert(buffer.points.items.len >= checkpoint.old_len);
            buffer.points.items.len = checkpoint.old_len;
            buffer.sorted = checkpoint.old_sorted;
            buffer.last_ts = checkpoint.old_last_ts;
        }
        _ = self.mem.bytes.fetchSub(appended_points * @sizeOf(types.Point), .monotonic);
    }

    fn flattenMarketFanoutPoints(self: *Engine, batch: *const QueuedMarketBatch) ![]ResolvedIngestPoint {
        var count: usize = 0;
        for (batch.fanout_series_ids) |series_ids| count += series_ids.len;
        const points = try self.alloc.alloc(ResolvedIngestPoint, count);
        var idx: usize = 0;
        for (batch.fanout_series_ids, batch.fanout_values, batch.rows) |series_ids, values, row| {
            if (series_ids.len != values.len) return error.InvalidMarketFanoutBatch;
            for (series_ids, values) |series_id, value| {
                points[idx] = .{
                    .series_id = series_id,
                    .ts = row.ts_ns,
                    .value = value,
                };
                idx += 1;
            }
        }
        return points;
    }

    fn appendRecoveredMarketFanout(
        self: *Engine,
        registration: MarketReplayRegistration,
        ts_ns: i64,
        values: []const f64,
    ) !void {
        if (self.config.market_storage_mode != .dual_write_v1) return;

        var schema = self.marketSchema(registration.metric) orelse return error.UnknownMarketSchema;
        defer schema.deinit(self.alloc);
        if (schema.ordered_columns.len != values.len) return error.MarketSchemaConflict;

        const fanout_points = try self.alloc.alloc(ResolvedIngestPoint, values.len);
        defer self.alloc.free(fanout_points);
        const fanout_series_ids = try self.alloc.alloc(types.SeriesId, values.len);
        defer self.alloc.free(fanout_series_ids);

        for (schema.ordered_columns, 0..) |column, column_idx| {
            const derived_metric = try std.fmt.allocPrint(self.alloc, "{s}.{s}", .{ registration.metric, column });
            defer self.alloc.free(derived_metric);
            _ = try self.registerMetricDescriptor(.{
                .metric = derived_metric,
                .kind = .gauge,
                .source_metric = registration.metric,
                .source_field = column,
            });
            const series_id = types.seriesIdFrom(derived_metric, registration.canonical_labels);
            try self.registerSeriesInternal(derived_metric, registration.canonical_labels, series_id, false);
            fanout_series_ids[column_idx] = series_id;
            fanout_points[column_idx] = .{
                .series_id = series_id,
                .ts = ts_ns,
                .value = values[column_idx],
            };
        }

        try self.appendMemtableBatchGrouped(fanout_points);
        self.noteTagsBatchForSeries(fanout_series_ids, registration.canonical_labels) catch {};
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
                    defer if (report.last_event_id) |event_id| self.alloc.free(event_id);
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
                    defer if (report.last_event_id) |event_id| self.alloc.free(event_id);
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
            defer if (report.last_event_id) |event_id| self.alloc.free(event_id);
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
            defer if (report.last_event_id) |event_id| self.alloc.free(event_id);
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
        const requested_columns = &.{ "price", "size" };
        const groups = try self.collectDerivedSeriesGroups(rollup.source_metric, requested_columns);
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
            const source_columns = try self.queryDerivedColumns(
                rollup.source_metric,
                group,
                requested_columns,
                start_ts,
                std.math.maxInt(i64),
            );
            defer self.freePointColumns(source_columns);
            const trades = try alignTradeSamples(self.alloc, source_columns[0], source_columns[1]);
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
        const requested_columns = &.{ "bid", "ask", "bid_size", "ask_size" };
        const groups = try self.collectDerivedSeriesGroups(rollup.source_metric, requested_columns);
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
            const source_columns = try self.queryDerivedColumns(
                rollup.source_metric,
                group,
                requested_columns,
                start_ts,
                std.math.maxInt(i64),
            );
            defer self.freePointColumns(source_columns);
            const quotes = try alignQuoteSamples(
                self.alloc,
                source_columns[0],
                source_columns[1],
                source_columns[2],
                source_columns[3],
            );
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
        const requested_columns = &.{ "open", "high", "low", "close", "volume", "vwap" };
        const groups = try self.collectDerivedSeriesGroups(rollup.source_metric, requested_columns);
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
            const source_columns = try self.queryDerivedColumns(
                rollup.source_metric,
                group,
                requested_columns,
                start_ts,
                std.math.maxInt(i64),
            );
            defer self.freePointColumns(source_columns);
            const bars = try alignBarSamples(self.alloc, source_columns);
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

        const groups = try self.collectDerivedSeriesGroups(signal.input_metric, columns);
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
            const source_columns = try self.queryDerivedColumns(
                signal.input_metric,
                group,
                columns,
                std.math.minInt(i64),
                std.math.maxInt(i64),
            );
            defer self.freePointColumns(source_columns);
            const primary_points = source_columns[0];
            rows_processed += @intCast(primary_points.len);
            const secondary_points: []const types.Point = if (source_columns.len > 1)
                source_columns[1]
            else
                &.{};

            const output_labels = try mergeLabelsJson(self.alloc, group.labels_json, &.{
                .{ .key = "data_revision", .value = revision },
                .{ .key = "definition_id", .value = signal.id },
                .{ .key = "definition_version", .value = version_text },
            });
            defer self.alloc.free(output_labels);

            const output_metric = try std.fmt.allocPrint(self.alloc, "_signal.{s}", .{signal.id});
            defer self.alloc.free(output_metric);
            const signal_report = try self.emitSignalPoints(output_metric, output_labels, group.labels_json, revision, signal, primary_points, secondary_points, checkpoint);
            defer if (signal_report.last_event_id) |event_id| self.alloc.free(event_id);
            emissions_total += signal_report.emissions_total;
            if (signal_report.last_output_ts != null) {
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
        errdefer if (last_event_id) |value| self.alloc.free(value);

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
                    const event_id = try self.recordSignalEmission(signal, raw_labels_json, data_revision, point.ts, ema_value);
                    if (last_event_id) |previous| self.alloc.free(previous);
                    last_event_id = event_id;
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
                    const event_id = try self.recordSignalEmission(signal, raw_labels_json, data_revision, point.ts, avg_value);
                    if (last_event_id) |previous| self.alloc.free(previous);
                    last_event_id = event_id;
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
                    const event_id = try self.recordSignalEmission(signal, raw_labels_json, data_revision, point.ts, 1.0);
                    if (last_event_id) |previous| self.alloc.free(previous);
                    last_event_id = event_id;
                    last_output_ts = point.ts;
                }
            },
            .spread_gt => {
                const threshold = jsonParamFloat(params_obj, "threshold", 0);
                for (primary_points, primary_values) |point, value| {
                    if (value <= threshold or point.ts <= checkpoint) continue;
                    try self.emitDerivedMetric(output_metric, output_labels, point.ts, 1.0, signal.input_metric, signal.expression_kind.text());
                    emissions_total += 1;
                    const event_id = try self.recordSignalEmission(signal, raw_labels_json, data_revision, point.ts, 1.0);
                    if (last_event_id) |previous| self.alloc.free(previous);
                    last_event_id = event_id;
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
                    const event_id = try self.recordSignalEmission(signal, raw_labels_json, data_revision, point.ts, 1.0);
                    if (last_event_id) |previous| self.alloc.free(previous);
                    last_event_id = event_id;
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
                            const event_id = try self.recordSignalEmission(signal, raw_labels_json, data_revision, point.ts, 1.0);
                            if (last_event_id) |previous| self.alloc.free(previous);
                            last_event_id = event_id;
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
        var schema = self.marketSchema(family_metric) orelse return error.UnknownMarketSchema;
        defer schema.deinit(self.alloc);
        if (schema.storage_mapping == .fanout_v1) {
            const values = [_]f64{ open, high, low, close, volume, vwap };
            const fields = [_][]const u8{ "open", "high", "low", "close", "volume", "vwap" };
            for (values, fields) |value, field| {
                const metric = try std.fmt.allocPrint(self.alloc, "{s}.{s}", .{ family_metric, field });
                defer self.alloc.free(metric);
                try self.emitDerivedMetric(
                    metric,
                    labels_json,
                    ts,
                    value,
                    source_metric,
                    field,
                );
            }
            return;
        }

        const values = [_]f64{ open, high, low, close, volume, vwap };
        _ = try self.appendMarketRows(&.{.{
            .metric = family_metric,
            .labels_json = labels_json,
            .ts_ns = ts,
            .values = &values,
        }});
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

    fn collectDerivedSeriesGroups(
        self: *Engine,
        family_metric: []const u8,
        columns: []const []const u8,
    ) ![]MetricSeriesGroup {
        const scalar_groups = try self.collectMetricSeriesGroups(family_metric, columns);
        if (self.marketSchema(family_metric)) |owned_schema| {
            defer self.freeMetricSeriesGroups(scalar_groups);
            var schema = owned_schema;
            defer schema.deinit(self.alloc);

            const identities = try self.metadata.market_catalog.listMarketSeries();
            defer {
                for (identities) |*identity| identity.deinit(self.alloc);
                self.alloc.free(identities);
            }

            var groups = std.array_list.Managed(MetricSeriesGroup).init(self.alloc);
            errdefer {
                for (groups.items) |*group| group.deinit(self.alloc);
                groups.deinit();
            }
            for (identities) |identity| {
                if (!std.mem.eql(u8, identity.metric, family_metric)) continue;
                var existing_index: ?usize = null;
                for (groups.items, 0..) |group, idx| {
                    if (std.mem.eql(u8, group.labels_json, identity.canonical_labels)) {
                        existing_index = idx;
                        break;
                    }
                }
                if (existing_index) |idx| {
                    groups.items[idx].has_market_identity = true;
                    continue;
                }
                const labels = try self.alloc.dupe(u8, identity.canonical_labels);
                errdefer self.alloc.free(labels);
                const series_ids = try self.alloc.alloc(types.SeriesId, 0);
                errdefer self.alloc.free(series_ids);
                try groups.append(.{
                    .labels_json = labels,
                    .series_ids = series_ids,
                    .has_market_identity = true,
                });
            }

            for (scalar_groups) |scalar_group| {
                var existing_index: ?usize = null;
                for (groups.items, 0..) |group, idx| {
                    if (std.mem.eql(u8, group.labels_json, scalar_group.labels_json)) {
                        existing_index = idx;
                        break;
                    }
                }
                if (existing_index) |idx| {
                    const series_ids = try self.alloc.dupe(types.SeriesId, scalar_group.series_ids);
                    self.alloc.free(groups.items[idx].series_ids);
                    groups.items[idx].series_ids = series_ids;
                    continue;
                }
                const labels = try self.alloc.dupe(u8, scalar_group.labels_json);
                errdefer self.alloc.free(labels);
                const series_ids = try self.alloc.dupe(types.SeriesId, scalar_group.series_ids);
                errdefer self.alloc.free(series_ids);
                try groups.append(.{
                    .labels_json = labels,
                    .series_ids = series_ids,
                });
            }
            return try groups.toOwnedSlice();
        }

        // Compatibility for custom and pre-native derived series that have no
        // logical market-series registration.
        return scalar_groups;
    }

    fn queryDerivedColumns(
        self: *Engine,
        family_metric: []const u8,
        group: MetricSeriesGroup,
        columns: []const []const u8,
        start_ts: i64,
        end_ts: i64,
    ) ![][]types.Point {
        if (!group.has_market_identity) {
            if (group.series_ids.len == 0) return error.IncompleteMarketRow;
            if (group.series_ids.len != columns.len) return error.IncompleteMarketRow;
            const points_by_column = try self.alloc.alloc([]types.Point, columns.len);
            var initialized: usize = 0;
            errdefer {
                for (points_by_column[0..initialized]) |points| self.alloc.free(points);
                self.alloc.free(points_by_column);
            }
            for (group.series_ids, 0..) |series_id, idx| {
                points_by_column[idx] = try self.querySeriesPoints(series_id, start_ts, end_ts);
                initialized += 1;
            }
            return points_by_column;
        }

        var result = try self.queryMarket(.{
            .metric = family_metric,
            .label_filter_json = group.labels_json,
            .start_ts_ns = start_ts,
            .end_ts_ns = end_ts,
            .requested_columns = columns,
        });
        defer result.deinit();

        var exact_row_count: usize = 0;
        for (result.rows) |row| {
            if (std.mem.eql(u8, row.canonical_labels, group.labels_json)) exact_row_count += 1;
        }

        const native_columns = try self.alloc.alloc([]types.Point, columns.len);
        var initialized: usize = 0;
        errdefer {
            for (native_columns[0..initialized]) |points| self.alloc.free(points);
            self.alloc.free(native_columns);
        }
        for (native_columns) |*points| {
            points.* = try self.alloc.alloc(types.Point, exact_row_count);
            initialized += 1;
        }

        var row_idx: usize = 0;
        for (result.rows) |row| {
            if (!std.mem.eql(u8, row.canonical_labels, group.labels_json)) continue;
            if (row.values.len != columns.len) return error.IncompleteMarketRow;
            for (native_columns, row.values) |points, value| {
                points[row_idx] = .{ .ts = row.ts_ns, .value = value };
            }
            row_idx += 1;
        }

        if (group.series_ids.len == 0) return native_columns;
        if (group.series_ids.len != columns.len) return error.IncompleteMarketRow;

        var scalar_columns = try self.alloc.alloc([]types.Point, columns.len);
        var scalar_initialized: usize = 0;
        errdefer {
            for (scalar_columns[0..scalar_initialized]) |points| self.alloc.free(points);
            self.alloc.free(scalar_columns);
        }
        for (group.series_ids, 0..) |series_id, idx| {
            scalar_columns[idx] = try self.querySeriesPoints(series_id, start_ts, end_ts);
            scalar_initialized += 1;
        }

        const merged_columns = try self.alloc.alloc([]types.Point, columns.len);
        var merged_initialized: usize = 0;
        errdefer {
            for (merged_columns[0..merged_initialized]) |points| self.alloc.free(points);
            self.alloc.free(merged_columns);
        }
        for (columns, 0..) |_, idx| {
            merged_columns[idx] = try self.mergeDerivedPoints(scalar_columns[idx], native_columns[idx]);
            merged_initialized += 1;
        }
        self.freePointColumns(native_columns);
        self.freePointColumns(scalar_columns);
        return merged_columns;
    }

    fn mergeDerivedPoints(self: *Engine, scalar: []const types.Point, native: []const types.Point) ![]types.Point {
        var by_timestamp = std.AutoHashMap(i64, f64).init(self.alloc);
        defer by_timestamp.deinit();

        for (scalar) |point| try by_timestamp.put(point.ts, point.value);
        // Market reads resolve corrections according to the selected storage
        // mapping, so their row takes precedence over legacy scalar history at
        // the same timestamp.
        for (native) |point| try by_timestamp.put(point.ts, point.value);

        const points = try self.alloc.alloc(types.Point, by_timestamp.count());
        errdefer self.alloc.free(points);
        var idx: usize = 0;
        var it = by_timestamp.iterator();
        while (it.next()) |entry| {
            points[idx] = .{ .ts = entry.key_ptr.*, .value = entry.value_ptr.* };
            idx += 1;
        }
        std.sort.block(types.Point, points, {}, struct {
            fn lessThan(_: void, lhs: types.Point, rhs: types.Point) bool {
                return lhs.ts < rhs.ts;
            }
        }.lessThan);
        return points;
    }

    fn freePointColumns(self: *Engine, columns: [][]types.Point) void {
        for (columns) |points| self.alloc.free(points);
        self.alloc.free(columns);
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
        var schema = self.marketSchema(input.input_metric) orelse {
            if (!std.mem.startsWith(u8, input.input_metric, "market.bar") and
                !std.mem.startsWith(u8, input.input_metric, "market.quote") and
                !std.mem.startsWith(u8, input.input_metric, "market.trade"))
                return error.InvalidSignalInputMetric;
            return;
        };
        defer schema.deinit(self.alloc);
        if (input.policy_id) |policy_id| {
            var policy = self.latestBarPolicy(policy_id) orelse return error.InvalidSignalPolicy;
            defer policy.deinit(self.alloc);
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
        self.market_data_mu.lock();
        defer self.market_data_mu.unlock();

        const start_ns = std.time.nanoTimestamp();
        var points_written: usize = 0;
        var segments_written: usize = 0;
        var series_buckets: usize = 0;
        var hour_slices: usize = 0;
        var selector_metadata_ns_total: u64 = 0;
        var segment_write_ns_total: u64 = 0;
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
            series_buckets += 1;
            if (!buffer.sorted and buffer.points.items.len > 1) {
                std.sort.block(types.Point, buffer.points.items, {}, struct {
                    fn lessThan(_: void, a: types.Point, b: types.Point) bool {
                        return a.ts < b.ts;
                    }
                }.lessThan);
            }
            const selector_start_ns = std.time.nanoTimestamp();
            const selector_metadata = try self.cachedFlushSelectorMetadata(&selector_cache, sid);
            selector_metadata_ns_total += @intCast(std.time.nanoTimestamp() - selector_start_ns);
            const first_hour = self.hourBucketForSeries(sid, buffer.points.items[0].ts);
            const last_hour = self.hourBucketForSeries(sid, buffer.points.items[buffer.points.items.len - 1].ts);

            if (buffer.points.items.len == 1 or first_hour == last_hour) {
                const write_start_ns = std.time.nanoTimestamp();
                const seg_path = try segment_mod.writeSegmentWithMetadata(self.alloc, self.data_dir, sid, first_hour, buffer.points.items, selector_metadata);
                segment_write_ns_total += @intCast(std.time.nanoTimestamp() - write_start_ns);
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
                hour_slices += 1;
            } else {
                var start_idx: usize = 0;
                while (start_idx < buffer.points.items.len) {
                    const hour = self.hourBucketForSeries(sid, buffer.points.items[start_idx].ts);
                    var end_idx = start_idx + 1;
                    while (end_idx < buffer.points.items.len and self.hourBucketForSeries(sid, buffer.points.items[end_idx].ts) == hour) : (end_idx += 1) {}
                    const slice = buffer.points.items[start_idx..end_idx];
                    const write_start_ns = std.time.nanoTimestamp();
                    const seg_path = try segment_mod.writeSegmentWithMetadata(self.alloc, self.data_dir, sid, hour, slice, selector_metadata);
                    segment_write_ns_total += @intCast(std.time.nanoTimestamp() - write_start_ns);
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
                    hour_slices += 1;
                    start_idx = end_idx;
                }
            }
            buffer.clearRetainingCapacity();
        }
        const manifest_start_ns = std.time.nanoTimestamp();
        try self.metadata.manifest.addBatch(self.data_dir, manifest_entries.items);
        const manifest_elapsed_ns: u64 = @intCast(std.time.nanoTimestamp() - manifest_start_ns);
        self.mem.bytes.store(0, .monotonic);
        if (segments_written > 0) {
            const duration_ns_i128 = std.time.nanoTimestamp() - start_ns;
            const duration_ns: u64 = @intCast(duration_ns_i128);
            const points_u64: u64 = @intCast(points_written);
            _ = self.metrics.flush_total.fetchAdd(1, .monotonic);
            _ = self.metrics.flush_ns_total.fetchAdd(duration_ns, .monotonic);
            _ = self.metrics.flush_points_total.fetchAdd(points_u64, .monotonic);
            _ = self.metrics.flush_manifest_ns_total.fetchAdd(manifest_elapsed_ns, .monotonic);
            _ = self.metrics.flush_segment_write_ns_total.fetchAdd(segment_write_ns_total, .monotonic);
            _ = self.metrics.flush_selector_metadata_ns_total.fetchAdd(selector_metadata_ns_total, .monotonic);
            _ = self.metrics.flush_segments_written_total.fetchAdd(@intCast(segments_written), .monotonic);
            _ = self.metrics.flush_series_buckets_total.fetchAdd(@intCast(series_buckets), .monotonic);
            _ = self.metrics.flush_hour_slices_total.fetchAdd(@intCast(hour_slices), .monotonic);
            const duration_ms = if (std.time.ns_per_ms == 0) 0 else duration_ns / std.time.ns_per_ms;
            std.log.info("flush completed: segments={d} points={d} duration_ms={d}", .{ segments_written, points_written, duration_ms });
        } else {
            _ = self.metrics.flush_manifest_ns_total.fetchAdd(manifest_elapsed_ns, .monotonic);
            _ = self.metrics.flush_selector_metadata_ns_total.fetchAdd(selector_metadata_ns_total, .monotonic);
            _ = self.metrics.flush_segment_write_ns_total.fetchAdd(segment_write_ns_total, .monotonic);
            _ = self.metrics.flush_series_buckets_total.fetchAdd(@intCast(series_buckets), .monotonic);
            _ = self.metrics.flush_hour_slices_total.fetchAdd(@intCast(hour_slices), .monotonic);
        }
        const native_flushed = try self.flushNativeMarketMemtable();

        // rotate WAL optionally
        self.wal.rotateIfNeeded() catch |err| {
            std.log.warn("wal rotation failed: {s}", .{@errorName(err)});
        };
        if (self.tag_index_dirty.swap(false, .monotonic)) {
            const tag_save_start_ns = std.time.nanoTimestamp();
            self.metadata.tags.save(self.data_dir) catch |err| {
                self.tag_index_dirty.store(true, .monotonic);
                std.log.warn("tag index save failed: {s}", .{@errorName(err)});
                return segments_written > 0 or native_flushed;
            };
            const tag_save_elapsed_ns: u64 = @intCast(std.time.nanoTimestamp() - tag_save_start_ns);
            _ = self.metrics.tag_index_save_total.fetchAdd(1, .monotonic);
            _ = self.metrics.tag_index_save_ns_total.fetchAdd(tag_save_elapsed_ns, .monotonic);
        } else {
            _ = self.metrics.tag_index_save_skipped_total.fetchAdd(1, .monotonic);
        }
        return segments_written > 0 or native_flushed;
    }

    fn flushNativeMarketMemtable(self: *Engine) !bool {
        if (self.market_mem.seriesCount() == 0 or self.market_mem.residentBytes() == 0) return false;

        const start_ns = std.time.nanoTimestamp();
        var extraction = try self.market_mem.extractByHour(self.alloc);
        defer extraction.deinit();
        if (extraction.groups.len == 0) return false;

        var additions = std.array_list.Managed(market_manifest_mod.AddInput).init(self.alloc);
        defer {
            for (additions.items) |entry| self.alloc.free(@constCast(entry.path));
            additions.deinit();
        }
        var addition_column_names = std.array_list.Managed([][]u8).init(self.alloc);
        defer {
            for (addition_column_names.items) |names| {
                for (names) |name| self.alloc.free(name);
                self.alloc.free(names);
            }
            addition_column_names.deinit();
        }
        try additions.ensureTotalCapacity(extraction.groups.len);
        try addition_column_names.ensureTotalCapacity(extraction.groups.len);

        var rows_written: usize = 0;
        var segments_written: usize = 0;
        var segment_write_ns_total: u64 = 0;

        for (extraction.groups) |group| {
            const row_count = group.rows.timestamps.len;
            if (row_count == 0) continue;
            var schema = self.marketSchema(group.identity.metric) orelse return error.UnknownMarketSchema;
            defer schema.deinit(self.alloc);
            const expected_digest = schema.digest();
            if (!std.mem.eql(u8, expected_digest[0..], group.schema_digest[0..])) {
                return error.MarketSchemaConflict;
            }
            if (schema.ordered_columns.len != group.rows.columns.len) return error.MarketSchemaConflict;

            const row_views = try self.alloc.alloc(market_segment_mod.MarketRowView, row_count);
            defer self.alloc.free(row_views);
            const row_values = try self.alloc.alloc([]f64, row_count);
            var initialized_values: usize = 0;
            defer {
                for (row_values[0..initialized_values]) |values| self.alloc.free(values);
                self.alloc.free(row_values);
            }
            for (0..row_count) |row_idx| {
                const values = try self.alloc.alloc(f64, group.rows.columns.len);
                row_values[row_idx] = values;
                initialized_values += 1;
                for (group.rows.columns, 0..) |column, column_idx| {
                    values[column_idx] = column[row_idx];
                }
                row_views[row_idx] = .{
                    .ts_ns = group.rows.timestamps[row_idx],
                    .write_sequence = group.rows.write_sequences[row_idx],
                    .values = values,
                };
            }

            const write_start_ns = std.time.nanoTimestamp();
            const path = try market_segment_mod.write(self.alloc, self.data_dir, .{
                .market_series_id = group.identity.series_id,
                .schema_digest = group.schema_digest,
                .metric = group.identity.metric,
                .canonical_labels = group.identity.canonical_labels,
                .hour = group.hour_bucket,
                .column_names = schema.ordered_columns,
            }, row_views);
            crash_injection.hit(.after_segment_creation);
            segment_write_ns_total += @intCast(std.time.nanoTimestamp() - write_start_ns);
            errdefer self.alloc.free(path);

            const file_bytes = try self.data_dir.readFileAlloc(self.alloc, path, 128 * 1024 * 1024);
            defer self.alloc.free(file_bytes);
            const digest = market_manifest_mod.contentDigest(file_bytes);
            const block_rows: usize = @intCast(market_segment_mod.market_segment_block_rows);
            const block_count: u32 = @intCast((row_count + block_rows - 1) / block_rows);
            const column_names = try self.alloc.alloc([]u8, schema.ordered_columns.len);
            var column_names_initialized: usize = 0;
            var column_names_transferred = false;
            errdefer if (!column_names_transferred) {
                for (column_names[0..column_names_initialized]) |name| self.alloc.free(name);
                self.alloc.free(column_names);
            };
            for (schema.ordered_columns, 0..) |name, name_idx| {
                column_names[name_idx] = try self.alloc.dupe(u8, name);
                column_names_initialized += 1;
            }
            try addition_column_names.append(column_names);
            column_names_transferred = true;
            try additions.append(.{
                .path = path,
                .market_series_id = group.identity.series_id,
                .schema_digest = group.schema_digest,
                .metric = group.identity.metric,
                .canonical_labels = group.identity.canonical_labels,
                .hour_bucket = group.hour_bucket,
                .start_ts_ns = group.rows.timestamps[0],
                .end_ts_ns = group.rows.timestamps[row_count - 1],
                .row_count = @intCast(row_count),
                .block_count = block_count,
                .column_names = column_names,
                .content_id = digest,
                .file_hash = digest,
                .file_size = @intCast(file_bytes.len),
            });
            rows_written += row_count;
            segments_written += 1;
        }

        const manifest_start_ns = std.time.nanoTimestamp();
        try self.market_manifest.addBatch(self.data_dir, additions.items);
        crash_injection.hit(.after_manifest_update);
        const manifest_elapsed_ns: u64 = @intCast(std.time.nanoTimestamp() - manifest_start_ns);

        self.market_mem.clearRetainingCapacity();
        self.market_mem_allocated_bytes.store(self.market_mem.allocatedBytes(), .monotonic);
        self.market_mem_resident_bytes.store(self.market_mem.residentBytes(), .monotonic);
        if (segments_written != 0) {
            _ = self.metrics.flush_total.fetchAdd(1, .monotonic);
            _ = self.metrics.flush_ns_total.fetchAdd(@intCast(std.time.nanoTimestamp() - start_ns), .monotonic);
            _ = self.metrics.flush_points_total.fetchAdd(@intCast(rows_written), .monotonic);
            _ = self.metrics.flush_manifest_ns_total.fetchAdd(manifest_elapsed_ns, .monotonic);
            _ = self.metrics.flush_segment_write_ns_total.fetchAdd(segment_write_ns_total, .monotonic);
            _ = self.metrics.flush_segments_written_total.fetchAdd(@intCast(segments_written), .monotonic);
            _ = self.metrics.flush_series_buckets_total.fetchAdd(@intCast(segments_written), .monotonic);
            _ = self.metrics.flush_hour_slices_total.fetchAdd(@intCast(segments_written), .monotonic);
        }
        return segments_written != 0;
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

    const MarketQuerySource = union(enum) {
        live,
        revision: *const cas_mod.SnapshotIndex,
    };

    const MarketProjection = struct {
        indices: []usize,
        names: [][]u8,
        names_owned: bool = true,

        fn resolve(
            alloc: std.mem.Allocator,
            schema_columns: []const []u8,
            requested_columns: []const []const u8,
        ) !MarketProjection {
            const count = if (requested_columns.len == 0)
                schema_columns.len
            else
                requested_columns.len;
            const indices = try alloc.alloc(usize, count);
            errdefer alloc.free(indices);
            const names = try alloc.alloc([]u8, count);
            errdefer alloc.free(names);
            var initialized: usize = 0;
            errdefer for (names[0..initialized]) |name| alloc.free(name);

            if (requested_columns.len == 0) {
                for (schema_columns, 0..) |column, idx| {
                    indices[idx] = idx;
                    names[idx] = try alloc.dupe(u8, column);
                    initialized += 1;
                }
            } else {
                for (requested_columns, 0..) |requested, requested_idx| {
                    const schema_idx = findMarketColumn(schema_columns, requested) orelse
                        return error.InvalidProjection;
                    for (indices[0..requested_idx]) |existing| {
                        if (existing == schema_idx) return error.InvalidProjection;
                    }
                    indices[requested_idx] = schema_idx;
                    names[requested_idx] = try alloc.dupe(u8, schema_columns[schema_idx]);
                    initialized += 1;
                }
            }
            return .{ .indices = indices, .names = names };
        }

        fn deinit(self: *MarketProjection, alloc: std.mem.Allocator) void {
            alloc.free(self.indices);
            if (self.names_owned) {
                for (self.names) |name| alloc.free(name);
                alloc.free(self.names);
            }
            self.* = undefined;
        }

        fn takeNames(self: *MarketProjection) [][]u8 {
            self.names_owned = false;
            return self.names;
        }
    };

    const FanoutRowAssembly = struct {
        values: []f64,
        present: []bool,

        fn init(alloc: std.mem.Allocator, column_count: usize) !FanoutRowAssembly {
            const values = try alloc.alloc(f64, column_count);
            errdefer alloc.free(values);
            const present = try alloc.alloc(bool, column_count);
            @memset(present, false);
            return .{ .values = values, .present = present };
        }

        fn deinit(self: *FanoutRowAssembly, alloc: std.mem.Allocator) void {
            alloc.free(self.values);
            alloc.free(self.present);
            self.* = undefined;
        }
    };

    const MarketShadowDifference = struct {
        reason: []const u8,
        row_index: ?usize = null,
        column_index: ?usize = null,
        market_series_id: ?market_identity_mod.MarketSeriesId = null,
        ts_ns: ?i64 = null,
    };

    /// Execute a logical market query against live state or one immutable CAS
    /// revision. The returned value owns all strings, columns, rows, and values.
    pub fn queryMarket(self: *Engine, request: MarketQueryRequest) !MarketQueryResult {
        if (request.metric.len == 0) return error.UnknownMarketSchema;
        if (request.start_ts_ns > request.end_ts_ns) return error.InvalidTimeRange;

        const canonical_filter = if (request.label_filter_json) |raw|
            market_identity_mod.canonicalizeLabels(self.alloc, raw) catch |err| switch (err) {
                error.OutOfMemory, error.WriteFailed => return error.OutOfMemory,
                else => return error.InvalidMarketLabels,
            }
        else
            null;
        defer if (canonical_filter) |filter| self.alloc.free(filter);

        const normalized = MarketQueryRequest{
            .metric = request.metric,
            .label_filter_json = canonical_filter,
            .start_ts_ns = request.start_ts_ns,
            .end_ts_ns = request.end_ts_ns,
            .requested_columns = request.requested_columns,
            .revision = request.revision,
        };

        if (request.revision) |revision_spec| {
            if (revision_spec.len == 0) return error.InvalidRevisionSpec;
            var manager = if (self.cas) |*cas| cas else return error.NativeRevisionUnavailable;
            const snapshot = try manager.loadSnapshotForSpec(revision_spec);
            var index = cas_mod.SnapshotIndex.init(self.alloc, &manager.store, snapshot);
            defer index.deinit();
            return try self.queryMarketBound(.{ .revision = &index }, normalized);
        }

        self.market_data_mu.lock();
        defer self.market_data_mu.unlock();
        return try self.queryMarketBound(.live, normalized);
    }

    fn queryMarketBound(
        self: *Engine,
        source: MarketQuerySource,
        request: MarketQueryRequest,
    ) !MarketQueryResult {
        var schema = try self.marketSchemaForQuery(source, request.metric);
        defer schema.deinit(self.alloc);

        const read_mode: cfg.MarketStorageReadMode = switch (self.config.market_storage_read_mode) {
            .auto => switch (schema.storage_mapping) {
                .fanout_v1 => .fanout,
                .native_v1 => .native,
            },
            else => |mode| mode,
        };

        return switch (read_mode) {
            .auto => unreachable,
            .fanout => try self.queryMarketFanout(source, schema, request),
            .native => try self.queryMarketNative(source, request),
            .shadow => try self.queryMarketShadow(source, schema, request),
        };
    }

    fn marketSchemaForQuery(
        self: *Engine,
        source: MarketQuerySource,
        metric: []const u8,
    ) !market_catalog_mod.MarketSchema {
        return switch (source) {
            .live => self.metadata.market_catalog.getSchema(metric) orelse
                error.UnknownMarketSchema,
            .revision => |index| blk: {
                const catalog_snapshot = index.snapshot.market_catalog_snapshot orelse
                    return error.NativeMarketDataUnavailable;
                for (catalog_snapshot.schemas) |schema| {
                    if (std.mem.eql(u8, schema.metric, metric)) {
                        break :blk try schema.clone(self.alloc);
                    }
                }
                return error.UnknownMarketSchema;
            },
        };
    }

    fn queryMarketNative(
        self: *Engine,
        source: MarketQuerySource,
        request: MarketQueryRequest,
    ) !MarketQueryResult {
        var reader = switch (source) {
            .live => market_reader_mod.MarketReader.init(
                self.alloc,
                self.data_dir,
                &self.metadata.market_catalog,
                &self.market_manifest,
                &self.market_mem,
            ),
            .revision => |index| market_reader_mod.MarketReader.initRevision(self.alloc, index),
        };
        var native = try reader.query(.{
            .metric = request.metric,
            .label_filter_json = request.label_filter_json,
            .start_ts_ns = request.start_ts_ns,
            .end_ts_ns = request.end_ts_ns,
            .requested_columns = request.requested_columns,
            .revision = if (request.revision) |revision|
                .{ .value = revision }
            else
                null,
        });
        errdefer native.deinit();
        return takeNativeMarketResult(self.alloc, &native);
    }

    fn queryMarketShadow(
        self: *Engine,
        source: MarketQuerySource,
        schema: market_catalog_mod.MarketSchema,
        request: MarketQueryRequest,
    ) !MarketQueryResult {
        const full_request = MarketQueryRequest{
            .metric = request.metric,
            .label_filter_json = request.label_filter_json,
            .start_ts_ns = request.start_ts_ns,
            .end_ts_ns = request.end_ts_ns,
            .requested_columns = &.{},
            .revision = request.revision,
        };
        var fanout = try self.queryMarketFanout(source, schema, full_request);
        errdefer fanout.deinit();
        var native = try self.queryMarketNative(source, full_request);
        defer native.deinit();

        if (marketShadowDifference(fanout, native)) |difference| {
            _ = self.metrics.market_shadow_mismatch_total.fetchAdd(1, .monotonic);
            std.log.warn(
                "market shadow mismatch metric={s} reason={s} row_index={?d} column_index={?d} market_series_id={?d} ts_ns={?d}",
                .{
                    request.metric,
                    difference.reason,
                    difference.row_index,
                    difference.column_index,
                    difference.market_series_id,
                    difference.ts_ns,
                },
            );
            return error.ShadowMismatch;
        }

        fanout.stats = .{
            .storage_mode = "shadow",
            .series_scanned = fanout.stats.series_scanned + native.stats.series_scanned,
            .blocks_scanned = fanout.stats.blocks_scanned + native.stats.blocks_scanned,
            .blocks_pruned = fanout.stats.blocks_pruned + native.stats.blocks_pruned,
            .columns_read = fanout.stats.columns_read + native.stats.columns_read,
            .bytes_decoded = fanout.stats.bytes_decoded + native.stats.bytes_decoded,
            .shadow_mismatches = 0,
        };
        try projectMarketResult(&fanout, request.requested_columns);
        return fanout;
    }

    fn queryMarketFanout(
        self: *Engine,
        source: MarketQuerySource,
        schema: market_catalog_mod.MarketSchema,
        request: MarketQueryRequest,
    ) !MarketQueryResult {
        var projection = try MarketProjection.resolve(
            self.alloc,
            schema.ordered_columns,
            request.requested_columns,
        );
        defer projection.deinit(self.alloc);

        const registered = try self.marketSeriesForQuery(source);
        defer {
            for (registered) |*series| series.deinit(self.alloc);
            self.alloc.free(registered);
        }

        var result_rows = std.array_list.Managed(MarketQueryRow).init(self.alloc);
        errdefer {
            for (result_rows.items) |*row| row.deinit(self.alloc);
            result_rows.deinit();
        }
        var stats = MarketQueryStats{ .storage_mode = "fanout" };

        for (registered) |series| {
            if (!std.mem.eql(u8, series.metric, request.metric)) continue;
            if (!try marketLabelsMatch(
                self.alloc,
                request.label_filter_json,
                series.canonical_labels,
            )) continue;
            const schema_digest = schema.digest();
            if (!std.mem.eql(u8, series.schema_digest[0..], schema_digest[0..])) {
                return error.MarketSchemaMismatch;
            }
            stats.series_scanned += 1;

            var assemblies = std.AutoHashMap(i64, FanoutRowAssembly).init(self.alloc);
            defer {
                var values = assemblies.valueIterator();
                while (values.next()) |assembly| assembly.deinit(self.alloc);
                assemblies.deinit();
            }

            for (schema.ordered_columns, 0..) |column, column_idx| {
                const derived_metric = try std.fmt.allocPrint(
                    self.alloc,
                    "{s}.{s}",
                    .{ request.metric, column },
                );
                defer self.alloc.free(derived_metric);
                const scalar_series_id = types.seriesIdFrom(
                    derived_metric,
                    series.canonical_labels,
                );
                var points = std.array_list.Managed(types.Point).init(self.alloc);
                defer points.deinit();
                try self.queryFanoutColumn(
                    source,
                    scalar_series_id,
                    request.start_ts_ns,
                    request.end_ts_ns,
                    &points,
                    &stats,
                );
                stats.columns_read += 1;
                stats.bytes_decoded += @intCast(points.items.len * @sizeOf(types.Point));

                for (points.items) |point| {
                    const gop = try assemblies.getOrPut(point.ts);
                    if (!gop.found_existing) {
                        gop.value_ptr.* = try FanoutRowAssembly.init(
                            self.alloc,
                            schema.ordered_columns.len,
                        );
                    }
                    // Persisted descriptors are visited in publication order,
                    // followed by the live memtable. Later corrections win.
                    gop.value_ptr.values[column_idx] = point.value;
                    gop.value_ptr.present[column_idx] = true;
                }
            }

            var assembly_it = assemblies.iterator();
            while (assembly_it.next()) |entry| {
                const assembly = entry.value_ptr;
                for (assembly.present) |present| {
                    if (!present) return error.IncompleteMarketRow;
                }
                const projected_values = try self.alloc.alloc(f64, projection.indices.len);
                errdefer self.alloc.free(projected_values);
                for (projection.indices, 0..) |source_idx, projected_idx| {
                    projected_values[projected_idx] = assembly.values[source_idx];
                }
                const metric = try self.alloc.dupe(u8, request.metric);
                errdefer self.alloc.free(metric);
                const labels = try self.alloc.dupe(u8, series.canonical_labels);
                errdefer self.alloc.free(labels);
                try result_rows.append(.{
                    .market_series_id = series.series_id,
                    .metric = metric,
                    .canonical_labels = labels,
                    .ts_ns = entry.key_ptr.*,
                    .values = projected_values,
                });
            }
        }

        std.sort.block(MarketQueryRow, result_rows.items, {}, marketQueryRowLessThan);
        const metric = try self.alloc.dupe(u8, request.metric);
        errdefer self.alloc.free(metric);
        const rows = try result_rows.toOwnedSlice();
        errdefer {
            for (rows) |*row| row.deinit(self.alloc);
            self.alloc.free(rows);
        }
        const requested_columns = projection.takeNames();
        return .{
            .allocator = self.alloc,
            .metric = metric,
            .requested_columns = requested_columns,
            .rows = rows,
            .stats = stats,
        };
    }

    fn marketSeriesForQuery(
        self: *Engine,
        source: MarketQuerySource,
    ) ![]market_catalog_mod.MarketSeriesIdentity {
        return switch (source) {
            .live => try self.metadata.market_catalog.listMarketSeries(),
            .revision => |index| blk: {
                const snapshot = index.snapshot.market_catalog_snapshot orelse
                    return error.NativeMarketDataUnavailable;
                const source_entries = snapshot.market_series orelse
                    return error.NativeMarketDataUnavailable;
                const entries = try self.alloc.alloc(
                    market_catalog_mod.MarketSeriesIdentity,
                    source_entries.len,
                );
                errdefer self.alloc.free(entries);
                var initialized: usize = 0;
                errdefer for (entries[0..initialized]) |*entry| entry.deinit(self.alloc);
                for (source_entries, 0..) |entry, idx| {
                    entries[idx] = try entry.clone(self.alloc);
                    initialized += 1;
                }
                break :blk entries;
            },
        };
    }

    fn queryFanoutColumn(
        self: *Engine,
        source: MarketQuerySource,
        series_id: types.SeriesId,
        start_ts: i64,
        end_ts: i64,
        out: *std.array_list.Managed(types.Point),
        stats: *MarketQueryStats,
    ) !void {
        switch (source) {
            .live => {
                for (self.metadata.manifest.entries.items) |descriptor| {
                    if (descriptor.series_id != series_id) continue;
                    if (descriptor.end_ts < start_ts or descriptor.start_ts > end_ts) {
                        stats.blocks_pruned += 1;
                    } else {
                        stats.blocks_scanned += 1;
                    }
                }
                try segment_mod.queryRange(
                    self.alloc,
                    self.data_dir,
                    &self.metadata.manifest,
                    series_id,
                    start_ts,
                    end_ts,
                    out,
                );
                if (self.mem.series.getPtr(series_id)) |buffer| {
                    for (buffer.points.items) |point| {
                        if (point.ts >= start_ts and point.ts <= end_ts) {
                            try out.append(point);
                        }
                    }
                }
            },
            .revision => |index| {
                for (index.snapshot.segment_descriptors) |descriptor| {
                    if (descriptor.series_id != series_id) continue;
                    if (descriptor.end_ts < start_ts or descriptor.start_ts > end_ts) {
                        stats.blocks_pruned += 1;
                    } else {
                        stats.blocks_scanned += 1;
                    }
                }
                try index.queryRange(
                    self.alloc,
                    self.data_dir,
                    series_id,
                    start_ts,
                    end_ts,
                    out,
                );
            },
        }
    }

    fn findMarketColumn(columns: []const []u8, requested: []const u8) ?usize {
        for (columns, 0..) |column, idx| {
            if (std.mem.eql(u8, column, requested)) return idx;
        }
        return null;
    }

    fn marketQueryRowLessThan(_: void, lhs: MarketQueryRow, rhs: MarketQueryRow) bool {
        const labels_order = std.mem.order(u8, lhs.canonical_labels, rhs.canonical_labels);
        if (labels_order != .eq) return labels_order == .lt;
        if (lhs.ts_ns != rhs.ts_ns) return lhs.ts_ns < rhs.ts_ns;
        return lhs.market_series_id < rhs.market_series_id;
    }

    fn marketLabelsMatch(
        alloc: std.mem.Allocator,
        canonical_filter: ?[]const u8,
        canonical_labels: []const u8,
    ) !bool {
        const filter_json = canonical_filter orelse return true;
        var parsed_filter = std.json.parseFromSlice(
            std.json.Value,
            alloc,
            filter_json,
            .{},
        ) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return error.InvalidMarketLabels,
        };
        defer parsed_filter.deinit();
        var parsed_labels = std.json.parseFromSlice(
            std.json.Value,
            alloc,
            canonical_labels,
            .{},
        ) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return error.InvalidMarketLabels,
        };
        defer parsed_labels.deinit();
        if (parsed_filter.value != .object or parsed_labels.value != .object) {
            return error.InvalidMarketLabels;
        }
        var iterator = parsed_filter.value.object.iterator();
        while (iterator.next()) |entry| {
            const actual = parsed_labels.value.object.get(entry.key_ptr.*) orelse return false;
            if (!marketJsonValueEql(entry.value_ptr.*, actual)) return false;
        }
        return true;
    }

    fn marketJsonValueEql(lhs: std.json.Value, rhs: std.json.Value) bool {
        if (std.meta.activeTag(lhs) != std.meta.activeTag(rhs)) return false;
        return switch (lhs) {
            .null => true,
            .bool => |value| value == rhs.bool,
            .integer => |value| value == rhs.integer,
            .float => |value| value == rhs.float,
            .number_string => |value| std.mem.eql(u8, value, rhs.number_string),
            .string => |value| std.mem.eql(u8, value, rhs.string),
            .array => |array| blk: {
                if (array.items.len != rhs.array.items.len) break :blk false;
                for (array.items, rhs.array.items) |left, right| {
                    if (!marketJsonValueEql(left, right)) break :blk false;
                }
                break :blk true;
            },
            .object => |object| blk: {
                if (object.count() != rhs.object.count()) break :blk false;
                var iterator = object.iterator();
                while (iterator.next()) |entry| {
                    const right = rhs.object.get(entry.key_ptr.*) orelse break :blk false;
                    if (!marketJsonValueEql(entry.value_ptr.*, right)) break :blk false;
                }
                break :blk true;
            },
        };
    }

    fn takeNativeMarketResult(
        alloc: std.mem.Allocator,
        native: *market_reader_mod.QueryResult,
    ) !MarketQueryResult {
        const rows = try alloc.alloc(MarketQueryRow, native.rows.len);
        for (native.rows, 0..) |row, idx| {
            rows[idx] = .{
                .market_series_id = row.market_series_id,
                .metric = row.metric,
                .canonical_labels = row.canonical_labels,
                .ts_ns = row.ts_ns,
                .values = row.values,
            };
        }
        const result = MarketQueryResult{
            .allocator = alloc,
            .metric = native.metric,
            .requested_columns = native.requested_columns,
            .rows = rows,
            .stats = .{
                .storage_mode = native.stats.storage_mode,
                .series_scanned = native.stats.series_scanned,
                .blocks_scanned = native.stats.blocks_scanned,
                .blocks_pruned = native.stats.blocks_pruned,
                .columns_read = native.stats.columns_read,
                .bytes_decoded = native.stats.bytes_decoded,
                .shadow_mismatches = native.stats.shadow_mismatches,
            },
        };
        alloc.free(native.rows);
        native.* = undefined;
        return result;
    }

    fn marketShadowDifference(
        fanout: MarketQueryResult,
        native: MarketQueryResult,
    ) ?MarketShadowDifference {
        if (!std.mem.eql(u8, fanout.metric, native.metric)) {
            return .{ .reason = "metric" };
        }
        if (fanout.requested_columns.len != native.requested_columns.len) {
            return .{ .reason = "column_count" };
        }
        for (fanout.requested_columns, native.requested_columns, 0..) |left, right, idx| {
            if (!std.mem.eql(u8, left, right)) {
                return .{ .reason = "column_order", .column_index = idx };
            }
        }
        if (fanout.rows.len != native.rows.len) return .{ .reason = "row_count" };
        for (fanout.rows, native.rows, 0..) |left, right, row_idx| {
            const context = MarketShadowDifference{
                .reason = undefined,
                .row_index = row_idx,
                .market_series_id = left.market_series_id,
                .ts_ns = left.ts_ns,
            };
            if (left.market_series_id != right.market_series_id) {
                var difference = context;
                difference.reason = "market_series_id";
                return difference;
            }
            if (!std.mem.eql(u8, left.metric, right.metric)) {
                var difference = context;
                difference.reason = "row_metric";
                return difference;
            }
            if (!std.mem.eql(u8, left.canonical_labels, right.canonical_labels)) {
                var difference = context;
                difference.reason = "labels";
                return difference;
            }
            if (left.ts_ns != right.ts_ns) {
                var difference = context;
                difference.reason = "timestamp";
                return difference;
            }
            if (left.values.len != right.values.len) {
                var difference = context;
                difference.reason = "value_count";
                return difference;
            }
            for (left.values, right.values, 0..) |left_value, right_value, column_idx| {
                if (@as(u64, @bitCast(left_value)) != @as(u64, @bitCast(right_value))) {
                    var difference = context;
                    difference.reason = "value_bits";
                    difference.column_index = column_idx;
                    return difference;
                }
            }
        }
        return null;
    }

    fn projectMarketResult(
        result: *MarketQueryResult,
        requested_columns: []const []const u8,
    ) !void {
        if (requested_columns.len == 0) return;
        var projection = try MarketProjection.resolve(
            result.allocator,
            result.requested_columns,
            requested_columns,
        );
        defer projection.deinit(result.allocator);

        const projected_values = try result.allocator.alloc([]f64, result.rows.len);
        errdefer result.allocator.free(projected_values);
        var initialized: usize = 0;
        errdefer for (projected_values[0..initialized]) |values| result.allocator.free(values);
        for (result.rows, 0..) |row, row_idx| {
            const values = try result.allocator.alloc(f64, projection.indices.len);
            for (projection.indices, 0..) |source_idx, output_idx| {
                values[output_idx] = row.values[source_idx];
            }
            projected_values[row_idx] = values;
            initialized += 1;
        }

        for (result.rows, projected_values) |*row, values| {
            result.allocator.free(row.values);
            row.values = values;
        }
        result.allocator.free(projected_values);
        for (result.requested_columns) |column| result.allocator.free(column);
        result.allocator.free(result.requested_columns);
        result.requested_columns = projection.takeNames();
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
        return try self.registerMarketSchemaWithStorageMappingOverride(input, null);
    }

    pub fn registerMarketSchemaWithStorageMappingOverride(
        self: *Engine,
        input: market_catalog_mod.MarketSchemaInput,
        explicit_storage_mapping: ?market_catalog_mod.StorageMapping,
    ) !market_catalog_mod.MarketSchema {
        const storage_mapping = try self.marketSchemaRegistrationMapping(input, explicit_storage_mapping);
        const stored = try self.metadata.market_catalog.registerSchema(marketSchemaInputWithMapping(input, storage_mapping));
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
                        if (self.metadata.simpleSelectorMatchesFromCas(.{ .by_id = series_id }, legacy)) |matches| {
                            if (!matches) {
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
                        if (self.metadata.simpleSelectorMatchesFromCas(.{ .name = series }, legacy)) |matches| {
                            if (!matches) {
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
                        if (try self.metadata.exactSelectorMatchesFromCas(exact.series, exact.tags_json, legacy)) |matches| {
                            if (!matches) {
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

    /// Resolves a simple selector into allocator-owned metadata for compiled plans.
    pub fn resolveSimpleSelectorOwned(
        self: *Engine,
        allocator: std.mem.Allocator,
        lookup: SimpleSelectorLookup,
    ) std.mem.Allocator.Error!series_catalog_mod.Resolution {
        const legacy_view = self.metadata.legacyView();
        return switch (self.config.metadata_read_mode) {
            .legacy => try cloneSelectorResolution(allocator, switch (lookup) {
                .by_id => |series_id| legacy_view.resolveBySeriesId(series_id),
                .name => |series| legacy_view.resolveUniqueSeriesNameDetailed(series),
            }),
            .shadow => blk: {
                const legacy_resolution = switch (lookup) {
                    .by_id => |series_id| legacy_view.resolveBySeriesId(series_id),
                    .name => |series| legacy_view.resolveUniqueSeriesNameDetailed(series),
                };
                if (self.metadata.simpleSelectorMatchesFromCas(lookup, legacy_resolution)) |matches| {
                    if (!matches) {
                        self.recordCasShadowMismatch();
                        switch (lookup) {
                            .by_id => |series_id| std.log.warn("cas shadow mismatch: resolveBySeriesId series_id={d}", .{series_id}),
                            .name => |series| std.log.warn("cas shadow mismatch: resolveUniqueSeriesName series='{s}'", .{series}),
                        }
                    }
                }
                break :blk try cloneSelectorResolution(allocator, legacy_resolution);
            },
            .primary => blk: {
                if (try self.metadata.resolveSimpleSelectorOwnedFromCas(allocator, lookup)) |resolution| {
                    break :blk resolution;
                }
                const legacy_resolution = switch (lookup) {
                    .by_id => |series_id| legacy_view.resolveBySeriesId(series_id),
                    .name => |series| legacy_view.resolveUniqueSeriesNameDetailed(series),
                };
                break :blk try cloneSelectorResolution(allocator, legacy_resolution);
            },
        };
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
        inputs: []const PreparedExactSeriesCanonicalDeclarationInput,
        results: []const ExactSeriesBatchDeclarationResult,
    ) !void {
        var batch_inputs = std.array_list.Managed(tags_mod.BatchAddInput).init(self.alloc);
        defer batch_inputs.deinit();
        for (inputs, results) |input, result| {
            if (result.status != .ok or result.registration != .inserted) continue;
            const series_id = result.series_id orelse continue;
            for (input.tag_pairs) |pair| {
                try batch_inputs.append(.{
                    .label = pair.label,
                    .value = pair.value,
                    .series_id = series_id,
                });
            }
        }

        if (batch_inputs.items.len == 0) return;

        std.sort.block(tags_mod.BatchAddInput, batch_inputs.items, {}, struct {
            fn lessThan(_: void, lhs: tags_mod.BatchAddInput, rhs: tags_mod.BatchAddInput) bool {
                const label_order = std.mem.order(u8, lhs.label, rhs.label);
                if (label_order != .eq) return label_order == .lt;
                const value_order = std.mem.order(u8, lhs.value, rhs.value);
                if (value_order != .eq) return value_order == .lt;
                return lhs.series_id < rhs.series_id;
            }
        }.lessThan);

        const inserted_total = self.metadata.tags.addBatch(batch_inputs.items) catch |err| {
            std.log.warn("tag index batch add failed: {s}", .{@errorName(err)});
            return;
        };
        if (inserted_total != 0) self.tag_index_dirty.store(true, .monotonic);
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

        var created_series = std.array_list.Managed(types.SeriesId).init(self.alloc);
        defer created_series.deinit();
        try created_series.ensureTotalCapacity(points.len);
        var preflight_committed = false;
        defer if (!preflight_committed) {
            for (created_series.items) |series_id| {
                if (self.mem.series.getPtr(series_id)) |buffer| buffer.deinit();
                _ = self.mem.series.remove(series_id);
            }
        };

        var start: usize = 0;
        while (start < points.len) {
            const sid = points[start].series_id;
            var end = start + 1;
            while (end < points.len and points[end].series_id == sid) : (end += 1) {}

            const gop = try self.mem.series.getOrPut(sid);
            if (!gop.found_existing) {
                gop.value_ptr.* = MemSeriesBuffer.init(self.alloc);
                created_series.appendAssumeCapacity(sid);
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
        preflight_committed = true;
    }

    pub fn verifyCasState(self: *Engine) !void {
        self.wal.lockForSnapshot();
        defer self.wal.unlockForSnapshot();
        if (self.cas) |*cas| {
            return try cas.verifyHeadMatchesLegacyWithNativeMarket(
                self.data_dir,
                &self.metadata.manifest,
                &self.metadata.tags,
                &self.metadata.series_catalog,
                &self.metadata.metric_catalog,
                &self.metadata.market_catalog,
                &self.market_manifest,
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
        try self.wal.sync();
        try resumeWriterAfterMaintenance(self);
        return flushed;
    }

    pub fn flushAndDrain(self: *Engine, timeout_ms: u64) !bool {
        const prior_flush_generation = self.requestFlush();
        self.queue.wake();
        const wait_result = try self.waitForDrainedState(timeout_ms, false, prior_flush_generation);
        if (wait_result.publication_error) |err| return err;
        self.drain_mu.lock();
        defer self.drain_mu.unlock();
        return self.flush_generation != prior_flush_generation;
    }

    pub fn waitForDrained(self: *Engine, timeout_ms: u64) WaitError!void {
        _ = try self.waitForDrainedState(timeout_ms, true, null);
    }

    const DrainWaitResult = struct {
        publication_error: ?anyerror = null,
    };

    fn waitForDrainedState(
        self: *Engine,
        timeout_ms: u64,
        verify_cas: bool,
        publication_error_after_flush: ?u64,
    ) WaitError!DrainWaitResult {
        const wait_start_ns = std.time.nanoTimestamp();
        const deadline_ns: i128 = std.time.nanoTimestamp() + @as(i128, @intCast(timeout_ms)) * std.time.ns_per_ms;
        while (true) {
            self.drain_mu.lock();
            const generation = self.drain_generation;
            const flush_in_progress = self.flush_in_progress;
            const flush_generation = self.flush_generation;
            const publication_error = self.flush_publication_error;
            self.drain_mu.unlock();

            if (publication_error_after_flush) |baseline| {
                if (flush_generation != baseline) {
                    if (publication_error) |err| {
                        _ = self.metrics.flush_queue_drain_wait_ns_total.fetchAdd(@intCast(std.time.nanoTimestamp() - wait_start_ns), .monotonic);
                        return .{ .publication_error = err };
                    }
                }
            }

            if (self.queue.isDrained() and self.liveMemtableBytes() == 0 and !flush_in_progress) {
                if (verify_cas and self.cas != null) {
                    self.verifyCasState() catch {
                        const now_ns = std.time.nanoTimestamp();
                        if (now_ns >= deadline_ns) break;
                        self.drain_mu.lock();
                        const remaining_ns: u64 = @intCast(deadline_ns - now_ns);
                        self.drain_cv.timedWait(&self.drain_mu, remaining_ns) catch {};
                        self.drain_mu.unlock();
                        continue;
                    };
                }
                _ = self.metrics.flush_queue_drain_wait_ns_total.fetchAdd(@intCast(std.time.nanoTimestamp() - wait_start_ns), .monotonic);
                return .{};
            }
            const now_ns = std.time.nanoTimestamp();
            if (now_ns >= deadline_ns) break;

            self.drain_mu.lock();
            if (generation == self.drain_generation) {
                const remaining_ns: u64 = @intCast(deadline_ns - now_ns);
                self.drain_cv.timedWait(&self.drain_mu, remaining_ns) catch {};
            }
            self.drain_mu.unlock();
        }
        _ = self.metrics.flush_queue_drain_wait_ns_total.fetchAdd(@intCast(std.time.nanoTimestamp() - wait_start_ns), .monotonic);
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
        const flushed = try flushMemtable(self);
        if (self.cas) |*cas| {
            try self.metadata.refreshCasIndexIfStale(cas);
        }
        const scalar_changed = if (self.cas != null and self.metadata.hasCasIndex())
            try compactCasBackedSegments(self)
        else
            try @import("storage/compact.zig").compactAllWithResult(self.alloc, self.data_dir, &self.metadata.manifest);

        var obsolete_market_mirrors = ObsoleteMarketMirrors.init(self.alloc);
        defer obsolete_market_mirrors.deinit();
        const market_changed = try compactNativeMarketSegments(
            self,
            &obsolete_market_mirrors,
        );
        const compacted = scalar_changed or market_changed;
        if (compacted) {
            try self.createMaintenanceCheckpoint("compaction");
        }
        if (flushed or compacted) {
            try self.syncCasSnapshot(if (compacted) "compaction" else "compaction-flush");
        }
        if (market_changed) {
            deleteObsoleteMarketMirrors(self, obsolete_market_mirrors.paths.items);
        }
        try resumeWriterAfterMaintenance(self);
        return compacted;
    }

    fn syncCasSnapshot(self: *Engine, reason: []const u8) !void {
        self.wal.lockForSnapshot();
        defer self.wal.unlockForSnapshot();
        if (self.cas) |*cas| {
            const start_ns = std.time.nanoTimestamp();
            errdefer _ = self.metrics.cas_sync_failed_total.fetchAdd(1, .monotonic);
            _ = try cas.syncLegacySnapshotWithNativeMarket(
                self.data_dir,
                &self.metadata.manifest,
                &self.metadata.tags,
                &self.metadata.series_catalog,
                &self.metadata.metric_catalog,
                &self.metadata.market_catalog,
                &self.market_manifest,
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
        self.wal.lockForSnapshot();
        defer self.wal.unlockForSnapshot();
        if (self.cas) |*cas| {
            if (try cas.refs.readHead(cas_mod.main_ref) == null) {
                _ = try cas.bootstrapIfMissingWithNativeMarket(
                    self.data_dir,
                    &self.metadata.manifest,
                    &self.metadata.tags,
                    &self.metadata.series_catalog,
                    &self.metadata.metric_catalog,
                    &self.metadata.market_catalog,
                    &self.market_manifest,
                );
            } else {
                _ = try cas.syncLegacySnapshotWithNativeMarket(
                    self.data_dir,
                    &self.metadata.manifest,
                    &self.metadata.tags,
                    &self.metadata.series_catalog,
                    &self.metadata.metric_catalog,
                    &self.metadata.market_catalog,
                    &self.market_manifest,
                    "snapshot",
                );
            }
            try self.metadata.refreshCasIndex(cas);
            return;
        }

        var temp = try cas_mod.CasManager.init(self.alloc, self.config.data_dir, self.config.fsync);
        defer temp.deinit();
        if (try temp.refs.readHead(cas_mod.main_ref) == null) {
            _ = try temp.bootstrapIfMissingWithNativeMarket(
                self.data_dir,
                &self.metadata.manifest,
                &self.metadata.tags,
                &self.metadata.series_catalog,
                &self.metadata.metric_catalog,
                &self.metadata.market_catalog,
                &self.market_manifest,
            );
        } else {
            _ = try temp.syncLegacySnapshotWithNativeMarket(
                self.data_dir,
                &self.metadata.manifest,
                &self.metadata.tags,
                &self.metadata.series_catalog,
                &self.metadata.metric_catalog,
                &self.metadata.market_catalog,
                &self.market_manifest,
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

        var market_registrations = std.AutoHashMap(market_identity_mod.MarketSeriesId, MarketReplayRegistration).init(self.alloc);
        defer {
            var values = market_registrations.valueIterator();
            while (values.next()) |registration| registration.deinit(self.alloc);
            market_registrations.deinit();
        }

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
        var max_market_sequence: u64 = 0;

        var ctx = struct {
            engine: *Engine,
            highwater: *std.AutoHashMap(types.SeriesId, i64),
            market_registrations: *std.AutoHashMap(market_identity_mod.MarketSeriesId, MarketReplayRegistration),
            max_market_sequence: *u64,

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

            pub fn onMarketSeriesRegistration(
                self_ctx: *@This(),
                market_series_id: market_identity_mod.MarketSeriesId,
                schema_digest: market_identity_mod.SchemaDigest,
                metric: []const u8,
                canonical_labels: []const u8,
            ) !void {
                try self_ctx.engine.requireRepositoryFormat4ForNativeMarket();
                const recanonicalized = try market_identity_mod.canonicalizeLabels(self_ctx.engine.alloc, canonical_labels);
                defer self_ctx.engine.alloc.free(recanonicalized);
                if (!std.mem.eql(u8, recanonicalized, canonical_labels)) return error.NonCanonicalMarketLabels;
                if (market_identity_mod.seriesId(metric, canonical_labels) != market_series_id) return error.MarketSeriesIdMismatch;

                var schema = self_ctx.engine.marketSchema(metric) orelse return error.UnknownMarketSchema;
                defer schema.deinit(self_ctx.engine.alloc);
                try market_identity_mod.validateRequiredLabels(
                    self_ctx.engine.alloc,
                    canonical_labels,
                    schema.required_labels,
                );
                const expected_digest = schema.digest();
                if (!std.mem.eql(u8, expected_digest[0..], schema_digest[0..])) {
                    return error.MarketSchemaConflict;
                }
                var identity = try self_ctx.engine.metadata.market_catalog.registerMarketSeriesWithId(
                    market_series_id,
                    metric,
                    canonical_labels,
                );
                defer identity.deinit(self_ctx.engine.alloc);
                if (!std.mem.eql(u8, identity.schema_digest[0..], schema_digest[0..])) {
                    return error.MarketSchemaConflict;
                }

                if (self_ctx.market_registrations.getPtr(market_series_id)) |existing| {
                    if (!std.mem.eql(u8, existing.schema_digest[0..], schema_digest[0..]) or
                        !std.mem.eql(u8, existing.metric, metric) or
                        !std.mem.eql(u8, existing.canonical_labels, canonical_labels) or
                        existing.column_count != schema.ordered_columns.len)
                    {
                        return error.MarketSeriesConflict;
                    }
                    return;
                }

                const metric_copy = try self_ctx.engine.alloc.dupe(u8, metric);
                errdefer self_ctx.engine.alloc.free(metric_copy);
                const labels_copy = try self_ctx.engine.alloc.dupe(u8, canonical_labels);
                errdefer self_ctx.engine.alloc.free(labels_copy);
                const registration = MarketReplayRegistration{
                    .schema_digest = schema_digest,
                    .metric = metric_copy,
                    .canonical_labels = labels_copy,
                    .column_count = schema.ordered_columns.len,
                };
                try self_ctx.market_registrations.put(market_series_id, registration);
            }

            pub fn onMarketRow(
                self_ctx: *@This(),
                market_series_id: market_identity_mod.MarketSeriesId,
                write_sequence: u64,
                ts_ns: i64,
                values: []const f64,
            ) !void {
                if (write_sequence > self_ctx.max_market_sequence.*) {
                    self_ctx.max_market_sequence.* = write_sequence;
                }
                const registration = self_ctx.market_registrations.get(market_series_id) orelse return error.OrphanMarketRow;
                try market_identity_mod.validateValueShape(registration.column_count, values.len);

                try self_ctx.engine.market_mem.appendBatch(&.{.{
                    .market_series_id = market_series_id,
                    .metric = registration.metric,
                    .canonical_labels = registration.canonical_labels,
                    .schema_digest = registration.schema_digest,
                    .ts_ns = ts_ns,
                    .write_sequence = write_sequence,
                    .values = values,
                }});
                self_ctx.engine.market_mem_allocated_bytes.store(self_ctx.engine.market_mem.allocatedBytes(), .monotonic);
                self_ctx.engine.market_mem_resident_bytes.store(self_ctx.engine.market_mem.residentBytes(), .monotonic);
                try self_ctx.engine.appendRecoveredMarketFanout(registration, ts_ns, values);
            }
        }{
            .engine = self,
            .highwater = &highwater,
            .market_registrations = &market_registrations,
            .max_market_sequence = &max_market_sequence,
        };

        if (try self.replayRecoveryWalFromCas(&ctx)) {
            // CAS snapshot replay handled above, including any explicit live WAL tail.
        } else if (try self.recoveryWalFiles()) |files| {
            defer wal_mod.freeWalFiles(self.alloc, files);
            try self.wal.replayFiles(self.alloc, files, &ctx);
        } else {
            try self.wal.replay(self.alloc, &ctx);
        }
        try self.advanceNextMarketWriteSequencePast(max_market_sequence);
        if (self.liveMemtableBytes() > 0) {
            const flushed = try flushMemtable(self);
            if (flushed) try self.syncCasSnapshot("recovery-flush");
        }
    }

    /// Refresh the next sequence from native segments after the caller drains
    /// queued writes and flushes live market memtable rows.
    pub fn refreshNextMarketWriteSequenceFromPersistedSegments(self: *Engine) !void {
        var maximum: u64 = 0;
        for (self.market_manifest.list()) |descriptor| {
            var segment = try market_segment_mod.readProjectedRange(
                self.alloc,
                self.data_dir,
                descriptor.path,
                std.math.minInt(i64),
                std.math.maxInt(i64),
                &.{},
            );
            defer segment.deinit(self.alloc);
            for (segment.write_sequences) |sequence| {
                if (sequence > maximum) maximum = sequence;
            }
        }
        try self.advanceNextMarketWriteSequencePast(maximum);
    }

    fn advanceNextMarketWriteSequencePast(self: *Engine, maximum: u64) !void {
        if (maximum >= self.next_market_write_sequence) {
            self.next_market_write_sequence = std.math.add(u64, maximum, 1) catch
                return error.MarketWriteSequenceOverflow;
        }
    }

    fn registerSeriesInternal(self: *Engine, series: []const u8, tags: []const u8, series_id: types.SeriesId, record_wal: bool) !void {
        const inserted = try self.metadata.series_catalog.register(series, tags, series_id);
        self.noteTags(series_id, tags);
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

    fn prepareExactSeriesCanonicalDeclarations(
        self: *Engine,
        inputs: []const ExactSeriesCanonicalDeclarationInput,
    ) ![]PreparedExactSeriesCanonicalDeclarationInput {
        const prepared = try self.alloc.alloc(PreparedExactSeriesCanonicalDeclarationInput, inputs.len);
        var prepared_len: usize = 0;
        errdefer {
            for (prepared[0..prepared_len]) |*input| input.deinit(self.alloc);
            self.alloc.free(prepared);
        }

        var selector_key_ns_total: u64 = 0;
        var tag_pairs_total: u64 = 0;
        for (inputs, 0..) |input, idx| {
            const selector_start_ns = std.time.nanoTimestamp();
            const selector_key = try series_catalog_mod.buildSelectorKeyOwned(self.alloc, input.name, input.canonical_tags);
            selector_key_ns_total += @intCast(std.time.nanoTimestamp() - selector_start_ns);
            const parsed_tag_pairs = try self.parsePreparedStringTagPairs(input.canonical_tags);
            tag_pairs_total += @intCast(parsed_tag_pairs.pairs.len);
            prepared[idx] = .{
                .name = input.name,
                .canonical_tags = input.canonical_tags,
                .selector_key = selector_key,
                .series_id = types.seriesIdFrom(input.name, input.canonical_tags),
                .descriptor = input.descriptor,
                .tag_pairs = parsed_tag_pairs.pairs,
                .tag_pairs_owned = parsed_tag_pairs.owned,
            };
            prepared_len += 1;
        }
        _ = self.metrics.exact_series_declare_selector_key_ns_total.fetchAdd(selector_key_ns_total, .monotonic);
        _ = self.metrics.exact_series_declare_tag_pairs_total.fetchAdd(tag_pairs_total, .monotonic);
        return prepared;
    }

    fn parsePreparedStringTagPairs(
        self: *Engine,
        tags_json: []const u8,
    ) !struct { pairs: []PreparedStringTagPair, owned: bool } {
        const trimmed = std.mem.trim(u8, tags_json, " \t\r\n");
        if (trimmed.len < 2 or trimmed[0] != '{' or trimmed[trimmed.len - 1] != '}') {
            return .{ .pairs = try self.alloc.alloc(PreparedStringTagPair, 0), .owned = false };
        }
        if (trimmed.len == 2) return .{ .pairs = try self.alloc.alloc(PreparedStringTagPair, 0), .owned = false };

        var count_offset: usize = 1;
        var pair_count: usize = 0;
        while (count_offset < trimmed.len - 1) {
            const key = scanSimpleJsonString(trimmed, &count_offset) orelse break;
            _ = key;
            if (count_offset >= trimmed.len - 1 or trimmed[count_offset] != ':') break;
            count_offset += 1;
            _ = scanSimpleJsonString(trimmed, &count_offset) orelse break;
            pair_count += 1;
            if (count_offset == trimmed.len - 1) {
                const pairs = try self.alloc.alloc(PreparedStringTagPair, pair_count);
                var fill_offset: usize = 1;
                var pair_idx: usize = 0;
                while (fill_offset < trimmed.len - 1) {
                    const fill_key = scanSimpleJsonString(trimmed, &fill_offset).?;
                    fill_offset += 1; // skip :
                    const fill_value = scanSimpleJsonString(trimmed, &fill_offset).?;
                    pairs[pair_idx] = .{ .label = fill_key, .value = fill_value };
                    pair_idx += 1;
                    if (fill_offset == trimmed.len - 1) break;
                    fill_offset += 1; // skip ,
                }
                return .{ .pairs = pairs, .owned = false };
            }
            if (trimmed[count_offset] != ',') break;
            count_offset += 1;
        }

        var parsed = try std.json.parseFromSlice(std.json.Value, self.alloc, trimmed, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return .{ .pairs = try self.alloc.alloc(PreparedStringTagPair, 0), .owned = false };

        var pairs = std.array_list.Managed(PreparedStringTagPair).init(self.alloc);
        errdefer {
            for (pairs.items) |pair| {
                self.alloc.free(@constCast(pair.label));
                self.alloc.free(@constCast(pair.value));
            }
            pairs.deinit();
        }
        var it = parsed.value.object.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* != .string) continue;
            try pairs.append(.{
                .label = try self.alloc.dupe(u8, entry.key_ptr.*),
                .value = try self.alloc.dupe(u8, entry.value_ptr.string),
            });
        }
        return .{ .pairs = try pairs.toOwnedSlice(), .owned = true };
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

        const prepared_inputs = try self.prepareExactSeriesCanonicalDeclarations(inputs);
        defer {
            for (prepared_inputs) |*input| input.deinit(self.alloc);
            self.alloc.free(prepared_inputs);
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

        for (prepared_inputs, 0..) |input, idx| {
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

        var unique_series_inputs = std.array_list.Managed(series_catalog_mod.PreparedCanonicalRegisterInput).init(self.alloc);
        defer unique_series_inputs.deinit();
        try unique_series_inputs.ensureTotalCapacity(inputs.len);
        var unique_series_owner_indices = std.array_list.Managed(usize).init(self.alloc);
        defer unique_series_owner_indices.deinit();
        try unique_series_owner_indices.ensureTotalCapacity(inputs.len);
        var unique_series_by_id = std.AutoHashMap(types.SeriesId, usize).init(self.alloc);
        defer unique_series_by_id.deinit();

        for (prepared_inputs, 0..) |input, idx| {
            if (results[idx].status != .ok) continue;
            if (unique_series_by_id.get(input.series_id)) |existing_slot| {
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
                .selector_key = input.selector_key,
                .series_id = input.series_id,
            });
            try unique_series_owner_indices.append(idx);
            series_slots[idx] = unique_series_inputs.items.len - 1;
            try unique_series_by_id.put(input.series_id, unique_series_inputs.items.len - 1);
        }

        var series_results: []series_catalog_mod.RegisterBatchResult = &.{};
        defer if (series_results.len != 0) self.alloc.free(series_results);
        var wal_registrations = std.array_list.Managed(series_catalog_mod.PendingWalRegistration).init(self.alloc);
        defer wal_registrations.deinit();

        if (unique_series_inputs.items.len != 0) {
            series_results = try self.alloc.alloc(series_catalog_mod.RegisterBatchResult, unique_series_inputs.items.len);
            try self.metadata.series_catalog.registerPreparedBatch(unique_series_inputs.items, series_results, &wal_registrations);
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
        try self.noteTagsBatch(prepared_inputs, results);
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

    fn collectMarketSegmentHighwater(
        highwater: *std.AutoHashMap(market_identity_mod.MarketSeriesId, i64),
        entries: []const market_manifest_mod.MarketSegmentDescriptor,
    ) !void {
        for (entries) |entry| {
            const gop = try highwater.getOrPut(entry.market_series_id);
            if (!gop.found_existing or entry.end_ts_ns > gop.value_ptr.*) {
                gop.value_ptr.* = entry.end_ts_ns;
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

const ObsoleteMarketMirrors = struct {
    alloc: std.mem.Allocator,
    paths: std.array_list.Managed([]u8),

    fn init(alloc: std.mem.Allocator) ObsoleteMarketMirrors {
        return .{
            .alloc = alloc,
            .paths = std.array_list.Managed([]u8).init(alloc),
        };
    }

    fn deinit(self: *ObsoleteMarketMirrors) void {
        for (self.paths.items) |path| self.alloc.free(path);
        self.paths.deinit();
        self.* = undefined;
    }
};

fn compactNativeMarketSegments(
    engine: *Engine,
    obsolete_mirrors: *ObsoleteMarketMirrors,
) !bool {
    const partitions = try market_compact_mod.selectOverlappingSeriesHours(
        engine.alloc,
        &engine.market_manifest,
    );
    defer engine.alloc.free(partitions);

    var changed = false;
    for (partitions) |partition| {
        const selected = try market_compact_mod.selectOverlappingDescriptors(
            engine.alloc,
            &engine.market_manifest,
            partition.market_series_id,
            partition.hour_bucket,
        );
        defer engine.alloc.free(selected);
        if (selected.len < 2) continue;

        for (selected) |descriptor| {
            try ensureMarketCompactionMirror(engine, descriptor);
        }

        var replaced_paths = std.array_list.Managed([]u8).init(engine.alloc);
        defer {
            for (replaced_paths.items) |path| engine.alloc.free(path);
            replaced_paths.deinit();
        }
        try replaced_paths.ensureTotalCapacity(selected.len);
        for (selected) |descriptor| {
            try replaced_paths.append(try engine.alloc.dupe(u8, descriptor.path));
        }

        var result = try market_compact_mod.compactSeriesHour(
            engine.alloc,
            engine.data_dir,
            &engine.market_manifest,
            partition.market_series_id,
            partition.hour_bucket,
        );
        defer result.deinit();
        switch (result.outcome) {
            .compacted => {
                changed = true;
                try obsolete_mirrors.paths.appendSlice(replaced_paths.items);
                replaced_paths.clearRetainingCapacity();
            },
            .already_applied, .no_overlaps => {},
        }
    }
    return changed;
}

fn ensureMarketCompactionMirror(
    engine: *Engine,
    descriptor: *const market_manifest_mod.MarketSegmentDescriptor,
) !void {
    if (engine.data_dir.access(descriptor.path, .{})) |_| {
        return;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    const cas = if (engine.cas) |*manager| manager else return error.NativeMarketDataUnavailable;
    engine.metadata.cas_index_mu.lock();
    defer engine.metadata.cas_index_mu.unlock();
    const index = if (engine.metadata.cas_index) |*snapshot_index| snapshot_index else return error.NativeMarketDataUnavailable;

    for (index.snapshot.market_segment_descriptors) |cas_descriptor| {
        if (cas_descriptor.market_series_id != descriptor.market_series_id or
            cas_descriptor.hour_bucket != descriptor.hour_bucket or
            !std.mem.eql(u8, &cas_descriptor.content_id, &descriptor.content_id) or
            !std.mem.eql(u8, cas_descriptor.mirrorPath(), descriptor.path))
        {
            continue;
        }
        const root_id = cas_descriptor.segmentRoot() orelse
            return error.NativeMarketDataUnavailable;
        const restored = try market_segment_mod.restoreSegmentRootToLocalMirror(
            engine.alloc,
            engine.data_dir,
            &cas.store,
            root_id,
        );
        defer engine.alloc.free(restored);
        if (!std.mem.eql(u8, restored, descriptor.path)) {
            return error.MarketSegmentDescriptorMismatch;
        }
        return;
    }
    return error.NativeMarketDataUnavailable;
}

fn deleteObsoleteMarketMirrors(engine: *Engine, paths: []const []const u8) void {
    for (paths) |path| {
        if (marketManifestReferencesPath(&engine.market_manifest, path)) continue;
        engine.data_dir.deleteFile(path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => std.log.warn("obsolete market mirror cleanup failed path={s} error={s}", .{
                path,
                @errorName(err),
            }),
        };
    }
}

fn marketManifestReferencesPath(
    manifest: *const market_manifest_mod.Manifest,
    path: []const u8,
) bool {
    for (manifest.list()) |descriptor| {
        if (std.mem.eql(u8, descriptor.path, path)) return true;
    }
    return false;
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

fn cloneSelectorResolution(
    allocator: std.mem.Allocator,
    resolution: series_catalog_mod.Resolution,
) std.mem.Allocator.Error!series_catalog_mod.Resolution {
    const series = if (resolution.series) |name| try allocator.dupe(u8, name) else null;
    errdefer if (series) |name| allocator.free(name);
    const canonical_tags = if (resolution.canonical_tags) |tags| try allocator.dupe(u8, tags) else null;

    return .{
        .status = resolution.status,
        .series_id = resolution.series_id,
        .series = series,
        .canonical_tags = canonical_tags,
    };
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

fn waitForFlush(engine: *Engine, expected_entries: usize, timeout_ms: u64) !void {
    const deadline: i64 = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
    while (true) {
        if (engine.metadata.manifest.entries.items.len >= expected_entries and engine.liveMemtableBytes() == 0 and engine.queue.isDrained()) {
            const now = std.time.milliTimestamp();
            if (now >= deadline) break;
            const remaining_ms: u64 = @intCast(deadline - now);
            _ = try engine.flushAndDrain(remaining_ms);
            if (engine.cas != null) {
                try engine.verifyCasState();
            }
            return;
        }
        if (std.time.milliTimestamp() >= deadline) break;
        sleepMs(10);
    }
    return waitError.Timeout;
}

fn waitForQueueEmpty(engine: *Engine, timeout_ms: u64) waitError!void {
    const deadline_ns: i128 = std.time.nanoTimestamp() + @as(i128, @intCast(timeout_ms)) * std.time.ns_per_ms;
    while (true) {
        if (engine.queue.isDrained()) return;
        const now_ns = std.time.nanoTimestamp();
        if (now_ns >= deadline_ns) break;
        engine.drain_mu.lock();
        const remaining_ns: u64 = @intCast(deadline_ns - now_ns);
        engine.drain_cv.timedWait(&engine.drain_mu, remaining_ns) catch {};
        engine.drain_mu.unlock();
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

fn writeTestRepositoryFormatMarker(data_path: []const u8, version: u16) !void {
    const magic = "SYDSTORE1";
    var bytes: [magic.len + @sizeOf(u16) + 1 + @sizeOf(u32)]u8 = undefined;
    @memcpy(bytes[0..magic.len], magic);
    var offset = magic.len;
    std.mem.writeInt(u16, bytes[offset..][0..@sizeOf(u16)], version, .little);
    offset += @sizeOf(u16);
    bytes[offset] = @intFromEnum(cas_mod.RefBackend.reftable);
    offset += 1;
    std.mem.writeInt(
        u32,
        bytes[offset..][0..@sizeOf(u32)],
        cas_mod.default_extent_chunk_bytes,
        .little,
    );

    try std.fs.cwd().makePath(data_path);
    var root = try std.fs.cwd().openDir(data_path, .{});
    defer root.close();
    try root.makePath("objects/info");
    try root.writeFile(.{
        .sub_path = "objects/info/store-format",
        .data = &bytes,
        .flags = .{},
    });
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
    switch (first.payload) {
        .scalar => |points| try std.testing.expectEqual(@as(types.SeriesId, 1), points[0].series_id),
        .market => return error.UnexpectedMarketBatch,
    }
    switch (second.payload) {
        .scalar => |points| try std.testing.expectEqual(@as(types.SeriesId, 2), points[0].series_id),
        .market => return error.UnexpectedMarketBatch,
    }

    try queue.push(.{ .series_id = 4, .ts = 4, .value = 4 });
    try queue.push(.{ .series_id = 5, .ts = 5, .value = 5 });

    var third = queue.pop().?;
    defer third.deinit(talloc);
    var fourth = queue.pop().?;
    defer fourth.deinit(talloc);
    var fifth = queue.pop().?;
    defer fifth.deinit(talloc);

    switch (third.payload) {
        .scalar => |points| try std.testing.expectEqual(@as(types.SeriesId, 3), points[0].series_id),
        .market => return error.UnexpectedMarketBatch,
    }
    switch (fourth.payload) {
        .scalar => |points| try std.testing.expectEqual(@as(types.SeriesId, 4), points[0].series_id),
        .market => return error.UnexpectedMarketBatch,
    }
    switch (fifth.payload) {
        .scalar => |points| try std.testing.expectEqual(@as(types.SeriesId, 5), points[0].series_id),
        .market => return error.UnexpectedMarketBatch,
    }
    for (0..5) |_| queue.completeBatch();
    try std.testing.expectEqual(@as(usize, 0), queue.len());
    try std.testing.expectEqual(@as(usize, 0), queue.pendingBytes());
}

test "engine queue drain state includes dequeued in-flight batches" {
    const talloc = std.testing.allocator;
    var metrics = Engine.Metrics.init();
    const queue = try Engine.Queue.init(talloc, &metrics);
    defer {
        queue.deinit();
        talloc.destroy(queue);
    }

    try std.testing.expect(queue.isDrained());
    try queue.push(.{ .series_id = 1, .ts = 1, .value = 1 });
    try std.testing.expect(!queue.isDrained());

    var batch = queue.pop().?;
    defer batch.deinit(talloc);
    try std.testing.expectEqual(@as(usize, 0), queue.len());
    try std.testing.expect(!queue.isDrained());

    queue.completeBatch();
    try std.testing.expect(queue.isDrained());
}

test "engine queue preserves a maintenance wake until an idle pop observes it" {
    const talloc = std.testing.allocator;
    var metrics = Engine.Metrics.init();
    const queue = try Engine.Queue.init(talloc, &metrics);
    defer {
        queue.deinit();
        talloc.destroy(queue);
    }

    queue.wake();
    try std.testing.expect(queue.wake_requested);
    try std.testing.expect(queue.pop() == null);
    try std.testing.expect(!queue.wake_requested);
}

test "engine market queue owns native batch payloads" {
    const talloc = std.testing.allocator;
    var metrics = Engine.Metrics.init();
    const queue = try Engine.Queue.init(talloc, &metrics);
    defer {
        queue.deinit();
        talloc.destroy(queue);
    }

    const values = try talloc.dupe(f64, &[_]f64{ 10.5, 100.0 });
    errdefer talloc.free(values);
    const metric = try talloc.dupe(u8, "market.trade");
    errdefer talloc.free(metric);
    const labels = try talloc.dupe(u8, "{\"symbol\":\"AAPL\"}");
    errdefer talloc.free(labels);
    var rows = try talloc.alloc(Engine.QueuedMarketRow, 1);
    errdefer talloc.free(rows);
    rows[0] = .{
        .market_series_id = market_identity_mod.seriesId("market.trade", labels),
        .schema_digest = @splat(0x11),
        .metric = metric,
        .canonical_labels = labels,
        .ts_ns = 1_000,
        .values = values,
    };
    const fanout_series_ids = try talloc.alloc([]types.SeriesId, 1);
    errdefer talloc.free(fanout_series_ids);
    fanout_series_ids[0] = try talloc.dupe(types.SeriesId, &[_]types.SeriesId{ 101, 102 });
    errdefer talloc.free(fanout_series_ids[0]);
    const fanout_values = try talloc.alloc([]f64, 1);
    errdefer talloc.free(fanout_values);
    fanout_values[0] = try talloc.dupe(f64, &[_]f64{ 10.5, 100.0 });
    errdefer talloc.free(fanout_values[0]);

    const batch = Engine.QueuedMarketBatch{
        .rows = rows,
        .mode = .dual_write_v1,
        .fanout_series_ids = fanout_series_ids,
        .fanout_values = fanout_values,
    };
    const queued_bytes = try batch.queuedBytes();
    const row_payload_bytes = try rows[0].payloadBytes();
    const expected_queued_bytes = @sizeOf(Engine.QueuedMarketBatch) +
        @sizeOf(Engine.QueuedMarketRow) +
        @sizeOf([]types.SeriesId) +
        @sizeOf([]f64) +
        metric.len +
        labels.len +
        values.len * @sizeOf(f64) +
        fanout_series_ids[0].len * @sizeOf(types.SeriesId) +
        fanout_values[0].len * @sizeOf(f64);
    try std.testing.expectEqual(expected_queued_bytes, queued_bytes);
    try std.testing.expect(queued_bytes > row_payload_bytes);
    try queue.pushMarketBatch(batch, queued_bytes);

    try std.testing.expectEqual(@as(usize, 1), queue.len());
    try std.testing.expectEqual(queued_bytes, queue.pendingBytes());
    var popped = queue.pop().?;
    defer popped.deinit(talloc);
    switch (popped.payload) {
        .market => |market_batch| {
            try std.testing.expectEqual(Engine.MarketStorageWriteMode.dual_write_v1, market_batch.mode);
            try std.testing.expectEqual(@as(usize, 1), market_batch.rows.len);
            try std.testing.expectEqual(@as(i64, 1_000), market_batch.rows[0].ts_ns);
            try std.testing.expectEqual(@as(f64, 10.5), market_batch.rows[0].values[0]);
            try std.testing.expectEqual(@as(types.SeriesId, 101), market_batch.fanout_series_ids[0][0]);
            try std.testing.expectEqual(@as(f64, 100.0), market_batch.fanout_values[0][1]);
        },
        .scalar => return error.UnexpectedScalarBatch,
    }
    queue.completeBatch();
    try std.testing.expectEqual(@as(usize, 0), queue.len());
    try std.testing.expectEqual(@as(usize, 0), queue.pendingBytes());
}

test "engine native market ingest does not acknowledge before the ordered writer" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/market-native-queue", .{tmp.sub_path});
    defer talloc.free(data_path);

    var config = try testConfig(talloc, data_path);
    config.cas_mode = .dual_write;
    config.market_storage_mode = .native_v1;
    var engine = try Engine.init(talloc, config);
    defer engine.deinit();
    try pauseWriterForMaintenance(engine);
    engine.queue.reopen();

    var schema = try engine.registerMarketSchema(.{
        .metric = "market.test_trade",
        .ordered_columns = &.{ "price", "size" },
        .required_labels = &.{"symbol"},
        .storage_mapping = .native_v1,
    });
    defer schema.deinit(talloc);

    const values = [_]f64{ 10.5, 100.0 };
    const Context = struct {
        engine: *Engine,
        values: *const [2]f64,
        done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        failure: ?anyerror = null,
        receipt: ?Engine.MarketIngestReceipt = null,

        fn run(ctx: *@This()) void {
            ctx.receipt = ctx.engine.ingestMarketBatch(&.{.{
                .metric = "market.test_trade",
                .labels_json = "{\"symbol\":\"AAPL\"}",
                .ts_ns = 1_000,
                .values = ctx.values,
            }}) catch |err| {
                ctx.failure = err;
                ctx.done.store(true, .release);
                return;
            };
            ctx.done.store(true, .release);
        }
    };
    var context = Context{ .engine = engine, .values = &values };
    const ingest_thread = try std.Thread.spawn(.{}, Context.run, .{&context});
    var ingest_thread_joined = false;
    defer if (!ingest_thread_joined) {
        resumeWriterAfterMaintenance(engine) catch {};
        ingest_thread.join();
    };

    const deadline = std.time.nanoTimestamp() + 2 * std.time.ns_per_s;
    while (engine.queue.len() == 0 and std.time.nanoTimestamp() < deadline) sleepMs(1);
    try std.testing.expectEqual(@as(usize, 1), engine.queue.len());
    try std.testing.expect(!context.done.load(.acquire));

    try resumeWriterAfterMaintenance(engine);
    ingest_thread.join();
    ingest_thread_joined = true;
    if (context.failure) |failure| return failure;
    const receipt = context.receipt orelse return error.MissingMarketIngestReceipt;
    try std.testing.expectEqual(Engine.MarketStorageWriteMode.native_v1, receipt.storage_mode);
    try std.testing.expectEqual(@as(usize, 1), receipt.accepted_rows);
    try std.testing.expectEqual(@as(usize, 1), receipt.native_rows);
    try std.testing.expectEqual(@as(usize, 0), receipt.fanout_writes);
}

test "engine explicit native market mode rejects format3 before series registration" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/market-format3-preflight", .{tmp.sub_path});
    defer talloc.free(data_path);
    try writeTestRepositoryFormatMarker(data_path, cas_mod.primary_repository_format_version);

    var config = try testConfig(talloc, data_path);
    defer config.deinit(talloc);
    config.cas_mode = .dual_write;
    config.market_storage_mode = .native_v1;
    try std.testing.expectError(error.RepositoryFormatMismatch, Engine.init(talloc, config));

    var root = try std.fs.cwd().openDir(data_path, .{});
    defer root.close();
    try std.testing.expectError(error.FileNotFound, root.access(market_catalog_mod.path, .{}));
    try std.testing.expectError(error.FileNotFound, root.access("wal", .{}));
}

test "engine native flush and drain includes CAS publication boundary" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(
        talloc,
        ".zig-cache/tmp/{s}/market-native-drain-cas-boundary",
        .{tmp.sub_path},
    );
    defer talloc.free(data_path);

    var config = try testConfig(talloc, data_path);
    config.cas_mode = .dual_write;
    config.market_storage_mode = .native_v1;
    config.market_storage_read_mode = .native;
    config.flush_interval_ms = 60_000;
    config.memtable_max_bytes = 1024 * 1024;
    var engine = try Engine.init(talloc, config);
    defer engine.deinit();

    var schema = try engine.registerMarketSchema(.{
        .metric = "market.drain_boundary",
        .ordered_columns = &.{ "price", "size" },
        .required_labels = &.{"symbol"},
        .storage_mapping = .native_v1,
    });
    defer schema.deinit(talloc);

    const values = [_]f64{ 101.25, 10.0 };
    const receipt = try engine.ingestMarketBatch(&.{.{
        .metric = "market.drain_boundary",
        .labels_json = "{\"symbol\":\"AAPL\"}",
        .ts_ns = 1_000,
        .values = &values,
    }});
    try std.testing.expectEqual(@as(usize, 1), receipt.native_rows);

    try std.testing.expect(try engine.flushAndDrain(5_000));
    try std.testing.expectEqual(
        @as(u64, 0),
        engine.metrics.cas_sync_failed_total.load(.monotonic),
    );
    try engine.verifyCasState();

    var result = try engine.queryMarket(.{
        .metric = "market.drain_boundary",
        .start_ts_ns = 0,
        .end_ts_ns = 2_000,
        .requested_columns = &.{"price"},
    });
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.rows.len);
    try std.testing.expectEqual(@as(usize, 1), result.rows[0].values.len);
    try std.testing.expectEqual(@as(f64, 101.25), result.rows[0].values[0]);
}

test "engine rejects future repository markers before WAL or catalog mutation with CAS off" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/market-format-future", .{tmp.sub_path});
    defer talloc.free(data_path);
    try writeTestRepositoryFormatMarker(data_path, cas_mod.current_repository_format_version + 1);

    var config = try testConfig(talloc, data_path);
    defer config.deinit(talloc);
    try std.testing.expectError(
        error.UnsupportedRepositoryFormatVersion,
        Engine.init(talloc, config),
    );

    var root = try std.fs.cwd().openDir(data_path, .{});
    defer root.close();
    try std.testing.expectError(error.FileNotFound, root.access(market_catalog_mod.path, .{}));
    try std.testing.expectError(error.FileNotFound, root.access("wal", .{}));
}

test "engine rejects future repository format before promoting recovery mutates state" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(
        talloc,
        ".zig-cache/tmp/{s}/market-format-future-promoting",
        .{tmp.sub_path},
    );
    defer talloc.free(data_path);
    try writeTestRepositoryFormatMarker(
        data_path,
        cas_mod.current_repository_format_version + 1,
    );

    const catalog_before =
        \\{"schemas":[{"metric":"market.future_guard","ordered_columns":["price"],"required_labels":["symbol"],"storage_mapping":"fanout_v1"}],"market_series":[],"bar_policies":[],"rollups":[],"signals":[]}
    ;
    {
        var root = try std.fs.cwd().openDir(data_path, .{});
        defer root.close();
        try root.writeFile(.{
            .sub_path = market_catalog_mod.path,
            .data = catalog_before,
            .flags = .{},
        });

        var state = market_migration_mod.MigrationState.init(talloc);
        defer state.deinit();
        _ = try state.advance(.reconstructing);
        _ = try state.advance(.native_complete);
        _ = try state.advance(.verifying);
        _ = try state.advance(.verified);
        _ = try state.recordCheckpointRef("refs/checkpoints/future-format-guard");
        _ = try state.advance(.checkpointed);
        _ = try state.advance(.promoting);
        try state.saveAtomically(root);
    }

    var root = try std.fs.cwd().openDir(data_path, .{});
    defer root.close();
    const state_before = try root.readFileAlloc(
        talloc,
        market_migration_mod.state_path,
        1024 * 1024,
    );
    defer talloc.free(state_before);

    var config = try testConfig(talloc, data_path);
    defer config.deinit(talloc);
    config.cas_mode = .dual_write;
    try std.testing.expectError(
        error.UnsupportedRepositoryFormatVersion,
        Engine.init(talloc, config),
    );

    const catalog_after = try root.readFileAlloc(
        talloc,
        market_catalog_mod.path,
        1024 * 1024,
    );
    defer talloc.free(catalog_after);
    try std.testing.expectEqualStrings(catalog_before, catalog_after);

    const state_after = try root.readFileAlloc(
        talloc,
        market_migration_mod.state_path,
        1024 * 1024,
    );
    defer talloc.free(state_after);
    try std.testing.expectEqualSlices(u8, state_before, state_after);
    try std.testing.expectError(error.FileNotFound, root.access("wal", .{}));
}

test "engine explicit native market mode requires canonical CAS before startup state" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/market-native-cas-off", .{tmp.sub_path});
    defer talloc.free(data_path);

    var config = try testConfig(talloc, data_path);
    defer config.deinit(talloc);
    config.market_storage_mode = .native_v1;
    try std.testing.expectError(error.NativeMarketRequiresCas, Engine.init(talloc, config));

    var root = try std.fs.cwd().openDir(data_path, .{});
    defer root.close();
    try std.testing.expectError(error.FileNotFound, root.access(market_catalog_mod.path, .{}));
    try std.testing.expectError(error.FileNotFound, root.access("wal", .{}));
}

test "engine legacy format3 remains fanout operational with CAS off" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/market-format3-fanout", .{tmp.sub_path});
    defer talloc.free(data_path);
    try writeTestRepositoryFormatMarker(data_path, cas_mod.primary_repository_format_version);

    var config = try testConfig(talloc, data_path);
    config.market_storage_mode = .auto;
    var engine = try Engine.init(talloc, config);
    defer engine.deinit();
    try std.testing.expectEqual(
        cas_mod.primary_repository_format_version,
        engine.repository_format.version,
    );

    var trade = engine.marketSchema("market.trade") orelse return error.MissingMarketSchema;
    defer trade.deinit(talloc);
    try std.testing.expectEqual(market_catalog_mod.StorageMapping.fanout_v1, trade.storage_mapping);

    const values = [_]f64{ 10.5, 100.0 };
    const receipt = try engine.ingestMarketBatch(&.{.{
        .metric = "market.trade",
        .labels_json = "{\"symbol\":\"AAPL\",\"venue\":\"XNAS\"}",
        .ts_ns = 1_000,
        .values = &values,
    }});
    try std.testing.expectEqual(Engine.MarketStorageWriteMode.fanout_v1, receipt.storage_mode);
    try std.testing.expectEqual(@as(usize, 1), receipt.accepted_rows);
    try std.testing.expectEqual(@as(usize, 0), receipt.native_rows);
    try std.testing.expectEqual(@as(usize, 2), receipt.fanout_writes);
    _ = try engine.flushNow();
}

test "engine auto market schema defaults fresh format4 repositories to native" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/market-auto-format4", .{tmp.sub_path});
    defer talloc.free(data_path);

    var config = try testConfig(talloc, data_path);
    config.cas_mode = .dual_write;
    config.market_storage_mode = .auto;
    var engine = try Engine.init(talloc, config);
    defer engine.deinit();

    const builtin_metrics = [_][]const u8{ "market.trade", "market.quote", "market.bar" };
    for (builtin_metrics) |metric| {
        var builtin_schema = engine.marketSchema(metric) orelse return error.MissingMarketSchema;
        defer builtin_schema.deinit(talloc);
        try std.testing.expectEqual(
            market_catalog_mod.StorageMapping.native_v1,
            builtin_schema.storage_mapping,
        );
    }

    var schema = try engine.registerMarketSchema(.{
        .metric = "market.test_auto_trade",
        .ordered_columns = &.{ "price", "size" },
        .required_labels = &.{"symbol"},
        .storage_mapping = .fanout_v1,
    });
    defer schema.deinit(talloc);
    try std.testing.expectEqual(market_catalog_mod.StorageMapping.native_v1, schema.storage_mapping);

    var loaded = engine.marketSchema("market.test_auto_trade") orelse return error.MissingMarketSchema;
    defer loaded.deinit(talloc);
    try std.testing.expectEqual(market_catalog_mod.StorageMapping.native_v1, loaded.storage_mapping);
}

test "engine explicit market schema mapping overrides fresh auto default" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/market-explicit-format4", .{tmp.sub_path});
    defer talloc.free(data_path);

    var config = try testConfig(talloc, data_path);
    config.cas_mode = .dual_write;
    config.market_storage_mode = .auto;
    var engine = try Engine.init(talloc, config);
    defer engine.deinit();

    var schema = try engine.registerMarketSchemaWithStorageMappingOverride(.{
        .metric = "market.test_explicit_trade",
        .ordered_columns = &.{ "price", "size" },
        .required_labels = &.{"symbol"},
        .storage_mapping = .fanout_v1,
    }, .fanout_v1);
    defer schema.deinit(talloc);
    try std.testing.expectEqual(market_catalog_mod.StorageMapping.fanout_v1, schema.storage_mapping);
}

test "engine auto market schema keeps format3 and existing mappings fanout" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/market-auto-format3-existing", .{tmp.sub_path});
    defer talloc.free(data_path);
    try writeTestRepositoryFormatMarker(data_path, cas_mod.primary_repository_format_version);

    var config = try testConfig(talloc, data_path);
    config.cas_mode = .dual_write;
    config.market_storage_mode = .auto;
    var engine = try Engine.init(talloc, config);
    defer engine.deinit();
    try std.testing.expectEqual(
        cas_mod.primary_repository_format_version,
        engine.repository_format.version,
    );

    var first = try engine.registerMarketSchema(.{
        .metric = "market.test_format3_existing",
        .ordered_columns = &.{ "price", "size" },
        .required_labels = &.{"symbol"},
        .storage_mapping = .fanout_v1,
    });
    defer first.deinit(talloc);
    try std.testing.expectEqual(market_catalog_mod.StorageMapping.fanout_v1, first.storage_mapping);

    var second = try engine.registerMarketSchema(.{
        .metric = "market.test_format3_existing",
        .ordered_columns = &.{ "price", "size" },
        .required_labels = &.{"symbol"},
        .storage_mapping = .fanout_v1,
    });
    defer second.deinit(talloc);
    try std.testing.expectEqual(market_catalog_mod.StorageMapping.fanout_v1, second.storage_mapping);

    try std.testing.expectError(
        error.RepositoryFormatMismatch,
        engine.registerMarketSchemaWithStorageMappingOverride(.{
            .metric = "market.test_format3_native",
            .ordered_columns = &.{ "price", "size" },
            .required_labels = &.{"symbol"},
            .storage_mapping = .native_v1,
        }, .native_v1),
    );
}

test "engine existing format4 catalog preserves mappings and fills missing builtins as fanout" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/market-format4-existing-catalog", .{tmp.sub_path});
    defer talloc.free(data_path);
    try writeTestRepositoryFormatMarker(data_path, cas_mod.current_repository_format_version);
    {
        var root = try std.fs.cwd().openDir(data_path, .{});
        defer root.close();
        try root.writeFile(.{
            .sub_path = market_catalog_mod.path,
            .data =
            \\{"schemas":[{"metric":"market.existing_fanout","ordered_columns":["price"],"required_labels":["symbol"],"storage_mapping":"fanout_v1"},{"metric":"market.existing_native","ordered_columns":["price"],"required_labels":["symbol"],"storage_mapping":"native_v1"}],"market_series":[],"bar_policies":[],"rollups":[],"signals":[]}
            ,
            .flags = .{},
        });
    }

    var config = try testConfig(talloc, data_path);
    config.cas_mode = .dual_write;
    config.market_storage_mode = .auto;
    var engine = try Engine.init(talloc, config);
    defer engine.deinit();

    const expected = [_]struct {
        metric: []const u8,
        mapping: market_catalog_mod.StorageMapping,
    }{
        .{ .metric = "market.existing_fanout", .mapping = .fanout_v1 },
        .{ .metric = "market.existing_native", .mapping = .native_v1 },
        .{ .metric = "market.trade", .mapping = .fanout_v1 },
        .{ .metric = "market.quote", .mapping = .fanout_v1 },
        .{ .metric = "market.bar", .mapping = .fanout_v1 },
    };
    for (expected) |entry| {
        var schema = engine.marketSchema(entry.metric) orelse return error.MissingMarketSchema;
        defer schema.deinit(talloc);
        try std.testing.expectEqual(entry.mapping, schema.storage_mapping);
    }
}

test "engine mixed market ingest preflight is atomic before catalog mutation" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/market-mixed-preflight", .{tmp.sub_path});
    defer talloc.free(data_path);

    var config = try testConfig(talloc, data_path);
    config.cas_mode = .dual_write;
    config.market_storage_mode = .fanout_v1;
    var engine = try Engine.init(talloc, config);
    defer engine.deinit();

    var fanout_schema = try engine.registerMarketSchema(.{
        .metric = "market.test_mixed_trade",
        .ordered_columns = &.{ "price", "size" },
        .required_labels = &.{"symbol"},
        .storage_mapping = .fanout_v1,
    });
    defer fanout_schema.deinit(talloc);

    engine.config.market_storage_mode = .native_v1;
    var native_schema = try engine.registerMarketSchema(.{
        .metric = "market.test_mixed_quote",
        .ordered_columns = &.{ "bid", "ask" },
        .required_labels = &.{"symbol"},
        .storage_mapping = .native_v1,
    });
    defer native_schema.deinit(talloc);
    engine.config.market_storage_mode = .auto;

    const trade_values = [_]f64{ 10.5, 100.0 };
    const quote_values = [_]f64{ 10.0, 10.1 };
    try std.testing.expectError(error.MixedMarketStorageModes, engine.ingestMarketBatch(&.{
        .{
            .metric = "market.test_mixed_trade",
            .labels_json = "{\"symbol\":\"AAPL\"}",
            .ts_ns = 1_000,
            .values = &trade_values,
        },
        .{
            .metric = "market.test_mixed_quote",
            .labels_json = "{\"symbol\":\"AAPL\"}",
            .ts_ns = 1_000,
            .values = &quote_values,
        },
    }));

    const identities = try engine.metadata.market_catalog.listMarketSeries();
    defer {
        for (identities) |*identity| identity.deinit(talloc);
        talloc.free(identities);
    }
    try std.testing.expectEqual(@as(usize, 0), identities.len);
    try std.testing.expectEqual(@as(usize, 0), engine.metadata.metric_catalog.entryCount());
    try std.testing.expectEqual(@as(usize, 0), engine.queue.len());
}

test "engine dual market writer emits one durable market row without scalar WAL" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/market-dual-writer-wal", .{tmp.sub_path});
    defer talloc.free(data_path);

    var config = try testConfig(talloc, data_path);
    config.cas_mode = .dual_write;
    config.market_storage_mode = .dual_write_v1;
    var engine = try Engine.init(talloc, config);
    defer engine.deinit();

    var schema = try engine.registerMarketSchema(.{
        .metric = "market.test_dual_trade",
        .ordered_columns = &.{ "price", "size" },
        .required_labels = &.{"symbol"},
        .storage_mapping = .fanout_v1,
    });
    defer schema.deinit(talloc);
    try std.testing.expectEqual(market_catalog_mod.StorageMapping.native_v1, schema.storage_mapping);

    const values = [_]f64{ 10.5, 100.0 };
    const next_values = [_]f64{ 11.5, 120.0 };
    const receipt = try engine.ingestMarketBatch(&.{
        .{
            .metric = "market.test_dual_trade",
            .labels_json = "{\"symbol\":\"AAPL\"}",
            .ts_ns = 1_000,
            .values = &values,
        },
        .{
            .metric = "market.test_dual_trade",
            .labels_json = "{\"symbol\":\"AAPL\"}",
            .ts_ns = 2_000,
            .values = &next_values,
        },
    });
    try std.testing.expectEqual(Engine.MarketStorageWriteMode.dual_write_v1, receipt.storage_mode);
    try std.testing.expectEqual(@as(usize, 0), engine.queue.len());
    _ = try engine.flushNow();
    try std.testing.expectEqual(@as(u64, 3), engine.next_market_write_sequence);
    try std.testing.expectEqual(@as(usize, 1), engine.market_manifest.list().len);
    try std.testing.expectEqual(@as(usize, 2), engine.metadata.manifest.entries.items.len);

    var counts = struct {
        scalar_rows: usize = 0,
        market_rows: usize = 0,
        market_registrations: usize = 0,
        seen_market_registration: bool = false,

        pub fn onRecord(self_ctx: *@This(), series_id: types.SeriesId, ts: i64, value: f64) !void {
            _ = series_id;
            _ = ts;
            _ = value;
            self_ctx.scalar_rows += 1;
        }

        pub fn onMarketSeriesRegistration(
            self_ctx: *@This(),
            market_series_id: market_identity_mod.MarketSeriesId,
            schema_digest: market_identity_mod.SchemaDigest,
            metric: []const u8,
            canonical_labels: []const u8,
        ) !void {
            _ = market_series_id;
            _ = schema_digest;
            _ = metric;
            _ = canonical_labels;
            self_ctx.market_registrations += 1;
            self_ctx.seen_market_registration = true;
        }

        pub fn onMarketRow(
            self_ctx: *@This(),
            market_series_id: market_identity_mod.MarketSeriesId,
            write_sequence: u64,
            ts_ns: i64,
            row_values: []const f64,
        ) !void {
            _ = market_series_id;
            _ = write_sequence;
            _ = ts_ns;
            _ = row_values;
            if (!self_ctx.seen_market_registration) return error.MarketRowBeforeRegistration;
            self_ctx.market_rows += 1;
        }
    }{};
    try engine.wal.replay(talloc, &counts);
    try std.testing.expectEqual(@as(usize, 0), counts.scalar_rows);
    try std.testing.expectEqual(@as(usize, 1), counts.market_registrations);
    try std.testing.expectEqual(@as(usize, 2), counts.market_rows);
}

test "engine propagates ordered market writer WAL failures to the caller" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/market-wal-ack-failure", .{tmp.sub_path});
    defer talloc.free(data_path);

    var config = try testConfig(talloc, data_path);
    config.fsync = .always;
    config.cas_mode = .dual_write;
    config.market_storage_mode = .native_v1;
    var engine = try Engine.init(talloc, config);
    defer engine.deinit();

    var schema = try engine.registerMarketSchema(.{
        .metric = "market.test_wal_ack_failure",
        .ordered_columns = &.{ "price", "size" },
        .required_labels = &.{"symbol"},
        .storage_mapping = .native_v1,
    });
    defer schema.deinit(talloc);

    engine.market_writer_fault = .wal_append;
    const values = [_]f64{ 10.5, 100.0 };
    try std.testing.expectError(error.InjectedMarketWalAppendFailure, engine.ingestMarketBatch(&.{.{
        .metric = "market.test_wal_ack_failure",
        .labels_json = "{\"symbol\":\"AAPL\"}",
        .ts_ns = 1_000,
        .values = &values,
    }}));
    engine.market_writer_fault = null;

    try std.testing.expectEqual(@as(usize, 0), engine.market_mem.residentBytes());
    try std.testing.expectEqual(@as(usize, 0), engine.mem.bytes.load(.monotonic));
}

test "engine rolls back dual fanout when native live apply fails" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/market-dual-live-rollback", .{tmp.sub_path});
    defer talloc.free(data_path);

    var config = try testConfig(talloc, data_path);
    config.cas_mode = .dual_write;
    config.market_storage_mode = .dual_write_v1;
    config.memtable_max_bytes = std.math.maxInt(usize);
    config.flush_interval_ms = std.math.maxInt(u32);
    var engine = try Engine.init(talloc, config);
    defer engine.deinit();

    var schema = try engine.registerMarketSchema(.{
        .metric = "market.test_dual_rollback",
        .ordered_columns = &.{ "price", "size" },
        .required_labels = &.{"symbol"},
        .storage_mapping = .native_v1,
    });
    defer schema.deinit(talloc);

    engine.market_writer_fault = .native_apply_after_fanout;
    const values = [_]f64{ 10.5, 100.0 };
    try std.testing.expectError(error.InjectedNativeMarketApplyFailure, engine.ingestMarketBatch(&.{.{
        .metric = "market.test_dual_rollback",
        .labels_json = "{\"symbol\":\"AAPL\"}",
        .ts_ns = 1_000,
        .values = &values,
    }}));
    engine.market_writer_fault = null;

    try std.testing.expectEqual(@as(usize, 0), engine.market_mem.residentBytes());
    try std.testing.expectEqual(@as(usize, 0), engine.mem.bytes.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 0), engine.mem.series.count());
}

test "engine restarts from an acknowledged always-sync native market row" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/market-always-ack-restart", .{tmp.sub_path});
    defer talloc.free(data_path);

    {
        var config = try testConfig(talloc, data_path);
        config.fsync = .always;
        config.cas_mode = .dual_write;
        config.market_storage_mode = .native_v1;
        config.memtable_max_bytes = std.math.maxInt(usize);
        config.flush_interval_ms = std.math.maxInt(u32);
        var engine = try Engine.init(talloc, config);
        defer engine.deinit();

        var schema = try engine.registerMarketSchema(.{
            .metric = "market.test_always_restart",
            .ordered_columns = &.{ "price", "size" },
            .required_labels = &.{"symbol"},
            .storage_mapping = .native_v1,
        });
        defer schema.deinit(talloc);

        const values = [_]f64{ 10.5, 100.0 };
        const receipt = try engine.ingestMarketBatch(&.{.{
            .metric = "market.test_always_restart",
            .labels_json = "{\"symbol\":\"AAPL\"}",
            .ts_ns = 1_000,
            .values = &values,
        }});
        try std.testing.expectEqual(@as(usize, 1), receipt.accepted_rows);

        // Model crash loss of volatile memory while retaining the already
        // synced WAL, then stop the writer without producing a segment.
        engine.market_mem.clearRetainingCapacity();
        engine.market_mem_resident_bytes.store(0, .monotonic);
        try pauseWriterForMaintenance(engine);
    }

    var config = try testConfig(talloc, data_path);
    config.fsync = .always;
    config.cas_mode = .dual_write;
    config.market_storage_mode = .native_v1;
    var recovered = try Engine.init(talloc, config);
    defer recovered.deinit();

    try std.testing.expectEqual(@as(usize, 1), recovered.market_manifest.list().len);
    const entry = recovered.market_manifest.list()[0];
    var segment = try market_segment_mod.readAll(talloc, recovered.data_dir, entry.path);
    defer segment.deinit(talloc);
    try std.testing.expectEqual(@as(usize, 1), segment.timestamps.len);
    try std.testing.expectEqual(@as(i64, 1_000), segment.timestamps[0]);
    try std.testing.expectEqual(@as(u64, @bitCast(@as(f64, 10.5))), @as(u64, @bitCast(segment.columns[0].values[0])));
    try std.testing.expectEqual(@as(u64, @bitCast(@as(f64, 100.0))), @as(u64, @bitCast(segment.columns[1].values[0])));
}

test "engine dual market WAL recovery derives fanout from logical market rows" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/market-dual-wal-recovery", .{tmp.sub_path});
    defer talloc.free(data_path);

    const canonical_labels = try market_identity_mod.canonicalizeLabels(talloc, "{\"symbol\":\"AAPL\"}");
    defer talloc.free(canonical_labels);
    const market_series_id = market_identity_mod.seriesId("market.test_dual_replay_trade", canonical_labels);

    {
        var config = try testConfig(talloc, data_path);
        config.cas_mode = .dual_write;
        config.market_storage_mode = .dual_write_v1;
        var engine = try Engine.init(talloc, config);
        defer engine.deinit();
        try pauseWriterForMaintenance(engine);

        var schema = try engine.registerMarketSchema(.{
            .metric = "market.test_dual_replay_trade",
            .ordered_columns = &.{ "price", "size" },
            .required_labels = &.{"symbol"},
            .storage_mapping = .native_v1,
        });
        defer schema.deinit(talloc);

        _ = try engine.wal.appendMarketSeriesRegistration(
            market_series_id,
            schema.digest(),
            "market.test_dual_replay_trade",
            canonical_labels,
        );
        _ = try engine.wal.appendMarketRow(
            market_series_id,
            11,
            1_000,
            &[_]f64{ 10.5, 100.0 },
        );
    }

    var config = try testConfig(talloc, data_path);
    config.cas_mode = .dual_write;
    config.market_storage_mode = .dual_write_v1;
    var recovered = try Engine.init(talloc, config);
    defer recovered.deinit();

    try std.testing.expectEqual(@as(u64, 12), recovered.next_market_write_sequence);
    try std.testing.expectEqual(@as(usize, 1), recovered.market_manifest.list().len);

    const price_series_id = types.seriesIdFrom("market.test_dual_replay_trade.price", canonical_labels);
    const size_series_id = types.seriesIdFrom("market.test_dual_replay_trade.size", canonical_labels);
    const price_points = try recovered.querySeriesPoints(price_series_id, 0, 2_000);
    defer talloc.free(price_points);
    const size_points = try recovered.querySeriesPoints(size_series_id, 0, 2_000);
    defer talloc.free(size_points);

    try std.testing.expectEqual(@as(usize, 1), price_points.len);
    try std.testing.expectEqual(@as(i64, 1_000), price_points[0].ts);
    try std.testing.expectApproxEqAbs(@as(f64, 10.5), price_points[0].value, 1e-9);
    try std.testing.expectEqual(@as(usize, 1), size_points.len);
    try std.testing.expectEqual(@as(i64, 1_000), size_points[0].ts);
    try std.testing.expectApproxEqAbs(@as(f64, 100.0), size_points[0].value, 1e-9);

    var counts = struct {
        scalar_rows: usize = 0,
        market_rows: usize = 0,
        market_registrations: usize = 0,

        pub fn onRecord(self_ctx: *@This(), series_id: types.SeriesId, ts: i64, value: f64) !void {
            _ = series_id;
            _ = ts;
            _ = value;
            self_ctx.scalar_rows += 1;
        }

        pub fn onMarketSeriesRegistration(
            self_ctx: *@This(),
            market_series_id_arg: market_identity_mod.MarketSeriesId,
            schema_digest: market_identity_mod.SchemaDigest,
            metric: []const u8,
            labels: []const u8,
        ) !void {
            _ = market_series_id_arg;
            _ = schema_digest;
            _ = metric;
            _ = labels;
            self_ctx.market_registrations += 1;
        }

        pub fn onMarketRow(
            self_ctx: *@This(),
            market_series_id_arg: market_identity_mod.MarketSeriesId,
            write_sequence: u64,
            ts_ns: i64,
            values: []const f64,
        ) !void {
            _ = market_series_id_arg;
            _ = write_sequence;
            _ = ts_ns;
            _ = values;
            self_ctx.market_rows += 1;
        }
    }{};
    try recovered.wal.replay(talloc, &counts);
    try std.testing.expectEqual(@as(usize, 0), counts.scalar_rows);
    try std.testing.expectEqual(@as(usize, 1), counts.market_registrations);
    try std.testing.expectEqual(@as(usize, 1), counts.market_rows);
}

test "engine native market WAL recovery flushes row and advances sequence" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/market-wal-recovery", .{tmp.sub_path});
    defer talloc.free(data_path);

    {
        var config = try testConfig(talloc, data_path);
        config.cas_mode = .dual_write;
        config.market_storage_mode = .native_v1;
        var engine = try Engine.init(talloc, config);
        defer engine.deinit();
        try pauseWriterForMaintenance(engine);

        var schema = try engine.registerMarketSchema(.{
            .metric = "market.test_recovery_trade",
            .ordered_columns = &.{ "price", "size" },
            .required_labels = &.{"symbol"},
            .storage_mapping = .native_v1,
        });
        defer schema.deinit(talloc);
        const schema_digest = schema.digest();
        const canonical_labels = try market_identity_mod.canonicalizeLabels(talloc, "{\"symbol\":\"AAPL\"}");
        defer talloc.free(canonical_labels);
        const market_series_id = market_identity_mod.seriesId("market.test_recovery_trade", canonical_labels);
        _ = try engine.wal.appendMarketSeriesRegistration(
            market_series_id,
            schema_digest,
            "market.test_recovery_trade",
            canonical_labels,
        );
        _ = try engine.wal.appendMarketRow(
            market_series_id,
            7,
            1_000,
            &[_]f64{ 10.5, 100.0 },
        );
    }

    var config = try testConfig(talloc, data_path);
    config.cas_mode = .dual_write;
    config.market_storage_mode = .native_v1;
    var recovered = try Engine.init(talloc, config);
    defer recovered.deinit();
    try std.testing.expectEqual(@as(usize, 1), recovered.market_manifest.list().len);
    try std.testing.expectEqual(@as(u64, 8), recovered.next_market_write_sequence);
    try std.testing.expectEqual(@as(usize, 0), recovered.market_mem.residentBytes());
    try std.testing.expect(recovered.market_mem.allocatedBytes() > 0);
    try std.testing.expectEqual(recovered.market_mem.allocatedBytes(), recovered.market_mem_allocated_bytes.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 0), recovered.market_mem_resident_bytes.load(.monotonic));
}

test "engine native market WAL recovery replays same timestamp corrections after flush" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/market-wal-correction", .{tmp.sub_path});
    defer talloc.free(data_path);

    const canonical_labels = try market_identity_mod.canonicalizeLabels(talloc, "{\"symbol\":\"AAPL\"}");
    defer talloc.free(canonical_labels);
    const market_series_id = market_identity_mod.seriesId("market.test_correction_trade", canonical_labels);

    {
        var config = try testConfig(talloc, data_path);
        config.cas_mode = .dual_write;
        config.market_storage_mode = .native_v1;
        var engine = try Engine.init(talloc, config);
        defer engine.deinit();
        try pauseWriterForMaintenance(engine);

        var schema = try engine.registerMarketSchema(.{
            .metric = "market.test_correction_trade",
            .ordered_columns = &.{ "price", "size" },
            .required_labels = &.{"symbol"},
            .storage_mapping = .native_v1,
        });
        defer schema.deinit(talloc);
        const schema_digest = schema.digest();
        _ = try engine.wal.appendMarketSeriesRegistration(
            market_series_id,
            schema_digest,
            "market.test_correction_trade",
            canonical_labels,
        );
        _ = try engine.wal.appendMarketRow(
            market_series_id,
            1,
            1_000,
            &[_]f64{ 10.5, 100.0 },
        );
    }

    {
        var config = try testConfig(talloc, data_path);
        config.cas_mode = .dual_write;
        config.market_storage_mode = .native_v1;
        var recovered = try Engine.init(talloc, config);
        defer recovered.deinit();
        try std.testing.expectEqual(@as(usize, 1), recovered.market_manifest.list().len);
        try pauseWriterForMaintenance(recovered);
        var schema = recovered.marketSchema("market.test_correction_trade") orelse return error.MissingMarketSchema;
        defer schema.deinit(talloc);
        const schema_digest = schema.digest();
        _ = try recovered.wal.appendMarketSeriesRegistration(
            market_series_id,
            schema_digest,
            "market.test_correction_trade",
            canonical_labels,
        );
        _ = try recovered.wal.appendMarketRow(
            market_series_id,
            2,
            1_000,
            &[_]f64{ 11.5, 100.0 },
        );
    }

    var config = try testConfig(talloc, data_path);
    config.cas_mode = .dual_write;
    config.market_storage_mode = .native_v1;
    var corrected = try Engine.init(talloc, config);
    defer corrected.deinit();
    try std.testing.expect(corrected.market_manifest.list().len >= 2);
    try std.testing.expectEqual(@as(u64, 3), corrected.next_market_write_sequence);

    var saw_correction = false;
    for (corrected.market_manifest.list()) |entry| {
        var result = try market_segment_mod.readAll(talloc, corrected.data_dir, entry.path);
        defer result.deinit(talloc);
        for (result.write_sequences, 0..) |sequence, row_idx| {
            if (sequence == 2 and result.timestamps[row_idx] == 1_000) {
                try std.testing.expectApproxEqAbs(@as(f64, 11.5), result.columns[0].values[row_idx], 1e-9);
                saw_correction = true;
            }
        }
    }
    try std.testing.expect(saw_correction);
}

test "engine native market WAL recovery rejects orphan rows" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/market-wal-orphan", .{tmp.sub_path});
    defer talloc.free(data_path);

    {
        var config = try testConfig(talloc, data_path);
        config.cas_mode = .dual_write;
        config.market_storage_mode = .native_v1;
        var engine = try Engine.init(talloc, config);
        defer engine.deinit();
        try pauseWriterForMaintenance(engine);

        var schema = try engine.registerMarketSchema(.{
            .metric = "market.test_orphan_trade",
            .ordered_columns = &.{ "price", "size" },
            .required_labels = &.{"symbol"},
            .storage_mapping = .native_v1,
        });
        defer schema.deinit(talloc);
        const canonical_labels = try market_identity_mod.canonicalizeLabels(talloc, "{\"symbol\":\"AAPL\"}");
        defer talloc.free(canonical_labels);
        const market_series_id = market_identity_mod.seriesId("market.test_orphan_trade", canonical_labels);
        _ = try engine.wal.appendMarketRow(
            market_series_id,
            1,
            1_000,
            &[_]f64{ 10.5, 100.0 },
        );
    }

    var config = try testConfig(talloc, data_path);
    config.cas_mode = .dual_write;
    config.market_storage_mode = .native_v1;
    try std.testing.expectError(error.OrphanMarketRow, Engine.init(talloc, config));
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

test "engine flushAndDrain returns segment publication error and retains buffered input" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/flush-publication-error", .{tmp.sub_path});
    defer talloc.free(data_path);

    var config = try testConfig(talloc, data_path);
    config.flush_interval_ms = std.math.maxInt(u32);
    config.memtable_max_bytes = std.math.maxInt(usize);
    var engine = try Engine.init(talloc, config);
    defer engine.deinit();

    const sid = try engine.declareExactSeriesCanonical("svc.flush_error", "{}", null);
    try engine.data_dir.makePath("segments");
    var blocker = try engine.data_dir.createFile("segments/0", .{});
    blocker.close();

    _ = try engine.appendResolvedPoint(.{ .series_id = sid, .ts = 7, .value = 3.5 });
    try std.testing.expectError(error.NotDir, engine.flushAndDrain(5_000));
    try std.testing.expectEqual(@as(usize, 0), engine.queue.len());
    try std.testing.expectEqual(@sizeOf(types.Point), engine.liveMemtableBytes());

    try engine.data_dir.deleteFile("segments/0");
    try std.testing.expect(try engine.flushAndDrain(5_000));

    var results = std.array_list.Managed(types.Point).init(talloc);
    defer results.deinit();
    try engine.queryRange(sid, 0, 10, &results);
    try std.testing.expectEqual(@as(usize, 1), results.items.len);
    try std.testing.expectEqual(@as(i64, 7), results.items[0].ts);
    try std.testing.expectApproxEqAbs(@as(f64, 3.5), results.items[0].value, 1e-9);
}

test "engine waitForFlush waits through CAS snapshot publication" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(talloc, ".zig-cache/tmp/{s}/wait-for-flush-cas-publication", .{tmp.sub_path});
    defer talloc.free(data_path);

    var config = try testConfig(talloc, data_path);
    config.cas_mode = .dual_write;
    config.flush_interval_ms = std.math.maxInt(u32);
    config.memtable_max_bytes = std.math.maxInt(usize);
    var engine = try Engine.init(talloc, config);
    defer engine.deinit();

    const sid = try engine.declareExactSeriesCanonical("svc.flush_barrier", "{}", null);
    _ = try engine.appendResolvedPoint(.{ .series_id = sid, .ts = 7, .value = 3.5 });
    const ingest_deadline = std.time.nanoTimestamp() + std.time.ns_per_s;
    while ((!engine.queue.isDrained() or engine.liveMemtableBytes() == 0) and std.time.nanoTimestamp() < ingest_deadline) {
        std.Thread.sleep(std.time.ns_per_ms);
    }
    try std.testing.expect(engine.queue.isDrained());
    try std.testing.expect(engine.liveMemtableBytes() > 0);

    const TriggerContext = struct {
        engine: *Engine,
        done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        failure: ?anyerror = null,

        fn run(ctx: *@This()) void {
            _ = ctx.engine.flushAndDrain(5_000) catch |err| {
                ctx.failure = err;
                ctx.done.store(true, .release);
                return;
            };
            ctx.done.store(true, .release);
        }
    };
    const PollerContext = struct {
        engine: *Engine,
        done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        failure: ?anyerror = null,

        fn run(ctx: *@This()) void {
            waitForFlush(ctx.engine, 1, 5_000) catch |err| {
                ctx.failure = err;
                ctx.done.store(true, .release);
                return;
            };
            ctx.done.store(true, .release);
        }
    };

    engine.wal.lockForSnapshot();
    var gate_held = true;
    var trigger_thread: ?std.Thread = null;
    var poller_thread: ?std.Thread = null;
    defer {
        if (gate_held) engine.wal.unlockForSnapshot();
        if (poller_thread) |thread| thread.join();
        if (trigger_thread) |thread| thread.join();
    }

    var trigger_context = TriggerContext{ .engine = engine };
    trigger_thread = try std.Thread.spawn(.{}, TriggerContext.run, .{&trigger_context});
    const publication_deadline = std.time.nanoTimestamp() + std.time.ns_per_s;
    while (engine.metrics.flush_total.load(.monotonic) == 0 and std.time.nanoTimestamp() < publication_deadline) {
        std.Thread.sleep(std.time.ns_per_ms);
    }
    try std.testing.expect(engine.metrics.flush_total.load(.monotonic) >= 1);

    engine.drain_mu.lock();
    const generation_before_poller = engine.drain_generation;
    const writer_still_publishing = engine.flush_in_progress;
    engine.drain_mu.unlock();
    try std.testing.expect(writer_still_publishing);

    var poller_context = PollerContext{ .engine = engine };
    poller_thread = try std.Thread.spawn(.{}, PollerContext.run, .{&poller_context});
    const barrier_deadline = std.time.nanoTimestamp() + std.time.ns_per_s;
    var poller_barrier_observed = false;
    while (!poller_barrier_observed and std.time.nanoTimestamp() < barrier_deadline) {
        engine.drain_mu.lock();
        poller_barrier_observed = engine.drain_generation != generation_before_poller;
        engine.drain_mu.unlock();
        if (!poller_barrier_observed) std.Thread.sleep(std.time.ns_per_ms);
    }
    const poller_stayed_blocked = !poller_context.done.load(.acquire);

    engine.wal.unlockForSnapshot();
    gate_held = false;
    if (poller_thread) |thread| {
        thread.join();
        poller_thread = null;
    }
    if (trigger_thread) |thread| {
        thread.join();
        trigger_thread = null;
    }

    try std.testing.expect(poller_barrier_observed);
    try std.testing.expect(poller_stayed_blocked);
    try std.testing.expect(trigger_context.failure == null);
    try std.testing.expect(poller_context.failure == null);
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
    engine.stop_flag = true;
    engine.derived_mu.lock();
    engine.derived_pending = true;
    engine.derived_mu.unlock();
    engine.derived_cv.broadcast();
    if (engine.derived_thread) |thread| {
        thread.join();
        engine.derived_thread = null;
    }
    engine.stop_flag = false;

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

    const cas_sync_deadline = std.time.milliTimestamp() + 1_000;
    while (engine.metrics.cas_sync_total.load(.monotonic) == 0 and std.time.milliTimestamp() < cas_sync_deadline) {
        sleepMs(10);
    }
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
    const sid: types.SeriesId = 42;

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

    engine.queue.reopen();
    try engine.queue.push(.{
        .series_id = types.hash64("drain.timeout.series"),
        .ts = 10,
        .value = 1.0,
    });
    engine.queue.close();

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
        try waitForFlush(engine, 2, 5_000);
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
        try std.testing.expectEqual(@as(usize, 1), engine.metadata.manifest.entries.items.len);
        try engine.ingest(.{ .series_id = sid, .ts = 2_000, .value = 3.0, .tags_json = "{}" });
        try engine.waitForQueryablePoints(talloc, sid, 3, 1_000);

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
    try waitForFlush(engine, 1, 5_000);
    try engine.ingest(.{ .series_id = sid, .ts = 1_500, .value = 2.0, .tags_json = "{}" });
    try waitForFlush(engine, 2, 5_000);

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
        _ = try worker.cas.syncLegacySnapshotWithNativeMarket(
            engine.data_dir,
            &engine.metadata.manifest,
            &engine.metadata.tags,
            &engine.metadata.series_catalog,
            &engine.metadata.metric_catalog,
            &engine.metadata.market_catalog,
            &engine.market_manifest,
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

test "engine market query auto uses fresh native storage with labels time and projection" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(
        talloc,
        ".zig-cache/tmp/{s}/market-query-native-auto",
        .{tmp.sub_path},
    );
    defer talloc.free(data_path);
    var config = try testConfig(talloc, data_path);
    config.cas_mode = .dual_write;
    config.market_storage_mode = .auto;
    config.market_storage_read_mode = .auto;
    config.flush_interval_ms = std.math.maxInt(u32);
    config.memtable_max_bytes = std.math.maxInt(usize);
    var engine = try Engine.init(talloc, config);
    defer engine.deinit();

    const nan_bits: u64 = 0x7ff8_0000_0000_0042;
    const first = [_]f64{ @as(f64, @bitCast(@as(u64, 0x8000_0000_0000_0000))), @bitCast(nan_bits) };
    const second = [_]f64{ 20.0, 200.0 };
    _ = try engine.ingestMarketBatch(&.{
        .{
            .metric = "market.trade",
            .labels_json = "{\"venue\":\"XNAS\",\"symbol\":\"AAPL\"}",
            .ts_ns = 100,
            .values = &first,
        },
        .{
            .metric = "market.trade",
            .labels_json = "{\"symbol\":\"MSFT\",\"venue\":\"XNAS\"}",
            .ts_ns = 200,
            .values = &second,
        },
    });

    var result = try engine.queryMarket(.{
        .metric = "market.trade",
        .label_filter_json = "{\"symbol\":\"AAPL\"}",
        .start_ts_ns = 50,
        .end_ts_ns = 150,
        .requested_columns = &.{ "size", "price" },
    });
    defer result.deinit();
    try std.testing.expectEqualStrings("native", result.stats.storage_mode);
    try std.testing.expectEqual(@as(usize, 2), result.requested_columns.len);
    try std.testing.expectEqualStrings("size", result.requested_columns[0]);
    try std.testing.expectEqualStrings("price", result.requested_columns[1]);
    try std.testing.expectEqual(@as(usize, 1), result.rows.len);
    try std.testing.expectEqual(@as(i64, 100), result.rows[0].ts_ns);
    try std.testing.expectEqual(
        nan_bits,
        @as(u64, @bitCast(result.rows[0].values[0])),
    );
    try std.testing.expectEqual(
        @as(u64, 0x8000_0000_0000_0000),
        @as(u64, @bitCast(result.rows[0].values[1])),
    );
}

test "engine market query shadow compares corrections and hidden columns exactly" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(
        talloc,
        ".zig-cache/tmp/{s}/market-query-shadow",
        .{tmp.sub_path},
    );
    defer talloc.free(data_path);
    var config = try testConfig(talloc, data_path);
    config.cas_mode = .dual_write;
    config.market_storage_mode = .dual_write_v1;
    config.market_storage_read_mode = .shadow;
    config.flush_interval_ms = std.math.maxInt(u32);
    config.memtable_max_bytes = std.math.maxInt(usize);
    var engine = try Engine.init(talloc, config);
    defer engine.deinit();

    const original = [_]f64{ 10.0, 100.0 };
    const correction = [_]f64{ 11.0, 110.0 };
    const exact_bits = [_]f64{
        @as(f64, @bitCast(@as(u64, 0x8000_0000_0000_0000))),
        @as(f64, @bitCast(@as(u64, 0x7ff8_0000_0000_0042))),
    };
    _ = try engine.ingestMarketBatch(&.{.{
        .metric = "market.trade",
        .labels_json = "{\"symbol\":\"AAPL\",\"venue\":\"XNAS\"}",
        .ts_ns = 1_000,
        .values = &original,
    }});
    _ = try engine.ingestMarketBatch(&.{.{
        .metric = "market.trade",
        .labels_json = "{\"symbol\":\"AAPL\",\"venue\":\"XNAS\"}",
        .ts_ns = 1_000,
        .values = &correction,
    }});
    _ = try engine.ingestMarketBatch(&.{.{
        .metric = "market.trade",
        .labels_json = "{\"symbol\":\"AAPL\",\"venue\":\"XNAS\"}",
        .ts_ns = 1_001,
        .values = &exact_bits,
    }});

    var matched = try engine.queryMarket(.{
        .metric = "market.trade",
        .label_filter_json = "{\"venue\":\"XNAS\"}",
        .start_ts_ns = 1_000,
        .end_ts_ns = 1_001,
        .requested_columns = &.{"price"},
    });
    defer matched.deinit();
    try std.testing.expectEqualStrings("shadow", matched.stats.storage_mode);
    try std.testing.expectEqual(@as(u64, 0), matched.stats.shadow_mismatches);
    try std.testing.expectEqual(@as(usize, 2), matched.rows.len);
    try std.testing.expectEqual(
        @as(u64, @bitCast(@as(f64, 11.0))),
        @as(u64, @bitCast(matched.rows[0].values[0])),
    );
    try std.testing.expectEqual(
        @as(u64, 0x8000_0000_0000_0000),
        @as(u64, @bitCast(matched.rows[1].values[0])),
    );

    const labels = "{\"symbol\":\"AAPL\",\"venue\":\"XNAS\"}";
    const hidden_series_id = types.seriesIdFrom("market.trade.size", labels);
    {
        engine.market_data_mu.lock();
        defer engine.market_data_mu.unlock();
        const hidden = engine.mem.series.getPtr(hidden_series_id) orelse
            return error.MissingFanoutSeries;
        hidden.points.items[hidden.points.items.len - 1].value = 111.0;
    }

    try std.testing.expectError(error.ShadowMismatch, engine.queryMarket(.{
        .metric = "market.trade",
        .label_filter_json = "{\"symbol\":\"AAPL\"}",
        .start_ts_ns = 1_000,
        .end_ts_ns = 1_001,
        .requested_columns = &.{"price"},
    }));
    try std.testing.expectEqual(
        @as(u64, 1),
        engine.metrics.market_shadow_mismatch_total.load(.monotonic),
    );
}

test "engine market query fanout auto rejects unavailable native and incomplete rows" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(
        talloc,
        ".zig-cache/tmp/{s}/market-query-format3-fanout",
        .{tmp.sub_path},
    );
    defer talloc.free(data_path);
    try writeTestRepositoryFormatMarker(
        data_path,
        cas_mod.primary_repository_format_version,
    );
    var config = try testConfig(talloc, data_path);
    config.market_storage_mode = .auto;
    config.market_storage_read_mode = .auto;
    config.flush_interval_ms = std.math.maxInt(u32);
    config.memtable_max_bytes = std.math.maxInt(usize);
    var engine = try Engine.init(talloc, config);
    defer engine.deinit();

    const values = [_]f64{ 10.0, 100.0 };
    _ = try engine.ingestMarketBatch(&.{.{
        .metric = "market.trade",
        .labels_json = "{\"symbol\":\"AAPL\",\"venue\":\"XNAS\"}",
        .ts_ns = 500,
        .values = &values,
    }});
    try waitForQueueEmpty(engine, 1_000);

    var result = try engine.queryMarket(.{
        .metric = "market.trade",
        .start_ts_ns = 0,
        .end_ts_ns = 1_000,
    });
    defer result.deinit();
    try std.testing.expectEqualStrings("fanout", result.stats.storage_mode);
    try std.testing.expectEqual(@as(usize, 1), result.rows.len);

    engine.config.market_storage_read_mode = .native;
    try std.testing.expectError(error.NativeMarketDataUnavailable, engine.queryMarket(.{
        .metric = "market.trade",
        .start_ts_ns = 0,
        .end_ts_ns = 1_000,
    }));
    engine.config.market_storage_read_mode = .auto;

    const labels = "{\"symbol\":\"AAPL\",\"venue\":\"XNAS\"}";
    const missing_series_id = types.seriesIdFrom("market.trade.size", labels);
    {
        engine.market_data_mu.lock();
        defer engine.market_data_mu.unlock();
        const missing = engine.mem.series.getPtr(missing_series_id) orelse
            return error.MissingFanoutSeries;
        missing.points.clearRetainingCapacity();
    }
    try std.testing.expectError(error.IncompleteMarketRow, engine.queryMarket(.{
        .metric = "market.trade",
        .start_ts_ns = 0,
        .end_ts_ns = 1_000,
        .requested_columns = &.{"price"},
    }));
}

test "engine market query revision returns historical native values" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(
        talloc,
        ".zig-cache/tmp/{s}/market-query-revision",
        .{tmp.sub_path},
    );
    defer talloc.free(data_path);
    var config = try testConfig(talloc, data_path);
    config.cas_mode = .dual_write;
    config.market_storage_mode = .native_v1;
    config.market_storage_read_mode = .auto;
    config.flush_interval_ms = std.math.maxInt(u32);
    config.memtable_max_bytes = std.math.maxInt(usize);
    var engine = try Engine.init(talloc, config);
    defer engine.deinit();

    const old_values = [_]f64{ 10.0, 100.0 };
    _ = try engine.ingestMarketBatch(&.{.{
        .metric = "market.trade",
        .labels_json = "{\"symbol\":\"AAPL\",\"venue\":\"XNAS\"}",
        .ts_ns = 1_000,
        .values = &old_values,
    }});
    _ = try engine.flushNow();
    const old_head = try engine.cas.?.refs.readHead(cas_mod.main_ref) orelse
        return error.MissingCasHead;
    const old_revision = old_head.toHex();

    const new_values = [_]f64{ 12.0, 120.0 };
    _ = try engine.ingestMarketBatch(&.{.{
        .metric = "market.trade",
        .labels_json = "{\"symbol\":\"AAPL\",\"venue\":\"XNAS\"}",
        .ts_ns = 1_000,
        .values = &new_values,
    }});
    _ = try engine.flushNow();

    var historical = try engine.queryMarket(.{
        .metric = "market.trade",
        .start_ts_ns = 1_000,
        .end_ts_ns = 1_000,
        .revision = old_revision[0..],
    });
    defer historical.deinit();
    try std.testing.expectEqualStrings("native", historical.stats.storage_mode);
    try std.testing.expectEqual(@as(usize, 1), historical.rows.len);
    try std.testing.expectEqual(
        @as(u64, @bitCast(@as(f64, 10.0))),
        @as(u64, @bitCast(historical.rows[0].values[0])),
    );

    var current = try engine.queryMarket(.{
        .metric = "market.trade",
        .start_ts_ns = 1_000,
        .end_ts_ns = 1_000,
    });
    defer current.deinit();
    try std.testing.expectEqual(
        @as(u64, @bitCast(@as(f64, 12.0))),
        @as(u64, @bitCast(current.rows[0].values[0])),
    );
}

test "engine compacts native market corrections and preserves CAS revisions" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(
        talloc,
        ".zig-cache/tmp/{s}/native-market-compaction",
        .{tmp.sub_path},
    );
    defer talloc.free(data_path);
    var config = try testConfig(talloc, data_path);
    config.cas_mode = .dual_write;
    config.market_storage_mode = .native_v1;
    config.market_storage_read_mode = .auto;
    config.flush_interval_ms = std.math.maxInt(u32);
    config.memtable_max_bytes = std.math.maxInt(usize);
    var engine = try Engine.init(talloc, config);
    defer engine.deinit();

    const first_values = [_]f64{ 10.0, 100.0 };
    const original_values = [_]f64{ 20.0, 200.0 };
    _ = try engine.ingestMarketBatch(&.{
        .{
            .metric = "market.trade",
            .labels_json = "{\"symbol\":\"AAPL\",\"venue\":\"XNAS\"}",
            .ts_ns = 1_000,
            .values = &first_values,
        },
        .{
            .metric = "market.trade",
            .labels_json = "{\"symbol\":\"AAPL\",\"venue\":\"XNAS\"}",
            .ts_ns = 2_000,
            .values = &original_values,
        },
    });
    _ = try engine.flushNow();

    const corrected_values = [_]f64{ 22.0, 220.0 };
    const final_values = [_]f64{ 30.0, 300.0 };
    _ = try engine.ingestMarketBatch(&.{
        .{
            .metric = "market.trade",
            .labels_json = "{\"symbol\":\"AAPL\",\"venue\":\"XNAS\"}",
            .ts_ns = 2_000,
            .values = &corrected_values,
        },
        .{
            .metric = "market.trade",
            .labels_json = "{\"symbol\":\"AAPL\",\"venue\":\"XNAS\"}",
            .ts_ns = 3_000,
            .values = &final_values,
        },
    });
    _ = try engine.flushNow();
    try std.testing.expectEqual(@as(usize, 2), engine.market_manifest.list().len);

    var source_paths = std.array_list.Managed([]u8).init(talloc);
    defer {
        for (source_paths.items) |path| talloc.free(path);
        source_paths.deinit();
    }
    for (engine.market_manifest.list()) |descriptor| {
        try source_paths.append(try talloc.dupe(u8, descriptor.path));
    }

    const pre_compaction_head = try engine.cas.?.refs.readHead(cas_mod.main_ref) orelse
        return error.MissingCasHead;
    const pre_compaction_revision = pre_compaction_head.toHex();
    for (source_paths.items) |path| {
        try engine.data_dir.deleteFile(path);
    }
    try std.testing.expect(try engine.compactNow());
    try std.testing.expectEqual(@as(usize, 1), engine.market_manifest.list().len);
    try engine.verifyCasState();

    const output_path = engine.market_manifest.list()[0].path;
    try engine.data_dir.access(output_path, .{});
    for (source_paths.items) |path| {
        try std.testing.expectError(error.FileNotFound, engine.data_dir.access(path, .{}));
    }

    var current = try engine.queryMarket(.{
        .metric = "market.trade",
        .start_ts_ns = 1_000,
        .end_ts_ns = 3_000,
    });
    defer current.deinit();
    try std.testing.expectEqual(@as(usize, 3), current.rows.len);
    try std.testing.expectEqual(@as(i64, 2_000), current.rows[1].ts_ns);
    try std.testing.expectEqual(
        @as(u64, @bitCast(corrected_values[0])),
        @as(u64, @bitCast(current.rows[1].values[0])),
    );
    try std.testing.expectEqual(
        @as(u64, @bitCast(corrected_values[1])),
        @as(u64, @bitCast(current.rows[1].values[1])),
    );

    var historical = try engine.queryMarket(.{
        .metric = "market.trade",
        .start_ts_ns = 1_000,
        .end_ts_ns = 3_000,
        .revision = pre_compaction_revision[0..],
    });
    defer historical.deinit();
    try std.testing.expectEqual(@as(usize, 3), historical.rows.len);
    try std.testing.expectEqual(
        @as(u64, @bitCast(corrected_values[0])),
        @as(u64, @bitCast(historical.rows[1].values[0])),
    );

    const post_compaction_head = try engine.cas.?.refs.readHead(cas_mod.main_ref) orelse
        return error.MissingCasHead;
    const post_compaction_revision = post_compaction_head.toHex();
    const diff = try engine.cas.?.diffSnapshots(
        pre_compaction_revision[0..],
        post_compaction_revision[0..],
    );
    try std.testing.expectEqual(@as(usize, 1), diff.market_segments_added);
    try std.testing.expectEqual(@as(usize, 2), diff.market_segments_removed);

    const refs = try engine.cas.?.listRefs();
    defer {
        for (refs) |*entry| entry.deinit(talloc);
        talloc.free(refs);
    }
    var saw_checkpoint = false;
    for (refs) |entry| {
        if (std.mem.startsWith(u8, entry.name, "checkpoints/compaction-") and
            entry.id.eql(pre_compaction_head))
        {
            saw_checkpoint = true;
            break;
        }
    }
    try std.testing.expect(saw_checkpoint);
}

test "engine native market rows drive rollups and signals without scalar fanout" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(
        talloc,
        ".zig-cache/tmp/{s}/native-derived-runtime",
        .{tmp.sub_path},
    );
    defer talloc.free(data_path);
    var config = try testConfig(talloc, data_path);
    config.cas_mode = .dual_write;
    config.market_storage_mode = .native_v1;
    config.market_storage_read_mode = .auto;
    config.flush_interval_ms = std.math.maxInt(u32);
    config.memtable_max_bytes = std.math.maxInt(usize);
    var engine = try Engine.init(talloc, config);
    defer engine.deinit();

    engine.stop_flag = true;
    engine.derived_mu.lock();
    engine.derived_pending = true;
    engine.derived_mu.unlock();
    engine.derived_cv.broadcast();
    if (engine.derived_thread) |thread| {
        thread.join();
        engine.derived_thread = null;
    }
    engine.stop_flag = false;

    var trade_policy = try engine.registerBarPolicy(.{
        .id = "native-trade-1m",
        .source_metric = "market.trade",
        .interval_ns = 60 * std.time.ns_per_s,
        .session_rule = "all_sessions",
        .no_trade_rule = "skip_empty",
        .halt_rule = "skip_halts",
        .correction_policy = "append_only",
        .trade_filter = null,
    });
    defer trade_policy.deinit(talloc);
    var trade_rollup = try engine.registerRollup(.{
        .id = "native-bars-1m",
        .source_metric = "market.trade",
        .target_metric = "market.bar",
        .policy_id = trade_policy.id,
        .transform_kind = .trade_to_bar,
    });
    defer trade_rollup.deinit(talloc);

    const trade_values_0 = [_]f64{ 10.0, 1.0 };
    const trade_values_1 = [_]f64{ 12.0, 2.0 };
    const trade_values_2 = [_]f64{ 11.0, 3.0 };
    _ = try engine.ingestMarketBatch(&.{
        .{
            .metric = "market.trade",
            .labels_json = "{\"venue\":\"XNAS\",\"symbol\":\"AAPL\"}",
            .ts_ns = 0,
            .values = &trade_values_0,
        },
        .{
            .metric = "market.trade",
            .labels_json = "{\"symbol\":\"AAPL\",\"venue\":\"XNAS\"}",
            .ts_ns = 30 * std.time.ns_per_s,
            .values = &trade_values_1,
        },
        .{
            .metric = "market.trade",
            .labels_json = "{\"symbol\":\"AAPL\",\"venue\":\"XNAS\"}",
            .ts_ns = 61 * std.time.ns_per_s,
            .values = &trade_values_2,
        },
    });

    const trade_labels = "{\"symbol\":\"AAPL\",\"venue\":\"XNAS\"}";
    const trade_report = try engine.processRollupDefinitionFiltered(
        trade_rollup,
        trade_labels,
    );
    defer if (trade_report.last_event_id) |event_id| talloc.free(event_id);
    try std.testing.expectEqual(@as(u64, 3), trade_report.rows_processed);
    try std.testing.expectEqual(@as(u64, 6), trade_report.emissions_total);

    var bars = try engine.queryMarket(.{
        .metric = "market.bar",
        .label_filter_json = "{\"bar_policy_id\":\"native-trade-1m\",\"interval\":\"60000000000\",\"symbol\":\"AAPL\",\"venue\":\"XNAS\"}",
        .start_ts_ns = 0,
        .end_ts_ns = 0,
    });
    defer bars.deinit();
    try std.testing.expectEqualStrings("native", bars.stats.storage_mode);
    try std.testing.expectEqual(@as(usize, 1), bars.rows.len);
    try std.testing.expectEqual(@as(usize, 6), bars.rows[0].values.len);
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), bars.rows[0].values[0], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 12.0), bars.rows[0].values[1], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), bars.rows[0].values[2], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 12.0), bars.rows[0].values[3], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), bars.rows[0].values[4], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 34.0 / 3.0), bars.rows[0].values[5], 1e-9);

    var signal = try engine.registerSignal(.{
        .id = "native-close-ema",
        .input_metric = "market.bar",
        .policy_id = trade_policy.id,
        .expression_kind = .ema,
        .params_json = "{\"column\":\"close\",\"period\":1}",
        .emit_rule = "on_close",
    });
    defer signal.deinit(talloc);
    const signal_report = try engine.processSignalDefinitionFiltered(
        signal,
        bars.rows[0].canonical_labels,
    );
    defer if (signal_report.last_event_id) |event_id| talloc.free(event_id);
    try std.testing.expectEqual(@as(u64, 1), signal_report.rows_processed);
    try std.testing.expectEqual(@as(u64, 1), signal_report.emissions_total);

    const signal_events = try engine.listSignalEvents(
        signal.id,
        signal.version,
        null,
        null,
        null,
        10,
    );
    defer {
        for (signal_events) |*event| event.deinit(talloc);
        talloc.free(signal_events);
    }
    try std.testing.expectEqual(@as(usize, 1), signal_events.len);
    try std.testing.expectApproxEqAbs(@as(f64, 12.0), signal_events[0].value, 1e-9);

    var bar_policy = try engine.registerBarPolicy(.{
        .id = "native-bar-5m",
        .source_metric = "market.bar",
        .interval_ns = 5 * 60 * std.time.ns_per_s,
        .session_rule = "all_sessions",
        .no_trade_rule = "skip_empty",
        .halt_rule = "skip_halts",
        .correction_policy = "append_only",
        .trade_filter = null,
    });
    defer bar_policy.deinit(talloc);
    var bar_rollup = try engine.registerRollup(.{
        .id = "native-bars-5m",
        .source_metric = "market.bar",
        .target_metric = "market.bar",
        .policy_id = bar_policy.id,
        .transform_kind = .bar_to_bar,
    });
    defer bar_rollup.deinit(talloc);

    const source_bar_values_0 = [_]f64{ 20.0, 22.0, 19.0, 21.0, 4.0, 20.5 };
    const source_bar_values_1 = [_]f64{ 21.0, 24.0, 20.0, 23.0, 6.0, 22.5 };
    const source_bar_values_2 = [_]f64{ 23.0, 25.0, 22.0, 24.0, 5.0, 23.5 };
    const source_bar_labels = "{\"bar_policy_id\":\"native-trade-1m\",\"interval\":\"60000000000\",\"symbol\":\"MSFT\",\"venue\":\"XNAS\"}";
    _ = try engine.ingestMarketBatch(&.{
        .{
            .metric = "market.bar",
            .labels_json = source_bar_labels,
            .ts_ns = 0,
            .values = &source_bar_values_0,
        },
        .{
            .metric = "market.bar",
            .labels_json = source_bar_labels,
            .ts_ns = 60 * std.time.ns_per_s,
            .values = &source_bar_values_1,
        },
        .{
            .metric = "market.bar",
            .labels_json = source_bar_labels,
            .ts_ns = 301 * std.time.ns_per_s,
            .values = &source_bar_values_2,
        },
    });
    const bar_report = try engine.processRollupDefinitionFiltered(
        bar_rollup,
        source_bar_labels,
    );
    defer if (bar_report.last_event_id) |event_id| talloc.free(event_id);
    try std.testing.expectEqual(@as(u64, 3), bar_report.rows_processed);
    try std.testing.expectEqual(@as(u64, 6), bar_report.emissions_total);

    var rolled_bars = try engine.queryMarket(.{
        .metric = "market.bar",
        .label_filter_json = "{\"bar_policy_id\":\"native-bar-5m\",\"interval\":\"300000000000\",\"symbol\":\"MSFT\",\"venue\":\"XNAS\"}",
        .start_ts_ns = 0,
        .end_ts_ns = 0,
    });
    defer rolled_bars.deinit();
    try std.testing.expectEqual(@as(usize, 1), rolled_bars.rows.len);
    try std.testing.expectApproxEqAbs(@as(f64, 20.0), rolled_bars.rows[0].values[0], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 24.0), rolled_bars.rows[0].values[1], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 19.0), rolled_bars.rows[0].values[2], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 23.0), rolled_bars.rows[0].values[3], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), rolled_bars.rows[0].values[4], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 21.7), rolled_bars.rows[0].values[5], 1e-9);

    var quote_rollup = try engine.registerRollup(.{
        .id = "native-spread-mid",
        .source_metric = "market.quote",
        .target_metric = "market.quote_derived",
        .policy_id = trade_policy.id,
        .transform_kind = .quote_to_spread_mid,
    });
    defer quote_rollup.deinit(talloc);
    const quote_values_0 = [_]f64{ 100.0, 101.0, 5.0, 6.0 };
    const quote_values_1 = [_]f64{ 101.0, 103.0, 7.0, 8.0 };
    const quote_labels = "{\"symbol\":\"NVDA\",\"venue\":\"XNAS\"}";
    _ = try engine.ingestMarketBatch(&.{
        .{
            .metric = "market.quote",
            .labels_json = quote_labels,
            .ts_ns = 10,
            .values = &quote_values_0,
        },
        .{
            .metric = "market.quote",
            .labels_json = quote_labels,
            .ts_ns = 20,
            .values = &quote_values_1,
        },
    });
    const quote_report = try engine.processRollupDefinitionFiltered(
        quote_rollup,
        quote_labels,
    );
    defer if (quote_report.last_event_id) |event_id| talloc.free(event_id);
    try std.testing.expectEqual(@as(u64, 2), quote_report.rows_processed);
    try std.testing.expectEqual(@as(u64, 4), quote_report.emissions_total);
}

fn ingestLegacyBarScalars(
    engine: *Engine,
    alloc: std.mem.Allocator,
    labels_json: []const u8,
    ts_ns: i64,
    values: [6]f64,
) !void {
    const columns = [_][]const u8{ "open", "high", "low", "close", "volume", "vwap" };
    for (columns, values) |column, value| {
        const metric = try std.fmt.allocPrint(alloc, "market.bar.{s}", .{column});
        defer alloc.free(metric);
        _ = try engine.ingestExactMetric(metric, labels_json, ts_ns, value, null);
    }
}

test "engine derived processors include native and legacy scalar bar groups" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(
        talloc,
        ".zig-cache/tmp/{s}/mixed-derived-groups",
        .{tmp.sub_path},
    );
    defer talloc.free(data_path);
    var config = try testConfig(talloc, data_path);
    config.cas_mode = .dual_write;
    config.market_storage_mode = .native_v1;
    config.market_storage_read_mode = .auto;
    config.flush_interval_ms = std.math.maxInt(u32);
    config.memtable_max_bytes = std.math.maxInt(usize);
    var engine = try Engine.init(talloc, config);
    defer engine.deinit();

    engine.stop_flag = true;
    engine.derived_mu.lock();
    engine.derived_pending = true;
    engine.derived_mu.unlock();
    engine.derived_cv.broadcast();
    if (engine.derived_thread) |thread| {
        thread.join();
        engine.derived_thread = null;
    }
    engine.stop_flag = false;

    var policy = try engine.registerBarPolicy(.{
        .id = "mixed-groups-5m",
        .source_metric = "market.bar",
        .interval_ns = 5 * 60 * std.time.ns_per_s,
        .session_rule = "all_sessions",
        .no_trade_rule = "skip_empty",
        .halt_rule = "skip_halts",
        .correction_policy = "append_only",
        .trade_filter = null,
    });
    defer policy.deinit(talloc);
    var rollup = try engine.registerRollup(.{
        .id = "mixed-groups-rollup",
        .source_metric = "market.bar",
        .target_metric = "market.bar",
        .policy_id = policy.id,
        .transform_kind = .bar_to_bar,
    });
    defer rollup.deinit(talloc);
    var signal = try engine.registerSignal(.{
        .id = "mixed-groups-signal",
        .input_metric = "market.bar",
        .policy_id = policy.id,
        .expression_kind = .ema,
        .params_json = "{\"column\":\"close\",\"period\":1}",
        .emit_rule = "on_close",
    });
    defer signal.deinit(talloc);

    const native_labels = "{\"bar_policy_id\":\"legacy-1m\",\"interval\":\"60000000000\",\"symbol\":\"NATIVE\",\"venue\":\"XNAS\"}";
    const legacy_labels = "{\"bar_policy_id\":\"legacy-1m\",\"interval\":\"60000000000\",\"symbol\":\"LEGACY\",\"venue\":\"XNAS\"}";
    const native_values_0 = [_]f64{ 20.0, 22.0, 19.0, 21.0, 4.0, 20.5 };
    const native_values_1 = [_]f64{ 21.0, 24.0, 20.0, 23.0, 6.0, 22.5 };
    _ = try engine.ingestMarketBatch(&.{
        .{ .metric = "market.bar", .labels_json = native_labels, .ts_ns = 0, .values = &native_values_0 },
        .{ .metric = "market.bar", .labels_json = native_labels, .ts_ns = 5 * 60 * std.time.ns_per_s, .values = &native_values_1 },
    });
    try ingestLegacyBarScalars(engine, talloc, legacy_labels, 0, .{ 30.0, 32.0, 29.0, 31.0, 2.0, 30.5 });
    try ingestLegacyBarScalars(engine, talloc, legacy_labels, 5 * 60 * std.time.ns_per_s, .{ 31.0, 34.0, 30.0, 33.0, 3.0, 32.5 });
    _ = try engine.flushNow();

    const signal_report = try engine.processSignalDefinitionFiltered(signal, null);
    defer if (signal_report.last_event_id) |event_id| talloc.free(event_id);
    try std.testing.expectEqual(@as(u64, 4), signal_report.rows_processed);
    try std.testing.expectEqual(@as(u64, 4), signal_report.emissions_total);

    const rollup_report = try engine.processRollupDefinitionFiltered(rollup, null);
    defer if (rollup_report.last_event_id) |event_id| talloc.free(event_id);
    try std.testing.expectEqual(@as(u64, 4), rollup_report.rows_processed);
    try std.testing.expectEqual(@as(u64, 12), rollup_report.emissions_total);

    var rolled = try engine.queryMarket(.{
        .metric = "market.bar",
        .label_filter_json = "{\"bar_policy_id\":\"mixed-groups-5m\",\"interval\":\"300000000000\"}",
        .start_ts_ns = 0,
        .end_ts_ns = 0,
    });
    defer rolled.deinit();
    try std.testing.expectEqual(@as(usize, 2), rolled.rows.len);
}

test "engine derived native rows retain scalar history and override overlapping corrections" {
    const talloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(
        talloc,
        ".zig-cache/tmp/{s}/mixed-derived-correction",
        .{tmp.sub_path},
    );
    defer talloc.free(data_path);
    var config = try testConfig(talloc, data_path);
    config.cas_mode = .dual_write;
    config.market_storage_mode = .native_v1;
    config.market_storage_read_mode = .auto;
    config.flush_interval_ms = std.math.maxInt(u32);
    config.memtable_max_bytes = std.math.maxInt(usize);
    var engine = try Engine.init(talloc, config);
    defer engine.deinit();

    engine.stop_flag = true;
    engine.derived_mu.lock();
    engine.derived_pending = true;
    engine.derived_mu.unlock();
    engine.derived_cv.broadcast();
    if (engine.derived_thread) |thread| {
        thread.join();
        engine.derived_thread = null;
    }
    engine.stop_flag = false;

    var policy = try engine.registerBarPolicy(.{
        .id = "mixed-correction-5m",
        .source_metric = "market.bar",
        .interval_ns = 5 * 60 * std.time.ns_per_s,
        .session_rule = "all_sessions",
        .no_trade_rule = "skip_empty",
        .halt_rule = "skip_halts",
        .correction_policy = "append_only",
        .trade_filter = null,
    });
    defer policy.deinit(talloc);
    var rollup = try engine.registerRollup(.{
        .id = "mixed-correction-rollup",
        .source_metric = "market.bar",
        .target_metric = "market.bar",
        .policy_id = policy.id,
        .transform_kind = .bar_to_bar,
    });
    defer rollup.deinit(talloc);

    const labels = "{\"bar_policy_id\":\"legacy-1m\",\"interval\":\"60000000000\",\"symbol\":\"MIXED\",\"venue\":\"XNAS\"}";
    try ingestLegacyBarScalars(engine, talloc, labels, 0, .{ 100.0, 101.0, 99.0, 100.0, 2.0, 100.0 });
    try ingestLegacyBarScalars(engine, talloc, labels, 60 * std.time.ns_per_s, .{ 10.0, 11.0, 9.0, 10.0, 1.0, 10.0 });
    const native_values_initial = [_]f64{ 20.0, 21.0, 19.0, 20.0, 3.0, 20.0 };
    const native_values_correction = [_]f64{ 30.0, 32.0, 29.0, 31.0, 4.0, 30.0 };
    const native_values_next_bucket = [_]f64{ 31.0, 35.0, 30.0, 34.0, 5.0, 33.0 };
    _ = try engine.ingestMarketBatch(&.{
        .{ .metric = "market.bar", .labels_json = labels, .ts_ns = 60 * std.time.ns_per_s, .values = &native_values_initial },
        .{ .metric = "market.bar", .labels_json = labels, .ts_ns = 60 * std.time.ns_per_s, .values = &native_values_correction },
        .{ .metric = "market.bar", .labels_json = labels, .ts_ns = 5 * 60 * std.time.ns_per_s, .values = &native_values_next_bucket },
    });
    _ = try engine.flushNow();

    const report = try engine.processRollupDefinitionFiltered(rollup, null);
    defer if (report.last_event_id) |event_id| talloc.free(event_id);
    try std.testing.expectEqual(@as(u64, 3), report.rows_processed);
    try std.testing.expectEqual(@as(u64, 6), report.emissions_total);

    var rolled = try engine.queryMarket(.{
        .metric = "market.bar",
        .label_filter_json = "{\"bar_policy_id\":\"mixed-correction-5m\",\"interval\":\"300000000000\",\"symbol\":\"MIXED\"}",
        .start_ts_ns = 0,
        .end_ts_ns = 0,
    });
    defer rolled.deinit();
    try std.testing.expectEqual(@as(usize, 1), rolled.rows.len);
    try std.testing.expectApproxEqAbs(@as(f64, 100.0), rolled.rows[0].values[0], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 101.0), rolled.rows[0].values[1], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 29.0), rolled.rows[0].values[2], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 31.0), rolled.rows[0].values[3], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 6.0), rolled.rows[0].values[4], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 320.0 / 6.0), rolled.rows[0].values[5], 1e-9);
}
