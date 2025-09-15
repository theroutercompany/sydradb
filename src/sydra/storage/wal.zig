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
        const f = try data_dir.createFile("wal/current.wal", .{ .read = true });
        return .{ .alloc = alloc, .dir = data_dir, .fsync = policy, .file = f, .bytes_written = 0 };
    }

    pub fn close(self: *WAL) void {
        self.file.close();
    }

    pub fn append(self: *WAL, series_id: u64, ts: i64, value: f64) !void {
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
        self.bytes_written += header.len + payload.len + 4;
        switch (self.fsync) {
            .always => try self.file.sync(),
            .interval => {},
            .none => {},
        }
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
};
