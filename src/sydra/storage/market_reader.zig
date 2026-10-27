const std = @import("std");
const cas = @import("cas.zig");
const cfg = @import("../config.zig");
const market_catalog = @import("market_catalog.zig");
const market_identity = @import("market_identity.zig");
const market_manifest = @import("market_manifest.zig");
const market_memtable = @import("market_memtable.zig");
const market_segment = @import("market_segment.zig");
const object_store = @import("object_store.zig");

const ManagedArrayList = std.array_list.Managed;

pub const MarketSeriesId = market_identity.MarketSeriesId;
pub const SchemaDigest = market_identity.SchemaDigest;
pub const RowFingerprint = market_segment.RowFingerprint;

pub const RevisionToken = struct {
    value: []const u8,
};

pub const QueryRequest = struct {
    metric: []const u8,
    /// Optional JSON object. Keys present here must exactly match the
    /// registered canonical labels for a series; omitted labels are wildcards.
    label_filter_json: ?[]const u8 = null,
    start_ts_ns: i64,
    end_ts_ns: i64,
    /// Empty means all columns in schema order.
    requested_columns: []const []const u8 = &.{},
    revision: ?RevisionToken = null,
};

pub const QueryStats = struct {
    storage_mode: []const u8 = "native",
    series_scanned: u64 = 0,
    blocks_scanned: u64 = 0,
    blocks_pruned: u64 = 0,
    columns_read: u64 = 0,
    bytes_decoded: u64 = 0,
    shadow_mismatches: u64 = 0,
};

pub const CanonicalRow = struct {
    market_series_id: MarketSeriesId,
    schema_digest: SchemaDigest,
    metric: []u8,
    canonical_labels: []u8,
    ts_ns: i64,
    write_sequence: u64,
    values: []f64,
    row_fingerprint: RowFingerprint,

    pub fn deinit(self: *CanonicalRow, alloc: std.mem.Allocator) void {
        alloc.free(self.metric);
        alloc.free(self.canonical_labels);
        alloc.free(self.values);
        self.* = undefined;
    }
};

pub const QueryResult = struct {
    allocator: std.mem.Allocator,
    metric: []u8,
    requested_columns: [][]u8,
    rows: []CanonicalRow,
    stats: QueryStats,

    pub fn deinit(self: *QueryResult) void {
        self.allocator.free(self.metric);
        for (self.requested_columns) |column| self.allocator.free(column);
        self.allocator.free(self.requested_columns);
        deinitCanonicalRows(self.allocator, self.rows);
        self.* = undefined;
    }
};

pub const MarketReader = struct {
    allocator: std.mem.Allocator,
    source: Source,

    const LocalSource = struct {
        data_dir: std.fs.Dir,
        catalog: ?*market_catalog.Catalog,
        schema_snapshot: ?*const market_catalog.MarketSchema = null,
        series_snapshot: ?[]const market_catalog.MarketSeriesIdentity = null,
        manifest: *const market_manifest.Manifest,
        memtable: ?*const market_memtable.MarketMemtable = null,
    };

    const RevisionSource = struct {
        snapshot_index: *const cas.SnapshotIndex,
    };

    const Source = union(enum) {
        local: LocalSource,
        revision: RevisionSource,
    };

    const RegisteredSeriesView = struct {
        entries: []const market_catalog.MarketSeriesIdentity,
        owned: ?[]market_catalog.MarketSeriesIdentity = null,

        fn deinit(self: *RegisteredSeriesView, alloc: std.mem.Allocator) void {
            if (self.owned) |entries| {
                for (entries) |*entry| entry.deinit(alloc);
                alloc.free(entries);
            }
            self.* = undefined;
        }
    };

    pub fn init(
        allocator: std.mem.Allocator,
        data_dir: std.fs.Dir,
        catalog: *market_catalog.Catalog,
        manifest: *const market_manifest.Manifest,
        memtable: ?*const market_memtable.MarketMemtable,
    ) MarketReader {
        return .{
            .allocator = allocator,
            .source = .{ .local = .{
                .data_dir = data_dir,
                .catalog = catalog,
                .manifest = manifest,
                .memtable = memtable,
            } },
        };
    }

    /// Bind a live read to an Engine-owned catalog snapshot while continuing
    /// to decode the Engine's manifest and memtable under its data lock.
    pub fn initLocalSnapshot(
        allocator: std.mem.Allocator,
        data_dir: std.fs.Dir,
        schema: *const market_catalog.MarketSchema,
        registered_series: []const market_catalog.MarketSeriesIdentity,
        manifest: *const market_manifest.Manifest,
        memtable: ?*const market_memtable.MarketMemtable,
    ) MarketReader {
        return .{
            .allocator = allocator,
            .source = .{ .local = .{
                .data_dir = data_dir,
                .catalog = null,
                .schema_snapshot = schema,
                .series_snapshot = registered_series,
                .manifest = manifest,
                .memtable = memtable,
            } },
        };
    }

    /// Bind all native reads to exactly one immutable CAS snapshot. The caller
    /// owns the SnapshotIndex and keeps it alive for the reader's lifetime.
    pub fn initRevision(
        allocator: std.mem.Allocator,
        snapshot_index: *const cas.SnapshotIndex,
    ) MarketReader {
        return .{
            .allocator = allocator,
            .source = .{ .revision = .{ .snapshot_index = snapshot_index } },
        };
    }

    pub fn query(self: *const MarketReader, request: QueryRequest) !QueryResult {
        if (request.revision != null and self.source == .local) {
            return error.NativeRevisionUnavailable;
        }
        if (request.metric.len == 0) return error.UnknownMarketSchema;
        if (request.start_ts_ns > request.end_ts_ns) return error.InvalidTimeRange;

        var schema = try self.schemaForMetric(request.metric);
        defer schema.deinit(self.allocator);

        var projection = try Projection.resolve(
            self.allocator,
            schema.ordered_columns,
            request.requested_columns,
        );
        defer projection.deinit(self.allocator);

        var filter = try LabelFilter.init(self.allocator, request.label_filter_json);
        defer filter.deinit(self.allocator);

        var registered = try self.registeredSeriesForMetric(request.metric);
        defer registered.deinit(self.allocator);

        var candidates = ManagedArrayList(CandidateRow).init(self.allocator);
        defer {
            for (candidates.items) |*candidate| candidate.deinit(self.allocator);
            candidates.deinit();
        }
        var candidate_by_key = std.AutoHashMap(TimestampKey, usize).init(self.allocator);
        defer candidate_by_key.deinit();

        var stats = QueryStats{};
        var saw_matching_series = false;
        var saw_native_source = false;

        for (registered.entries) |series| {
            if (!std.mem.eql(u8, series.metric, request.metric)) continue;
            if (!try filter.matches(self.allocator, series.canonical_labels)) continue;
            saw_matching_series = true;
            stats.series_scanned += 1;

            const expected_schema_digest = schema.digest();
            if (!std.mem.eql(u8, &series.schema_digest, &expected_schema_digest)) {
                return error.MarketSchemaMismatch;
            }

            const series_has_source = switch (self.source) {
                .local => |local| try self.readLocalSeries(
                    local,
                    series,
                    schema,
                    request,
                    &projection,
                    &candidates,
                    &candidate_by_key,
                    &stats,
                ),
                .revision => |revision| try self.readRevisionSeries(
                    revision,
                    series,
                    schema,
                    request,
                    &projection,
                    &candidates,
                    &candidate_by_key,
                    &stats,
                ),
            };
            saw_native_source = saw_native_source or series_has_source;
        }

        if (saw_matching_series and !saw_native_source) return error.NativeMarketDataUnavailable;

        std.sort.block(CandidateRow, candidates.items, {}, CandidateRow.lessThan);

        const rows = try cloneCanonicalRows(self.allocator, candidates.items);
        errdefer deinitCanonicalRows(self.allocator, rows);

        const result_metric = try self.allocator.dupe(u8, request.metric);
        errdefer self.allocator.free(result_metric);
        const result_columns = try projection.cloneNames(self.allocator);
        errdefer {
            for (result_columns) |column| self.allocator.free(column);
            self.allocator.free(result_columns);
        }

        return .{
            .allocator = self.allocator,
            .metric = result_metric,
            .requested_columns = result_columns,
            .rows = rows,
            .stats = stats,
        };
    }

    fn schemaForMetric(
        self: *const MarketReader,
        metric: []const u8,
    ) !market_catalog.MarketSchema {
        return switch (self.source) {
            .local => |local| if (local.schema_snapshot) |schema|
                if (std.mem.eql(u8, schema.metric, metric))
                    try schema.clone(self.allocator)
                else
                    error.UnknownMarketSchema
            else
                local.catalog.?.getSchema(metric) orelse error.UnknownMarketSchema,
            .revision => |revision| blk: {
                const snapshot = revision.snapshot_index.snapshot.market_catalog_snapshot orelse
                    return error.NativeMarketDataUnavailable;
                for (snapshot.schemas) |schema| {
                    if (std.mem.eql(u8, schema.metric, metric)) {
                        break :blk try schema.clone(self.allocator);
                    }
                }
                return error.UnknownMarketSchema;
            },
        };
    }

    fn registeredSeriesForMetric(
        self: *const MarketReader,
        metric: []const u8,
    ) !RegisteredSeriesView {
        return switch (self.source) {
            .local => |local| if (local.series_snapshot) |entries|
                .{ .entries = entries }
            else blk: {
                const entries = try local.catalog.?.listMarketSeriesForMetric(metric);
                break :blk .{ .entries = entries, .owned = entries };
            },
            .revision => |revision| blk: {
                const snapshot = revision.snapshot_index.snapshot.market_catalog_snapshot orelse
                    return error.NativeMarketDataUnavailable;
                const entries = snapshot.market_series orelse
                    return error.NativeMarketDataUnavailable;
                break :blk .{ .entries = entries };
            },
        };
    }

    fn readLocalSeries(
        self: *const MarketReader,
        local: LocalSource,
        series: market_catalog.MarketSeriesIdentity,
        schema: market_catalog.MarketSchema,
        request: QueryRequest,
        projection: *const Projection,
        candidates: *ManagedArrayList(CandidateRow),
        candidate_by_key: *std.AutoHashMap(TimestampKey, usize),
        stats: *QueryStats,
    ) !bool {
        const has_manifest_source = hasAnyManifestDescriptorForSeries(
            local.manifest,
            series.series_id,
        );
        const has_memtable_source = if (local.memtable) |mem|
            mem.seriesState(series.series_id) != null
        else
            false;

        const descriptors = try local.manifest.selectBySeriesAndTime(
            self.allocator,
            series.series_id,
            request.start_ts_ns,
            request.end_ts_ns,
        );
        defer market_manifest.deinitDescriptorList(self.allocator, descriptors);

        for (descriptors) |descriptor| {
            try validateDescriptorAgainstSchema(descriptor, series, schema);
            var segment_result = market_segment.readProjectedRange(
                self.allocator,
                local.data_dir,
                descriptor.path,
                request.start_ts_ns,
                request.end_ts_ns,
                projection.namesConst(),
            ) catch |err| switch (err) {
                error.FileNotFound => return error.NativeMarketDataUnavailable,
                else => return err,
            };
            defer segment_result.deinit(self.allocator);

            try market_segment.validateExpectedSchema(&segment_result.metadata, .{
                .market_series_id = series.series_id,
                .schema_digest = nativeSchemaDigest(schema),
                .metric = series.metric,
                .canonical_labels = series.canonical_labels,
                .hour = descriptor.hour_bucket,
                .column_names = schema.ordered_columns,
            });
            try validateSegmentDescriptorMatchesRead(descriptor, &segment_result.metadata);
            try self.appendSegmentCandidates(
                series,
                &segment_result,
                projection,
                candidates,
                candidate_by_key,
                stats,
            );
        }

        if (local.memtable) |mem| {
            if (mem.seriesState(series.series_id)) |state| {
                try validateMemtableState(series, schema, state);
                var full_rows = try mem.queryProjected(
                    self.allocator,
                    series.series_id,
                    .{ .start_ns = request.start_ts_ns, .end_ns = request.end_ts_ns },
                    projection.all_schema_indices,
                );
                defer full_rows.deinit();

                if (full_rows.timestamps.len > 0) {
                    stats.columns_read += projection.indices.len;
                    stats.bytes_decoded += @as(
                        u64,
                        @intCast(
                            full_rows.timestamps.len *
                                projection.indices.len *
                                @sizeOf(f64),
                        ),
                    );
                }

                for (full_rows.timestamps, 0..) |ts_ns, row_idx| {
                    const values = try self.allocator.alloc(f64, projection.indices.len);
                    for (projection.indices, 0..) |source_idx, projected_idx| {
                        values[projected_idx] = full_rows.columns[source_idx][row_idx];
                    }
                    try addCandidate(self.allocator, candidates, candidate_by_key, .{
                        .market_series_id = series.series_id,
                        .schema_digest = series.schema_digest,
                        .metric = series.metric,
                        .canonical_labels = series.canonical_labels,
                        .ts_ns = ts_ns,
                        .write_sequence = full_rows.write_sequences[row_idx],
                        .values = values,
                        .row_fingerprint = fingerprintFullMemtableRow(
                            full_rows,
                            row_idx,
                        ),
                    });
                }
            }
        }

        return has_manifest_source or has_memtable_source;
    }

    fn readRevisionSeries(
        self: *const MarketReader,
        revision: RevisionSource,
        series: market_catalog.MarketSeriesIdentity,
        schema: market_catalog.MarketSchema,
        request: QueryRequest,
        projection: *const Projection,
        candidates: *ManagedArrayList(CandidateRow),
        candidate_by_key: *std.AutoHashMap(TimestampKey, usize),
        stats: *QueryStats,
    ) !bool {
        var has_source = false;
        for (revision.snapshot_index.snapshot.market_segment_descriptors) |descriptor| {
            if (descriptor.market_series_id != series.series_id) continue;
            has_source = true;
            if (descriptor.end_ts_ns < request.start_ts_ns or
                descriptor.start_ts_ns > request.end_ts_ns)
            {
                continue;
            }

            try validateCasDescriptorAgainstSchema(descriptor, series, schema);
            const root_id = descriptor.segmentRoot() orelse
                return error.NativeMarketDataUnavailable;
            var segment_result = market_segment.readProjectedRangeSegmentRoot(
                self.allocator,
                revision.snapshot_index.store,
                root_id,
                request.start_ts_ns,
                request.end_ts_ns,
                projection.namesConst(),
            ) catch |err| switch (err) {
                error.OutOfMemory => return err,
                error.FileNotFound => return error.NativeMarketDataUnavailable,
                else => return error.NativeMarketDataCorrupt,
            };
            defer segment_result.deinit(self.allocator);

            market_segment.validateExpectedSchema(&segment_result.metadata, .{
                .market_series_id = series.series_id,
                .schema_digest = nativeSchemaDigest(schema),
                .metric = series.metric,
                .canonical_labels = series.canonical_labels,
                .hour = descriptor.hour_bucket,
                .column_names = schema.ordered_columns,
            }) catch return error.MarketSegmentSchemaMismatch;
            try validateCasSegmentDescriptorMatchesRead(descriptor, &segment_result.metadata);
            try self.appendSegmentCandidates(
                series,
                &segment_result,
                projection,
                candidates,
                candidate_by_key,
                stats,
            );
        }
        return has_source;
    }

    fn appendSegmentCandidates(
        self: *const MarketReader,
        series: market_catalog.MarketSeriesIdentity,
        segment_result: *const market_segment.ReadResult,
        projection: *const Projection,
        candidates: *ManagedArrayList(CandidateRow),
        candidate_by_key: *std.AutoHashMap(TimestampKey, usize),
        stats: *QueryStats,
    ) !void {
        stats.blocks_scanned += segment_result.stats.blocks_scanned;
        stats.blocks_pruned += segment_result.stats.blocks_pruned;
        stats.columns_read += segment_result.stats.columns_decoded;
        stats.bytes_decoded += segment_result.stats.bytes_decoded;

        for (segment_result.timestamps, 0..) |ts_ns, row_idx| {
            const values = try self.allocator.alloc(f64, projection.indices.len);
            for (segment_result.columns, 0..) |column, projected_idx| {
                values[projected_idx] = column.values[row_idx];
            }
            try addCandidate(self.allocator, candidates, candidate_by_key, .{
                .market_series_id = series.series_id,
                .schema_digest = series.schema_digest,
                .metric = series.metric,
                .canonical_labels = series.canonical_labels,
                .ts_ns = ts_ns,
                .write_sequence = segment_result.write_sequences[row_idx],
                .values = values,
                .row_fingerprint = segment_result.row_fingerprints[row_idx],
            });
        }
    }
};

fn cloneCanonicalRows(alloc: std.mem.Allocator, candidates: []const CandidateRow) ![]CanonicalRow {
    const rows = try alloc.alloc(CanonicalRow, candidates.len);
    errdefer alloc.free(rows);
    var initialized: usize = 0;
    errdefer for (rows[0..initialized]) |*row| row.deinit(alloc);

    for (candidates, 0..) |candidate, idx| {
        rows[idx] = try candidate.cloneCanonical(alloc);
        initialized += 1;
    }
    return rows;
}

fn deinitCanonicalRows(alloc: std.mem.Allocator, rows: []CanonicalRow) void {
    for (rows) |*row| row.deinit(alloc);
    alloc.free(rows);
}

const Projection = struct {
    indices: []usize,
    all_schema_indices: []usize,
    names: [][]u8,

    fn resolve(
        alloc: std.mem.Allocator,
        schema_columns: []const []u8,
        requested_columns: []const []const u8,
    ) !Projection {
        if (schema_columns.len == 0) return error.InvalidMarketColumnCount;

        const output_len = if (requested_columns.len == 0) schema_columns.len else requested_columns.len;
        var indices = try alloc.alloc(usize, output_len);
        errdefer alloc.free(indices);
        var names = try alloc.alloc([]u8, output_len);
        errdefer alloc.free(names);
        var initialized_names: usize = 0;
        errdefer {
            for (names[0..initialized_names]) |name| alloc.free(name);
        }

        if (requested_columns.len == 0) {
            for (schema_columns, 0..) |name, idx| {
                indices[idx] = idx;
                names[idx] = try alloc.dupe(u8, name);
                initialized_names += 1;
            }
        } else {
            for (requested_columns, 0..) |name, idx| {
                const source_idx = findColumn(schema_columns, name) orelse return error.InvalidProjection;
                for (indices[0..idx]) |previous| {
                    if (previous == source_idx) return error.InvalidProjection;
                }
                indices[idx] = source_idx;
                names[idx] = try alloc.dupe(u8, schema_columns[source_idx]);
                initialized_names += 1;
            }
        }

        const all_schema_indices = try alloc.alloc(usize, schema_columns.len);
        errdefer alloc.free(all_schema_indices);
        for (all_schema_indices, 0..) |*slot, idx| slot.* = idx;

        return .{
            .indices = indices,
            .all_schema_indices = all_schema_indices,
            .names = names,
        };
    }

    fn deinit(self: *Projection, alloc: std.mem.Allocator) void {
        alloc.free(self.indices);
        alloc.free(self.all_schema_indices);
        for (self.names) |name| alloc.free(name);
        alloc.free(self.names);
        self.* = undefined;
    }

    fn namesConst(self: *const Projection) []const []const u8 {
        return self.names;
    }

    fn cloneNames(self: *const Projection, alloc: std.mem.Allocator) ![][]u8 {
        var cloned = try alloc.alloc([]u8, self.names.len);
        errdefer alloc.free(cloned);
        var initialized: usize = 0;
        errdefer {
            for (cloned[0..initialized]) |name| alloc.free(name);
        }
        for (self.names, 0..) |name, idx| {
            cloned[idx] = try alloc.dupe(u8, name);
            initialized += 1;
        }
        return cloned;
    }
};

const LabelFilter = struct {
    canonical: ?[]u8 = null,
    parsed: ?std.json.Parsed(std.json.Value) = null,

    fn init(alloc: std.mem.Allocator, label_filter_json: ?[]const u8) !LabelFilter {
        const raw = label_filter_json orelse return .{};
        const canonical = market_identity.canonicalizeLabels(alloc, raw) catch |err| switch (err) {
            // The canonicalizer writes into an allocator-backed buffer. Its
            // writer adapter reports allocation failure as WriteFailed.
            error.OutOfMemory, error.WriteFailed => return error.OutOfMemory,
            else => return error.InvalidMarketLabels,
        };
        errdefer alloc.free(canonical);
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, canonical, .{}) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return error.InvalidMarketLabels,
        };
        errdefer parsed.deinit();
        if (parsed.value != .object) return error.InvalidMarketLabels;
        return .{ .canonical = canonical, .parsed = parsed };
    }

    fn deinit(self: *LabelFilter, alloc: std.mem.Allocator) void {
        if (self.parsed) |*parsed| parsed.deinit();
        if (self.canonical) |canonical| alloc.free(canonical);
        self.* = undefined;
    }

    fn matches(self: *const LabelFilter, alloc: std.mem.Allocator, canonical_labels: []const u8) !bool {
        const parsed_filter = if (self.parsed) |*parsed| parsed else return true;
        if (parsed_filter.value.object.count() == 0) return true;

        var candidate = std.json.parseFromSlice(std.json.Value, alloc, canonical_labels, .{}) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return error.InvalidMarketLabels,
        };
        defer candidate.deinit();
        if (candidate.value != .object) return error.InvalidMarketLabels;

        var it = parsed_filter.value.object.iterator();
        while (it.next()) |entry| {
            const candidate_value = candidate.value.object.get(entry.key_ptr.*) orelse return false;
            if (!jsonValueEql(entry.value_ptr.*, candidate_value)) return false;
        }
        return true;
    }
};

const TimestampKey = struct {
    market_series_id: MarketSeriesId,
    ts_ns: i64,
};

const CandidateRow = struct {
    market_series_id: MarketSeriesId,
    schema_digest: SchemaDigest,
    metric: []const u8,
    canonical_labels: []const u8,
    ts_ns: i64,
    write_sequence: u64,
    values: []f64,
    row_fingerprint: RowFingerprint,

    fn deinit(self: *CandidateRow, alloc: std.mem.Allocator) void {
        alloc.free(self.values);
        self.* = undefined;
    }

    fn cloneCanonical(self: CandidateRow, alloc: std.mem.Allocator) !CanonicalRow {
        const metric = try alloc.dupe(u8, self.metric);
        errdefer alloc.free(metric);
        const canonical_labels = try alloc.dupe(u8, self.canonical_labels);
        errdefer alloc.free(canonical_labels);
        return .{
            .market_series_id = self.market_series_id,
            .schema_digest = self.schema_digest,
            .metric = metric,
            .canonical_labels = canonical_labels,
            .ts_ns = self.ts_ns,
            .write_sequence = self.write_sequence,
            .values = try alloc.dupe(f64, self.values),
            .row_fingerprint = self.row_fingerprint,
        };
    }

    fn lessThan(_: void, lhs: CandidateRow, rhs: CandidateRow) bool {
        const metric_order = std.mem.order(u8, lhs.metric, rhs.metric);
        if (metric_order != .eq) return metric_order == .lt;
        const label_order = std.mem.order(u8, lhs.canonical_labels, rhs.canonical_labels);
        if (label_order != .eq) return label_order == .lt;
        if (lhs.ts_ns != rhs.ts_ns) return lhs.ts_ns < rhs.ts_ns;
        if (lhs.write_sequence != rhs.write_sequence) return lhs.write_sequence < rhs.write_sequence;
        return lhs.market_series_id < rhs.market_series_id;
    }
};

fn addCandidate(
    alloc: std.mem.Allocator,
    rows: *ManagedArrayList(CandidateRow),
    by_key: *std.AutoHashMap(TimestampKey, usize),
    candidate: CandidateRow,
) !void {
    // This function consumes candidate.values on every return path, including
    // allocation failure while extending either collection.
    var owns_candidate_values = true;
    errdefer if (owns_candidate_values) alloc.free(candidate.values);

    const key = TimestampKey{
        .market_series_id = candidate.market_series_id,
        .ts_ns = candidate.ts_ns,
    };
    if (by_key.get(key)) |existing_idx| {
        var current = &rows.items[existing_idx];
        if (candidate.write_sequence < current.write_sequence) {
            alloc.free(candidate.values);
            owns_candidate_values = false;
            return;
        }
        if (candidate.write_sequence == current.write_sequence) {
            defer alloc.free(candidate.values);
            owns_candidate_values = false;
            try market_segment.validateEqualSequenceFingerprints(
                current.row_fingerprint,
                candidate.row_fingerprint,
            );
            return;
        }

        alloc.free(current.values);
        current.write_sequence = candidate.write_sequence;
        current.values = candidate.values;
        current.row_fingerprint = candidate.row_fingerprint;
        owns_candidate_values = false;
        return;
    }

    const idx = rows.items.len;
    try rows.append(candidate);
    owns_candidate_values = false;
    by_key.put(key, idx) catch |err| {
        var removed = rows.pop().?;
        removed.deinit(alloc);
        return err;
    };
}

fn hasAnyManifestDescriptorForSeries(
    manifest: *const market_manifest.Manifest,
    series_id: MarketSeriesId,
) bool {
    for (manifest.list()) |descriptor| {
        if (descriptor.market_series_id == series_id) return true;
    }
    return false;
}

fn nativeSchemaDigest(schema: market_catalog.MarketSchema) SchemaDigest {
    return market_identity.schemaDigest(
        schema.metric,
        schema.ordered_columns,
        schema.required_labels,
        market_catalog.StorageMapping.native_v1.text(),
    );
}

fn validateDescriptorAgainstSchema(
    descriptor: market_manifest.MarketSegmentDescriptor,
    series: market_catalog.MarketSeriesIdentity,
    schema: market_catalog.MarketSchema,
) !void {
    const catalog_digest = schema.digest();
    const segment_digest = nativeSchemaDigest(schema);
    if (descriptor.market_series_id != series.series_id or
        !std.mem.eql(u8, &series.schema_digest, &catalog_digest) or
        !std.mem.eql(u8, &descriptor.schema_digest, &segment_digest) or
        !std.mem.eql(u8, descriptor.metric, series.metric) or
        !std.mem.eql(u8, descriptor.canonical_labels, series.canonical_labels) or
        !stringSlicesEql(descriptor.column_names, schema.ordered_columns))
    {
        return error.MarketSegmentSchemaMismatch;
    }
}

fn validateSegmentDescriptorMatchesRead(
    descriptor: market_manifest.MarketSegmentDescriptor,
    metadata: *const market_segment.Metadata,
) !void {
    if (descriptor.hour_bucket != metadata.hour or
        descriptor.start_ts_ns != metadata.start_ts_ns or
        descriptor.end_ts_ns != metadata.end_ts_ns or
        descriptor.row_count != metadata.count or
        descriptor.block_count != metadata.block_count)
    {
        return error.MarketSegmentSchemaMismatch;
    }
}

fn validateCasDescriptorAgainstSchema(
    descriptor: cas.MarketSegmentDescriptor,
    series: market_catalog.MarketSeriesIdentity,
    schema: market_catalog.MarketSchema,
) !void {
    const catalog_digest = schema.digest();
    const segment_digest = nativeSchemaDigest(schema);
    if (descriptor.market_series_id != series.series_id or
        !std.mem.eql(u8, &series.schema_digest, &catalog_digest) or
        !std.mem.eql(u8, &descriptor.schema_digest, &segment_digest) or
        !std.mem.eql(u8, descriptor.metric, series.metric) or
        !std.mem.eql(u8, descriptor.canonical_labels, series.canonical_labels) or
        !stringSlicesEql(descriptor.column_names, schema.ordered_columns))
    {
        return error.MarketSegmentSchemaMismatch;
    }
}

fn validateCasSegmentDescriptorMatchesRead(
    descriptor: cas.MarketSegmentDescriptor,
    metadata: *const market_segment.Metadata,
) !void {
    if (descriptor.hour_bucket != metadata.hour or
        descriptor.start_ts_ns != metadata.start_ts_ns or
        descriptor.end_ts_ns != metadata.end_ts_ns or
        descriptor.row_count != metadata.count or
        descriptor.block_count != metadata.block_count)
    {
        return error.MarketSegmentSchemaMismatch;
    }
}

fn validateMemtableState(
    series: market_catalog.MarketSeriesIdentity,
    schema: market_catalog.MarketSchema,
    state: market_memtable.SeriesState,
) !void {
    if (state.identity.series_id != series.series_id or
        !std.mem.eql(u8, state.identity.metric, series.metric) or
        !std.mem.eql(u8, state.identity.canonical_labels, series.canonical_labels) or
        !std.mem.eql(u8, &state.schema_digest, &series.schema_digest) or
        state.column_count != schema.ordered_columns.len)
    {
        return error.MarketSchemaMismatch;
    }
}

fn findColumn(columns: []const []u8, needle: []const u8) ?usize {
    for (columns, 0..) |column, idx| {
        if (std.mem.eql(u8, column, needle)) return idx;
    }
    return null;
}

fn stringSlicesEql(lhs: []const []u8, rhs: []const []u8) bool {
    if (lhs.len != rhs.len) return false;
    for (lhs, rhs) |left, right| {
        if (!std.mem.eql(u8, left, right)) return false;
    }
    return true;
}

fn fingerprintFullMemtableRow(rows: market_memtable.ProjectedRows, row_idx: usize) RowFingerprint {
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update("SYDRA_MARKET_ROW_V1");
    var count_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &count_bytes, @intCast(rows.columns.len), .little);
    hasher.update(&count_bytes);
    for (rows.columns) |column| {
        var value_bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &value_bytes, @bitCast(column[row_idx]), .little);
        hasher.update(&value_bytes);
    }
    var fingerprint: RowFingerprint = undefined;
    hasher.final(&fingerprint);
    return fingerprint;
}

fn jsonValueEql(lhs: std.json.Value, rhs: std.json.Value) bool {
    if (std.meta.activeTag(lhs) != std.meta.activeTag(rhs)) return false;
    return switch (lhs) {
        .null => true,
        .bool => |value| value == rhs.bool,
        .integer => |value| value == rhs.integer,
        .float => |value| value == rhs.float,
        .number_string => |value| std.mem.eql(u8, value, rhs.number_string),
        .string => |value| std.mem.eql(u8, value, rhs.string),
        .array => |items| blk: {
            if (items.items.len != rhs.array.items.len) break :blk false;
            for (items.items, rhs.array.items) |left, right| {
                if (!jsonValueEql(left, right)) break :blk false;
            }
            break :blk true;
        },
        .object => |obj| blk: {
            if (obj.count() != rhs.object.count()) break :blk false;
            var it = obj.iterator();
            while (it.next()) |entry| {
                const right = rhs.object.get(entry.key_ptr.*) orelse break :blk false;
                if (!jsonValueEql(entry.value_ptr.*, right)) break :blk false;
            }
            break :blk true;
        },
    };
}

fn testDigest(byte: u8) SchemaDigest {
    return @splat(byte);
}

fn appendOwnedTestCandidate(
    alloc: std.mem.Allocator,
    rows: *ManagedArrayList(CandidateRow),
    by_key: *std.AutoHashMap(TimestampKey, usize),
    ts_ns: i64,
    write_sequence: u64,
    values: []const f64,
    fingerprint_byte: u8,
) !void {
    const owned_values = try alloc.dupe(f64, values);
    try addCandidate(alloc, rows, by_key, .{
        .market_series_id = 7,
        .schema_digest = testDigest(1),
        .metric = "market.test",
        .canonical_labels = "{\"symbol\":\"AAPL\"}",
        .ts_ns = ts_ns,
        .write_sequence = write_sequence,
        .values = owned_values,
        .row_fingerprint = @splat(fingerprint_byte),
    });
}

fn checkCandidateOwnershipAllocationFailures(alloc: std.mem.Allocator) !void {
    var rows = ManagedArrayList(CandidateRow).init(alloc);
    defer {
        for (rows.items) |*row| row.deinit(alloc);
        rows.deinit();
    }
    var by_key = std.AutoHashMap(TimestampKey, usize).init(alloc);
    defer by_key.deinit();

    try appendOwnedTestCandidate(alloc, &rows, &by_key, 10, 2, &.{ 2, 20 }, 2);
    try appendOwnedTestCandidate(alloc, &rows, &by_key, 10, 1, &.{ 1, 10 }, 1);
    try appendOwnedTestCandidate(alloc, &rows, &by_key, 10, 2, &.{ 2, 20 }, 2);
    try appendOwnedTestCandidate(alloc, &rows, &by_key, 10, 3, &.{ 3, 30 }, 3);
    try appendOwnedTestCandidate(alloc, &rows, &by_key, 20, 1, &.{ 4, 40 }, 4);

    try std.testing.expectEqual(@as(usize, 2), rows.items.len);
    try std.testing.expectEqual(@as(u64, 3), rows.items[0].write_sequence);
    try std.testing.expectEqual(@as(u64, @bitCast(@as(f64, 3))), @as(u64, @bitCast(rows.items[0].values[0])));
}

fn checkCanonicalRowCloneAllocationFailures(alloc: std.mem.Allocator) !void {
    var first_values = [_]f64{ -0.0, @bitCast(@as(u64, 0x7ff8_0000_0000_0042)) };
    var second_values = [_]f64{ 1.25, -99.5 };
    const sources = [_]CandidateRow{
        .{
            .market_series_id = 7,
            .schema_digest = testDigest(2),
            .metric = "market.test",
            .canonical_labels = "{\"symbol\":\"AAPL\"}",
            .ts_ns = -1,
            .write_sequence = 9,
            .values = &first_values,
            .row_fingerprint = @splat(3),
        },
        .{
            .market_series_id = 8,
            .schema_digest = testDigest(4),
            .metric = "market.test",
            .canonical_labels = "{\"symbol\":\"MSFT\"}",
            .ts_ns = 2,
            .write_sequence = 10,
            .values = &second_values,
            .row_fingerprint = @splat(5),
        },
    };
    const cloned = try cloneCanonicalRows(alloc, &sources);
    defer deinitCanonicalRows(alloc, cloned);

    for (sources, cloned) |source, row| {
        try std.testing.expectEqualStrings(source.metric, row.metric);
        try std.testing.expectEqualStrings(source.canonical_labels, row.canonical_labels);
        for (source.values, row.values) |expected, actual| {
            try std.testing.expectEqual(@as(u64, @bitCast(expected)), @as(u64, @bitCast(actual)));
        }
    }
}

fn checkLabelFilterAllocationFailures(alloc: std.mem.Allocator) !void {
    var filter = try LabelFilter.init(
        alloc,
        "{\"venue\":\"XNAS\",\"symbol\":\"AAPL\"}",
    );
    defer filter.deinit(alloc);
    try std.testing.expect(try filter.matches(
        alloc,
        "{\"feed\":\"sip\",\"symbol\":\"AAPL\",\"venue\":\"XNAS\"}",
    ));
    try std.testing.expect(!try filter.matches(
        alloc,
        "{\"feed\":\"sip\",\"symbol\":\"MSFT\",\"venue\":\"XNAS\"}",
    ));
}

test "candidate merge consumes owned values across every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkCandidateOwnershipAllocationFailures,
        .{},
    );
}

test "canonical query row cloning cleans up every partial allocation" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkCanonicalRowCloneAllocationFailures,
        .{},
    );
}

test "label filtering cleans up and preserves every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkLabelFilterAllocationFailures,
        .{},
    );
}

fn buildNativeCatalog(
    alloc: std.mem.Allocator,
    metric: []const u8,
    columns: []const []const u8,
    required_labels: []const []const u8,
) !market_catalog.Catalog {
    var catalog = market_catalog.Catalog.initEmpty(alloc, cfg.FsyncPolicy.none);
    errdefer catalog.deinit();
    var schema = try catalog.registerSchema(.{
        .metric = metric,
        .ordered_columns = columns,
        .required_labels = required_labels,
        .storage_mapping = .native_v1,
    });
    schema.deinit(alloc);
    return catalog;
}

fn addSegmentToManifest(
    alloc: std.mem.Allocator,
    data_dir: std.fs.Dir,
    manifest: *market_manifest.Manifest,
    series: market_catalog.MarketSeriesIdentity,
    columns: []const []const u8,
    rows: []const market_segment.MarketRowView,
) !void {
    const path = try market_segment.write(alloc, data_dir, .{
        .market_series_id = series.series_id,
        .schema_digest = series.schema_digest,
        .metric = series.metric,
        .canonical_labels = series.canonical_labels,
        .hour = market_memtable.hourBucket(rows[0].ts_ns),
        .column_names = columns,
    }, rows);
    defer alloc.free(path);

    var metadata = try market_segment.inspect(alloc, data_dir, path);
    defer metadata.deinit(alloc);

    const bytes = try data_dir.readFileAlloc(alloc, path, 16 * 1024 * 1024);
    defer alloc.free(bytes);
    const digest = market_manifest.contentDigest(bytes);

    try manifest.addBatch(data_dir, &.{.{
        .path = path,
        .market_series_id = series.series_id,
        .schema_digest = series.schema_digest,
        .metric = series.metric,
        .canonical_labels = series.canonical_labels,
        .hour_bucket = metadata.hour,
        .start_ts_ns = metadata.start_ts_ns,
        .end_ts_ns = metadata.end_ts_ns,
        .row_count = metadata.count,
        .block_count = metadata.block_count,
        .column_names = columns,
        .content_id = digest,
        .file_hash = digest,
        .file_size = bytes.len,
    }});
}

fn buildTestRevisionSnapshot(
    alloc: std.mem.Allocator,
    data_dir: std.fs.Dir,
    store: *object_store.ObjectStore,
    catalog: *market_catalog.Catalog,
    manifest: *const market_manifest.Manifest,
) !cas.Snapshot {
    var market_descriptors = ManagedArrayList(cas.MarketSegmentDescriptor).init(alloc);
    errdefer {
        for (market_descriptors.items) |*descriptor| descriptor.deinit(alloc);
        market_descriptors.deinit();
    }
    for (manifest.list()) |entry| {
        const root_id = try market_segment.writeSegmentRootForFile(
            alloc,
            data_dir,
            store,
            entry.path,
            64,
        );
        try market_descriptors.append(try cloneTestCasDescriptor(
            alloc,
            entry,
            root_id,
        ));
    }

    const scalar_descriptors = try alloc.alloc(cas.SegmentDescriptor, 0);
    errdefer alloc.free(scalar_descriptors);
    const owned_market_descriptors = try market_descriptors.toOwnedSlice();
    errdefer {
        for (owned_market_descriptors) |*descriptor| descriptor.deinit(alloc);
        alloc.free(owned_market_descriptors);
    }
    var tag_snapshot = try cas.TagSnapshot.empty(alloc);
    errdefer tag_snapshot.deinit(alloc);
    var series_snapshot = try cas.SeriesCatalogSnapshot.empty(alloc);
    errdefer series_snapshot.deinit(alloc);
    var metric_snapshot = try cas.MetricCatalogSnapshot.empty(alloc);
    errdefer metric_snapshot.deinit(alloc);
    var market_snapshot = try catalog.snapshotClone();
    errdefer market_snapshot.deinit(alloc);
    var wal_index = try cas.WalIndex.empty(alloc);
    errdefer wal_index.deinit(alloc);
    var checkpoint = try cas.CheckpointState.empty(alloc);
    errdefer checkpoint.deinit(alloc);
    const parents = try alloc.alloc(object_store.ObjectId, 0);
    errdefer alloc.free(parents);
    const reason = try alloc.dupe(u8, "market-reader-test-snapshot");
    errdefer alloc.free(reason);
    const zero_id = object_store.ObjectId{ .hash = [_]u8{0} ** 32 };

    return .{
        .commit_id = zero_id,
        .root_id = zero_id,
        .commit = .{
            .format_version = 1,
            .root = zero_id,
            .parents = parents,
            .created_at_ms = 0,
            .reason = reason,
        },
        .segment_descriptors = scalar_descriptors,
        .market_segment_descriptors = owned_market_descriptors,
        .tag_snapshot = tag_snapshot,
        .series_catalog_snapshot = series_snapshot,
        .metric_catalog_snapshot = metric_snapshot,
        .market_catalog_snapshot = market_snapshot,
        .wal_index = wal_index,
        .checkpoint_state = checkpoint,
    };
}

fn cloneTestCasDescriptor(
    alloc: std.mem.Allocator,
    entry: market_manifest.MarketSegmentDescriptor,
    root_id: object_store.ObjectId,
) !cas.MarketSegmentDescriptor {
    const path = try alloc.dupe(u8, entry.path);
    errdefer alloc.free(path);
    const metric = try alloc.dupe(u8, entry.metric);
    errdefer alloc.free(metric);
    const labels = try alloc.dupe(u8, entry.canonical_labels);
    errdefer alloc.free(labels);
    const column_names = try alloc.alloc([]u8, entry.column_names.len);
    errdefer alloc.free(column_names);
    var initialized: usize = 0;
    errdefer for (column_names[0..initialized]) |name| alloc.free(name);
    for (entry.column_names, 0..) |name, idx| {
        column_names[idx] = try alloc.dupe(u8, name);
        initialized += 1;
    }
    return .{
        .path = path,
        .market_segment_root = root_id,
        .market_series_id = entry.market_series_id,
        .schema_digest = entry.schema_digest,
        .metric = metric,
        .canonical_labels = labels,
        .hour_bucket = entry.hour_bucket,
        .start_ts_ns = entry.start_ts_ns,
        .end_ts_ns = entry.end_ts_ns,
        .row_count = entry.row_count,
        .block_count = entry.block_count,
        .column_names = column_names,
        .content_id = entry.content_id,
        .file_hash = entry.file_hash,
        .file_size = entry.file_size,
    };
}

test "native reader projects and prunes segment blocks" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const columns = [_][]const u8{ "bid", "ask", "size" };
    var catalog = try buildNativeCatalog(alloc, "market.quote", &columns, &.{"symbol"});
    defer catalog.deinit();
    var series = try catalog.registerMarketSeries("market.quote", "{\"symbol\":\"AAPL\"}");
    defer series.deinit(alloc);

    var manifest = market_manifest.Manifest.init(alloc);
    defer manifest.deinit();

    const first_values = [_]f64{ 10, 11, 100 };
    const second_values = [_]f64{ 20, 21, 200 };
    const rows = [_]market_segment.MarketRowView{
        .{ .ts_ns = 10, .write_sequence = 1, .values = &first_values },
        .{ .ts_ns = 20, .write_sequence = 2, .values = &second_values },
    };
    try addSegmentToManifest(alloc, tmp.dir, &manifest, series, &columns, &rows);

    var reader = MarketReader.init(alloc, tmp.dir, &catalog, &manifest, null);
    var result = try reader.query(.{
        .metric = "market.quote",
        .label_filter_json = "{\"symbol\":\"AAPL\"}",
        .start_ts_ns = 15,
        .end_ts_ns = 25,
        .requested_columns = &.{"ask"},
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.rows.len);
    try std.testing.expectEqual(@as(i64, 20), result.rows[0].ts_ns);
    try std.testing.expectEqual(@as(u64, 2), result.rows[0].write_sequence);
    try std.testing.expectEqual(@as(usize, 1), result.rows[0].values.len);
    try std.testing.expectEqual(@as(u64, @bitCast(@as(f64, 21))), @as(u64, @bitCast(result.rows[0].values[0])));
    try std.testing.expectEqualStrings("ask", result.requested_columns[0]);
    try std.testing.expectEqual(@as(u64, 1), result.stats.series_scanned);
    try std.testing.expectEqual(@as(u64, 1), result.stats.blocks_scanned);
    try std.testing.expectEqual(@as(u64, 1), result.stats.columns_read);
    try std.testing.expect(result.stats.bytes_decoded > 0);
}

test "native reader accepts migration catalogs for native segments" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const column_names = [_][]const u8{ "price", "size" };
    var catalog = market_catalog.Catalog.initEmpty(alloc, .none);
    defer catalog.deinit();
    var schema = try catalog.registerSchema(.{
        .metric = "market.migration",
        .ordered_columns = &column_names,
        .required_labels = &.{"symbol"},
        .storage_mapping = .fanout_v1,
    });
    defer schema.deinit(alloc);
    var series = try catalog.registerMarketSeries(
        "market.migration",
        "{\"symbol\":\"AAPL\"}",
    );
    defer series.deinit(alloc);

    var native_identity = series;
    native_identity.schema_digest = nativeSchemaDigest(schema);
    var manifest = market_manifest.Manifest.init(alloc);
    defer manifest.deinit();
    const values = [_]f64{ 101.5, 7.0 };
    const rows = [_]market_segment.MarketRowView{
        .{ .ts_ns = 10, .write_sequence = 1, .values = &values },
    };
    try addSegmentToManifest(
        alloc,
        tmp.dir,
        &manifest,
        native_identity,
        &column_names,
        &rows,
    );

    var reader = MarketReader.init(alloc, tmp.dir, &catalog, &manifest, null);
    var result = try reader.query(.{
        .metric = "market.migration",
        .label_filter_json = "{\"symbol\":\"AAPL\"}",
        .start_ts_ns = 0,
        .end_ts_ns = 20,
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.rows.len);
    try std.testing.expectEqualSlices(f64, &values, result.rows[0].values);
}

test "native reader applies highest write sequence across segment and memtable" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const columns = [_][]const u8{ "price", "size" };
    var catalog = try buildNativeCatalog(alloc, "market.trade", &columns, &.{"symbol"});
    defer catalog.deinit();
    var series = try catalog.registerMarketSeries("market.trade", "{\"symbol\":\"AAPL\"}");
    defer series.deinit(alloc);

    var manifest = market_manifest.Manifest.init(alloc);
    defer manifest.deinit();

    const old_values = [_]f64{ 10, 1 };
    const rows = [_]market_segment.MarketRowView{
        .{ .ts_ns = 100, .write_sequence = 1, .values = &old_values },
    };
    try addSegmentToManifest(alloc, tmp.dir, &manifest, series, &columns, &rows);

    var memtable = market_memtable.MarketMemtable.init(alloc);
    defer memtable.deinit();
    const corrected_values = [_]f64{ 12, 3 };
    try memtable.appendBatch(&.{.{
        .market_series_id = series.series_id,
        .metric = series.metric,
        .canonical_labels = series.canonical_labels,
        .schema_digest = series.schema_digest,
        .ts_ns = 100,
        .write_sequence = 7,
        .values = &corrected_values,
    }});

    var reader = MarketReader.init(alloc, tmp.dir, &catalog, &manifest, &memtable);
    var result = try reader.query(.{
        .metric = "market.trade",
        .start_ts_ns = 0,
        .end_ts_ns = 200,
        .requested_columns = &.{ "price", "size" },
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.rows.len);
    try std.testing.expectEqual(@as(u64, 7), result.rows[0].write_sequence);
    try std.testing.expectEqual(@as(u64, @bitCast(@as(f64, 12))), @as(u64, @bitCast(result.rows[0].values[0])));
    try std.testing.expectEqual(@as(u64, @bitCast(@as(f64, 3))), @as(u64, @bitCast(result.rows[0].values[1])));
}

test "native reader detects equal sequence hidden-column conflicts under projection" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const columns = [_][]const u8{ "visible", "hidden" };
    var catalog = try buildNativeCatalog(alloc, "market.synthetic", &columns, &.{"symbol"});
    defer catalog.deinit();
    var series = try catalog.registerMarketSeries("market.synthetic", "{\"symbol\":\"AAPL\"}");
    defer series.deinit(alloc);

    var manifest = market_manifest.Manifest.init(alloc);
    defer manifest.deinit();

    const persisted_values = [_]f64{ 1, 100 };
    const rows = [_]market_segment.MarketRowView{
        .{ .ts_ns = 10, .write_sequence = 5, .values = &persisted_values },
    };
    try addSegmentToManifest(alloc, tmp.dir, &manifest, series, &columns, &rows);

    var memtable = market_memtable.MarketMemtable.init(alloc);
    defer memtable.deinit();
    const live_values = [_]f64{ 1, 200 };
    try memtable.appendBatch(&.{.{
        .market_series_id = series.series_id,
        .metric = series.metric,
        .canonical_labels = series.canonical_labels,
        .schema_digest = series.schema_digest,
        .ts_ns = 10,
        .write_sequence = 5,
        .values = &live_values,
    }});

    var reader = MarketReader.init(alloc, tmp.dir, &catalog, &manifest, &memtable);
    try std.testing.expectError(
        error.DuplicateWriteSequenceConflict,
        reader.query(.{
            .metric = "market.synthetic",
            .start_ts_ns = 0,
            .end_ts_ns = 20,
            .requested_columns = &.{"visible"},
        }),
    );
}

test "native reader matches multiple label series with subset filter" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const columns = [_][]const u8{"price"};
    var catalog = try buildNativeCatalog(alloc, "market.trade", &columns, &.{ "symbol", "venue" });
    defer catalog.deinit();
    var xnas = try catalog.registerMarketSeries("market.trade", "{\"symbol\":\"AAPL\",\"venue\":\"XNAS\"}");
    defer xnas.deinit(alloc);
    var bats = try catalog.registerMarketSeries("market.trade", "{\"symbol\":\"AAPL\",\"venue\":\"BATS\"}");
    defer bats.deinit(alloc);
    var msft = try catalog.registerMarketSeries("market.trade", "{\"symbol\":\"MSFT\",\"venue\":\"XNAS\"}");
    defer msft.deinit(alloc);

    var manifest = market_manifest.Manifest.init(alloc);
    defer manifest.deinit();

    const xnas_values = [_]f64{1};
    const bats_values = [_]f64{2};
    const msft_values = [_]f64{3};
    try addSegmentToManifest(alloc, tmp.dir, &manifest, xnas, &columns, &.{.{ .ts_ns = 1, .write_sequence = 1, .values = &xnas_values }});
    try addSegmentToManifest(alloc, tmp.dir, &manifest, bats, &columns, &.{.{ .ts_ns = 2, .write_sequence = 1, .values = &bats_values }});
    try addSegmentToManifest(alloc, tmp.dir, &manifest, msft, &columns, &.{.{ .ts_ns = 3, .write_sequence = 1, .values = &msft_values }});

    var reader = MarketReader.init(alloc, tmp.dir, &catalog, &manifest, null);
    var result = try reader.query(.{
        .metric = "market.trade",
        .label_filter_json = "{\"symbol\":\"AAPL\"}",
        .start_ts_ns = 0,
        .end_ts_ns = 10,
        .requested_columns = &.{"price"},
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.rows.len);
    try std.testing.expectEqualStrings("{\"symbol\":\"AAPL\",\"venue\":\"BATS\"}", result.rows[0].canonical_labels);
    try std.testing.expectEqualStrings("{\"symbol\":\"AAPL\",\"venue\":\"XNAS\"}", result.rows[1].canonical_labels);
}

test "native reader distinguishes empty result from unavailable native data" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const columns = [_][]const u8{"price"};
    var catalog = try buildNativeCatalog(alloc, "market.trade", &columns, &.{"symbol"});
    defer catalog.deinit();
    var series = try catalog.registerMarketSeries("market.trade", "{\"symbol\":\"AAPL\"}");
    defer series.deinit(alloc);

    var manifest = market_manifest.Manifest.init(alloc);
    defer manifest.deinit();

    var reader = MarketReader.init(alloc, tmp.dir, &catalog, &manifest, null);
    try std.testing.expectError(
        error.NativeMarketDataUnavailable,
        reader.query(.{
            .metric = "market.trade",
            .start_ts_ns = 0,
            .end_ts_ns = 10,
            .requested_columns = &.{"price"},
        }),
    );

    const values = [_]f64{1};
    try addSegmentToManifest(alloc, tmp.dir, &manifest, series, &columns, &.{.{ .ts_ns = 100, .write_sequence = 1, .values = &values }});
    var empty = try reader.query(.{
        .metric = "market.trade",
        .start_ts_ns = 0,
        .end_ts_ns = 10,
        .requested_columns = &.{"price"},
    });
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.rows.len);
}

test "native reader surfaces missing files and rejects revisions" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const columns = [_][]const u8{"price"};
    var catalog = try buildNativeCatalog(alloc, "market.trade", &columns, &.{"symbol"});
    defer catalog.deinit();
    var series = try catalog.registerMarketSeries("market.trade", "{\"symbol\":\"AAPL\"}");
    defer series.deinit(alloc);

    var manifest = market_manifest.Manifest.init(alloc);
    defer manifest.deinit();
    const digest = testDigest(1);
    try manifest.addBatch(tmp.dir, &.{.{
        .path = "market_segments/0/missing.mseg",
        .market_series_id = series.series_id,
        .schema_digest = series.schema_digest,
        .metric = series.metric,
        .canonical_labels = series.canonical_labels,
        .hour_bucket = 0,
        .start_ts_ns = 1,
        .end_ts_ns = 1,
        .row_count = 1,
        .block_count = 1,
        .column_names = &columns,
        .content_id = digest,
        .file_hash = digest,
        .file_size = 128,
    }});

    var reader = MarketReader.init(alloc, tmp.dir, &catalog, &manifest, null);
    try std.testing.expectError(
        error.NativeRevisionUnavailable,
        reader.query(.{
            .metric = "market.trade",
            .start_ts_ns = 0,
            .end_ts_ns = 10,
            .requested_columns = &.{"price"},
            .revision = .{ .value = "abc" },
        }),
    );
    try std.testing.expectError(
        error.NativeMarketDataUnavailable,
        reader.query(.{
            .metric = "market.trade",
            .start_ts_ns = 0,
            .end_ts_ns = 10,
            .requested_columns = &.{"price"},
        }),
    );
}

test "revision reader stays on one snapshot while live corrections and catalog grow" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(
        alloc,
        ".zig-cache/tmp/{s}/revision-reader",
        .{tmp.sub_path},
    );
    defer alloc.free(data_path);
    try std.fs.cwd().makePath(data_path);
    var data_dir = try std.fs.cwd().openDir(data_path, .{ .iterate = true });
    defer data_dir.close();

    const columns = [_][]const u8{ "bid", "ask", "bid_size", "ask_size" };
    var catalog = try market_catalog.Catalog.loadOrInit(alloc, data_dir, .none);
    defer catalog.deinit();
    var quote_schema = try catalog.registerSchema(.{
        .metric = "market.quote.revision",
        .ordered_columns = &columns,
        .required_labels = &.{"symbol"},
        .storage_mapping = .native_v1,
    });
    defer quote_schema.deinit(alloc);
    var aapl = try catalog.registerMarketSeries(
        "market.quote.revision",
        "{\"symbol\":\"AAPL\"}",
    );
    defer aapl.deinit(alloc);
    var msft = try catalog.registerMarketSeries(
        "market.quote.revision",
        "{\"symbol\":\"MSFT\"}",
    );
    defer msft.deinit(alloc);

    var manifest = market_manifest.Manifest.init(alloc);
    defer manifest.deinit();
    const aapl_old = [_]f64{ 100, 101, 10, 11 };
    const aapl_late = [_]f64{ 200, 201, 20, 21 };
    const msft_values = [_]f64{ 300, 301, 30, 31 };
    try addSegmentToManifest(
        alloc,
        data_dir,
        &manifest,
        aapl,
        &columns,
        &.{.{ .ts_ns = 100, .write_sequence = 1, .values = &aapl_old }},
    );
    try addSegmentToManifest(
        alloc,
        data_dir,
        &manifest,
        aapl,
        &columns,
        &.{.{ .ts_ns = 10_000, .write_sequence = 2, .values = &aapl_late }},
    );
    try addSegmentToManifest(
        alloc,
        data_dir,
        &manifest,
        msft,
        &columns,
        &.{.{ .ts_ns = 100, .write_sequence = 1, .values = &msft_values }},
    );

    var store = try object_store.ObjectStore.init(alloc, data_path, .none);
    defer store.deinit();
    const snapshot = try buildTestRevisionSnapshot(
        alloc,
        data_dir,
        &store,
        &catalog,
        &manifest,
    );
    var snapshot_index = cas.SnapshotIndex.init(alloc, &store, snapshot);
    defer snapshot_index.deinit();

    var live_memtable = market_memtable.MarketMemtable.init(alloc);
    defer live_memtable.deinit();
    const corrected = [_]f64{ 110, 111, 12, 13 };
    try live_memtable.appendBatch(&.{.{
        .market_series_id = aapl.series_id,
        .metric = aapl.metric,
        .canonical_labels = aapl.canonical_labels,
        .schema_digest = aapl.schema_digest,
        .ts_ns = 100,
        .write_sequence = 9,
        .values = &corrected,
    }});

    // This identity exists only in the live catalog after the CAS commit.
    var goog = try catalog.registerMarketSeries(
        "market.quote.revision",
        "{\"symbol\":\"GOOG\"}",
    );
    defer goog.deinit(alloc);
    const goog_values = [_]f64{ 400, 401, 40, 41 };
    try live_memtable.appendBatch(&.{.{
        .market_series_id = goog.series_id,
        .metric = goog.metric,
        .canonical_labels = goog.canonical_labels,
        .schema_digest = goog.schema_digest,
        .ts_ns = 100,
        .write_sequence = 10,
        .values = &goog_values,
    }});

    var local_reader = MarketReader.init(
        alloc,
        data_dir,
        &catalog,
        &manifest,
        &live_memtable,
    );
    var local = try local_reader.query(.{
        .metric = "market.quote.revision",
        .label_filter_json = "{\"symbol\":\"AAPL\"}",
        .start_ts_ns = 50,
        .end_ts_ns = 150,
        .requested_columns = &.{ "ask", "ask_size" },
    });
    defer local.deinit();
    try std.testing.expectEqual(@as(u64, 9), local.rows[0].write_sequence);
    try std.testing.expectEqual(
        @as(u64, @bitCast(@as(f64, 111))),
        @as(u64, @bitCast(local.rows[0].values[0])),
    );

    var revision_reader = MarketReader.initRevision(alloc, &snapshot_index);
    var historical = try revision_reader.query(.{
        .metric = "market.quote.revision",
        .label_filter_json = "{\"symbol\":\"AAPL\"}",
        .start_ts_ns = 50,
        .end_ts_ns = 150,
        .requested_columns = &.{ "ask", "ask_size" },
        .revision = .{ .value = "heads/main" },
    });
    defer historical.deinit();

    try std.testing.expectEqual(@as(usize, 1), historical.rows.len);
    try std.testing.expectEqual(@as(u64, 1), historical.rows[0].write_sequence);
    try std.testing.expectEqual(
        @as(u64, @bitCast(@as(f64, 101))),
        @as(u64, @bitCast(historical.rows[0].values[0])),
    );
    try std.testing.expectEqual(
        @as(u64, @bitCast(@as(f64, 11))),
        @as(u64, @bitCast(historical.rows[0].values[1])),
    );
    try std.testing.expectEqual(@as(u64, 1), historical.stats.series_scanned);
    try std.testing.expectEqual(@as(u64, 1), historical.stats.blocks_scanned);
    try std.testing.expectEqual(@as(u64, 2), historical.stats.columns_read);
    try std.testing.expect(historical.stats.bytes_decoded > 0);

    var snapshot_all = try revision_reader.query(.{
        .metric = "market.quote.revision",
        .start_ts_ns = 50,
        .end_ts_ns = 150,
        .requested_columns = &.{"bid"},
    });
    defer snapshot_all.deinit();
    try std.testing.expectEqual(@as(usize, 2), snapshot_all.rows.len);
    for (snapshot_all.rows) |row| {
        try std.testing.expect(!std.mem.eql(
            u8,
            row.canonical_labels,
            "{\"symbol\":\"GOOG\"}",
        ));
    }
}

test "revision reader reports stable missing and corrupt root errors" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(
        alloc,
        ".zig-cache/tmp/{s}/revision-reader-errors",
        .{tmp.sub_path},
    );
    defer alloc.free(data_path);
    try std.fs.cwd().makePath(data_path);
    var data_dir = try std.fs.cwd().openDir(data_path, .{ .iterate = true });
    defer data_dir.close();

    const columns = [_][]const u8{"price"};
    var catalog = try market_catalog.Catalog.loadOrInit(alloc, data_dir, .none);
    defer catalog.deinit();
    var trade_schema = try catalog.registerSchema(.{
        .metric = "market.trade.revision-errors",
        .ordered_columns = &columns,
        .required_labels = &.{"symbol"},
        .storage_mapping = .native_v1,
    });
    defer trade_schema.deinit(alloc);
    var series = try catalog.registerMarketSeries(
        "market.trade.revision-errors",
        "{\"symbol\":\"AAPL\"}",
    );
    defer series.deinit(alloc);
    var manifest = market_manifest.Manifest.init(alloc);
    defer manifest.deinit();
    const values = [_]f64{42};
    try addSegmentToManifest(
        alloc,
        data_dir,
        &manifest,
        series,
        &columns,
        &.{.{ .ts_ns = 10, .write_sequence = 1, .values = &values }},
    );

    var store = try object_store.ObjectStore.init(alloc, data_path, .none);
    defer store.deinit();
    const snapshot = try buildTestRevisionSnapshot(
        alloc,
        data_dir,
        &store,
        &catalog,
        &manifest,
    );
    var snapshot_index = cas.SnapshotIndex.init(alloc, &store, snapshot);
    defer snapshot_index.deinit();
    var reader = MarketReader.initRevision(alloc, &snapshot_index);

    const valid_root = snapshot_index.snapshot.market_segment_descriptors[0]
        .market_segment_root.?;
    snapshot_index.snapshot.market_segment_descriptors[0].market_segment_root = null;
    try std.testing.expectError(
        error.NativeMarketDataUnavailable,
        reader.query(.{
            .metric = "market.trade.revision-errors",
            .start_ts_ns = 0,
            .end_ts_ns = 20,
            .requested_columns = &.{"price"},
        }),
    );

    const invalid_root = try store.put(.blob, "not-a-market-segment-root");
    snapshot_index.snapshot.market_segment_descriptors[0].market_segment_root =
        invalid_root;
    try std.testing.expectError(
        error.NativeMarketDataCorrupt,
        reader.query(.{
            .metric = "market.trade.revision-errors",
            .start_ts_ns = 0,
            .end_ts_ns = 20,
            .requested_columns = &.{"price"},
        }),
    );

    snapshot_index.snapshot.market_segment_descriptors[0].market_segment_root =
        valid_root;
    try store.delete(valid_root);
    try std.testing.expectError(
        error.NativeMarketDataUnavailable,
        reader.query(.{
            .metric = "market.trade.revision-errors",
            .start_ts_ns = 0,
            .end_ts_ns = 20,
            .requested_columns = &.{"price"},
        }),
    );
}

test "revision reader rejects equal sequence conflicts across CAS roots" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(
        alloc,
        ".zig-cache/tmp/{s}/revision-reader-conflict",
        .{tmp.sub_path},
    );
    defer alloc.free(data_path);
    try std.fs.cwd().makePath(data_path);
    var data_dir = try std.fs.cwd().openDir(data_path, .{ .iterate = true });
    defer data_dir.close();

    const columns = [_][]const u8{ "visible", "hidden" };
    var catalog = try market_catalog.Catalog.loadOrInit(alloc, data_dir, .none);
    defer catalog.deinit();
    var conflict_schema = try catalog.registerSchema(.{
        .metric = "market.synthetic.revision-conflict",
        .ordered_columns = &columns,
        .required_labels = &.{"symbol"},
        .storage_mapping = .native_v1,
    });
    defer conflict_schema.deinit(alloc);
    var series = try catalog.registerMarketSeries(
        "market.synthetic.revision-conflict",
        "{\"symbol\":\"AAPL\"}",
    );
    defer series.deinit(alloc);
    var manifest = market_manifest.Manifest.init(alloc);
    defer manifest.deinit();

    const first = [_]f64{ 1, 100 };
    const second = [_]f64{ 1, 200 };
    try addSegmentToManifest(
        alloc,
        data_dir,
        &manifest,
        series,
        &columns,
        &.{.{ .ts_ns = 10, .write_sequence = 7, .values = &first }},
    );
    try addSegmentToManifest(
        alloc,
        data_dir,
        &manifest,
        series,
        &columns,
        &.{.{ .ts_ns = 10, .write_sequence = 7, .values = &second }},
    );

    var store = try object_store.ObjectStore.init(alloc, data_path, .none);
    defer store.deinit();
    const snapshot = try buildTestRevisionSnapshot(
        alloc,
        data_dir,
        &store,
        &catalog,
        &manifest,
    );
    var snapshot_index = cas.SnapshotIndex.init(alloc, &store, snapshot);
    defer snapshot_index.deinit();
    var reader = MarketReader.initRevision(alloc, &snapshot_index);

    try std.testing.expectError(
        error.DuplicateWriteSequenceConflict,
        reader.query(.{
            .metric = "market.synthetic.revision-conflict",
            .start_ts_ns = 0,
            .end_ts_ns = 20,
            .requested_columns = &.{"visible"},
            .revision = .{ .value = "checkpoint" },
        }),
    );
}
