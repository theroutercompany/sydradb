const std = @import("std");

const ast = @import("../ast.zig");
const expression = @import("../expression.zig");
const functions = @import("../functions.zig");
const infer = @import("../type_inference.zig");
const errors = @import("errors.zig");
const ir = @import("ir.zig");

pub fn buildTypedSelect(
    allocator: std.mem.Allocator,
    statement: *const ast.Statement,
    bound_selector: ?ir.BoundSelector,
) errors.CompileError!ir.TypedQuery {
    if (statement.* != .select) return error.UnsupportedStatement;
    const select = statement.select;
    if (select.fill != null) return error.UnsupportedFill;

    const deferred_features = &[_]ir.DeferredFeature{};
    const predicate = if (select.predicate) |expr| try typeCheckedExpr(allocator, expr) else null;
    if (predicate) |typed| {
        try ensurePredicateSupported(typed.expr);
    }

    const groupings = try buildTypedGroupings(allocator, select.groupings);
    const aggregates = try buildAggregateSpecs(allocator, select.projections);
    const is_aggregate_query = groupings.len != 0 or aggregates.len != 0;
    const projections = try buildTypedProjections(allocator, select.projections, groupings, aggregates, bound_selector != null);
    const ordering = try buildTypedOrderings(allocator, select.ordering, projections);
    const time_range = extractTimeRange(if (predicate) |typed| typed.expr else null);
    const properties = deriveProperties(select, groupings, aggregates, ordering);

    return .{
        .statement = statement,
        .select = select,
        .bound_selector = bound_selector,
        .predicate = predicate,
        .projections = projections,
        .groupings = groupings,
        .ordering = ordering,
        .aggregates = aggregates,
        .time_range = time_range,
        .properties = properties,
        .deferred_features = deferred_features,
        .is_aggregate_query = is_aggregate_query,
    };
}

pub fn typeCheckedExpr(allocator: std.mem.Allocator, expr: *const ast.Expr) errors.CompileError!ir.TypedExpr {
    const info = try infer.inferExpression(allocator, expr);
    return .{
        .expr = expr,
        .ty = info.ty,
        .has_time = info.has_time,
    };
}

pub fn buildTypedGroupings(
    allocator: std.mem.Allocator,
    groupings: []const ast.GroupExpr,
) errors.CompileError![]const ir.TypedGrouping {
    if (groupings.len == 0) return &[_]ir.TypedGrouping{};
    if (groupings.len != 1) return error.UnsupportedGrouping;

    const typed = try typeCheckedExpr(allocator, groupings[0].expr);
    if (!isTimeBucketExpr(groupings[0].expr)) return error.UnsupportedGrouping;
    try ensureTimeBucketSupported(groupings[0].expr);

    const list = try allocator.alloc(ir.TypedGrouping, 1);
    list[0] = .{
        .expr = typed,
        .is_time_bucket = true,
    };
    return list;
}

pub fn buildAggregateSpecs(
    allocator: std.mem.Allocator,
    projections: []const ast.Projection,
) errors.CompileError![]const ir.AggregateSpec {
    var count: usize = 0;
    for (projections) |projection| {
        if (projection.expr.* == .call) {
            const call = projection.expr.call;
            if (functions.lookup(call.callee.value)) |signature| {
                if (signature.kind == .aggregate) count += 1;
            }
        }
    }

    if (count == 0) return &[_]ir.AggregateSpec{};

    const specs = try allocator.alloc(ir.AggregateSpec, count);
    var index: usize = 0;
    for (projections) |projection| {
        if (projection.expr.* != .call) continue;
        const call = projection.expr.call;
        const signature = functions.lookup(call.callee.value) orelse continue;
        if (signature.kind != .aggregate) continue;

        const aggregate_kind = classifyAggregate(call.callee.value) orelse return error.UnsupportedAggregate;
        const arg_exprs = try allocator.alloc(ir.TypedExpr, call.args.len);
        for (call.args, 0..) |arg, arg_idx| {
            arg_exprs[arg_idx] = try typeCheckedExpr(allocator, arg);
            try ensureRawRowScalarSupported(arg);
        }

        specs[index] = .{
            .expr = projection.expr,
            .kind = aggregate_kind,
            .name = call.callee.value,
            .args = arg_exprs,
            .return_type = (try typeCheckedExpr(allocator, projection.expr)).ty,
        };
        index += 1;
    }
    return specs;
}

pub fn buildTypedProjections(
    allocator: std.mem.Allocator,
    projections: []const ast.Projection,
    groupings: []const ir.TypedGrouping,
    aggregates: []const ir.AggregateSpec,
    has_selector: bool,
) errors.CompileError![]const ir.TypedProjection {
    if (projections.len == 0) return &[_]ir.TypedProjection{};

    const typed = try allocator.alloc(ir.TypedProjection, projections.len);
    const aggregate_query = groupings.len != 0 or aggregates.len != 0;

    for (projections, 0..) |projection, idx| {
        const typed_expr = try typeCheckedExpr(allocator, projection.expr);
        const is_grouping = matchesGrouping(projection.expr, groupings);
        const is_aggregate = matchesAggregate(projection.expr, aggregates);

        if (aggregate_query) {
            if (!is_grouping and !is_aggregate) return error.UnsupportedProjection;
        } else if (has_selector) {
            try ensureRawRowScalarSupported(projection.expr);
        } else {
            try ensureConstantOnlySupported(projection.expr);
        }

        typed[idx] = .{
            .expr = typed_expr,
            .name = try inferProjectionName(allocator, projection, idx),
            .alias = projection.alias,
            .is_grouping = is_grouping,
            .is_aggregate = is_aggregate,
        };
    }

    return typed;
}

pub fn buildTypedOrderings(
    allocator: std.mem.Allocator,
    ordering: []const ast.OrderExpr,
    projections: []const ir.TypedProjection,
) errors.CompileError![]const ir.TypedOrdering {
    if (ordering.len == 0) return &[_]ir.TypedOrdering{};

    const out = try allocator.alloc(ir.TypedOrdering, ordering.len);
    for (ordering, 0..) |order_expr, idx| {
        if (order_expr.expr.* == .identifier) {
            try ensureOrderIdentifier(order_expr.expr.identifier, projections);
        } else if (!matchesProjectionExpr(order_expr.expr, projections)) {
            return error.UnsupportedOrdering;
        }
        out[idx] = .{
            .expr = try typeCheckedExpr(allocator, order_expr.expr),
            .direction = order_expr.direction,
        };
    }
    return out;
}

pub fn deriveProperties(
    select: *const ast.Select,
    groupings: []const ir.TypedGrouping,
    aggregates: []const ir.AggregateSpec,
    ordering: []const ir.TypedOrdering,
) ir.QueryProperties {
    var requires_sorted_input = ordering.len != 0;
    for (aggregates) |aggregate| {
        if (functions.lookup(aggregate.name)) |signature| {
            if (signature.hints.requires_sorted_input) requires_sorted_input = true;
        }
    }

    return .{
        .requires_sorted_input = requires_sorted_input,
        .can_use_rollup = groupings.len != 0,
        .materializes = aggregates.len != 0 or ordering.len != 0 or select.limit != null,
        .uses_top_n = ordering.len != 0 and select.limit != null,
    };
}

pub fn inferProjectionName(
    allocator: std.mem.Allocator,
    projection: ast.Projection,
    index: usize,
) ![]const u8 {
    if (projection.alias) |alias| {
        return allocator.dupe(u8, alias.value);
    }
    return switch (projection.expr.*) {
        .identifier => |ident| allocator.dupe(u8, ident.value),
        .call => |call| std.fmt.allocPrint(allocator, "{s}_{d}", .{ call.callee.value, index }),
        else => std.fmt.allocPrint(allocator, "_col{d}", .{index}),
    };
}

pub fn extractTimeRange(predicate: ?*const ast.Expr) ir.TimeRange {
    if (predicate == null) return .{};
    return timeRangeFromExpr(predicate.?);
}

pub fn pruneScanColumns(
    allocator: std.mem.Allocator,
    typed_query: *const ir.TypedQuery,
) ![]const @import("../plan.zig").ColumnInfo {
    const plan = @import("../plan.zig");
    const need_time = needsIdentifier(typed_query, "time");
    const need_value = needsIdentifier(typed_query, "value");
    const column_count: usize =
        @as(usize, @intFromBool(need_time)) +
        @as(usize, @intFromBool(need_value));
    const cols = try allocator.alloc(plan.ColumnInfo, column_count);

    var next_idx: usize = 0;
    if (need_time) {
        const time_name = try allocator.dupe(u8, "time");
        const time_ident = ast.Identifier{ .value = time_name, .quoted = false, .span = astSpan() };
        const time_expr = try allocator.create(ast.Expr);
        time_expr.* = .{ .identifier = time_ident };
        cols[next_idx] = .{ .name = time_name, .expr = time_expr };
        next_idx += 1;
    }
    if (need_value) {
        const value_name = try allocator.dupe(u8, "value");
        const value_ident = ast.Identifier{ .value = value_name, .quoted = false, .span = astSpan() };
        const value_expr = try allocator.create(ast.Expr);
        value_expr.* = .{ .identifier = value_ident };
        cols[next_idx] = .{ .name = value_name, .expr = value_expr };
    }
    return cols;
}

fn astSpan() @import("../common.zig").Span {
    return @import("../common.zig").Span.init(0, 0);
}

fn needsIdentifier(typed_query: *const ir.TypedQuery, name: []const u8) bool {
    for (typed_query.projections) |projection| {
        if (expressionContainsIdentifier(projection.expr.expr, name)) return true;
    }
    if (typed_query.predicate) |predicate| {
        if (expressionContainsIdentifier(predicate.expr, name)) return true;
    }
    for (typed_query.groupings) |grouping| {
        if (expressionContainsIdentifier(grouping.expr.expr, name)) return true;
    }
    for (typed_query.ordering) |ordering| {
        if (expressionContainsIdentifier(ordering.expr.expr, name)) return true;
    }
    return false;
}

fn expressionContainsIdentifier(expr: *const ast.Expr, name: []const u8) bool {
    return switch (expr.*) {
        .identifier => |ident| std.ascii.eqlIgnoreCase(trailingSegment(ident.value), trailingSegment(name)),
        .literal => false,
        .unary => |unary| expressionContainsIdentifier(unary.operand, name),
        .binary => |binary| expressionContainsIdentifier(binary.left, name) or expressionContainsIdentifier(binary.right, name),
        .call => |call| blk: {
            for (call.args) |arg| {
                if (expressionContainsIdentifier(arg, name)) break :blk true;
            }
            break :blk false;
        },
    };
}

fn ensurePredicateSupported(expr: *const ast.Expr) errors.CompileError!void {
    try ensureRawRowScalarSupported(expr);
}

fn ensureConstantOnlySupported(expr: *const ast.Expr) errors.CompileError!void {
    switch (expr.*) {
        .identifier => return error.UnsupportedExpression,
        .literal => return,
        .unary => |unary| return ensureConstantOnlySupported(unary.operand),
        .binary => |binary| {
            try ensureBinaryOpSupported(binary.op);
            try ensureConstantOnlySupported(binary.left);
            try ensureConstantOnlySupported(binary.right);
        },
        .call => return error.UnsupportedFunction,
    }
}

fn ensureRawRowScalarSupported(expr: *const ast.Expr) errors.CompileError!void {
    switch (expr.*) {
        .identifier => |ident| {
            if (!identifierAllowedInRawRow(ident.value)) return error.UnsupportedExpression;
        },
        .literal => {},
        .unary => |unary| try ensureRawRowScalarSupported(unary.operand),
        .binary => |binary| {
            try ensureBinaryOpSupported(binary.op);
            try ensureRawRowScalarSupported(binary.left);
            try ensureRawRowScalarSupported(binary.right);
        },
        .call => |call| {
            if (std.ascii.eqlIgnoreCase(call.callee.value, "time_bucket")) {
                try ensureTimeBucketSupported(expr);
                return;
            }
            if (isSupportedUnaryRawRowFunction(call.callee.value)) {
                if (call.args.len != 1) return error.UnsupportedFunction;
                try ensureRawRowScalarSupported(call.args[0]);
                return;
            }
            if (std.ascii.eqlIgnoreCase(call.callee.value, "pow")) {
                if (call.args.len != 2) return error.UnsupportedFunction;
                try ensureRawRowScalarSupported(call.args[0]);
                try ensureRawRowScalarSupported(call.args[1]);
                return;
            }
            return error.UnsupportedFunction;
        },
    }
}

fn ensureTimeBucketSupported(expr: *const ast.Expr) errors.CompileError!void {
    if (expr.* != .call) return error.UnsupportedFunction;
    const call = expr.call;
    if (!std.ascii.eqlIgnoreCase(call.callee.value, "time_bucket")) return error.UnsupportedFunction;
    if (call.args.len != 2 and call.args.len != 3) return error.UnsupportedFunction;
    if (call.args[0].* == .identifier) return error.UnsupportedFunction;
    if (!infer.expressionHasTime(call.args[1])) return error.UnsupportedFunction;
    for (call.args, 0..) |arg, idx| {
        if (idx == 1) {
            try ensureRawRowScalarSupported(arg);
        } else {
            try ensureConstantOnlySupported(arg);
        }
    }
}

fn ensureBinaryOpSupported(op: ast.BinaryOp) errors.CompileError!void {
    switch (op) {
        .add,
        .subtract,
        .multiply,
        .divide,
        .modulo,
        .equal,
        .not_equal,
        .less,
        .less_equal,
        .greater,
        .greater_equal,
        .logical_and,
        .logical_or,
        => {},
        else => return error.UnsupportedExpression,
    }
}

fn isSupportedUnaryRawRowFunction(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "abs") or
        std.ascii.eqlIgnoreCase(name, "ceil") or
        std.ascii.eqlIgnoreCase(name, "floor") or
        std.ascii.eqlIgnoreCase(name, "round") or
        std.ascii.eqlIgnoreCase(name, "sqrt") or
        std.ascii.eqlIgnoreCase(name, "ln");
}

fn ensureOrderIdentifier(
    order_ident: ast.Identifier,
    projections: []const ir.TypedProjection,
) errors.CompileError!void {
    for (projections) |projection| {
        if (std.ascii.eqlIgnoreCase(projection.name, order_ident.value)) return;
    }
    return error.UnsupportedOrdering;
}

fn identifierAllowedInRawRow(name: []const u8) bool {
    const segment = trailingSegment(name);
    return std.ascii.eqlIgnoreCase(segment, "time") or std.ascii.eqlIgnoreCase(segment, "value");
}

fn matchesGrouping(expr: *const ast.Expr, groupings: []const ir.TypedGrouping) bool {
    for (groupings) |grouping| {
        if (expression.expressionsEqual(expr, grouping.expr.expr)) return true;
    }
    return false;
}

fn matchesAggregate(expr: *const ast.Expr, aggregates: []const ir.AggregateSpec) bool {
    for (aggregates) |aggregate| {
        if (expression.expressionsEqual(expr, aggregate.expr)) return true;
    }
    return false;
}

fn matchesProjectionExpr(expr: *const ast.Expr, projections: []const ir.TypedProjection) bool {
    for (projections) |projection| {
        if (expression.expressionsEqual(expr, projection.expr.expr)) return true;
    }
    return false;
}

fn classifyAggregate(name: []const u8) ?ir.AggregateKind {
    if (std.ascii.eqlIgnoreCase(name, "avg")) return .avg;
    if (std.ascii.eqlIgnoreCase(name, "sum")) return .sum;
    if (std.ascii.eqlIgnoreCase(name, "count")) return .count;
    if (std.ascii.eqlIgnoreCase(name, "min")) return .min;
    if (std.ascii.eqlIgnoreCase(name, "max")) return .max;
    if (std.ascii.eqlIgnoreCase(name, "first")) return .first;
    if (std.ascii.eqlIgnoreCase(name, "last")) return .last;
    return null;
}

fn isTimeBucketExpr(expr: *const ast.Expr) bool {
    if (expr.* != .call) return false;
    return std.ascii.eqlIgnoreCase(expr.call.callee.value, "time_bucket");
}

fn timeRangeFromExpr(expr: *const ast.Expr) ir.TimeRange {
    switch (expr.*) {
        .binary => |binary| {
            if (binary.op == .logical_and) {
                return mergeTimeRanges(timeRangeFromExpr(binary.left), timeRangeFromExpr(binary.right));
            }
            const lhs_time = infer.expressionHasTime(binary.left) and binary.left.* == .identifier and identifierAllowedInRawRow(binary.left.identifier.value);
            const rhs_time = infer.expressionHasTime(binary.right) and binary.right.* == .identifier and identifierAllowedInRawRow(binary.right.identifier.value);
            if (lhs_time == rhs_time) return .{};

            const literal = if (lhs_time) literalToTimestamp(binary.right) else literalToTimestamp(binary.left);
            if (literal == null) return .{};
            const value = literal.?;

            var range = ir.TimeRange{};
            if (lhs_time) {
                switch (binary.op) {
                    .greater_equal => range.start = .{ .value = value, .inclusive = true },
                    .greater => range.start = .{ .value = value, .inclusive = false },
                    .less_equal => range.end = .{ .value = value, .inclusive = true },
                    .less => range.end = .{ .value = value, .inclusive = false },
                    .equal => {
                        range.start = .{ .value = value, .inclusive = true };
                        range.end = .{ .value = value, .inclusive = true };
                    },
                    else => {},
                }
            } else {
                switch (binary.op) {
                    .greater_equal => range.end = .{ .value = value, .inclusive = true },
                    .greater => range.end = .{ .value = value, .inclusive = false },
                    .less_equal => range.start = .{ .value = value, .inclusive = true },
                    .less => range.start = .{ .value = value, .inclusive = false },
                    .equal => {
                        range.start = .{ .value = value, .inclusive = true };
                        range.end = .{ .value = value, .inclusive = true };
                    },
                    else => {},
                }
            }
            return range;
        },
        else => return .{},
    }
}

fn mergeTimeRanges(lhs: ir.TimeRange, rhs: ir.TimeRange) ir.TimeRange {
    var merged = lhs;
    if (rhs.start) |start| {
        if (merged.start == null or start.value > merged.start.?.value or (start.value == merged.start.?.value and !start.inclusive and merged.start.?.inclusive)) {
            merged.start = start;
        }
    }
    if (rhs.end) |ending| {
        if (merged.end == null or ending.value < merged.end.?.value or (ending.value == merged.end.?.value and !ending.inclusive and merged.end.?.inclusive)) {
            merged.end = ending;
        }
    }
    return merged;
}

fn literalToTimestamp(expr: *const ast.Expr) ?i64 {
    return switch (expr.*) {
        .literal => |literal| switch (literal.value) {
            .integer => |value| value,
            .float => |value| @intFromFloat(value),
            else => null,
        },
        else => null,
    };
}

fn trailingSegment(slice: []const u8) []const u8 {
    if (slice.len == 0) return slice;
    var index = slice.len;
    while (index > 0) {
        index -= 1;
        if (slice[index] == '.') return slice[index + 1 ..];
    }
    return slice;
}

test "extractTimeRange merges bounded predicates" {
    const parser = @import("../parser.zig");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser_inst = parser.Parser.init(arena.allocator(), "select value from metrics where time >= 10 and time < 20");
    const statement = try parser_inst.parse();
    const range = extractTimeRange(statement.select.predicate);

    try std.testing.expectEqual(@as(i64, 10), range.start.?.value);
    try std.testing.expect(range.start.?.inclusive);
    try std.testing.expectEqual(@as(i64, 20), range.end.?.value);
    try std.testing.expect(!range.end.?.inclusive);
}

test "raw row scalar support accepts pow and time_bucket origin" {
    const parser = @import("../parser.zig");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser_inst = parser.Parser.init(arena.allocator(), "select pow(value, 2), time_bucket(60, time, 5) from metrics");
    const statement = try parser_inst.parse();
    const select = statement.select;

    try ensureRawRowScalarSupported(select.projections[0].expr);
    try ensureRawRowScalarSupported(select.projections[1].expr);
}
