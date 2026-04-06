const std = @import("std");
const cfg = @import("../config.zig");

pub const path = "market_runtime.json";

pub const DefinitionStatus = enum {
    active,
    paused,
    failed,

    pub fn parse(input: []const u8) ?DefinitionStatus {
        if (std.ascii.eqlIgnoreCase(input, "error")) return .failed;
        inline for (std.meta.fields(DefinitionStatus)) |field| {
            if (std.ascii.eqlIgnoreCase(input, field.name)) return @enumFromInt(field.value);
        }
        return null;
    }

    pub fn text(self: DefinitionStatus) []const u8 {
        return switch (self) {
            .failed => "error",
            else => @tagName(self),
        };
    }
};

pub const Checkpoint = struct {
    namespace: []u8,
    definition_id: []u8,
    definition_version: u32,
    series_key: []u8,
    highwater_ts: i64,
    pending: bool = false,
    last_event_sequence: ?u64 = null,
    last_output_ts: ?i64 = null,
    state_json: ?[]u8 = null,

    pub fn clone(self: Checkpoint, alloc: std.mem.Allocator) !Checkpoint {
        return .{
            .namespace = try alloc.dupe(u8, self.namespace),
            .definition_id = try alloc.dupe(u8, self.definition_id),
            .definition_version = self.definition_version,
            .series_key = try alloc.dupe(u8, self.series_key),
            .highwater_ts = self.highwater_ts,
            .pending = self.pending,
            .last_event_sequence = self.last_event_sequence,
            .last_output_ts = self.last_output_ts,
            .state_json = if (self.state_json) |value| try alloc.dupe(u8, value) else null,
        };
    }

    pub fn deinit(self: *Checkpoint, alloc: std.mem.Allocator) void {
        alloc.free(self.namespace);
        alloc.free(self.definition_id);
        alloc.free(self.series_key);
        if (self.state_json) |value| alloc.free(value);
        self.* = undefined;
    }
};

pub const DefinitionRuntime = struct {
    namespace: []u8,
    definition_id: []u8,
    definition_version: u32,
    status: DefinitionStatus = .active,
    last_run_ts: ?i64 = null,
    last_success_ts: ?i64 = null,
    last_error: ?[]u8 = null,
    rows_processed: u64 = 0,
    emissions_total: u64 = 0,
    last_event_id: ?[]u8 = null,

    pub fn clone(self: DefinitionRuntime, alloc: std.mem.Allocator) !DefinitionRuntime {
        return .{
            .namespace = try alloc.dupe(u8, self.namespace),
            .definition_id = try alloc.dupe(u8, self.definition_id),
            .definition_version = self.definition_version,
            .status = self.status,
            .last_run_ts = self.last_run_ts,
            .last_success_ts = self.last_success_ts,
            .last_error = if (self.last_error) |value| try alloc.dupe(u8, value) else null,
            .rows_processed = self.rows_processed,
            .emissions_total = self.emissions_total,
            .last_event_id = if (self.last_event_id) |value| try alloc.dupe(u8, value) else null,
        };
    }

    pub fn deinit(self: *DefinitionRuntime, alloc: std.mem.Allocator) void {
        alloc.free(self.namespace);
        alloc.free(self.definition_id);
        if (self.last_error) |value| alloc.free(value);
        if (self.last_event_id) |value| alloc.free(value);
        self.* = undefined;
    }
};

pub const ProcessingReport = struct {
    rows_processed: u64 = 0,
    emissions_total: u64 = 0,
    last_event_id: ?[]const u8 = null,
    last_output_ts: ?i64 = null,
    success: bool = true,
    error_message: ?[]const u8 = null,
};

pub const State = struct {
    alloc: std.mem.Allocator,
    fsync: cfg.FsyncPolicy,
    root: std.fs.Dir,
    mutex: std.Thread.Mutex = .{},
    checkpoints: std.array_list.Managed(Checkpoint),
    runtimes: std.array_list.Managed(DefinitionRuntime),

    pub fn loadOrInit(alloc: std.mem.Allocator, data_dir: std.fs.Dir, fsync: cfg.FsyncPolicy) !State {
        var root = try data_dir.openDir(".", .{ .iterate = true });
        errdefer root.close();
        var state = State{
            .alloc = alloc,
            .fsync = fsync,
            .root = root,
            .checkpoints = std.array_list.Managed(Checkpoint).init(alloc),
            .runtimes = std.array_list.Managed(DefinitionRuntime).init(alloc),
        };
        errdefer state.deinit();

        const body = state.root.readFileAlloc(alloc, path, 4 * 1024 * 1024) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        defer if (body) |buf| alloc.free(buf);
        if (body) |buf| try state.loadFromJson(buf);
        return state;
    }

    pub fn deinit(self: *State) void {
        for (self.checkpoints.items) |*entry| entry.deinit(self.alloc);
        self.checkpoints.deinit();
        for (self.runtimes.items) |*entry| entry.deinit(self.alloc);
        self.runtimes.deinit();
        self.root.close();
        self.* = undefined;
    }

    pub fn getHighwater(
        self: *State,
        namespace: []const u8,
        definition_id: []const u8,
        definition_version: u32,
        series_key: []const u8,
    ) ?i64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.checkpoints.items) |entry| {
            if (!std.mem.eql(u8, entry.namespace, namespace)) continue;
            if (!std.mem.eql(u8, entry.definition_id, definition_id)) continue;
            if (entry.definition_version != definition_version) continue;
            if (!std.mem.eql(u8, entry.series_key, series_key)) continue;
            return entry.highwater_ts;
        }
        return null;
    }

    pub fn upsertHighwater(
        self: *State,
        namespace: []const u8,
        definition_id: []const u8,
        definition_version: u32,
        series_key: []const u8,
        highwater_ts: i64,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.checkpoints.items) |*entry| {
            if (!std.mem.eql(u8, entry.namespace, namespace)) continue;
            if (!std.mem.eql(u8, entry.definition_id, definition_id)) continue;
            if (entry.definition_version != definition_version) continue;
            if (!std.mem.eql(u8, entry.series_key, series_key)) continue;
            if (highwater_ts > entry.highwater_ts) {
                entry.highwater_ts = highwater_ts;
                try self.rewriteLocked();
            }
            return;
        }

        try self.checkpoints.append(.{
            .namespace = try self.alloc.dupe(u8, namespace),
            .definition_id = try self.alloc.dupe(u8, definition_id),
            .definition_version = definition_version,
            .series_key = try self.alloc.dupe(u8, series_key),
            .highwater_ts = highwater_ts,
        });
        try self.rewriteLocked();
    }

    pub fn setPending(
        self: *State,
        namespace: []const u8,
        definition_id: []const u8,
        definition_version: u32,
        series_key: []const u8,
        pending: bool,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const checkpoint = try self.ensureCheckpointLocked(namespace, definition_id, definition_version, series_key);
        if (checkpoint.pending == pending) return;
        checkpoint.pending = pending;
        try self.rewriteLocked();
    }

    pub fn recordInstanceOutput(
        self: *State,
        namespace: []const u8,
        definition_id: []const u8,
        definition_version: u32,
        series_key: []const u8,
        output_ts: i64,
        last_event_sequence: ?u64,
        state_json: ?[]const u8,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const checkpoint = try self.ensureCheckpointLocked(namespace, definition_id, definition_version, series_key);
        checkpoint.last_output_ts = output_ts;
        checkpoint.pending = false;
        checkpoint.last_event_sequence = last_event_sequence;
        if (checkpoint.state_json) |value| self.alloc.free(value);
        checkpoint.state_json = if (state_json) |value| try self.alloc.dupe(u8, value) else null;
        try self.rewriteLocked();
    }

    pub fn latestCheckpointTs(
        self: *State,
        namespace: []const u8,
        definition_id: []const u8,
        definition_version: u32,
    ) ?i64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        var latest: ?i64 = null;
        for (self.checkpoints.items) |entry| {
            if (!std.mem.eql(u8, entry.namespace, namespace)) continue;
            if (!std.mem.eql(u8, entry.definition_id, definition_id)) continue;
            if (entry.definition_version != definition_version) continue;
            if (latest == null or entry.highwater_ts > latest.?) latest = entry.highwater_ts;
        }
        return latest;
    }

    pub fn latestEventSequence(
        self: *State,
        namespace: []const u8,
        definition_id: []const u8,
        definition_version: u32,
    ) ?u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        var latest: ?u64 = null;
        for (self.checkpoints.items) |entry| {
            if (!std.mem.eql(u8, entry.namespace, namespace)) continue;
            if (!std.mem.eql(u8, entry.definition_id, definition_id)) continue;
            if (entry.definition_version != definition_version) continue;
            if (entry.last_event_sequence) |sequence| {
                if (latest == null or sequence > latest.?) latest = sequence;
            }
        }
        return latest;
    }

    pub fn pendingInstanceCount(
        self: *State,
        namespace: []const u8,
        definition_id: []const u8,
        definition_version: u32,
    ) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        var count: usize = 0;
        for (self.checkpoints.items) |entry| {
            if (!std.mem.eql(u8, entry.namespace, namespace)) continue;
            if (!std.mem.eql(u8, entry.definition_id, definition_id)) continue;
            if (entry.definition_version != definition_version) continue;
            if (entry.pending) count += 1;
        }
        return count;
    }

    pub fn reportStart(
        self: *State,
        namespace: []const u8,
        definition_id: []const u8,
        definition_version: u32,
        now_ts: i64,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const runtime = try self.ensureRuntimeLocked(namespace, definition_id, definition_version);
        runtime.last_run_ts = now_ts;
        try self.rewriteLocked();
    }

    pub fn reportResult(
        self: *State,
        namespace: []const u8,
        definition_id: []const u8,
        definition_version: u32,
        now_ts: i64,
        report: ProcessingReport,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const runtime = try self.ensureRuntimeLocked(namespace, definition_id, definition_version);
        runtime.last_run_ts = now_ts;
        if (report.success) {
            runtime.status = if (runtime.status == .paused) .paused else .active;
            runtime.last_success_ts = now_ts;
            if (runtime.last_error) |value| {
                self.alloc.free(value);
                runtime.last_error = null;
            }
        } else {
            runtime.status = .failed;
            if (runtime.last_error) |value| self.alloc.free(value);
            runtime.last_error = if (report.error_message) |message| try self.alloc.dupe(u8, message) else try self.alloc.dupe(u8, "processing_failed");
        }
        runtime.rows_processed += report.rows_processed;
        runtime.emissions_total += report.emissions_total;
        if (report.last_event_id) |event_id| {
            if (runtime.last_event_id) |value| self.alloc.free(value);
            runtime.last_event_id = try self.alloc.dupe(u8, event_id);
        }
        try self.rewriteLocked();
    }

    pub fn setStatus(
        self: *State,
        namespace: []const u8,
        definition_id: []const u8,
        definition_version: ?u32,
        status: DefinitionStatus,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var changed = false;
        for (self.runtimes.items) |*runtime| {
            if (!std.mem.eql(u8, runtime.namespace, namespace)) continue;
            if (!std.mem.eql(u8, runtime.definition_id, definition_id)) continue;
            if (definition_version != null and runtime.definition_version != definition_version.?) continue;
            runtime.status = status;
            changed = true;
        }
        if (changed) try self.rewriteLocked();
    }

    pub fn deleteDefinition(
        self: *State,
        namespace: []const u8,
        definition_id: []const u8,
        definition_version: ?u32,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var idx: usize = 0;
        while (idx < self.checkpoints.items.len) {
            const entry = self.checkpoints.items[idx];
            if (std.mem.eql(u8, entry.namespace, namespace) and std.mem.eql(u8, entry.definition_id, definition_id) and (definition_version == null or entry.definition_version == definition_version.?)) {
                var removed = self.checkpoints.orderedRemove(idx);
                removed.deinit(self.alloc);
                continue;
            }
            idx += 1;
        }

        idx = 0;
        while (idx < self.runtimes.items.len) {
            const entry = self.runtimes.items[idx];
            if (std.mem.eql(u8, entry.namespace, namespace) and std.mem.eql(u8, entry.definition_id, definition_id) and (definition_version == null or entry.definition_version == definition_version.?)) {
                var removed = self.runtimes.orderedRemove(idx);
                removed.deinit(self.alloc);
                continue;
            }
            idx += 1;
        }
        try self.rewriteLocked();
    }

    pub fn runtimeFor(
        self: *State,
        namespace: []const u8,
        definition_id: []const u8,
        definition_version: u32,
    ) ?DefinitionRuntime {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.runtimes.items) |entry| {
            if (!std.mem.eql(u8, entry.namespace, namespace)) continue;
            if (!std.mem.eql(u8, entry.definition_id, definition_id)) continue;
            if (entry.definition_version != definition_version) continue;
            return entry.clone(self.alloc) catch null;
        }
        return null;
    }

    pub fn isPaused(
        self: *State,
        namespace: []const u8,
        definition_id: []const u8,
        definition_version: u32,
    ) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.runtimes.items) |entry| {
            if (!std.mem.eql(u8, entry.namespace, namespace)) continue;
            if (!std.mem.eql(u8, entry.definition_id, definition_id)) continue;
            if (entry.definition_version != definition_version) continue;
            return entry.status == .paused;
        }
        return false;
    }

    fn ensureRuntimeLocked(
        self: *State,
        namespace: []const u8,
        definition_id: []const u8,
        definition_version: u32,
    ) !*DefinitionRuntime {
        for (self.runtimes.items) |*runtime| {
            if (!std.mem.eql(u8, runtime.namespace, namespace)) continue;
            if (!std.mem.eql(u8, runtime.definition_id, definition_id)) continue;
            if (runtime.definition_version != definition_version) continue;
            return runtime;
        }
        try self.runtimes.append(.{
            .namespace = try self.alloc.dupe(u8, namespace),
            .definition_id = try self.alloc.dupe(u8, definition_id),
            .definition_version = definition_version,
        });
        return &self.runtimes.items[self.runtimes.items.len - 1];
    }

    fn ensureCheckpointLocked(
        self: *State,
        namespace: []const u8,
        definition_id: []const u8,
        definition_version: u32,
        series_key: []const u8,
    ) !*Checkpoint {
        for (self.checkpoints.items) |*entry| {
            if (!std.mem.eql(u8, entry.namespace, namespace)) continue;
            if (!std.mem.eql(u8, entry.definition_id, definition_id)) continue;
            if (entry.definition_version != definition_version) continue;
            if (!std.mem.eql(u8, entry.series_key, series_key)) continue;
            return entry;
        }
        try self.checkpoints.append(.{
            .namespace = try self.alloc.dupe(u8, namespace),
            .definition_id = try self.alloc.dupe(u8, definition_id),
            .definition_version = definition_version,
            .series_key = try self.alloc.dupe(u8, series_key),
            .highwater_ts = std.math.minInt(i64),
        });
        return &self.checkpoints.items[self.checkpoints.items.len - 1];
    }

    fn loadFromJson(self: *State, body: []const u8) !void {
        var parsed = try std.json.parseFromSlice(std.json.Value, self.alloc, body, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidMarketRuntime;
        if (parsed.value.object.get("checkpoints")) |checkpoints_value| {
            if (checkpoints_value != .array) return error.InvalidMarketRuntime;
            for (checkpoints_value.array.items) |value| {
                if (value != .object) return error.InvalidMarketRuntime;
                const obj = value.object;
                const namespace_value = obj.get("namespace") orelse return error.InvalidMarketRuntime;
                const id_value = obj.get("definition_id") orelse return error.InvalidMarketRuntime;
                const version_value = obj.get("definition_version") orelse return error.InvalidMarketRuntime;
                const key_value = obj.get("series_key") orelse return error.InvalidMarketRuntime;
                const highwater_value = obj.get("highwater_ts") orelse return error.InvalidMarketRuntime;
                if (namespace_value != .string or id_value != .string or key_value != .string) return error.InvalidMarketRuntime;
                try self.checkpoints.append(.{
                    .namespace = try self.alloc.dupe(u8, namespace_value.string),
                    .definition_id = try self.alloc.dupe(u8, id_value.string),
                    .definition_version = parseU32(version_value) catch return error.InvalidMarketRuntime,
                    .series_key = try self.alloc.dupe(u8, key_value.string),
                    .highwater_ts = parseI64(highwater_value) catch return error.InvalidMarketRuntime,
                    .pending = if (obj.get("pending")) |entry| parseBool(entry) catch return error.InvalidMarketRuntime else false,
                    .last_event_sequence = if (obj.get("last_event_sequence")) |entry| parseOptionalU64(entry) catch return error.InvalidMarketRuntime else null,
                    .last_output_ts = if (obj.get("last_output_ts")) |entry| parseOptionalI64(entry) catch return error.InvalidMarketRuntime else null,
                    .state_json = if (obj.get("state_json")) |entry| parseOptionalString(self.alloc, entry) catch return error.InvalidMarketRuntime else null,
                });
            }
        }
        if (parsed.value.object.get("runtimes")) |runtimes_value| {
            if (runtimes_value != .array) return error.InvalidMarketRuntime;
            for (runtimes_value.array.items) |value| {
                if (value != .object) return error.InvalidMarketRuntime;
                const obj = value.object;
                const namespace_value = obj.get("namespace") orelse return error.InvalidMarketRuntime;
                const id_value = obj.get("definition_id") orelse return error.InvalidMarketRuntime;
                const version_value = obj.get("definition_version") orelse return error.InvalidMarketRuntime;
                const status_value = obj.get("status") orelse return error.InvalidMarketRuntime;
                if (namespace_value != .string or id_value != .string or status_value != .string) return error.InvalidMarketRuntime;
                try self.runtimes.append(.{
                    .namespace = try self.alloc.dupe(u8, namespace_value.string),
                    .definition_id = try self.alloc.dupe(u8, id_value.string),
                    .definition_version = parseU32(version_value) catch return error.InvalidMarketRuntime,
                    .status = DefinitionStatus.parse(status_value.string) orelse return error.InvalidMarketRuntime,
                    .last_run_ts = if (obj.get("last_run_ts")) |entry| parseOptionalI64(entry) catch return error.InvalidMarketRuntime else null,
                    .last_success_ts = if (obj.get("last_success_ts")) |entry| parseOptionalI64(entry) catch return error.InvalidMarketRuntime else null,
                    .last_error = if (obj.get("last_error")) |entry| parseOptionalString(self.alloc, entry) catch return error.InvalidMarketRuntime else null,
                    .rows_processed = if (obj.get("rows_processed")) |entry| parseU64(entry) catch return error.InvalidMarketRuntime else 0,
                    .emissions_total = if (obj.get("emissions_total")) |entry| parseU64(entry) catch return error.InvalidMarketRuntime else 0,
                    .last_event_id = if (obj.get("last_event_id")) |entry| parseOptionalString(self.alloc, entry) catch return error.InvalidMarketRuntime else null,
                });
            }
        }
    }

    fn rewriteLocked(self: *State) !void {
        const temp_name = "market_runtime.json.tmp";
        var file = try self.root.createFile(temp_name, .{ .truncate = true, .read = true });
        defer file.close();
        errdefer self.root.deleteFile(temp_name) catch {};

        var write_buf: [4096]u8 = undefined;
        var writer_state = file.writer(&write_buf);
        const writer = &writer_state.interface;
        var jw = std.json.Stringify{ .writer = writer };
        try jw.beginObject();
        try jw.objectField("checkpoints");
        try jw.beginArray();
        for (self.checkpoints.items) |entry| {
            try jw.beginObject();
            try jw.objectField("namespace");
            try jw.write(entry.namespace);
            try jw.objectField("definition_id");
            try jw.write(entry.definition_id);
            try jw.objectField("definition_version");
            try jw.write(entry.definition_version);
            try jw.objectField("series_key");
            try jw.write(entry.series_key);
            try jw.objectField("highwater_ts");
            try jw.write(entry.highwater_ts);
            try jw.objectField("pending");
            try jw.write(entry.pending);
            try jw.objectField("last_event_sequence");
            if (entry.last_event_sequence) |value| try jw.write(value) else try jw.write(null);
            try jw.objectField("last_output_ts");
            if (entry.last_output_ts) |value| try jw.write(value) else try jw.write(null);
            try jw.objectField("state_json");
            if (entry.state_json) |value| try jw.write(value) else try jw.write(null);
            try jw.endObject();
        }
        try jw.endArray();

        try jw.objectField("runtimes");
        try jw.beginArray();
        for (self.runtimes.items) |entry| {
            try jw.beginObject();
            try jw.objectField("namespace");
            try jw.write(entry.namespace);
            try jw.objectField("definition_id");
            try jw.write(entry.definition_id);
            try jw.objectField("definition_version");
            try jw.write(entry.definition_version);
            try jw.objectField("status");
            try jw.write(entry.status.text());
            try jw.objectField("last_run_ts");
            if (entry.last_run_ts) |value| try jw.write(value) else try jw.write(null);
            try jw.objectField("last_success_ts");
            if (entry.last_success_ts) |value| try jw.write(value) else try jw.write(null);
            try jw.objectField("last_error");
            if (entry.last_error) |value| try jw.write(value) else try jw.write(null);
            try jw.objectField("rows_processed");
            try jw.write(entry.rows_processed);
            try jw.objectField("emissions_total");
            try jw.write(entry.emissions_total);
            try jw.objectField("last_event_id");
            if (entry.last_event_id) |value| try jw.write(value) else try jw.write(null);
            try jw.endObject();
        }
        try jw.endArray();
        try jw.endObject();
        try writer_state.end();
        if (self.fsync == .always) try file.sync();
        self.root.rename(temp_name, path) catch |err| switch (err) {
            error.PathAlreadyExists => {
                self.root.deleteFile(path) catch {};
                try self.root.rename(temp_name, path);
            },
            else => return err,
        };
    }
};

fn parseU32(value: std.json.Value) !u32 {
    return switch (value) {
        .integer => |int| @intCast(int),
        else => error.InvalidMarketRuntime,
    };
}

fn parseU64(value: std.json.Value) !u64 {
    return switch (value) {
        .integer => |int| @intCast(int),
        else => error.InvalidMarketRuntime,
    };
}

fn parseOptionalU64(value: std.json.Value) !?u64 {
    return switch (value) {
        .null => null,
        .integer => |int| @intCast(int),
        else => error.InvalidMarketRuntime,
    };
}

fn parseI64(value: std.json.Value) !i64 {
    return switch (value) {
        .integer => |int| int,
        else => error.InvalidMarketRuntime,
    };
}

fn parseBool(value: std.json.Value) !bool {
    return switch (value) {
        .bool => |v| v,
        else => error.InvalidMarketRuntime,
    };
}

fn parseOptionalI64(value: std.json.Value) !?i64 {
    return switch (value) {
        .null => null,
        .integer => |int| int,
        else => error.InvalidMarketRuntime,
    };
}

fn parseOptionalString(alloc: std.mem.Allocator, value: std.json.Value) !?[]u8 {
    return switch (value) {
        .null => null,
        .string => |text| try alloc.dupe(u8, text),
        else => error.InvalidMarketRuntime,
    };
}

test "market runtime tracks status and counters" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var state = try State.loadOrInit(alloc, tmp.dir, .none);
    defer state.deinit();

    try state.reportStart("signal", "ema", 1, 10);
    try state.reportResult("signal", "ema", 1, 11, .{
        .rows_processed = 4,
        .emissions_total = 2,
        .last_event_id = "s1:11",
        .success = true,
    });
    var runtime = state.runtimeFor("signal", "ema", 1).?;
    defer runtime.deinit(alloc);
    try std.testing.expectEqual(DefinitionStatus.active, runtime.status);
    try std.testing.expectEqual(@as(?i64, 11), runtime.last_success_ts);
    try std.testing.expectEqual(@as(u64, 4), runtime.rows_processed);
    try std.testing.expectEqual(@as(u64, 2), runtime.emissions_total);
}

test "market runtime persists lifecycle state across reload" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var state = try State.loadOrInit(alloc, tmp.dir, .none);
        defer state.deinit();

        try state.reportStart("rollup", "bars-1m", 2, 100);
        try state.reportResult("rollup", "bars-1m", 2, 120, .{
            .rows_processed = 12,
            .emissions_total = 3,
            .last_event_id = "bars-1m:{}:120",
            .last_output_ts = 119,
            .success = true,
        });
        try state.setStatus("rollup", "bars-1m", 2, .paused);
        try state.upsertHighwater("rollup", "bars-1m", 2, "{\"symbol\":\"AAPL\",\"venue\":\"XNAS\"}", 120);
        try state.setPending("rollup", "bars-1m", 2, "{\"symbol\":\"AAPL\",\"venue\":\"XNAS\"}", true);
        try state.recordInstanceOutput("rollup", "bars-1m", 2, "{\"symbol\":\"AAPL\",\"venue\":\"XNAS\"}", 119, 7, "{\"ema\":42}");
    }

    {
        var reloaded = try State.loadOrInit(alloc, tmp.dir, .none);
        defer reloaded.deinit();

        var runtime = reloaded.runtimeFor("rollup", "bars-1m", 2).?;
        defer runtime.deinit(alloc);
        try std.testing.expectEqual(DefinitionStatus.paused, runtime.status);
        try std.testing.expectEqual(@as(?i64, 120), runtime.last_success_ts);
        try std.testing.expectEqualStrings("bars-1m:{}:120", runtime.last_event_id.?);
        try std.testing.expectEqual(@as(?i64, 120), reloaded.getHighwater("rollup", "bars-1m", 2, "{\"symbol\":\"AAPL\",\"venue\":\"XNAS\"}"));
        try std.testing.expectEqual(@as(?i64, 120), reloaded.latestCheckpointTs("rollup", "bars-1m", 2));
        try std.testing.expectEqual(@as(?u64, 7), reloaded.latestEventSequence("rollup", "bars-1m", 2));
        try std.testing.expectEqual(@as(usize, 0), reloaded.pendingInstanceCount("rollup", "bars-1m", 2));

        try reloaded.deleteDefinition("rollup", "bars-1m", null);
        try std.testing.expect(reloaded.runtimeFor("rollup", "bars-1m", 2) == null);
        try std.testing.expect(reloaded.getHighwater("rollup", "bars-1m", 2, "{\"symbol\":\"AAPL\",\"venue\":\"XNAS\"}") == null);
    }
}
