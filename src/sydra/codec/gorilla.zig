const std = @import("std");

// Timestamp delta-of-delta using ZigZag varint (Gorilla-inspired)
pub fn encodeTsDoD(writer: anytype, start_ts: i64, points: []const @import("../types.zig").Point) !void {
    var prev_ts: i64 = start_ts;
    var prev_delta: i64 = 0;
    for (points) |p| {
        const delta: i64 = p.ts - prev_ts;
        const dod: i64 = delta - prev_delta;
        var buf: [10]u8 = undefined;
        const n = encodeZigZagVarint(&buf, dod);
        try writer.writeAll(buf[0..n]);
        prev_delta = delta;
        prev_ts = p.ts;
    }
}

pub fn decodeTsDoD(alloc: std.mem.Allocator, reader: anytype, count: usize, start_ts: i64) ![]i64 {
    var ts_list = try alloc.alloc(i64, count);
    var prev_ts: i64 = start_ts;
    var prev_delta: i64 = 0;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const dod = try decodeZigZagVarint(reader);
        const delta = prev_delta + dod;
        const ts = prev_ts + delta;
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
    var out = try alloc.alloc(f64, count);
    var prev_bits: u64 = 0;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const marker = try readByte(reader);
        switch (marker) {
            2 => {
                var b: [8]u8 = undefined;
                try reader.readNoEof(&b);
                prev_bits = std.mem.readInt(u64, &b, .little);
                out[i] = @bitCast(prev_bits);
            },
            0 => {
                out[i] = @bitCast(prev_bits);
            },
            1 => {
                _ = try readByte(reader); // lz (ignored in simplified decode)
                const tz = try readByte(reader);
                const nbytes = try readByte(reader);
                var bytes: [8]u8 = .{0} ** 8;
                try reader.readNoEof(bytes[0..nbytes]);
                const payload = std.mem.readInt(u64, &bytes, .little);
                const tz6: u6 = @intCast(tz);
                const x: u64 = payload << tz6;
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
    const uv: u64 = @bitCast((v << 1) ^ (v >> 63));
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
