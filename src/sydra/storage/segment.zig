const std = @import("std");
const types = @import("../types.zig");
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

pub fn readAll(alloc: std.mem.Allocator, data_dir: std.fs.Dir, path: []const u8) ![]types.Point {
    var f = try data_dir.openFile(path, .{});
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
