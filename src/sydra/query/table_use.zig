const std = @import("std");

const ast = @import("ast.zig");
const compiler = @import("compiler.zig");
const frontend = @import("frontend.zig");
const types = @import("../types.zig");

pub const TableUseKind = enum {
    series,
};

pub const TableUse = struct {
    kind: TableUseKind,
    name: []const u8,
    series_id: ?types.SeriesId = null,
};

pub fn freeTableUses(allocator: std.mem.Allocator, uses: []TableUse) void {
    for (uses) |use| {
        if (use.name.len != 0) allocator.free(use.name);
    }
    allocator.free(uses);
}

pub fn collectTableUses(
    allocator: std.mem.Allocator,
    typed_query: ?compiler.TypedQuery,
    statement: frontend.normalize.Statement,
) ![]TableUse {
    var uses = std.array_list.Managed(TableUse).init(allocator);
    errdefer for (uses.items) |use| allocator.free(use.name);
    defer uses.deinit();

    if (typed_query) |typed| {
        if (typed.bound_selector) |selector| {
            try appendBoundSelectorTableUse(allocator, &uses, selector);
        } else if (typed.select.selector) |selector| {
            try appendAstSelectorTableUse(allocator, &uses, selector);
        }
    } else {
        try appendFrontendStatementTableUses(allocator, &uses, statement);
    }

    return try uses.toOwnedSlice();
}

fn appendFrontendStatementTableUses(
    allocator: std.mem.Allocator,
    uses: *std.array_list.Managed(TableUse),
    statement: frontend.normalize.Statement,
) !void {
    switch (statement) {
        .select => |select| {
            if (select.selector) |selector| {
                try appendFrontendSelectorTableUse(allocator, uses, selector);
            }
        },
        .insert => |insert| {
            try appendTableUse(allocator, uses, .series, insert.target.value, null);
        },
        .delete => |delete| {
            try appendTableUse(allocator, uses, .series, delete.target.value, null);
        },
        .explain => |explain| try appendFrontendStatementTableUses(allocator, uses, explain.target.*),
    }
}

fn appendBoundSelectorTableUse(
    allocator: std.mem.Allocator,
    uses: *std.array_list.Managed(TableUse),
    selector: compiler.BoundSelector,
) !void {
    if (selector.name) |name| {
        try appendTableUse(allocator, uses, .series, name, selector.series_id);
        return;
    }

    const rendered = try std.fmt.allocPrint(allocator, "series_id:{d}", .{selector.series_id});
    errdefer allocator.free(rendered);
    for (uses.items) |existing| {
        if (existing.kind == .series and existing.series_id == selector.series_id and std.mem.eql(u8, existing.name, rendered)) {
            allocator.free(rendered);
            return;
        }
    }
    try appendOwnedTableUse(uses, .series, rendered, selector.series_id);
}

fn appendFrontendSelectorTableUse(
    allocator: std.mem.Allocator,
    uses: *std.array_list.Managed(TableUse),
    selector: frontend.normalize.Selector,
) !void {
    switch (selector.series) {
        .name => |name| try appendTableUse(allocator, uses, .series, name.value, null),
        .by_id => |by_id| {
            const rendered = try std.fmt.allocPrint(allocator, "series_id:{d}", .{by_id.value});
            errdefer allocator.free(rendered);
            for (uses.items) |existing| {
                if (existing.kind == .series and existing.series_id == @as(types.SeriesId, @intCast(by_id.value)) and std.mem.eql(u8, existing.name, rendered)) {
                    allocator.free(rendered);
                    return;
                }
            }
            try appendOwnedTableUse(uses, .series, rendered, @intCast(by_id.value));
        },
    }
}

fn appendAstSelectorTableUse(
    allocator: std.mem.Allocator,
    uses: *std.array_list.Managed(TableUse),
    selector: ast.Selector,
) !void {
    switch (selector.series) {
        .name => |name| try appendTableUse(allocator, uses, .series, name.value, null),
        .by_id => |by_id| {
            const rendered = try std.fmt.allocPrint(allocator, "series_id:{d}", .{by_id.value});
            errdefer allocator.free(rendered);
            for (uses.items) |existing| {
                if (existing.kind == .series and existing.series_id == @as(types.SeriesId, @intCast(by_id.value)) and std.mem.eql(u8, existing.name, rendered)) {
                    allocator.free(rendered);
                    return;
                }
            }
            try appendOwnedTableUse(uses, .series, rendered, @intCast(by_id.value));
        },
    }
}

fn appendTableUse(
    allocator: std.mem.Allocator,
    uses: *std.array_list.Managed(TableUse),
    kind: TableUseKind,
    name: []const u8,
    series_id: ?types.SeriesId,
) !void {
    for (uses.items) |existing| {
        if (existing.kind == kind and existing.series_id == series_id and std.mem.eql(u8, existing.name, name)) {
            return;
        }
    }
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    try appendOwnedTableUse(uses, kind, owned_name, series_id);
}

fn appendOwnedTableUse(
    uses: *std.array_list.Managed(TableUse),
    kind: TableUseKind,
    owned_name: []const u8,
    series_id: ?types.SeriesId,
) !void {
    try uses.append(.{
        .kind = kind,
        .name = owned_name,
        .series_id = series_id,
    });
}
