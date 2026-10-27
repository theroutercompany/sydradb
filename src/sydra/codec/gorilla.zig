const std = @import("std");

// Timestamp delta-of-delta using ZigZag varint (Gorilla-inspired)
pub fn encodeTsDoD(writer: anytype, start_ts: i64, points: []const @import("../types.zig").Point) !void {
    var prev_ts: i64 = start_ts;
    var prev_delta: i64 = 0;
    for (points) |p| {
        const delta = std.math.sub(i64, p.ts, prev_ts) catch return error.TimestampOverflow;
        const dod = std.math.sub(i64, delta, prev_delta) catch return error.TimestampOverflow;
        var buf: [10]u8 = undefined;
        const n = encodeZigZagVarint(&buf, dod);
        try writer.writeAll(buf[0..n]);
        prev_delta = delta;
        prev_ts = p.ts;
    }
}

pub fn decodeTsDoD(alloc: std.mem.Allocator, reader: anytype, count: usize, start_ts: i64) ![]i64 {
    const ts_list = try alloc.alloc(i64, count);
    errdefer alloc.free(ts_list);
    var prev_ts: i64 = start_ts;
    var prev_delta: i64 = 0;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const dod = try decodeZigZagVarint(reader);
        const delta = std.math.add(i64, prev_delta, dod) catch return error.TimestampOverflow;
        const ts = std.math.add(i64, prev_ts, delta) catch return error.TimestampOverflow;
        ts_list[i] = ts;
        prev_ts = ts;
        prev_delta = delta;
    }
    return ts_list;
}

// Float64 XOR Gorilla-like encoding (byte-aligned for simplicity)
// Encoding per value:
// - marker: 0 = same as prev, 1 = changed (xor payload), 2 = first/raw (8 bytes)
// - when marker=1: write [leading_zeros:u8][trailing_zeros:u8][nbytes:u8][payload:nbytes]
pub fn encodeF64(writer: anytype, values: []const f64) !void {
    var prev_bits: u64 = 0;
    for (values, 0..) |v, idx| {
        const bits: u64 = @bitCast(v);
        if (idx == 0) {
            try writer.writeByte(2);
            var b: [8]u8 = undefined;
            std.mem.writeInt(u64, &b, bits, .little);
            try writer.writeAll(b[0..8]);
            prev_bits = bits;
            continue;
        }
        const x = bits ^ prev_bits;
        if (x == 0) {
            try writer.writeByte(0); // same
        } else {
            const lz: u8 = @intCast(@clz(x));
            const tz: u8 = @intCast(@ctz(x));
            const sig_bits_usize = 64 - @as(usize, lz) - @as(usize, tz);
            const tz6: u6 = @intCast(tz);
            const payload: u64 = x >> tz6;
            var bytes: [8]u8 = undefined;
            std.mem.writeInt(u64, &bytes, payload, .little);
            const nbytes: u8 = @intCast((sig_bits_usize + 7) / 8);
            try writer.writeByte(1);
            try writer.writeByte(lz);
            try writer.writeByte(tz);
            try writer.writeByte(nbytes);
            try writer.writeAll(bytes[0..nbytes]);
        }
        prev_bits = bits;
    }
}

pub fn decodeF64(alloc: std.mem.Allocator, reader: anytype, count: usize) ![]f64 {
    const out = try alloc.alloc(f64, count);
    errdefer alloc.free(out);
    var prev_bits: u64 = 0;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const marker = try readByte(reader);
        switch (marker) {
            2 => {
                if (i != 0) return error.InvalidEncoding;
                var b: [8]u8 = undefined;
                try reader.readNoEof(&b);
                prev_bits = std.mem.readInt(u64, &b, .little);
                out[i] = @bitCast(prev_bits);
            },
            0 => {
                if (i == 0) return error.InvalidEncoding;
                out[i] = @bitCast(prev_bits);
            },
            1 => {
                if (i == 0) return error.InvalidEncoding;
                const lz = try readByte(reader);
                const tz = try readByte(reader);
                const nbytes = try readByte(reader);
                if (lz >= 64 or tz >= 64 or
                    @as(u16, lz) + @as(u16, tz) >= 64)
                {
                    return error.InvalidEncoding;
                }
                const significant_bits: u8 = @intCast(64 - @as(u16, lz) - @as(u16, tz));
                const expected_nbytes: u8 = @intCast((@as(u16, significant_bits) + 7) / 8);
                if (nbytes == 0 or nbytes > 8 or nbytes != expected_nbytes) {
                    return error.InvalidEncoding;
                }
                var bytes: [8]u8 = .{0} ** 8;
                try reader.readNoEof(bytes[0..nbytes]);
                const payload = std.mem.readInt(u64, &bytes, .little);
                if (significant_bits < 64 and
                    (payload >> @as(u6, @intCast(significant_bits))) != 0)
                {
                    return error.InvalidEncoding;
                }
                const tz6: u6 = @intCast(tz);
                const x: u64 = payload << tz6;
                if (x == 0 or @clz(x) != lz or @ctz(x) != tz) {
                    return error.InvalidEncoding;
                }
                const bits2 = prev_bits ^ x;
                prev_bits = bits2;
                out[i] = @bitCast(bits2);
            },
            else => return error.InvalidEncoding,
        }
    }
    return out;
}

fn encodeZigZagVarint(buf: []u8, v: i64) usize {
    const uv = zigZagEncode(v);
    var x = uv;
    var i: usize = 0;
    while (x >= 0x80) : (i += 1) {
        buf[i] = @intCast((x & 0x7F) | 0x80);
        x >>= 7;
    }
    buf[i] = @intCast(x);
    return i + 1;
}

fn decodeZigZagVarint(reader: anytype) !i64 {
    var result: u64 = 0;
    var idx: usize = 0;
    while (idx < 10) : (idx += 1) {
        const b = try readByte(reader);
        if (idx == 9 and (b & 0xfe) != 0) return error.InvalidEncoding;
        const shift: u6 = @intCast(idx * 7);
        result |= (@as(u64, b & 0x7F)) << shift;
        if ((b & 0x80) == 0) {
            if (idx > 0 and (b & 0x7f) == 0) return error.InvalidEncoding;
            return zigZagDecode(result);
        }
    }
    return error.InvalidEncoding;
}

inline fn zigZagEncode(v: i64) u64 {
    const bits: u64 = @bitCast(v);
    const sign: u64 = @bitCast(v >> 63);
    return (bits << 1) ^ sign;
}

inline fn zigZagDecode(uv: u64) i64 {
    const shifted = @as(i64, @intCast(uv >> 1));
    const neg_mask = -@as(i64, @intCast(uv & 1));
    return shifted ^ neg_mask;
}

inline fn readByte(reader: anytype) !u8 {
    return try reader.readByte();
}

test "zigzag encode/decode round-trip" {
    const cases = [_]i64{ 0, 1, -1, 2, -2, 123456789, -987654321 };
    for (cases) |value| {
        const encoded = zigZagEncode(value);
        const decoded = zigZagDecode(encoded);
        try std.testing.expectEqual(value, decoded);
    }
}

test "encodeTsDoD/decodeTsDoD preserves timestamps" {
    const types = @import("../types.zig");
    var buf: [64]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const writer = stream.writer();
    const points = [_]types.Point{
        .{ .ts = 1697040000, .value = 1.23 },
        .{ .ts = 1697040010, .value = 2.0 },
        .{ .ts = 1697040050, .value = 3.0 },
    };
    try encodeTsDoD(writer, points[0].ts, &points);
    const written = stream.getWritten();

    var reader_stream = std.io.fixedBufferStream(written);
    const reader = reader_stream.reader();
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const decoded = try decodeTsDoD(alloc, reader, points.len, points[0].ts);
    defer alloc.free(decoded);
    for (decoded, 0..) |ts, idx| {
        try std.testing.expectEqual(points[idx].ts, ts);
    }
}

test "decodeF64 rejects invalid marker order and bit windows" {
    const alloc = std.testing.allocator;
    const invalid_first = [_]u8{0};
    var first_stream = std.io.fixedBufferStream(&invalid_first);
    try std.testing.expectError(
        error.InvalidEncoding,
        decodeF64(alloc, first_stream.reader(), 1),
    );

    const repeated_raw = [_]u8{
        2, 0, 0, 0, 0, 0, 0, 0, 0,
        2, 0, 0, 0, 0, 0, 0, 0, 0,
    };
    var repeated_stream = std.io.fixedBufferStream(&repeated_raw);
    try std.testing.expectError(
        error.InvalidEncoding,
        decodeF64(alloc, repeated_stream.reader(), 2),
    );

    const invalid_window = [_]u8{
        2, 0,  0, 0, 0, 0, 0, 0, 0,
        1, 63, 1, 1, 1,
    };
    var window_stream = std.io.fixedBufferStream(&invalid_window);
    try std.testing.expectError(
        error.InvalidEncoding,
        decodeF64(alloc, window_stream.reader(), 2),
    );
}

test "timestamp decode rejects overflow and overlong varints" {
    const alloc = std.testing.allocator;
    const overflow = [_]u8{2};
    var overflow_stream = std.io.fixedBufferStream(&overflow);
    try std.testing.expectError(
        error.TimestampOverflow,
        decodeTsDoD(alloc, overflow_stream.reader(), 1, std.math.maxInt(i64)),
    );

    const overlong = [_]u8{0x80} ** 10;
    var overlong_stream = std.io.fixedBufferStream(&overlong);
    try std.testing.expectError(
        error.InvalidEncoding,
        decodeTsDoD(alloc, overlong_stream.reader(), 1, 0),
    );
}
