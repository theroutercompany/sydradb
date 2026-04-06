const std = @import("std");
const types = @import("../types.zig");
const object_store = @import("object_store.zig");
const extents = @import("extents.zig");
const manifest_mod = @import("manifest.zig");

// Segment format v2 (SYSEG3):
// [magic:6 'SYSEG2'][series_id:u64][hour:i64][count:u32]
// [start_ts:i64][end_ts:i64][ts_codec:u8][val_codec:u8]
// [series_len:u32][tags_len:u32][series bytes][canonical tags bytes]
// payload depends on codecs (default: ts=dod+zigzag varint, val=gorilla-xor byte-aligned)
// Back-compat: v0 (SYSEG1) supports ts delta varint + raw f64 values; v1 (SYSEG2) omits selector metadata.

pub const SelectorMetadata = struct {
    series: []u8,
    canonical_tags: []u8,

    pub fn deinit(self: *SelectorMetadata, alloc: std.mem.Allocator) void {
        alloc.free(self.series);
        alloc.free(self.canonical_tags);
    }
};

pub const SelectorMetadataView = struct {
    series: []const u8,
    canonical_tags: []const u8,
};

pub const SegmentMetadata = struct {
    series_id: types.SeriesId,
    hour_bucket: i64,
    count: u32,
    start_ts: i64,
    end_ts: i64,
    ts_codec: u8,
    val_codec: u8,
    file_size: u64,
    selector: ?SelectorMetadata = null,

    pub fn deinit(self: *SegmentMetadata, alloc: std.mem.Allocator) void {
        if (self.selector) |*selector| selector.deinit(alloc);
    }
};

pub const SegmentRootWriteMetadata = struct {
    series_id: types.SeriesId,
    hour_bucket: i64,
    ts_codec: u8,
    val_codec: u8,
    selector: ?SelectorMetadataView = null,
};

pub const SegmentRootMetadata = struct {
    series_id: types.SeriesId,
    hour_bucket: i64,
    count: u32,
    start_ts: i64,
    end_ts: i64,
    ts_codec: u8,
    val_codec: u8,
    block_point_count: u32,
    block_count: u32,
    extent_chunk_bytes: u32,
    selector: ?SelectorMetadata = null,

    pub fn deinit(self: *SegmentRootMetadata, alloc: std.mem.Allocator) void {
        if (self.selector) |*selector| selector.deinit(alloc);
    }
};

pub const SegmentBlockStats = struct {
    count: u32,
    min_ts: i64,
    max_ts: i64,
    first_ts: i64,
    last_ts: i64,
    ts_size_bytes: u64,
    values_size_bytes: u64,
};

pub const segment_root_block_point_count: u32 = 4096;

const segment_root_meta_version: u8 = 1;
const segment_block_stats_version: u8 = 1;

const TreeEntry = struct {
    name: []u8,
    object_type: object_store.ObjectType,
    object_id: object_store.ObjectId,

    fn deinit(self: *TreeEntry, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
    }
};

pub fn writeSegment(alloc: std.mem.Allocator, data_dir: std.fs.Dir, series_id: types.SeriesId, hour: i64, points: []const types.Point) ![]const u8 {
    return writeSegmentWithMetadata(alloc, data_dir, series_id, hour, points, null);
}

pub fn writeSegmentWithMetadata(
    alloc: std.mem.Allocator,
    data_dir: std.fs.Dir,
    series_id: types.SeriesId,
    hour: i64,
    points: []const types.Point,
    selector_metadata: ?SelectorMetadataView,
) ![]const u8 {
    // Ensure directory for hour exists
    var hour_buf: [32]u8 = undefined;
    const hour_dir = try std.fmt.bufPrint(&hour_buf, "segments/{d}", .{hour});
    data_dir.makePath(hour_dir) catch {};
    const start_ts = points[0].ts;
    const end_ts = points[points.len - 1].ts;
    var file_name_buf: [160]u8 = undefined;
    const now_ms = std.time.milliTimestamp();
    // Unique: {series}-{start}-{end}-{ms}.seg
    const file_name = try std.fmt.bufPrint(&file_name_buf, "{s}/{x}-{d}-{d}-{d}.seg", .{ hour_dir, series_id, start_ts, end_ts, now_ms });
    var f = try data_dir.createFile(file_name, .{ .read = true });
    defer f.close();

    var write_buf: [4096]u8 = undefined;
    var writer_state = f.writer(&write_buf);
    var writer = anyWriter(&writer_state.interface);

    try writer.writeAll(if (selector_metadata != null) "SYSEG3" else "SYSEG2");
    var tmp8: [8]u8 = undefined;
    std.mem.writeInt(u64, &tmp8, series_id, .little);
    try writer.writeAll(tmp8[0..8]);
    std.mem.writeInt(i64, &tmp8, hour, .little);
    try writer.writeAll(tmp8[0..8]);
    var tmp4: [4]u8 = undefined;
    const cnt_u32: u32 = @intCast(points.len);
    std.mem.writeInt(u32, &tmp4, cnt_u32, .little);
    try writer.writeAll(tmp4[0..4]);
    std.mem.writeInt(i64, &tmp8, points[0].ts, .little);
    try writer.writeAll(tmp8[0..8]);
    std.mem.writeInt(i64, &tmp8, points[points.len - 1].ts, .little);
    try writer.writeAll(tmp8[0..8]);
    try writer.writeByte(1); // ts codec: 1=dod-zzvar
    try writer.writeByte(1); // val codec: 1=gorilla-xor
    if (selector_metadata) |selector| {
        std.mem.writeInt(u32, &tmp4, @intCast(selector.series.len), .little);
        try writer.writeAll(tmp4[0..4]);
        std.mem.writeInt(u32, &tmp4, @intCast(selector.canonical_tags.len), .little);
        try writer.writeAll(tmp4[0..4]);
        try writer.writeAll(selector.series);
        try writer.writeAll(selector.canonical_tags);
    }

    // Encode timestamps (delta-of-delta zigzag varint)
    try @import("../codec/gorilla.zig").encodeTsDoD(writer, points[0].ts, points);
    // Encode values using gorilla-like XOR
    var vals = try alloc.alloc(f64, points.len);
    defer alloc.free(vals);
    for (points, 0..) |p, i| vals[i] = p.value;
    try @import("../codec/gorilla.zig").encodeF64(writer, vals);

    try writer_state.end();

    return try alloc.dupe(u8, file_name);
}

pub fn writeSegmentRootForFile(
    alloc: std.mem.Allocator,
    data_dir: std.fs.Dir,
    store: *object_store.ObjectStore,
    path: []const u8,
    extent_chunk_bytes: u32,
) !object_store.ObjectId {
    var metadata = try inspectMetadata(alloc, data_dir, path);
    defer metadata.deinit(alloc);

    const points = try readAll(alloc, data_dir, path);
    defer alloc.free(points);

    return try writeSegmentRoot(alloc, store, .{
        .series_id = metadata.series_id,
        .hour_bucket = metadata.hour_bucket,
        .ts_codec = metadata.ts_codec,
        .val_codec = metadata.val_codec,
        .selector = if (metadata.selector) |selector| .{
            .series = selector.series,
            .canonical_tags = selector.canonical_tags,
        } else null,
    }, points, extent_chunk_bytes);
}

pub fn writeSegmentRoot(
    alloc: std.mem.Allocator,
    store: *object_store.ObjectStore,
    metadata: SegmentRootWriteMetadata,
    points: []const types.Point,
    extent_chunk_bytes: u32,
) !object_store.ObjectId {
    if (points.len == 0) return error.EmptySegment;

    const effective_chunk_bytes = if (extent_chunk_bytes == 0) extents.DefaultChunkBytes else extent_chunk_bytes;
    const block_count = std.math.divCeil(u32, @intCast(points.len), segment_root_block_point_count) catch unreachable;

    var block_entries = std.array_list.Managed(TreeEntry).init(alloc);
    defer {
        for (block_entries.items) |*entry| entry.deinit(alloc);
        block_entries.deinit();
    }

    var block_start: usize = 0;
    var block_index: usize = 0;
    while (block_start < points.len) : (block_index += 1) {
        const block_end = @min(points.len, block_start + segment_root_block_point_count);
        const block_points = points[block_start..block_end];

        const ts_bytes = try encodeBlockTimestamps(alloc, block_points);
        defer alloc.free(ts_bytes);
        const values_bytes = try encodeBlockValues(alloc, block_points);
        defer alloc.free(values_bytes);

        const ts_extent = try extents.writeAll(alloc, store, ts_bytes, effective_chunk_bytes);
        const values_extent = try extents.writeAll(alloc, store, values_bytes, effective_chunk_bytes);

        const stats_payload = try encodeSegmentBlockStats(alloc, .{
            .count = @intCast(block_points.len),
            .min_ts = block_points[0].ts,
            .max_ts = block_points[block_points.len - 1].ts,
            .first_ts = block_points[0].ts,
            .last_ts = block_points[block_points.len - 1].ts,
            .ts_size_bytes = ts_bytes.len,
            .values_size_bytes = values_bytes.len,
        });
        defer alloc.free(stats_payload);
        const stats_id = try store.put(.blob, stats_payload);

        var per_block = std.array_list.Managed(TreeEntry).init(alloc);
        defer {
            for (per_block.items) |*entry| entry.deinit(alloc);
            per_block.deinit();
        }

        try per_block.append(.{
            .name = try alloc.dupe(u8, "stats"),
            .object_type = .blob,
            .object_id = stats_id,
        });
        try per_block.append(.{
            .name = try alloc.dupe(u8, "ts"),
            .object_type = .tree,
            .object_id = ts_extent.root_id,
        });
        try per_block.append(.{
            .name = try alloc.dupe(u8, "values"),
            .object_type = .tree,
            .object_id = values_extent.root_id,
        });

        const block_tree_id = try putTree(alloc, store, per_block.items);
        try block_entries.append(.{
            .name = try std.fmt.allocPrint(alloc, "{d:0>16}", .{block_index}),
            .object_type = .tree,
            .object_id = block_tree_id,
        });

        block_start = block_end;
    }

    const blocks_tree_id = try putTree(alloc, store, block_entries.items);
    var root_metadata = SegmentRootMetadata{
        .series_id = metadata.series_id,
        .hour_bucket = metadata.hour_bucket,
        .count = @intCast(points.len),
        .start_ts = points[0].ts,
        .end_ts = points[points.len - 1].ts,
        .ts_codec = metadata.ts_codec,
        .val_codec = metadata.val_codec,
        .block_point_count = segment_root_block_point_count,
        .block_count = block_count,
        .extent_chunk_bytes = effective_chunk_bytes,
        .selector = if (metadata.selector) |selector| .{
            .series = try alloc.dupe(u8, selector.series),
            .canonical_tags = try alloc.dupe(u8, selector.canonical_tags),
        } else null,
    };
    defer root_metadata.deinit(alloc);
    const meta_payload = try encodeSegmentRootMetadata(alloc, root_metadata);
    defer alloc.free(meta_payload);
    const meta_id = try store.put(.blob, meta_payload);

    var root_entries = [_]TreeEntry{
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

pub fn readAll(alloc: std.mem.Allocator, data_dir: std.fs.Dir, path: []const u8) ![]types.Point {
    var f = try data_dir.openFile(path, .{});
    defer f.close();

    const stat = try f.stat();
    const bytes = try alloc.alloc(u8, @intCast(stat.size));
    defer alloc.free(bytes);
    const read_len = try f.readAll(bytes);
    if (read_len != bytes.len) return error.CorruptSegment;
    return try readAllFromBytes(alloc, bytes);
}

pub fn readAllDescriptor(alloc: std.mem.Allocator, data_dir: std.fs.Dir, store: *object_store.ObjectStore, descriptor: anytype) ![]types.Point {
    const Descriptor = @TypeOf(descriptor);
    if (@hasField(Descriptor, "segment_root")) {
        if (descriptor.segment_root) |segment_root| {
            return try readAllSegmentRoot(alloc, store, segment_root);
        }
    }
    if (@hasField(Descriptor, "content")) {
        if (descriptor.content) |content| {
            switch (content) {
                .blob => |content_id| {
                    const loaded = try store.get(alloc, content_id);
                    defer alloc.free(loaded.payload);
                    if (loaded.obj_type != .blob) return error.InvalidSegmentContentObject;
                    return try readAllFromBytes(alloc, loaded.payload);
                },
                .extent_tree => |tree| {
                    const bytes = try extents.readAll(alloc, store, tree);
                    defer alloc.free(bytes);
                    return try readAllFromBytes(alloc, bytes);
                },
            }
        }
    }
    if (@hasField(Descriptor, "content_id")) {
        if (descriptor.content_id) |content_id| {
            const loaded = try store.get(alloc, content_id);
            defer alloc.free(loaded.payload);
            if (loaded.obj_type != .blob) return error.InvalidSegmentContentObject;
            return try readAllFromBytes(alloc, loaded.payload);
        }
    }
    if (@hasField(Descriptor, "path") and descriptor.path.len != 0) {
        return try readAll(alloc, data_dir, descriptor.path);
    }
    return error.MissingSegmentContent;
}

pub fn readAllSegmentRoot(
    alloc: std.mem.Allocator,
    store: *object_store.ObjectStore,
    root_id: object_store.ObjectId,
) ![]types.Point {
    var points = std.array_list.Managed(types.Point).init(alloc);
    errdefer points.deinit();
    try appendSegmentRootPoints(alloc, store, root_id, null, null, &points);
    return try points.toOwnedSlice();
}

pub fn readAllFromBytes(alloc: std.mem.Allocator, bytes: []const u8) ![]types.Point {
    var stream = std.io.fixedBufferStream(bytes);
    const reader = stream.reader().any();
    var read_buf: [4096]u8 = undefined;
    _ = &read_buf;

    var hdr: [6]u8 = undefined;
    try reader.readNoEof(&hdr);
    var tmp8: [8]u8 = undefined;
    try reader.readNoEof(tmp8[0..8]); // series id (unused)
    try reader.readNoEof(tmp8[0..8]); // hour bucket (unused)
    var tmp4: [4]u8 = undefined;
    try reader.readNoEof(tmp4[0..4]);
    const count = std.mem.readInt(u32, &tmp4, .little);
    try reader.readNoEof(tmp8[0..8]);
    const start = std.mem.readInt(i64, &tmp8, .little);
    try reader.readNoEof(tmp8[0..8]); // end

    if (std.mem.eql(u8, hdr[0..6], "SYSEG1")) {
        var ts_list = try alloc.alloc(i64, count);
        defer alloc.free(ts_list);
        var prev_ts: i64 = 0;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const delta = try decodeZigZagVarint(reader);
            const ts: i64 = if (i == 0) delta else prev_ts + delta;
            ts_list[i] = ts;
            prev_ts = ts;
        }
        var points = try alloc.alloc(types.Point, count);
        var j: usize = 0;
        while (j < count) : (j += 1) {
            try reader.readNoEof(tmp8[0..8]);
            const u: u64 = std.mem.readInt(u64, &tmp8, .little);
            points[j] = .{ .ts = ts_list[j], .value = @bitCast(u) };
        }
        return points;
    }

    const ts_codec = try readByte(reader);
    const val_codec = try readByte(reader);
    _ = ts_codec;
    _ = val_codec;
    if (std.mem.eql(u8, hdr[0..6], "SYSEG3")) {
        try skipSelectorMetadata(reader);
    }
    const ts_list = try @import("../codec/gorilla.zig").decodeTsDoD(alloc, reader, count, start);
    defer alloc.free(ts_list);
    const vals = try @import("../codec/gorilla.zig").decodeF64(alloc, reader, count);
    defer alloc.free(vals);
    var points = try alloc.alloc(types.Point, count);
    for (ts_list, 0..) |ts, idx| {
        points[idx] = .{ .ts = ts, .value = vals[idx] };
    }
    return points;
}

pub fn inspectMetadata(alloc: std.mem.Allocator, data_dir: std.fs.Dir, path: []const u8) !SegmentMetadata {
    var f = try data_dir.openFile(path, .{});
    defer f.close();

    const stat = try f.stat();

    var read_buf: [4096]u8 = undefined;
    var reader_state = f.reader(&read_buf);
    const reader = std.Io.Reader.adaptToOldInterface(&reader_state.interface);

    var hdr: [6]u8 = undefined;
    try reader.readNoEof(&hdr);
    var tmp8: [8]u8 = undefined;
    try reader.readNoEof(tmp8[0..8]);
    const series_id = std.mem.readInt(u64, &tmp8, .little);
    try reader.readNoEof(tmp8[0..8]);
    const hour_bucket = std.mem.readInt(i64, &tmp8, .little);
    var tmp4: [4]u8 = undefined;
    try reader.readNoEof(tmp4[0..4]);
    const count = std.mem.readInt(u32, &tmp4, .little);
    try reader.readNoEof(tmp8[0..8]);
    const start_ts = std.mem.readInt(i64, &tmp8, .little);
    try reader.readNoEof(tmp8[0..8]);
    const end_ts = std.mem.readInt(i64, &tmp8, .little);

    if (std.mem.eql(u8, hdr[0..6], "SYSEG1")) {
        return .{
            .series_id = series_id,
            .hour_bucket = hour_bucket,
            .count = count,
            .start_ts = start_ts,
            .end_ts = end_ts,
            .ts_codec = 0,
            .val_codec = 0,
            .file_size = stat.size,
            .selector = null,
        };
    }
    if (!std.mem.eql(u8, hdr[0..6], "SYSEG2") and !std.mem.eql(u8, hdr[0..6], "SYSEG3")) return error.UnknownSegmentFormat;

    const ts_codec = try readByte(reader);
    const val_codec = try readByte(reader);
    const selector = if (std.mem.eql(u8, hdr[0..6], "SYSEG3")) try readSelectorMetadata(alloc, reader) else null;
    return .{
        .series_id = series_id,
        .hour_bucket = hour_bucket,
        .count = count,
        .start_ts = start_ts,
        .end_ts = end_ts,
        .ts_codec = ts_codec,
        .val_codec = val_codec,
        .file_size = stat.size,
        .selector = selector,
    };
}

pub fn queryRange(alloc: std.mem.Allocator, data_dir: std.fs.Dir, manifest: *manifest_mod.Manifest, series_id: types.SeriesId, start_ts: i64, end_ts: i64, out: *std.array_list.Managed(types.Point)) !void {
    try queryRangeEntries(alloc, data_dir, manifest.entries.items, series_id, start_ts, end_ts, out);
}

pub fn queryRangeEntries(
    alloc: std.mem.Allocator,
    data_dir: std.fs.Dir,
    entries: anytype,
    series_id: types.SeriesId,
    start_ts: i64,
    end_ts: i64,
    out: *std.array_list.Managed(types.Point),
) !void {
    for (entries) |e| {
        if (e.series_id != series_id) continue;
        if (e.end_ts < start_ts or e.start_ts > end_ts) continue;

        var f = try data_dir.openFile(e.path, .{});
        defer f.close();

        var read_buf: [4096]u8 = undefined;
        var reader_state = f.reader(&read_buf);
        const reader = std.Io.Reader.adaptToOldInterface(&reader_state.interface);

        var hdr: [6]u8 = undefined;
        try reader.readNoEof(&hdr);
        var tmp8: [8]u8 = undefined;
        try reader.readNoEof(tmp8[0..8]); // series id (unused)
        try reader.readNoEof(tmp8[0..8]); // hour bucket (unused)
        var tmp4: [4]u8 = undefined;
        try reader.readNoEof(tmp4[0..4]);
        const count = std.mem.readInt(u32, &tmp4, .little);
        try reader.readNoEof(tmp8[0..8]);
        const start = std.mem.readInt(i64, &tmp8, .little);
        try reader.readNoEof(tmp8[0..8]); // end (ignored)

        if (std.mem.eql(u8, hdr[0..6], "SYSEG1")) {
            var ts_list = try alloc.alloc(i64, count);
            defer alloc.free(ts_list);
            var prev_ts: i64 = 0;
            var i: usize = 0;
            while (i < count) : (i += 1) {
                const delta = try decodeZigZagVarint(reader);
                const ts: i64 = if (i == 0) delta else prev_ts + delta;
                ts_list[i] = ts;
                prev_ts = ts;
            }
            var j: usize = 0;
            while (j < count) : (j += 1) {
                try reader.readNoEof(tmp8[0..8]);
                const u: u64 = std.mem.readInt(u64, &tmp8, .little);
                const val: f64 = @bitCast(u);
                const ts = ts_list[j];
                if (ts >= start_ts and ts <= end_ts) try out.append(.{ .ts = ts, .value = val });
            }
            continue;
        }

        const ts_codec = try readByte(reader);
        const val_codec = try readByte(reader);
        _ = ts_codec;
        _ = val_codec;
        if (std.mem.eql(u8, hdr[0..6], "SYSEG3")) {
            try skipSelectorMetadata(reader);
        }
        const ts_list = try @import("../codec/gorilla.zig").decodeTsDoD(alloc, reader, count, start);
        defer alloc.free(ts_list);
        const vals = try @import("../codec/gorilla.zig").decodeF64(alloc, reader, count);
        defer alloc.free(vals);
        var k: usize = 0;
        while (k < count) : (k += 1) {
            const ts = ts_list[k];
            if (ts >= start_ts and ts <= end_ts) try out.append(.{ .ts = ts, .value = vals[k] });
        }
    }
}

pub fn queryRangeDescriptorEntries(
    alloc: std.mem.Allocator,
    data_dir: std.fs.Dir,
    store: *object_store.ObjectStore,
    descriptors: anytype,
    series_id: types.SeriesId,
    start_ts: i64,
    end_ts: i64,
    out: *std.array_list.Managed(types.Point),
) !void {
    for (descriptors) |descriptor| {
        if (descriptor.series_id != series_id) continue;
        if (descriptor.end_ts < start_ts or descriptor.start_ts > end_ts) continue;

        const Descriptor = @TypeOf(descriptor);
        if (@hasField(Descriptor, "segment_root")) {
            if (descriptor.segment_root) |segment_root| {
                try appendSegmentRootPoints(alloc, store, segment_root, start_ts, end_ts, out);
                continue;
            }
        }

        const points = try readAllDescriptor(alloc, data_dir, store, descriptor);
        defer alloc.free(points);
        for (points) |point| {
            if (point.ts < start_ts or point.ts > end_ts) continue;
            try out.append(point);
        }
    }
}

pub fn appendDescriptorPoints(
    alloc: std.mem.Allocator,
    data_dir: std.fs.Dir,
    store: *object_store.ObjectStore,
    descriptor: anytype,
    out: *std.array_list.Managed(types.Point),
) !void {
    const Descriptor = @TypeOf(descriptor);
    if (@hasField(Descriptor, "segment_root")) {
        if (descriptor.segment_root) |segment_root| {
            try appendSegmentRootPoints(alloc, store, segment_root, null, null, out);
            return;
        }
    }

    const points = try readAllDescriptor(alloc, data_dir, store, descriptor);
    defer alloc.free(points);
    try out.appendSlice(points);
}

fn decodeZigZagVarint(reader: anytype) !i64 {
    var shift: u6 = 0;
    var result: u64 = 0;
    while (true) {
        const b = try readByte(reader);
        result |= (@as(u64, b & 0x7F)) << shift;
        if ((b & 0x80) == 0) break;
        shift += 7;
    }
    const tmp: i64 = @bitCast((result >> 1) ^ (~result & 1));
    return tmp;
}

fn readSelectorMetadata(alloc: std.mem.Allocator, reader: anytype) !SelectorMetadata {
    const series_len = try readInt(reader, u32);
    const tags_len = try readInt(reader, u32);
    const series = try alloc.alloc(u8, series_len);
    errdefer alloc.free(series);
    const canonical_tags = try alloc.alloc(u8, tags_len);
    errdefer alloc.free(canonical_tags);
    try reader.readNoEof(series);
    try reader.readNoEof(canonical_tags);
    return .{
        .series = series,
        .canonical_tags = canonical_tags,
    };
}

fn skipSelectorMetadata(reader: anytype) !void {
    const series_len = try readInt(reader, u32);
    const tags_len = try readInt(reader, u32);
    try drainBytes(reader, @as(usize, series_len) + @as(usize, tags_len));
}

fn readInt(reader: anytype, comptime T: type) !T {
    var buf: [@sizeOf(T)]u8 = undefined;
    try reader.readNoEof(buf[0..]);
    return std.mem.readInt(T, &buf, .little);
}

fn drainBytes(reader: anytype, len: usize) !void {
    var remaining = len;
    var scratch: [256]u8 = undefined;
    while (remaining > 0) {
        const chunk_len = @min(remaining, scratch.len);
        try reader.readNoEof(scratch[0..chunk_len]);
        remaining -= chunk_len;
    }
}

inline fn readByte(reader: anytype) !u8 {
    return try reader.readByte();
}

fn anyWriter(writer: *std.Io.Writer) std.Io.AnyWriter {
    return .{
        .context = writer,
        .writeFn = struct {
            fn call(ctx: *const anyopaque, bytes: []const u8) anyerror!usize {
                const w: *std.Io.Writer = @ptrCast(@alignCast(@constCast(ctx)));
                return w.write(bytes);
            }
        }.call,
    };
}

test "segment metadata preserves selector metadata" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const points = [_]types.Point{
        .{ .ts = 1_000, .value = 1.5 },
        .{ .ts = 1_005, .value = 2.0 },
    };

    const path = try writeSegmentWithMetadata(alloc, tmp.dir, 77, 0, points[0..], .{
        .series = "weather.room3",
        .canonical_tags = "{\"host\":\"a\"}",
    });
    defer alloc.free(path);

    var metadata = try inspectMetadata(alloc, tmp.dir, path);
    defer metadata.deinit(alloc);

    try std.testing.expect(metadata.selector != null);
    try std.testing.expectEqualStrings("weather.room3", metadata.selector.?.series);
    try std.testing.expectEqualStrings("{\"host\":\"a\"}", metadata.selector.?.canonical_tags);

    const loaded = try readAll(alloc, tmp.dir, path);
    defer alloc.free(loaded);
    try std.testing.expectEqual(@as(usize, 2), loaded.len);
    try std.testing.expectEqual(@as(i64, 1_000), loaded[0].ts);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), loaded[1].value, 1e-9);
}

test "segment roots round-trip large segments with selector metadata" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const store_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/segment-root-store", .{tmp.sub_path});
    defer alloc.free(store_path);
    var store = try object_store.ObjectStore.init(alloc, store_path, .none);
    defer store.deinit();

    const point_count: usize = segment_root_block_point_count + 19;
    const points = try alloc.alloc(types.Point, point_count);
    defer alloc.free(points);
    for (points, 0..) |*point, idx| {
        point.* = .{
            .ts = 10_000 + @as(i64, @intCast(idx)) * 5,
            .value = @floatFromInt(idx),
        };
    }

    const root_id = try writeSegmentRoot(alloc, &store, .{
        .series_id = 99,
        .hour_bucket = 7_200,
        .ts_codec = 1,
        .val_codec = 1,
        .selector = .{
            .series = "metric.cpu",
            .canonical_tags = "{\"host\":\"a\"}",
        },
    }, points, 0);

    const restored = try readAllSegmentRoot(alloc, &store, root_id);
    defer alloc.free(restored);

    try std.testing.expectEqual(points.len, restored.len);
    for (points, restored) |expected, actual| {
        try std.testing.expectEqual(expected.ts, actual.ts);
        try std.testing.expectApproxEqAbs(expected.value, actual.value, 1e-9);
    }
}

test "descriptor reads prefer native segment roots" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const store_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/segment-root-descriptor-store", .{tmp.sub_path});
    defer alloc.free(store_path);
    var store = try object_store.ObjectStore.init(alloc, store_path, .none);
    defer store.deinit();

    const points = [_]types.Point{
        .{ .ts = 42, .value = 1.0 },
        .{ .ts = 47, .value = 2.5 },
        .{ .ts = 52, .value = 3.75 },
    };
    const root_id = try writeSegmentRoot(alloc, &store, .{
        .series_id = 7,
        .hour_bucket = 0,
        .ts_codec = 1,
        .val_codec = 1,
    }, points[0..], 0);

    const Descriptor = struct {
        segment_root: ?object_store.ObjectId,
        path: []const u8 = "",
    };
    const restored = try readAllDescriptor(alloc, tmp.dir, &store, Descriptor{ .segment_root = root_id });
    defer alloc.free(restored);

    try std.testing.expectEqual(@as(usize, points.len), restored.len);
    for (points, restored) |expected, actual| {
        try std.testing.expectEqual(expected.ts, actual.ts);
        try std.testing.expectApproxEqAbs(expected.value, actual.value, 1e-9);
    }
}

test "segment root range queries skip unrelated blocks" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const store_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/segment-root-range-store", .{tmp.sub_path});
    defer alloc.free(store_path);
    var store = try object_store.ObjectStore.init(alloc, store_path, .none);
    defer store.deinit();

    const point_count: usize = segment_root_block_point_count * 3;
    const points = try alloc.alloc(types.Point, point_count);
    defer alloc.free(points);
    for (points, 0..) |*point, idx| {
        point.* = .{
            .ts = 100_000 + @as(i64, @intCast(idx)),
            .value = @floatFromInt(idx),
        };
    }

    const root_id = try writeSegmentRoot(alloc, &store, .{
        .series_id = 11,
        .hour_bucket = 0,
        .ts_codec = 1,
        .val_codec = 1,
    }, points, 0);

    var root_tree = try loadTreeObject(alloc, &store, root_id);
    defer root_tree.deinit(alloc);
    const blocks_id = findTreeEntry(root_tree.entries, "blocks", .tree).?;
    var blocks_tree = try loadTreeObject(alloc, &store, blocks_id);
    defer blocks_tree.deinit(alloc);

    var first_block = try loadTreeObject(alloc, &store, blocks_tree.entries[0].object_id);
    defer first_block.deinit(alloc);
    const first_block_ts_root = findTreeEntry(first_block.entries, "ts", .tree).?;
    try corruptLooseObject(store.root, first_block_ts_root);

    const second_block_start_idx: usize = segment_root_block_point_count;
    const second_block_end_idx: usize = second_block_start_idx + segment_root_block_point_count - 1;

    const Descriptor = struct {
        series_id: types.SeriesId,
        start_ts: i64,
        end_ts: i64,
        segment_root: ?object_store.ObjectId,
        path: []const u8 = "",
    };
    const descriptors = [_]Descriptor{.{
        .series_id = 11,
        .start_ts = points[0].ts,
        .end_ts = points[points.len - 1].ts,
        .segment_root = root_id,
    }};

    var out = std.array_list.Managed(types.Point).init(alloc);
    defer out.deinit();
    try queryRangeDescriptorEntries(
        alloc,
        tmp.dir,
        &store,
        descriptors[0..],
        11,
        points[second_block_start_idx].ts,
        points[second_block_end_idx].ts,
        &out,
    );

    try std.testing.expectEqual(@as(usize, segment_root_block_point_count), out.items.len);
    try std.testing.expectEqual(points[second_block_start_idx].ts, out.items[0].ts);
    try std.testing.expectApproxEqAbs(points[second_block_start_idx].value, out.items[0].value, 1e-9);
    try std.testing.expectEqual(points[second_block_end_idx].ts, out.items[out.items.len - 1].ts);
}

test "segment root range queries stream from packed extents" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const store_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/segment-root-packed-range-store", .{tmp.sub_path});
    defer alloc.free(store_path);
    var store = try object_store.ObjectStore.init(alloc, store_path, .none);
    defer store.deinit();

    const point_count: usize = segment_root_block_point_count + 32;
    const points = try alloc.alloc(types.Point, point_count);
    defer alloc.free(points);
    for (points, 0..) |*point, idx| {
        point.* = .{
            .ts = 200_000 + @as(i64, @intCast(idx)) * 2,
            .value = @floatFromInt(idx),
        };
    }

    const root_id = try writeSegmentRoot(alloc, &store, .{
        .series_id = 15,
        .hour_bucket = 0,
        .ts_codec = 1,
        .val_codec = 1,
    }, points, 0);

    const ids = try store.listIds(alloc);
    defer alloc.free(ids);
    var pack_write = try store.writePack(alloc, ids);
    defer pack_write.deinit(alloc);

    const Descriptor = struct {
        series_id: types.SeriesId,
        start_ts: i64,
        end_ts: i64,
        segment_root: ?object_store.ObjectId,
        path: []const u8 = "",
    };
    const descriptors = [_]Descriptor{.{
        .series_id = 15,
        .start_ts = points[0].ts,
        .end_ts = points[points.len - 1].ts,
        .segment_root = root_id,
    }};

    var out = std.array_list.Managed(types.Point).init(alloc);
    defer out.deinit();
    try queryRangeDescriptorEntries(
        alloc,
        tmp.dir,
        &store,
        descriptors[0..],
        15,
        points[segment_root_block_point_count - 3].ts,
        points[segment_root_block_point_count + 3].ts,
        &out,
    );
    try std.testing.expectEqual(@as(usize, 7), out.items.len);
    try std.testing.expectEqual(points[segment_root_block_point_count - 3].ts, out.items[0].ts);
    try std.testing.expectEqual(points[segment_root_block_point_count + 3].ts, out.items[out.items.len - 1].ts);
}

fn appendBlockPointsFromExtentTrees(
    alloc: std.mem.Allocator,
    store: *object_store.ObjectStore,
    ts_tree: extents.WriteResult,
    values_tree: extents.WriteResult,
    stats: SegmentBlockStats,
    maybe_start_ts: ?i64,
    maybe_end_ts: ?i64,
    out: *std.array_list.Managed(types.Point),
) !usize {
    var ts_reader = try extents.openReader(alloc, store, ts_tree);
    defer ts_reader.deinit();
    const ts_list = try @import("../codec/gorilla.zig").decodeTsDoD(alloc, &ts_reader, stats.count, stats.first_ts);
    defer alloc.free(ts_list);
    try ts_reader.finish();

    var values_reader = try extents.openReader(alloc, store, values_tree);
    defer values_reader.deinit();
    const values = try @import("../codec/gorilla.zig").decodeF64(alloc, &values_reader, stats.count);
    defer alloc.free(values);
    try values_reader.finish();

    var appended: usize = 0;
    for (ts_list, values) |ts, value| {
        if (maybe_start_ts) |start_ts| {
            if (ts < start_ts) continue;
        }
        if (maybe_end_ts) |end_ts| {
            if (ts > end_ts) continue;
        }
        try out.append(.{ .ts = ts, .value = value });
        appended += 1;
    }
    return appended;
}

fn appendSegmentRootPoints(
    alloc: std.mem.Allocator,
    store: *object_store.ObjectStore,
    root_id: object_store.ObjectId,
    maybe_start_ts: ?i64,
    maybe_end_ts: ?i64,
    out: *std.array_list.Managed(types.Point),
) !void {
    var root_tree = try loadTreeObject(alloc, store, root_id);
    defer root_tree.deinit(alloc);

    const meta_id = findTreeEntry(root_tree.entries, "meta", .blob) orelse return error.MissingSegmentRootMeta;
    const blocks_id = findTreeEntry(root_tree.entries, "blocks", .tree) orelse return error.MissingSegmentRootBlocks;

    const meta_payload = try loadBlobObject(alloc, store, meta_id);
    defer alloc.free(meta_payload);
    var metadata = try decodeSegmentRootMetadata(alloc, meta_payload);
    defer metadata.deinit(alloc);

    if (maybe_start_ts == null and maybe_end_ts == null) {
        try out.ensureUnusedCapacity(@intCast(metadata.count));
    }

    var blocks_tree = try loadTreeObject(alloc, store, blocks_id);
    defer blocks_tree.deinit(alloc);

    var appended_count: usize = 0;
    for (blocks_tree.entries) |block_entry| {
        if (block_entry.object_type != .tree) return error.InvalidSegmentBlockTree;

        var block_tree = try loadTreeObject(alloc, store, block_entry.object_id);
        defer block_tree.deinit(alloc);

        const stats_id = findTreeEntry(block_tree.entries, "stats", .blob) orelse return error.MissingSegmentBlockStats;
        const stats_payload = try loadBlobObject(alloc, store, stats_id);
        defer alloc.free(stats_payload);
        const stats = try decodeSegmentBlockStats(stats_payload);

        if (maybe_start_ts) |start_ts| {
            if (stats.max_ts < start_ts) continue;
        }
        if (maybe_end_ts) |end_ts| {
            if (stats.min_ts > end_ts) continue;
        }

        const ts_root_id = findTreeEntry(block_tree.entries, "ts", .tree) orelse return error.MissingSegmentBlockTs;
        const values_root_id = findTreeEntry(block_tree.entries, "values", .tree) orelse return error.MissingSegmentBlockValues;
        appended_count += try appendBlockPointsFromExtentTrees(alloc, store, .{
            .root_id = ts_root_id,
            .size_bytes = stats.ts_size_bytes,
            .chunk_bytes = metadata.extent_chunk_bytes,
        }, .{
            .root_id = values_root_id,
            .size_bytes = stats.values_size_bytes,
            .chunk_bytes = metadata.extent_chunk_bytes,
        }, stats, maybe_start_ts, maybe_end_ts, out);
    }

    if (maybe_start_ts == null and maybe_end_ts == null and appended_count != metadata.count) {
        return error.CorruptSegmentRoot;
    }
}

fn encodeBlockTimestamps(alloc: std.mem.Allocator, points: []const types.Point) ![]u8 {
    var bytes = std.array_list.Managed(u8).init(alloc);
    errdefer bytes.deinit();
    try @import("../codec/gorilla.zig").encodeTsDoD(bytes.writer(), points[0].ts, points);
    return try bytes.toOwnedSlice();
}

fn encodeBlockValues(alloc: std.mem.Allocator, points: []const types.Point) ![]u8 {
    var values = try alloc.alloc(f64, points.len);
    defer alloc.free(values);
    for (points, 0..) |point, idx| values[idx] = point.value;

    var bytes = std.array_list.Managed(u8).init(alloc);
    errdefer bytes.deinit();
    try @import("../codec/gorilla.zig").encodeF64(bytes.writer(), values);
    return try bytes.toOwnedSlice();
}

fn encodeSegmentRootMetadata(alloc: std.mem.Allocator, metadata: SegmentRootMetadata) ![]u8 {
    var bytes = std.array_list.Managed(u8).init(alloc);
    errdefer bytes.deinit();

    try bytes.append(segment_root_meta_version);
    try appendInt(&bytes, u64, metadata.series_id);
    try appendInt(&bytes, i64, metadata.hour_bucket);
    try appendInt(&bytes, u32, metadata.count);
    try appendInt(&bytes, i64, metadata.start_ts);
    try appendInt(&bytes, i64, metadata.end_ts);
    try bytes.append(metadata.ts_codec);
    try bytes.append(metadata.val_codec);
    try appendInt(&bytes, u32, metadata.block_point_count);
    try appendInt(&bytes, u32, metadata.block_count);
    try appendInt(&bytes, u32, metadata.extent_chunk_bytes);
    if (metadata.selector) |selector| {
        try appendString(&bytes, selector.series);
        try appendString(&bytes, selector.canonical_tags);
    } else {
        try appendString(&bytes, "");
        try appendString(&bytes, "");
    }
    return try bytes.toOwnedSlice();
}

fn decodeSegmentRootMetadata(alloc: std.mem.Allocator, payload: []const u8) !SegmentRootMetadata {
    var cursor: usize = 0;
    if (try readByteAt(payload, &cursor) != segment_root_meta_version) return error.UnsupportedSegmentRootMetaVersion;

    const series_id = try readIntAt(payload, &cursor, u64);
    const hour_bucket = try readIntAt(payload, &cursor, i64);
    const count = try readIntAt(payload, &cursor, u32);
    const start_ts = try readIntAt(payload, &cursor, i64);
    const end_ts = try readIntAt(payload, &cursor, i64);
    const ts_codec = try readByteAt(payload, &cursor);
    const val_codec = try readByteAt(payload, &cursor);
    const block_point_count = try readIntAt(payload, &cursor, u32);
    const block_count = try readIntAt(payload, &cursor, u32);
    const extent_chunk_bytes = try readIntAt(payload, &cursor, u32);
    const selector_series = try readOwnedStringAt(alloc, payload, &cursor);
    errdefer alloc.free(selector_series);
    const selector_tags = try readOwnedStringAt(alloc, payload, &cursor);
    errdefer alloc.free(selector_tags);
    if (cursor != payload.len) return error.ExtraObjectBytes;

    return .{
        .series_id = series_id,
        .hour_bucket = hour_bucket,
        .count = count,
        .start_ts = start_ts,
        .end_ts = end_ts,
        .ts_codec = ts_codec,
        .val_codec = val_codec,
        .block_point_count = block_point_count,
        .block_count = block_count,
        .extent_chunk_bytes = extent_chunk_bytes,
        .selector = if (selector_series.len == 0 and selector_tags.len == 0)
            blk: {
                alloc.free(selector_series);
                alloc.free(selector_tags);
                break :blk null;
            }
        else
            .{
                .series = selector_series,
                .canonical_tags = selector_tags,
            },
    };
}

fn encodeSegmentBlockStats(alloc: std.mem.Allocator, stats: SegmentBlockStats) ![]u8 {
    var bytes = std.array_list.Managed(u8).init(alloc);
    errdefer bytes.deinit();

    try bytes.append(segment_block_stats_version);
    try appendInt(&bytes, u32, stats.count);
    try appendInt(&bytes, i64, stats.min_ts);
    try appendInt(&bytes, i64, stats.max_ts);
    try appendInt(&bytes, i64, stats.first_ts);
    try appendInt(&bytes, i64, stats.last_ts);
    try appendInt(&bytes, u64, stats.ts_size_bytes);
    try appendInt(&bytes, u64, stats.values_size_bytes);
    return try bytes.toOwnedSlice();
}

fn decodeSegmentBlockStats(payload: []const u8) !SegmentBlockStats {
    var cursor: usize = 0;
    if (try readByteAt(payload, &cursor) != segment_block_stats_version) return error.UnsupportedSegmentBlockStatsVersion;

    const stats = SegmentBlockStats{
        .count = try readIntAt(payload, &cursor, u32),
        .min_ts = try readIntAt(payload, &cursor, i64),
        .max_ts = try readIntAt(payload, &cursor, i64),
        .first_ts = try readIntAt(payload, &cursor, i64),
        .last_ts = try readIntAt(payload, &cursor, i64),
        .ts_size_bytes = try readIntAt(payload, &cursor, u64),
        .values_size_bytes = try readIntAt(payload, &cursor, u64),
    };
    if (cursor != payload.len) return error.ExtraObjectBytes;
    return stats;
}

fn putTree(alloc: std.mem.Allocator, store: *object_store.ObjectStore, entries: []const TreeEntry) !object_store.ObjectId {
    const payload = try encodeTree(alloc, entries);
    defer alloc.free(payload);
    return try store.put(.tree, payload);
}

fn loadTreeObject(alloc: std.mem.Allocator, store: *object_store.ObjectStore, id: object_store.ObjectId) !struct {
    entries: []TreeEntry,
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        for (self.entries) |*entry| entry.deinit(allocator);
        allocator.free(self.entries);
    }
} {
    const loaded = try store.get(alloc, id);
    defer alloc.free(loaded.payload);
    if (loaded.obj_type != .tree) return error.InvalidSegmentRootTree;
    return .{ .entries = try decodeTree(alloc, loaded.payload) };
}

fn loadBlobObject(alloc: std.mem.Allocator, store: *object_store.ObjectStore, id: object_store.ObjectId) ![]u8 {
    const loaded = try store.get(alloc, id);
    errdefer alloc.free(loaded.payload);
    if (loaded.obj_type != .blob) return error.InvalidSegmentRootBlob;
    return loaded.payload;
}

fn findTreeEntry(entries: []const TreeEntry, name: []const u8, object_type: object_store.ObjectType) ?object_store.ObjectId {
    for (entries) |entry| {
        if (entry.object_type != object_type) continue;
        if (std.mem.eql(u8, entry.name, name)) return entry.object_id;
    }
    return null;
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
    if (try readByteAt(payload, &cursor) != 1) return error.UnsupportedSegmentTreeVersion;
    const entry_count = try readIntAt(payload, &cursor, u32);
    var entries = try alloc.alloc(TreeEntry, entry_count);
    var decoded_count: usize = 0;
    errdefer {
        for (entries[0..decoded_count]) |*entry| entry.deinit(alloc);
        alloc.free(entries);
    }

    while (decoded_count < entry_count) : (decoded_count += 1) {
        const name = try readOwnedStringAt(alloc, payload, &cursor);
        errdefer alloc.free(name);
        const object_type = std.meta.intToEnum(object_store.ObjectType, try readByteAt(payload, &cursor)) catch return error.UnknownTreeObjectType;
        entries[decoded_count] = .{
            .name = name,
            .object_type = object_type,
            .object_id = .{ .hash = try readHashAt(payload, &cursor) },
        };
    }
    if (cursor != payload.len) return error.ExtraObjectBytes;
    return entries;
}

fn appendString(bytes: *std.array_list.Managed(u8), value: []const u8) !void {
    try appendInt(bytes, u32, @intCast(value.len));
    try bytes.appendSlice(value);
}

fn appendInt(bytes: *std.array_list.Managed(u8), comptime T: type, value: T) !void {
    var tmp: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, tmp[0..], value, .little);
    try bytes.appendSlice(tmp[0..]);
}

fn readByteAt(payload: []const u8, cursor: *usize) !u8 {
    if (cursor.* >= payload.len) return error.TruncatedObject;
    const out = payload[cursor.*];
    cursor.* += 1;
    return out;
}

fn readIntAt(payload: []const u8, cursor: *usize, comptime T: type) !T {
    const size = @sizeOf(T);
    if (cursor.* + size > payload.len) return error.TruncatedObject;
    const out = std.mem.readInt(T, @as(*const [size]u8, @ptrCast(payload[cursor.* .. cursor.* + size].ptr)), .little);
    cursor.* += size;
    return out;
}

fn readHashAt(payload: []const u8, cursor: *usize) ![32]u8 {
    if (cursor.* + 32 > payload.len) return error.TruncatedObject;
    var out: [32]u8 = undefined;
    @memcpy(out[0..], payload[cursor.* .. cursor.* + 32]);
    cursor.* += 32;
    return out;
}

fn readOwnedStringAt(alloc: std.mem.Allocator, payload: []const u8, cursor: *usize) ![]u8 {
    const len = try readIntAt(payload, cursor, u32);
    if (cursor.* + len > payload.len) return error.TruncatedObject;
    const out = try alloc.dupe(u8, payload[cursor.* .. cursor.* + len]);
    cursor.* += len;
    return out;
}

fn corruptLooseObject(root: std.fs.Dir, id: object_store.ObjectId) !void {
    const object_name = id.toHex();
    const bucket = std.fmt.bytesToHex([_]u8{id.hash[0]}, .lower);
    const path = try std.fmt.allocPrint(std.testing.allocator, "objects/{s}/{s}", .{ bucket[0..], object_name[0..] });
    defer std.testing.allocator.free(path);
    try root.writeFile(.{
        .sub_path = path,
        .data = "bad",
        .flags = .{},
    });
}
