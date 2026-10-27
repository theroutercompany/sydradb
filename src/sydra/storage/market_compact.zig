const std = @import("std");
const market_manifest = @import("market_manifest.zig");
const market_segment = @import("market_segment.zig");

pub const CompactionOutcome = enum {
    compacted,
    already_applied,
    no_overlaps,
};

pub const CompactionResult = struct {
    allocator: std.mem.Allocator,
    outcome: CompactionOutcome,
    input_segment_count: usize,
    input_row_count: u64,
    output_row_count: u64,
    output_path: ?[]u8,

    pub fn deinit(self: *CompactionResult) void {
        if (self.output_path) |path| self.allocator.free(path);
        self.* = undefined;
    }
};

const OwnedRow = struct {
    ts_ns: i64,
    write_sequence: u64,
    values: []f64,

    fn deinit(self: *OwnedRow, alloc: std.mem.Allocator) void {
        alloc.free(self.values);
        self.* = undefined;
    }
};

/// Returns borrowed descriptors that overlap at least one other descriptor for
/// the same series and hour. The returned pointer slice is owned by `alloc` and
/// remains valid until the manifest is mutated.
pub fn selectOverlappingDescriptors(
    alloc: std.mem.Allocator,
    manifest: *const market_manifest.Manifest,
    market_series_id: market_manifest.MarketSeriesId,
    hour_bucket: i64,
) ![]*const market_manifest.MarketSegmentDescriptor {
    var candidates = std.array_list.Managed(*const market_manifest.MarketSegmentDescriptor).init(alloc);
    defer candidates.deinit();
    for (manifest.list()) |*descriptor| {
        if (descriptor.market_series_id == market_series_id and
            descriptor.hour_bucket == hour_bucket)
        {
            try candidates.append(descriptor);
        }
    }

    var selected = std.array_list.Managed(*const market_manifest.MarketSegmentDescriptor).init(alloc);
    errdefer selected.deinit();
    for (candidates.items, 0..) |candidate, candidate_idx| {
        var overlaps = false;
        for (candidates.items, 0..) |other, other_idx| {
            if (candidate_idx == other_idx) continue;
            if (rangesOverlap(candidate.*, other.*)) {
                overlaps = true;
                break;
            }
        }
        if (overlaps) try selected.append(candidate);
    }
    return try selected.toOwnedSlice();
}

/// Compacts every overlapping descriptor for one market series/hour into one
/// immutable SYMKT1 segment.
///
/// The local output segment is written before manifest publication. If
/// publication fails, the immutable output is intentionally retained as an
/// orphan; a retry writes identical bytes, reuses the same content-addressed
/// path, and retries the atomic manifest replacement.
pub fn compactSeriesHour(
    alloc: std.mem.Allocator,
    data_dir: std.fs.Dir,
    manifest: *market_manifest.Manifest,
    market_series_id: market_manifest.MarketSeriesId,
    hour_bucket: i64,
) !CompactionResult {
    const selected = try selectOverlappingDescriptors(
        alloc,
        manifest,
        market_series_id,
        hour_bucket,
    );
    defer alloc.free(selected);
    if (selected.len < 2) {
        return .{
            .allocator = alloc,
            .outcome = .no_overlaps,
            .input_segment_count = selected.len,
            .input_row_count = 0,
            .output_row_count = 0,
            .output_path = null,
        };
    }

    try validateDescriptorSet(selected);

    var rows = std.array_list.Managed(OwnedRow).init(alloc);
    defer {
        for (rows.items) |*row| row.deinit(alloc);
        rows.deinit();
    }
    var row_by_timestamp = std.AutoHashMap(i64, usize).init(alloc);
    defer row_by_timestamp.deinit();

    var input_row_count: u64 = 0;
    for (selected) |descriptor| {
        const file_size = std.math.cast(usize, descriptor.file_size) orelse
            return error.MarketSegmentTooLarge;
        const bytes = data_dir.readFileAlloc(alloc, descriptor.path, file_size) catch |err| switch (err) {
            error.FileTooBig => return error.MarketSegmentContentMismatch,
            else => return err,
        };
        defer alloc.free(bytes);
        if (bytes.len != file_size) return error.MarketSegmentContentMismatch;
        const digest = market_manifest.contentDigest(bytes);
        if (!std.mem.eql(u8, &digest, &descriptor.content_id) or
            !std.mem.eql(u8, &digest, &descriptor.file_hash))
        {
            return error.MarketSegmentContentMismatch;
        }

        var decoded = try market_segment.readAll(alloc, data_dir, descriptor.path);
        defer decoded.deinit(alloc);
        try validateDecodedDescriptor(descriptor, &decoded);
        input_row_count = std.math.add(u64, input_row_count, descriptor.row_count) catch
            return error.MarketSegmentTooLarge;

        for (decoded.timestamps, 0..) |ts_ns, row_idx| {
            const write_sequence = decoded.write_sequences[row_idx];
            if (row_by_timestamp.get(ts_ns)) |existing_idx| {
                const existing = &rows.items[existing_idx];
                if (write_sequence < existing.write_sequence) continue;
                if (write_sequence == existing.write_sequence) {
                    if (!rowMatchesDecoded(existing.values, &decoded, row_idx)) {
                        return error.DuplicateWriteSequenceConflict;
                    }
                    continue;
                }

                const replacement_values = try copyDecodedValues(alloc, &decoded, row_idx);
                alloc.free(existing.values);
                existing.values = replacement_values;
                existing.write_sequence = write_sequence;
                continue;
            }

            const values = try copyDecodedValues(alloc, &decoded, row_idx);
            var values_owned = true;
            errdefer if (values_owned) alloc.free(values);
            const new_idx = rows.items.len;
            try rows.append(.{
                .ts_ns = ts_ns,
                .write_sequence = write_sequence,
                .values = values,
            });
            values_owned = false;
            row_by_timestamp.put(ts_ns, new_idx) catch |err| {
                var removed = rows.pop().?;
                removed.deinit(alloc);
                return err;
            };
        }
    }
    if (rows.items.len == 0) return error.EmptyMarketSegment;

    std.sort.block(OwnedRow, rows.items, {}, struct {
        fn lessThan(_: void, lhs: OwnedRow, rhs: OwnedRow) bool {
            if (lhs.ts_ns != rhs.ts_ns) return lhs.ts_ns < rhs.ts_ns;
            return lhs.write_sequence < rhs.write_sequence;
        }
    }.lessThan);

    const row_views = try alloc.alloc(market_segment.MarketRowView, rows.items.len);
    defer alloc.free(row_views);
    for (rows.items, 0..) |row, row_idx| {
        row_views[row_idx] = .{
            .ts_ns = row.ts_ns,
            .write_sequence = row.write_sequence,
            .values = row.values,
        };
    }

    const first = selected[0];
    const output_path = try market_segment.write(alloc, data_dir, .{
        .market_series_id = first.market_series_id,
        .schema_digest = first.schema_digest,
        .metric = first.metric,
        .canonical_labels = first.canonical_labels,
        .hour = first.hour_bucket,
        .column_names = first.column_names,
    }, row_views);
    errdefer alloc.free(output_path);

    const output_bytes = try data_dir.readFileAlloc(
        alloc,
        output_path,
        std.math.maxInt(usize),
    );
    defer alloc.free(output_bytes);
    const output_digest = market_manifest.contentDigest(output_bytes);
    var output_metadata = try market_segment.inspect(alloc, data_dir, output_path);
    defer output_metadata.deinit(alloc);

    const replacement_keys = try alloc.alloc(market_manifest.ReplacementKey, selected.len);
    defer alloc.free(replacement_keys);
    for (selected, 0..) |descriptor, idx| {
        replacement_keys[idx] = .{
            .path = descriptor.path,
            .content_id = descriptor.content_id,
        };
    }

    const replacement_outcome = try manifest.replaceBatch(data_dir, replacement_keys, &.{.{
        .path = output_path,
        .market_series_id = first.market_series_id,
        .schema_digest = first.schema_digest,
        .metric = first.metric,
        .canonical_labels = first.canonical_labels,
        .hour_bucket = first.hour_bucket,
        .start_ts_ns = output_metadata.start_ts_ns,
        .end_ts_ns = output_metadata.end_ts_ns,
        .row_count = output_metadata.count,
        .block_count = output_metadata.block_count,
        .column_names = first.column_names,
        .content_id = output_digest,
        .file_hash = output_digest,
        .file_size = output_bytes.len,
    }});

    return .{
        .allocator = alloc,
        .outcome = switch (replacement_outcome) {
            .applied => .compacted,
            .already_applied => .already_applied,
        },
        .input_segment_count = selected.len,
        .input_row_count = input_row_count,
        .output_row_count = output_metadata.count,
        .output_path = output_path,
    };
}

fn rangesOverlap(
    lhs: market_manifest.MarketSegmentDescriptor,
    rhs: market_manifest.MarketSegmentDescriptor,
) bool {
    return lhs.start_ts_ns <= rhs.end_ts_ns and rhs.start_ts_ns <= lhs.end_ts_ns;
}

fn validateDescriptorSet(
    descriptors: []const *const market_manifest.MarketSegmentDescriptor,
) !void {
    const first = descriptors[0];
    for (descriptors[1..]) |descriptor| {
        if (descriptor.market_series_id != first.market_series_id or
            descriptor.hour_bucket != first.hour_bucket or
            !std.mem.eql(u8, &descriptor.schema_digest, &first.schema_digest) or
            !std.mem.eql(u8, descriptor.metric, first.metric) or
            !std.mem.eql(u8, descriptor.canonical_labels, first.canonical_labels) or
            !columnNamesEqual(descriptor.column_names, first.column_names))
        {
            return error.MarketCompactionSchemaMismatch;
        }
    }
}

fn validateDecodedDescriptor(
    descriptor: *const market_manifest.MarketSegmentDescriptor,
    decoded: *const market_segment.ReadResult,
) !void {
    if (decoded.metadata.market_series_id != descriptor.market_series_id or
        !std.mem.eql(u8, &decoded.metadata.schema_digest, &descriptor.schema_digest) or
        !std.mem.eql(u8, decoded.metadata.metric, descriptor.metric) or
        !std.mem.eql(u8, decoded.metadata.canonical_labels, descriptor.canonical_labels) or
        decoded.metadata.hour != descriptor.hour_bucket or
        decoded.metadata.start_ts_ns != descriptor.start_ts_ns or
        decoded.metadata.end_ts_ns != descriptor.end_ts_ns or
        decoded.metadata.count != descriptor.row_count or
        decoded.metadata.block_count != descriptor.block_count or
        !columnNamesEqual(decoded.metadata.column_names, descriptor.column_names) or
        decoded.columns.len != descriptor.column_names.len)
    {
        return error.MarketSegmentDescriptorMismatch;
    }
    for (decoded.columns, descriptor.column_names) |column, expected_name| {
        if (!std.mem.eql(u8, column.name, expected_name)) {
            return error.MarketSegmentDescriptorMismatch;
        }
    }
}

fn columnNamesEqual(lhs: []const []const u8, rhs: []const []const u8) bool {
    if (lhs.len != rhs.len) return false;
    for (lhs, rhs) |lhs_name, rhs_name| {
        if (!std.mem.eql(u8, lhs_name, rhs_name)) return false;
    }
    return true;
}

fn copyDecodedValues(
    alloc: std.mem.Allocator,
    decoded: *const market_segment.ReadResult,
    row_idx: usize,
) ![]f64 {
    const values = try alloc.alloc(f64, decoded.columns.len);
    for (decoded.columns, 0..) |column, column_idx| {
        values[column_idx] = column.values[row_idx];
    }
    return values;
}

fn rowMatchesDecoded(
    expected: []const f64,
    decoded: *const market_segment.ReadResult,
    row_idx: usize,
) bool {
    if (expected.len != decoded.columns.len) return false;
    for (decoded.columns, 0..) |column, column_idx| {
        if (@as(u64, @bitCast(expected[column_idx])) !=
            @as(u64, @bitCast(column.values[row_idx])))
        {
            return false;
        }
    }
    return true;
}

const test_metric = "market.quote";
const test_labels = "{\"symbol\":\"AAPL\",\"venue\":\"XNAS\"}";
const test_columns = [_][]const u8{ "bid", "ask" };
const test_schema_digest = [_]u8{0x44} ** 32;

fn addTestSegment(
    alloc: std.mem.Allocator,
    data_dir: std.fs.Dir,
    manifest: *market_manifest.Manifest,
    rows: []const market_segment.MarketRowView,
) ![]u8 {
    const series_id = @import("market_identity.zig").seriesId(test_metric, test_labels);
    const path = try market_segment.write(alloc, data_dir, .{
        .market_series_id = series_id,
        .schema_digest = test_schema_digest,
        .metric = test_metric,
        .canonical_labels = test_labels,
        .hour = 0,
        .column_names = &test_columns,
    }, rows);
    errdefer alloc.free(path);

    const bytes = try data_dir.readFileAlloc(alloc, path, 16 * 1024 * 1024);
    defer alloc.free(bytes);
    const digest = market_manifest.contentDigest(bytes);
    var metadata = try market_segment.inspect(alloc, data_dir, path);
    defer metadata.deinit(alloc);
    try manifest.addBatch(data_dir, &.{.{
        .path = path,
        .market_series_id = series_id,
        .schema_digest = test_schema_digest,
        .metric = test_metric,
        .canonical_labels = test_labels,
        .hour_bucket = 0,
        .start_ts_ns = metadata.start_ts_ns,
        .end_ts_ns = metadata.end_ts_ns,
        .row_count = metadata.count,
        .block_count = metadata.block_count,
        .column_names = &test_columns,
        .content_id = digest,
        .file_hash = digest,
        .file_size = bytes.len,
    }});
    return path;
}

test "market compaction selects only overlapping descriptors for one series hour" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var manifest = market_manifest.Manifest.init(alloc);
    defer manifest.deinit();

    const a_values = [_]f64{ 1, 2 };
    const b_values = [_]f64{ 3, 4 };
    const c_values = [_]f64{ 5, 6 };
    const a_rows = [_]market_segment.MarketRowView{
        .{ .ts_ns = 1, .write_sequence = 1, .values = &a_values },
        .{ .ts_ns = 5, .write_sequence = 2, .values = &b_values },
    };
    const b_rows = [_]market_segment.MarketRowView{
        .{ .ts_ns = 5, .write_sequence = 3, .values = &b_values },
        .{ .ts_ns = 8, .write_sequence = 4, .values = &c_values },
    };
    const c_rows = [_]market_segment.MarketRowView{
        .{ .ts_ns = 20, .write_sequence = 5, .values = &a_values },
        .{ .ts_ns = 30, .write_sequence = 6, .values = &c_values },
    };
    const a_path = try addTestSegment(alloc, tmp.dir, &manifest, &a_rows);
    defer alloc.free(a_path);
    const b_path = try addTestSegment(alloc, tmp.dir, &manifest, &b_rows);
    defer alloc.free(b_path);
    const c_path = try addTestSegment(alloc, tmp.dir, &manifest, &c_rows);
    defer alloc.free(c_path);

    const series_id = @import("market_identity.zig").seriesId(test_metric, test_labels);
    const selected = try selectOverlappingDescriptors(alloc, &manifest, series_id, 0);
    defer alloc.free(selected);
    try std.testing.expectEqual(@as(usize, 2), selected.len);
    try std.testing.expectEqualStrings(a_path, selected[0].path);
    try std.testing.expectEqualStrings(b_path, selected[1].path);
}

test "market compaction is deterministic and highest sequence wins atomically" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var manifest = market_manifest.Manifest.init(alloc);
    defer manifest.deinit();

    const first_a = [_]f64{ 1, 10 };
    const first_b = [_]f64{ 2, 20 };
    const corrected_b = [_]f64{ 22, 220 };
    const final_c = [_]f64{ 3, 30 };
    const first_rows = [_]market_segment.MarketRowView{
        .{ .ts_ns = 1, .write_sequence = 1, .values = &first_a },
        .{ .ts_ns = 2, .write_sequence = 1, .values = &first_b },
    };
    const second_rows = [_]market_segment.MarketRowView{
        .{ .ts_ns = 2, .write_sequence = 9, .values = &corrected_b },
        .{ .ts_ns = 3, .write_sequence = 2, .values = &final_c },
    };
    const first_path = try addTestSegment(alloc, tmp.dir, &manifest, &first_rows);
    defer alloc.free(first_path);
    const second_path = try addTestSegment(alloc, tmp.dir, &manifest, &second_rows);
    defer alloc.free(second_path);

    var equivalent_pre_compaction = try manifest.clone(alloc);
    defer equivalent_pre_compaction.deinit();
    const series_id = @import("market_identity.zig").seriesId(test_metric, test_labels);

    var result = try compactSeriesHour(alloc, tmp.dir, &manifest, series_id, 0);
    defer result.deinit();
    try std.testing.expectEqual(CompactionOutcome.compacted, result.outcome);
    try std.testing.expectEqual(@as(usize, 2), result.input_segment_count);
    try std.testing.expectEqual(@as(u64, 4), result.input_row_count);
    try std.testing.expectEqual(@as(u64, 3), result.output_row_count);
    try std.testing.expectEqual(@as(usize, 1), manifest.list().len);

    var decoded = try market_segment.readAll(alloc, tmp.dir, result.output_path.?);
    defer decoded.deinit(alloc);
    try std.testing.expectEqualSlices(i64, &.{ 1, 2, 3 }, decoded.timestamps);
    try std.testing.expectEqualSlices(u64, &.{ 1, 9, 2 }, decoded.write_sequences);
    try std.testing.expectEqual(@as(u64, @bitCast(corrected_b[0])), @as(u64, @bitCast(decoded.columns[0].values[1])));
    try std.testing.expectEqual(@as(u64, @bitCast(corrected_b[1])), @as(u64, @bitCast(decoded.columns[1].values[1])));

    try tmp.dir.access(first_path, .{});
    try tmp.dir.access(second_path, .{});

    var deterministic_retry = try compactSeriesHour(
        alloc,
        tmp.dir,
        &equivalent_pre_compaction,
        series_id,
        0,
    );
    defer deterministic_retry.deinit();
    try std.testing.expectEqualStrings(result.output_path.?, deterministic_retry.output_path.?);
    const first_output = try tmp.dir.readFileAlloc(alloc, result.output_path.?, 16 * 1024 * 1024);
    defer alloc.free(first_output);
    const second_output = try tmp.dir.readFileAlloc(alloc, deterministic_retry.output_path.?, 16 * 1024 * 1024);
    defer alloc.free(second_output);
    try std.testing.expectEqualSlices(u8, first_output, second_output);
}

test "market compaction rejects exact sequence conflicts before manifest publication" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var manifest = market_manifest.Manifest.init(alloc);
    defer manifest.deinit();

    const lhs_values = [_]f64{ 1, 2 };
    const rhs_values = [_]f64{ 1, 3 };
    const lhs_rows = [_]market_segment.MarketRowView{
        .{ .ts_ns = 1, .write_sequence = 7, .values = &lhs_values },
        .{ .ts_ns = 2, .write_sequence = 8, .values = &lhs_values },
    };
    const rhs_rows = [_]market_segment.MarketRowView{
        .{ .ts_ns = 1, .write_sequence = 7, .values = &rhs_values },
        .{ .ts_ns = 3, .write_sequence = 9, .values = &rhs_values },
    };
    const lhs_path = try addTestSegment(alloc, tmp.dir, &manifest, &lhs_rows);
    defer alloc.free(lhs_path);
    const rhs_path = try addTestSegment(alloc, tmp.dir, &manifest, &rhs_rows);
    defer alloc.free(rhs_path);
    const manifest_before = try tmp.dir.readFileAlloc(alloc, market_manifest.manifest_path, 1024 * 1024);
    defer alloc.free(manifest_before);

    const series_id = @import("market_identity.zig").seriesId(test_metric, test_labels);
    try std.testing.expectError(
        error.DuplicateWriteSequenceConflict,
        compactSeriesHour(alloc, tmp.dir, &manifest, series_id, 0),
    );
    try std.testing.expectEqual(@as(usize, 2), manifest.list().len);
    const manifest_after = try tmp.dir.readFileAlloc(alloc, market_manifest.manifest_path, 1024 * 1024);
    defer alloc.free(manifest_after);
    try std.testing.expectEqualSlices(u8, manifest_before, manifest_after);
}
