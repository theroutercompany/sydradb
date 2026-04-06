const std = @import("std");
const cfg = @import("../config.zig");

pub const path = "signal_events.jsonl";
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

        const body = store.root.readFileAlloc(alloc, path, 16 * 1024 * 1024) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        defer if (body) |buf| alloc.free(buf);
        if (body) |buf| try store.loadFromJsonl(buf);
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
        try self.trimLocked();
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
            try self.trimLocked();
        }
    }

    fn appendToFileLocked(self: *Store, event: Event) !void {
        var file = try self.root.createFile(path, .{ .read = true, .truncate = false });
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

    fn trimLocked(self: *Store) !void {
        while (self.events.items.len > recent_event_limit) {
            var removed = self.events.orderedRemove(0);
            removed.deinit(self.alloc);
        }
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
