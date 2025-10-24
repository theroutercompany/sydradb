const std = @import("std");
const cfg = @import("../config.zig");

// WAL v0: record = [u32 len][u8 type][u64 series_id][i64 ts][f64 value][u32 crc32]
// Type: 1 = Put

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
        var wal_dir = self.dir.openDir("wal", .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer wal_dir.close();

        var files = try std.array_list.Managed([]u8).initCapacity(alloc, 0);
        defer {
            for (files.items) |name| alloc.free(name);
            files.deinit();
        }

        var it = wal_dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".wal")) continue;
            const name = try alloc.dupe(u8, entry.name);
            try files.append(name);
        }

        std.sort.block([]u8, files.items, {}, struct {
            fn lessThan(_: void, a: []u8, b: []u8) bool {
                const is_a_current = std.mem.eql(u8, a, "current.wal");
                const is_b_current = std.mem.eql(u8, b, "current.wal");
                if (is_a_current and !is_b_current) return false;
                if (!is_a_current and is_b_current) return true;
                return std.mem.lessThan(u8, a, b);
            }
        }.lessThan);

        const ctx_ptr = @constCast(ctx);
        for (files.items) |name| {
            try replayFile(alloc, wal_dir, name, ctx_ptr);
        }
    }
};

fn replayFile(alloc: std.mem.Allocator, wal_dir: std.fs.Dir, file_name: []const u8, ctx: anytype) !void {
    var file = try wal_dir.openFile(file_name, .{});
    defer file.close();

    var read_buf: [4096]u8 = undefined;
    var reader_state = file.reader(&read_buf);
    var reader = &reader_state.interface;

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

        if (payload.len < 1 + 8 + 8 + 8) continue;
        if (payload[0] != 1) continue;
        const sid = std.mem.readInt(u64, payload[1 .. 1 + 8], .little);
        const ts = std.mem.readInt(i64, payload[9 .. 9 + 8], .little);
        const val_bits = std.mem.readInt(u64, payload[17 .. 17 + 8], .little);
        const value: f64 = @bitCast(val_bits);
        try ctx.onRecord(sid, ts, value);
    }
}

fn readExact(reader: *std.Io.Reader, buf: []u8) !void {
    var offset: usize = 0;
    while (offset < buf.len) {
        const n = try reader.read(buf[offset..]);
        if (n == 0) return error.CorruptWal;
        offset += n;
    }
}
