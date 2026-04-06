const std = @import("std");
const series_catalog = @import("series_catalog.zig");

pub const path = "annotations.jsonl";

var file_mu: std.Thread.Mutex = .{};

pub const Entry = struct {
    id: u64,
    kind: []u8,
    title: []u8,
    message: ?[]u8 = null,
    metric: ?[]u8 = null,
    start_ts: i64,
    end_ts: i64,
    labels_json: []u8,

    pub fn deinit(self: *Entry, alloc: std.mem.Allocator) void {
        alloc.free(self.kind);
        alloc.free(self.title);
        if (self.message) |value| alloc.free(value);
        if (self.metric) |value| alloc.free(value);
        alloc.free(self.labels_json);
        self.* = undefined;
    }
};

pub const WriteInput = struct {
    kind: []const u8,
    title: []const u8,
    message: ?[]const u8 = null,
    metric: ?[]const u8 = null,
    start_ts: i64,
    end_ts: i64,
    labels_json: ?[]const u8 = null,
};

pub const Query = struct {
    start_ts: ?i64 = null,
    end_ts: ?i64 = null,
    kind: ?[]const u8 = null,
    metric: ?[]const u8 = null,
    limit: ?usize = null,
};

pub fn append(alloc: std.mem.Allocator, data_dir: std.fs.Dir, input: WriteInput) !Entry {
    file_mu.lock();
    defer file_mu.unlock();

    const next_id = try nextId(alloc, data_dir);
    const canonical_labels = try series_catalog.canonicalizeTagsJson(alloc, input.labels_json orelse "{}");
    errdefer alloc.free(canonical_labels);

    var entry = Entry{
        .id = next_id,
        .kind = try alloc.dupe(u8, input.kind),
        .title = try alloc.dupe(u8, input.title),
        .message = if (input.message) |value| try alloc.dupe(u8, value) else null,
        .metric = if (input.metric) |value| try alloc.dupe(u8, value) else null,
        .start_ts = input.start_ts,
        .end_ts = input.end_ts,
        .labels_json = canonical_labels,
    };
    errdefer entry.deinit(alloc);

    var file = data_dir.openFile(path, .{ .mode = .read_write }) catch |err| switch (err) {
        error.FileNotFound => try data_dir.createFile(path, .{ .read = true }),
        else => return err,
    };
    defer file.close();
    try file.seekFromEnd(0);

    var write_buf: [1024]u8 = undefined;
    var writer_state = file.writer(&write_buf);
    const writer = &writer_state.interface;
    var jw = std.json.Stringify{ .writer = writer };
    try writeEntry(&jw, entry);
    try writer.writeByte('\n');
    try writer_state.end();
    return entry;
}

pub fn query(alloc: std.mem.Allocator, data_dir: std.fs.Dir, filter: Query) ![]Entry {
    file_mu.lock();
    defer file_mu.unlock();

    const body = data_dir.readFileAlloc(alloc, path, 8 * 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return alloc.alloc(Entry, 0),
        else => return err,
    };
    defer alloc.free(body);

    var entries = std.array_list.Managed(Entry).init(alloc);
    errdefer {
        for (entries.items) |*entry| entry.deinit(alloc);
        entries.deinit();
    }

    var line_it = std.mem.splitScalar(u8, body, '\n');
    while (line_it.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (line.len == 0) continue;
        var entry = try parseEntry(alloc, line);
        errdefer entry.deinit(alloc);
        if (!matchesQuery(entry, filter)) {
            entry.deinit(alloc);
            continue;
        }
        try entries.append(entry);
        if (filter.limit) |limit| {
            if (entries.items.len >= limit) break;
        }
    }

    return try entries.toOwnedSlice();
}

fn nextId(alloc: std.mem.Allocator, data_dir: std.fs.Dir) !u64 {
    const body = data_dir.readFileAlloc(alloc, path, 8 * 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return 1,
        else => return err,
    };
    defer alloc.free(body);

    var max_id: u64 = 0;
    var line_it = std.mem.splitScalar(u8, body, '\n');
    while (line_it.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (line.len == 0) continue;
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, line, .{});
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const id_value = parsed.value.object.get("id") orelse continue;
        const id = switch (id_value) {
            .integer => @as(u64, @intCast(id_value.integer)),
            else => continue,
        };
        if (id > max_id) max_id = id;
    }
    return max_id + 1;
}

fn writeEntry(jw: *std.json.Stringify, entry: Entry) !void {
    try jw.beginObject();
    try jw.objectField("id");
    try jw.write(entry.id);
    try jw.objectField("kind");
    try jw.write(entry.kind);
    try jw.objectField("title");
    try jw.write(entry.title);
    if (entry.message) |message| {
        try jw.objectField("message");
        try jw.write(message);
    }
    if (entry.metric) |metric| {
        try jw.objectField("metric");
        try jw.write(metric);
    }
    try jw.objectField("start_ts");
    try jw.write(entry.start_ts);
    try jw.objectField("end_ts");
    try jw.write(entry.end_ts);
    try jw.objectField("labels_json");
    try jw.write(entry.labels_json);
    try jw.endObject();
}

fn parseEntry(alloc: std.mem.Allocator, line: []const u8) !Entry {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, line, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidAnnotationRecord;
    const obj = parsed.value.object;

    const id_value = obj.get("id") orelse return error.InvalidAnnotationRecord;
    const kind_value = obj.get("kind") orelse return error.InvalidAnnotationRecord;
    const title_value = obj.get("title") orelse return error.InvalidAnnotationRecord;
    const start_value = obj.get("start_ts") orelse return error.InvalidAnnotationRecord;
    const end_value = obj.get("end_ts") orelse return error.InvalidAnnotationRecord;
    const labels_value = obj.get("labels_json") orelse return error.InvalidAnnotationRecord;
    if (kind_value != .string or title_value != .string or labels_value != .string) return error.InvalidAnnotationRecord;

    return .{
        .id = switch (id_value) {
            .integer => @as(u64, @intCast(id_value.integer)),
            else => return error.InvalidAnnotationRecord,
        },
        .kind = try alloc.dupe(u8, kind_value.string),
        .title = try alloc.dupe(u8, title_value.string),
        .message = if (obj.get("message")) |message|
            if (message == .string) try alloc.dupe(u8, message.string) else null
        else
            null,
        .metric = if (obj.get("metric")) |metric|
            if (metric == .string) try alloc.dupe(u8, metric.string) else null
        else
            null,
        .start_ts = switch (start_value) {
            .integer => start_value.integer,
            else => return error.InvalidAnnotationRecord,
        },
        .end_ts = switch (end_value) {
            .integer => end_value.integer,
            else => return error.InvalidAnnotationRecord,
        },
        .labels_json = try alloc.dupe(u8, labels_value.string),
    };
}

fn matchesQuery(entry: Entry, filter: Query) bool {
    if (filter.kind) |kind| {
        if (!std.ascii.eqlIgnoreCase(entry.kind, kind)) return false;
    }
    if (filter.metric) |metric| {
        if (entry.metric == null or !std.mem.eql(u8, entry.metric.?, metric)) return false;
    }
    if (filter.start_ts) |start_ts| {
        if (entry.end_ts < start_ts) return false;
    }
    if (filter.end_ts) |end_ts| {
        if (entry.start_ts > end_ts) return false;
    }
    return true;
}
