const std = @import("std");

const ast = @import("../ast.zig");
const errors = @import("errors.zig");
const ir = @import("ir.zig");
const optimizer = @import("../optimizer.zig");
const physical = @import("../physical.zig");
const plan = @import("../plan.zig");

pub fn lowerTypedQuery(
    allocator: std.mem.Allocator,
    typed_query: *const ir.TypedQuery,
) errors.CompileError!ir.BackendLoweringResult {
    var bound_statement = typed_query.statement;

    if (typed_query.statement.* == .select and typed_query.bound_selector != null) {
        const original_select = typed_query.select;
        const selector_ptr = try allocator.create(ast.Selector);
        selector_ptr.* = .{
            .series = .{ .by_id = .{
                .value = typed_query.bound_selector.?.series_id,
                .span = typed_query.bound_selector.?.span,
            } },
            .tag_filter = null,
            .span = original_select.selector.?.span,
        };

        const select_ptr = try allocator.create(ast.Select);
        select_ptr.* = .{
            .projections = original_select.projections,
            .selector = selector_ptr.*,
            .predicate = original_select.predicate,
            .groupings = original_select.groupings,
            .fill = original_select.fill,
            .ordering = original_select.ordering,
            .limit = original_select.limit,
            .span = original_select.span,
        };

        const statement_ptr = try allocator.create(ast.Statement);
        statement_ptr.* = .{ .select = select_ptr };
        bound_statement = statement_ptr;
    }

    const logical_start = std.time.microTimestamp();
    var builder = plan.Builder.init(allocator);
    const logical_plan = try builder.build(bound_statement);
    const logical_end = std.time.microTimestamp();

    const optimize_start = std.time.microTimestamp();
    const optimized_plan = try optimizer.optimize(allocator, logical_plan);
    const optimize_end = std.time.microTimestamp();

    const physical_start = std.time.microTimestamp();
    const physical_plan = try physical.build(allocator, optimized_plan);
    const physical_end = std.time.microTimestamp();

    return .{
        .logical_plan = logical_plan,
        .optimized_plan = optimized_plan,
        .physical_plan = physical_plan,
        .logical_us = durationMicros(logical_end - logical_start),
        .optimize_us = durationMicros(optimize_end - optimize_start),
        .physical_us = durationMicros(physical_end - physical_start),
    };
}

fn durationMicros(value: i64) u64 {
    return @intCast(@max(value, 0));
}
