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
    // Use Unmanaged to be stable across Zig versions; pass allocator on mutation
    entries: std.ArrayListUnmanaged(Entry),

    pub fn loadOrInit(alloc: std.mem.Allocator, data_dir: std.fs.Dir) !Manifest {
        var mf = Manifest{ .alloc = alloc, .entries = .{} };
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
        // Read entire file (reasonable upper bound) and split by lines
        const body = try file.readToEndAlloc(alloc, 1024 * 1024 * 64);
        defer alloc.free(body);
        var it = std.mem.tokenizeScalar(u8, body, '\n');
        while (it.next()) |raw_line| {
            const s = std.mem.trim(u8, raw_line, " \t\r\n");
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
            try mf.entries.append(alloc, .{
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
        self.entries.deinit(self.alloc);
    }

    pub fn maxEndTs(self: *const Manifest, sid: types.SeriesId) ?i64 {
        var result: ?i64 = null;
        for (self.entries.items) |e| {
            if (e.series_id != sid) continue;
            if (result) |existing| {
                if (e.end_ts > existing) result = e.end_ts;
            } else {
                result = e.end_ts;
            }
        }
        return result;
    }

    pub fn add(self: *Manifest, data_dir: std.fs.Dir, sid: types.SeriesId, hour: i64, start_ts: i64, end_ts: i64, count: u32, path: []const u8) !void {
        // append line to MANIFEST
        const OpenFlags = std.fs.File.OpenFlags;
        const open_opts: OpenFlags = if (@hasField(OpenFlags, "write"))
            OpenFlags{ .write = true, .read = true }
        else
            OpenFlags{ .mode = .read_write };
        var file = try data_dir.openFile("MANIFEST", open_opts);
        defer file.close();
        try file.seekFromEnd(0);
        var write_buf: [4096]u8 = undefined;
        var writer_state = file.writer(&write_buf);
        var writer = anyWriter(&writer_state.interface);
        try writer.print("{{\"series_id\":{d},\"hour_bucket\":{d},\"start_ts\":{d},\"end_ts\":{d},\"count\":{d},\"path\":\"{s}\"}}\n", .{ sid, hour, start_ts, end_ts, count, path });
        try writer_state.end();
        try self.entries.append(self.alloc, .{ .series_id = sid, .hour_bucket = hour, .start_ts = start_ts, .end_ts = end_ts, .count = count, .path = try self.alloc.dupe(u8, path) });
    }
};

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
