const std = @import("std");
const types = @import("../types.zig");

pub const Entry = struct {
    series_id: types.SeriesId,
    hour_bucket: i64,
    start_ts: i64,
    end_ts: i64,
    count: u32,
    path: []u8,
};

pub const Manifest = struct {
    alloc: std.mem.Allocator,
    entries: std.ArrayList(Entry),

    pub fn loadOrInit(alloc: std.mem.Allocator, data_dir: std.fs.Dir) !Manifest {
        var mf = Manifest{ .alloc = alloc, .entries = std.ArrayList(Entry).init(alloc) };
        // create directory structure
        data_dir.makePath("segments") catch {};
        var file = data_dir.openFile("MANIFEST", .{}) catch |e| switch (e) {
            error.FileNotFound => blk: {
                var f = try data_dir.createFile("MANIFEST", .{ .read = true });
                f.close();
                break :blk try data_dir.openFile("MANIFEST", .{});
            },
            else => return e,
        };
        defer file.close();
        // parse lines JSON
        var br = std.io.bufferedReader(file.reader());
        const r = br.reader();
        var buf = std.ArrayList(u8).init(alloc);
        defer buf.deinit();
        while (true) {
            buf.shrinkRetainingCapacity(0);
            const line = try r.readUntilDelimiterOrEofAlloc(alloc, '\n', 1024 * 16);
            if (line == null) break;
            defer alloc.free(line.?);
            const s = std.mem.trim(u8, line.?, " \t\r\n");
            if (s.len == 0) continue;
            var parsed = try std.json.parseFromSlice(std.json.Value, alloc, s, .{});
            defer parsed.deinit();
            const obj = parsed.value.object;
            const sid = obj.get("series_id").?.integer;
            const hour = obj.get("hour_bucket").?.integer;
            const start_ts = obj.get("start_ts").?.integer;
            const end_ts = obj.get("end_ts").?.integer;
            const count = obj.get("count").?.integer;
            const path = obj.get("path").?.string;
            try mf.entries.append(.{
                .series_id = @intCast(sid),
                .hour_bucket = @intCast(hour),
                .start_ts = @intCast(start_ts),
                .end_ts = @intCast(end_ts),
                .count = @intCast(count),
                .path = try alloc.dupe(u8, path),
            });
        }
        return mf;
    }

    pub fn deinit(self: *Manifest) void {
        for (self.entries.items) |*e| self.alloc.free(e.path);
        self.entries.deinit();
    }

    pub fn add(self: *Manifest, data_dir: std.fs.Dir, sid: types.SeriesId, hour: i64, start_ts: i64, end_ts: i64, count: u32, path: []const u8) !void {
        // append line to MANIFEST
        var file = try data_dir.openFile("MANIFEST", .{ .write = true, .read = true });
        defer file.close();
        try file.seekFromEnd(0);
        var bw = std.io.bufferedWriter(file.writer());
        const w = bw.writer();
        try w.print("{{\"series_id\":{d},\"hour_bucket\":{d},\"start_ts\":{d},\"end_ts\":{d},\"count\":{d},\"path\":\"{s}\"}}\n", .{ sid, hour, start_ts, end_ts, count, path });
        try bw.flush();
        try self.entries.append(.{ .series_id = sid, .hour_bucket = hour, .start_ts = start_ts, .end_ts = end_ts, .count = count, .path = try self.alloc.dupe(u8, path) });
    }
};
