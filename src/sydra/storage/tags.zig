const std = @import("std");
const types = @import("../types.zig");

pub const TagIndex = struct {
    alloc: std.mem.Allocator,
    map: std.StringHashMap(std.ArrayListUnmanaged(types.SeriesId)),

    pub fn loadOrInit(alloc: std.mem.Allocator, data_dir: std.fs.Dir) !TagIndex {
        var idx = TagIndex{ .alloc = alloc, .map = std.StringHashMap(std.ArrayListUnmanaged(types.SeriesId)).init(alloc) };
        const f = data_dir.openFile("tags.json", .{}) catch |e| switch (e) {
            error.FileNotFound => return idx,
            else => return e,
        };
        defer f.close();
        const body = try f.readToEndAlloc(alloc, 1024 * 1024);
        defer alloc.free(body);
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return idx;
        var it = parsed.value.object.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            if (entry.value_ptr.* != .array) continue;
            var arr = std.ArrayListUnmanaged(types.SeriesId){};
            for (entry.value_ptr.array.items) |v| {
                if (jsonSeriesId(v)) |series_id| {
                    try arr.append(alloc, series_id);
                } else |_| {}
            }
            const owned_key = try alloc.dupe(u8, key);
            errdefer alloc.free(owned_key);
            try idx.map.put(owned_key, arr);
        }
        return idx;
    }

    pub fn deinit(self: *TagIndex) void {
        var it = self.map.iterator();
        while (it.next()) |e| {
            self.alloc.free(e.key_ptr.*);
            e.value_ptr.deinit(self.alloc);
        }
        self.map.deinit();
    }

    pub fn add(self: *TagIndex, key: []const u8, series_id: types.SeriesId) !void {
        if (self.map.getPtr(key)) |existing| {
            for (existing.items) |sid| if (sid == series_id) return;
            try existing.append(self.alloc, series_id);
            return;
        }

        const owned_key = try self.alloc.dupe(u8, key);
        errdefer self.alloc.free(owned_key);
        try self.map.put(owned_key, .{});
        const inserted = self.map.getPtr(owned_key).?;
        try inserted.append(self.alloc, series_id);
    }

    pub fn get(self: *TagIndex, key: []const u8) []const types.SeriesId {
        if (self.map.get(key)) |lst| return lst.items;
        return &[_]types.SeriesId{};
    }

    pub fn save(self: *TagIndex, data_dir: std.fs.Dir) !void {
        var f = try data_dir.createFile("tags.json", .{ .truncate = true, .read = true });
        defer f.close();
        var write_buf: [4096]u8 = undefined;
        var writer_state = f.writer(&write_buf);
        var w = anyWriter(&writer_state.interface);
        try w.writeAll("{");
        var it = self.map.iterator();
        var first = true;
        while (it.next()) |e| {
            if (!first) try w.writeAll(",");
            first = false;
            try w.print("\"{s}\":[", .{e.key_ptr.*});
            var first2 = true;
            for (e.value_ptr.items) |sid| {
                if (!first2) try w.writeAll(",");
                first2 = false;
                try w.print("{d}", .{sid});
            }
            try w.writeAll("]");
        }
        try w.writeAll("}");
        try writer_state.end();
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

fn jsonSeriesId(value: std.json.Value) !types.SeriesId {
    return switch (value) {
        .integer => |integer| @intCast(integer),
        .number_string => |digits| try std.fmt.parseInt(types.SeriesId, digits, 10),
        else => error.InvalidCharacter,
    };
}
