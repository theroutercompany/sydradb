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
            const sid = try jsonSeriesId(obj.get("series_id") orelse return error.InvalidCharacter);
            const hour = try jsonI64(obj.get("hour_bucket") orelse return error.InvalidCharacter);
            const start_ts = try jsonI64(obj.get("start_ts") orelse return error.InvalidCharacter);
            const end_ts = try jsonI64(obj.get("end_ts") orelse return error.InvalidCharacter);
            const count = try jsonU32(obj.get("count") orelse return error.InvalidCharacter);
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

    pub fn appendEntry(self: *Manifest, entry: Entry) !void {
        try self.entries.append(self.alloc, entry);
    }

    pub fn add(self: *Manifest, data_dir: std.fs.Dir, sid: types.SeriesId, hour: i64, start_ts: i64, end_ts: i64, count: u32, path: []const u8) !void {
        // append line to MANIFEST
        const OpenFlags = std.fs.File.OpenFlags;
        const open_opts: OpenFlags = if (@hasField(OpenFlags, "write"))
            OpenFlags{ .write = true, .read = true }
        else
            OpenFlags{ .mode = .read_write };
        var file = data_dir.openFile("MANIFEST", open_opts) catch |err| switch (err) {
            error.FileNotFound => try data_dir.createFile("MANIFEST", .{ .read = true }),
            else => return err,
        };
        defer file.close();
        try file.seekFromEnd(0);
        var write_buf: [4096]u8 = undefined;
        var writer_state = file.writer(&write_buf);
        var writer = anyWriter(&writer_state.interface);
        try writeEntry(&writer, .{
            .series_id = sid,
            .hour_bucket = hour,
            .start_ts = start_ts,
            .end_ts = end_ts,
            .count = count,
            .path = @constCast(path),
        });
        try writer_state.end();
        try self.entries.append(self.alloc, .{
            .series_id = sid,
            .hour_bucket = hour,
            .start_ts = start_ts,
            .end_ts = end_ts,
            .count = count,
            .path = try self.alloc.dupe(u8, path),
        });
    }

    pub fn rewriteCheckpoint(self: *Manifest, data_dir: std.fs.Dir) !void {
        const temp_name = "MANIFEST.tmp";
        var file = try data_dir.createFile(temp_name, .{ .truncate = true, .read = true });
        defer file.close();
        errdefer data_dir.deleteFile(temp_name) catch {};

        var write_buf: [4096]u8 = undefined;
        var writer_state = file.writer(&write_buf);
        var writer = anyWriter(&writer_state.interface);
        for (self.entries.items) |entry| {
            try writeEntry(&writer, entry);
        }
        try writer_state.end();
        try file.sync();
        try data_dir.rename(temp_name, "MANIFEST");
    }
};

fn writeEntry(writer: *std.Io.AnyWriter, entry: Entry) !void {
    try writer.print(
        "{{\"series_id\":{d},\"hour_bucket\":{d},\"start_ts\":{d},\"end_ts\":{d},\"count\":{d},\"path\":\"{s}\"}}\n",
        .{ entry.series_id, entry.hour_bucket, entry.start_ts, entry.end_ts, entry.count, entry.path },
    );
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

fn jsonI64(value: std.json.Value) !i64 {
    return switch (value) {
        .integer => |integer| integer,
        .number_string => |digits| try std.fmt.parseInt(i64, digits, 10),
        else => error.InvalidCharacter,
    };
}

fn jsonU32(value: std.json.Value) !u32 {
    return switch (value) {
        .integer => |integer| @intCast(integer),
        .number_string => |digits| try std.fmt.parseInt(u32, digits, 10),
        else => error.InvalidCharacter,
    };
}

fn jsonSeriesId(value: std.json.Value) !types.SeriesId {
    return switch (value) {
        .integer => |integer| @intCast(integer),
        .number_string => |digits| try std.fmt.parseInt(types.SeriesId, digits, 10),
        else => error.InvalidCharacter,
    };
}
