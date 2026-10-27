const std = @import("std");
pub const market_identity = @import("market_identity.zig");

const ManagedArrayList = std.array_list.Managed;

pub const MarketSeriesId = market_identity.MarketSeriesId;
pub const SchemaDigest = market_identity.SchemaDigest;
pub const seriesId = market_identity.seriesId;
pub const marketSeriesId = seriesId;
pub const seriesIdFromLabels = market_identity.seriesIdFromLabels;
pub const canonicalizeLabels = market_identity.canonicalizeLabels;
pub const schemaDigest = market_identity.schemaDigest;
pub const validateValueShape = market_identity.validateValueShape;

pub const MarketSeriesIdentityView = struct {
    series_id: MarketSeriesId,
    metric: []const u8,
    canonical_labels: []const u8,
};

/// A logical native-market row. All slices are borrowed for the duration of
/// `appendBatch`; the memtable copies values and owns series identity strings.
pub const MarketRowInput = struct {
    market_series_id: MarketSeriesId,
    metric: []const u8,
    canonical_labels: []const u8,
    schema_digest: SchemaDigest,
    ts_ns: i64,
    write_sequence: u64,
    values: []const f64,
};

/// Inclusive nanosecond range used by memtable reads.
pub const TimeRange = struct {
    start_ns: i64,
    end_ns: i64,
};

pub const SeriesState = struct {
    identity: MarketSeriesIdentityView,
    schema_digest: SchemaDigest,
    column_count: usize,
    row_count: usize,
    /// Exact live timestamp, sequence, and value payload.
    resident_bytes: usize,
    /// Requested dynamic allocation bytes, excluding allocator rounding.
    allocated_bytes: usize,
    sorted: bool,
    highest_write_sequence: ?u64,
};

pub const ProjectedRows = struct {
    allocator: std.mem.Allocator,
    timestamps: []i64,
    write_sequences: []u64,
    /// One contiguous value vector per requested projection, in request order.
    columns: [][]f64,

    pub fn deinit(self: *ProjectedRows) void {
        self.allocator.free(self.timestamps);
        self.allocator.free(self.write_sequences);
        for (self.columns) |column| self.allocator.free(column);
        self.allocator.free(self.columns);
        self.* = undefined;
    }
};

pub const HourGroup = struct {
    identity: MarketSeriesIdentityView,
    schema_digest: SchemaDigest,
    /// Signed UTC-hour index: floor(ts_ns / nanoseconds_per_hour).
    hour_bucket: i64,
    rows: ProjectedRows,
};

/// The identity strings in each group borrow from the source memtable. Row
/// arrays own their memory and are released by `deinit`.
pub const HourExtraction = struct {
    allocator: std.mem.Allocator,
    groups: []HourGroup,

    pub fn deinit(self: *HourExtraction) void {
        for (self.groups) |*group| group.rows.deinit();
        self.allocator.free(self.groups);
        self.* = undefined;
    }
};

const SeriesBuffer = struct {
    allocator: std.mem.Allocator,
    metric: []u8,
    canonical_labels: []u8,
    schema_digest: SchemaDigest,
    timestamps: ManagedArrayList(i64),
    write_sequences: ManagedArrayList(u64),
    columns: []ManagedArrayList(f64),
    resident_bytes: usize = 0,
    sorted: bool = true,
    last_appended_ts: ?i64 = null,
    highest_write_sequence: ?u64 = null,

    fn init(
        allocator: std.mem.Allocator,
        metric: []const u8,
        canonical_labels: []const u8,
        schema_digest: SchemaDigest,
        column_count: usize,
    ) !SeriesBuffer {
        const owned_metric = try allocator.dupe(u8, metric);
        errdefer allocator.free(owned_metric);
        const owned_labels = try allocator.dupe(u8, canonical_labels);
        errdefer allocator.free(owned_labels);

        const columns = try allocator.alloc(ManagedArrayList(f64), column_count);
        for (columns) |*column| column.* = ManagedArrayList(f64).init(allocator);

        return .{
            .allocator = allocator,
            .metric = owned_metric,
            .canonical_labels = owned_labels,
            .schema_digest = schema_digest,
            .timestamps = ManagedArrayList(i64).init(allocator),
            .write_sequences = ManagedArrayList(u64).init(allocator),
            .columns = columns,
        };
    }

    fn deinit(self: *SeriesBuffer) void {
        self.allocator.free(self.metric);
        self.allocator.free(self.canonical_labels);
        self.timestamps.deinit();
        self.write_sequences.deinit();
        for (self.columns) |*column| column.deinit();
        self.allocator.free(self.columns);
        self.* = undefined;
    }

    fn ensureUnusedCapacity(self: *SeriesBuffer, additional_rows: usize) !void {
        try self.timestamps.ensureUnusedCapacity(additional_rows);
        try self.write_sequences.ensureUnusedCapacity(additional_rows);
        for (self.columns) |*column| try column.ensureUnusedCapacity(additional_rows);
    }

    fn appendValidated(self: *SeriesBuffer, row: MarketRowInput, row_bytes: usize) void {
        if (self.findTimestamp(row.ts_ns)) |idx| {
            if (row.write_sequence < self.write_sequences.items[idx]) return;
            if (row.write_sequence == self.write_sequences.items[idx]) {
                std.debug.assert(bufferRowBitsEqual(self, idx, row.values));
                return;
            }
            self.write_sequences.items[idx] = row.write_sequence;
            for (self.columns, row.values) |*column, value| column.items[idx] = value;
            self.noteHighestWriteSequence(row.write_sequence);
            return;
        }

        if (self.last_appended_ts) |last_ts| {
            if (row.ts_ns < last_ts) self.sorted = false;
        }
        self.timestamps.appendAssumeCapacity(row.ts_ns);
        self.write_sequences.appendAssumeCapacity(row.write_sequence);
        for (self.columns, row.values) |*column, value| column.appendAssumeCapacity(value);
        self.last_appended_ts = row.ts_ns;
        self.noteHighestWriteSequence(row.write_sequence);
        self.resident_bytes += row_bytes;
    }

    fn findTimestamp(self: *const SeriesBuffer, ts_ns: i64) ?usize {
        for (self.timestamps.items, 0..) |candidate, idx| {
            if (candidate == ts_ns) return idx;
        }
        return null;
    }

    fn noteHighestWriteSequence(self: *SeriesBuffer, sequence: u64) void {
        if (self.highest_write_sequence == null or sequence > self.highest_write_sequence.?) {
            self.highest_write_sequence = sequence;
        }
    }

    fn clearRetainingCapacity(self: *SeriesBuffer) void {
        self.timestamps.clearRetainingCapacity();
        self.write_sequences.clearRetainingCapacity();
        for (self.columns) |*column| column.clearRetainingCapacity();
        self.resident_bytes = 0;
        self.sorted = true;
        self.last_appended_ts = null;
        self.highest_write_sequence = null;
    }

    fn allocatedBytes(self: *const SeriesBuffer) usize {
        var total = saturatingAdd(self.metric.len, self.canonical_labels.len);
        total = saturatingAdd(total, saturatingMul(self.columns.len, @sizeOf(ManagedArrayList(f64))));
        total = saturatingAdd(total, saturatingMul(self.timestamps.capacity, @sizeOf(i64)));
        total = saturatingAdd(total, saturatingMul(self.write_sequences.capacity, @sizeOf(u64)));
        for (self.columns) |column| {
            total = saturatingAdd(total, saturatingMul(column.capacity, @sizeOf(f64)));
        }
        return total;
    }

    fn identityMatches(self: *const SeriesBuffer, identity: MarketSeriesIdentityView) bool {
        return std.mem.eql(u8, self.metric, identity.metric) and
            std.mem.eql(u8, self.canonical_labels, identity.canonical_labels);
    }
};

const BatchSeries = struct {
    metric: []const u8,
    canonical_labels: []const u8,
    schema_digest: SchemaDigest,
    column_count: usize,
    row_count: usize = 0,
};

const PreparedSeries = struct {
    series_id: MarketSeriesId,
    buffer: ?SeriesBuffer,
};

const TimestampKey = struct {
    market_series_id: MarketSeriesId,
    ts_ns: i64,
};

const EffectiveValues = union(enum) {
    existing: struct {
        buffer: *const SeriesBuffer,
        row_idx: usize,
    },
    batch: []const f64,
};

const EffectiveRow = struct {
    write_sequence: u64,
    values: EffectiveValues,
};

pub const MarketMemtable = struct {
    allocator: std.mem.Allocator,
    series: std.AutoHashMap(MarketSeriesId, SeriesBuffer),
    resident_bytes: usize = 0,

    pub fn init(allocator: std.mem.Allocator) MarketMemtable {
        return .{
            .allocator = allocator,
            .series = std.AutoHashMap(MarketSeriesId, SeriesBuffer).init(allocator),
        };
    }

    pub fn deinit(self: *MarketMemtable) void {
        var values = self.series.valueIterator();
        while (values.next()) |buffer| buffer.deinit();
        self.series.deinit();
        self.* = undefined;
    }

    /// Exact live row payload retained for flush and ingest metrics.
    pub fn livePayloadBytes(self: *const MarketMemtable) usize {
        return self.resident_bytes;
    }

    /// Backward-compatible name for the live-payload metric.
    pub fn residentBytes(self: *const MarketMemtable) usize {
        return self.livePayloadBytes();
    }

    /// Estimated requested allocation bytes suitable for admission control.
    ///
    /// This includes retained timestamp, sequence, value, column-vector, and
    /// identity allocations plus visible hash-map key/value slot capacity.
    /// `std.AutoHashMap` does not expose its control-byte allocation and the
    /// allocator may round requests upward, so those small overheads remain an
    /// unavoidable approximation.
    pub fn allocatedBytes(self: *const MarketMemtable) usize {
        var total = saturatingMul(
            self.series.capacity(),
            @sizeOf(MarketSeriesId) + @sizeOf(SeriesBuffer),
        );
        var values = self.series.valueIterator();
        while (values.next()) |buffer| {
            total = saturatingAdd(total, buffer.allocatedBytes());
        }
        return total;
    }

    pub fn seriesCount(self: *const MarketMemtable) usize {
        return self.series.count();
    }

    pub fn seriesState(self: *const MarketMemtable, series_id: MarketSeriesId) ?SeriesState {
        const buffer = self.series.getPtr(series_id) orelse return null;
        return .{
            .identity = .{
                .series_id = series_id,
                .metric = buffer.metric,
                .canonical_labels = buffer.canonical_labels,
            },
            .schema_digest = buffer.schema_digest,
            .column_count = buffer.columns.len,
            .row_count = buffer.timestamps.items.len,
            .resident_bytes = buffer.resident_bytes,
            .allocated_bytes = buffer.allocatedBytes(),
            .sorted = buffer.sorted,
            .highest_write_sequence = buffer.highest_write_sequence,
        };
    }

    /// Appends a logical batch atomically with respect to identity and schema
    /// validation. Duplicate timestamps retain the row with the greatest write
    /// sequence. Equal sequences are idempotent only when every value bit
    /// matches; conflicting bits reject the entire batch.
    pub fn appendBatch(self: *MarketMemtable, rows: []const MarketRowInput) !void {
        if (rows.len == 0) return;

        var batch_series = std.AutoHashMap(MarketSeriesId, BatchSeries).init(self.allocator);
        defer batch_series.deinit();
        try batch_series.ensureUnusedCapacity(@intCast(rows.len));

        var additional_upper_bytes: usize = 0;
        for (rows) |row| {
            try validateRowShape(row);
            const row_bytes = try rowResidentBytes(row.values.len);
            additional_upper_bytes = try checkedAdd(additional_upper_bytes, row_bytes);

            if (self.series.getPtr(row.market_series_id)) |existing| {
                try validateBinding(existing, row);
            }

            const gop = batch_series.getOrPutAssumeCapacity(row.market_series_id);
            if (!gop.found_existing) {
                if (!self.series.contains(row.market_series_id)) {
                    try validateFirstBinding(self.allocator, row);
                }
                gop.value_ptr.* = .{
                    .metric = row.metric,
                    .canonical_labels = row.canonical_labels,
                    .schema_digest = row.schema_digest,
                    .column_count = row.values.len,
                    .row_count = 1,
                };
            } else {
                try validateBatchBinding(gop.value_ptr.*, row);
                gop.value_ptr.row_count = try checkedAdd(gop.value_ptr.row_count, 1);
            }
        }
        _ = try checkedAdd(self.resident_bytes, additional_upper_bytes);
        try self.prevalidateCorrections(rows);

        var prepared = ManagedArrayList(PreparedSeries).init(self.allocator);
        defer {
            for (prepared.items) |*entry| {
                if (entry.buffer) |*buffer| buffer.deinit();
            }
            prepared.deinit();
        }

        var new_series_count: usize = 0;
        var preflight_it = batch_series.iterator();
        while (preflight_it.next()) |entry| {
            if (!self.series.contains(entry.key_ptr.*)) new_series_count += 1;
        }
        try prepared.ensureTotalCapacity(new_series_count);
        try self.series.ensureUnusedCapacity(@intCast(new_series_count));

        preflight_it = batch_series.iterator();
        while (preflight_it.next()) |entry| {
            const series_id = entry.key_ptr.*;
            const pending = entry.value_ptr.*;
            if (self.series.getPtr(series_id)) |buffer| {
                try buffer.ensureUnusedCapacity(pending.row_count);
                continue;
            }

            var buffer = try SeriesBuffer.init(
                self.allocator,
                pending.metric,
                pending.canonical_labels,
                pending.schema_digest,
                pending.column_count,
            );
            errdefer buffer.deinit();
            try buffer.ensureUnusedCapacity(pending.row_count);
            prepared.appendAssumeCapacity(.{
                .series_id = series_id,
                .buffer = buffer,
            });
        }

        for (prepared.items) |*entry| {
            self.series.putAssumeCapacityNoClobber(entry.series_id, entry.buffer.?);
            entry.buffer = null;
        }

        for (rows) |row| {
            const row_bytes = rowResidentBytes(row.values.len) catch unreachable;
            const buffer = self.series.getPtr(row.market_series_id).?;
            const before = buffer.resident_bytes;
            buffer.appendValidated(row, row_bytes);
            self.resident_bytes += buffer.resident_bytes - before;
        }
    }

    fn prevalidateCorrections(self: *const MarketMemtable, rows: []const MarketRowInput) !void {
        var effective_rows = std.AutoHashMap(TimestampKey, EffectiveRow).init(self.allocator);
        defer effective_rows.deinit();
        try effective_rows.ensureUnusedCapacity(@intCast(rows.len));

        for (rows) |row| {
            const key = TimestampKey{
                .market_series_id = row.market_series_id,
                .ts_ns = row.ts_ns,
            };
            const gop = effective_rows.getOrPutAssumeCapacity(key);
            if (!gop.found_existing) {
                if (self.series.getPtr(row.market_series_id)) |buffer| {
                    if (buffer.findTimestamp(row.ts_ns)) |row_idx| {
                        gop.value_ptr.* = .{
                            .write_sequence = buffer.write_sequences.items[row_idx],
                            .values = .{ .existing = .{
                                .buffer = buffer,
                                .row_idx = row_idx,
                            } },
                        };
                        try considerCorrection(gop.value_ptr, row);
                        continue;
                    }
                }
                gop.value_ptr.* = .{
                    .write_sequence = row.write_sequence,
                    .values = .{ .batch = row.values },
                };
                continue;
            }
            try considerCorrection(gop.value_ptr, row);
        }
    }

    pub fn queryProjected(
        self: *const MarketMemtable,
        allocator: std.mem.Allocator,
        series_id: MarketSeriesId,
        time_range: TimeRange,
        projection: []const usize,
    ) !ProjectedRows {
        if (time_range.end_ns < time_range.start_ns) return error.InvalidTimeRange;
        const buffer = self.series.getPtr(series_id) orelse return error.MarketSeriesNotFound;
        for (projection) |column_idx| {
            if (column_idx >= buffer.columns.len) return error.InvalidProjection;
        }
        return buildProjectedRows(allocator, buffer, time_range, projection, null);
    }

    /// Returns deterministic `(series_id, hour)` groups. Groups and rows are
    /// sorted ascending, and each group includes every schema column.
    pub fn extractByHour(self: *const MarketMemtable, allocator: std.mem.Allocator) !HourExtraction {
        const Descriptor = struct {
            series_id: MarketSeriesId,
            hour_bucket: i64,
            buffer: *const SeriesBuffer,

            fn lessThan(_: void, lhs: @This(), rhs: @This()) bool {
                if (lhs.series_id != rhs.series_id) return lhs.series_id < rhs.series_id;
                return lhs.hour_bucket < rhs.hour_bucket;
            }
        };

        var descriptors = ManagedArrayList(Descriptor).init(allocator);
        defer descriptors.deinit();

        var series_it = self.series.iterator();
        while (series_it.next()) |entry| {
            const buffer = entry.value_ptr;
            var seen_hours = std.AutoHashMap(i64, void).init(allocator);
            defer seen_hours.deinit();
            try seen_hours.ensureUnusedCapacity(@intCast(buffer.timestamps.items.len));

            for (buffer.timestamps.items) |ts_ns| {
                const hour = hourBucket(ts_ns);
                const gop = seen_hours.getOrPutAssumeCapacity(hour);
                if (gop.found_existing) continue;
                gop.value_ptr.* = {};
                try descriptors.append(.{
                    .series_id = entry.key_ptr.*,
                    .hour_bucket = hour,
                    .buffer = buffer,
                });
            }
        }
        std.sort.block(Descriptor, descriptors.items, {}, Descriptor.lessThan);

        const groups = try allocator.alloc(HourGroup, descriptors.items.len);
        errdefer allocator.free(groups);
        var initialized: usize = 0;
        errdefer {
            for (groups[0..initialized]) |*group| group.rows.deinit();
        }

        for (descriptors.items, 0..) |descriptor, idx| {
            groups[idx] = .{
                .identity = .{
                    .series_id = descriptor.series_id,
                    .metric = descriptor.buffer.metric,
                    .canonical_labels = descriptor.buffer.canonical_labels,
                },
                .schema_digest = descriptor.buffer.schema_digest,
                .hour_bucket = descriptor.hour_bucket,
                .rows = try buildProjectedRows(
                    allocator,
                    descriptor.buffer,
                    .{ .start_ns = std.math.minInt(i64), .end_ns = std.math.maxInt(i64) },
                    null,
                    descriptor.hour_bucket,
                ),
            };
            initialized += 1;
        }

        return .{
            .allocator = allocator,
            .groups = groups,
        };
    }

    pub fn clearRetainingCapacity(self: *MarketMemtable) void {
        var values = self.series.valueIterator();
        while (values.next()) |buffer| buffer.clearRetainingCapacity();
        self.resident_bytes = 0;
    }
};

/// Exact live row payload used for memtable backpressure accounting.
pub fn rowResidentBytes(column_count: usize) !usize {
    const value_bytes = std.math.mul(usize, column_count, @sizeOf(f64)) catch
        return error.ResidentByteOverflow;
    return checkedAdd(@sizeOf(i64) + @sizeOf(u64), value_bytes);
}

pub fn hourBucket(ts_ns: i64) i64 {
    const hour_ns: i64 = 3600 * std.time.ns_per_s;
    return @divFloor(ts_ns, hour_ns);
}

fn validateRowShape(row: MarketRowInput) !void {
    if (row.metric.len == 0) return error.InvalidMarketSeriesIdentity;
    try market_identity.validateValueShape(row.values.len, row.values.len);
}

fn validateFirstBinding(allocator: std.mem.Allocator, row: MarketRowInput) !void {
    const canonical_labels = try market_identity.canonicalizeLabels(allocator, row.canonical_labels);
    defer allocator.free(canonical_labels);
    if (!std.mem.eql(u8, canonical_labels, row.canonical_labels)) {
        return error.NonCanonicalMarketLabels;
    }
    if (market_identity.seriesId(row.metric, canonical_labels) != row.market_series_id) {
        return error.MarketSeriesIdentityMismatch;
    }
}

fn validateBinding(buffer: *const SeriesBuffer, row: MarketRowInput) !void {
    if (!buffer.identityMatches(.{
        .series_id = row.market_series_id,
        .metric = row.metric,
        .canonical_labels = row.canonical_labels,
    })) return error.MarketSeriesConflict;
    if (!std.mem.eql(u8, buffer.schema_digest[0..], row.schema_digest[0..])) {
        return error.MarketSchemaConflict;
    }
    try market_identity.validateValueShape(buffer.columns.len, row.values.len);
}

fn validateBatchBinding(binding: BatchSeries, row: MarketRowInput) !void {
    if (!std.mem.eql(u8, binding.metric, row.metric) or
        !std.mem.eql(u8, binding.canonical_labels, row.canonical_labels))
    {
        return error.MarketSeriesConflict;
    }
    if (!std.mem.eql(u8, binding.schema_digest[0..], row.schema_digest[0..])) {
        return error.MarketSchemaConflict;
    }
    try market_identity.validateValueShape(binding.column_count, row.values.len);
}

fn considerCorrection(effective: *EffectiveRow, row: MarketRowInput) !void {
    if (row.write_sequence < effective.write_sequence) return;
    if (row.write_sequence == effective.write_sequence) {
        if (!effectiveRowBitsEqual(effective.values, row.values)) {
            return error.DuplicateWriteSequenceConflict;
        }
        return;
    }
    effective.* = .{
        .write_sequence = row.write_sequence,
        .values = .{ .batch = row.values },
    };
}

fn effectiveRowBitsEqual(effective: EffectiveValues, candidate: []const f64) bool {
    return switch (effective) {
        .existing => |existing| bufferRowBitsEqual(existing.buffer, existing.row_idx, candidate),
        .batch => |values| f64SlicesBitEqual(values, candidate),
    };
}

fn bufferRowBitsEqual(buffer: *const SeriesBuffer, row_idx: usize, candidate: []const f64) bool {
    if (buffer.columns.len != candidate.len) return false;
    for (buffer.columns, candidate) |column, value| {
        if (@as(u64, @bitCast(column.items[row_idx])) != @as(u64, @bitCast(value))) return false;
    }
    return true;
}

fn f64SlicesBitEqual(lhs: []const f64, rhs: []const f64) bool {
    if (lhs.len != rhs.len) return false;
    for (lhs, rhs) |left, right| {
        if (@as(u64, @bitCast(left)) != @as(u64, @bitCast(right))) return false;
    }
    return true;
}

fn checkedAdd(lhs: usize, rhs: usize) !usize {
    return std.math.add(usize, lhs, rhs) catch error.ResidentByteOverflow;
}

fn saturatingAdd(lhs: usize, rhs: usize) usize {
    return std.math.add(usize, lhs, rhs) catch std.math.maxInt(usize);
}

fn saturatingMul(lhs: usize, rhs: usize) usize {
    return std.math.mul(usize, lhs, rhs) catch std.math.maxInt(usize);
}

fn buildProjectedRows(
    allocator: std.mem.Allocator,
    buffer: *const SeriesBuffer,
    time_range: TimeRange,
    projection: ?[]const usize,
    required_hour: ?i64,
) !ProjectedRows {
    var indexes = ManagedArrayList(usize).init(allocator);
    defer indexes.deinit();
    try indexes.ensureTotalCapacity(buffer.timestamps.items.len);

    for (buffer.timestamps.items, 0..) |ts_ns, idx| {
        if (ts_ns < time_range.start_ns or ts_ns > time_range.end_ns) continue;
        if (required_hour) |hour| {
            if (hourBucket(ts_ns) != hour) continue;
        }
        indexes.appendAssumeCapacity(idx);
    }

    const SortContext = struct {
        buffer: *const SeriesBuffer,

        fn lessThan(ctx: @This(), lhs_idx: usize, rhs_idx: usize) bool {
            const lhs_ts = ctx.buffer.timestamps.items[lhs_idx];
            const rhs_ts = ctx.buffer.timestamps.items[rhs_idx];
            if (lhs_ts != rhs_ts) return lhs_ts < rhs_ts;
            const lhs_sequence = ctx.buffer.write_sequences.items[lhs_idx];
            const rhs_sequence = ctx.buffer.write_sequences.items[rhs_idx];
            if (lhs_sequence != rhs_sequence) return lhs_sequence < rhs_sequence;
            return lhs_idx < rhs_idx;
        }
    };
    std.sort.block(usize, indexes.items, SortContext{ .buffer = buffer }, SortContext.lessThan);

    const timestamps = try allocator.alloc(i64, indexes.items.len);
    errdefer allocator.free(timestamps);
    const write_sequences = try allocator.alloc(u64, indexes.items.len);
    errdefer allocator.free(write_sequences);

    const output_column_count = if (projection) |indices| indices.len else buffer.columns.len;
    const columns = try allocator.alloc([]f64, output_column_count);
    errdefer allocator.free(columns);
    var initialized_columns: usize = 0;
    errdefer {
        for (columns[0..initialized_columns]) |column| allocator.free(column);
    }
    for (columns) |*column| {
        column.* = try allocator.alloc(f64, indexes.items.len);
        initialized_columns += 1;
    }

    for (indexes.items, 0..) |source_idx, output_idx| {
        timestamps[output_idx] = buffer.timestamps.items[source_idx];
        write_sequences[output_idx] = buffer.write_sequences.items[source_idx];
        for (columns, 0..) |column, projected_idx| {
            const source_column = if (projection) |indices| indices[projected_idx] else projected_idx;
            column[output_idx] = buffer.columns[source_column].items[source_idx];
        }
    }

    return .{
        .allocator = allocator,
        .timestamps = timestamps,
        .write_sequences = write_sequences,
        .columns = columns,
    };
}

fn testDigest(byte: u8) SchemaDigest {
    return @splat(byte);
}

fn testRow(
    market_series_id: MarketSeriesId,
    metric: []const u8,
    canonical_labels: []const u8,
    digest_byte: u8,
    ts_ns: i64,
    write_sequence: u64,
    values: []const f64,
) MarketRowInput {
    return .{
        .market_series_id = market_series_id,
        .metric = metric,
        .canonical_labels = canonical_labels,
        .schema_digest = testDigest(digest_byte),
        .ts_ns = ts_ns,
        .write_sequence = write_sequence,
        .values = values,
    };
}

test "appendBatch rejects a late conflict without partial mutation" {
    var memtable = MarketMemtable.init(std.testing.allocator);
    defer memtable.deinit();

    const labels = "{\"symbol\":\"ABC\"}";
    const sid = marketSeriesId("market.trade", labels);
    const initial_values = [_]f64{ 1, 2 };
    try memtable.appendBatch(&.{.{
        .market_series_id = sid,
        .metric = "market.trade",
        .canonical_labels = labels,
        .schema_digest = testDigest(1),
        .ts_ns = 10,
        .write_sequence = 1,
        .values = &initial_values,
    }});
    const bytes_before = memtable.residentBytes();

    const correction = [_]f64{ 10, 20 };
    const conflicting = [_]f64{ 30, 40 };
    try std.testing.expectError(error.MarketSchemaConflict, memtable.appendBatch(&.{
        .{
            .market_series_id = sid,
            .metric = "market.trade",
            .canonical_labels = labels,
            .schema_digest = testDigest(1),
            .ts_ns = 10,
            .write_sequence = 2,
            .values = &correction,
        },
        .{
            .market_series_id = sid,
            .metric = "market.trade",
            .canonical_labels = labels,
            .schema_digest = testDigest(2),
            .ts_ns = 20,
            .write_sequence = 3,
            .values = &conflicting,
        },
    }));

    try std.testing.expectEqual(bytes_before, memtable.residentBytes());
    const projection = [_]usize{ 0, 1 };
    var rows = try memtable.queryProjected(
        std.testing.allocator,
        sid,
        .{ .start_ns = 0, .end_ns = 100 },
        &projection,
    );
    defer rows.deinit();
    try std.testing.expectEqual(@as(usize, 1), rows.timestamps.len);
    try std.testing.expectEqual(@as(u64, 1), rows.write_sequences[0]);
    try std.testing.expectEqual(@as(f64, 1), rows.columns[0][0]);
}

test "out of order rows query in timestamp order" {
    var memtable = MarketMemtable.init(std.testing.allocator);
    defer memtable.deinit();

    const sid = marketSeriesId("market.trade", "{}");
    const v30 = [_]f64{30};
    const v10 = [_]f64{10};
    const v20 = [_]f64{20};
    try memtable.appendBatch(&.{
        testRow(sid, "market.trade", "{}", 1, 30, 1, &v30),
        testRow(sid, "market.trade", "{}", 1, 10, 2, &v10),
        testRow(sid, "market.trade", "{}", 1, 20, 3, &v20),
    });

    const state = memtable.seriesState(sid).?;
    try std.testing.expect(!state.sorted);
    try std.testing.expectEqual(@as(?u64, 3), state.highest_write_sequence);

    const projection = [_]usize{0};
    var rows = try memtable.queryProjected(
        std.testing.allocator,
        sid,
        .{ .start_ns = 0, .end_ns = 100 },
        &projection,
    );
    defer rows.deinit();
    try std.testing.expectEqualSlices(i64, &.{ 10, 20, 30 }, rows.timestamps);
    try std.testing.expectEqualSlices(f64, &.{ 10, 20, 30 }, rows.columns[0]);
}

test "duplicate timestamps enforce sequence and exact row bit semantics" {
    var memtable = MarketMemtable.init(std.testing.allocator);
    defer memtable.deinit();

    const sid = marketSeriesId("market.quote", "{}");
    const first = [_]f64{ 1, 0.0 };
    try memtable.appendBatch(&.{
        testRow(sid, "market.quote", "{}", 3, 50, 3, &first),
    });
    const bytes_after_first = memtable.residentBytes();

    // Equal sequence and bit-identical values are an idempotent replay.
    try memtable.appendBatch(&.{
        testRow(sid, "market.quote", "{}", 3, 50, 3, &first),
    });
    try std.testing.expectEqual(bytes_after_first, memtable.residentBytes());

    // Lower sequence is stale even when its values differ.
    const stale = [_]f64{ 2, 8 };
    try memtable.appendBatch(&.{
        testRow(sid, "market.quote", "{}", 3, 50, 2, &stale),
    });

    // A higher sequence replaces the complete row.
    const newest = [_]f64{ 3, 0.0 };
    try memtable.appendBatch(&.{
        testRow(sid, "market.quote", "{}", 3, 50, 4, &newest),
    });

    // Positive and negative zero compare numerically equal but have different
    // persisted IEEE-754 bits.
    const conflicting_bits = [_]f64{ 3, -0.0 };
    try std.testing.expectError(error.DuplicateWriteSequenceConflict, memtable.appendBatch(&.{
        testRow(sid, "market.quote", "{}", 3, 50, 4, &conflicting_bits),
    }));

    const projection = [_]usize{ 0, 1 };
    var rows = try memtable.queryProjected(
        std.testing.allocator,
        sid,
        .{ .start_ns = 50, .end_ns = 50 },
        &projection,
    );
    defer rows.deinit();
    try std.testing.expectEqual(@as(usize, 1), rows.timestamps.len);
    try std.testing.expectEqual(@as(u64, 4), rows.write_sequences[0]);
    try std.testing.expectEqual(@as(f64, 3), rows.columns[0][0]);
    try std.testing.expectEqual(@as(u64, @bitCast(@as(f64, 0.0))), @as(u64, @bitCast(rows.columns[1][0])));
}

test "duplicate sequence conflict keeps every earlier batch correction unapplied" {
    var memtable = MarketMemtable.init(std.testing.allocator);
    defer memtable.deinit();

    const sid = marketSeriesId("market.trade", "{}");
    const first = [_]f64{1};
    const second = [_]f64{2};
    try memtable.appendBatch(&.{
        testRow(sid, "market.trade", "{}", 5, 10, 1, &first),
        testRow(sid, "market.trade", "{}", 5, 20, 1, &second),
    });
    const bytes_before = memtable.residentBytes();

    const valid_higher = [_]f64{10};
    const conflicting_equal = [_]f64{20};
    try std.testing.expectError(error.DuplicateWriteSequenceConflict, memtable.appendBatch(&.{
        testRow(sid, "market.trade", "{}", 5, 10, 2, &valid_higher),
        testRow(sid, "market.trade", "{}", 5, 20, 1, &conflicting_equal),
    }));
    try std.testing.expectEqual(bytes_before, memtable.residentBytes());

    const projection = [_]usize{0};
    var rows = try memtable.queryProjected(
        std.testing.allocator,
        sid,
        .{ .start_ns = 0, .end_ns = 100 },
        &projection,
    );
    defer rows.deinit();
    try std.testing.expectEqualSlices(u64, &.{ 1, 1 }, rows.write_sequences);
    try std.testing.expectEqualSlices(f64, &.{ 1, 2 }, rows.columns[0]);
}

test "first binding requires canonical labels and their derived series id" {
    var memtable = MarketMemtable.init(std.testing.allocator);
    defer memtable.deinit();

    const values = [_]f64{1};
    try std.testing.expectError(error.MarketSeriesIdentityMismatch, memtable.appendBatch(&.{
        testRow(99, "market.trade", "{}", 1, 10, 1, &values),
    }));

    const noncanonical_labels = "{\"venue\":\"XNAS\",\"symbol\":\"AAPL\"}";
    try std.testing.expectError(error.NonCanonicalMarketLabels, memtable.appendBatch(&.{
        testRow(
            marketSeriesId("market.trade", noncanonical_labels),
            "market.trade",
            noncanonical_labels,
            1,
            10,
            1,
            &values,
        ),
    }));

    try std.testing.expectError(error.InvalidTagsJson, memtable.appendBatch(&.{
        testRow(marketSeriesId("market.trade", "[]"), "market.trade", "[]", 1, 10, 1, &values),
    }));
    try std.testing.expectEqual(@as(usize, 0), memtable.seriesCount());
    try std.testing.expectEqual(@as(usize, 0), memtable.residentBytes());
}

test "projected range query preserves requested column order" {
    var memtable = MarketMemtable.init(std.testing.allocator);
    defer memtable.deinit();

    const sid = marketSeriesId("market.bar", "{}");
    const row10 = [_]f64{ 1, 2, 3 };
    const row20 = [_]f64{ 4, 5, 6 };
    const row30 = [_]f64{ 7, 8, 9 };
    try memtable.appendBatch(&.{
        testRow(sid, "market.bar", "{}", 4, 10, 1, &row10),
        testRow(sid, "market.bar", "{}", 4, 20, 2, &row20),
        testRow(sid, "market.bar", "{}", 4, 30, 3, &row30),
    });

    const projection = [_]usize{ 2, 0 };
    var rows = try memtable.queryProjected(
        std.testing.allocator,
        sid,
        .{ .start_ns = 15, .end_ns = 25 },
        &projection,
    );
    defer rows.deinit();
    try std.testing.expectEqualSlices(i64, &.{20}, rows.timestamps);
    try std.testing.expectEqualSlices(f64, &.{6}, rows.columns[0]);
    try std.testing.expectEqualSlices(f64, &.{4}, rows.columns[1]);
}

test "hour extraction is deterministic and groups negative timestamps" {
    var memtable = MarketMemtable.init(std.testing.allocator);
    defer memtable.deinit();

    const hour_ns: i64 = 3600 * std.time.ns_per_s;
    const labels_a = "{\"symbol\":\"A\"}";
    const labels_b = "{\"symbol\":\"B\"}";
    const sid_a = marketSeriesId("market.trade", labels_a);
    const sid_b = marketSeriesId("market.trade", labels_b);
    const a = [_]f64{1};
    const b = [_]f64{2};
    const c = [_]f64{3};
    const d = [_]f64{4};
    try memtable.appendBatch(&.{
        testRow(sid_b, "market.trade", labels_b, 2, hour_ns + 5, 1, &a),
        testRow(sid_a, "market.trade", labels_a, 1, 10, 2, &b),
        testRow(sid_a, "market.trade", labels_a, 1, -1, 3, &c),
        testRow(sid_a, "market.trade", labels_a, 1, 20, 4, &d),
    });

    var extraction = try memtable.extractByHour(std.testing.allocator);
    defer extraction.deinit();
    try std.testing.expectEqual(@as(usize, 3), extraction.groups.len);
    const a_start: usize = if (sid_a < sid_b) 0 else 1;
    const b_idx: usize = if (sid_a < sid_b) 2 else 0;
    try std.testing.expectEqual(sid_a, extraction.groups[a_start].identity.series_id);
    try std.testing.expectEqual(@as(i64, -1), extraction.groups[a_start].hour_bucket);
    try std.testing.expectEqualSlices(i64, &.{-1}, extraction.groups[a_start].rows.timestamps);
    try std.testing.expectEqual(sid_a, extraction.groups[a_start + 1].identity.series_id);
    try std.testing.expectEqual(@as(i64, 0), extraction.groups[a_start + 1].hour_bucket);
    try std.testing.expectEqualSlices(i64, &.{ 10, 20 }, extraction.groups[a_start + 1].rows.timestamps);
    try std.testing.expectEqual(sid_b, extraction.groups[b_idx].identity.series_id);
    try std.testing.expectEqual(@as(i64, 1), extraction.groups[b_idx].hour_bucket);
}

test "hour bucket covers the full signed timestamp domain and exact boundaries" {
    const hour_ns: i64 = 3600 * std.time.ns_per_s;
    try std.testing.expectEqual(@divFloor(std.math.minInt(i64), hour_ns), hourBucket(std.math.minInt(i64)));
    try std.testing.expectEqual(@divFloor(std.math.maxInt(i64), hour_ns), hourBucket(std.math.maxInt(i64)));
    try std.testing.expectEqual(@as(i64, -2), hourBucket(-hour_ns - 1));
    try std.testing.expectEqual(@as(i64, -1), hourBucket(-hour_ns));
    try std.testing.expectEqual(@as(i64, -1), hourBucket(-1));
    try std.testing.expectEqual(@as(i64, 0), hourBucket(0));
    try std.testing.expectEqual(@as(i64, 0), hourBucket(hour_ns - 1));
    try std.testing.expectEqual(@as(i64, 1), hourBucket(hour_ns));
}

test "resident byte accounting clears and reuses schema binding" {
    var memtable = MarketMemtable.init(std.testing.allocator);
    defer memtable.deinit();

    const sid = marketSeriesId("market.synthetic", "{}");
    const one = [_]f64{ 1, 2, 3 };
    const two = [_]f64{ 4, 5, 6 };
    try memtable.appendBatch(&.{
        testRow(sid, "market.synthetic", "{}", 8, 1, 1, &one),
        testRow(sid, "market.synthetic", "{}", 8, 2, 2, &two),
    });
    const row_bytes = try rowResidentBytes(3);
    try std.testing.expectEqual(2 * row_bytes, memtable.residentBytes());
    try std.testing.expectEqual(2 * row_bytes, memtable.livePayloadBytes());
    const allocated_before_clear = memtable.allocatedBytes();
    try std.testing.expect(allocated_before_clear > memtable.livePayloadBytes());

    const correction = [_]f64{ 7, 8, 9 };
    try memtable.appendBatch(&.{
        testRow(sid, "market.synthetic", "{}", 8, 1, 3, &correction),
    });
    try std.testing.expectEqual(2 * row_bytes, memtable.residentBytes());

    memtable.clearRetainingCapacity();
    try std.testing.expectEqual(@as(usize, 0), memtable.residentBytes());
    try std.testing.expectEqual(@as(usize, 0), memtable.livePayloadBytes());
    try std.testing.expectEqual(allocated_before_clear, memtable.allocatedBytes());
    try std.testing.expect(memtable.allocatedBytes() > 0);
    try std.testing.expectEqual(@as(usize, 1), memtable.seriesCount());
    try std.testing.expectEqual(@as(usize, 0), memtable.seriesState(sid).?.row_count);
    try std.testing.expect(memtable.seriesState(sid).?.allocated_bytes > 0);

    try memtable.appendBatch(&.{
        testRow(sid, "market.synthetic", "{}", 8, 4, 4, &one),
    });
    try std.testing.expectEqual(row_bytes, memtable.residentBytes());
    try std.testing.expect(memtable.seriesState(sid).?.sorted);
}

test "series collision schema conflict and column mismatch preserve contents" {
    var memtable = MarketMemtable.init(std.testing.allocator);
    defer memtable.deinit();

    const labels = "{\"symbol\":\"ABC\"}";
    const sid = marketSeriesId("market.trade", labels);
    const initial = [_]f64{ 1, 2 };
    try memtable.appendBatch(&.{
        testRow(sid, "market.trade", labels, 1, 1, 1, &initial),
    });

    const bytes_before = memtable.residentBytes();
    const collision = [_]f64{ 3, 4 };
    try std.testing.expectError(error.MarketSeriesConflict, memtable.appendBatch(&.{
        testRow(sid, "market.trade", "{\"symbol\":\"XYZ\"}", 1, 2, 2, &collision),
    }));
    try std.testing.expectError(error.MarketSchemaConflict, memtable.appendBatch(&.{
        testRow(sid, "market.trade", labels, 9, 2, 2, &collision),
    }));

    const wrong_columns = [_]f64{ 3, 4, 5 };
    try std.testing.expectError(error.MarketValueCountMismatch, memtable.appendBatch(&.{
        testRow(sid, "market.trade", labels, 1, 2, 2, &wrong_columns),
    }));
    try std.testing.expectEqual(bytes_before, memtable.residentBytes());
    try std.testing.expectEqual(@as(usize, 1), memtable.seriesState(sid).?.row_count);
}
