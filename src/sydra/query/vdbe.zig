const std = @import("std");

const expression = @import("expression.zig");
const types = @import("../types.zig");
const value_mod = @import("value.zig");

pub const SeriesCursor = struct {
    points: std.array_list.Managed(types.Point),
    index: usize = 0,
    current: ?types.Point = null,

    pub fn init(allocator: std.mem.Allocator) SeriesCursor {
        return .{ .points = std.array_list.Managed(types.Point).init(allocator) };
    }

    pub fn deinit(self: *SeriesCursor) void {
        self.points.deinit();
        self.* = undefined;
    }

    pub fn reset(self: *SeriesCursor) void {
        self.points.clearRetainingCapacity();
        self.index = 0;
        self.current = null;
    }
};

pub const RollupCursor = struct {
    active: bool = false,

    pub fn reset(self: *RollupCursor) void {
        self.active = false;
    }
};

pub const TagCursor = struct {
    active: bool = false,
    entries: []expression.TagField = &.{},

    pub fn deinit(self: *TagCursor, allocator: std.mem.Allocator) void {
        self.clear(allocator);
        self.* = undefined;
    }

    pub fn reset(self: *TagCursor) void {
        self.active = false;
    }

    pub fn clear(self: *TagCursor, allocator: std.mem.Allocator) void {
        for (self.entries) |entry| {
            allocator.free(@constCast(entry.key));
            allocator.free(@constCast(entry.value));
        }
        if (self.entries.len != 0) allocator.free(self.entries);
        self.entries = &.{};
        self.active = false;
    }

    pub fn loadCanonicalTags(self: *TagCursor, allocator: std.mem.Allocator, tags_json: []const u8) !void {
        self.clear(allocator);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, tags_json, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return;

        var count: usize = 0;
        var it_count = parsed.value.object.iterator();
        while (it_count.next()) |entry| {
            if (entry.value_ptr.* == .string) count += 1;
        }
        if (count == 0) return;

        const entries = try allocator.alloc(expression.TagField, count);
        errdefer allocator.free(entries);

        var idx: usize = 0;
        var it = parsed.value.object.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* != .string) continue;
            entries[idx] = .{
                .key = try allocator.dupe(u8, entry.key_ptr.*),
                .value = try allocator.dupe(u8, entry.value_ptr.string),
            };
            idx += 1;
        }

        self.entries = entries;
        self.active = true;
    }
};

pub const CatalogCursor = struct {
    active: bool = false,

    pub fn reset(self: *CatalogCursor) void {
        self.active = false;
    }
};

pub const SorterRow = struct {
    values: []value_mod.Value,
    keys: []value_mod.Value,
    sequence: usize,
};

pub const TempSorter = struct {
    rows: std.array_list.Managed(SorterRow),
    index: usize = 0,
    next_sequence: usize = 0,
    offset: usize = 0,
    take: ?usize = null,
    ordering_id: ?usize = null,
    sorted: bool = false,

    pub fn init(allocator: std.mem.Allocator) TempSorter {
        return .{ .rows = std.array_list.Managed(SorterRow).init(allocator) };
    }

    pub fn deinit(self: *TempSorter, allocator: std.mem.Allocator) void {
        self.clear(allocator);
        self.rows.deinit();
        self.* = undefined;
    }

    pub fn clear(self: *TempSorter, allocator: std.mem.Allocator) void {
        for (self.rows.items) |row| {
            allocator.free(row.values);
            allocator.free(row.keys);
        }
        self.rows.clearRetainingCapacity();
        self.index = 0;
        self.next_sequence = 0;
        self.offset = 0;
        self.take = null;
        self.ordering_id = null;
        self.sorted = false;
    }
};

pub const AvgState = struct {
    total: f64 = 0,
    count: u64 = 0,
};

pub const OptionalValue = struct {
    seen: bool = false,
    value: value_mod.Value = .null,
};

pub const AggregateState = union(enum) {
    avg: AvgState,
    sum: f64,
    count: u64,
    min: OptionalValue,
    max: OptionalValue,
    first: OptionalValue,
    last: OptionalValue,
};

pub const AggregateGroup = struct {
    keys: []value_mod.Value,
    states: []AggregateState,
};

pub const AggTable = struct {
    groups: std.array_list.Managed(AggregateGroup),
    rows: std.array_list.Managed([]value_mod.Value),
    index: usize = 0,
    finalized: bool = false,
    group_expr_start: usize = 0,
    group_expr_count: usize = 0,
    aggregate_start: usize = 0,
    aggregate_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator) AggTable {
        return .{
            .groups = std.array_list.Managed(AggregateGroup).init(allocator),
            .rows = std.array_list.Managed([]value_mod.Value).init(allocator),
        };
    }

    pub fn deinit(self: *AggTable, allocator: std.mem.Allocator) void {
        self.clear(allocator);
        self.groups.deinit();
        self.rows.deinit();
        self.* = undefined;
    }

    pub fn clear(self: *AggTable, allocator: std.mem.Allocator) void {
        for (self.groups.items) |group| {
            allocator.free(group.keys);
            allocator.free(group.states);
        }
        self.groups.clearRetainingCapacity();
        for (self.rows.items) |row| allocator.free(row);
        self.rows.clearRetainingCapacity();
        self.index = 0;
        self.finalized = false;
        self.group_expr_start = 0;
        self.group_expr_count = 0;
        self.aggregate_start = 0;
        self.aggregate_count = 0;
    }
};

test "vdbe substrate cursor and sorter reset state" {
    const alloc = std.testing.allocator;

    var cursor = SeriesCursor.init(alloc);
    defer cursor.deinit();
    try cursor.points.append(.{ .ts = 10, .value = 1.0 });
    cursor.index = 1;
    cursor.current = cursor.points.items[0];
    cursor.reset();
    try std.testing.expectEqual(@as(usize, 0), cursor.points.items.len);
    try std.testing.expectEqual(@as(usize, 0), cursor.index);
    try std.testing.expect(cursor.current == null);

    var sorter = TempSorter.init(alloc);
    defer sorter.deinit(alloc);
    const values = try alloc.dupe(value_mod.Value, &.{value_mod.Value{ .integer = 1 }});
    const keys = try alloc.dupe(value_mod.Value, &.{value_mod.Value{ .integer = 1 }});
    try sorter.rows.append(.{ .values = values, .keys = keys, .sequence = 0 });
    sorter.sorted = true;
    sorter.clear(alloc);
    try std.testing.expectEqual(@as(usize, 0), sorter.rows.items.len);
    try std.testing.expect(!sorter.sorted);
}

test "tag cursor loads canonical selector tags" {
    const alloc = std.testing.allocator;
    var cursor = TagCursor{};
    defer cursor.deinit(alloc);

    try cursor.loadCanonicalTags(alloc, "{\"host\":\"a\",\"rack\":\"r1\"}");
    try std.testing.expect(cursor.active);
    try std.testing.expectEqual(@as(usize, 2), cursor.entries.len);

    cursor.clear(alloc);
    try std.testing.expectEqual(@as(usize, 0), cursor.entries.len);
    try std.testing.expect(!cursor.active);
}
