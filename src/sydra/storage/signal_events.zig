const std = @import("std");
const cfg = @import("../config.zig");

pub const legacy_path = "signal_events.jsonl";
pub const dir_path = "signal_events";
const recent_event_limit: usize = 4096;

pub const Event = struct {
    definition_id: []u8,
    definition_version: u32,
    sequence: u64,
    event_id: []u8,
    data_revision: []u8,
    labels_json: []u8,
    ts_ns: i64,
    value: f64,

    pub fn clone(self: Event, alloc: std.mem.Allocator) !Event {
        return .{
            .definition_id = try alloc.dupe(u8, self.definition_id),
            .definition_version = self.definition_version,
            .sequence = self.sequence,
            .event_id = try alloc.dupe(u8, self.event_id),
            .data_revision = try alloc.dupe(u8, self.data_revision),
            .labels_json = try alloc.dupe(u8, self.labels_json),
            .ts_ns = self.ts_ns,
            .value = self.value,
        };
    }

    pub fn deinit(self: *Event, alloc: std.mem.Allocator) void {
        alloc.free(self.definition_id);
        alloc.free(self.event_id);
        alloc.free(self.data_revision);
        alloc.free(self.labels_json);
        self.* = undefined;
    }
};

pub const Store = struct {
    alloc: std.mem.Allocator,
    fsync: cfg.FsyncPolicy,
    root: std.fs.Dir,
    mutex: std.Thread.Mutex = .{},
    events: std.array_list.Managed(Event),
    next_sequences: std.StringHashMap(u64),

    pub fn loadOrInit(alloc: std.mem.Allocator, data_dir: std.fs.Dir, fsync: cfg.FsyncPolicy) !Store {
        var root = try data_dir.openDir(".", .{ .iterate = true });
        errdefer root.close();
        var store = Store{
            .alloc = alloc,
            .fsync = fsync,
            .root = root,
            .events = std.array_list.Managed(Event).init(alloc),
            .next_sequences = std.StringHashMap(u64).init(alloc),
        };
        errdefer store.deinit();

        store.root.makePath(dir_path) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        const legacy_body = store.root.readFileAlloc(alloc, legacy_path, 16 * 1024 * 1024) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        defer if (legacy_body) |buf| alloc.free(buf);
        if (legacy_body) |buf| {
            try store.loadFromJsonl(buf);
            try store.rewriteAllDefinitionFilesLocked();
            store.root.deleteFile(legacy_path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
        } else {
            try store.loadFromDefinitionDir();
        }
        return store;
    }

    pub fn deinit(self: *Store) void {
        for (self.events.items) |*event| event.deinit(self.alloc);
        self.events.deinit();
        var seq_it = self.next_sequences.iterator();
        while (seq_it.next()) |entry| self.alloc.free(entry.key_ptr.*);
        self.next_sequences.deinit();
        self.root.close();
        self.* = undefined;
    }

    pub fn append(
        self: *Store,
        definition_id: []const u8,
        definition_version: u32,
        data_revision: []const u8,
        labels_json: []const u8,
        ts_ns: i64,
        value: f64,
    ) !Event {
        self.mutex.lock();
        defer self.mutex.unlock();

        const sequence = try self.nextSequenceLocked(definition_id, definition_version);
        const event_id = try std.fmt.allocPrint(self.alloc, "signal/{s}/{d}/{d}", .{ definition_id, definition_version, sequence });
        errdefer self.alloc.free(event_id);
        var event = Event{
            .definition_id = try self.alloc.dupe(u8, definition_id),
            .definition_version = definition_version,
            .sequence = sequence,
            .event_id = event_id,
            .data_revision = try self.alloc.dupe(u8, data_revision),
            .labels_json = try self.alloc.dupe(u8, labels_json),
            .ts_ns = ts_ns,
            .value = value,
        };
        errdefer event.deinit(self.alloc);

        try self.appendToFileLocked(event);
        try self.events.append(try event.clone(self.alloc));
        try self.trimDefinitionLocked(definition_id, definition_version);
        return event;
    }

    pub fn listAfter(
        self: *Store,
        definition_id: []const u8,
        definition_version: ?u32,
        after_sequence: ?u64,
        start_ts_ns: ?i64,
        end_ts_ns: ?i64,
        limit: usize,
    ) ![]Event {
        self.mutex.lock();
        defer self.mutex.unlock();

        var out = std.array_list.Managed(Event).init(self.alloc);
        errdefer {
            for (out.items) |*event| event.deinit(self.alloc);
            out.deinit();
        }

        var oldest_sequence: ?u64 = null;
        for (self.events.items) |event| {
            if (!std.mem.eql(u8, event.definition_id, definition_id)) continue;
            if (definition_version != null and event.definition_version != definition_version.?) continue;
            if (oldest_sequence == null or event.sequence < oldest_sequence.?) oldest_sequence = event.sequence;
        }
        if (after_sequence) |seq| {
            if (seq != 0 and oldest_sequence != null and seq + 1 < oldest_sequence.?) {
                return error.EventReplayExpired;
            }
        }

        for (self.events.items) |event| {
            if (!std.mem.eql(u8, event.definition_id, definition_id)) continue;
            if (definition_version != null and event.definition_version != definition_version.?) continue;
            if (after_sequence != null and event.sequence <= after_sequence.?) continue;
            if (start_ts_ns != null and event.ts_ns < start_ts_ns.?) continue;
            if (end_ts_ns != null and event.ts_ns > end_ts_ns.?) continue;
            try out.append(try event.clone(self.alloc));
            if (out.items.len >= limit) break;
        }

        return try out.toOwnedSlice();
    }

    fn loadFromJsonl(self: *Store, body: []const u8) !void {
        var lines = std.mem.splitScalar(u8, body, '\n');
        while (lines.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r");
            if (line.len == 0) continue;
            var parsed = try std.json.parseFromSlice(std.json.Value, self.alloc, line, .{});
            defer parsed.deinit();
            if (parsed.value != .object) return error.InvalidSignalEventLog;
            const obj = parsed.value.object;
            const definition_id = obj.get("definition_id") orelse return error.InvalidSignalEventLog;
            const version = obj.get("definition_version") orelse return error.InvalidSignalEventLog;
            const sequence = obj.get("sequence") orelse return error.InvalidSignalEventLog;
            const event_id = obj.get("event_id") orelse return error.InvalidSignalEventLog;
            const data_revision = obj.get("data_revision") orelse return error.InvalidSignalEventLog;
            const labels_json = obj.get("labels_json") orelse return error.InvalidSignalEventLog;
            const ts_ns = obj.get("ts_ns") orelse return error.InvalidSignalEventLog;
            const value = obj.get("value") orelse return error.InvalidSignalEventLog;
            if (definition_id != .string or version != .integer or sequence != .integer or event_id != .string or data_revision != .string or labels_json != .string or ts_ns != .integer) {
                return error.InvalidSignalEventLog;
            }
            var event = Event{
                .definition_id = try self.alloc.dupe(u8, definition_id.string),
                .definition_version = @intCast(version.integer),
                .sequence = @intCast(sequence.integer),
                .event_id = try self.alloc.dupe(u8, event_id.string),
                .data_revision = try self.alloc.dupe(u8, data_revision.string),
                .labels_json = try self.alloc.dupe(u8, labels_json.string),
                .ts_ns = ts_ns.integer,
                .value = switch (value) {
                    .integer => @floatFromInt(value.integer),
                    .float => value.float,
                    else => return error.InvalidSignalEventLog,
                },
            };
            errdefer event.deinit(self.alloc);
            try self.events.append(event);
            try self.recordLoadedSequenceLocked(definition_id.string, @intCast(version.integer), @intCast(sequence.integer));
            try self.trimDefinitionLocked(definition_id.string, @intCast(version.integer));
        }
    }

    fn appendToFileLocked(self: *Store, event: Event) !void {
        const rel_path = try definitionFilePath(self.alloc, event.definition_id, event.definition_version);
        defer self.alloc.free(rel_path);
        var file = try self.root.createFile(rel_path, .{ .read = true, .truncate = false });
        defer file.close();
        try file.seekFromEnd(0);

        var write_buf: [2048]u8 = undefined;
        var writer_state = file.writer(&write_buf);
        const writer = &writer_state.interface;
        var jw = std.json.Stringify{ .writer = writer };
        try jw.beginObject();
        try jw.objectField("definition_id");
        try jw.write(event.definition_id);
        try jw.objectField("definition_version");
        try jw.write(event.definition_version);
        try jw.objectField("sequence");
        try jw.write(event.sequence);
        try jw.objectField("event_id");
        try jw.write(event.event_id);
        try jw.objectField("data_revision");
        try jw.write(event.data_revision);
        try jw.objectField("labels_json");
        try jw.write(event.labels_json);
        try jw.objectField("ts_ns");
        try jw.write(event.ts_ns);
        try jw.objectField("value");
        try jw.write(event.value);
        try jw.endObject();
        try writer.writeAll("\n");
        try writer_state.end();
        if (self.fsync == .always) try file.sync();
    }

    fn loadFromDefinitionDir(self: *Store) !void {
        var dir = try self.root.openDir(dir_path, .{ .iterate = true });
        defer dir.close();
        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;
            const body = try dir.readFileAlloc(self.alloc, entry.name, 16 * 1024 * 1024);
            defer self.alloc.free(body);
            try self.loadFromJsonl(body);
        }
    }

    fn trimDefinitionLocked(self: *Store, definition_id: []const u8, definition_version: u32) !void {
        var count: usize = 0;
        for (self.events.items) |event| {
            if (std.mem.eql(u8, event.definition_id, definition_id) and event.definition_version == definition_version) count += 1;
        }
        var changed = false;
        while (count > recent_event_limit) {
            var idx: usize = 0;
            while (idx < self.events.items.len) : (idx += 1) {
                const event = self.events.items[idx];
                if (!std.mem.eql(u8, event.definition_id, definition_id) or event.definition_version != definition_version) continue;
                var removed = self.events.orderedRemove(idx);
                removed.deinit(self.alloc);
                count -= 1;
                changed = true;
                break;
            }
        }
        if (changed) try self.rewriteDefinitionFileLocked(definition_id, definition_version);
    }

    fn rewriteAllDefinitionFilesLocked(self: *Store) !void {
        var keys = std.StringHashMap(void).init(self.alloc);
        defer {
            var it = keys.iterator();
            while (it.next()) |entry| self.alloc.free(entry.key_ptr.*);
            keys.deinit();
        }
        for (self.events.items) |event| {
            const key = try definitionKey(self.alloc, event.definition_id, event.definition_version);
            errdefer self.alloc.free(key);
            if (keys.contains(key)) {
                self.alloc.free(key);
                continue;
            }
            try keys.put(key, {});
        }
        var it = keys.iterator();
        while (it.next()) |entry| {
            const sep = std.mem.lastIndexOfScalar(u8, entry.key_ptr.*, '|') orelse continue;
            const definition_id = entry.key_ptr.*[0..sep];
            const version = try std.fmt.parseInt(u32, entry.key_ptr.*[sep + 1 ..], 10);
            try self.rewriteDefinitionFileLocked(definition_id, version);
        }
    }

    fn rewriteDefinitionFileLocked(self: *Store, definition_id: []const u8, definition_version: u32) !void {
        const rel_path = try definitionFilePath(self.alloc, definition_id, definition_version);
        defer self.alloc.free(rel_path);
        const tmp_path = try std.fmt.allocPrint(self.alloc, "{s}.tmp", .{rel_path});
        defer self.alloc.free(tmp_path);

        var file = try self.root.createFile(tmp_path, .{ .truncate = true, .read = true });
        defer file.close();
        errdefer self.root.deleteFile(tmp_path) catch {};

        var write_buf: [2048]u8 = undefined;
        var writer_state = file.writer(&write_buf);
        const writer = &writer_state.interface;
        for (self.events.items) |event| {
            if (!std.mem.eql(u8, event.definition_id, definition_id) or event.definition_version != definition_version) continue;
            try writeEventJsonLine(writer, event);
        }
        try writer_state.end();
        if (self.fsync == .always) try file.sync();
        self.root.rename(tmp_path, rel_path) catch |err| switch (err) {
            error.PathAlreadyExists => {
                self.root.deleteFile(rel_path) catch {};
                try self.root.rename(tmp_path, rel_path);
            },
            else => return err,
        };
    }

    fn nextSequenceLocked(self: *Store, definition_id: []const u8, definition_version: u32) !u64 {
        const key = try definitionKey(self.alloc, definition_id, definition_version);
        errdefer self.alloc.free(key);
        if (self.next_sequences.getPtr(key)) |ptr| {
            const current = ptr.*;
            ptr.* += 1;
            self.alloc.free(key);
            return current;
        }
        try self.next_sequences.put(key, 2);
        return 1;
    }

    fn recordLoadedSequenceLocked(self: *Store, definition_id: []const u8, definition_version: u32, sequence: u64) !void {
        const key = try definitionKey(self.alloc, definition_id, definition_version);
        errdefer self.alloc.free(key);
        if (self.next_sequences.getPtr(key)) |ptr| {
            if (sequence + 1 > ptr.*) ptr.* = sequence + 1;
            self.alloc.free(key);
            return;
        }
        try self.next_sequences.put(key, sequence + 1);
    }
};

fn definitionKey(alloc: std.mem.Allocator, definition_id: []const u8, definition_version: u32) ![]u8 {
    return try std.fmt.allocPrint(alloc, "{s}|{d}", .{ definition_id, definition_version });
}

fn definitionFilePath(alloc: std.mem.Allocator, definition_id: []const u8, definition_version: u32) ![]u8 {
    const safe_id = try sanitizeDefinitionId(alloc, definition_id);
    defer alloc.free(safe_id);
    return try std.fmt.allocPrint(alloc, "{s}/{s}@{d}.jsonl", .{ dir_path, safe_id, definition_version });
}

fn sanitizeDefinitionId(alloc: std.mem.Allocator, definition_id: []const u8) ![]u8 {
    var out = try alloc.alloc(u8, definition_id.len);
    for (definition_id, 0..) |ch, idx| {
        out[idx] = switch (ch) {
            '/', '\\', ':', ' ', '\t' => '_',
            else => ch,
        };
    }
    return out;
}

fn writeEventJsonLine(writer: anytype, event: Event) !void {
    var jw = std.json.Stringify{ .writer = writer };
    try jw.beginObject();
    try jw.objectField("definition_id");
    try jw.write(event.definition_id);
    try jw.objectField("definition_version");
    try jw.write(event.definition_version);
    try jw.objectField("sequence");
    try jw.write(event.sequence);
    try jw.objectField("event_id");
    try jw.write(event.event_id);
    try jw.objectField("data_revision");
    try jw.write(event.data_revision);
    try jw.objectField("labels_json");
    try jw.write(event.labels_json);
    try jw.objectField("ts_ns");
    try jw.write(event.ts_ns);
    try jw.objectField("value");
    try jw.write(event.value);
    try jw.endObject();
    try writer.writeAll("\n");
}

test "signal event store appends and replays recent events" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var store = try Store.loadOrInit(alloc, tmp.dir, .none);
        defer store.deinit();

        var first = try store.append("ema", 1, "rev-a", "{\"symbol\":\"AAPL\"}", 10, 1.5);
        defer first.deinit(alloc);
        var second = try store.append("ema", 1, "rev-a", "{\"symbol\":\"AAPL\"}", 20, 2.5);
        defer second.deinit(alloc);
        try std.testing.expectEqualStrings("signal/ema/1/1", first.event_id);
        try std.testing.expectEqualStrings("signal/ema/1/2", second.event_id);
    }

    {
        var store = try Store.loadOrInit(alloc, tmp.dir, .none);
        defer store.deinit();
        const events = try store.listAfter("ema", 1, 1, null, null, 16);
        defer {
            for (events) |*event| event.deinit(alloc);
            alloc.free(events);
        }
        try std.testing.expectEqual(@as(usize, 1), events.len);
        try std.testing.expectEqual(@as(i64, 20), events[0].ts_ns);
        try std.testing.expectEqual(@as(f64, 2.5), events[0].value);
    }
}

test "signal event store migrates legacy flat log" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = legacy_path,
        .data =
        \\{"definition_id":"ema","definition_version":1,"sequence":1,"event_id":"signal/ema/1/1","data_revision":"rev-a","labels_json":"{\"symbol\":\"AAPL\"}","ts_ns":10,"value":1.5}
        \\{"definition_id":"ema","definition_version":1,"sequence":2,"event_id":"signal/ema/1/2","data_revision":"rev-a","labels_json":"{\"symbol\":\"AAPL\"}","ts_ns":20,"value":2.5}
        \\
        ,
    });

    var store = try Store.loadOrInit(alloc, tmp.dir, .none);
    defer store.deinit();
    const events = try store.listAfter("ema", 1, null, null, null, 16);
    defer {
        for (events) |*event| event.deinit(alloc);
        alloc.free(events);
    }
    try std.testing.expectEqual(@as(usize, 2), events.len);

    tmp.dir.access(legacy_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    const migrated_path = try definitionFilePath(alloc, "ema", 1);
    defer alloc.free(migrated_path);
    try tmp.dir.access(migrated_path, .{});
}
