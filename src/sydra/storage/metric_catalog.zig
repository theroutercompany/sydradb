const std = @import("std");

const cfg = @import("../config.zig");

pub const path = "metric_catalog.jsonl";

pub const MetricKind = enum {
    gauge,
    counter,

    pub fn parse(input_text: []const u8) ?MetricKind {
        if (std.ascii.eqlIgnoreCase(input_text, "gauge")) return .gauge;
        if (std.ascii.eqlIgnoreCase(input_text, "counter")) return .counter;
        return null;
    }

    pub fn text(self: MetricKind) []const u8 {
        return @tagName(self);
    }
};

pub const Descriptor = struct {
    metric: []const u8,
    kind: ?MetricKind = null,
    unit: ?[]const u8 = null,
    description: ?[]const u8 = null,
    source_metric: ?[]const u8 = null,
    source_field: ?[]const u8 = null,

    pub fn deinit(self: *Descriptor, alloc: std.mem.Allocator) void {
        alloc.free(self.metric);
        freeOptional(alloc, self.unit);
        freeOptional(alloc, self.description);
        freeOptional(alloc, self.source_metric);
        freeOptional(alloc, self.source_field);
        self.* = undefined;
    }

    pub fn clone(self: Descriptor, alloc: std.mem.Allocator) !Descriptor {
        return .{
            .metric = try alloc.dupe(u8, self.metric),
            .kind = self.kind,
            .unit = try dupeOptional(alloc, self.unit),
            .description = try dupeOptional(alloc, self.description),
            .source_metric = try dupeOptional(alloc, self.source_metric),
            .source_field = try dupeOptional(alloc, self.source_field),
        };
    }
};

pub const DescriptorInput = struct {
    metric: []const u8,
    kind: ?MetricKind = null,
    unit: ?[]const u8 = null,
    description: ?[]const u8 = null,
    source_metric: ?[]const u8 = null,
    source_field: ?[]const u8 = null,
};

pub const RegisterResult = enum {
    unchanged,
    inserted,
    updated,
};

pub const BatchRegisterResult = enum {
    unchanged,
    inserted,
    updated,
    conflict,
};

pub const MetricCatalog = struct {
    alloc: std.mem.Allocator,
    fsync: cfg.FsyncPolicy,
    root: ?std.fs.Dir = null,
    mutex: std.Thread.Mutex = .{},
    entries: std.ArrayListUnmanaged(Descriptor) = .{},
    index: std.StringHashMap(usize),

    pub fn initEmpty(alloc: std.mem.Allocator, fsync: cfg.FsyncPolicy) MetricCatalog {
        return .{
            .alloc = alloc,
            .fsync = fsync,
            .root = null,
            .index = std.StringHashMap(usize).init(alloc),
        };
    }

    pub fn loadOrInit(alloc: std.mem.Allocator, data_dir: std.fs.Dir, fsync: cfg.FsyncPolicy) !MetricCatalog {
        var root = try data_dir.openDir(".", .{ .iterate = true });
        errdefer root.close();

        var catalog = MetricCatalog.initEmpty(alloc, fsync);
        catalog.root = root;
        errdefer catalog.deinit();

        const body = catalog.root.?.readFileAlloc(alloc, path, 8 * 1024 * 1024) catch |err| switch (err) {
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

        return catalog;
    }

    pub fn deinit(self: *MetricCatalog) void {
        for (self.entries.items) |*entry| entry.deinit(self.alloc);
        self.entries.deinit(self.alloc);
        self.index.deinit();
        if (self.root) |*root| root.close();
        self.* = undefined;
    }

    pub fn entryCount(self: *const MetricCatalog) usize {
        return self.entries.items.len;
    }

    pub fn get(self: *MetricCatalog, metric: []const u8) ?Descriptor {
        self.mutex.lock();
        defer self.mutex.unlock();
        const idx = self.index.get(metric) orelse return null;
        return self.entries.items[idx];
    }

    pub fn register(self: *MetricCatalog, input: DescriptorInput) !RegisterResult {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.index.get(input.metric)) |idx| {
            const result = try mergeDescriptor(self.alloc, &self.entries.items[idx], input);
            if (result != .unchanged and self.root != null) try self.rewriteLocked();
            return result;
        }

        var descriptor = Descriptor{
            .metric = try self.alloc.dupe(u8, input.metric),
            .kind = input.kind,
            .unit = try dupeOptional(self.alloc, normalizeOptional(input.unit)),
            .description = try dupeOptional(self.alloc, normalizeOptional(input.description)),
            .source_metric = try dupeOptional(self.alloc, normalizeOptional(input.source_metric)),
            .source_field = try dupeOptional(self.alloc, normalizeOptional(input.source_field)),
        };
        errdefer descriptor.deinit(self.alloc);

        try self.entries.append(self.alloc, descriptor);
        try self.index.put(self.entries.items[self.entries.items.len - 1].metric, self.entries.items.len - 1);
        if (self.root != null) try self.rewriteLocked();
        return .inserted;
    }

    pub fn registerBatch(self: *MetricCatalog, inputs: []const DescriptorInput, out: []BatchRegisterResult) !void {
        std.debug.assert(inputs.len == out.len);

        self.mutex.lock();
        defer self.mutex.unlock();

        try self.entries.ensureUnusedCapacity(self.alloc, inputs.len);

        var changed = false;
        for (inputs, 0..) |input, idx| {
            if (self.index.get(input.metric)) |entry_idx| {
                const result = mergeDescriptor(self.alloc, &self.entries.items[entry_idx], input) catch |err| switch (err) {
                    error.MetricDescriptorConflict => {
                        out[idx] = .conflict;
                        continue;
                    },
                    else => return err,
                };
                out[idx] = switch (result) {
                    .unchanged => .unchanged,
                    .inserted => unreachable,
                    .updated => .updated,
                };
                changed = changed or result != .unchanged;
                continue;
            }

            const unit = normalizeOptional(input.unit);
            const description = normalizeOptional(input.description);
            const source_metric = normalizeOptional(input.source_metric);
            const source_field = normalizeOptional(input.source_field);
            var descriptor = Descriptor{
                .metric = try self.alloc.dupe(u8, input.metric),
                .kind = input.kind,
                .unit = try dupeOptional(self.alloc, unit),
                .description = try dupeOptional(self.alloc, description),
                .source_metric = try dupeOptional(self.alloc, source_metric),
                .source_field = try dupeOptional(self.alloc, source_field),
            };
            errdefer descriptor.deinit(self.alloc);

            try self.entries.append(self.alloc, descriptor);
            try self.index.put(self.entries.items[self.entries.items.len - 1].metric, self.entries.items.len - 1);
            out[idx] = .inserted;
            changed = true;
        }

        if (changed and self.root != null) try self.rewriteLocked();
    }

    pub fn checkpointTo(self: *MetricCatalog) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.root != null) try self.rewriteLocked();
    }

    fn loadLine(self: *MetricCatalog, line: []const u8) !void {
        var parsed = try std.json.parseFromSlice(std.json.Value, self.alloc, line, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidMetricCatalog;

        const obj = parsed.value.object;
        const metric_value = obj.get("metric") orelse return error.InvalidMetricCatalog;
        if (metric_value != .string) return error.InvalidMetricCatalog;

        var descriptor = Descriptor{
            .metric = try self.alloc.dupe(u8, metric_value.string),
            .kind = kindFromJson(obj.get("kind")) orelse null,
            .unit = try ownedOptionalJsonString(self.alloc, obj.get("unit")),
            .description = try ownedOptionalJsonString(self.alloc, obj.get("description")),
            .source_metric = try ownedOptionalJsonString(self.alloc, obj.get("source_metric")),
            .source_field = try ownedOptionalJsonString(self.alloc, obj.get("source_field")),
        };
        errdefer descriptor.deinit(self.alloc);

        try self.index.put(descriptor.metric, self.entries.items.len);
        try self.entries.append(self.alloc, descriptor);
    }

    fn rewriteLocked(self: *MetricCatalog) !void {
        const root = self.root orelse return;
        const temp_name = "metric_catalog.jsonl.tmp";
        var file = try root.createFile(temp_name, .{ .truncate = true, .read = true });
        defer file.close();
        errdefer root.deleteFile(temp_name) catch {};

        var write_buf: [4096]u8 = undefined;
        var writer_state = file.writer(&write_buf);
        const writer = &writer_state.interface;

        for (self.entries.items) |entry| {
            var jw = std.json.Stringify{ .writer = writer };
            try jw.beginObject();
            try jw.objectField("metric");
            try jw.write(entry.metric);
            if (entry.kind) |kind| {
                try jw.objectField("kind");
                try jw.write(kind.text());
            }
            if (entry.unit) |unit| {
                try jw.objectField("unit");
                try jw.write(unit);
            }
            if (entry.description) |description| {
                try jw.objectField("description");
                try jw.write(description);
            }
            if (entry.source_metric) |source_metric| {
                try jw.objectField("source_metric");
                try jw.write(source_metric);
            }
            if (entry.source_field) |source_field| {
                try jw.objectField("source_field");
                try jw.write(source_field);
            }
            try jw.endObject();
            try writer.writeByte('\n');
        }

        try writer_state.end();
        if (self.fsync == .always) try file.sync();
        root.rename(temp_name, path) catch |err| switch (err) {
            error.PathAlreadyExists => {
                root.deleteFile(path) catch {};
                try root.rename(temp_name, path);
            },
            else => return err,
        };
    }
};

fn mergeDescriptor(alloc: std.mem.Allocator, existing: *Descriptor, input: DescriptorInput) !RegisterResult {
    var changed = false;

    if (input.kind) |incoming| {
        if (existing.kind) |current| {
            if (current != incoming) return error.MetricDescriptorConflict;
        } else {
            existing.kind = incoming;
            changed = true;
        }
    }

    changed = try mergeOptionalField(alloc, &existing.unit, normalizeOptional(input.unit)) or changed;
    changed = try mergeOptionalField(alloc, &existing.description, normalizeOptional(input.description)) or changed;
    changed = try mergeOptionalField(alloc, &existing.source_metric, normalizeOptional(input.source_metric)) or changed;
    changed = try mergeOptionalField(alloc, &existing.source_field, normalizeOptional(input.source_field)) or changed;

    return if (changed) .updated else .unchanged;
}

fn mergeOptionalField(alloc: std.mem.Allocator, existing: *?[]const u8, incoming: ?[]const u8) !bool {
    const normalized = normalizeOptional(incoming);
    if (normalized == null) return false;

    if (existing.*) |current| {
        if (!std.mem.eql(u8, current, normalized.?)) return error.MetricDescriptorConflict;
        return false;
    }

    existing.* = try alloc.dupe(u8, normalized.?);
    return true;
}

fn kindFromJson(maybe_value: ?std.json.Value) ?MetricKind {
    if (maybe_value) |value| {
        if (value == .string) return MetricKind.parse(value.string);
    }
    return null;
}

fn ownedOptionalJsonString(alloc: std.mem.Allocator, maybe_value: ?std.json.Value) !?[]const u8 {
    if (maybe_value) |value| {
        if (value == .string and value.string.len != 0) return try alloc.dupe(u8, value.string);
    }
    return null;
}

fn normalizeOptional(maybe_value: ?[]const u8) ?[]const u8 {
    if (maybe_value) |value| {
        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        if (trimmed.len != 0) return trimmed;
    }
    return null;
}

fn dupeOptional(alloc: std.mem.Allocator, value: ?[]const u8) !?[]const u8 {
    if (value) |slice| return try alloc.dupe(u8, slice);
    return null;
}

fn freeOptional(alloc: std.mem.Allocator, value: ?[]const u8) void {
    if (value) |slice| alloc.free(slice);
}

test "metric catalog merges descriptor metadata and rejects conflicts" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var catalog = try MetricCatalog.loadOrInit(alloc, tmp.dir, .none);
    defer catalog.deinit();

    try std.testing.expectEqual(RegisterResult.inserted, try catalog.register(.{
        .metric = "requests_total",
        .kind = .counter,
    }));
    try std.testing.expectEqual(RegisterResult.updated, try catalog.register(.{
        .metric = "requests_total",
        .description = "request count",
    }));
    try std.testing.expectEqual(RegisterResult.unchanged, try catalog.register(.{
        .metric = "requests_total",
        .kind = .counter,
    }));
    try std.testing.expectError(error.MetricDescriptorConflict, catalog.register(.{
        .metric = "requests_total",
        .kind = .gauge,
    }));
}
