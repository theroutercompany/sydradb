const std = @import("std");
const types = @import("../types.zig");
const manifest_mod = @import("manifest.zig");

// Segment format v1 (SYSEG2):
// [magic:6 'SYSEG2'][series_id:u64][hour:i64][count:u32]
// [start_ts:i64][end_ts:i64][ts_codec:u8][val_codec:u8]
// payload depends on codecs (default: ts=dod+zigzag varint, val=gorilla-xor byte-aligned)
// Back-compat: v0 (SYSEG1) supports ts delta varint + raw f64 values.

pub fn writeSegment(alloc: std.mem.Allocator, data_dir: std.fs.Dir, series_id: types.SeriesId, hour: i64, points: []const types.Point) ![]const u8 {
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

    var buffered_writer = std.io.bufferedWriter(f.writer());
    var writer = buffered_writer.writer();

    try writer.writeAll("SYSEG2");
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

    // Encode timestamps (delta-of-delta zigzag varint)
    try @import("../codec/gorilla.zig").encodeTsDoD(writer, points[0].ts, points);
    // Encode values using gorilla-like XOR
    var vals = try alloc.alloc(f64, points.len);
    defer alloc.free(vals);
    for (points, 0..) |p, i| vals[i] = p.value;
    try @import("../codec/gorilla.zig").encodeF64(writer, vals);

    try buffered_writer.flush();

    return try alloc.dupe(u8, file_name);
}

pub fn readAll(alloc: std.mem.Allocator, data_dir: std.fs.Dir, path: []const u8) ![]types.Point {
    var f = try data_dir.openFile(path, .{});
    defer f.close();

    var buffered_reader = std.io.bufferedReader(f.reader());
    const reader = buffered_reader.reader();

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

pub fn queryRange(alloc: std.mem.Allocator, data_dir: std.fs.Dir, manifest: *manifest_mod.Manifest, series_id: types.SeriesId, start_ts: i64, end_ts: i64, out: *std.ArrayList(types.Point)) !void {
    for (manifest.entries.items) |e| {
        if (e.series_id != series_id) continue;
        if (e.end_ts < start_ts or e.start_ts > end_ts) continue;

        var f = try data_dir.openFile(e.path, .{});
        defer f.close();

        var buffered_reader = std.io.bufferedReader(f.reader());
        const reader = buffered_reader.reader();

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

inline fn readByte(reader: anytype) !u8 {
    return try reader.readByte();
}
