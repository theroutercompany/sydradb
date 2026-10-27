const std = @import("std");
const types = @import("../types.zig");
const gorilla = @import("../codec/gorilla.zig");
const market_identity = @import("market_identity.zig");
const object_store = @import("object_store.zig");
const extents = @import("extents.zig");

pub const market_segment_magic = "SYMKT1";
pub const market_segment_version: u16 = 1;
pub const market_segment_block_rows: u32 = 4096;

const block_magic = "MBLK";
const max_metadata_string_bytes: usize = 1024 * 1024;
const hour_ns: i64 = 3600 * std.time.ns_per_s;
const market_segment_root_meta_version: u8 = 2;
const market_segment_block_index_version: u8 = 1;
const market_segment_block_stats_version: u8 = 1;

pub const MarketSeriesId = market_identity.MarketSeriesId;
pub const SchemaDigest = market_identity.SchemaDigest;
pub const RowFingerprint = [32]u8;

pub const MetadataView = struct {
    market_series_id: MarketSeriesId,
    schema_digest: SchemaDigest,
    metric: []const u8,
    canonical_labels: []const u8,
    hour: i64,
    column_names: []const []const u8,
};

pub const MarketRowView = struct {
    ts_ns: i64,
    write_sequence: u64,
    values: []const f64,
};

pub const Metadata = struct {
    market_series_id: MarketSeriesId,
    schema_digest: SchemaDigest,
    metric: []u8,
    canonical_labels: []u8,
    hour: i64,
    count: u64,
    start_ts_ns: i64,
    end_ts_ns: i64,
    block_count: u32,
    column_names: [][]u8,

    pub fn deinit(self: *Metadata, alloc: std.mem.Allocator) void {
        alloc.free(self.metric);
        alloc.free(self.canonical_labels);
        for (self.column_names) |name| alloc.free(name);
        alloc.free(self.column_names);
    }
};

pub const MarketSegmentRootMetadata = struct {
    market_series_id: MarketSeriesId,
    schema_digest: SchemaDigest,
    metric: []u8,
    canonical_labels: []u8,
    hour: i64,
    count: u64,
    start_ts_ns: i64,
    end_ts_ns: i64,
    block_rows: u32,
    block_count: u32,
    column_names: [][]u8,
    file_size: u64,
    content_hash: [32]u8,
    extent_chunk_bytes: u32,

    pub fn deinit(self: *MarketSegmentRootMetadata, alloc: std.mem.Allocator) void {
        alloc.free(self.metric);
        alloc.free(self.canonical_labels);
        for (self.column_names) |name| alloc.free(name);
        alloc.free(self.column_names);
    }
};

pub const MarketSegmentBlockView = struct {
    index: u32,
    count: u32,
    min_ts_ns: i64,
    max_ts_ns: i64,
    bounds_valid: []bool,
    column_mins: []f64,
    column_maxs: []f64,
    timestamp_payload_bytes: u64,
    sequence_payload_bytes: u64,
    fingerprint_payload_bytes: u64,
    column_payload_bytes: []u64,
    timestamp_tree: extents.WriteResult,
    sequence_tree: extents.WriteResult,
    fingerprint_tree: extents.WriteResult,
    value_trees: []extents.WriteResult,

    pub fn deinit(self: *MarketSegmentBlockView, alloc: std.mem.Allocator) void {
        alloc.free(self.bounds_valid);
        alloc.free(self.column_mins);
        alloc.free(self.column_maxs);
        alloc.free(self.column_payload_bytes);
        alloc.free(self.value_trees);
    }
};

pub const MarketSegmentBlockCursor = struct {
    alloc: std.mem.Allocator,
    store: *object_store.ObjectStore,
    metadata: MarketSegmentRootMetadata,
    blocks: []TreeEntry,
    block_index: []MarketBlockStats,
    next_index: usize = 0,

    pub fn open(
        alloc: std.mem.Allocator,
        store: *object_store.ObjectStore,
        root_id: object_store.ObjectId,
    ) !MarketSegmentBlockCursor {
        var root = try loadMarketRoot(alloc, store, root_id);
        defer root.root_tree.deinit(alloc);
        var metadata = root.metadata;
        errdefer metadata.deinit(alloc);
        root.metadata = undefined;

        var blocks_tree = try loadTreeObject(alloc, store, root.blocks_id);
        errdefer blocks_tree.deinit(alloc);
        const block_index = try loadBlockIndex(alloc, store, root.block_index_id, &metadata);
        errdefer {
            for (block_index) |*stats| stats.deinit(alloc);
            alloc.free(block_index);
        }
        try validateBlockTreeEntries(blocks_tree.entries, metadata.block_count);

        return .{
            .alloc = alloc,
            .store = store,
            .metadata = metadata,
            .blocks = blocks_tree.entries,
            .block_index = block_index,
        };
    }

    pub fn deinit(self: *MarketSegmentBlockCursor) void {
        self.metadata.deinit(self.alloc);
        for (self.blocks) |*entry| entry.deinit(self.alloc);
        self.alloc.free(self.blocks);
        for (self.block_index) |*stats| stats.deinit(self.alloc);
        self.alloc.free(self.block_index);
    }

    pub fn next(self: *MarketSegmentBlockCursor) !?MarketSegmentBlockView {
        if (self.next_index >= self.block_index.len) return null;
        const expected = &self.block_index[self.next_index];
        var block = try loadCasBlock(
            self.alloc,
            self.store,
            self.blocks[self.next_index],
            expected,
            self.metadata.extent_chunk_bytes,
        );
        defer block.deinit(self.alloc);

        const bounds_valid = try self.alloc.dupe(bool, expected.bounds_valid);
        errdefer self.alloc.free(bounds_valid);
        const column_mins = try self.alloc.dupe(f64, expected.column_mins);
        errdefer self.alloc.free(column_mins);
        const column_maxs = try self.alloc.dupe(f64, expected.column_maxs);
        errdefer self.alloc.free(column_maxs);
        const column_payload_bytes = try self.alloc.dupe(u64, expected.column_payload_bytes);
        errdefer self.alloc.free(column_payload_bytes);
        const value_trees = try self.alloc.dupe(extents.WriteResult, block.value_trees);
        errdefer self.alloc.free(value_trees);

        const view = MarketSegmentBlockView{
            .index = @intCast(self.next_index),
            .count = expected.count,
            .min_ts_ns = expected.min_ts_ns,
            .max_ts_ns = expected.max_ts_ns,
            .bounds_valid = bounds_valid,
            .column_mins = column_mins,
            .column_maxs = column_maxs,
            .timestamp_payload_bytes = expected.timestamp_payload_bytes,
            .sequence_payload_bytes = expected.sequence_payload_bytes,
            .fingerprint_payload_bytes = expected.fingerprint_payload_bytes,
            .column_payload_bytes = column_payload_bytes,
            .timestamp_tree = block.timestamp_tree,
            .sequence_tree = block.sequence_tree,
            .fingerprint_tree = block.fingerprint_tree,
            .value_trees = value_trees,
        };
        self.next_index += 1;
        return view;
    }
};

const MarketBlockStats = struct {
    count: u32,
    min_ts_ns: i64,
    max_ts_ns: i64,
    bounds_valid: []bool,
    column_mins: []f64,
    column_maxs: []f64,
    timestamp_payload_bytes: u64,
    sequence_payload_bytes: u64,
    fingerprint_payload_bytes: u64,
    column_payload_bytes: []u64,

    fn deinit(self: *MarketBlockStats, alloc: std.mem.Allocator) void {
        alloc.free(self.bounds_valid);
        alloc.free(self.column_mins);
        alloc.free(self.column_maxs);
        alloc.free(self.column_payload_bytes);
    }
};

const CasBlock = struct {
    stats: MarketBlockStats,
    timestamp_tree: extents.WriteResult,
    sequence_tree: extents.WriteResult,
    fingerprint_tree: extents.WriteResult,
    value_trees: []extents.WriteResult,

    fn deinit(self: *CasBlock, alloc: std.mem.Allocator) void {
        self.stats.deinit(alloc);
        alloc.free(self.value_trees);
    }
};

pub const ProjectedColumn = struct {
    name: []u8,
    values: []f64,

    fn deinit(self: *ProjectedColumn, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
        alloc.free(self.values);
    }
};

pub const ReadStats = struct {
    blocks_total: u32 = 0,
    blocks_scanned: u32 = 0,
    blocks_pruned: u32 = 0,
    columns_decoded: u64 = 0,
    bytes_decoded: u64 = 0,
};

pub const ReadResult = struct {
    metadata: Metadata,
    timestamps: []i64,
    write_sequences: []u64,
    row_fingerprints: []RowFingerprint,
    columns: []ProjectedColumn,
    stats: ReadStats,

    pub fn deinit(self: *ReadResult, alloc: std.mem.Allocator) void {
        self.metadata.deinit(alloc);
        alloc.free(self.timestamps);
        alloc.free(self.write_sequences);
        alloc.free(self.row_fingerprints);
        for (self.columns) |*column| column.deinit(alloc);
        alloc.free(self.columns);
    }
};

const CandidateRow = struct {
    ts_ns: i64,
    write_sequence: u64,
    fingerprint: RowFingerprint,
    values: []f64,

    fn deinit(self: *CandidateRow, alloc: std.mem.Allocator) void {
        alloc.free(self.values);
    }
};

const ParsedHeader = struct {
    metadata: Metadata,
    blocks_offset: usize,
};

const ParsedBlock = struct {
    next_offset: usize,
    count: u32,
    min_ts_ns: i64,
    max_ts_ns: i64,
    bounds_valid: []bool,
    column_mins: []f64,
    column_maxs: []f64,
    timestamp_payload: []const u8,
    sequence_payload: []const u8,
    fingerprint_payload: []const u8,
    column_payloads: [][]const u8,

    fn deinit(self: *ParsedBlock, alloc: std.mem.Allocator) void {
        alloc.free(self.bounds_valid);
        alloc.free(self.column_mins);
        alloc.free(self.column_maxs);
        alloc.free(self.column_payloads);
    }
};

pub fn write(
    alloc: std.mem.Allocator,
    data_dir: std.fs.Dir,
    metadata: MetadataView,
    rows: []const MarketRowView,
) ![]u8 {
    try validateWriteInput(alloc, metadata, rows);

    var encoded = std.array_list.Managed(u8).init(alloc);
    defer encoded.deinit();

    try encoded.appendSlice(market_segment_magic);
    try appendInt(&encoded, u16, market_segment_version);

    var header = std.array_list.Managed(u8).init(alloc);
    defer header.deinit();
    try encodeHeader(&header, metadata, rows);
    try appendInt(&encoded, u32, @intCast(header.items.len));
    try appendInt(&encoded, u32, checksum(header.items));
    try encoded.appendSlice(header.items);

    var row_offset: usize = 0;
    while (row_offset < rows.len) {
        const end = @min(row_offset + market_segment_block_rows, rows.len);
        try encodeBlock(alloc, &encoded, metadata.column_names.len, rows[row_offset..end]);
        row_offset = end;
    }

    return try writeLocalMirrorBytes(
        alloc,
        data_dir,
        metadata.hour,
        metadata.market_series_id,
        rows[0].ts_ns,
        rows[rows.len - 1].ts_ns,
        encoded.items,
    );
}

pub fn inspect(
    alloc: std.mem.Allocator,
    data_dir: std.fs.Dir,
    path: []const u8,
) !Metadata {
    const bytes = try readFileAlloc(alloc, data_dir, path);
    defer alloc.free(bytes);

    var parsed = try parseHeader(alloc, bytes);
    errdefer parsed.metadata.deinit(alloc);
    try validateBlockFrames(alloc, bytes, &parsed.metadata, parsed.blocks_offset);
    return parsed.metadata;
}

pub fn validateExpectedSchema(actual: *const Metadata, expected: MetadataView) !void {
    if (actual.market_series_id != expected.market_series_id or
        !std.mem.eql(u8, &actual.schema_digest, &expected.schema_digest) or
        !std.mem.eql(u8, actual.metric, expected.metric) or
        !std.mem.eql(u8, actual.canonical_labels, expected.canonical_labels) or
        actual.column_names.len != expected.column_names.len)
    {
        return error.MarketSegmentSchemaMismatch;
    }
    for (actual.column_names, expected.column_names) |actual_name, expected_name| {
        if (!std.mem.eql(u8, actual_name, expected_name)) {
            return error.MarketSegmentSchemaMismatch;
        }
    }
}

pub fn readAll(
    alloc: std.mem.Allocator,
    data_dir: std.fs.Dir,
    path: []const u8,
) !ReadResult {
    return readRange(alloc, data_dir, path, std.math.minInt(i64), std.math.maxInt(i64));
}

pub fn readRange(
    alloc: std.mem.Allocator,
    data_dir: std.fs.Dir,
    path: []const u8,
    start_ts_ns: i64,
    end_ts_ns: i64,
) !ReadResult {
    return readProjectedRangeInternal(alloc, data_dir, path, start_ts_ns, end_ts_ns, null);
}

pub fn readProjectedRange(
    alloc: std.mem.Allocator,
    data_dir: std.fs.Dir,
    path: []const u8,
    start_ts_ns: i64,
    end_ts_ns: i64,
    requested_columns: []const []const u8,
) !ReadResult {
    return readProjectedRangeInternal(
        alloc,
        data_dir,
        path,
        start_ts_ns,
        end_ts_ns,
        requested_columns,
    );
}

pub fn writeSegmentRootForFile(
    alloc: std.mem.Allocator,
    data_dir: std.fs.Dir,
    store: *object_store.ObjectStore,
    path: []const u8,
    extent_chunk_bytes: u32,
) !object_store.ObjectId {
    const bytes = try readFileAlloc(alloc, data_dir, path);
    defer alloc.free(bytes);
    return try writeSegmentRootFromBytes(alloc, store, bytes, extent_chunk_bytes);
}

pub fn writeSegmentRootFromBytes(
    alloc: std.mem.Allocator,
    store: *object_store.ObjectStore,
    bytes: []const u8,
    extent_chunk_bytes: u32,
) !object_store.ObjectId {
    var parsed = try parseHeader(alloc, bytes);
    defer parsed.metadata.deinit(alloc);
    try validateBlockFrames(alloc, bytes, &parsed.metadata, parsed.blocks_offset);

    const effective_chunk_bytes = if (extent_chunk_bytes == 0)
        extents.DefaultChunkBytes
    else
        extent_chunk_bytes;

    var block_entries = std.array_list.Managed(TreeEntry).init(alloc);
    defer {
        for (block_entries.items) |*entry| entry.deinit(alloc);
        block_entries.deinit();
    }
    var block_index_payload = std.array_list.Managed(u8).init(alloc);
    defer block_index_payload.deinit();
    try block_index_payload.append(market_segment_block_index_version);
    try appendInt(&block_index_payload, u32, parsed.metadata.block_count);

    var cursor = parsed.blocks_offset;
    var block_idx: u32 = 0;
    while (block_idx < parsed.metadata.block_count) : (block_idx += 1) {
        var block = try parseBlock(
            alloc,
            bytes,
            cursor,
            parsed.metadata.column_names.len,
        );
        defer block.deinit(alloc);
        cursor = block.next_offset;

        const stats = MarketBlockStats{
            .count = block.count,
            .min_ts_ns = block.min_ts_ns,
            .max_ts_ns = block.max_ts_ns,
            .bounds_valid = block.bounds_valid,
            .column_mins = block.column_mins,
            .column_maxs = block.column_maxs,
            .timestamp_payload_bytes = block.timestamp_payload.len,
            .sequence_payload_bytes = block.sequence_payload.len,
            .fingerprint_payload_bytes = block.fingerprint_payload.len,
            .column_payload_bytes = blk: {
                const sizes = try alloc.alloc(u64, block.column_payloads.len);
                for (block.column_payloads, 0..) |payload, idx| sizes[idx] = payload.len;
                break :blk sizes;
            },
        };
        defer alloc.free(stats.column_payload_bytes);
        try encodeMarketBlockStatsRecord(&block_index_payload, stats);

        const timestamps_extent = try extents.writeAll(
            alloc,
            store,
            block.timestamp_payload,
            effective_chunk_bytes,
        );
        const sequences_extent = try extents.writeAll(
            alloc,
            store,
            block.sequence_payload,
            effective_chunk_bytes,
        );
        const fingerprints_extent = try extents.writeAll(
            alloc,
            store,
            block.fingerprint_payload,
            effective_chunk_bytes,
        );

        var value_entries = std.array_list.Managed(TreeEntry).init(alloc);
        defer {
            for (value_entries.items) |*entry| entry.deinit(alloc);
            value_entries.deinit();
        }
        for (block.column_payloads, 0..) |payload, column_idx| {
            const value_extent = try extents.writeAll(
                alloc,
                store,
                payload,
                effective_chunk_bytes,
            );
            try value_entries.append(.{
                .name = try std.fmt.allocPrint(alloc, "{x:0>8}", .{column_idx}),
                .object_type = .tree,
                .object_id = value_extent.root_id,
            });
        }
        const values_tree_id = try putTree(alloc, store, value_entries.items);

        const stats_payload = try encodeMarketBlockStats(alloc, stats);
        defer alloc.free(stats_payload);
        const stats_id = try store.put(.blob, stats_payload);
        var per_block_entries = [_]TreeEntry{
            .{
                .name = try alloc.dupe(u8, "fingerprints"),
                .object_type = .tree,
                .object_id = fingerprints_extent.root_id,
            },
            .{
                .name = try alloc.dupe(u8, "sequences"),
                .object_type = .tree,
                .object_id = sequences_extent.root_id,
            },
            .{
                .name = try alloc.dupe(u8, "stats"),
                .object_type = .blob,
                .object_id = stats_id,
            },
            .{
                .name = try alloc.dupe(u8, "timestamps"),
                .object_type = .tree,
                .object_id = timestamps_extent.root_id,
            },
            .{
                .name = try alloc.dupe(u8, "values"),
                .object_type = .tree,
                .object_id = values_tree_id,
            },
        };
        defer {
            for (&per_block_entries) |*entry| entry.deinit(alloc);
        }
        const block_tree_id = try putTree(alloc, store, per_block_entries[0..]);
        try block_entries.append(.{
            .name = try std.fmt.allocPrint(alloc, "{x:0>16}", .{block_idx}),
            .object_type = .tree,
            .object_id = block_tree_id,
        });
    }
    if (cursor != bytes.len) return error.CorruptMarketSegment;

    const blocks_tree_id = try putTree(alloc, store, block_entries.items);
    const block_index_id = try store.put(.blob, block_index_payload.items);
    var root_metadata = try rootMetadataFromSegment(
        alloc,
        &parsed.metadata,
        bytes,
        effective_chunk_bytes,
    );
    defer root_metadata.deinit(alloc);

    const meta_payload = try encodeMarketSegmentRootMetadata(alloc, root_metadata);
    defer alloc.free(meta_payload);
    const meta_id = try store.put(.blob, meta_payload);

    var root_entries = [_]TreeEntry{
        .{
            .name = try alloc.dupe(u8, "block_index"),
            .object_type = .blob,
            .object_id = block_index_id,
        },
        .{
            .name = try alloc.dupe(u8, "blocks"),
            .object_type = .tree,
            .object_id = blocks_tree_id,
        },
        .{
            .name = try alloc.dupe(u8, "meta"),
            .object_type = .blob,
            .object_id = meta_id,
        },
    };
    defer {
        for (&root_entries) |*entry| entry.deinit(alloc);
    }
    return try putTree(alloc, store, root_entries[0..]);
}

pub fn inspectSegmentRoot(
    alloc: std.mem.Allocator,
    store: *object_store.ObjectStore,
    root_id: object_store.ObjectId,
) !MarketSegmentRootMetadata {
    var root = try loadMarketRoot(alloc, store, root_id);
    defer root.root_tree.deinit(alloc);
    const metadata = root.metadata;
    root.metadata = undefined;
    return metadata;
}

pub fn validateSegmentRoot(
    alloc: std.mem.Allocator,
    store: *object_store.ObjectStore,
    root_id: object_store.ObjectId,
) !void {
    var metadata = try inspectSegmentRoot(alloc, store, root_id);
    defer metadata.deinit(alloc);
    const bytes = try reconstructSegmentRootBytes(alloc, store, root_id, &metadata);
    alloc.free(bytes);
}

pub fn readAllSegmentRoot(
    alloc: std.mem.Allocator,
    store: *object_store.ObjectStore,
    root_id: object_store.ObjectId,
) !ReadResult {
    return readProjectedRangeSegmentRoot(
        alloc,
        store,
        root_id,
        std.math.minInt(i64),
        std.math.maxInt(i64),
        null,
    );
}

pub fn readProjectedRangeSegmentRoot(
    alloc: std.mem.Allocator,
    store: *object_store.ObjectStore,
    root_id: object_store.ObjectId,
    start_ts_ns: i64,
    end_ts_ns: i64,
    requested_columns: ?[]const []const u8,
) !ReadResult {
    if (start_ts_ns > end_ts_ns) return error.InvalidTimeRange;
    return try readProjectedRangeCas(
        alloc,
        store,
        root_id,
        start_ts_ns,
        end_ts_ns,
        requested_columns,
    );
}

pub fn restoreSegmentRootToLocalMirror(
    alloc: std.mem.Allocator,
    data_dir: std.fs.Dir,
    store: *object_store.ObjectStore,
    root_id: object_store.ObjectId,
) ![]u8 {
    var metadata = try inspectSegmentRoot(alloc, store, root_id);
    defer metadata.deinit(alloc);
    const bytes = try reconstructSegmentRootBytes(alloc, store, root_id, &metadata);
    defer alloc.free(bytes);
    return try writeLocalMirrorBytes(
        alloc,
        data_dir,
        metadata.hour,
        metadata.market_series_id,
        metadata.start_ts_ns,
        metadata.end_ts_ns,
        bytes,
    );
}

pub fn collectSegmentRootObjectIds(
    alloc: std.mem.Allocator,
    store: *object_store.ObjectStore,
    root_id: object_store.ObjectId,
) ![]object_store.ObjectId {
    var out = std.array_list.Managed(object_store.ObjectId).init(alloc);
    errdefer out.deinit();
    try appendUniqueObjectId(&out, root_id);

    try collectTreeObjectIdsRecursive(alloc, store, root_id, &out);
    return try out.toOwnedSlice();
}

const LoadedMarketRoot = struct {
    root_tree: LoadedTree,
    metadata: MarketSegmentRootMetadata,
    block_index_id: object_store.ObjectId,
    blocks_id: object_store.ObjectId,
};

fn loadMarketRoot(
    alloc: std.mem.Allocator,
    store: *object_store.ObjectStore,
    root_id: object_store.ObjectId,
) !LoadedMarketRoot {
    var root_tree = try loadTreeObject(alloc, store, root_id);
    errdefer root_tree.deinit(alloc);
    if (root_tree.entries.len != 3) return error.InvalidMarketSegmentRootTree;
    const meta_id = try findRequiredTreeEntry(
        root_tree.entries,
        "meta",
        .blob,
        error.MissingMarketSegmentRootMeta,
    );
    const block_index_id = try findRequiredTreeEntry(
        root_tree.entries,
        "block_index",
        .blob,
        error.MissingMarketSegmentBlockIndex,
    );
    const blocks_id = try findRequiredTreeEntry(
        root_tree.entries,
        "blocks",
        .tree,
        error.MissingMarketSegmentRootBlocks,
    );
    const meta_payload = try loadBlobObject(alloc, store, meta_id);
    defer alloc.free(meta_payload);
    return .{
        .root_tree = root_tree,
        .metadata = try decodeMarketSegmentRootMetadata(alloc, meta_payload),
        .block_index_id = block_index_id,
        .blocks_id = blocks_id,
    };
}

fn validateBlockTreeEntries(entries: []const TreeEntry, expected_count: u32) !void {
    if (entries.len != expected_count) return error.CorruptMarketSegmentRoot;
    for (entries, 0..) |entry, idx| {
        var expected_name_buf: [16]u8 = undefined;
        const expected_name = try std.fmt.bufPrint(
            &expected_name_buf,
            "{x:0>16}",
            .{idx},
        );
        if (entry.object_type != .tree or !std.mem.eql(u8, entry.name, expected_name)) {
            return error.InvalidMarketSegmentRootTree;
        }
    }
}

fn encodeMarketBlockStatsRecord(
    bytes: *std.array_list.Managed(u8),
    stats: MarketBlockStats,
) !void {
    try appendInt(bytes, u32, stats.count);
    try appendInt(bytes, i64, stats.min_ts_ns);
    try appendInt(bytes, i64, stats.max_ts_ns);
    try appendInt(bytes, u64, stats.timestamp_payload_bytes);
    try appendInt(bytes, u64, stats.sequence_payload_bytes);
    try appendInt(bytes, u64, stats.fingerprint_payload_bytes);
    try appendInt(bytes, u32, @intCast(stats.column_payload_bytes.len));
    for (
        stats.bounds_valid,
        stats.column_mins,
        stats.column_maxs,
        stats.column_payload_bytes,
    ) |bounds_valid, min_value, max_value, size_bytes| {
        try bytes.append(@intFromBool(bounds_valid));
        try appendF64(bytes, min_value);
        try appendF64(bytes, max_value);
        try appendInt(bytes, u64, size_bytes);
    }
}

fn encodeMarketBlockStats(
    alloc: std.mem.Allocator,
    stats: MarketBlockStats,
) ![]u8 {
    var bytes = std.array_list.Managed(u8).init(alloc);
    errdefer bytes.deinit();
    try bytes.append(market_segment_block_stats_version);
    try encodeMarketBlockStatsRecord(&bytes, stats);
    return try bytes.toOwnedSlice();
}

fn decodeMarketBlockStatsRecord(
    alloc: std.mem.Allocator,
    payload: []const u8,
    cursor: *usize,
    expected_column_count: usize,
) !MarketBlockStats {
    const count = try readIntAt(payload, cursor, u32);
    const min_ts_ns = try readIntAt(payload, cursor, i64);
    const max_ts_ns = try readIntAt(payload, cursor, i64);
    const timestamp_payload_bytes = try readIntAt(payload, cursor, u64);
    const sequence_payload_bytes = try readIntAt(payload, cursor, u64);
    const fingerprint_payload_bytes = try readIntAt(payload, cursor, u64);
    const column_count: usize = try readIntAt(payload, cursor, u32);
    if (count == 0 or count > market_segment_block_rows or min_ts_ns > max_ts_ns or
        timestamp_payload_bytes == 0 or sequence_payload_bytes == 0 or
        fingerprint_payload_bytes != @as(u64, count) * @sizeOf(RowFingerprint) or
        column_count != expected_column_count)
    {
        return error.CorruptMarketSegmentRoot;
    }

    const bounds_valid = try alloc.alloc(bool, column_count);
    errdefer alloc.free(bounds_valid);
    const column_mins = try alloc.alloc(f64, column_count);
    errdefer alloc.free(column_mins);
    const column_maxs = try alloc.alloc(f64, column_count);
    errdefer alloc.free(column_maxs);
    const column_payload_bytes = try alloc.alloc(u64, column_count);
    errdefer alloc.free(column_payload_bytes);
    for (0..column_count) |idx| {
        const raw_bounds = try readByteAt(payload, cursor);
        if (raw_bounds > 1) return error.CorruptMarketSegmentRoot;
        bounds_valid[idx] = raw_bounds == 1;
        column_mins[idx] = try readF64At(payload, cursor);
        column_maxs[idx] = try readF64At(payload, cursor);
        column_payload_bytes[idx] = try readIntAt(payload, cursor, u64);
        if (column_payload_bytes[idx] == 0) return error.CorruptMarketSegmentRoot;
        if (bounds_valid[idx]) {
            if (std.math.isNan(column_mins[idx]) or
                std.math.isNan(column_maxs[idx]) or
                column_mins[idx] > column_maxs[idx])
            {
                return error.CorruptMarketSegmentRoot;
            }
        } else if (@as(u64, @bitCast(column_mins[idx])) != 0 or
            @as(u64, @bitCast(column_maxs[idx])) != 0)
        {
            return error.CorruptMarketSegmentRoot;
        }
    }
    return .{
        .count = count,
        .min_ts_ns = min_ts_ns,
        .max_ts_ns = max_ts_ns,
        .bounds_valid = bounds_valid,
        .column_mins = column_mins,
        .column_maxs = column_maxs,
        .timestamp_payload_bytes = timestamp_payload_bytes,
        .sequence_payload_bytes = sequence_payload_bytes,
        .fingerprint_payload_bytes = fingerprint_payload_bytes,
        .column_payload_bytes = column_payload_bytes,
    };
}

fn loadBlockIndex(
    alloc: std.mem.Allocator,
    store: *object_store.ObjectStore,
    id: object_store.ObjectId,
    metadata: *const MarketSegmentRootMetadata,
) ![]MarketBlockStats {
    const payload = try loadBlobObject(alloc, store, id);
    defer alloc.free(payload);
    var cursor: usize = 0;
    if (try readByteAt(payload, &cursor) != market_segment_block_index_version) {
        return error.UnsupportedMarketSegmentBlockIndexVersion;
    }
    const block_count = try readIntAt(payload, &cursor, u32);
    if (block_count != metadata.block_count) return error.CorruptMarketSegmentRoot;
    const blocks = try alloc.alloc(MarketBlockStats, block_count);
    var decoded: usize = 0;
    errdefer {
        for (blocks[0..decoded]) |*stats| stats.deinit(alloc);
        alloc.free(blocks);
    }
    var total_rows: u64 = 0;
    var previous_max: ?i64 = null;
    while (decoded < blocks.len) : (decoded += 1) {
        blocks[decoded] = try decodeMarketBlockStatsRecord(
            alloc,
            payload,
            &cursor,
            metadata.column_names.len,
        );
        const stats = blocks[decoded];
        if (try hourBucket(stats.min_ts_ns) != metadata.hour or
            try hourBucket(stats.max_ts_ns) != metadata.hour)
        {
            return error.CorruptMarketSegmentRoot;
        }
        if (previous_max) |prior| {
            if (stats.min_ts_ns < prior) return error.CorruptMarketSegmentRoot;
        }
        previous_max = stats.max_ts_ns;
        total_rows = std.math.add(u64, total_rows, stats.count) catch
            return error.CorruptMarketSegmentRoot;
    }
    if (cursor != payload.len or total_rows != metadata.count or
        blocks.len == 0 or blocks[0].min_ts_ns != metadata.start_ts_ns or
        blocks[blocks.len - 1].max_ts_ns != metadata.end_ts_ns)
    {
        return error.CorruptMarketSegmentRoot;
    }
    return blocks;
}

fn decodeMarketBlockStats(
    alloc: std.mem.Allocator,
    payload: []const u8,
    expected_column_count: usize,
) !MarketBlockStats {
    var cursor: usize = 0;
    if (try readByteAt(payload, &cursor) != market_segment_block_stats_version) {
        return error.UnsupportedMarketSegmentBlockStatsVersion;
    }
    var stats = try decodeMarketBlockStatsRecord(
        alloc,
        payload,
        &cursor,
        expected_column_count,
    );
    errdefer stats.deinit(alloc);
    if (cursor != payload.len) return error.ExtraObjectBytes;
    return stats;
}

fn marketBlockStatsEql(lhs: MarketBlockStats, rhs: MarketBlockStats) bool {
    if (lhs.count != rhs.count or lhs.min_ts_ns != rhs.min_ts_ns or
        lhs.max_ts_ns != rhs.max_ts_ns or
        lhs.timestamp_payload_bytes != rhs.timestamp_payload_bytes or
        lhs.sequence_payload_bytes != rhs.sequence_payload_bytes or
        lhs.fingerprint_payload_bytes != rhs.fingerprint_payload_bytes or
        lhs.bounds_valid.len != rhs.bounds_valid.len or
        lhs.column_payload_bytes.len != rhs.column_payload_bytes.len)
    {
        return false;
    }
    for (
        lhs.bounds_valid,
        lhs.column_mins,
        lhs.column_maxs,
        lhs.column_payload_bytes,
        rhs.bounds_valid,
        rhs.column_mins,
        rhs.column_maxs,
        rhs.column_payload_bytes,
    ) |lb, lmin, lmax, lsize, rb, rmin, rmax, rsize| {
        if (lb != rb or
            @as(u64, @bitCast(lmin)) != @as(u64, @bitCast(rmin)) or
            @as(u64, @bitCast(lmax)) != @as(u64, @bitCast(rmax)) or
            lsize != rsize)
        {
            return false;
        }
    }
    return true;
}

fn loadCasBlock(
    alloc: std.mem.Allocator,
    store: *object_store.ObjectStore,
    block_entry: TreeEntry,
    expected: *const MarketBlockStats,
    extent_chunk_bytes: u32,
) !CasBlock {
    if (block_entry.object_type != .tree) return error.InvalidMarketSegmentBlockTree;
    var tree = try loadTreeObject(alloc, store, block_entry.object_id);
    defer tree.deinit(alloc);
    if (tree.entries.len != 5) return error.InvalidMarketSegmentBlockTree;
    const stats_id = try findRequiredTreeEntry(
        tree.entries,
        "stats",
        .blob,
        error.MissingMarketSegmentBlockStats,
    );
    const timestamps_id = try findRequiredTreeEntry(
        tree.entries,
        "timestamps",
        .tree,
        error.MissingMarketSegmentTimestamps,
    );
    const sequences_id = try findRequiredTreeEntry(
        tree.entries,
        "sequences",
        .tree,
        error.MissingMarketSegmentSequences,
    );
    const fingerprints_id = try findRequiredTreeEntry(
        tree.entries,
        "fingerprints",
        .tree,
        error.MissingMarketSegmentFingerprints,
    );
    const values_id = try findRequiredTreeEntry(
        tree.entries,
        "values",
        .tree,
        error.MissingMarketSegmentValues,
    );
    const stats_payload = try loadBlobObject(alloc, store, stats_id);
    defer alloc.free(stats_payload);
    var stats = try decodeMarketBlockStats(
        alloc,
        stats_payload,
        expected.column_payload_bytes.len,
    );
    errdefer stats.deinit(alloc);
    if (!marketBlockStatsEql(stats, expected.*)) return error.MarketSegmentBlockIndexMismatch;

    var values_tree = try loadTreeObject(alloc, store, values_id);
    defer values_tree.deinit(alloc);
    if (values_tree.entries.len != expected.column_payload_bytes.len) {
        return error.InvalidMarketSegmentValuesTree;
    }
    const value_trees = try alloc.alloc(extents.WriteResult, values_tree.entries.len);
    errdefer alloc.free(value_trees);
    for (values_tree.entries, 0..) |entry, idx| {
        var expected_name_buf: [8]u8 = undefined;
        const expected_name = try std.fmt.bufPrint(&expected_name_buf, "{x:0>8}", .{idx});
        if (entry.object_type != .tree or !std.mem.eql(u8, entry.name, expected_name)) {
            return error.InvalidMarketSegmentValuesTree;
        }
        value_trees[idx] = .{
            .root_id = entry.object_id,
            .size_bytes = expected.column_payload_bytes[idx],
            .chunk_bytes = extent_chunk_bytes,
        };
    }
    return .{
        .stats = stats,
        .timestamp_tree = .{
            .root_id = timestamps_id,
            .size_bytes = expected.timestamp_payload_bytes,
            .chunk_bytes = extent_chunk_bytes,
        },
        .sequence_tree = .{
            .root_id = sequences_id,
            .size_bytes = expected.sequence_payload_bytes,
            .chunk_bytes = extent_chunk_bytes,
        },
        .fingerprint_tree = .{
            .root_id = fingerprints_id,
            .size_bytes = expected.fingerprint_payload_bytes,
            .chunk_bytes = extent_chunk_bytes,
        },
        .value_trees = value_trees,
    };
}

const CasBlockPayloads = struct {
    timestamps: []u8,
    sequences: []u8,
    fingerprints: []u8,
    columns: [][]const u8,

    fn deinit(self: *CasBlockPayloads, alloc: std.mem.Allocator) void {
        alloc.free(self.timestamps);
        alloc.free(self.sequences);
        alloc.free(self.fingerprints);
        for (self.columns) |column| {
            if (column.len != 0) alloc.free(@constCast(column));
        }
        alloc.free(self.columns);
    }
};

fn readCasBlockPayloads(
    alloc: std.mem.Allocator,
    store: *object_store.ObjectStore,
    block: MarketSegmentBlockView,
    selected_columns: ?[]const usize,
) !CasBlockPayloads {
    const timestamps = try extents.readAll(alloc, store, block.timestamp_tree);
    errdefer alloc.free(timestamps);
    const sequences = try extents.readAll(alloc, store, block.sequence_tree);
    errdefer alloc.free(sequences);
    const fingerprints = try extents.readAll(alloc, store, block.fingerprint_tree);
    errdefer alloc.free(fingerprints);
    const columns = try alloc.alloc([]const u8, block.value_trees.len);
    errdefer alloc.free(columns);
    @memset(columns, &[_]u8{});
    var loaded_count: usize = 0;
    errdefer {
        if (selected_columns) |indices| {
            for (indices[0..loaded_count]) |idx| alloc.free(@constCast(columns[idx]));
        } else {
            for (columns[0..loaded_count]) |payload| alloc.free(@constCast(payload));
        }
    }
    if (selected_columns) |indices| {
        for (indices) |idx| {
            columns[idx] = try extents.readAll(alloc, store, block.value_trees[idx]);
            loaded_count += 1;
        }
    } else {
        for (columns, block.value_trees) |*payload, tree| {
            payload.* = try extents.readAll(alloc, store, tree);
            loaded_count += 1;
        }
    }
    return .{
        .timestamps = timestamps,
        .sequences = sequences,
        .fingerprints = fingerprints,
        .columns = columns,
    };
}

fn parsedBlockFromPayloads(
    block: MarketSegmentBlockView,
    payloads: CasBlockPayloads,
) ParsedBlock {
    return .{
        .next_offset = 0,
        .count = block.count,
        .min_ts_ns = block.min_ts_ns,
        .max_ts_ns = block.max_ts_ns,
        .bounds_valid = block.bounds_valid,
        .column_mins = block.column_mins,
        .column_maxs = block.column_maxs,
        .timestamp_payload = payloads.timestamps,
        .sequence_payload = payloads.sequences,
        .fingerprint_payload = payloads.fingerprints,
        .column_payloads = payloads.columns,
    };
}

fn appendEncodedBlockFromPayloads(
    destination: *std.array_list.Managed(u8),
    block: MarketSegmentBlockView,
    payloads: CasBlockPayloads,
) !void {
    var body = std.array_list.Managed(u8).init(destination.allocator);
    defer body.deinit();
    try appendInt(&body, u32, block.count);
    try appendInt(&body, i64, block.min_ts_ns);
    try appendInt(&body, i64, block.max_ts_ns);
    try appendInt(&body, u32, @intCast(payloads.timestamps.len));
    try appendInt(&body, u32, @intCast(payloads.sequences.len));
    try appendInt(&body, u32, @intCast(payloads.fingerprints.len));
    for (
        block.bounds_valid,
        block.column_mins,
        block.column_maxs,
        payloads.columns,
    ) |bounds_valid, min_value, max_value, payload| {
        if (payload.len == 0) return error.MissingMarketSegmentColumn;
        try body.append(@intFromBool(bounds_valid));
        try appendF64(&body, min_value);
        try appendF64(&body, max_value);
        try appendInt(&body, u32, @intCast(payload.len));
    }
    try body.appendSlice(payloads.timestamps);
    try body.appendSlice(payloads.sequences);
    try body.appendSlice(payloads.fingerprints);
    for (payloads.columns) |payload| try body.appendSlice(payload);
    try destination.appendSlice(block_magic);
    try appendInt(destination, u32, @intCast(body.items.len));
    try destination.appendSlice(body.items);
    try appendInt(destination, u32, checksum(body.items));
}

fn encodeHeaderFromRoot(
    bytes: *std.array_list.Managed(u8),
    metadata: *const MarketSegmentRootMetadata,
) !void {
    try appendInt(bytes, u64, metadata.market_series_id);
    try bytes.appendSlice(&metadata.schema_digest);
    try appendInt(bytes, i64, metadata.hour);
    try appendInt(bytes, u64, metadata.count);
    try appendInt(bytes, i64, metadata.start_ts_ns);
    try appendInt(bytes, i64, metadata.end_ts_ns);
    try appendInt(bytes, u32, metadata.block_rows);
    try appendInt(bytes, u32, metadata.block_count);
    try appendInt(bytes, u32, @intCast(metadata.column_names.len));
    try appendInt(bytes, u32, @intCast(metadata.metric.len));
    try appendInt(bytes, u32, @intCast(metadata.canonical_labels.len));
    try bytes.appendSlice(metadata.metric);
    try bytes.appendSlice(metadata.canonical_labels);
    for (metadata.column_names) |name| try appendString(bytes, name);
}

fn metadataFromRoot(
    alloc: std.mem.Allocator,
    root: *const MarketSegmentRootMetadata,
) !Metadata {
    const metric = try alloc.dupe(u8, root.metric);
    errdefer alloc.free(metric);
    const canonical_labels = try alloc.dupe(u8, root.canonical_labels);
    errdefer alloc.free(canonical_labels);
    const column_names = try alloc.alloc([]u8, root.column_names.len);
    errdefer alloc.free(column_names);
    var copied: usize = 0;
    errdefer for (column_names[0..copied]) |name| alloc.free(name);
    for (root.column_names, 0..) |name, idx| {
        column_names[idx] = try alloc.dupe(u8, name);
        copied += 1;
    }
    return .{
        .market_series_id = root.market_series_id,
        .schema_digest = root.schema_digest,
        .metric = metric,
        .canonical_labels = canonical_labels,
        .hour = root.hour,
        .count = root.count,
        .start_ts_ns = root.start_ts_ns,
        .end_ts_ns = root.end_ts_ns,
        .block_count = root.block_count,
        .column_names = column_names,
    };
}

fn viewFromCasBlock(index: usize, block: *const CasBlock) MarketSegmentBlockView {
    return .{
        .index = @intCast(index),
        .count = block.stats.count,
        .min_ts_ns = block.stats.min_ts_ns,
        .max_ts_ns = block.stats.max_ts_ns,
        .bounds_valid = block.stats.bounds_valid,
        .column_mins = block.stats.column_mins,
        .column_maxs = block.stats.column_maxs,
        .timestamp_payload_bytes = block.stats.timestamp_payload_bytes,
        .sequence_payload_bytes = block.stats.sequence_payload_bytes,
        .fingerprint_payload_bytes = block.stats.fingerprint_payload_bytes,
        .column_payload_bytes = block.stats.column_payload_bytes,
        .timestamp_tree = block.timestamp_tree,
        .sequence_tree = block.sequence_tree,
        .fingerprint_tree = block.fingerprint_tree,
        .value_trees = block.value_trees,
    };
}

fn readProjectedRangeCas(
    alloc: std.mem.Allocator,
    store: *object_store.ObjectStore,
    root_id: object_store.ObjectId,
    start_ts_ns: i64,
    end_ts_ns: i64,
    requested_columns: ?[]const []const u8,
) !ReadResult {
    var cursor = try MarketSegmentBlockCursor.open(alloc, store, root_id);
    defer cursor.deinit();
    var metadata = try metadataFromRoot(alloc, &cursor.metadata);
    errdefer metadata.deinit(alloc);
    const selected_indices = try resolveProjection(alloc, &metadata, requested_columns);
    defer alloc.free(selected_indices);

    var candidates = std.array_list.Managed(CandidateRow).init(alloc);
    defer {
        for (candidates.items) |*candidate| candidate.deinit(alloc);
        candidates.deinit();
    }
    var candidate_by_timestamp = std.AutoHashMap(i64, usize).init(alloc);
    defer candidate_by_timestamp.deinit();
    var stats = ReadStats{ .blocks_total = cursor.metadata.block_count };

    for (cursor.block_index, 0..) |block_stats, block_idx| {
        if (block_stats.max_ts_ns < start_ts_ns or block_stats.min_ts_ns > end_ts_ns) {
            stats.blocks_pruned += 1;
            continue;
        }
        var cas_block = try loadCasBlock(
            alloc,
            store,
            cursor.blocks[block_idx],
            &block_stats,
            cursor.metadata.extent_chunk_bytes,
        );
        defer cas_block.deinit(alloc);
        const view = viewFromCasBlock(block_idx, &cas_block);
        var payloads = try readCasBlockPayloads(
            alloc,
            store,
            view,
            selected_indices,
        );
        defer payloads.deinit(alloc);
        const block = parsedBlockFromPayloads(view, payloads);
        const timestamps = try decodeTimestamps(alloc, block);
        defer alloc.free(timestamps);
        const sequences = try decodeSequences(alloc, block);
        defer alloc.free(sequences);
        try validateKeyOrder(metadata.hour, timestamps, sequences);

        var decoded_columns = try alloc.alloc([]f64, selected_indices.len);
        defer alloc.free(decoded_columns);
        var decoded_count: usize = 0;
        defer {
            for (decoded_columns[0..decoded_count]) |values| alloc.free(values);
        }
        for (selected_indices, 0..) |column_idx, selected_idx| {
            decoded_columns[selected_idx] = try decodeColumn(alloc, block, column_idx);
            decoded_count += 1;
        }

        stats.blocks_scanned += 1;
        stats.columns_decoded += selected_indices.len;
        stats.bytes_decoded += block_stats.timestamp_payload_bytes +
            block_stats.sequence_payload_bytes +
            block_stats.fingerprint_payload_bytes;
        for (selected_indices) |column_idx| {
            stats.bytes_decoded += block_stats.column_payload_bytes[column_idx];
        }

        for (timestamps, 0..) |ts_ns, row_idx| {
            if (ts_ns < start_ts_ns or ts_ns > end_ts_ns) continue;
            const sequence = sequences[row_idx];
            const fingerprint = readFingerprint(payloads.fingerprints, row_idx);
            if (candidate_by_timestamp.get(ts_ns)) |candidate_idx| {
                const current = &candidates.items[candidate_idx];
                if (sequence < current.write_sequence) continue;
                if (sequence == current.write_sequence) {
                    if (!std.mem.eql(u8, &fingerprint, &current.fingerprint)) {
                        return error.DuplicateWriteSequenceConflict;
                    }
                    continue;
                }
                current.write_sequence = sequence;
                current.fingerprint = fingerprint;
                for (decoded_columns, 0..) |values, selected_idx| {
                    current.values[selected_idx] = values[row_idx];
                }
                continue;
            }

            const projected_values = try alloc.alloc(f64, selected_indices.len);
            errdefer alloc.free(projected_values);
            for (decoded_columns, 0..) |values, selected_idx| {
                projected_values[selected_idx] = values[row_idx];
            }
            const candidate_idx = candidates.items.len;
            try candidates.append(.{
                .ts_ns = ts_ns,
                .write_sequence = sequence,
                .fingerprint = fingerprint,
                .values = projected_values,
            });
            errdefer {
                var removed = candidates.pop().?;
                removed.deinit(alloc);
            }
            try candidate_by_timestamp.put(ts_ns, candidate_idx);
        }
    }

    std.sort.block(CandidateRow, candidates.items, {}, struct {
        fn lessThan(_: void, lhs: CandidateRow, rhs: CandidateRow) bool {
            return lhs.ts_ns < rhs.ts_ns;
        }
    }.lessThan);
    const timestamps = try alloc.alloc(i64, candidates.items.len);
    errdefer alloc.free(timestamps);
    const sequences = try alloc.alloc(u64, candidates.items.len);
    errdefer alloc.free(sequences);
    const fingerprints = try alloc.alloc(RowFingerprint, candidates.items.len);
    errdefer alloc.free(fingerprints);
    const columns = try alloc.alloc(ProjectedColumn, selected_indices.len);
    errdefer alloc.free(columns);
    var initialized_columns: usize = 0;
    errdefer for (columns[0..initialized_columns]) |*column| column.deinit(alloc);
    for (selected_indices, 0..) |column_idx, selected_idx| {
        const name = try alloc.dupe(u8, metadata.column_names[column_idx]);
        errdefer alloc.free(name);
        columns[selected_idx] = .{
            .name = name,
            .values = try alloc.alloc(f64, candidates.items.len),
        };
        initialized_columns += 1;
    }
    for (candidates.items, 0..) |candidate, row_idx| {
        timestamps[row_idx] = candidate.ts_ns;
        sequences[row_idx] = candidate.write_sequence;
        fingerprints[row_idx] = candidate.fingerprint;
        for (columns, 0..) |*column, selected_idx| {
            column.values[row_idx] = candidate.values[selected_idx];
        }
    }
    return .{
        .metadata = metadata,
        .timestamps = timestamps,
        .write_sequences = sequences,
        .row_fingerprints = fingerprints,
        .columns = columns,
        .stats = stats,
    };
}

fn collectTreeObjectIdsRecursive(
    alloc: std.mem.Allocator,
    store: *object_store.ObjectStore,
    tree_id: object_store.ObjectId,
    out: *std.array_list.Managed(object_store.ObjectId),
) !void {
    const loaded = try store.get(alloc, tree_id);
    defer alloc.free(loaded.payload);
    if (loaded.obj_type != .tree) return error.InvalidMarketSegmentRootTree;
    const entries = try decodeTree(alloc, loaded.payload);
    defer {
        for (entries) |*entry| entry.deinit(alloc);
        alloc.free(entries);
    }
    for (entries) |entry| {
        const prior_len = out.items.len;
        try appendUniqueObjectId(out, entry.object_id);
        if (entry.object_type == .tree and out.items.len != prior_len) {
            try collectTreeObjectIdsRecursive(alloc, store, entry.object_id, out);
        } else if (entry.object_type != .tree and entry.object_type != .blob) {
            return error.InvalidMarketSegmentRootTree;
        }
    }
}

fn readProjectedRangeInternal(
    alloc: std.mem.Allocator,
    data_dir: std.fs.Dir,
    path: []const u8,
    start_ts_ns: i64,
    end_ts_ns: i64,
    requested_columns: ?[]const []const u8,
) !ReadResult {
    if (start_ts_ns > end_ts_ns) return error.InvalidTimeRange;

    const bytes = try readFileAlloc(alloc, data_dir, path);
    defer alloc.free(bytes);
    return try readProjectedRangeBytes(
        alloc,
        bytes,
        start_ts_ns,
        end_ts_ns,
        requested_columns,
    );
}

fn readProjectedRangeBytes(
    alloc: std.mem.Allocator,
    bytes: []const u8,
    start_ts_ns: i64,
    end_ts_ns: i64,
    requested_columns: ?[]const []const u8,
) !ReadResult {
    var parsed = try parseHeader(alloc, bytes);
    errdefer parsed.metadata.deinit(alloc);

    const selected_indices = try resolveProjection(alloc, &parsed.metadata, requested_columns);
    defer alloc.free(selected_indices);

    var candidates = std.array_list.Managed(CandidateRow).init(alloc);
    defer {
        for (candidates.items) |*candidate| candidate.deinit(alloc);
        candidates.deinit();
    }
    var candidate_by_timestamp = std.AutoHashMap(i64, usize).init(alloc);
    defer candidate_by_timestamp.deinit();

    var stats = ReadStats{ .blocks_total = parsed.metadata.block_count };
    var cursor = parsed.blocks_offset;
    var total_rows: u64 = 0;
    var observed_start: ?i64 = null;
    var observed_end: ?i64 = null;
    var previous_block_max: ?i64 = null;
    var block_idx: u32 = 0;
    while (block_idx < parsed.metadata.block_count) : (block_idx += 1) {
        var block = try parseBlock(alloc, bytes, cursor, parsed.metadata.column_names.len);
        defer block.deinit(alloc);
        cursor = block.next_offset;
        total_rows = std.math.add(u64, total_rows, block.count) catch return error.CorruptMarketSegment;
        if (try hourBucket(block.min_ts_ns) != parsed.metadata.hour or
            try hourBucket(block.max_ts_ns) != parsed.metadata.hour)
        {
            return error.CorruptMarketSegment;
        }
        if (previous_block_max) |previous_max| {
            if (block.min_ts_ns < previous_max) return error.CorruptMarketSegment;
        }
        previous_block_max = block.max_ts_ns;

        if (block_idx == 0) observed_start = block.min_ts_ns;
        observed_end = block.max_ts_ns;
        if (block.max_ts_ns < start_ts_ns or block.min_ts_ns > end_ts_ns) {
            stats.blocks_pruned += 1;
            continue;
        }

        stats.blocks_scanned += 1;
        stats.columns_decoded += selected_indices.len;
        stats.bytes_decoded += block.timestamp_payload.len +
            block.sequence_payload.len +
            block.fingerprint_payload.len;
        for (selected_indices) |column_idx| {
            stats.bytes_decoded += block.column_payloads[column_idx].len;
        }

        const timestamps = try decodeTimestamps(alloc, block);
        defer alloc.free(timestamps);
        const sequences = try decodeSequences(alloc, block);
        defer alloc.free(sequences);
        try validateKeyOrder(parsed.metadata.hour, timestamps, sequences);

        var decoded_columns = try alloc.alloc([]f64, selected_indices.len);
        defer alloc.free(decoded_columns);
        var decoded_count: usize = 0;
        defer {
            for (decoded_columns[0..decoded_count]) |values| alloc.free(values);
        }
        for (selected_indices, 0..) |column_idx, selected_idx| {
            const values = try decodeColumn(alloc, block, column_idx);
            decoded_columns[selected_idx] = values;
            decoded_count += 1;
        }

        for (timestamps, 0..) |ts_ns, row_idx| {
            if (ts_ns < start_ts_ns or ts_ns > end_ts_ns) continue;

            const sequence = sequences[row_idx];
            const fingerprint = readFingerprint(block.fingerprint_payload, row_idx);
            if (candidate_by_timestamp.get(ts_ns)) |candidate_idx| {
                const current = &candidates.items[candidate_idx];
                if (sequence < current.write_sequence) continue;
                if (sequence == current.write_sequence) {
                    if (!std.mem.eql(u8, &fingerprint, &current.fingerprint))
                        return error.DuplicateWriteSequenceConflict;
                    continue;
                }
                current.write_sequence = sequence;
                current.fingerprint = fingerprint;
                for (decoded_columns, 0..) |column, selected_idx| {
                    current.values[selected_idx] = column[row_idx];
                }
                continue;
            }

            const projected_values = try alloc.alloc(f64, selected_indices.len);
            errdefer alloc.free(projected_values);
            for (decoded_columns, 0..) |column, selected_idx| {
                projected_values[selected_idx] = column[row_idx];
            }
            const candidate_idx = candidates.items.len;
            try candidates.append(.{
                .ts_ns = ts_ns,
                .write_sequence = sequence,
                .fingerprint = fingerprint,
                .values = projected_values,
            });
            errdefer {
                var removed = candidates.pop().?;
                removed.deinit(alloc);
            }
            try candidate_by_timestamp.put(ts_ns, candidate_idx);
        }
    }

    if (cursor != bytes.len or total_rows != parsed.metadata.count or
        observed_start == null or observed_end == null or
        observed_start.? != parsed.metadata.start_ts_ns or
        observed_end.? != parsed.metadata.end_ts_ns)
    {
        return error.CorruptMarketSegment;
    }

    std.sort.block(CandidateRow, candidates.items, {}, struct {
        fn lessThan(_: void, lhs: CandidateRow, rhs: CandidateRow) bool {
            return lhs.ts_ns < rhs.ts_ns;
        }
    }.lessThan);

    const timestamps = try alloc.alloc(i64, candidates.items.len);
    errdefer alloc.free(timestamps);
    const sequences = try alloc.alloc(u64, candidates.items.len);
    errdefer alloc.free(sequences);
    const fingerprints = try alloc.alloc(RowFingerprint, candidates.items.len);
    errdefer alloc.free(fingerprints);
    var columns = try alloc.alloc(ProjectedColumn, selected_indices.len);
    errdefer alloc.free(columns);
    var initialized_columns: usize = 0;
    errdefer {
        for (columns[0..initialized_columns]) |*column| column.deinit(alloc);
    }
    for (selected_indices, 0..) |column_idx, selected_idx| {
        const name = try alloc.dupe(u8, parsed.metadata.column_names[column_idx]);
        errdefer alloc.free(name);
        const values = try alloc.alloc(f64, candidates.items.len);
        columns[selected_idx] = .{
            .name = name,
            .values = values,
        };
        initialized_columns += 1;
    }
    for (candidates.items, 0..) |candidate, row_idx| {
        timestamps[row_idx] = candidate.ts_ns;
        sequences[row_idx] = candidate.write_sequence;
        fingerprints[row_idx] = candidate.fingerprint;
        for (columns, 0..) |*column, selected_idx| {
            column.values[row_idx] = candidate.values[selected_idx];
        }
    }

    return .{
        .metadata = parsed.metadata,
        .timestamps = timestamps,
        .write_sequences = sequences,
        .row_fingerprints = fingerprints,
        .columns = columns,
        .stats = stats,
    };
}

fn validateWriteInput(
    alloc: std.mem.Allocator,
    metadata: MetadataView,
    rows: []const MarketRowView,
) !void {
    if (rows.len == 0) return error.EmptyMarketSegment;
    if (metadata.metric.len == 0 or metadata.metric.len > max_metadata_string_bytes) {
        return error.InvalidMarketMetadata;
    }
    market_identity.validateSchemaShape(
        metadata.metric,
        metadata.column_names,
        &.{},
    ) catch return error.InvalidMarketSchema;
    if (metadata.canonical_labels.len == 0 or metadata.canonical_labels.len > max_metadata_string_bytes) {
        return error.InvalidMarketMetadata;
    }
    const canonical_labels = market_identity.canonicalizeLabels(
        alloc,
        metadata.canonical_labels,
    ) catch return error.InvalidCanonicalMarketLabels;
    defer alloc.free(canonical_labels);
    if (!std.mem.eql(u8, canonical_labels, metadata.canonical_labels)) {
        return error.NonCanonicalMarketLabels;
    }
    if (metadata.market_series_id !=
        market_identity.seriesId(metadata.metric, metadata.canonical_labels))
    {
        return error.MarketSeriesIdMismatch;
    }
    if (metadata.column_names.len == 0 or
        metadata.column_names.len > market_identity.max_market_columns)
    {
        return error.InvalidMarketSchema;
    }
    for (metadata.column_names, 0..) |name, idx| {
        if (name.len == 0 or name.len > max_metadata_string_bytes) {
            return error.InvalidMarketSchema;
        }
        for (metadata.column_names[0..idx]) |previous| {
            if (std.mem.eql(u8, name, previous)) return error.DuplicateMarketColumn;
        }
    }

    var previous: ?MarketRowView = null;
    for (rows) |row| {
        market_identity.validateValueShape(
            metadata.column_names.len,
            row.values.len,
        ) catch return error.MarketColumnCountMismatch;
        if (try hourBucket(row.ts_ns) != metadata.hour) return error.MarketRowOutsideHour;
        if (previous) |prior| {
            if (row.ts_ns < prior.ts_ns or
                (row.ts_ns == prior.ts_ns and row.write_sequence < prior.write_sequence))
            {
                return error.UnsortedMarketRows;
            }
            if (row.ts_ns == prior.ts_ns and
                row.write_sequence == prior.write_sequence and
                !rowBitsEqual(row.values, prior.values))
            {
                return error.DuplicateWriteSequenceConflict;
            }
        }
        previous = row;
    }
    if (rows.len > std.math.maxInt(u32) * @as(u64, market_segment_block_rows)) {
        return error.MarketSegmentTooLarge;
    }
}

fn encodeHeader(
    bytes: *std.array_list.Managed(u8),
    metadata: MetadataView,
    rows: []const MarketRowView,
) !void {
    try appendInt(bytes, u64, metadata.market_series_id);
    try bytes.appendSlice(&metadata.schema_digest);
    try appendInt(bytes, i64, metadata.hour);
    try appendInt(bytes, u64, rows.len);
    try appendInt(bytes, i64, rows[0].ts_ns);
    try appendInt(bytes, i64, rows[rows.len - 1].ts_ns);
    try appendInt(bytes, u32, market_segment_block_rows);
    try appendInt(bytes, u32, @intCast(std.math.divCeil(usize, rows.len, market_segment_block_rows) catch unreachable));
    try appendInt(bytes, u32, @intCast(metadata.column_names.len));
    try appendInt(bytes, u32, @intCast(metadata.metric.len));
    try appendInt(bytes, u32, @intCast(metadata.canonical_labels.len));
    try bytes.appendSlice(metadata.metric);
    try bytes.appendSlice(metadata.canonical_labels);
    for (metadata.column_names) |name| try appendString(bytes, name);
}

fn encodeBlock(
    alloc: std.mem.Allocator,
    destination: *std.array_list.Managed(u8),
    column_count: usize,
    rows: []const MarketRowView,
) !void {
    std.debug.assert(rows.len > 0 and rows.len <= market_segment_block_rows);

    const timestamp_payload = try encodeTimestamps(alloc, rows);
    defer alloc.free(timestamp_payload);

    var sequence_payload = std.array_list.Managed(u8).init(alloc);
    defer sequence_payload.deinit();
    for (rows) |row| try appendU64Varint(&sequence_payload, row.write_sequence);

    var fingerprint_payload = std.array_list.Managed(u8).init(alloc);
    defer fingerprint_payload.deinit();
    for (rows) |row| {
        const fingerprint = fingerprintRow(row.values);
        try fingerprint_payload.appendSlice(&fingerprint);
    }

    var column_payloads = try alloc.alloc([]u8, column_count);
    defer alloc.free(column_payloads);
    const bounds_valid = try alloc.alloc(bool, column_count);
    defer alloc.free(bounds_valid);
    var column_mins = try alloc.alloc(f64, column_count);
    defer alloc.free(column_mins);
    var column_maxs = try alloc.alloc(f64, column_count);
    defer alloc.free(column_maxs);
    var encoded_columns: usize = 0;
    defer {
        for (column_payloads[0..encoded_columns]) |payload| alloc.free(payload);
    }

    for (0..column_count) |column_idx| {
        var values = try alloc.alloc(f64, rows.len);
        defer alloc.free(values);
        var min_value: f64 = 0;
        var max_value: f64 = 0;
        var has_bounds = false;
        for (rows, 0..) |row, row_idx| {
            const value = row.values[column_idx];
            values[row_idx] = value;
            if (!std.math.isNan(value)) {
                if (!has_bounds) {
                    min_value = value;
                    max_value = value;
                    has_bounds = true;
                } else {
                    if (value < min_value) min_value = value;
                    if (value > max_value) max_value = value;
                }
            }
        }
        bounds_valid[column_idx] = has_bounds;
        column_mins[column_idx] = min_value;
        column_maxs[column_idx] = max_value;

        var payload = std.array_list.Managed(u8).init(alloc);
        errdefer payload.deinit();
        try gorilla.encodeF64(payload.writer(), values);
        column_payloads[column_idx] = try payload.toOwnedSlice();
        encoded_columns += 1;
    }

    var body = std.array_list.Managed(u8).init(alloc);
    defer body.deinit();
    try appendInt(&body, u32, @intCast(rows.len));
    try appendInt(&body, i64, rows[0].ts_ns);
    try appendInt(&body, i64, rows[rows.len - 1].ts_ns);
    try appendInt(&body, u32, @intCast(timestamp_payload.len));
    try appendInt(&body, u32, @intCast(sequence_payload.items.len));
    try appendInt(&body, u32, @intCast(fingerprint_payload.items.len));
    for (0..column_count) |idx| {
        try body.append(@intFromBool(bounds_valid[idx]));
        try appendF64(&body, column_mins[idx]);
        try appendF64(&body, column_maxs[idx]);
        try appendInt(&body, u32, @intCast(column_payloads[idx].len));
    }
    try body.appendSlice(timestamp_payload);
    try body.appendSlice(sequence_payload.items);
    try body.appendSlice(fingerprint_payload.items);
    for (column_payloads) |payload| try body.appendSlice(payload);

    try destination.appendSlice(block_magic);
    try appendInt(destination, u32, @intCast(body.items.len));
    try destination.appendSlice(body.items);
    try appendInt(destination, u32, checksum(body.items));
}

fn encodeTimestamps(alloc: std.mem.Allocator, rows: []const MarketRowView) ![]u8 {
    var points = try alloc.alloc(types.Point, rows.len);
    defer alloc.free(points);
    for (rows, 0..) |row, idx| {
        points[idx] = .{ .ts = row.ts_ns, .value = 0 };
    }

    var payload = std.array_list.Managed(u8).init(alloc);
    errdefer payload.deinit();
    try gorilla.encodeTsDoD(payload.writer(), rows[0].ts_ns, points);
    return try payload.toOwnedSlice();
}

fn writeLocalMirrorBytes(
    alloc: std.mem.Allocator,
    data_dir: std.fs.Dir,
    hour: i64,
    market_series_id: MarketSeriesId,
    start_ts_ns: i64,
    end_ts_ns: i64,
    bytes: []const u8,
) ![]u8 {
    const file_content_id = contentId(bytes);
    const hour_dir = try std.fmt.allocPrint(alloc, "market_segments/{d}", .{hour});
    defer alloc.free(hour_dir);
    try data_dir.makePath(hour_dir);

    const path = try std.fmt.allocPrint(
        alloc,
        "{s}/{x}-{d}-{d}-{x}.mseg",
        .{ hour_dir, market_series_id, start_ts_ns, end_ts_ns, file_content_id },
    );
    errdefer alloc.free(path);

    if (try existingFileMatches(data_dir, path, bytes)) return path;

    const temp_path = try std.fmt.allocPrint(
        alloc,
        "{s}.tmp-{d}",
        .{ path, std.time.nanoTimestamp() },
    );
    defer alloc.free(temp_path);
    errdefer data_dir.deleteFile(temp_path) catch {};

    {
        var file = try data_dir.createFile(temp_path, .{ .exclusive = true });
        defer file.close();
        try file.writeAll(bytes);
        try file.sync();
    }
    data_dir.rename(temp_path, path) catch |err| switch (err) {
        error.PathAlreadyExists => {
            try data_dir.deleteFile(temp_path);
            if (!try existingFileMatches(data_dir, path, bytes)) {
                return error.ImmutableSegmentConflict;
            }
        },
        else => return err,
    };

    return path;
}

fn rootMetadataFromSegment(
    alloc: std.mem.Allocator,
    metadata: *const Metadata,
    bytes: []const u8,
    extent_chunk_bytes: u32,
) !MarketSegmentRootMetadata {
    const metric = try alloc.dupe(u8, metadata.metric);
    errdefer alloc.free(metric);
    const canonical_labels = try alloc.dupe(u8, metadata.canonical_labels);
    errdefer alloc.free(canonical_labels);
    const column_names = try alloc.alloc([]u8, metadata.column_names.len);
    errdefer alloc.free(column_names);
    var copied: usize = 0;
    errdefer {
        for (column_names[0..copied]) |name| alloc.free(name);
    }
    for (metadata.column_names, 0..) |name, idx| {
        column_names[idx] = try alloc.dupe(u8, name);
        copied += 1;
    }
    return .{
        .market_series_id = metadata.market_series_id,
        .schema_digest = metadata.schema_digest,
        .metric = metric,
        .canonical_labels = canonical_labels,
        .hour = metadata.hour,
        .count = metadata.count,
        .start_ts_ns = metadata.start_ts_ns,
        .end_ts_ns = metadata.end_ts_ns,
        .block_rows = market_segment_block_rows,
        .block_count = metadata.block_count,
        .column_names = column_names,
        .file_size = bytes.len,
        .content_hash = hashBytes(bytes),
        .extent_chunk_bytes = extent_chunk_bytes,
    };
}

fn reconstructSegmentRootBytes(
    alloc: std.mem.Allocator,
    store: *object_store.ObjectStore,
    root_id: object_store.ObjectId,
    metadata: *const MarketSegmentRootMetadata,
) ![]u8 {
    if (metadata.file_size > std.math.maxInt(usize)) return error.MarketSegmentTooLarge;
    var encoded = std.array_list.Managed(u8).init(alloc);
    errdefer encoded.deinit();
    try encoded.ensureTotalCapacity(@intCast(metadata.file_size));
    try encoded.appendSlice(market_segment_magic);
    try appendInt(&encoded, u16, market_segment_version);
    var header = std.array_list.Managed(u8).init(alloc);
    defer header.deinit();
    try encodeHeaderFromRoot(&header, metadata);
    try appendInt(&encoded, u32, @intCast(header.items.len));
    try appendInt(&encoded, u32, checksum(header.items));
    try encoded.appendSlice(header.items);

    var cursor = try MarketSegmentBlockCursor.open(alloc, store, root_id);
    defer cursor.deinit();
    while (try cursor.next()) |block_value| {
        var block = block_value;
        defer block.deinit(alloc);
        var payloads = try readCasBlockPayloads(alloc, store, block, null);
        defer payloads.deinit(alloc);
        try appendEncodedBlockFromPayloads(&encoded, block, payloads);
    }
    const bytes = try encoded.toOwnedSlice();
    errdefer alloc.free(bytes);
    if (bytes.len != metadata.file_size or
        !std.mem.eql(u8, &hashBytes(bytes), &metadata.content_hash))
    {
        return error.MarketSegmentRootContentMismatch;
    }
    var parsed = try parseHeader(alloc, bytes);
    defer parsed.metadata.deinit(alloc);
    try validateBlockFrames(alloc, bytes, &parsed.metadata, parsed.blocks_offset);
    try validateRootMetadataMatchesSegment(metadata, &parsed.metadata, bytes.len);
    return bytes;
}

fn validateRootMetadataMatchesSegment(
    root: *const MarketSegmentRootMetadata,
    segment: *const Metadata,
    file_size: usize,
) !void {
    if (root.market_series_id != segment.market_series_id or
        !std.mem.eql(u8, &root.schema_digest, &segment.schema_digest) or
        !std.mem.eql(u8, root.metric, segment.metric) or
        !std.mem.eql(u8, root.canonical_labels, segment.canonical_labels) or
        root.hour != segment.hour or
        root.count != segment.count or
        root.start_ts_ns != segment.start_ts_ns or
        root.end_ts_ns != segment.end_ts_ns or
        root.block_rows != market_segment_block_rows or
        root.block_count != segment.block_count or
        root.file_size != file_size or
        root.column_names.len != segment.column_names.len)
    {
        return error.MarketSegmentRootMetadataMismatch;
    }
    for (root.column_names, segment.column_names) |root_name, segment_name| {
        if (!std.mem.eql(u8, root_name, segment_name)) {
            return error.MarketSegmentRootMetadataMismatch;
        }
    }
}

fn encodeMarketSegmentRootMetadata(
    alloc: std.mem.Allocator,
    metadata: MarketSegmentRootMetadata,
) ![]u8 {
    var bytes = std.array_list.Managed(u8).init(alloc);
    errdefer bytes.deinit();

    try bytes.append(market_segment_root_meta_version);
    try appendInt(&bytes, u64, metadata.market_series_id);
    try bytes.appendSlice(&metadata.schema_digest);
    try appendInt(&bytes, i64, metadata.hour);
    try appendInt(&bytes, u64, metadata.count);
    try appendInt(&bytes, i64, metadata.start_ts_ns);
    try appendInt(&bytes, i64, metadata.end_ts_ns);
    try appendInt(&bytes, u32, metadata.block_rows);
    try appendInt(&bytes, u32, metadata.block_count);
    try appendInt(&bytes, u64, metadata.file_size);
    try appendInt(&bytes, u32, metadata.extent_chunk_bytes);
    try bytes.appendSlice(&metadata.content_hash);
    try appendString(&bytes, metadata.metric);
    try appendString(&bytes, metadata.canonical_labels);
    try appendInt(&bytes, u32, @intCast(metadata.column_names.len));
    for (metadata.column_names) |name| try appendString(&bytes, name);
    return try bytes.toOwnedSlice();
}

fn decodeMarketSegmentRootMetadata(
    alloc: std.mem.Allocator,
    payload: []const u8,
) !MarketSegmentRootMetadata {
    var cursor: usize = 0;
    if (try readByteAt(payload, &cursor) != market_segment_root_meta_version) {
        return error.UnsupportedMarketSegmentRootVersion;
    }
    const market_series_id = try readIntAt(payload, &cursor, u64);
    const schema_digest_bytes = try take(payload, &cursor, 32);
    var schema_digest: SchemaDigest = undefined;
    @memcpy(&schema_digest, schema_digest_bytes);
    const hour = try readIntAt(payload, &cursor, i64);
    const count = try readIntAt(payload, &cursor, u64);
    const start_ts_ns = try readIntAt(payload, &cursor, i64);
    const end_ts_ns = try readIntAt(payload, &cursor, i64);
    const block_rows = try readIntAt(payload, &cursor, u32);
    const block_count = try readIntAt(payload, &cursor, u32);
    const file_size = try readIntAt(payload, &cursor, u64);
    const extent_chunk_bytes = try readIntAt(payload, &cursor, u32);
    const content_hash_bytes = try take(payload, &cursor, 32);
    var content_hash: [32]u8 = undefined;
    @memcpy(&content_hash, content_hash_bytes);
    const metric = try readOwnedStringAt(alloc, payload, &cursor);
    errdefer alloc.free(metric);
    const canonical_labels = try readOwnedStringAt(alloc, payload, &cursor);
    errdefer alloc.free(canonical_labels);
    const column_count: usize = try readIntAt(payload, &cursor, u32);

    if (count == 0 or start_ts_ns > end_ts_ns or
        block_rows != market_segment_block_rows or block_count == 0 or
        file_size == 0 or extent_chunk_bytes == 0)
    {
        return error.CorruptMarketSegmentRoot;
    }
    if (column_count == 0 or column_count > market_identity.max_market_columns) {
        return error.InvalidMarketSchema;
    }
    if (metric.len == 0 or metric.len > max_metadata_string_bytes or
        canonical_labels.len == 0 or canonical_labels.len > max_metadata_string_bytes)
    {
        return error.InvalidMarketMetadata;
    }
    const recanonicalized = market_identity.canonicalizeLabels(
        alloc,
        canonical_labels,
    ) catch return error.InvalidCanonicalMarketLabels;
    defer alloc.free(recanonicalized);
    if (!std.mem.eql(u8, recanonicalized, canonical_labels)) {
        return error.NonCanonicalMarketLabels;
    }
    if (market_series_id != market_identity.seriesId(metric, canonical_labels)) {
        return error.MarketSeriesIdMismatch;
    }

    var column_names = try alloc.alloc([]u8, column_count);
    errdefer alloc.free(column_names);
    var decoded: usize = 0;
    errdefer {
        for (column_names[0..decoded]) |name| alloc.free(name);
    }
    while (decoded < column_count) : (decoded += 1) {
        const name = try readOwnedStringAt(alloc, payload, &cursor);
        if (name.len == 0) {
            alloc.free(name);
            return error.InvalidMarketSchema;
        }
        for (column_names[0..decoded]) |previous| {
            if (std.mem.eql(u8, previous, name)) {
                alloc.free(name);
                return error.DuplicateMarketColumn;
            }
        }
        column_names[decoded] = name;
    }
    if (cursor != payload.len) return error.ExtraObjectBytes;

    return .{
        .market_series_id = market_series_id,
        .schema_digest = schema_digest,
        .metric = metric,
        .canonical_labels = canonical_labels,
        .hour = hour,
        .count = count,
        .start_ts_ns = start_ts_ns,
        .end_ts_ns = end_ts_ns,
        .block_rows = block_rows,
        .block_count = block_count,
        .column_names = column_names,
        .file_size = file_size,
        .content_hash = content_hash,
        .extent_chunk_bytes = extent_chunk_bytes,
    };
}

fn parseHeader(alloc: std.mem.Allocator, bytes: []const u8) !ParsedHeader {
    var cursor: usize = 0;
    const magic = try take(bytes, &cursor, market_segment_magic.len);
    if (!std.mem.eql(u8, magic, market_segment_magic)) return error.InvalidMarketSegmentMagic;
    if (try readIntAt(bytes, &cursor, u16) != market_segment_version) {
        return error.UnsupportedMarketSegmentVersion;
    }
    const header_len: usize = try readIntAt(bytes, &cursor, u32);
    const expected_crc = try readIntAt(bytes, &cursor, u32);
    const header_bytes = try take(bytes, &cursor, header_len);
    if (checksum(header_bytes) != expected_crc) return error.CorruptMarketSegment;

    var header_cursor: usize = 0;
    const market_series_id = try readIntAt(header_bytes, &header_cursor, u64);
    const schema_digest_bytes = try take(header_bytes, &header_cursor, 32);
    var schema_digest: SchemaDigest = undefined;
    @memcpy(&schema_digest, schema_digest_bytes);
    const hour = try readIntAt(header_bytes, &header_cursor, i64);
    const count = try readIntAt(header_bytes, &header_cursor, u64);
    const start_ts_ns = try readIntAt(header_bytes, &header_cursor, i64);
    const end_ts_ns = try readIntAt(header_bytes, &header_cursor, i64);
    const block_rows = try readIntAt(header_bytes, &header_cursor, u32);
    const block_count = try readIntAt(header_bytes, &header_cursor, u32);
    const column_count: usize = try readIntAt(header_bytes, &header_cursor, u32);
    const metric_len: usize = try readIntAt(header_bytes, &header_cursor, u32);
    const canonical_labels_len: usize = try readIntAt(header_bytes, &header_cursor, u32);
    if (count == 0 or block_rows != market_segment_block_rows or block_count == 0) {
        return error.CorruptMarketSegment;
    }
    const expected_block_count = std.math.divCeil(u64, count, market_segment_block_rows) catch
        return error.CorruptMarketSegment;
    if (block_count != expected_block_count) return error.CorruptMarketSegment;
    if (start_ts_ns > end_ts_ns) return error.CorruptMarketSegment;
    if (column_count == 0 or column_count > market_identity.max_market_columns) {
        return error.InvalidMarketSchema;
    }
    if (metric_len == 0 or metric_len > max_metadata_string_bytes or
        canonical_labels_len == 0 or canonical_labels_len > max_metadata_string_bytes)
    {
        return error.InvalidMarketMetadata;
    }

    const metric = try alloc.dupe(u8, try take(header_bytes, &header_cursor, metric_len));
    errdefer alloc.free(metric);
    const canonical_labels = try alloc.dupe(
        u8,
        try take(header_bytes, &header_cursor, canonical_labels_len),
    );
    errdefer alloc.free(canonical_labels);
    const recanonicalized = market_identity.canonicalizeLabels(
        alloc,
        canonical_labels,
    ) catch return error.InvalidCanonicalMarketLabels;
    defer alloc.free(recanonicalized);
    if (!std.mem.eql(u8, recanonicalized, canonical_labels)) {
        return error.NonCanonicalMarketLabels;
    }
    if (market_series_id != market_identity.seriesId(metric, canonical_labels)) {
        return error.MarketSeriesIdMismatch;
    }
    if (try hourBucket(start_ts_ns) != hour or try hourBucket(end_ts_ns) != hour) {
        return error.MarketRowOutsideHour;
    }

    var column_names = try alloc.alloc([]u8, column_count);
    errdefer alloc.free(column_names);
    var decoded_columns: usize = 0;
    errdefer {
        for (column_names[0..decoded_columns]) |name| alloc.free(name);
    }
    while (decoded_columns < column_count) : (decoded_columns += 1) {
        const name = try readOwnedStringAt(alloc, header_bytes, &header_cursor);
        if (name.len == 0) {
            alloc.free(name);
            return error.InvalidMarketSchema;
        }
        for (column_names[0..decoded_columns]) |previous| {
            if (std.mem.eql(u8, name, previous)) {
                alloc.free(name);
                return error.DuplicateMarketColumn;
            }
        }
        column_names[decoded_columns] = name;
    }
    if (header_cursor != header_bytes.len) return error.CorruptMarketSegment;

    return .{
        .metadata = .{
            .market_series_id = market_series_id,
            .schema_digest = schema_digest,
            .metric = metric,
            .canonical_labels = canonical_labels,
            .hour = hour,
            .count = count,
            .start_ts_ns = start_ts_ns,
            .end_ts_ns = end_ts_ns,
            .block_count = block_count,
            .column_names = column_names,
        },
        .blocks_offset = cursor,
    };
}

fn parseBlock(
    alloc: std.mem.Allocator,
    bytes: []const u8,
    offset: usize,
    column_count: usize,
) !ParsedBlock {
    var cursor = offset;
    const magic = try take(bytes, &cursor, block_magic.len);
    if (!std.mem.eql(u8, magic, block_magic)) return error.InvalidMarketBlockMagic;
    const body_len: usize = try readIntAt(bytes, &cursor, u32);
    const body = try take(bytes, &cursor, body_len);
    const expected_crc = try readIntAt(bytes, &cursor, u32);
    if (checksum(body) != expected_crc) return error.CorruptMarketSegment;

    var body_cursor: usize = 0;
    const count = try readIntAt(body, &body_cursor, u32);
    const min_ts_ns = try readIntAt(body, &body_cursor, i64);
    const max_ts_ns = try readIntAt(body, &body_cursor, i64);
    const timestamp_len: usize = try readIntAt(body, &body_cursor, u32);
    const sequence_len: usize = try readIntAt(body, &body_cursor, u32);
    const fingerprint_len: usize = try readIntAt(body, &body_cursor, u32);
    if (count == 0 or count > market_segment_block_rows or min_ts_ns > max_ts_ns) {
        return error.CorruptMarketSegment;
    }
    const expected_fingerprint_len = std.math.mul(
        usize,
        count,
        @sizeOf(RowFingerprint),
    ) catch return error.CorruptMarketSegment;
    if (timestamp_len == 0 or sequence_len == 0 or
        fingerprint_len != expected_fingerprint_len)
    {
        return error.CorruptMarketSegment;
    }

    const bounds_valid = try alloc.alloc(bool, column_count);
    errdefer alloc.free(bounds_valid);
    const column_mins = try alloc.alloc(f64, column_count);
    errdefer alloc.free(column_mins);
    const column_maxs = try alloc.alloc(f64, column_count);
    errdefer alloc.free(column_maxs);
    var column_lengths = try alloc.alloc(usize, column_count);
    defer alloc.free(column_lengths);
    for (0..column_count) |idx| {
        const raw_bounds_valid = try readByteAt(body, &body_cursor);
        if (raw_bounds_valid > 1) return error.CorruptMarketSegment;
        bounds_valid[idx] = raw_bounds_valid == 1;
        column_mins[idx] = try readF64At(body, &body_cursor);
        column_maxs[idx] = try readF64At(body, &body_cursor);
        column_lengths[idx] = try readIntAt(body, &body_cursor, u32);
        if (column_lengths[idx] == 0) return error.CorruptMarketSegment;
        if (bounds_valid[idx]) {
            if (std.math.isNan(column_mins[idx]) or
                std.math.isNan(column_maxs[idx]) or
                column_mins[idx] > column_maxs[idx])
            {
                return error.CorruptMarketSegment;
            }
        } else if (@as(u64, @bitCast(column_mins[idx])) != 0 or
            @as(u64, @bitCast(column_maxs[idx])) != 0)
        {
            return error.CorruptMarketSegment;
        }
    }

    const timestamp_payload = try take(body, &body_cursor, timestamp_len);
    const sequence_payload = try take(body, &body_cursor, sequence_len);
    const fingerprint_payload = try take(body, &body_cursor, fingerprint_len);
    const column_payloads = try alloc.alloc([]const u8, column_count);
    errdefer alloc.free(column_payloads);
    for (0..column_count) |idx| {
        column_payloads[idx] = try take(body, &body_cursor, column_lengths[idx]);
    }
    if (body_cursor != body.len) return error.CorruptMarketSegment;

    return .{
        .next_offset = cursor,
        .count = count,
        .min_ts_ns = min_ts_ns,
        .max_ts_ns = max_ts_ns,
        .bounds_valid = bounds_valid,
        .column_mins = column_mins,
        .column_maxs = column_maxs,
        .timestamp_payload = timestamp_payload,
        .sequence_payload = sequence_payload,
        .fingerprint_payload = fingerprint_payload,
        .column_payloads = column_payloads,
    };
}

fn validateBlockFrames(
    alloc: std.mem.Allocator,
    bytes: []const u8,
    metadata: *const Metadata,
    blocks_offset: usize,
) !void {
    var cursor = blocks_offset;
    var total_count: u64 = 0;
    var start: ?i64 = null;
    var end: ?i64 = null;
    var previous_block_max: ?i64 = null;
    var previous_ts: ?i64 = null;
    var previous_sequence: u64 = 0;
    var previous_fingerprint: RowFingerprint = undefined;
    var idx: u32 = 0;
    while (idx < metadata.block_count) : (idx += 1) {
        var block = try parseBlock(alloc, bytes, cursor, metadata.column_names.len);
        defer block.deinit(alloc);
        cursor = block.next_offset;
        total_count = std.math.add(u64, total_count, block.count) catch
            return error.CorruptMarketSegment;
        if (try hourBucket(block.min_ts_ns) != metadata.hour or
            try hourBucket(block.max_ts_ns) != metadata.hour)
        {
            return error.CorruptMarketSegment;
        }
        if (previous_block_max) |previous_max| {
            if (block.min_ts_ns < previous_max) return error.CorruptMarketSegment;
        }
        previous_block_max = block.max_ts_ns;

        const timestamps = try decodeTimestamps(alloc, block);
        defer alloc.free(timestamps);
        const sequences = try decodeSequences(alloc, block);
        defer alloc.free(sequences);
        try validateKeyOrder(metadata.hour, timestamps, sequences);

        const decoded_columns = try alloc.alloc([]f64, metadata.column_names.len);
        defer alloc.free(decoded_columns);
        var decoded_count: usize = 0;
        defer {
            for (decoded_columns[0..decoded_count]) |values| alloc.free(values);
        }
        for (0..metadata.column_names.len) |column_idx| {
            decoded_columns[column_idx] = try decodeColumn(alloc, block, column_idx);
            decoded_count += 1;
        }
        const row_values = try alloc.alloc(f64, metadata.column_names.len);
        defer alloc.free(row_values);
        for (timestamps, sequences, 0..) |timestamp, sequence, row_idx| {
            for (decoded_columns, 0..) |column, column_idx| {
                row_values[column_idx] = column[row_idx];
            }
            const fingerprint = fingerprintRow(row_values);
            if (!std.mem.eql(
                u8,
                &fingerprint,
                block.fingerprint_payload[row_idx * @sizeOf(RowFingerprint) ..][0..@sizeOf(RowFingerprint)],
            )) return error.CorruptMarketSegment;
            if (previous_ts) |prior_ts| {
                if (timestamp < prior_ts or
                    (timestamp == prior_ts and sequence < previous_sequence))
                {
                    return error.CorruptMarketSegment;
                }
                if (timestamp == prior_ts and sequence == previous_sequence and
                    !std.mem.eql(u8, &fingerprint, &previous_fingerprint))
                {
                    return error.DuplicateWriteSequenceConflict;
                }
            }
            previous_ts = timestamp;
            previous_sequence = sequence;
            previous_fingerprint = fingerprint;
        }
        if (idx == 0) start = block.min_ts_ns;
        end = block.max_ts_ns;
    }
    if (cursor != bytes.len or total_count != metadata.count or
        start == null or end == null or
        start.? != metadata.start_ts_ns or end.? != metadata.end_ts_ns)
    {
        return error.CorruptMarketSegment;
    }
}

fn decodeTimestamps(alloc: std.mem.Allocator, block: ParsedBlock) ![]i64 {
    var stream = std.io.fixedBufferStream(block.timestamp_payload);
    const timestamps = gorilla.decodeTsDoD(
        alloc,
        stream.reader(),
        block.count,
        block.min_ts_ns,
    ) catch return error.CorruptMarketSegment;
    errdefer alloc.free(timestamps);
    if (stream.pos != block.timestamp_payload.len) return error.CorruptMarketSegment;
    for (timestamps, 0..) |timestamp, idx| {
        if (idx > 0 and timestamp < timestamps[idx - 1]) return error.CorruptMarketSegment;
    }
    if (timestamps[0] != block.min_ts_ns or timestamps[timestamps.len - 1] != block.max_ts_ns) {
        return error.CorruptMarketSegment;
    }
    return timestamps;
}

fn decodeSequences(alloc: std.mem.Allocator, block: ParsedBlock) ![]u64 {
    const sequences = try alloc.alloc(u64, block.count);
    errdefer alloc.free(sequences);
    var cursor: usize = 0;
    for (sequences) |*sequence| {
        sequence.* = decodeU64Varint(block.sequence_payload, &cursor) catch
            return error.CorruptMarketSegment;
    }
    if (cursor != block.sequence_payload.len) return error.CorruptMarketSegment;
    return sequences;
}

fn decodeColumn(alloc: std.mem.Allocator, block: ParsedBlock, column_idx: usize) ![]f64 {
    var stream = std.io.fixedBufferStream(block.column_payloads[column_idx]);
    const values = gorilla.decodeF64(alloc, stream.reader(), block.count) catch
        return error.CorruptMarketSegment;
    errdefer alloc.free(values);
    if (stream.pos != block.column_payloads[column_idx].len) return error.CorruptMarketSegment;

    var min_value: f64 = 0;
    var max_value: f64 = 0;
    var has_bounds = false;
    for (values) |value| {
        if (std.math.isNan(value)) continue;
        if (!has_bounds) {
            min_value = value;
            max_value = value;
            has_bounds = true;
        } else {
            if (value < min_value) min_value = value;
            if (value > max_value) max_value = value;
        }
    }
    if (has_bounds != block.bounds_valid[column_idx]) {
        return error.CorruptMarketSegment;
    }
    if (has_bounds and
        (@as(u64, @bitCast(min_value)) != @as(u64, @bitCast(block.column_mins[column_idx])) or
            @as(u64, @bitCast(max_value)) != @as(u64, @bitCast(block.column_maxs[column_idx]))))
    {
        return error.CorruptMarketSegment;
    }
    return values;
}

fn resolveProjection(
    alloc: std.mem.Allocator,
    metadata: *const Metadata,
    requested: ?[]const []const u8,
) ![]usize {
    if (requested == null) {
        const indices = try alloc.alloc(usize, metadata.column_names.len);
        for (indices, 0..) |*index, idx| index.* = idx;
        return indices;
    }

    const indices = try alloc.alloc(usize, requested.?.len);
    errdefer alloc.free(indices);
    for (requested.?, 0..) |requested_name, requested_idx| {
        for (requested.?[0..requested_idx]) |previous| {
            if (std.mem.eql(u8, previous, requested_name)) return error.DuplicateProjectionColumn;
        }
        var found: ?usize = null;
        for (metadata.column_names, 0..) |name, column_idx| {
            if (std.mem.eql(u8, name, requested_name)) {
                found = column_idx;
                break;
            }
        }
        indices[requested_idx] = found orelse return error.UnknownMarketColumn;
    }
    return indices;
}

fn readFileAlloc(
    alloc: std.mem.Allocator,
    data_dir: std.fs.Dir,
    path: []const u8,
) ![]u8 {
    var file = try data_dir.openFile(path, .{});
    defer file.close();
    const stat = try file.stat();
    if (stat.size > std.math.maxInt(usize)) return error.MarketSegmentTooLarge;
    const bytes = try alloc.alloc(u8, @intCast(stat.size));
    errdefer alloc.free(bytes);
    const read_len = try file.readAll(bytes);
    if (read_len != bytes.len) return error.TruncatedMarketSegment;
    return bytes;
}

fn existingFileMatches(data_dir: std.fs.Dir, path: []const u8, expected: []const u8) !bool {
    var file = data_dir.openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer file.close();
    const stat = try file.stat();
    if (stat.size != expected.len) return false;
    var offset: usize = 0;
    var buffer: [4096]u8 = undefined;
    while (offset < expected.len) {
        const count = try file.read(&buffer);
        if (count == 0) return false;
        if (!std.mem.eql(u8, buffer[0..count], expected[offset .. offset + count])) return false;
        offset += count;
    }
    return true;
}

fn checksum(bytes: []const u8) u32 {
    var crc = std.hash.Crc32.init();
    crc.update(bytes);
    return crc.final();
}

fn contentId(bytes: []const u8) u64 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.Blake3.hash(bytes, &digest, .{});
    return std.mem.readInt(u64, digest[0..8], .little);
}

fn hashBytes(bytes: []const u8) [32]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.Blake3.hash(bytes, &digest, .{});
    return digest;
}

const TreeEntry = struct {
    name: []u8,
    object_type: object_store.ObjectType,
    object_id: object_store.ObjectId,

    fn deinit(self: *TreeEntry, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
    }
};

const LoadedTree = struct {
    entries: []TreeEntry,

    fn deinit(self: *LoadedTree, alloc: std.mem.Allocator) void {
        for (self.entries) |*entry| entry.deinit(alloc);
        alloc.free(self.entries);
    }
};

fn appendUniqueObjectId(
    ids: *std.array_list.Managed(object_store.ObjectId),
    id: object_store.ObjectId,
) !void {
    for (ids.items) |existing| {
        if (existing.eql(id)) return;
    }
    try ids.append(id);
}

fn putTree(
    alloc: std.mem.Allocator,
    store: *object_store.ObjectStore,
    entries: []const TreeEntry,
) !object_store.ObjectId {
    const payload = try encodeTree(alloc, entries);
    defer alloc.free(payload);
    return try store.put(.tree, payload);
}

fn loadTreeObject(
    alloc: std.mem.Allocator,
    store: *object_store.ObjectStore,
    id: object_store.ObjectId,
) !LoadedTree {
    const loaded = try store.get(alloc, id);
    defer alloc.free(loaded.payload);
    if (loaded.obj_type != .tree) return error.InvalidMarketSegmentRootTree;
    return .{ .entries = try decodeTree(alloc, loaded.payload) };
}

fn loadBlobObject(
    alloc: std.mem.Allocator,
    store: *object_store.ObjectStore,
    id: object_store.ObjectId,
) ![]u8 {
    const loaded = try store.get(alloc, id);
    errdefer alloc.free(loaded.payload);
    if (loaded.obj_type != .blob) return error.InvalidMarketSegmentRootBlob;
    return loaded.payload;
}

fn findRequiredTreeEntry(
    entries: []const TreeEntry,
    name: []const u8,
    expected_type: object_store.ObjectType,
    missing_error: anyerror,
) !object_store.ObjectId {
    for (entries) |entry| {
        if (!std.mem.eql(u8, entry.name, name)) continue;
        if (entry.object_type != expected_type) return error.InvalidMarketSegmentRootTree;
        return entry.object_id;
    }
    return missing_error;
}

fn encodeTree(alloc: std.mem.Allocator, entries: []const TreeEntry) ![]u8 {
    var copy_entries = try alloc.alloc(TreeEntry, entries.len);
    defer {
        for (copy_entries) |*entry| entry.deinit(alloc);
        alloc.free(copy_entries);
    }
    for (entries, 0..) |entry, idx| {
        copy_entries[idx] = .{
            .name = try alloc.dupe(u8, entry.name),
            .object_type = entry.object_type,
            .object_id = entry.object_id,
        };
    }
    std.sort.block(TreeEntry, copy_entries, {}, struct {
        fn lessThan(_: void, lhs: TreeEntry, rhs: TreeEntry) bool {
            return std.mem.lessThan(u8, lhs.name, rhs.name);
        }
    }.lessThan);

    var bytes = std.array_list.Managed(u8).init(alloc);
    errdefer bytes.deinit();
    try bytes.append(1);
    try appendInt(&bytes, u32, @intCast(copy_entries.len));
    for (copy_entries) |entry| {
        try appendString(&bytes, entry.name);
        try bytes.append(@intFromEnum(entry.object_type));
        try bytes.appendSlice(entry.object_id.hash[0..]);
    }
    return try bytes.toOwnedSlice();
}

fn decodeTree(alloc: std.mem.Allocator, payload: []const u8) ![]TreeEntry {
    var cursor: usize = 0;
    if (try readByteAt(payload, &cursor) != 1) return error.UnsupportedMarketSegmentRootTreeVersion;
    const entry_count = try readIntAt(payload, &cursor, u32);
    var entries = try alloc.alloc(TreeEntry, entry_count);
    var decoded: usize = 0;
    errdefer {
        for (entries[0..decoded]) |*entry| entry.deinit(alloc);
        alloc.free(entries);
    }
    while (decoded < entry_count) : (decoded += 1) {
        const name = try readOwnedStringAt(alloc, payload, &cursor);
        errdefer alloc.free(name);
        const object_type = std.meta.intToEnum(
            object_store.ObjectType,
            try readByteAt(payload, &cursor),
        ) catch return error.UnknownTreeObjectType;
        entries[decoded] = .{
            .name = name,
            .object_type = object_type,
            .object_id = .{ .hash = try readHashAt(payload, &cursor) },
        };
    }
    if (cursor != payload.len) return error.ExtraObjectBytes;
    return entries;
}

fn appendInt(bytes: *std.array_list.Managed(u8), comptime T: type, value: T) !void {
    var buf: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buf, value, .little);
    try bytes.appendSlice(&buf);
}

fn appendF64(bytes: *std.array_list.Managed(u8), value: f64) !void {
    try appendInt(bytes, u64, @bitCast(value));
}

fn appendString(bytes: *std.array_list.Managed(u8), value: []const u8) !void {
    if (value.len > max_metadata_string_bytes) return error.InvalidMarketMetadata;
    try appendInt(bytes, u32, @intCast(value.len));
    try bytes.appendSlice(value);
}

fn readOwnedStringAt(
    alloc: std.mem.Allocator,
    bytes: []const u8,
    cursor: *usize,
) ![]u8 {
    const len: usize = try readIntAt(bytes, cursor, u32);
    if (len > max_metadata_string_bytes) return error.InvalidMarketMetadata;
    return try alloc.dupe(u8, try take(bytes, cursor, len));
}

fn readByteAt(bytes: []const u8, cursor: *usize) !u8 {
    const value = try take(bytes, cursor, 1);
    return value[0];
}

fn readIntAt(bytes: []const u8, cursor: *usize, comptime T: type) !T {
    const value = try take(bytes, cursor, @sizeOf(T));
    return std.mem.readInt(T, value[0..@sizeOf(T)], .little);
}

fn readF64At(bytes: []const u8, cursor: *usize) !f64 {
    return @bitCast(try readIntAt(bytes, cursor, u64));
}

fn readHashAt(bytes: []const u8, cursor: *usize) ![32]u8 {
    var hash: [32]u8 = undefined;
    @memcpy(&hash, try take(bytes, cursor, 32));
    return hash;
}

fn take(bytes: []const u8, cursor: *usize, len: usize) ![]const u8 {
    const end = std.math.add(usize, cursor.*, len) catch return error.TruncatedMarketSegment;
    if (end > bytes.len) return error.TruncatedMarketSegment;
    const result = bytes[cursor.*..end];
    cursor.* = end;
    return result;
}

fn hourBucket(ts_ns: i64) !i64 {
    return @divFloor(ts_ns, hour_ns);
}

fn rowBitsEqual(lhs: []const f64, rhs: []const f64) bool {
    if (lhs.len != rhs.len) return false;
    for (lhs, rhs) |lhs_value, rhs_value| {
        if (@as(u64, @bitCast(lhs_value)) != @as(u64, @bitCast(rhs_value))) {
            return false;
        }
    }
    return true;
}

fn fingerprintRow(values: []const f64) RowFingerprint {
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update("SYDRA_MARKET_ROW_V1");
    var count_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &count_bytes, @intCast(values.len), .little);
    hasher.update(&count_bytes);
    for (values) |value| {
        var value_bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &value_bytes, @bitCast(value), .little);
        hasher.update(&value_bytes);
    }
    var fingerprint: RowFingerprint = undefined;
    hasher.final(&fingerprint);
    return fingerprint;
}

fn readFingerprint(payload: []const u8, row_idx: usize) RowFingerprint {
    const offset = row_idx * @sizeOf(RowFingerprint);
    var fingerprint: RowFingerprint = undefined;
    @memcpy(&fingerprint, payload[offset..][0..@sizeOf(RowFingerprint)]);
    return fingerprint;
}

pub fn validateEqualSequenceFingerprints(
    lhs: RowFingerprint,
    rhs: RowFingerprint,
) !void {
    if (!std.mem.eql(u8, &lhs, &rhs)) return error.DuplicateWriteSequenceConflict;
}

fn validateKeyOrder(hour: i64, timestamps: []const i64, sequences: []const u64) !void {
    if (timestamps.len != sequences.len or timestamps.len == 0) {
        return error.CorruptMarketSegment;
    }
    for (timestamps, sequences, 0..) |timestamp, sequence, idx| {
        if (try hourBucket(timestamp) != hour) return error.CorruptMarketSegment;
        if (idx > 0 and
            (timestamp < timestamps[idx - 1] or
                (timestamp == timestamps[idx - 1] and sequence < sequences[idx - 1])))
        {
            return error.CorruptMarketSegment;
        }
    }
}

fn appendU64Varint(bytes: *std.array_list.Managed(u8), value: u64) !void {
    var remaining = value;
    while (remaining >= 0x80) {
        try bytes.append(@intCast((remaining & 0x7f) | 0x80));
        remaining >>= 7;
    }
    try bytes.append(@intCast(remaining));
}

fn decodeU64Varint(bytes: []const u8, cursor: *usize) !u64 {
    var result: u64 = 0;
    var idx: usize = 0;
    while (idx < 10) : (idx += 1) {
        const byte = try readByteAt(bytes, cursor);
        if (idx == 9 and (byte & 0xfe) != 0) return error.InvalidUnsignedVarint;
        const shift: u6 = @intCast(idx * 7);
        result |= @as(u64, byte & 0x7f) << shift;
        if ((byte & 0x80) == 0) {
            if (idx > 0 and (byte & 0x7f) == 0) return error.InvalidUnsignedVarint;
            return result;
        }
    }
    return error.InvalidUnsignedVarint;
}

fn sampleMetadata(column_names: []const []const u8) MetadataView {
    const metric = "book.top";
    const labels = "{\"exchange\":\"XTSE\",\"symbol\":\"SHOP\"}";
    return .{
        .market_series_id = market_identity.seriesId(metric, labels),
        .schema_digest = [_]u8{0x5a} ** 32,
        .metric = metric,
        .canonical_labels = labels,
        .hour = 0,
        .column_names = column_names,
    };
}

test "SYMKT1 round trip preserves metadata and rows" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = std.testing.allocator;
    const names = [_][]const u8{ "bid", "ask" };
    const values = [_][2]f64{
        .{ 100.25, 100.5 },
        .{ 100.5, 100.75 },
        .{ 100.75, 101.0 },
    };
    const rows = [_]MarketRowView{
        .{ .ts_ns = 10, .write_sequence = 7, .values = &values[0] },
        .{ .ts_ns = 20, .write_sequence = 8, .values = &values[1] },
        .{ .ts_ns = 30, .write_sequence = 9, .values = &values[2] },
    };

    const path = try write(alloc, tmp.dir, sampleMetadata(&names), &rows);
    defer alloc.free(path);
    try std.testing.expect(std.mem.endsWith(u8, path, ".mseg"));

    var result = try readAll(alloc, tmp.dir, path);
    defer result.deinit(alloc);
    try std.testing.expectEqual(@as(u64, rows.len), result.metadata.count);
    try std.testing.expectEqualStrings("book.top", result.metadata.metric);
    try std.testing.expectEqualStrings(
        "{\"exchange\":\"XTSE\",\"symbol\":\"SHOP\"}",
        result.metadata.canonical_labels,
    );
    try std.testing.expectEqualSlices(i64, &.{ 10, 20, 30 }, result.timestamps);
    try std.testing.expectEqualSlices(u64, &.{ 7, 8, 9 }, result.write_sequences);
    try std.testing.expectEqualStrings("bid", result.columns[0].name);
    try std.testing.expectEqualSlices(f64, &.{ 100.25, 100.5, 100.75 }, result.columns[0].values);
    try std.testing.expectEqualSlices(f64, &.{ 100.5, 100.75, 101.0 }, result.columns[1].values);
}

test "projected range preserves requested order and decodes selected columns only" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = std.testing.allocator;
    const names = [_][]const u8{ "bid", "ask", "size" };
    const values = [_][3]f64{
        .{ 100, 101, 10 },
        .{ 102, 103, 20 },
        .{ 104, 105, 30 },
    };
    const rows = [_]MarketRowView{
        .{ .ts_ns = 10, .write_sequence = 1, .values = &values[0] },
        .{ .ts_ns = 20, .write_sequence = 2, .values = &values[1] },
        .{ .ts_ns = 30, .write_sequence = 3, .values = &values[2] },
    };
    const path = try write(alloc, tmp.dir, sampleMetadata(&names), &rows);
    defer alloc.free(path);

    const projection = [_][]const u8{ "size", "bid" };
    var result = try readProjectedRange(alloc, tmp.dir, path, 15, 25, &projection);
    defer result.deinit(alloc);
    try std.testing.expectEqualSlices(i64, &.{20}, result.timestamps);
    try std.testing.expectEqual(@as(usize, 2), result.columns.len);
    try std.testing.expectEqualStrings("size", result.columns[0].name);
    try std.testing.expectEqualSlices(f64, &.{20}, result.columns[0].values);
    try std.testing.expectEqualStrings("bid", result.columns[1].name);
    try std.testing.expectEqualSlices(f64, &.{102}, result.columns[1].values);
    try std.testing.expectEqual(@as(u64, 2), result.stats.columns_decoded);
}

test "range reads prune unrelated blocks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = std.testing.allocator;
    const names = [_][]const u8{"price"};
    const values = try alloc.alloc([1]f64, market_segment_block_rows + 5);
    defer alloc.free(values);
    const rows = try alloc.alloc(MarketRowView, values.len);
    defer alloc.free(rows);
    for (values, rows, 0..) |*value, *row, idx| {
        value.* = .{@floatFromInt(idx)};
        row.* = .{
            .ts_ns = @intCast(idx),
            .write_sequence = idx + 1,
            .values = value,
        };
    }
    const path = try write(alloc, tmp.dir, sampleMetadata(&names), rows);
    defer alloc.free(path);

    var result = try readRange(alloc, tmp.dir, path, market_segment_block_rows + 1, market_segment_block_rows + 3);
    defer result.deinit(alloc);
    try std.testing.expectEqual(@as(u32, 2), result.stats.blocks_total);
    try std.testing.expectEqual(@as(u32, 1), result.stats.blocks_scanned);
    try std.testing.expectEqual(@as(u32, 1), result.stats.blocks_pruned);
    try std.testing.expectEqual(@as(usize, 3), result.timestamps.len);
}

test "highest write sequence wins for duplicate timestamps across blocks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = std.testing.allocator;
    const names = [_][]const u8{"price"};
    const values = try alloc.alloc([1]f64, market_segment_block_rows + 1);
    defer alloc.free(values);
    const rows = try alloc.alloc(MarketRowView, values.len);
    defer alloc.free(rows);
    for (values, rows, 0..) |*value, *row, idx| {
        value.* = .{@floatFromInt(idx)};
        row.* = .{
            .ts_ns = if (idx < market_segment_block_rows) 50 else 50,
            .write_sequence = idx + 1,
            .values = value,
        };
    }
    const path = try write(alloc, tmp.dir, sampleMetadata(&names), rows);
    defer alloc.free(path);

    var result = try readAll(alloc, tmp.dir, path);
    defer result.deinit(alloc);
    try std.testing.expectEqualSlices(i64, &.{50}, result.timestamps);
    try std.testing.expectEqual(@as(u64, market_segment_block_rows + 1), result.write_sequences[0]);
    try std.testing.expectEqual(@as(f64, market_segment_block_rows), result.columns[0].values[0]);
}

test "truncated and corrupted segments are rejected" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = std.testing.allocator;
    const names = [_][]const u8{"price"};
    const value = [_]f64{42};
    const rows = [_]MarketRowView{
        .{ .ts_ns = 10, .write_sequence = 1, .values = &value },
    };
    const path = try write(alloc, tmp.dir, sampleMetadata(&names), &rows);
    defer alloc.free(path);

    const original = try readFileAlloc(alloc, tmp.dir, path);
    defer alloc.free(original);

    {
        var file = try tmp.dir.createFile("truncated.mseg", .{});
        defer file.close();
        try file.writeAll(original[0 .. original.len - 1]);
    }
    try std.testing.expectError(
        error.TruncatedMarketSegment,
        readAll(alloc, tmp.dir, "truncated.mseg"),
    );

    const corrupted = try alloc.dupe(u8, original);
    defer alloc.free(corrupted);
    corrupted[corrupted.len - 5] ^= 0xff;
    {
        var file = try tmp.dir.createFile("corrupted.mseg", .{});
        defer file.close();
        try file.writeAll(corrupted);
    }
    try std.testing.expectError(
        error.CorruptMarketSegment,
        readAll(alloc, tmp.dir, "corrupted.mseg"),
    );
}

test "multi-block segment round trip preserves all rows" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = std.testing.allocator;
    const names = [_][]const u8{ "price", "size" };
    const row_count = market_segment_block_rows * 2 + 17;
    const values = try alloc.alloc([2]f64, row_count);
    defer alloc.free(values);
    const rows = try alloc.alloc(MarketRowView, row_count);
    defer alloc.free(rows);
    for (values, rows, 0..) |*value, *row, idx| {
        value.* = .{ @floatFromInt(idx), @floatFromInt(idx * 10) };
        row.* = .{
            .ts_ns = @intCast(1_000 + idx),
            .write_sequence = idx + 100,
            .values = value,
        };
    }
    const path = try write(alloc, tmp.dir, sampleMetadata(&names), rows);
    defer alloc.free(path);

    var result = try readAll(alloc, tmp.dir, path);
    defer result.deinit(alloc);
    try std.testing.expectEqual(@as(u32, 3), result.metadata.block_count);
    try std.testing.expectEqual(@as(usize, row_count), result.timestamps.len);
    try std.testing.expectEqual(@as(i64, 1_000), result.timestamps[0]);
    try std.testing.expectEqual(@as(i64, 1_000 + row_count - 1), result.timestamps[row_count - 1]);
    try std.testing.expectEqual(@as(f64, (row_count - 1) * 10), result.columns[1].values[row_count - 1]);
}

test "schema and row column count mismatches are rejected" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = std.testing.allocator;
    const names = [_][]const u8{ "price", "size" };
    const incomplete_value = [_]f64{42};
    const incomplete_row = [_]MarketRowView{
        .{ .ts_ns = 10, .write_sequence = 1, .values = &incomplete_value },
    };
    try std.testing.expectError(
        error.MarketColumnCountMismatch,
        write(alloc, tmp.dir, sampleMetadata(&names), &incomplete_row),
    );

    const complete_value = [_]f64{ 42, 10 };
    const complete_row = [_]MarketRowView{
        .{ .ts_ns = 10, .write_sequence = 1, .values = &complete_value },
    };
    const path = try write(alloc, tmp.dir, sampleMetadata(&names), &complete_row);
    defer alloc.free(path);
    var metadata = try inspect(alloc, tmp.dir, path);
    defer metadata.deinit(alloc);

    var wrong_schema = sampleMetadata(&names);
    wrong_schema.schema_digest[0] ^= 0xff;
    try std.testing.expectError(
        error.MarketSegmentSchemaMismatch,
        validateExpectedSchema(&metadata, wrong_schema),
    );

    var wrong_id = sampleMetadata(&names);
    wrong_id.market_series_id +%= 1;
    try std.testing.expectError(
        error.MarketSeriesIdMismatch,
        write(alloc, tmp.dir, wrong_id, &complete_row),
    );

    var noncanonical_labels = sampleMetadata(&names);
    noncanonical_labels.canonical_labels = "{\"symbol\":\"SHOP\",\"exchange\":\"XTSE\"}";
    noncanonical_labels.market_series_id = market_identity.seriesId(
        noncanonical_labels.metric,
        noncanonical_labels.canonical_labels,
    );
    try std.testing.expectError(
        error.NonCanonicalMarketLabels,
        write(alloc, tmp.dir, noncanonical_labels, &complete_row),
    );
}

test "SYMKT1 v1 golden bytes remain stable and readable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = std.testing.allocator;
    const names = [_][]const u8{"v"};
    const metric = "m";
    const labels = "{}";
    const metadata = MetadataView{
        .market_series_id = market_identity.seriesId(metric, labels),
        .schema_digest = [_]u8{0x11} ** 32,
        .metric = metric,
        .canonical_labels = labels,
        .hour = -1,
        .column_names = &names,
    };
    const value = [_]f64{@bitCast(@as(u64, 0x7ff8000000000042))};
    const rows = [_]MarketRowView{
        .{ .ts_ns = -1, .write_sequence = 300, .values = &value },
    };
    const path = try write(alloc, tmp.dir, metadata, &rows);
    defer alloc.free(path);
    const bytes = try readFileAlloc(alloc, tmp.dir, path);
    defer alloc.free(bytes);
    const golden_hex =
        "53594d4b5431010064000000500d2a92f983b46d49c7792e" ++
        "1111111111111111111111111111111111111111111111111111111111111111" ++
        "ffffffffffffffff0100000000000000ffffffffffffffffffffffffffffffff" ++
        "00100000010000000100000001000000020000006d7b7d0100000076" ++
        "4d424c4b6100000001000000ffffffffffffffffffffffffffffffff01000000" ++
        "020000002000000000000000000000000000000000000000000900000000ac02" ++
        "0f4c7f109fc0bf7c8e1744c6bda696ac718e52a6b69e2c145d864d9396a1f2da" ++
        "02420000000000f87fe5ef73f4";
    var golden: [golden_hex.len / 2]u8 = undefined;
    _ = try std.fmt.hexToBytes(&golden, golden_hex);
    try std.testing.expectEqualSlices(u8, &golden, bytes);

    var result = try readAll(alloc, tmp.dir, path);
    defer result.deinit(alloc);
    try std.testing.expectEqual(@as(i64, -1), result.timestamps[0]);
    try std.testing.expectEqual(@as(u64, 300), result.write_sequences[0]);
    try std.testing.expectEqual(
        @as(u64, 0x7ff8000000000042),
        @as(u64, @bitCast(result.columns[0].values[0])),
    );
}

test "forward header versions are rejected before frame decoding" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = std.testing.allocator;
    const names = [_][]const u8{"price"};
    const value = [_]f64{42};
    const rows = [_]MarketRowView{
        .{ .ts_ns = 1, .write_sequence = 1, .values = &value },
    };
    const path = try write(alloc, tmp.dir, sampleMetadata(&names), &rows);
    defer alloc.free(path);
    const bytes = try readFileAlloc(alloc, tmp.dir, path);
    defer alloc.free(bytes);
    bytes[market_segment_magic.len] = 2;
    bytes[market_segment_magic.len + 1] = 0;
    {
        var file = try tmp.dir.createFile("future.mseg", .{});
        defer file.close();
        try file.writeAll(bytes);
    }
    try std.testing.expectError(
        error.UnsupportedMarketSegmentVersion,
        readAll(alloc, tmp.dir, "future.mseg"),
    );
}

test "signed hour buckets preserve negative epoch and i64 endpoints" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = std.testing.allocator;
    const names = [_][]const u8{"price"};

    const cases = [_]i64{
        std.math.minInt(i64),
        -hour_ns,
        -1,
        0,
        hour_ns - 1,
        std.math.maxInt(i64),
    };
    for (cases, 0..) |timestamp, idx| {
        var metadata = sampleMetadata(&names);
        metadata.hour = try hourBucket(timestamp);
        const value = [_]f64{@floatFromInt(idx)};
        const rows = [_]MarketRowView{
            .{ .ts_ns = timestamp, .write_sequence = idx + 1, .values = &value },
        };
        const path = try write(alloc, tmp.dir, metadata, &rows);
        defer alloc.free(path);
        var result = try readAll(alloc, tmp.dir, path);
        defer result.deinit(alloc);
        try std.testing.expectEqual(timestamp, result.timestamps[0]);
        try std.testing.expectEqual(@divFloor(timestamp, hour_ns), result.metadata.hour);
    }
}

test "all f64 bit patterns including NaNs survive round trip" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = std.testing.allocator;
    const names = [_][]const u8{"value"};
    const bits = [_]u64{
        0x7ff0000000000001,
        0x7ff8000000000042,
        0xfff8000000000001,
        0x8000000000000000,
        0x7ff0000000000000,
    };
    var values: [bits.len][1]f64 = undefined;
    var rows: [bits.len]MarketRowView = undefined;
    for (bits, 0..) |value_bits, idx| {
        values[idx] = .{@bitCast(value_bits)};
        rows[idx] = .{
            .ts_ns = @intCast(idx),
            .write_sequence = idx + 1,
            .values = &values[idx],
        };
    }
    const path = try write(alloc, tmp.dir, sampleMetadata(&names), &rows);
    defer alloc.free(path);
    var result = try readAll(alloc, tmp.dir, path);
    defer result.deinit(alloc);
    for (bits, result.columns[0].values) |expected_bits, actual| {
        try std.testing.expectEqual(expected_bits, @as(u64, @bitCast(actual)));
    }
}

test "equal timestamp and sequence require identical full-row bits" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = std.testing.allocator;
    const names = [_][]const u8{ "visible", "hidden" };
    const first = [_]f64{ 1, 2 };
    const second = [_]f64{ 1, 3 };
    const conflicting = [_]MarketRowView{
        .{ .ts_ns = 1, .write_sequence = 7, .values = &first },
        .{ .ts_ns = 1, .write_sequence = 7, .values = &second },
    };
    try std.testing.expectError(
        error.DuplicateWriteSequenceConflict,
        write(alloc, tmp.dir, sampleMetadata(&names), &conflicting),
    );
}

test "projected rows expose hidden-column conflict fingerprints" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = std.testing.allocator;
    const names = [_][]const u8{ "visible", "hidden" };
    const first = [_]f64{ 1, 2 };
    const second = [_]f64{ 1, 3 };
    const first_rows = [_]MarketRowView{
        .{ .ts_ns = 1, .write_sequence = 7, .values = &first },
    };
    const second_rows = [_]MarketRowView{
        .{ .ts_ns = 1, .write_sequence = 7, .values = &second },
    };
    try std.testing.expect(!std.mem.eql(
        u8,
        &fingerprintRow(&first),
        &fingerprintRow(&second),
    ));
    const first_path = try write(alloc, tmp.dir, sampleMetadata(&names), &first_rows);
    defer alloc.free(first_path);
    const second_path = try write(alloc, tmp.dir, sampleMetadata(&names), &second_rows);
    defer alloc.free(second_path);
    try std.testing.expect(!std.mem.eql(u8, first_path, second_path));

    const projection = [_][]const u8{"visible"};
    var first_result = try readProjectedRange(
        alloc,
        tmp.dir,
        first_path,
        1,
        1,
        &projection,
    );
    defer first_result.deinit(alloc);
    var second_result = try readProjectedRange(
        alloc,
        tmp.dir,
        second_path,
        1,
        1,
        &projection,
    );
    defer second_result.deinit(alloc);
    try std.testing.expectEqualSlices(
        f64,
        first_result.columns[0].values,
        second_result.columns[0].values,
    );
    try std.testing.expect(!std.mem.eql(
        u8,
        &first_result.row_fingerprints[0],
        &second_result.row_fingerprints[0],
    ));
    try std.testing.expectError(
        error.DuplicateWriteSequenceConflict,
        validateEqualSequenceFingerprints(
            first_result.row_fingerprints[0],
            second_result.row_fingerprints[0],
        ),
    );
}

test "absolute unsigned sequence varints cover endpoints and reject overlong encodings" {
    var encoded = std.array_list.Managed(u8).init(std.testing.allocator);
    defer encoded.deinit();
    try appendU64Varint(&encoded, 0);
    try appendU64Varint(&encoded, 300);
    try appendU64Varint(&encoded, std.math.maxInt(u64));
    var cursor: usize = 0;
    try std.testing.expectEqual(@as(u64, 0), try decodeU64Varint(encoded.items, &cursor));
    try std.testing.expectEqual(@as(u64, 300), try decodeU64Varint(encoded.items, &cursor));
    try std.testing.expectEqual(
        @as(u64, std.math.maxInt(u64)),
        try decodeU64Varint(encoded.items, &cursor),
    );
    try std.testing.expectEqual(encoded.items.len, cursor);

    const overlong = [_]u8{0x80} ** 10;
    cursor = 0;
    try std.testing.expectError(
        error.InvalidUnsignedVarint,
        decodeU64Varint(&overlong, &cursor),
    );
}

test "market segment roots round trip exact bytes deterministically" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const alloc = std.testing.allocator;

    const store_path = try std.fmt.allocPrint(
        alloc,
        ".zig-cache/tmp/{s}/market-segment-root-store",
        .{tmp.sub_path},
    );
    defer alloc.free(store_path);
    var store = try object_store.ObjectStore.init(alloc, store_path, .none);
    defer store.deinit();

    const names = [_][]const u8{ "bid", "ask" };
    const values = [_][2]f64{
        .{ 100.25, 100.5 },
        .{ 100.5, 100.75 },
        .{ 100.75, 101.0 },
    };
    const rows = [_]MarketRowView{
        .{ .ts_ns = 10, .write_sequence = 7, .values = &values[0] },
        .{ .ts_ns = 20, .write_sequence = 8, .values = &values[1] },
        .{ .ts_ns = 30, .write_sequence = 9, .values = &values[2] },
    };
    const path = try write(alloc, tmp.dir, sampleMetadata(&names), &rows);
    defer alloc.free(path);
    const bytes = try readFileAlloc(alloc, tmp.dir, path);
    defer alloc.free(bytes);

    const root_a = try writeSegmentRootForFile(alloc, tmp.dir, &store, path, 17);
    const root_b = try writeSegmentRootFromBytes(alloc, &store, bytes, 17);
    try std.testing.expect(root_a.eql(root_b));

    var root_tree = try loadTreeObject(alloc, &store, root_a);
    defer root_tree.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 3), root_tree.entries.len);
    try std.testing.expectEqualStrings("block_index", root_tree.entries[0].name);
    try std.testing.expectEqualStrings("blocks", root_tree.entries[1].name);
    try std.testing.expectEqualStrings("meta", root_tree.entries[2].name);
    var blocks_tree = try loadTreeObject(alloc, &store, root_tree.entries[1].object_id);
    defer blocks_tree.deinit(alloc);
    try std.testing.expectEqualStrings("0000000000000000", blocks_tree.entries[0].name);
    var block_tree = try loadTreeObject(alloc, &store, blocks_tree.entries[0].object_id);
    defer block_tree.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 5), block_tree.entries.len);
    try std.testing.expectEqualStrings("fingerprints", block_tree.entries[0].name);
    try std.testing.expectEqualStrings("sequences", block_tree.entries[1].name);
    try std.testing.expectEqualStrings("stats", block_tree.entries[2].name);
    try std.testing.expectEqualStrings("timestamps", block_tree.entries[3].name);
    try std.testing.expectEqualStrings("values", block_tree.entries[4].name);
    var values_tree = try loadTreeObject(alloc, &store, block_tree.entries[4].object_id);
    defer values_tree.deinit(alloc);
    try std.testing.expectEqualStrings("00000000", values_tree.entries[0].name);
    try std.testing.expectEqualStrings("00000001", values_tree.entries[1].name);

    var metadata = try inspectSegmentRoot(alloc, &store, root_a);
    defer metadata.deinit(alloc);
    try std.testing.expectEqual(@as(u64, rows.len), metadata.count);
    try std.testing.expectEqual(@as(u32, 17), metadata.extent_chunk_bytes);
    try std.testing.expectEqualStrings("book.top", metadata.metric);

    const restored_path = try restoreSegmentRootToLocalMirror(alloc, tmp.dir, &store, root_a);
    defer alloc.free(restored_path);
    const restored_bytes = try readFileAlloc(alloc, tmp.dir, restored_path);
    defer alloc.free(restored_bytes);
    try std.testing.expectEqualSlices(u8, bytes, restored_bytes);

    var result = try readAllSegmentRoot(alloc, &store, root_a);
    defer result.deinit(alloc);
    try std.testing.expectEqualSlices(i64, &.{ 10, 20, 30 }, result.timestamps);
    try std.testing.expectEqualSlices(u64, &.{ 7, 8, 9 }, result.write_sequences);
    try std.testing.expectEqualSlices(f64, &.{ 100.25, 100.5, 100.75 }, result.columns[0].values);

    const object_ids = try collectSegmentRootObjectIds(alloc, &store, root_a);
    defer alloc.free(object_ids);
    try std.testing.expect(object_ids.len >= 4);
}

test "market segment roots support packed projection and CAS block cursor" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const alloc = std.testing.allocator;

    const store_path = try std.fmt.allocPrint(
        alloc,
        ".zig-cache/tmp/{s}/market-segment-packed-store",
        .{tmp.sub_path},
    );
    defer alloc.free(store_path);
    var store = try object_store.ObjectStore.init(alloc, store_path, .none);
    defer store.deinit();

    const names = [_][]const u8{ "bid", "ask", "size" };
    const row_count = market_segment_block_rows + 5;
    const values = try alloc.alloc([3]f64, row_count);
    defer alloc.free(values);
    const rows = try alloc.alloc(MarketRowView, row_count);
    defer alloc.free(rows);
    for (values, rows, 0..) |*value, *row, idx| {
        value.* = .{
            @floatFromInt(idx),
            @floatFromInt(idx + 1),
            @floatFromInt(idx * 10),
        };
        row.* = .{
            .ts_ns = @intCast(idx),
            .write_sequence = idx + 100,
            .values = value,
        };
    }

    const path = try write(alloc, tmp.dir, sampleMetadata(&names), rows);
    defer alloc.free(path);
    const original_bytes = try readFileAlloc(alloc, tmp.dir, path);
    defer alloc.free(original_bytes);
    const root_id = try writeSegmentRootForFile(alloc, tmp.dir, &store, path, 4096);

    const ids = try store.listIds(alloc);
    defer alloc.free(ids);
    var pack = try store.writePack(alloc, ids);
    defer pack.deinit(alloc);

    const restored_path = try restoreSegmentRootToLocalMirror(
        alloc,
        tmp.dir,
        &store,
        root_id,
    );
    defer alloc.free(restored_path);
    const restored_bytes = try readFileAlloc(alloc, tmp.dir, restored_path);
    defer alloc.free(restored_bytes);
    try std.testing.expectEqualSlices(u8, original_bytes, restored_bytes);

    var cursor = try MarketSegmentBlockCursor.open(alloc, &store, root_id);
    defer cursor.deinit();
    var first = (try cursor.next()) orelse return error.MissingMarketSegmentBlock;
    defer first.deinit(alloc);
    try std.testing.expectEqual(@as(u32, 0), first.index);
    try std.testing.expectEqual(market_segment_block_rows, first.count);
    var second = (try cursor.next()) orelse return error.MissingMarketSegmentBlock;
    defer second.deinit(alloc);
    try std.testing.expectEqual(@as(u32, 1), second.index);
    try std.testing.expectEqual(@as(u32, 5), second.count);
    try std.testing.expect((try cursor.next()) == null);

    const projection = [_][]const u8{ "size", "bid" };
    var result = try readProjectedRangeSegmentRoot(
        alloc,
        &store,
        root_id,
        market_segment_block_rows + 1,
        market_segment_block_rows + 3,
        &projection,
    );
    defer result.deinit(alloc);
    try std.testing.expectEqual(@as(u32, 2), result.stats.blocks_total);
    try std.testing.expectEqual(@as(u32, 1), result.stats.blocks_scanned);
    try std.testing.expectEqual(@as(u32, 1), result.stats.blocks_pruned);
    try std.testing.expectEqual(@as(usize, 3), result.timestamps.len);
    try std.testing.expectEqualStrings("size", result.columns[0].name);
    try std.testing.expectEqualStrings("bid", result.columns[1].name);
    try std.testing.expectEqual(@as(f64, (market_segment_block_rows + 1) * 10), result.columns[0].values[0]);
    try std.testing.expectEqual(@as(f64, market_segment_block_rows + 1), result.columns[1].values[0]);
}

test "market segment CAS projection isolates unrequested columns and integrity walks all streams" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const alloc = std.testing.allocator;
    const store_path = try std.fmt.allocPrint(
        alloc,
        ".zig-cache/tmp/{s}/market-projection-isolation",
        .{tmp.sub_path},
    );
    defer alloc.free(store_path);
    var store = try object_store.ObjectStore.init(alloc, store_path, .none);
    defer store.deinit();

    const names = [_][]const u8{ "c0", "c1", "c2", "c3", "c4", "c5", "c6", "c7" };
    const values = [_][8]f64{
        .{ 1, 11, 21, 31, 41, 51, 61, 71 },
        .{ 2, 12, 22, 32, 42, 52, 62, 72 },
    };
    const rows = [_]MarketRowView{
        .{ .ts_ns = 10, .write_sequence = 101, .values = &values[0] },
        .{ .ts_ns = 20, .write_sequence = 102, .values = &values[1] },
    };
    const path = try write(alloc, tmp.dir, sampleMetadata(&names), &rows);
    defer alloc.free(path);
    const bytes = try readFileAlloc(alloc, tmp.dir, path);
    defer alloc.free(bytes);
    const root_id = try writeSegmentRootFromBytes(alloc, &store, bytes, 8);

    const unrequested_chunk = try marketValueChunkId(alloc, &store, root_id, 0, 7);
    const reachable = try collectSegmentRootObjectIds(alloc, &store, root_id);
    defer alloc.free(reachable);
    var found_unrequested_chunk = false;
    for (reachable) |id| {
        if (id.eql(unrequested_chunk)) found_unrequested_chunk = true;
    }
    try std.testing.expect(found_unrequested_chunk);
    try store.delete(unrequested_chunk);
    const projection = [_][]const u8{ "c0", "c2" };
    var projected = try readProjectedRangeSegmentRoot(
        alloc,
        &store,
        root_id,
        0,
        100,
        &projection,
    );
    defer projected.deinit(alloc);
    try std.testing.expectEqual(@as(u64, 2), projected.stats.columns_decoded);
    try std.testing.expectEqualSlices(f64, &.{ 1, 2 }, projected.columns[0].values);
    try std.testing.expectEqualSlices(f64, &.{ 21, 22 }, projected.columns[1].values);
    try std.testing.expectEqualSlices(
        u8,
        &fingerprintRow(&values[0]),
        &projected.row_fingerprints[0],
    );
    try std.testing.expectError(
        error.FileNotFound,
        validateSegmentRoot(alloc, &store, root_id),
    );

    const restored_root = try writeSegmentRootFromBytes(alloc, &store, bytes, 8);
    try std.testing.expect(root_id.eql(restored_root));
    const requested_chunk = try marketValueChunkId(alloc, &store, root_id, 0, 0);
    try store.delete(requested_chunk);
    try std.testing.expectError(
        error.FileNotFound,
        readProjectedRangeSegmentRoot(alloc, &store, root_id, 0, 100, &projection),
    );
}

test "market segment CAS time pruning avoids unrelated corrupt block streams" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const alloc = std.testing.allocator;
    const store_path = try std.fmt.allocPrint(
        alloc,
        ".zig-cache/tmp/{s}/market-time-pruning-isolation",
        .{tmp.sub_path},
    );
    defer alloc.free(store_path);
    var store = try object_store.ObjectStore.init(alloc, store_path, .none);
    defer store.deinit();

    const names = [_][]const u8{"price"};
    const row_count = market_segment_block_rows + 2;
    const values = try alloc.alloc([1]f64, row_count);
    defer alloc.free(values);
    const rows = try alloc.alloc(MarketRowView, row_count);
    defer alloc.free(rows);
    for (values, rows, 0..) |*value, *row, idx| {
        value.* = .{@floatFromInt(idx)};
        row.* = .{
            .ts_ns = @intCast(idx),
            .write_sequence = idx + 1,
            .values = value,
        };
    }
    const path = try write(alloc, tmp.dir, sampleMetadata(&names), rows);
    defer alloc.free(path);
    const root_id = try writeSegmentRootForFile(alloc, tmp.dir, &store, path, 64);
    const unrelated_chunk = try marketValueChunkId(alloc, &store, root_id, 0, 0);
    try store.delete(unrelated_chunk);

    const projection = [_][]const u8{"price"};
    var result = try readProjectedRangeSegmentRoot(
        alloc,
        &store,
        root_id,
        market_segment_block_rows,
        market_segment_block_rows + 1,
        &projection,
    );
    defer result.deinit(alloc);
    try std.testing.expectEqual(@as(u32, 1), result.stats.blocks_pruned);
    try std.testing.expectEqual(@as(u32, 1), result.stats.blocks_scanned);
    try std.testing.expectEqual(@as(usize, 2), result.timestamps.len);
    try std.testing.expectError(
        error.FileNotFound,
        validateSegmentRoot(alloc, &store, root_id),
    );
}

test "market segment CAS projected reads always require intact fingerprints" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const alloc = std.testing.allocator;
    const store_path = try std.fmt.allocPrint(
        alloc,
        ".zig-cache/tmp/{s}/market-fingerprint-integrity",
        .{tmp.sub_path},
    );
    defer alloc.free(store_path);
    var store = try object_store.ObjectStore.init(alloc, store_path, .none);
    defer store.deinit();

    const names = [_][]const u8{ "price", "size" };
    const values = [_][2]f64{ .{ 42, 10 }, .{ 43, 11 } };
    const rows = [_]MarketRowView{
        .{ .ts_ns = 10, .write_sequence = 1, .values = &values[0] },
        .{ .ts_ns = 20, .write_sequence = 2, .values = &values[1] },
    };
    const path = try write(alloc, tmp.dir, sampleMetadata(&names), &rows);
    defer alloc.free(path);
    const root_id = try writeSegmentRootForFile(alloc, tmp.dir, &store, path, 8);
    const fingerprint_chunk = try marketBlockStreamChunkId(
        alloc,
        &store,
        root_id,
        0,
        "fingerprints",
    );
    try corruptLooseMarketObject(store.root, fingerprint_chunk);
    const projection = [_][]const u8{"price"};
    try std.testing.expectError(
        error.ObjectHashMismatch,
        readProjectedRangeSegmentRoot(alloc, &store, root_id, 0, 100, &projection),
    );
}

test "market segment roots reject missing corrupt and malformed CAS objects" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const alloc = std.testing.allocator;

    const names = [_][]const u8{"price"};
    const values = [_][1]f64{
        .{42},
        .{43},
    };
    const rows = [_]MarketRowView{
        .{ .ts_ns = 10, .write_sequence = 1, .values = &values[0] },
        .{ .ts_ns = 20, .write_sequence = 2, .values = &values[1] },
    };

    const missing_store_path = try std.fmt.allocPrint(
        alloc,
        ".zig-cache/tmp/{s}/market-segment-missing-store",
        .{tmp.sub_path},
    );
    defer alloc.free(missing_store_path);
    var missing_store = try object_store.ObjectStore.init(alloc, missing_store_path, .none);
    defer missing_store.deinit();

    const path = try write(alloc, tmp.dir, sampleMetadata(&names), &rows);
    defer alloc.free(path);
    const root_id = try writeSegmentRootForFile(alloc, tmp.dir, &missing_store, path, 8);
    const missing_chunk_id = try firstMarketValueChunkId(alloc, &missing_store, root_id);
    try missing_store.delete(missing_chunk_id);
    try std.testing.expectError(
        error.FileNotFound,
        readAllSegmentRoot(alloc, &missing_store, root_id),
    );

    const corrupt_store_path = try std.fmt.allocPrint(
        alloc,
        ".zig-cache/tmp/{s}/market-segment-corrupt-store",
        .{tmp.sub_path},
    );
    defer alloc.free(corrupt_store_path);
    var corrupt_store = try object_store.ObjectStore.init(alloc, corrupt_store_path, .none);
    defer corrupt_store.deinit();
    const corrupt_root = try writeSegmentRootForFile(alloc, tmp.dir, &corrupt_store, path, 8);
    const corrupt_chunk_id = try firstMarketValueChunkId(alloc, &corrupt_store, corrupt_root);
    try corruptLooseMarketObject(corrupt_store.root, corrupt_chunk_id);
    try std.testing.expectError(
        error.ObjectHashMismatch,
        readAllSegmentRoot(alloc, &corrupt_store, corrupt_root),
    );

    const malformed_store_path = try std.fmt.allocPrint(
        alloc,
        ".zig-cache/tmp/{s}/market-segment-malformed-store",
        .{tmp.sub_path},
    );
    defer alloc.free(malformed_store_path);
    var malformed_store = try object_store.ObjectStore.init(alloc, malformed_store_path, .none);
    defer malformed_store.deinit();
    const malformed_root = try writeSegmentRootForFile(alloc, tmp.dir, &malformed_store, path, 8);
    var root_tree = try loadTreeObject(alloc, &malformed_store, malformed_root);
    defer root_tree.deinit(alloc);
    const meta_id = try findRequiredTreeEntry(
        root_tree.entries,
        "meta",
        .blob,
        error.MissingMarketSegmentRootMeta,
    );
    const block_index_id = try findRequiredTreeEntry(
        root_tree.entries,
        "block_index",
        .blob,
        error.MissingMarketSegmentBlockIndex,
    );
    const blocks_id = try findRequiredTreeEntry(
        root_tree.entries,
        "blocks",
        .tree,
        error.MissingMarketSegmentRootBlocks,
    );
    var bad_entries = [_]TreeEntry{
        .{
            .name = try alloc.dupe(u8, "block_index"),
            .object_type = .tree,
            .object_id = block_index_id,
        },
        .{
            .name = try alloc.dupe(u8, "blocks"),
            .object_type = .tree,
            .object_id = blocks_id,
        },
        .{
            .name = try alloc.dupe(u8, "meta"),
            .object_type = .blob,
            .object_id = meta_id,
        },
    };
    defer {
        for (&bad_entries) |*entry| entry.deinit(alloc);
    }
    const bad_root = try putTree(alloc, &malformed_store, bad_entries[0..]);
    try std.testing.expectError(
        error.InvalidMarketSegmentRootTree,
        inspectSegmentRoot(alloc, &malformed_store, bad_root),
    );
}

fn firstMarketValueChunkId(
    alloc: std.mem.Allocator,
    store: *object_store.ObjectStore,
    root_id: object_store.ObjectId,
) !object_store.ObjectId {
    return try marketValueChunkId(alloc, store, root_id, 0, 0);
}

fn marketValueChunkId(
    alloc: std.mem.Allocator,
    store: *object_store.ObjectStore,
    root_id: object_store.ObjectId,
    block_idx: usize,
    column_idx: usize,
) !object_store.ObjectId {
    var root = try loadMarketRoot(alloc, store, root_id);
    defer {
        root.root_tree.deinit(alloc);
        root.metadata.deinit(alloc);
    }
    var blocks = try loadTreeObject(alloc, store, root.blocks_id);
    defer blocks.deinit(alloc);
    if (block_idx >= blocks.entries.len) return error.MissingMarketSegmentBlock;
    var block = try loadTreeObject(alloc, store, blocks.entries[block_idx].object_id);
    defer block.deinit(alloc);
    const values_id = try findRequiredTreeEntry(
        block.entries,
        "values",
        .tree,
        error.MissingMarketSegmentValues,
    );
    var values = try loadTreeObject(alloc, store, values_id);
    defer values.deinit(alloc);
    if (column_idx >= values.entries.len) return error.UnknownMarketColumn;
    var extent = try loadTreeObject(alloc, store, values.entries[column_idx].object_id);
    defer extent.deinit(alloc);
    if (extent.entries.len == 0 or extent.entries[0].object_type != .blob) {
        return error.InvalidExtentTreeObject;
    }
    return extent.entries[0].object_id;
}

fn marketBlockStreamChunkId(
    alloc: std.mem.Allocator,
    store: *object_store.ObjectStore,
    root_id: object_store.ObjectId,
    block_idx: usize,
    stream_name: []const u8,
) !object_store.ObjectId {
    var root = try loadMarketRoot(alloc, store, root_id);
    defer {
        root.root_tree.deinit(alloc);
        root.metadata.deinit(alloc);
    }
    var blocks = try loadTreeObject(alloc, store, root.blocks_id);
    defer blocks.deinit(alloc);
    if (block_idx >= blocks.entries.len) return error.MissingMarketSegmentBlock;
    var block = try loadTreeObject(alloc, store, blocks.entries[block_idx].object_id);
    defer block.deinit(alloc);
    const stream_id = try findRequiredTreeEntry(
        block.entries,
        stream_name,
        .tree,
        error.MissingMarketSegmentStream,
    );
    var extent = try loadTreeObject(alloc, store, stream_id);
    defer extent.deinit(alloc);
    if (extent.entries.len == 0 or extent.entries[0].object_type != .blob) {
        return error.InvalidExtentTreeObject;
    }
    return extent.entries[0].object_id;
}

fn corruptLooseMarketObject(root: std.fs.Dir, id: object_store.ObjectId) !void {
    const object_name = id.toHex();
    const bucket = std.fmt.bytesToHex([_]u8{id.hash[0]}, .lower);
    const path = try std.fmt.allocPrint(
        std.testing.allocator,
        "objects/{s}/{s}",
        .{ bucket[0..], object_name[0..] },
    );
    defer std.testing.allocator.free(path);
    var payload = std.array_list.Managed(u8).init(std.testing.allocator);
    defer payload.deinit();
    try payload.append(@intFromEnum(object_store.ObjectType.blob));
    try appendInt(&payload, u32, 3);
    try payload.appendSlice("bad");
    try root.writeFile(.{
        .sub_path = path,
        .data = payload.items,
        .flags = .{},
    });
}
