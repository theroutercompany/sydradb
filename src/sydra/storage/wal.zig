const std = @import("std");
const cfg = @import("../config.zig");

// WAL v0:
// Type 1 = Put: [u32 len][u8 type][u64 series_id][i64 ts][f64 value][u32 crc32]
// Type 2 = SeriesRegistration: [u32 len][u8 type][u64 series_id][u32 series_len][u32 tags_len][series bytes][canonical tags bytes][u32 crc32]

pub const WAL = struct {
    alloc: std.mem.Allocator,
    dir: std.fs.Dir,
    fsync: cfg.FsyncPolicy,
    file: std.fs.File,
    bytes_written: usize,

    pub fn open(alloc: std.mem.Allocator, data_dir: std.fs.Dir, policy: cfg.FsyncPolicy) !WAL {
        data_dir.makePath("wal") catch {};
        const open_flags = std.fs.File.OpenFlags{ .mode = .read_write };
        var f = data_dir.openFile("wal/current.wal", open_flags) catch |err| switch (err) {
            error.FileNotFound => try data_dir.createFile("wal/current.wal", .{ .read = true }),
            else => return err,
        };
        const end_pos = try f.getEndPos();
        try f.seekFromEnd(0);
        return .{ .alloc = alloc, .dir = data_dir, .fsync = policy, .file = f, .bytes_written = @intCast(end_pos) };
    }

    pub fn close(self: *WAL) void {
        self.file.close();
    }

    pub fn append(self: *WAL, series_id: u64, ts: i64, value: f64) !u32 {
        var buf: [1 + 8 + 8 + 8]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        const w = fbs.writer();
        try w.writeByte(1); // type
        try w.writeInt(u64, series_id, .little);
        try w.writeInt(i64, ts, .little);
        const uv: u64 = @bitCast(value);
        try w.writeInt(u64, uv, .little);
        const payload = fbs.getWritten();
        var header: [4]u8 = undefined;
        const plen: u32 = @intCast(payload.len);
        std.mem.writeInt(u32, &header, plen, .little);
        try self.file.writeAll(&header);
        try self.file.writeAll(payload);
        var crc = std.hash.Crc32.init();
        crc.update(payload);
        var crc_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &crc_bytes, crc.final(), .little);
        try self.file.writeAll(&crc_bytes);
        const total_bytes: usize = header.len + payload.len + 4;
        self.bytes_written += total_bytes;
        switch (self.fsync) {
            .always => try self.file.sync(),
            .interval => {},
            .none => {},
        }
        return @intCast(total_bytes);
    }

    pub fn appendSeriesRegistration(self: *WAL, series_id: u64, series: []const u8, canonical_tags: []const u8) !u32 {
        var payload = std.array_list.Managed(u8).init(self.alloc);
        defer payload.deinit();

        var writer = payload.writer();
        try writer.writeByte(2);
        try writer.writeInt(u64, series_id, .little);
        try writer.writeInt(u32, @intCast(series.len), .little);
        try writer.writeInt(u32, @intCast(canonical_tags.len), .little);
        try writer.writeAll(series);
        try writer.writeAll(canonical_tags);
        return try appendPayload(self, payload.items);
    }

    pub fn rotateIfNeeded(self: *WAL) !void {
        if (self.bytes_written < 64 * 1024 * 1024) return; // 64 MiB
        self.file.close();
        // move current to wal/<epoch>.wal
        const now = std.time.milliTimestamp();
        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "wal/{d}.wal", .{now});
        try self.dir.rename("wal/current.wal", name);
        self.file = try self.dir.createFile("wal/current.wal", .{ .read = true });
        self.bytes_written = 0;
    }

    pub fn replay(self: *WAL, alloc: std.mem.Allocator, ctx: anytype) !void {
        const files = try listWalFiles(alloc, self.dir);
        defer freeWalFiles(alloc, files);
        try self.replayFiles(alloc, files, ctx);
    }

    pub fn replayFiles(self: *WAL, alloc: std.mem.Allocator, files: []const []const u8, ctx: anytype) !void {
        var wal_dir = self.dir.openDir("wal", .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer wal_dir.close();

        const ctx_ptr = @constCast(ctx);
        for (files) |name| {
            try replayFile(alloc, wal_dir, name, ctx_ptr);
        }
    }

    pub fn replayFileFromOffset(self: *WAL, alloc: std.mem.Allocator, file_name: []const u8, offset: u64, ctx: anytype) !void {
        var wal_dir = self.dir.openDir("wal", .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer wal_dir.close();

        var file = try wal_dir.openFile(file_name, .{});
        defer file.close();
        try file.seekTo(offset);

        var read_buf: [4096]u8 = undefined;
        var reader_state = file.reader(&read_buf);
        const reader = std.Io.Reader.adaptToOldInterface(&reader_state.interface);
        const ctx_ptr = @constCast(ctx);
        try replayReader(alloc, reader, ctx_ptr);
    }
};

pub const WalFileInfo = struct {
    name: []u8,
    size: u64,
    hash: [32]u8,
};

pub fn listWalFiles(alloc: std.mem.Allocator, data_dir: std.fs.Dir) ![][]u8 {
    var wal_dir = data_dir.openDir("wal", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return try alloc.alloc([]u8, 0),
        else => return err,
    };
    defer wal_dir.close();

    var files = try std.array_list.Managed([]u8).initCapacity(alloc, 0);
    errdefer {
        for (files.items) |name| alloc.free(name);
        files.deinit();
    }

    var it = wal_dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".wal")) continue;
        try files.append(try alloc.dupe(u8, entry.name));
    }

    sortWalFiles(files.items);
    return try files.toOwnedSlice();
}

pub fn freeWalFiles(alloc: std.mem.Allocator, files: [][]u8) void {
    for (files) |name| alloc.free(name);
    alloc.free(files);
}

pub fn freeWalFileInfos(alloc: std.mem.Allocator, files: []WalFileInfo) void {
    for (files) |file| alloc.free(file.name);
    alloc.free(files);
}

pub fn collectWalFileInfos(alloc: std.mem.Allocator, data_dir: std.fs.Dir) ![]WalFileInfo {
    const files = try listWalFiles(alloc, data_dir);
    defer freeWalFiles(alloc, files);

    var infos = std.array_list.Managed(WalFileInfo).init(alloc);
    errdefer {
        for (infos.items) |info| alloc.free(info.name);
        infos.deinit();
    }

    for (files) |name| {
        const path = try std.fmt.allocPrint(alloc, "wal/{s}", .{name});
        defer alloc.free(path);

        var file = try data_dir.openFile(path, .{});
        defer file.close();
        const stat = try file.stat();

        var buf: [8192]u8 = undefined;
        var hasher = std.crypto.hash.Blake3.init(.{});
        while (true) {
            const bytes_read = try file.read(buf[0..]);
            if (bytes_read == 0) break;
            hasher.update(buf[0..bytes_read]);
        }
        var out: [32]u8 = undefined;
        hasher.final(out[0..]);

        try infos.append(.{
            .name = try alloc.dupe(u8, name),
            .size = stat.size,
            .hash = out,
        });
    }

    return try infos.toOwnedSlice();
}

fn replayFile(alloc: std.mem.Allocator, wal_dir: std.fs.Dir, file_name: []const u8, ctx: anytype) !void {
    var file = try wal_dir.openFile(file_name, .{});
    defer file.close();

    var read_buf: [4096]u8 = undefined;
    var reader_state = file.reader(&read_buf);
    const reader = std.Io.Reader.adaptToOldInterface(&reader_state.interface);
    try replayReader(alloc, reader, ctx);
}

pub fn replayBytes(alloc: std.mem.Allocator, bytes: []const u8, ctx: anytype) !void {
    var stream = std.io.fixedBufferStream(bytes);
    try replayReader(alloc, stream.reader().any(), ctx);
}

pub fn filePrefixMatches(data_dir: std.fs.Dir, path: []const u8, expected_prefix: []const u8) !bool {
    var file = data_dir.openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer file.close();

    var remaining = expected_prefix;
    var scratch: [4096]u8 = undefined;
    while (remaining.len > 0) {
        const chunk_len = @min(remaining.len, scratch.len);
        const read_len = try file.readAll(scratch[0..chunk_len]);
        if (read_len != chunk_len) return false;
        if (!std.mem.eql(u8, scratch[0..chunk_len], remaining[0..chunk_len])) return false;
        remaining = remaining[chunk_len..];
    }
    return true;
}

fn replayReader(alloc: std.mem.Allocator, reader: anytype, ctx: anytype) !void {
    while (true) {
        var len_buf: [4]u8 = undefined;
        const len_read = try reader.read(&len_buf);
        if (len_read == 0) break;
        if (len_read != 4) return error.CorruptWal;

        const payload_len = std.mem.readInt(u32, &len_buf, .little);
        if (payload_len == 0 or payload_len > (1 << 20)) return error.CorruptWal;

        const payload = try alloc.alloc(u8, payload_len);
        defer alloc.free(payload);
        try readExact(reader, payload);

        var crc_buf: [4]u8 = undefined;
        try readExact(reader, crc_buf[0..4]);
        const expected_crc = std.mem.readInt(u32, &crc_buf, .little);
        var crc = std.hash.Crc32.init();
        crc.update(payload);
        if (crc.final() != expected_crc) return error.CorruptWal;

        switch (payload[0]) {
            1 => {
                if (payload.len < 1 + 8 + 8 + 8) continue;
                const sid = std.mem.readInt(u64, payload[1 .. 1 + 8], .little);
                const ts = std.mem.readInt(i64, payload[9 .. 9 + 8], .little);
                const val_bits = std.mem.readInt(u64, payload[17 .. 17 + 8], .little);
                const value: f64 = @bitCast(val_bits);
                try ctx.onRecord(sid, ts, value);
            },
            2 => {
                if (payload.len < 1 + 8 + 4 + 4) return error.CorruptWal;
                const sid = std.mem.readInt(u64, payload[1 .. 1 + 8], .little);
                const series_len = std.mem.readInt(u32, payload[9 .. 9 + 4], .little);
                const tags_len = std.mem.readInt(u32, payload[13 .. 13 + 4], .little);
                const expected_len = 1 + 8 + 4 + 4 + @as(usize, series_len) + @as(usize, tags_len);
                if (payload.len != expected_len) return error.CorruptWal;
                const series_start = 17;
                const tags_start = series_start + series_len;
                const series = payload[series_start..tags_start];
                const tags = payload[tags_start .. tags_start + tags_len];
                if (@hasDecl(@TypeOf(ctx.*), "onSeriesRegistration")) {
                    try ctx.onSeriesRegistration(sid, series, tags);
                }
            },
            else => continue,
        }
    }
}

fn appendPayload(self: *WAL, payload: []const u8) !u32 {
    var header: [4]u8 = undefined;
    const plen: u32 = @intCast(payload.len);
    std.mem.writeInt(u32, &header, plen, .little);
    try self.file.writeAll(&header);
    try self.file.writeAll(payload);
    var crc = std.hash.Crc32.init();
    crc.update(payload);
    var crc_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc_bytes, crc.final(), .little);
    try self.file.writeAll(&crc_bytes);
    const total_bytes: usize = header.len + payload.len + 4;
    self.bytes_written += total_bytes;
    switch (self.fsync) {
        .always => try self.file.sync(),
        .interval => {},
        .none => {},
    }
    return @intCast(total_bytes);
}

fn sortWalFiles(files: [][]u8) void {
    std.sort.block([]u8, files, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            const is_a_current = std.mem.eql(u8, a, "current.wal");
            const is_b_current = std.mem.eql(u8, b, "current.wal");
            if (is_a_current and !is_b_current) return false;
            if (!is_a_current and is_b_current) return true;
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
}

fn readExact(reader: std.Io.AnyReader, buf: []u8) !void {
    var offset: usize = 0;
    while (offset < buf.len) {
        const n = try reader.read(buf[offset..]);
        if (n == 0) return error.CorruptWal;
        offset += n;
    }
}

test "wal replays series registrations before point records" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var wal = try WAL.open(alloc, tmp.dir, .none);
    defer wal.close();

    _ = try wal.appendSeriesRegistration(77, "weather.room4", "{\"host\":\"b\"}");
    _ = try wal.append(77, 1_000, 3.5);

    var ctx = struct {
        registered: bool = false,
        seen_series_id: ?u64 = null,
        seen_series: ?[]const u8 = null,
        seen_tags: ?[]const u8 = null,
        point_count: usize = 0,

        pub fn onSeriesRegistration(self: *@This(), series_id: u64, series: []const u8, canonical_tags: []const u8) !void {
            self.registered = true;
            self.seen_series_id = series_id;
            self.seen_series = series;
            self.seen_tags = canonical_tags;
        }

        pub fn onRecord(self: *@This(), series_id: u64, ts: i64, value: f64) !void {
            try std.testing.expect(self.registered);
            try std.testing.expectEqual(@as(u64, 77), series_id);
            try std.testing.expectEqual(@as(i64, 1_000), ts);
            try std.testing.expectApproxEqAbs(@as(f64, 3.5), value, 1e-9);
            self.point_count += 1;
        }
    }{};

    try wal.replay(alloc, &ctx);

    try std.testing.expect(ctx.registered);
    try std.testing.expectEqual(@as(u64, 77), ctx.seen_series_id.?);
    try std.testing.expectEqualStrings("weather.room4", ctx.seen_series.?);
    try std.testing.expectEqualStrings("{\"host\":\"b\"}", ctx.seen_tags.?);
    try std.testing.expectEqual(@as(usize, 1), ctx.point_count);
}
