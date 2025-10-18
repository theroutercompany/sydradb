const std = @import("std");
const plan = @import("plan.zig");
const ast = @import("ast.zig");
const meta = std.meta;

pub const BuildError = std.mem.Allocator.Error;

pub const PhysicalPlan = struct {
    root: *Node,
};

pub const Node = union(enum) {
    scan: Scan,
    filter: Filter,
    project: Project,
    aggregate: Aggregate,
    sort: Sort,
    limit: Limit,
};

pub const Scan = struct {
    selector: ?ast.Selector,
    output: []const plan.ColumnInfo,
    rollup_hint: ?plan.RollupHint,
    time_bounds: TimeBounds,
};

pub const Filter = struct {
    predicate: *const ast.Expr,
    output: []const plan.ColumnInfo,
    child: *Node,
    conjunction_count: usize,
    time_bounds: TimeBounds,
};

pub const Project = struct {
    columns: []const plan.ColumnInfo,
    child: *Node,
    reuse_child_schema: bool,
};

pub const Aggregate = struct {
    groupings: []const ast.GroupExpr,
    rollup_hint: ?plan.RollupHint,
    output: []const plan.ColumnInfo,
    child: *Node,
    requires_hash: bool,
    has_fill_clause: bool,
};

pub const Sort = struct {
    ordering: []const ast.OrderExpr,
    child: *Node,
    is_stable: bool,
    output: []const plan.ColumnInfo,
};

pub const Limit = struct {
    limit: ast.LimitClause,
    child: *Node,
    offset: usize,
    output: []const plan.ColumnInfo,
};

pub const TimeBounds = struct {
    min: ?i64 = null,
    min_inclusive: bool = true,
    max: ?i64 = null,
    max_inclusive: bool = true,
};

const Context = struct {
    time_bounds: TimeBounds = .{},
};

pub fn build(allocator: std.mem.Allocator, logical: *plan.Node) BuildError!PhysicalPlan {
    const root = try buildNode(allocator, logical, .{});
    return .{ .root = root };
}

pub fn nodeOutput(node: *Node) []const plan.ColumnInfo {
    return switch (node.*) {
        .scan => node.scan.output,
        .filter => node.filter.output,
        .project => node.project.columns,
        .aggregate => node.aggregate.output,
        .sort => node.sort.output,
        .limit => node.limit.output,
    };
}

fn buildNode(allocator: std.mem.Allocator, logical: *plan.Node, ctx: Context) BuildError!*Node {
    const node = try allocator.create(Node);
    switch (logical.*) {
        .scan => |scan| {
            node.* = .{ .scan = .{ .selector = scan.selector, .output = scan.output, .rollup_hint = detectScanRollup(scan), .time_bounds = ctx.time_bounds } };
        },
        .filter => |filter| {
            const extracted = extractTimeBounds(filter.conjunctive_predicates);
            const merged_ctx = Context{ .time_bounds = mergeTimeBounds(ctx.time_bounds, extracted) };
            const child = try buildNode(allocator, filter.input, merged_ctx);
            node.* = .{ .filter = .{ .predicate = filter.predicate, .output = filter.output, .child = child, .conjunction_count = filter.conjunctive_predicates.len, .time_bounds = extracted } };
        },
        .project => |project| {
            const child = try buildNode(allocator, project.input, ctx);
            node.* = .{ .project = .{ .columns = project.output, .child = child, .reuse_child_schema = child.* == .project } };
        },
        .aggregate => |aggregate| {
            const child = try buildNode(allocator, aggregate.input, ctx);
            node.* = .{ .aggregate = .{ .groupings = aggregate.groupings, .rollup_hint = aggregate.rollup_hint, .output = aggregate.output, .child = child, .requires_hash = aggregate.groupings.len != 0, .has_fill_clause = aggregate.fill != null } };
        },
        .sort => |sort| {
            const child = try buildNode(allocator, sort.input, ctx);
            node.* = .{ .sort = .{ .ordering = sort.ordering, .child = child, .is_stable = true, .output = sort.output } };
        },
        .limit => |limit| {
            const child = try buildNode(allocator, limit.input, ctx);
            node.* = .{ .limit = .{ .limit = limit.limit, .child = child, .offset = limit.limit.offset orelse 0, .output = limit.output } };
        },
    }
    return node;
}

fn detectScanRollup(scan: plan.Scan) ?plan.RollupHint {
    _ = scan;
    return null;
}

fn extractTimeBounds(predicates: []const *const ast.Expr) TimeBounds {
    var result = TimeBounds{};
    for (predicates) |expr| {
        if (timeBoundsFromExpr(expr)) |bounds| {
            result = mergeTimeBounds(result, bounds);
        }
    }
    return result;
}

fn timeBoundsFromExpr(expr: *const ast.Expr) ?TimeBounds {
    if (expr.* != .binary) return null;
    const bin = expr.binary;
    const lhs_time = exprIsTimeIdentifier(bin.left);
    const rhs_time = exprIsTimeIdentifier(bin.right);
    if (!lhs_time and !rhs_time) return null;

    const op = bin.op;
    if (lhs_time and rhs_time) return null;

    const literal = if (lhs_time) convertTimeLiteral(bin.right) else convertTimeLiteral(bin.left);
    if (literal == null) return null;
    const value = literal.?;
    var bounds = TimeBounds{};
    if (lhs_time) {
        switch (op) {
            .greater_equal => {
                bounds.min = value;
                bounds.min_inclusive = true;
            },
            .greater => {
                bounds.min = value;
                bounds.min_inclusive = false;
            },
            .less_equal => {
                bounds.max = value;
                bounds.max_inclusive = true;
            },
            .less => {
                bounds.max = value;
                bounds.max_inclusive = false;
            },
            .equal => {
                bounds.min = value;
                bounds.min_inclusive = true;
                bounds.max = value;
                bounds.max_inclusive = true;
            },
            else => return null,
        }
    } else { // time on right side
        switch (op) {
            .greater_equal => {
                bounds.max = value;
                bounds.max_inclusive = true;
            },
            .greater => {
                bounds.max = value;
                bounds.max_inclusive = false;
            },
            .less_equal => {
                bounds.min = value;
                bounds.min_inclusive = true;
            },
            .less => {
                bounds.min = value;
                bounds.min_inclusive = false;
            },
            .equal => {
                bounds.min = value;
                bounds.min_inclusive = true;
                bounds.max = value;
                bounds.max_inclusive = true;
            },
            else => return null,
        }
    }
    return bounds;
}

fn exprIsTimeIdentifier(expr: *const ast.Expr) bool {
    return switch (expr.*) {
        .identifier => |ident| std.ascii.eqlIgnoreCase(ident.value, "time"),
        else => false,
    };
}

fn convertTimeLiteral(expr: *const ast.Expr) ?i64 {
    return switch (expr.*) {
        .literal => |lit| switch (lit.value) {
            .integer => |value| value,
            else => null,
        },
        else => null,
    };
}

fn mergeTimeBounds(existing: TimeBounds, update: TimeBounds) TimeBounds {
    var result = existing;
    if (update.min) |new_min| {
        if (result.min) |current_min| {
            if (new_min > current_min or (new_min == current_min and !update.min_inclusive and result.min_inclusive)) {
                result.min = new_min;
                result.min_inclusive = update.min_inclusive;
            } else if (new_min == current_min) {
                result.min_inclusive = result.min_inclusive and update.min_inclusive;
            }
        } else {
            result.min = new_min;
            result.min_inclusive = update.min_inclusive;
        }
    }
    if (update.max) |new_max| {
        if (result.max) |current_max| {
            if (new_max < current_max or (new_max == current_max and !update.max_inclusive and result.max_inclusive)) {
                result.max = new_max;
                result.max_inclusive = update.max_inclusive;
            } else if (new_max == current_max) {
                result.max_inclusive = result.max_inclusive and update.max_inclusive;
            }
        } else {
            result.max = new_max;
            result.max_inclusive = update.max_inclusive;
        }
    }
    return result;
}

test "physical plan mirrors logical structure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const query = "select avg(value) from metrics where time >= 0 group by time_bucket(60, time)";
    var parser_inst = @import("parser.zig").Parser.init(arena.allocator(), query);
    var statement = try parser_inst.parse();

    var analyzer = @import("validator.zig").Analyzer.init(arena.allocator());
    var analysis = try analyzer.analyze(&statement);
    defer analyzer.deinit(&analysis);
    try std.testing.expect(analysis.is_valid);

    var builder = plan.Builder.init(arena.allocator());
    const logical_root = try builder.build(&statement);
    const physical_plan = try build(arena.allocator(), logical_root);

    try std.testing.expect(physical_plan.root.* == .project);
    const aggregate_node = physical_plan.root.project.child;
    try std.testing.expect(aggregate_node.* == .aggregate);
    try std.testing.expect(aggregate_node.aggregate.rollup_hint != null);
    try std.testing.expect(aggregate_node.aggregate.requires_hash);
    try std.testing.expect(!aggregate_node.aggregate.has_fill_clause);
}

test "physical filter captures time bounds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const query = "select value from metrics where time >= 10 and time < 20";
    var parser_inst = @import("parser.zig").Parser.init(arena.allocator(), query);
    var statement = try parser_inst.parse();

    var analyzer = @import("validator.zig").Analyzer.init(arena.allocator());
    var analysis = try analyzer.analyze(&statement);
    defer analyzer.deinit(&analysis);
    try std.testing.expect(analysis.is_valid);

    var builder = plan.Builder.init(arena.allocator());
    const logical_root = try builder.build(&statement);
    const physical_plan = try build(arena.allocator(), logical_root);

    try std.testing.expect(physical_plan.root.* == .project);
    const filter_node = physical_plan.root.project.child;
    try std.testing.expect(filter_node.* == .filter);
    const bounds = filter_node.filter.time_bounds;
    try std.testing.expect(bounds.min != null);
    try std.testing.expectEqual(@as(i64, 10), bounds.min.?);
    try std.testing.expect(bounds.min_inclusive);
    try std.testing.expect(bounds.max != null);
    try std.testing.expectEqual(@as(i64, 20), bounds.max.?);
    try std.testing.expect(!bounds.max_inclusive);

    const scan_node = filter_node.filter.child;
    try std.testing.expect(scan_node.* == .scan);
    const scan_bounds = scan_node.scan.time_bounds;
    try std.testing.expect(scan_bounds.min != null);
    try std.testing.expectEqual(@as(i64, 10), scan_bounds.min.?);
    try std.testing.expect(scan_bounds.max != null);
    try std.testing.expectEqual(@as(i64, 20), scan_bounds.max.?);
}
