const std = @import("std");

const cfg = @import("../config.zig");
const types = @import("../types.zig");

const catalog_file_name = "series_catalog.jsonl";
const default_tags_json = "{}";

const SidList = std.ArrayListUnmanaged(types.SeriesId);

pub const Match = union(enum) {
    not_found,
    resolved: types.SeriesId,
    ambiguous,
};

pub const Entry = struct {
    series: []const u8,
    canonical_tags: []const u8,
    selector_key: []const u8,
    series_id: types.SeriesId,
};

pub const SeriesCatalog = struct {
    alloc: std.mem.Allocator,
    fsync: cfg.FsyncPolicy,
    mutex: std.Thread.Mutex = .{},
    file: ?std.fs.File = null,
    entries: std.ArrayListUnmanaged(Entry) = .{},
    selector_index: std.StringHashMap(SidList),
    name_index: std.StringHashMap(SidList),

    pub fn loadOrInit(alloc: std.mem.Allocator, data_dir: std.fs.Dir, fsync: cfg.FsyncPolicy) !SeriesCatalog {
        var catalog = SeriesCatalog{
            .alloc = alloc,
            .fsync = fsync,
            .file = undefined,
            .selector_index = std.StringHashMap(SidList).init(alloc),
            .name_index = std.StringHashMap(SidList).init(alloc),
        };
        errdefer catalog.deinit();

        const body = data_dir.readFileAlloc(alloc, catalog_file_name, 8 * 1024 * 1024) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        defer if (body) |buf| alloc.free(buf);

        if (body) |buf| {
            var line_it = std.mem.splitScalar(u8, buf, '\n');
            while (line_it.next()) |line_raw| {
                const line = std.mem.trim(u8, line_raw, " \t\r\n");
                if (line.len == 0) continue;
                try catalog.loadLine(line);
            }
        }

        const open_flags = std.fs.File.OpenFlags{ .mode = .read_write };
        catalog.file = data_dir.openFile(catalog_file_name, open_flags) catch |err| switch (err) {
            error.FileNotFound => try data_dir.createFile(catalog_file_name, .{ .read = true }),
            else => return err,
        };
        try catalog.file.?.seekFromEnd(0);
        return catalog;
    }

    pub fn deinit(self: *SeriesCatalog) void {
        if (self.file) |*file| {
            file.close();
        }
        var selector_it = self.selector_index.iterator();
        while (selector_it.next()) |entry| {
            entry.value_ptr.deinit(self.alloc);
        }
        self.selector_index.deinit();

        var name_it = self.name_index.iterator();
        while (name_it.next()) |entry| {
            entry.value_ptr.deinit(self.alloc);
        }
        self.name_index.deinit();

        for (self.entries.items) |entry| {
            self.alloc.free(entry.series);
            self.alloc.free(entry.canonical_tags);
            self.alloc.free(entry.selector_key);
        }
        self.entries.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn register(self: *SeriesCatalog, series: []const u8, tags_json: []const u8, series_id: types.SeriesId) !void {
        const owned_series = try self.alloc.dupe(u8, series);
        errdefer self.alloc.free(owned_series);

        const canonical_tags = try canonicalizeTagsJson(self.alloc, tags_json);
        errdefer self.alloc.free(canonical_tags);

        const selector_key = try buildSelectorKey(self.alloc, owned_series, canonical_tags);
        errdefer self.alloc.free(selector_key);

        self.mutex.lock();
        defer self.mutex.unlock();

        const inserted = try self.insertOwned(owned_series, canonical_tags, selector_key, series_id);
        if (!inserted) return;

        try self.appendLine(owned_series, canonical_tags, series_id);
    }

    pub fn resolveUniqueName(self: *SeriesCatalog, series: []const u8) Match {
        self.mutex.lock();
        defer self.mutex.unlock();
        return matchForList(self.name_index.get(series));
    }

    pub fn resolveExact(self: *SeriesCatalog, series: []const u8, tags_json: []const u8) !Match {
        const canonical_tags = try canonicalizeTagsJson(self.alloc, tags_json);
        defer self.alloc.free(canonical_tags);

        const selector_key = try buildSelectorKey(self.alloc, series, canonical_tags);
        defer self.alloc.free(selector_key);

        self.mutex.lock();
        defer self.mutex.unlock();
        return matchForList(self.selector_index.get(selector_key));
    }

    pub fn entryCount(self: *const SeriesCatalog) usize {
        return self.entries.items.len;
    }

    fn loadLine(self: *SeriesCatalog, line: []const u8) !void {
        var parsed = try std.json.parseFromSlice(std.json.Value, self.alloc, line, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidSeriesCatalog;

        const obj = parsed.value.object;
        const series_val = obj.get("series") orelse return error.InvalidSeriesCatalog;
        const tags_val = obj.get("tags_json") orelse return error.InvalidSeriesCatalog;
        const series_id_val = obj.get("series_id") orelse return error.InvalidSeriesCatalog;
        if (series_val != .string or tags_val != .string or series_id_val != .integer) {
            return error.InvalidSeriesCatalog;
        }

        const owned_series = try self.alloc.dupe(u8, series_val.string);
        errdefer self.alloc.free(owned_series);
        const owned_tags = try self.alloc.dupe(u8, tags_val.string);
        errdefer self.alloc.free(owned_tags);
        const selector_key = try buildSelectorKey(self.alloc, owned_series, owned_tags);
        errdefer self.alloc.free(selector_key);

        _ = try self.insertOwned(owned_series, owned_tags, selector_key, @intCast(series_id_val.integer));
    }

    fn insertOwned(self: *SeriesCatalog, owned_series: []const u8, owned_tags: []const u8, selector_key: []const u8, series_id: types.SeriesId) !bool {
        var selector_gop = try self.selector_index.getOrPut(selector_key);
        if (!selector_gop.found_existing) {
            selector_gop.value_ptr.* = .{};
        }
        if (containsSid(selector_gop.value_ptr.items, series_id)) {
            self.alloc.free(owned_series);
            self.alloc.free(owned_tags);
            self.alloc.free(selector_key);
            return false;
        }
        try selector_gop.value_ptr.append(self.alloc, series_id);

        var name_gop = try self.name_index.getOrPut(owned_series);
        if (!name_gop.found_existing) {
            name_gop.value_ptr.* = .{};
        }
        if (!containsSid(name_gop.value_ptr.items, series_id)) {
            try name_gop.value_ptr.append(self.alloc, series_id);
        }

        try self.entries.append(self.alloc, .{
            .series = owned_series,
            .canonical_tags = owned_tags,
            .selector_key = selector_key,
            .series_id = series_id,
        });
        return true;
    }

    fn appendLine(self: *SeriesCatalog, series: []const u8, canonical_tags: []const u8, series_id: types.SeriesId) !void {
        var buffer = std.array_list.Managed(u8).init(self.alloc);
        defer buffer.deinit();

        var writer = buffer.writer();
        var tmp: [128]u8 = undefined;
        var adapter = writer.adaptToNewApi(&tmp);
        var iface = &adapter.new_interface;
        var jw = std.json.Stringify{ .writer = iface };
        try jw.beginObject();
        try jw.objectField("series");
        try jw.write(series);
        try jw.objectField("tags_json");
        try jw.write(canonical_tags);
        try jw.objectField("series_id");
        try jw.write(series_id);
        try jw.endObject();
        try iface.flush();
        if (adapter.err) |write_err| return write_err;

        try buffer.append('\n');
        try self.file.?.writeAll(buffer.items);
        switch (self.fsync) {
            .always => try self.file.?.sync(),
            .interval, .none => {},
        }
    }
};

pub fn canonicalizeTagsJson(alloc: std.mem.Allocator, tags_json: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, tags_json, " \t\r\n");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, default_tags_json)) {
        return alloc.dupe(u8, default_tags_json);
    }

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, trimmed, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidTagsJson;

    var buffer = std.array_list.Managed(u8).init(alloc);
    errdefer buffer.deinit();

    var writer = buffer.writer();
    var tmp: [128]u8 = undefined;
    var adapter = writer.adaptToNewApi(&tmp);
    var iface = &adapter.new_interface;
    var jw = std.json.Stringify{ .writer = iface };
    try writeCanonicalValue(alloc, parsed.value, &jw);
    try iface.flush();
    if (adapter.err) |write_err| return write_err;
    return try buffer.toOwnedSlice();
}

fn writeCanonicalValue(alloc: std.mem.Allocator, value: std.json.Value, jw: *std.json.Stringify) !void {
    switch (value) {
        .null => try jw.write(null),
        .bool => |b| try jw.write(b),
        .integer => |i| try jw.write(i),
        .float => |f| try jw.write(f),
        .number_string => |n| try jw.write(n),
        .string => |s| try jw.write(s),
        .array => |items| {
            try jw.beginArray();
            for (items.items) |item| {
                try writeCanonicalValue(alloc, item, jw);
            }
            try jw.endArray();
        },
        .object => |obj| {
            var keys = try alloc.alloc([]const u8, obj.count());
            defer alloc.free(keys);

            var it = obj.iterator();
            var idx: usize = 0;
            while (it.next()) |entry| : (idx += 1) {
                keys[idx] = entry.key_ptr.*;
            }

            std.sort.block([]const u8, keys, {}, struct {
                fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
                    return std.mem.lessThan(u8, lhs, rhs);
                }
            }.lessThan);

            try jw.beginObject();
            for (keys) |key| {
                try jw.objectField(key);
                try writeCanonicalValue(alloc, obj.get(key).?, jw);
            }
            try jw.endObject();
        },
    }
}

fn matchForList(maybe_list: ?SidList) Match {
    if (maybe_list) |list| {
        if (list.items.len == 1) return .{ .resolved = list.items[0] };
        if (list.items.len > 1) return .ambiguous;
    }
    return .not_found;
}

fn containsSid(values: []const types.SeriesId, series_id: types.SeriesId) bool {
    for (values) |existing| {
        if (existing == series_id) return true;
    }
    return false;
}

fn buildSelectorKey(alloc: std.mem.Allocator, series: []const u8, canonical_tags: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}\x1f{s}", .{ series, canonical_tags });
}

test "canonicalize tags sorts object keys" {
    const alloc = std.testing.allocator;
    const canonical = try canonicalizeTagsJson(alloc, "{\"b\":\"two\",\"a\":\"one\"}");
    defer alloc.free(canonical);

    try std.testing.expectEqualStrings("{\"a\":\"one\",\"b\":\"two\"}", canonical);
}

test "series catalog resolves exact and unique names across restart" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var catalog = try SeriesCatalog.loadOrInit(alloc, tmp.dir, .always);
    defer catalog.deinit();

    try catalog.register("metrics.cpu", "{\"host\":\"b\",\"env\":\"prod\"}", 11);
    try catalog.register("metrics.cpu", "{\"env\":\"prod\",\"host\":\"b\"}", 13);
    try catalog.register("metrics.mem", "{}", 21);

    try std.testing.expectEqual(@as(usize, 3), catalog.entryCount());
    try std.testing.expect(catalog.resolveUniqueName("metrics.cpu") == .ambiguous);
    try std.testing.expectEqual(@as(types.SeriesId, 21), switch (catalog.resolveUniqueName("metrics.mem")) {
        .resolved => |sid| sid,
        else => unreachable,
    });
    try std.testing.expect((try catalog.resolveExact("metrics.cpu", "{\"host\":\"b\",\"env\":\"prod\"}")) == .ambiguous);
}

test "series catalog reloads persisted mappings" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    {
        var catalog = try SeriesCatalog.loadOrInit(alloc, tmp.dir, .always);
        defer catalog.deinit();
        try catalog.register("weather.room1", "{}", 42);
    }

    var reopened = try SeriesCatalog.loadOrInit(alloc, tmp.dir, .always);
    defer reopened.deinit();

    try std.testing.expectEqual(@as(types.SeriesId, 42), switch (reopened.resolveUniqueName("weather.room1")) {
        .resolved => |sid| sid,
        else => unreachable,
    });
    try std.testing.expectEqual(@as(types.SeriesId, 42), switch (try reopened.resolveExact("weather.room1", "{}")) {
        .resolved => |sid| sid,
        else => unreachable,
    });
}
