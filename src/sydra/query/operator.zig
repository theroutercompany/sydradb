const std = @import("std");
const builtin = @import("builtin");

const physical = @import("physical.zig");
const plan = @import("plan.zig");
const ast = @import("ast.zig");
const types = @import("../types.zig");
const engine_mod = @import("../engine.zig");
const expression = @import("expression.zig");
const value_mod = @import("value.zig");

const ManagedArrayList = std.array_list.Managed;

pub const Value = value_mod.Value;

const empty_values = [_]Value{};

const QueryRangeError = @typeInfo(@typeInfo(@TypeOf(engine_mod.Engine.queryRange)).@"fn".return_type.?).error_union.error_set;

pub const ExecuteError = std.mem.Allocator.Error || expression.EvalError || QueryRangeError || error{
    UnsupportedPlan,
    UnsupportedAggregate,
};

pub const Row = struct {
    schema: []const plan.ColumnInfo,
    values: []Value,
};

pub const Operator = struct {
    allocator: std.mem.Allocator,
    schema: []const plan.ColumnInfo,
    payload: Payload,
    next_fn: *const fn (*Operator) ExecuteError!?Row,
    destroy_fn: *const fn (*Operator) void,
    stats: Stats,

    pub fn next(self: *Operator) ExecuteError!?Row {
        const start = std.time.microTimestamp();
        const result = self.next_fn(self);
        const elapsed = std.time.microTimestamp() - start;
        self.stats.elapsed_us += @as(u64, @intCast(elapsed));
        const maybe_row = result catch |err| return err;
        if (maybe_row) |_| {
            self.stats.rows_out += 1;
        }
        return maybe_row;
    }

    pub fn destroy(self: *Operator) void {
        self.destroy_fn(self);
        self.allocator.destroy(self);
    }

    const TestSource = struct {
        schema: []const plan.ColumnInfo,
        rows: []([]Value),
        index: usize,
    };

    const Payload = union(enum) {
        scan: Scan,
        one_row: OneRow,
        filter: Filter,
        project: Project,
        aggregate: Aggregate,
        sort: Sort,
        limit: Limit,
        test_source: TestSource,
    };

    pub const Stats = struct {
        name: []const u8,
        elapsed_us: u64 = 0,
        rows_out: u64 = 0,
    };

    pub const StatsSnapshot = struct {
        name: []const u8,
        elapsed_us: u64,
        rows_out: u64,
    };

    const Scan = struct {
        engine: *engine_mod.Engine,
        selector: ?ast.Selector,
        series_id: ?types.SeriesId,
        points: std.array_list.Managed(types.Point),
        index: usize,
        buffer: []Value,
    };

    const OneRow = struct {
        emitted: bool,
    };

    const Filter = struct {
        child: *Operator,
        predicate: *const ast.Expr,
    };

    const Project = struct {
        child: *Operator,
        buffer: []Value,
    };

    const Aggregate = struct {
        child: *Operator,
        group_exprs: []const ast.GroupExpr,
        aggregates: []AggregateExpr,
        column_meta: []ColumnMeta,
        groups: ManagedArrayList(GroupState),
        key_buffer: ManagedArrayList(Value),
        output_buffer: []Value,
        initialized: bool,
        index: usize,
    };

    const Sort = struct {
        rows: ManagedArrayList(OwnedRow),
        index: usize,
    };

    const Limit = struct {
        child: *Operator,
        offset: usize,
        remaining: usize,
    };

    const AggregateKind = enum { avg, sum, count };

    const AggregateExpr = struct {
        expr: *const ast.Expr,
        kind: AggregateKind,
        args: []const *const ast.Expr,
    };

    const ColumnKind = enum { group, aggregate };

    const ColumnMeta = struct {
        kind: ColumnKind,
        index: usize,
    };

    const AvgState = struct {
        total: f64,
        count: u64,
    };

    const AggregateState = union(enum) {
        avg: AvgState,
        sum: f64,
        count: u64,
    };

    const GroupState = struct {
        keys: []Value,
        aggregates: []AggregateState,
    };

    const OwnedRow = struct {
        values: []Value,
        keys: []Value,
    };

    pub fn collectStats(self: *Operator, list: *ManagedArrayList(Operator.StatsSnapshot)) !void {
        try list.append(.{
            .name = self.stats.name,
            .elapsed_us = self.stats.elapsed_us,
            .rows_out = self.stats.rows_out,
        });

        switch (self.payload) {
            .filter => |payload| try payload.child.collectStats(list),
            .project => |payload| try payload.child.collectStats(list),
            .aggregate => |payload| try payload.child.collectStats(list),
            .limit => |payload| try payload.child.collectStats(list),
            .scan,
            .one_row,
            .sort,
            .test_source,
            => {},
        }
    }
};

pub fn buildPipeline(allocator: std.mem.Allocator, engine: *engine_mod.Engine, node: *physical.Node) ExecuteError!*Operator {
    return switch (node.*) {
        .scan => |scan| try createScanOperator(allocator, engine, scan, physical.nodeOutput(node)),
        .one_row => |one_row| try createOneRowOperator(allocator, one_row.output),
        .filter => |filter| {
            const child = try buildPipeline(allocator, engine, filter.child);
            return try createFilterOperator(allocator, child, filter.predicate, physical.nodeOutput(node));
        },
        .project => |project| try buildProjectOperator(allocator, engine, project),
        .aggregate => |aggregate| {
            const child = try buildPipeline(allocator, engine, aggregate.child);
            return try createAggregateOperator(allocator, child, aggregate, physical.nodeOutput(node));
        },
        .sort => |sort| {
            const child = try buildPipeline(allocator, engine, sort.child);
            return try createSortOperator(allocator, child, physical.nodeOutput(node), sort.ordering, null);
        },
        .limit => |limit| {
            if (limit.child.* == .sort) {
                return try createSortLimitOperator(allocator, engine, limit.child, limit, physical.nodeOutput(node));
            }
            const child = try buildPipeline(allocator, engine, limit.child);
            return try createLimitOperator(allocator, child, physical.nodeOutput(node), limit.offset, limit.limit.limit);
        },
    };
}

fn createOperator(allocator: std.mem.Allocator, schema: []const plan.ColumnInfo, name: []const u8, next_fn: *const fn (*Operator) ExecuteError!?Row, destroy_fn: *const fn (*Operator) void, payload: Operator.Payload) !*Operator {
    const op = try allocator.create(Operator);
    op.* = .{
        .allocator = allocator,
        .schema = schema,
        .payload = payload,
        .next_fn = next_fn,
        .destroy_fn = destroy_fn,
        .stats = .{ .name = name },
    };
    return op;
}

fn createScanOperator(allocator: std.mem.Allocator, engine: *engine_mod.Engine, node: physical.Scan, schema: []const plan.ColumnInfo) ExecuteError!*Operator {
    if (node.selector == null) return error.UnsupportedPlan;

    var payload = Operator.Scan{
        .engine = engine,
        .selector = node.selector,
        .series_id = null,
        .points = std.array_list.Managed(types.Point).init(allocator),
        .index = 0,
        .buffer = try allocator.alloc(Value, schema.len),
    };

    for (payload.buffer) |*slot| slot.* = Value.null;

    const selector = node.selector.?;
    switch (selector.series) {
        .by_id => |id| payload.series_id = @as(types.SeriesId, @intCast(id.value)),
        .name => return error.UnsupportedPlan,
    }

    if (payload.series_id) |sid| {
        const bounds = node.time_bounds;
        const start_ts = bounds.min orelse std.math.minInt(i64);
        const end_ts = bounds.max orelse std.math.maxInt(i64);
        try payload.engine.queryRange(sid, start_ts, end_ts, &payload.points);
    }

    return try createOperator(allocator, schema, "scan", scanNext, scanDestroy, .{ .scan = payload });
}

fn scanNext(op: *Operator) ExecuteError!?Row {
    var payload = &op.payload.scan;
    if (payload.index >= payload.points.items.len) return null;
    const point = payload.points.items[payload.index];
    payload.index += 1;

    for (op.schema, 0..) |column, idx| {
        if (column.expr.* != .identifier) return error.UnsupportedPlan;
        const name = column.expr.identifier.value;
        if (namesEqual(name, "time")) {
            payload.buffer[idx] = Value{ .integer = point.ts };
        } else if (namesEqual(name, "value")) {
            payload.buffer[idx] = Value{ .float = point.value };
        } else {
            return error.UnsupportedPlan;
        }
    }

    return Row{ .schema = op.schema, .values = payload.buffer };
}

fn scanDestroy(op: *Operator) void {
    var payload = &op.payload.scan;
    payload.points.deinit();
    op.allocator.free(payload.buffer);
}

fn createOneRowOperator(allocator: std.mem.Allocator, schema: []const plan.ColumnInfo) ExecuteError!*Operator {
    const payload = Operator.OneRow{ .emitted = false };
    return try createOperator(allocator, schema, "one_row", oneRowNext, oneRowDestroy, .{ .one_row = payload });
}

fn oneRowNext(op: *Operator) ExecuteError!?Row {
    var payload = &op.payload.one_row;
    if (payload.emitted) return null;
    payload.emitted = true;
    return Row{ .schema = op.schema, .values = empty_values[0..] };
}

fn oneRowDestroy(op: *Operator) void {
    _ = op;
}

fn createFilterOperator(allocator: std.mem.Allocator, child: *Operator, predicate: *const ast.Expr, schema: []const plan.ColumnInfo) ExecuteError!*Operator {
    const payload = Operator.Filter{ .child = child, .predicate = predicate };
    return try createOperator(allocator, schema, "filter", filterNext, filterDestroy, .{ .filter = payload });
}

fn filterNext(op: *Operator) ExecuteError!?Row {
    var payload = &op.payload.filter;
    while (try payload.child.next()) |row| {
        var ctx = expression.RowContext{ .schema = row.schema, .values = row.values };
        const resolver = expression.rowResolver(&ctx);
        if (try expression.evaluateBoolean(payload.predicate, &resolver)) {
            return Row{ .schema = op.schema, .values = row.values };
        }
    }
    return null;
}

fn filterDestroy(op: *Operator) void {
    op.payload.filter.child.destroy();
}

fn buildProjectOperator(allocator: std.mem.Allocator, engine: *engine_mod.Engine, node: physical.Project) ExecuteError!*Operator {
    const child = try buildPipeline(allocator, engine, node.child);
    if (node.reuse_child_schema or schemasEqual(child.schema, node.columns)) {
        return child;
    }
    return try createProjectOperator(allocator, child, node.columns);
}

fn createProjectOperator(allocator: std.mem.Allocator, child: *Operator, columns: []const plan.ColumnInfo) ExecuteError!*Operator {
    const buffer = try allocator.alloc(Value, columns.len);
    for (buffer) |*slot| slot.* = Value.null;
    const payload = Operator.Project{ .child = child, .buffer = buffer };
    return try createOperator(allocator, columns, "project", projectNext, projectDestroy, .{ .project = payload });
}

fn projectNext(op: *Operator) ExecuteError!?Row {
    var payload = &op.payload.project;
    const maybe_child = try payload.child.next();
    if (maybe_child == null) return null;
    const child_row = maybe_child.?;

    var ctx = expression.RowContext{ .schema = child_row.schema, .values = child_row.values };
    const resolver = expression.rowResolver(&ctx);
    for (op.schema, 0..) |column, idx| {
        payload.buffer[idx] = try expression.evaluate(column.expr, &resolver);
    }

    return Row{ .schema = op.schema, .values = payload.buffer };
}

fn projectDestroy(op: *Operator) void {
    op.payload.project.child.destroy();
    op.allocator.free(op.payload.project.buffer);
}

fn createAggregateOperator(allocator: std.mem.Allocator, child: *Operator, node: physical.Aggregate, schema: []const plan.ColumnInfo) ExecuteError!*Operator {
    var aggregates = try analyseAggregates(allocator, node.output, node.groupings);
    defer aggregates.map.deinit();
    const column_meta = try buildColumnMeta(allocator, node.output, node.groupings, aggregates.exprs);
    errdefer allocator.free(column_meta);

    const payload = Operator.Aggregate{
        .child = child,
        .group_exprs = node.groupings,
        .aggregates = aggregates.exprs,
        .column_meta = column_meta,
        .groups = ManagedArrayList(Operator.GroupState).init(allocator),
        .key_buffer = ManagedArrayList(Value).init(allocator),
        .output_buffer = try allocator.alloc(Value, schema.len),
        .initialized = false,
        .index = 0,
    };

    for (payload.output_buffer) |*slot| slot.* = Value.null;

    return try createOperator(allocator, schema, "aggregate", aggregateNext, aggregateDestroy, .{ .aggregate = payload });
}

const AggregateAnalysis = struct {
    exprs: []Operator.AggregateExpr,
    map: std.AutoHashMap(*const ast.Expr, usize),
};

fn analyseAggregates(allocator: std.mem.Allocator, columns: []const plan.ColumnInfo, groupings: []const ast.GroupExpr) ExecuteError!AggregateAnalysis {
    _ = groupings;
    var exprs = ManagedArrayList(Operator.AggregateExpr).init(allocator);
    errdefer exprs.deinit();

    var map = std.AutoHashMap(*const ast.Expr, usize).init(allocator);
    errdefer map.deinit();

    for (columns) |column| {
        const expr = column.expr;
        if (expr.* != .call) continue;
        const call = expr.call;
        if (aggregateKindFor(call.callee.value)) |kind| {
            if (map.get(expr) != null) continue;
            const idx = exprs.items.len;
            try exprs.append(.{ .expr = expr, .kind = kind, .args = call.args });
            try map.put(expr, idx);
        }
    }

    return AggregateAnalysis{ .exprs = try exprs.toOwnedSlice(), .map = map };
}

fn buildColumnMeta(allocator: std.mem.Allocator, columns: []const plan.ColumnInfo, groupings: []const ast.GroupExpr, aggregates: []Operator.AggregateExpr) ExecuteError![]Operator.ColumnMeta {
    const meta = try allocator.alloc(Operator.ColumnMeta, columns.len);
    for (columns, 0..) |column, idx| {
        if (findGroupIndex(groupings, column.expr)) |group_idx| {
            meta[idx] = .{ .kind = .group, .index = group_idx };
            continue;
        }

        if (column.expr.* == .call) {
            const call_expr = column.expr;
            for (aggregates, 0..) |agg, agg_idx| {
                if (call_expr == agg.expr) {
                    meta[idx] = .{ .kind = .aggregate, .index = agg_idx };
                    break;
                }
            } else return error.UnsupportedAggregate;
            continue;
        }

        return error.UnsupportedAggregate;
    }
    return meta;
}

fn aggregateNext(op: *Operator) ExecuteError!?Row {
    var payload = &op.payload.aggregate;
    if (!payload.initialized) {
        try materializeGroups(op.allocator, payload, payload.child);
        payload.initialized = true;
    }

    if (payload.index >= payload.groups.items.len) return null;
    const group = payload.groups.items[payload.index];
    payload.index += 1;

    for (op.schema, 0..) |_, idx| {
        const meta = payload.column_meta[idx];
        payload.output_buffer[idx] = switch (meta.kind) {
            .group => group.keys[meta.index],
            .aggregate => finalizeState(group.aggregates[meta.index], payload.aggregates[meta.index].kind),
        };
    }

    return Row{ .schema = op.schema, .values = payload.output_buffer };
}

fn aggregateDestroy(op: *Operator) void {
    var payload = &op.payload.aggregate;
    payload.child.destroy();
    for (payload.groups.items) |group| {
        op.allocator.free(group.keys);
        op.allocator.free(group.aggregates);
    }
    payload.groups.deinit();
    payload.key_buffer.deinit();
    op.allocator.free(payload.output_buffer);
    op.allocator.free(payload.aggregates);
    op.allocator.free(payload.column_meta);
}

fn materializeGroups(allocator: std.mem.Allocator, payload: *Operator.Aggregate, child: *Operator) ExecuteError!void {
    while (try child.next()) |row| {
        var ctx = expression.RowContext{ .schema = row.schema, .values = row.values };
        const resolver = expression.rowResolver(&ctx);

        try payload.key_buffer.ensureTotalCapacity(payload.group_exprs.len);
        payload.key_buffer.items.len = payload.group_exprs.len;
        for (payload.group_exprs, 0..) |group_expr, idx| {
            payload.key_buffer.items[idx] = try expression.evaluate(group_expr.expr, &resolver);
        }

        const key_slice = payload.key_buffer.items;
        const group_state = try findOrCreateGroup(allocator, payload, key_slice);
        try updateAggregateStates(payload, &resolver, group_state);
    }
}

fn findOrCreateGroup(allocator: std.mem.Allocator, payload: *Operator.Aggregate, key_values: []const Value) ExecuteError!*Operator.GroupState {
    for (payload.groups.items) |*group| {
        if (valuesEqual(group.keys, key_values)) {
            return group;
        }
    }

    const key_copy = try Value.copySlice(allocator, key_values);
    const states = try allocator.alloc(Operator.AggregateState, payload.aggregates.len);
    for (payload.aggregates, 0..) |agg, idx| {
        states[idx] = initState(agg.kind);
    }

    try payload.groups.append(.{ .keys = key_copy, .aggregates = states });
    return &payload.groups.items[payload.groups.items.len - 1];
}

fn updateAggregateStates(payload: *Operator.Aggregate, resolver: *const expression.Resolver, group: *Operator.GroupState) ExecuteError!void {
    for (payload.aggregates, 0..) |agg, idx| {
        var maybe_value: ?Value = null;
        if (agg.args.len != 0) {
            maybe_value = try expression.evaluate(agg.args[0], resolver);
        }
        try updateState(&group.aggregates[idx], agg.kind, maybe_value);
    }
}

const LimitHint = struct {
    offset: usize,
    take: usize,
};

fn createSortOperator(
    allocator: std.mem.Allocator,
    child: *Operator,
    schema: []const plan.ColumnInfo,
    ordering: []const ast.OrderExpr,
    limit_hint: ?LimitHint,
) ExecuteError!*Operator {
    var rows = ManagedArrayList(Operator.OwnedRow).init(allocator);
    errdefer {
        for (rows.items) |owned| freeOwnedRow(allocator, owned);
        rows.deinit();
    }

    defer child.destroy();

    const capacity = if (limit_hint) |hint| hint.offset + hint.take else 0;
    while (try child.next()) |row| {
        const owned = try makeOwnedRow(allocator, schema, ordering, row);
        if (limit_hint) |hint| {
            if (hint.take == 0) {
                freeOwnedRow(allocator, owned);
                continue;
            }
            if (rows.items.len < capacity) {
                try rows.append(owned);
            } else {
                const worst_idx = findWorstIndex(rows.items, ordering);
                if (compareOwnedRows(ordering, owned, rows.items[worst_idx]) == .lt) {
                    freeOwnedRow(allocator, rows.items[worst_idx]);
                    rows.items[worst_idx] = owned;
                } else {
                    freeOwnedRow(allocator, owned);
                }
            }
        } else {
            try rows.append(owned);
        }
    }

    const sort_ctx = SortContext{ .ordering = ordering };
    std.sort.pdq(Operator.OwnedRow, rows.items, sort_ctx, SortContext.lessThan);

    if (limit_hint) |hint| {
        const start = @min(hint.offset, rows.items.len);
        for (rows.items[0..start]) |owned| {
            freeOwnedRow(allocator, owned);
        }
        const remaining = rows.items[start..];
        std.mem.copyForwards(Operator.OwnedRow, rows.items[0..remaining.len], remaining);
        rows.items.len = remaining.len;

        if (rows.items.len > hint.take) {
            for (rows.items[hint.take..]) |owned| {
                freeOwnedRow(allocator, owned);
            }
            rows.items.len = hint.take;
        }
    }

    return try createOperator(allocator, schema, "sort", sortNext, sortDestroy, .{ .sort = .{ .rows = rows, .index = 0 } });
}

fn createLimitOperator(
    allocator: std.mem.Allocator,
    child: *Operator,
    schema: []const plan.ColumnInfo,
    offset: usize,
    take: usize,
) ExecuteError!*Operator {
    const payload = Operator.Limit{ .child = child, .offset = offset, .remaining = take };
    return try createOperator(allocator, schema, "limit", limitNext, limitDestroy, .{ .limit = payload });
}

fn createSortLimitOperator(
    allocator: std.mem.Allocator,
    engine: *engine_mod.Engine,
    sort_node: *physical.Node,
    limit: physical.Limit,
    schema: []const plan.ColumnInfo,
) ExecuteError!*Operator {
    const sort_data = sort_node.sort;
    const child = try buildPipeline(allocator, engine, sort_data.child);
    const hint = LimitHint{ .offset = limit.offset, .take = limit.limit.limit };
    return try createSortOperator(allocator, child, schema, sort_data.ordering, hint);
}

fn sortNext(op: *Operator) ExecuteError!?Row {
    var payload = &op.payload.sort;
    if (payload.index >= payload.rows.items.len) return null;
    const row = payload.rows.items[payload.index];
    payload.index += 1;
    return Row{ .schema = op.schema, .values = row.values };
}

fn sortDestroy(op: *Operator) void {
    var payload = &op.payload.sort;
    for (payload.rows.items) |row| {
        freeOwnedRow(op.allocator, row);
    }
    payload.rows.deinit();
}

fn limitNext(op: *Operator) ExecuteError!?Row {
    var payload = &op.payload.limit;
    while (payload.offset > 0) {
        if ((try payload.child.next()) == null) return null;
        payload.offset -= 1;
    }
    if (payload.remaining == 0) return null;
    const maybe = try payload.child.next();
    if (maybe == null) return null;
    payload.remaining -= 1;
    return maybe;
}

fn limitDestroy(op: *Operator) void {
    op.payload.limit.child.destroy();
}

fn makeOwnedRow(
    allocator: std.mem.Allocator,
    schema: []const plan.ColumnInfo,
    ordering: []const ast.OrderExpr,
    row: Row,
) ExecuteError!Operator.OwnedRow {
    const copy = try Value.copySlice(allocator, row.values);
    errdefer allocator.free(copy);
    const keys = try computeOrderingKeys(allocator, schema, ordering, copy);
    return Operator.OwnedRow{ .values = copy, .keys = keys };
}

fn freeOwnedRow(allocator: std.mem.Allocator, owned: Operator.OwnedRow) void {
    allocator.free(owned.values);
    allocator.free(owned.keys);
}

fn computeOrderingKeys(
    allocator: std.mem.Allocator,
    schema: []const plan.ColumnInfo,
    ordering: []const ast.OrderExpr,
    values: []Value,
) ExecuteError![]Value {
    const keys = try allocator.alloc(Value, ordering.len);
    errdefer allocator.free(keys);
    var ctx = expression.RowContext{ .schema = schema, .values = values };
    const resolver = expression.rowResolver(&ctx);
    for (ordering, 0..) |order_expr, idx| {
        keys[idx] = try expression.evaluate(order_expr.expr, &resolver);
    }
    return keys;
}

const SortContext = struct {
    ordering: []const ast.OrderExpr,

    fn lessThan(ctx: SortContext, a: Operator.OwnedRow, b: Operator.OwnedRow) bool {
        return compareOwnedRows(ctx.ordering, a, b) == .lt;
    }
};

fn compareOwnedRows(ordering: []const ast.OrderExpr, a: Operator.OwnedRow, b: Operator.OwnedRow) std.math.Order {
    return compareKeyValues(ordering, a.keys, b.keys);
}

fn compareKeyValues(ordering: []const ast.OrderExpr, a_keys: []const Value, b_keys: []const Value) std.math.Order {
    if (ordering.len == 0) return .eq;
    for (ordering, 0..) |order_expr, idx| {
        const ord = compareValuesForSort(a_keys[idx], b_keys[idx]);
        if (ord == .eq) continue;
        return if (order_expr.direction == .desc) invertOrder(ord) else ord;
    }
    return .eq;
}

fn compareValuesForSort(a: Value, b: Value) std.math.Order {
    const tag_a = std.meta.activeTag(a);
    const tag_b = std.meta.activeTag(b);

    if (tag_a == .null and tag_b == .null) return .eq;
    if (tag_a == .null) return .lt;
    if (tag_b == .null) return .gt;

    if ((tag_a == .integer or tag_a == .float or tag_a == .boolean) and
        (tag_b == .integer or tag_b == .float or tag_b == .boolean))
    {
        const left = valueToFloat(a);
        const right = valueToFloat(b);
        if (left < right) return .lt;
        if (left > right) return .gt;
        return .eq;
    }

    if (tag_a == .string and tag_b == .string) {
        return if (std.mem.lessThan(u8, a.string, b.string))
            .lt
        else if (std.mem.lessThan(u8, b.string, a.string))
            .gt
        else
            .eq;
    }

    if (tag_a == .boolean and tag_b == .boolean) {
        if (a.boolean == b.boolean) return .eq;
        return if (!a.boolean and b.boolean) .lt else .gt;
    }

    return .eq;
}

fn valueToFloat(value: Value) f64 {
    return switch (value) {
        .integer => |i| @as(f64, @floatFromInt(i)),
        .float => |f| f,
        .boolean => |b| if (b) 1.0 else 0.0,
        else => 0,
    };
}

fn invertOrder(order: std.math.Order) std.math.Order {
    return switch (order) {
        .lt => .gt,
        .gt => .lt,
        .eq => .eq,
    };
}

fn findWorstIndex(rows: []Operator.OwnedRow, ordering: []const ast.OrderExpr) usize {
    var worst: usize = 0;
    for (rows, 1..) |row, idx| {
        if (compareOwnedRows(ordering, rows[worst], row) == .lt) {
            worst = idx;
        }
    }
    return worst;
}

fn aggregateKindFor(name: []const u8) ?Operator.AggregateKind {
    if (std.ascii.eqlIgnoreCase(name, "avg")) return .avg;
    if (std.ascii.eqlIgnoreCase(name, "sum")) return .sum;
    if (std.ascii.eqlIgnoreCase(name, "count")) return .count;
    return null;
}

fn initState(kind: Operator.AggregateKind) Operator.AggregateState {
    return switch (kind) {
        .avg => .{ .avg = .{ .total = 0, .count = 0 } },
        .sum => .{ .sum = 0 },
        .count => .{ .count = 0 },
    };
}

fn updateState(state: *Operator.AggregateState, kind: Operator.AggregateKind, maybe_value: ?Value) ExecuteError!void {
    switch (kind) {
        .avg => {
            if (maybe_value) |value| {
                const num = try value.asFloat();
                switch (state.*) {
                    .avg => |*avg_state| {
                        avg_state.total += num;
                        avg_state.count += 1;
                    },
                    else => unreachable,
                }
            }
        },
        .sum => {
            if (maybe_value) |value| {
                switch (state.*) {
                    .sum => |*sum_state| {
                        sum_state.* += try value.asFloat();
                    },
                    else => unreachable,
                }
            }
        },
        .count => {
            if (maybe_value) |value| {
                if (!value.isNull()) {
                    switch (state.*) {
                        .count => |*count_state| {
                            count_state.* += 1;
                        },
                        else => unreachable,
                    }
                }
            } else {
                switch (state.*) {
                    .count => |*count_state| {
                        count_state.* += 1;
                    },
                    else => unreachable,
                }
            }
        },
    }
}

fn finalizeState(state: Operator.AggregateState, kind: Operator.AggregateKind) Value {
    return switch (kind) {
        .avg => switch (state) {
            .avg => |avg_state| if (avg_state.count == 0) Value.null else Value{ .float = avg_state.total / @as(f64, @floatFromInt(avg_state.count)) },
            else => unreachable,
        },
        .sum => switch (state) {
            .sum => |sum_state| Value{ .float = sum_state },
            else => unreachable,
        },
        .count => switch (state) {
            .count => |count_state| Value{ .integer = @as(i64, @intCast(count_state)) },
            else => unreachable,
        },
    };
}

fn findGroupIndex(groupings: []const ast.GroupExpr, expr: *const ast.Expr) ?usize {
    for (groupings, 0..) |group_expr, idx| {
        if (expression.expressionsEqual(group_expr.expr, expr)) return idx;
    }
    return null;
}

fn schemasEqual(a: []const plan.ColumnInfo, b: []const plan.ColumnInfo) bool {
    if (a.ptr == b.ptr and a.len == b.len) return true;
    if (a.len != b.len) return false;
    for (a, b) |lhs, rhs| {
        if (!namesEqual(lhs.name, rhs.name)) return false;
        if (!expression.expressionsEqual(lhs.expr, rhs.expr)) return false;
    }
    return true;
}

fn valuesEqual(a: []const Value, b: []const Value) bool {
    if (a.len != b.len) return false;
    for (a, b) |lhs, rhs| {
        if (!Value.equals(lhs, rhs)) return false;
    }
    return true;
}

fn namesEqual(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn createTestSourceOperator(allocator: std.mem.Allocator, schema: []const plan.ColumnInfo, rows: []([]Value)) ExecuteError!*Operator {
    const payload = Operator.TestSource{ .schema = schema, .rows = rows, .index = 0 };
    return try createOperator(allocator, schema, "test_source", testSourceNext, testSourceDestroy, .{ .test_source = payload });
}

fn testSourceNext(op: *Operator) ExecuteError!?Row {
    var payload = &op.payload.test_source;
    if (payload.index >= payload.rows.len) return null;
    const values = payload.rows[payload.index];
    payload.index += 1;
    return Row{ .schema = payload.schema, .values = values };
}

fn testSourceDestroy(op: *Operator) void {
    _ = op;
}

test "aggregate avg without grouping" {
    const alloc = std.testing.allocator;
    const common = @import("common.zig");

    const time_name = try alloc.dupe(u8, "time");
    const value_name = try alloc.dupe(u8, "value");

    const base_span = common.Span.init(0, 0);

    const time_ident = ast.Identifier{ .value = time_name, .quoted = false, .span = base_span };
    const value_ident = ast.Identifier{ .value = value_name, .quoted = false, .span = base_span };

    const time_expr = try alloc.create(ast.Expr);
    time_expr.* = .{ .identifier = time_ident };
    const value_expr = try alloc.create(ast.Expr);
    value_expr.* = .{ .identifier = value_ident };

    const child_columns = try alloc.alloc(plan.ColumnInfo, 2);
    child_columns[0] = .{ .name = time_name, .expr = time_expr };
    child_columns[1] = .{ .name = value_name, .expr = value_expr };

    var row1 = try alloc.alloc(Value, 2);
    row1[0] = Value{ .integer = 0 };
    row1[1] = Value{ .float = 1.0 };
    var row2 = try alloc.alloc(Value, 2);
    row2[0] = Value{ .integer = 60 };
    row2[1] = Value{ .float = 3.0 };
    var row3 = try alloc.alloc(Value, 2);
    row3[0] = Value{ .integer = 120 };
    row3[1] = Value{ .float = 5.0 };

    const data = try alloc.alloc([]Value, 3);
    data[0] = row1;
    data[1] = row2;
    data[2] = row3;

    var child = try createTestSourceOperator(alloc, child_columns, data);
    var child_owned = false;
    defer if (!child_owned) child.destroy();

    const call_args = try alloc.alloc(*const ast.Expr, 1);
    call_args[0] = value_expr;

    const avg_callee = ast.Identifier{ .value = try alloc.dupe(u8, "avg"), .quoted = false, .span = base_span };
    const avg_call = ast.Call{ .callee = avg_callee, .args = call_args, .span = base_span };

    const avg_expr = try alloc.create(ast.Expr);
    avg_expr.* = .{ .call = avg_call };

    const agg_name = try alloc.dupe(u8, "avg_value");
    const agg_columns = try alloc.alloc(plan.ColumnInfo, 1);
    agg_columns[0] = .{ .name = agg_name, .expr = avg_expr };

    const aggregate_node = physical.Aggregate{
        .groupings = &[_]ast.GroupExpr{},
        .rollup_hint = null,
        .output = agg_columns,
        .child = undefined,
        .requires_hash = false,
        .has_fill_clause = false,
    };

    var agg_op = try createAggregateOperator(alloc, child, aggregate_node, agg_columns);
    child_owned = true;
    defer agg_op.destroy();

    const maybe_row = try agg_op.next();
    try std.testing.expect(maybe_row != null);
    const row = maybe_row.?;
    try std.testing.expectEqual(@as(usize, 1), row.values.len);
    const avg_value = row.values[0];
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), try avg_value.asFloat(), 1e-9);
    try std.testing.expect((try agg_op.next()) == null);

    alloc.destroy(time_expr);
    alloc.destroy(value_expr);
    alloc.destroy(avg_expr);
    alloc.free(call_args);
    alloc.free(child_columns);
    alloc.free(agg_columns);
    alloc.free(data);
    alloc.free(row1);
    alloc.free(row2);
    alloc.free(row3);
    alloc.free(time_name);
    alloc.free(value_name);
    alloc.free(@constCast(avg_callee.value));
    alloc.free(agg_name);
}

test "operator stats track rows" {
    const alloc = std.testing.allocator;
    const common = @import("common.zig");

    const value_name = try alloc.dupe(u8, "value");
    const base_span = common.Span.init(0, 0);

    const value_ident = ast.Identifier{ .value = value_name, .quoted = false, .span = base_span };
    const value_expr = try alloc.create(ast.Expr);
    value_expr.* = .{ .identifier = value_ident };

    const columns = try alloc.alloc(plan.ColumnInfo, 1);
    columns[0] = .{ .name = value_name, .expr = value_expr };

    var row1 = try alloc.alloc(Value, 1);
    row1[0] = Value{ .integer = 1 };
    var row2 = try alloc.alloc(Value, 1);
    row2[0] = Value{ .integer = 2 };

    const data = try alloc.alloc([]Value, 2);
    data[0] = row1;
    data[1] = row2;

    var source = try createTestSourceOperator(alloc, columns, data);
    var source_owned = false;
    defer if (!source_owned) source.destroy();

    var limit = try createLimitOperator(alloc, source, columns, 0, 10);
    source_owned = true;
    defer limit.destroy();

    while (try limit.next()) |_| {}

    var snapshots = ManagedArrayList(Operator.StatsSnapshot).init(alloc);
    defer snapshots.deinit();
    try limit.collectStats(&snapshots);

    try std.testing.expectEqual(@as(usize, 2), snapshots.items.len);
    try std.testing.expect(std.ascii.eqlIgnoreCase(snapshots.items[0].name, "limit"));
    try std.testing.expectEqual(@as(u64, 2), snapshots.items[0].rows_out);
    try std.testing.expect(std.ascii.eqlIgnoreCase(snapshots.items[1].name, "test_source"));
    try std.testing.expectEqual(@as(u64, 2), snapshots.items[1].rows_out);

    alloc.free(columns);
    alloc.free(data);
    alloc.free(row1);
    alloc.free(row2);
    alloc.destroy(value_expr);
    alloc.free(value_name);
}
