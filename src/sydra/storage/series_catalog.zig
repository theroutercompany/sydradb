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

pub const ResolutionStatus = enum {
    not_found,
    resolved,
    ambiguous,
    exact_match,
};

pub const Resolution = struct {
    status: ResolutionStatus,
    series_id: ?types.SeriesId = null,
    series: ?[]const u8 = null,
    canonical_tags: ?[]const u8 = null,

    pub fn toMatch(self: @This()) Match {
        return switch (self.status) {
            .not_found => .not_found,
            .resolved, .exact_match => .{ .resolved = self.series_id.? },
            .ambiguous => .ambiguous,
        };
    }
};

pub const Entry = struct {
    series: []const u8,
    canonical_tags: []const u8,
    selector_key: []const u8,
    series_id: types.SeriesId,
};

pub const RebuildEntry = struct {
    series: []const u8,
    canonical_tags: []const u8,
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
    series_id_index: std.AutoHashMap(types.SeriesId, usize),

    pub fn initEmpty(alloc: std.mem.Allocator, fsync: cfg.FsyncPolicy) SeriesCatalog {
        return .{
            .alloc = alloc,
            .fsync = fsync,
            .file = null,
            .selector_index = std.StringHashMap(SidList).init(alloc),
            .name_index = std.StringHashMap(SidList).init(alloc),
            .series_id_index = std.AutoHashMap(types.SeriesId, usize).init(alloc),
        };
    }

    pub fn loadOrInit(alloc: std.mem.Allocator, data_dir: std.fs.Dir, fsync: cfg.FsyncPolicy) !SeriesCatalog {
        var catalog = SeriesCatalog.initEmpty(alloc, fsync);
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
        self.series_id_index.deinit();
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

    pub fn register(self: *SeriesCatalog, series: []const u8, tags_json: []const u8, series_id: types.SeriesId) !bool {
        const owned_series = try self.alloc.dupe(u8, series);
        errdefer self.alloc.free(owned_series);

        const canonical_tags = try canonicalizeTagsJson(self.alloc, tags_json);
        errdefer self.alloc.free(canonical_tags);

        const selector_key = try buildSelectorKey(self.alloc, owned_series, canonical_tags);
        errdefer self.alloc.free(selector_key);

        self.mutex.lock();
        defer self.mutex.unlock();

        const inserted = try self.insertOwned(owned_series, canonical_tags, selector_key, series_id);
        if (!inserted) return false;

        try self.appendLine(owned_series, canonical_tags, series_id);
        return true;
    }

    pub fn resolveUniqueName(self: *SeriesCatalog, series: []const u8) Match {
        return self.resolveUniqueNameDetailed(series).toMatch();
    }

    pub fn resolveUniqueNameDetailed(self: *SeriesCatalog, series: []const u8) Resolution {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.resolutionForList(self.name_index.get(series), .resolved);
    }

    pub fn resolveExact(self: *SeriesCatalog, series: []const u8, tags_json: []const u8) !Match {
        return (try self.resolveExactDetailed(series, tags_json)).toMatch();
    }

    pub fn resolveExactDetailed(self: *SeriesCatalog, series: []const u8, tags_json: []const u8) !Resolution {
        const canonical_tags = try canonicalizeTagsJson(self.alloc, tags_json);
        defer self.alloc.free(canonical_tags);

        const selector_key = try buildSelectorKey(self.alloc, series, canonical_tags);
        defer self.alloc.free(selector_key);

        self.mutex.lock();
        defer self.mutex.unlock();
        return self.resolutionForList(self.selector_index.get(selector_key), .exact_match);
    }

    pub fn resolveBySeriesId(self: *SeriesCatalog, series_id: types.SeriesId) Resolution {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.resolutionForSeriesId(series_id);
    }

    pub fn entryCount(self: *const SeriesCatalog) usize {
        return self.entries.items.len;
    }

    pub fn rebuild(
        _: std.mem.Allocator,
        data_dir: std.fs.Dir,
        fsync: cfg.FsyncPolicy,
        entries: []const RebuildEntry,
    ) !void {
        const temp_name = "series_catalog.jsonl.tmp";
        var file = try data_dir.createFile(temp_name, .{ .truncate = true, .read = true });
        defer file.close();
        errdefer data_dir.deleteFile(temp_name) catch {};

        var write_buf: [4096]u8 = undefined;
        var writer_state = file.writer(&write_buf);
        const writer = &writer_state.interface;

        for (entries) |entry| {
            var jw = std.json.Stringify{ .writer = writer };
            try jw.beginObject();
            try jw.objectField("series");
            try jw.write(entry.series);
            try jw.objectField("tags_json");
            try jw.write(entry.canonical_tags);
            try jw.objectField("series_id");
            try jw.write(entry.series_id);
            try jw.endObject();
            try writer.writeByte('\n');
        }
        try writer_state.end();
        switch (fsync) {
            .always => try file.sync(),
            .interval, .none => {},
        }
        try data_dir.rename(temp_name, catalog_file_name);
    }

    pub fn checkpointTo(self: *SeriesCatalog, data_dir: std.fs.Dir) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var entries = try self.alloc.alloc(RebuildEntry, self.entries.items.len);
        defer self.alloc.free(entries);

        for (self.entries.items, 0..) |entry, idx| {
            entries[idx] = .{
                .series = entry.series,
                .canonical_tags = entry.canonical_tags,
                .series_id = entry.series_id,
            };
        }

        try rebuild(self.alloc, data_dir, self.fsync, entries);
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
        if (self.series_id_index.get(series_id)) |existing_idx| {
            const existing = self.entries.items[existing_idx];
            if (std.mem.eql(u8, existing.series, owned_series) and std.mem.eql(u8, existing.canonical_tags, owned_tags)) {
                self.alloc.free(owned_series);
                self.alloc.free(owned_tags);
                self.alloc.free(selector_key);
                return false;
            }
            return error.SeriesIdConflict;
        }

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

        const next_index = self.entries.items.len;
        try self.entries.append(self.alloc, .{
            .series = owned_series,
            .canonical_tags = owned_tags,
            .selector_key = selector_key,
            .series_id = series_id,
        });
        try self.series_id_index.put(series_id, next_index);
        return true;
    }

    fn appendLine(self: *SeriesCatalog, series: []const u8, canonical_tags: []const u8, series_id: types.SeriesId) !void {
        if (self.file == null) return;

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

    fn resolutionForList(self: *SeriesCatalog, maybe_list: ?SidList, success_status: ResolutionStatus) Resolution {
        if (maybe_list) |list| {
            if (list.items.len == 1) {
                return self.resolutionForSeriesIdWithStatus(list.items[0], success_status);
            }
            if (list.items.len > 1) return .{ .status = .ambiguous };
        }
        return .{ .status = .not_found };
    }

    fn resolutionForSeriesId(self: *SeriesCatalog, series_id: types.SeriesId) Resolution {
        return self.resolutionForSeriesIdWithStatus(series_id, .resolved);
    }

    fn resolutionForSeriesIdWithStatus(self: *SeriesCatalog, series_id: types.SeriesId, status: ResolutionStatus) Resolution {
        const idx = self.series_id_index.get(series_id) orelse return .{ .status = .not_found };
        const entry = self.entries.items[idx];
        return .{
            .status = status,
            .series_id = series_id,
            .series = entry.series,
            .canonical_tags = entry.canonical_tags,
        };
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

    _ = try catalog.register("metrics.cpu", "{\"host\":\"b\",\"env\":\"prod\"}", 11);
    _ = try catalog.register("metrics.cpu", "{\"env\":\"prod\",\"host\":\"b\"}", 13);
    _ = try catalog.register("metrics.mem", "{}", 21);

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
        _ = try catalog.register("weather.room1", "{}", 42);
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

test "series catalog detailed resolutions expose canonical metadata" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var catalog = try SeriesCatalog.loadOrInit(alloc, tmp.dir, .always);
    defer catalog.deinit();

    try std.testing.expect(try catalog.register("weather.room2", "{\"zone\":\"lab\",\"host\":\"a\"}", 77));
    try std.testing.expect(!(try catalog.register("weather.room2", "{\"host\":\"a\",\"zone\":\"lab\"}", 77)));

    const unique = catalog.resolveUniqueNameDetailed("weather.room2");
    try std.testing.expectEqual(ResolutionStatus.resolved, unique.status);
    try std.testing.expectEqual(@as(types.SeriesId, 77), unique.series_id.?);
    try std.testing.expectEqualStrings("weather.room2", unique.series.?);
    try std.testing.expectEqualStrings("{\"host\":\"a\",\"zone\":\"lab\"}", unique.canonical_tags.?);

    const exact = try catalog.resolveExactDetailed("weather.room2", "{\"host\":\"a\",\"zone\":\"lab\"}");
    try std.testing.expectEqual(ResolutionStatus.exact_match, exact.status);
    try std.testing.expectEqual(@as(types.SeriesId, 77), exact.series_id.?);
    try std.testing.expectEqualStrings("{\"host\":\"a\",\"zone\":\"lab\"}", exact.canonical_tags.?);

    const by_id = catalog.resolveBySeriesId(77);
    try std.testing.expectEqual(ResolutionStatus.resolved, by_id.status);
    try std.testing.expectEqualStrings("weather.room2", by_id.series.?);
}
