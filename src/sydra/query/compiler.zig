const std = @import("std");

const ast = @import("ast.zig");
const common = @import("common.zig");
const cfg_mod = @import("../config.zig");
const engine_mod = @import("../engine.zig");
const expression = @import("expression.zig");
const functions = @import("functions.zig");
const infer = @import("type_inference.zig");
const optimizer = @import("optimizer.zig");
const physical = @import("physical.zig");
const plan = @import("plan.zig");
const types = @import("../types.zig");

pub const ExecutionMode = cfg_mod.QueryCompilerMode;

pub const DeferredFeature = enum {
    insert,
    delete,
    explain,
    fill,
    tag_filter,
    rate_window,
    tag_selector_binding,
};

pub const BoundSelectorSource = enum {
    by_id,
    unique_name,
    exact_selector,
};

pub const BoundSelector = struct {
    source: BoundSelectorSource,
    series_id: types.SeriesId,
    name: ?[]const u8 = null,
    span: common.Span,
};

pub const TypedExpr = struct {
    expr: *const ast.Expr,
    ty: functions.Type,
    has_time: bool,
};

pub const TypedProjection = struct {
    expr: TypedExpr,
    name: []const u8,
    alias: ?ast.Identifier,
    is_grouping: bool,
    is_aggregate: bool,
};

pub const TypedGrouping = struct {
    expr: TypedExpr,
    is_time_bucket: bool,
};

pub const TypedOrdering = struct {
    expr: TypedExpr,
    direction: ast.OrderDirection,
};

pub const TimeBound = struct {
    value: i64,
    inclusive: bool,
};

pub const TimeRange = struct {
    start: ?TimeBound = null,
    end: ?TimeBound = null,
};

pub const AggregateKind = enum {
    avg,
    sum,
    count,
    min,
    max,
    percentile,
    rate,
    irate,
    delta,
    integral,
    first,
    last,
};

pub const AggregateSpec = struct {
    expr: *const ast.Expr,
    kind: AggregateKind,
    name: []const u8,
    args: []const TypedExpr,
    return_type: functions.Type,
};

pub const QueryProperties = struct {
    requires_sorted_input: bool = false,
    can_use_rollup: bool = false,
    materializes: bool = false,
};

pub const TypedQuery = struct {
    statement: *const ast.Statement,
    select: *const ast.Select,
    bound_selector: ?BoundSelector,
    predicate: ?TypedExpr,
    projections: []const TypedProjection,
    groupings: []const TypedGrouping,
    ordering: []const TypedOrdering,
    aggregates: []const AggregateSpec,
    time_range: TimeRange,
    properties: QueryProperties,
    deferred_features: []const DeferredFeature,
    is_aggregate_query: bool,
};

pub const BackendLoweringResult = struct {
    bound_statement: *const ast.Statement,
    logical_plan: *plan.Node,
    optimized_plan: *plan.Node,
    physical_plan: physical.PhysicalPlan,
    logical_us: u64,
    optimize_us: u64,
    physical_us: u64,
};

pub const CompiledSelect = struct {
    typed_query: TypedQuery,
    backend: BackendLoweringResult,
};

pub const CompileError = std.mem.Allocator.Error || functions.TypeCheckError || error{
    UnsupportedStatement,
    UnsupportedFill,
    UnsupportedTagFilter,
    UnsupportedGrouping,
    UnsupportedAggregate,
    UnsupportedProjection,
    UnsupportedOrdering,
    UnsupportedPredicate,
    UnsupportedExpression,
    UnsupportedFunction,
    SeriesNotFound,
    AmbiguousSelector,
};

pub fn canCompile(allocator: std.mem.Allocator, engine: *engine_mod.Engine, statement: *const ast.Statement) CompileError!bool {
    _ = compileTypedSelect(allocator, engine, statement) catch |err| switch (err) {
        error.UnsupportedStatement,
        error.UnsupportedFill,
        error.UnsupportedTagFilter,
        error.UnsupportedGrouping,
        error.UnsupportedAggregate,
        error.UnsupportedProjection,
        error.UnsupportedOrdering,
        error.UnsupportedPredicate,
        error.UnsupportedExpression,
        error.UnsupportedFunction,
        error.SeriesNotFound,
        error.AmbiguousSelector,
        => return false,
        else => return err,
    };
    return true;
}

pub fn compileSelect(allocator: std.mem.Allocator, engine: *engine_mod.Engine, statement: *const ast.Statement) CompileError!CompiledSelect {
    const typed_query = try compileTypedSelect(allocator, engine, statement);
    const backend = try lowerToBackend(allocator, &typed_query);
    return .{ .typed_query = typed_query, .backend = backend };
}

pub fn lowerToBackend(allocator: std.mem.Allocator, typed_query: *const TypedQuery) CompileError!BackendLoweringResult {
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
        .bound_statement = bound_statement,
        .logical_plan = logical_plan,
        .optimized_plan = optimized_plan,
        .physical_plan = physical_plan,
        .logical_us = durationMicros(logical_end - logical_start),
        .optimize_us = durationMicros(optimize_end - optimize_start),
        .physical_us = durationMicros(physical_end - physical_start),
    };
}

fn compileTypedSelect(allocator: std.mem.Allocator, engine: *engine_mod.Engine, statement: *const ast.Statement) CompileError!TypedQuery {
    if (statement.* != .select) return error.UnsupportedStatement;
    const select = statement.select;
    if (select.fill != null) return error.UnsupportedFill;
    if (select.selector != null and select.selector.?.tag_filter != null) return error.UnsupportedTagFilter;

    const deferred_features = &[_]DeferredFeature{};
    const bound_selector = try bindSelector(engine, select.selector);
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

fn bindSelector(engine: *engine_mod.Engine, selector: ?ast.Selector) CompileError!?BoundSelector {
    if (selector == null) return null;
    return switch (selector.?.series) {
        .by_id => |by_id| BoundSelector{
            .source = .by_id,
            .series_id = @intCast(by_id.value),
            .name = null,
            .span = by_id.span,
        },
        .name => |ident| switch (engine.resolveUniqueSeriesName(ident.value)) {
            .resolved => |series_id| BoundSelector{
                .source = .unique_name,
                .series_id = series_id,
                .name = ident.value,
                .span = ident.span,
            },
            .not_found => error.SeriesNotFound,
            .ambiguous => error.AmbiguousSelector,
        },
    };
}

fn buildTypedGroupings(allocator: std.mem.Allocator, groupings: []const ast.GroupExpr) CompileError![]const TypedGrouping {
    if (groupings.len == 0) return &[_]TypedGrouping{};
    if (groupings.len != 1) return error.UnsupportedGrouping;

    const typed = try typeCheckedExpr(allocator, groupings[0].expr);
    if (!isTimeBucketExpr(groupings[0].expr)) return error.UnsupportedGrouping;
    try ensureTimeBucketSupported(groupings[0].expr);

    const list = try allocator.alloc(TypedGrouping, 1);
    list[0] = .{
        .expr = typed,
        .is_time_bucket = true,
    };
    return list;
}

fn buildAggregateSpecs(allocator: std.mem.Allocator, projections: []const ast.Projection) CompileError![]const AggregateSpec {
    var count: usize = 0;
    for (projections) |projection| {
        if (projection.expr.* == .call) {
            const call = projection.expr.call;
            if (functions.lookup(call.callee.value)) |signature| {
                if (signature.kind == .aggregate) count += 1;
            }
        }
    }

    if (count == 0) return &[_]AggregateSpec{};

    const specs = try allocator.alloc(AggregateSpec, count);
    var index: usize = 0;
    for (projections) |projection| {
        if (projection.expr.* != .call) continue;
        const call = projection.expr.call;
        const signature = functions.lookup(call.callee.value) orelse continue;
        if (signature.kind != .aggregate) continue;

        const aggregate_kind = classifyAggregate(call.callee.value) orelse return error.UnsupportedAggregate;
        const arg_exprs = try allocator.alloc(TypedExpr, call.args.len);
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

fn buildTypedProjections(
    allocator: std.mem.Allocator,
    projections: []const ast.Projection,
    groupings: []const TypedGrouping,
    aggregates: []const AggregateSpec,
    has_selector: bool,
) CompileError![]const TypedProjection {
    if (projections.len == 0) return &[_]TypedProjection{};

    const typed = try allocator.alloc(TypedProjection, projections.len);
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

fn buildTypedOrderings(
    allocator: std.mem.Allocator,
    ordering: []const ast.OrderExpr,
    projections: []const TypedProjection,
) CompileError![]const TypedOrdering {
    if (ordering.len == 0) return &[_]TypedOrdering{};

    const out = try allocator.alloc(TypedOrdering, ordering.len);
    for (ordering, 0..) |order_expr, idx| {
        if (order_expr.expr.* != .identifier) return error.UnsupportedOrdering;
        try ensureOrderIdentifier(order_expr.expr.identifier, projections);
        out[idx] = .{
            .expr = try typeCheckedExpr(allocator, order_expr.expr),
            .direction = order_expr.direction,
        };
    }
    return out;
}

fn deriveProperties(
    select: *const ast.Select,
    groupings: []const TypedGrouping,
    aggregates: []const AggregateSpec,
    ordering: []const TypedOrdering,
) QueryProperties {
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
    };
}

fn typeCheckedExpr(allocator: std.mem.Allocator, expr: *const ast.Expr) CompileError!TypedExpr {
    const info = try infer.inferExpression(allocator, expr);
    return .{
        .expr = expr,
        .ty = info.ty,
        .has_time = info.has_time,
    };
}

fn inferProjectionName(allocator: std.mem.Allocator, projection: ast.Projection, index: usize) ![]const u8 {
    if (projection.alias) |alias| {
        return allocator.dupe(u8, alias.value);
    }
    return switch (projection.expr.*) {
        .identifier => |ident| allocator.dupe(u8, ident.value),
        .call => |call| std.fmt.allocPrint(allocator, "{s}_{d}", .{ call.callee.value, index }),
        else => std.fmt.allocPrint(allocator, "_col{d}", .{index}),
    };
}

fn ensurePredicateSupported(expr: *const ast.Expr) CompileError!void {
    try ensureRawRowScalarSupported(expr);
}

fn ensureConstantOnlySupported(expr: *const ast.Expr) CompileError!void {
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

fn ensureRawRowScalarSupported(expr: *const ast.Expr) CompileError!void {
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
            if (std.ascii.eqlIgnoreCase(call.callee.value, "abs")) {
                if (call.args.len != 1) return error.UnsupportedFunction;
                try ensureRawRowScalarSupported(call.args[0]);
                return;
            }
            if (std.ascii.eqlIgnoreCase(call.callee.value, "time_bucket")) {
                try ensureTimeBucketSupported(expr);
                return;
            }
            return error.UnsupportedFunction;
        },
    }
}

fn ensureTimeBucketSupported(expr: *const ast.Expr) CompileError!void {
    if (expr.* != .call) return error.UnsupportedFunction;
    const call = expr.call;
    if (!std.ascii.eqlIgnoreCase(call.callee.value, "time_bucket")) return error.UnsupportedFunction;
    if (call.args.len != 2 and call.args.len != 3) return error.UnsupportedFunction;
    if (call.args[0].* == .identifier) return error.UnsupportedFunction;
    if (!infer.expressionHasTime(call.args[1])) return error.UnsupportedFunction;
    for (call.args, 0..) |arg, idx| {
        if (idx == 1) {
            try ensureRawRowScalarSupported(arg);
        } else if (idx == 0) {
            try ensureConstantOnlySupported(arg);
        } else {
            try ensureConstantOnlySupported(arg);
        }
    }
}

fn ensureBinaryOpSupported(op: ast.BinaryOp) CompileError!void {
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

fn ensureOrderIdentifier(order_ident: ast.Identifier, projections: []const TypedProjection) CompileError!void {
    for (projections) |projection| {
        if (std.ascii.eqlIgnoreCase(projection.name, order_ident.value)) return;
    }
    return error.UnsupportedOrdering;
}

fn identifierAllowedInRawRow(name: []const u8) bool {
    const segment = trailingSegment(name);
    return std.ascii.eqlIgnoreCase(segment, "time") or std.ascii.eqlIgnoreCase(segment, "value");
}

fn matchesGrouping(expr: *const ast.Expr, groupings: []const TypedGrouping) bool {
    for (groupings) |grouping| {
        if (expression.expressionsEqual(expr, grouping.expr.expr)) return true;
    }
    return false;
}

fn matchesAggregate(expr: *const ast.Expr, aggregates: []const AggregateSpec) bool {
    for (aggregates) |aggregate| {
        if (expression.expressionsEqual(expr, aggregate.expr)) return true;
    }
    return false;
}

fn classifyAggregate(name: []const u8) ?AggregateKind {
    if (std.ascii.eqlIgnoreCase(name, "avg")) return .avg;
    if (std.ascii.eqlIgnoreCase(name, "sum")) return .sum;
    if (std.ascii.eqlIgnoreCase(name, "count")) return .count;
    return null;
}

fn isTimeBucketExpr(expr: *const ast.Expr) bool {
    if (expr.* != .call) return false;
    return std.ascii.eqlIgnoreCase(expr.call.callee.value, "time_bucket");
}

fn extractTimeRange(predicate: ?*const ast.Expr) TimeRange {
    if (predicate == null) return .{};
    return timeRangeFromExpr(predicate.?);
}

fn timeRangeFromExpr(expr: *const ast.Expr) TimeRange {
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

            var range = TimeRange{};
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

fn mergeTimeRanges(lhs: TimeRange, rhs: TimeRange) TimeRange {
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

fn durationMicros(value: i64) u64 {
    return @intCast(@max(value, 0));
}

test "can compile constant select" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/compiler-constant", .{tmp.sub_path});
    defer alloc.free(data_path);

    const config = try testConfig(alloc, data_path);
    var engine = try engine_mod.Engine.init(alloc, config);
    defer engine.deinit();

    var parser_inst = @import("parser.zig").Parser.init(arena.allocator(), "select 1");
    var statement = try parser_inst.parse();

    try std.testing.expect(try canCompile(arena.allocator(), engine, &statement));
}

test "compiler binds unique series names and lowers to backend" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/compiler-bind", .{tmp.sub_path});
    defer alloc.free(data_path);

    const config = try testConfig(alloc, data_path);
    var engine = try engine_mod.Engine.init(alloc, config);
    defer engine.deinit();

    try engine.registerSeries("weather.room1", "{}", 99);

    var parser_inst = @import("parser.zig").Parser.init(arena.allocator(), "select time, value from weather.room1 where time >= 0 order by time limit 5");
    var statement = try parser_inst.parse();
    const compiled = try compileSelect(arena.allocator(), engine, &statement);

    try std.testing.expect(compiled.typed_query.bound_selector != null);
    try std.testing.expectEqual(@as(types.SeriesId, 99), compiled.typed_query.bound_selector.?.series_id);
    try std.testing.expect(compiled.backend.physical_plan.root.* == .limit);
}

test "compiler rejects ambiguous series names" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/compiler-ambiguous", .{tmp.sub_path});
    defer alloc.free(data_path);

    const config = try testConfig(alloc, data_path);
    var engine = try engine_mod.Engine.init(alloc, config);
    defer engine.deinit();

    try engine.registerSeries("weather.room1", "{\"host\":\"a\"}", 100);
    try engine.registerSeries("weather.room1", "{\"host\":\"b\"}", 101);

    var parser_inst = @import("parser.zig").Parser.init(arena.allocator(), "select value from weather.room1 where time >= 0");
    var statement = try parser_inst.parse();

    try std.testing.expectError(error.AmbiguousSelector, compileSelect(arena.allocator(), engine, &statement));
}

fn testConfig(alloc: std.mem.Allocator, data_path: []const u8) !cfg_mod.Config {
    return .{
        .data_dir = try alloc.dupe(u8, data_path),
        .http_port = 0,
        .fsync = .none,
        .flush_interval_ms = 5,
        .memtable_max_bytes = 1024,
        .retention_days = 0,
        .auth_token = try alloc.dupe(u8, ""),
        .enable_influx = false,
        .enable_prom = false,
        .mem_limit_bytes = 1024 * 1024,
        .cas_mode = .off,
        .query_compiler_mode = .legacy,
        .retention_ns = std.StringHashMap(u32).init(alloc),
    };
}
