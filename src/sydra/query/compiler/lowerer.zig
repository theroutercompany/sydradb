const std = @import("std");

const ast = @import("../ast.zig");
const errors = @import("errors.zig");
const ir = @import("ir.zig");
const passes = @import("passes.zig");
const physical = @import("../physical.zig");
const plan = @import("../plan.zig");

pub fn lowerTypedQuery(
    allocator: std.mem.Allocator,
    typed_query: *const ir.TypedQuery,
) errors.CompileError!ir.BackendLoweringResult {
    const physical_start = std.time.microTimestamp();
    const physical_plan = try buildPhysicalPlan(allocator, typed_query);
    const physical_end = std.time.microTimestamp();

    return .{
        .physical_plan = physical_plan,
        .physical_us = durationMicros(physical_end - physical_start),
    };
}

fn buildPhysicalPlan(
    allocator: std.mem.Allocator,
    typed_query: *const ir.TypedQuery,
) errors.CompileError!physical.PhysicalPlan {
    var current = try buildInputNode(allocator, typed_query);
    const final_columns = try buildProjectionColumns(allocator, typed_query.projections);
    const time_bounds = lowerTimeBounds(typed_query.time_range);

    if (typed_query.predicate) |predicate| {
        current = try makeNode(allocator, .{
            .filter = .{
                .predicate = predicate.expr,
                .output = physical.nodeOutput(current),
                .child = current,
                .conjunction_count = countConjunctions(predicate.expr),
                .time_bounds = time_bounds,
            },
        });
    }

    if (typed_query.is_aggregate_query) {
        current = try makeNode(allocator, .{
            .aggregate = .{
                .groupings = typed_query.select.groupings,
                .rollup_hint = detectRollupHint(typed_query),
                .output = final_columns,
                .child = current,
                .requires_hash = typed_query.groupings.len != 0,
                .has_fill_clause = typed_query.select.fill != null,
                .fill = typed_query.select.fill,
            },
        });
    } else {
        current = try makeNode(allocator, .{
            .project = .{
                .columns = final_columns,
                .child = current,
                .reuse_child_schema = false,
            },
        });
    }

    if (typed_query.ordering.len != 0) {
        current = try makeNode(allocator, .{
            .sort = .{
                .ordering = typed_query.select.ordering,
                .child = current,
                .is_stable = true,
                .output = physical.nodeOutput(current),
            },
        });
    }

    if (typed_query.select.limit) |limit_clause| {
        current = try makeNode(allocator, .{
            .limit = .{
                .limit = limit_clause,
                .child = current,
                .offset = limit_clause.offset orelse 0,
                .output = physical.nodeOutput(current),
            },
        });
    }

    return .{ .root = current };
}

fn buildInputNode(
    allocator: std.mem.Allocator,
    typed_query: *const ir.TypedQuery,
) errors.CompileError!*physical.Node {
    if (typed_query.select.selector == null) {
        return makeNode(allocator, .{
            .one_row = .{
                .output = &.{},
            },
        });
    }

    const bound_selector = typed_query.bound_selector orelse return error.SeriesNotFound;
    const scan_columns = try passes.pruneScanColumns(allocator, typed_query);
    return makeNode(allocator, .{
        .scan = .{
            .selector = .{ .bound = .{
                .source = switch (bound_selector.source) {
                    .by_id => .by_id,
                    .unique_name => .unique_name,
                    .exact_match => .exact_match,
                },
                .series_id = bound_selector.series_id,
                .name = bound_selector.name,
                .canonical_tags = bound_selector.canonical_tags,
                .span = bound_selector.span,
            } },
            .output = scan_columns,
            .rollup_hint = null,
            .time_bounds = lowerTimeBounds(typed_query.time_range),
            .label_constraints = &.{},
            .require_exact_series = false,
        },
    });
}

fn buildProjectionColumns(
    allocator: std.mem.Allocator,
    projections: []const ir.TypedProjection,
) ![]const plan.ColumnInfo {
    const columns = try allocator.alloc(plan.ColumnInfo, projections.len);
    for (projections, 0..) |projection, idx| {
        columns[idx] = .{
            .name = projection.name,
            .expr = projection.expr.expr,
        };
    }
    return columns;
}

fn detectRollupHint(typed_query: *const ir.TypedQuery) ?plan.RollupHint {
    for (typed_query.groupings) |grouping| {
        if (grouping.is_time_bucket) {
            return .{ .bucket_expr = grouping.expr.expr };
        }
    }
    return null;
}

fn lowerTimeBounds(time_range: ir.TimeRange) physical.TimeBounds {
    return .{
        .min = if (time_range.start) |bound| bound.value else null,
        .min_inclusive = if (time_range.start) |bound| bound.inclusive else true,
        .max = if (time_range.end) |bound| bound.value else null,
        .max_inclusive = if (time_range.end) |bound| bound.inclusive else true,
    };
}

fn countConjunctions(expr: *const ast.Expr) usize {
    return switch (expr.*) {
        .binary => |binary| if (binary.op == .logical_and)
            countConjunctions(binary.left) + countConjunctions(binary.right)
        else
            1,
        else => 1,
    };
}

fn makeNode(allocator: std.mem.Allocator, node: physical.Node) !*physical.Node {
    const ptr = try allocator.create(physical.Node);
    ptr.* = node;
    return ptr;
}

fn durationMicros(value: i64) u64 {
    return @intCast(@max(value, 0));
}
