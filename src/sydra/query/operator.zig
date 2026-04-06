const std = @import("std");
const builtin = @import("builtin");

const physical = @import("physical.zig");
const plan = @import("plan.zig");
const ast = @import("ast.zig");
const types = @import("../types.zig");
const engine_mod = @import("../engine.zig");
const metric_catalog_mod = @import("../storage/metric_catalog.zig");
const expression = @import("expression.zig");
const value_mod = @import("value.zig");

const ManagedArrayList = std.array_list.Managed;

pub const Value = value_mod.Value;

const empty_values = [_]Value{};

const QueryRangeError = @typeInfo(@typeInfo(@TypeOf(engine_mod.Engine.queryRange)).@"fn".return_type.?).error_union.error_set;

pub const ExecuteError = std.mem.Allocator.Error || expression.EvalError || QueryRangeError || error{
    UnsupportedPlan,
    UnsupportedAggregate,
    UnsupportedFill,
    AmbiguousMetricFamilyQuery,
};

pub const Row = struct {
    schema: []const plan.ColumnInfo,
    values: []Value,
    tags: []const expression.TagField = &.{},
    series_id: ?types.SeriesId = null,
    ts: ?i64 = null,
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

    pub const SelectorStats = struct {
        mode: []const u8,
        selected_series_count: u64,
    };

    const Scan = struct {
        engine: *engine_mod.Engine,
        series: []ScanSeries,
        series_index: usize,
        buffer: []Value,
        selector_mode: []const u8,
        selected_series_count: u64,
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
        fill: ?ast.FillClause,
        metric_kind: metric_catalog_mod.MetricKind,
        initialized: bool,
        index: usize,
    };

    const Sort = struct {
        rows: ManagedArrayList(OwnedRow),
        index: usize,
        selector_stats: ?SelectorStats = null,
    };

    const Limit = struct {
        child: *Operator,
        offset: usize,
        remaining: usize,
    };

    const AggregateKind = enum { avg, sum, count, min, max, first, last, percentile, delta, rate, irate };

    const AggregateExpr = struct {
        expr: *const ast.Expr,
        kind: AggregateKind,
        args: []const *const ast.Expr,
        quantile: f64 = 0,
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

    const PercentileState = struct {
        values: ManagedArrayList(f64),
        quantile: f64,
    };

    const SeriesDerivativeState = struct {
        series_id: types.SeriesId,
        first_ts: i64,
        last_ts: i64,
        first_value: f64,
        last_value: f64,
        reset_accum: f64 = 0,
        last_step_delta: ?f64 = null,
        last_step_dt: ?i64 = null,
    };

    const DerivativeState = struct {
        series: ManagedArrayList(SeriesDerivativeState),
        metric_kind: metric_catalog_mod.MetricKind,
    };

    const AggregateState = union(enum) {
        avg: AvgState,
        sum: f64,
        count: u64,
        min: OptionalValue,
        max: OptionalValue,
        first: OptionalValue,
        last: OptionalValue,
        percentile: PercentileState,
        delta: DerivativeState,
        rate: DerivativeState,
        irate: DerivativeState,
        filled: Value,
    };

    const OptionalValue = struct {
        seen: bool = false,
        value: Value = Value.null,
    };

    const GroupState = struct {
        keys: []Value,
        aggregates: []AggregateState,
    };

    const OwnedRow = struct {
        values: []Value,
        keys: []Value,
        tags: []const expression.TagField = &.{},
        series_id: ?types.SeriesId = null,
        ts: ?i64 = null,
    };

    const ScanSeries = struct {
        series_id: types.SeriesId,
        points: std.array_list.Managed(types.Point),
        tags: []expression.TagField,
        index: usize = 0,
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

    pub fn selectorStats(self: *Operator) ?SelectorStats {
        return switch (self.payload) {
            .scan => |payload| .{
                .mode = payload.selector_mode,
                .selected_series_count = payload.selected_series_count,
            },
            .filter => |payload| payload.child.selectorStats(),
            .project => |payload| payload.child.selectorStats(),
            .aggregate => |payload| payload.child.selectorStats(),
            .limit => |payload| payload.child.selectorStats(),
            .sort => |payload| payload.selector_stats,
            .one_row,
            .test_source,
            => null,
        };
    }
};

pub fn buildPipeline(allocator: std.mem.Allocator, engine: *engine_mod.Engine, node: *physical.Node) ExecuteError!*Operator {
    return switch (node.*) {
        .scan => |scan| try createScanOperator(allocator, engine, scan, physical.nodeOutput(node)),
        .one_row => |one_row| try createOneRowOperator(allocator, one_row.output),
        .filter => |filter| {
            const child = try buildPipeline(allocator, engine, filter.child);
            errdefer child.destroy();
            return try createFilterOperator(allocator, child, filter.predicate, physical.nodeOutput(node));
        },
        .project => |project| try buildProjectOperator(allocator, engine, project),
        .aggregate => |aggregate| {
            const child = try buildPipeline(allocator, engine, aggregate.child);
            errdefer child.destroy();
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
            errdefer child.destroy();
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
        .series = try allocator.alloc(Operator.ScanSeries, 0),
        .series_index = 0,
        .buffer = try allocator.alloc(Value, schema.len),
        .selector_mode = "exact",
        .selected_series_count = 0,
    };
    errdefer allocator.free(payload.series);
    errdefer allocator.free(payload.buffer);

    for (payload.buffer) |*slot| slot.* = Value.null;

    const selector = node.selector.?;
    switch (selector) {
        .ast => |ast_selector| switch (ast_selector.series) {
            .by_id => |id| try appendScanSeries(allocator, &payload, engine, @as(types.SeriesId, @intCast(id.value)), null, node.time_bounds),
            .name => |ident| {
                const resolution = engine.resolveSelector(.{ .name = ident.value }) catch return error.UnsupportedPlan;
                switch (resolution.status) {
                    .resolved, .exact_match => try appendScanSeries(allocator, &payload, engine, resolution.series_id.?, resolution.canonical_tags, node.time_bounds),
                    .ambiguous => {
                        payload.selector_mode = "metric_family";
                        try appendMetricFamilySeries(allocator, &payload, engine, ident.value, node.label_constraints, node.time_bounds);
                    },
                    .not_found => {},
                }
            },
        },
        .bound => |bound_selector| try appendScanSeries(allocator, &payload, engine, bound_selector.series_id, bound_selector.canonical_tags, node.time_bounds),
    }

    payload.selected_series_count = @intCast(payload.series.len);
    if (node.require_exact_series and payload.selected_series_count > 1) {
        return error.AmbiguousMetricFamilyQuery;
    }

    return try createOperator(allocator, schema, "scan", scanNext, scanDestroy, .{ .scan = payload });
}

fn scanNext(op: *Operator) ExecuteError!?Row {
    const payload = &op.payload.scan;
    while (payload.series_index < payload.series.len) {
        var current = &payload.series[payload.series_index];
        if (current.index >= current.points.items.len) {
            payload.series_index += 1;
            continue;
        }
        const point = current.points.items[current.index];
        current.index += 1;

        for (op.schema, 0..) |column, idx| {
            if (column.expr.* != .identifier) return error.UnsupportedPlan;
            const name = column.expr.identifier.value;
            if (namesEqual(name, "time")) {
                payload.buffer[idx] = Value{ .integer = point.ts };
            } else if (namesEqual(name, "value")) {
                payload.buffer[idx] = Value{ .float = point.value };
            } else if (hasTagLikePrefix(name)) {
                payload.buffer[idx] = findTagValue(current.tags, tagKey(name));
            } else {
                return error.UnsupportedPlan;
            }
        }

        return Row{
            .schema = op.schema,
            .values = payload.buffer,
            .tags = current.tags,
            .series_id = current.series_id,
            .ts = point.ts,
        };
    }
    return null;
}

fn scanDestroy(op: *Operator) void {
    const payload = &op.payload.scan;
    for (payload.series) |scan_series| {
        scan_series.points.deinit();
        for (scan_series.tags) |tag| {
            op.allocator.free(tag.key);
            op.allocator.free(tag.value);
        }
        op.allocator.free(scan_series.tags);
    }
    op.allocator.free(payload.series);
    op.allocator.free(payload.buffer);
}

fn appendScanSeries(
    allocator: std.mem.Allocator,
    payload: *Operator.Scan,
    engine: *engine_mod.Engine,
    series_id: types.SeriesId,
    canonical_tags: ?[]const u8,
    bounds: physical.TimeBounds,
) ExecuteError!void {
    var points = std.array_list.Managed(types.Point).init(allocator);
    errdefer points.deinit();
    const start_ts = bounds.min orelse std.math.minInt(i64);
    const end_ts = bounds.max orelse std.math.maxInt(i64);
    try engine.queryRange(series_id, start_ts, end_ts, &points);

    const tags_json = canonical_tags orelse blk: {
        const resolution = engine.resolveSelector(.{ .by_id = series_id }) catch break :blk null;
        break :blk resolution.canonical_tags;
    };
    const tag_fields = try parseTagFields(allocator, tags_json orelse "{}");
    errdefer freeTagFields(allocator, tag_fields);

    const next = try allocator.realloc(payload.series, payload.series.len + 1);
    payload.series = next;
    payload.series[payload.series.len - 1] = .{
        .series_id = series_id,
        .points = points,
        .tags = tag_fields,
    };
}

fn appendMetricFamilySeries(
    allocator: std.mem.Allocator,
    payload: *Operator.Scan,
    engine: *engine_mod.Engine,
    metric: []const u8,
    constraints: []const physical.LabelConstraint,
    bounds: physical.TimeBounds,
) ExecuteError!void {
    const descriptors = try engine.seriesDescriptorsForMetric(allocator, metric, null, true, null);
    defer allocator.free(descriptors);
    for (descriptors) |descriptor| {
        if (!descriptorSatisfiesConstraints(descriptor.labels_json, constraints)) continue;
        try appendScanSeries(allocator, payload, engine, descriptor.series_id, descriptor.labels_json, bounds);
    }
}

fn parseTagFields(allocator: std.mem.Allocator, tags_json: []const u8) ExecuteError![]expression.TagField {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, tags_json, .{}) catch return allocator.alloc(expression.TagField, 0);
    defer parsed.deinit();
    if (parsed.value != .object) return try allocator.alloc(expression.TagField, 0);

    var fields = std.array_list.Managed(expression.TagField).init(allocator);
    errdefer {
        for (fields.items) |field| {
            allocator.free(field.key);
            allocator.free(field.value);
        }
        fields.deinit();
    }
    var it = parsed.value.object.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .string) continue;
        try fields.append(.{
            .key = try allocator.dupe(u8, entry.key_ptr.*),
            .value = try allocator.dupe(u8, entry.value_ptr.string),
        });
    }
    return try fields.toOwnedSlice();
}

fn descriptorSatisfiesConstraints(labels_json: []const u8, constraints: []const physical.LabelConstraint) bool {
    if (constraints.len == 0) return true;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), labels_json, .{}) catch return false;
    if (parsed.value != .object) return false;
    for (constraints) |constraint| {
        const actual = parsed.value.object.get(constraint.key) orelse return false;
        if (actual != .string or !std.mem.eql(u8, actual.string, constraint.value)) return false;
    }
    return true;
}

fn freeTagFields(allocator: std.mem.Allocator, fields: []expression.TagField) void {
    for (fields) |field| {
        allocator.free(field.key);
        allocator.free(field.value);
    }
    allocator.free(fields);
}

fn findTagValue(fields: []const expression.TagField, key: []const u8) Value {
    for (fields) |field| {
        if (namesEqual(field.key, key)) return .{ .string = field.value };
    }
    return Value.null;
}

fn createOneRowOperator(allocator: std.mem.Allocator, schema: []const plan.ColumnInfo) ExecuteError!*Operator {
    const payload = Operator.OneRow{ .emitted = false };
    return try createOperator(allocator, schema, "one_row", oneRowNext, oneRowDestroy, .{ .one_row = payload });
}

fn oneRowNext(op: *Operator) ExecuteError!?Row {
    var payload = &op.payload.one_row;
    if (payload.emitted) return null;
    payload.emitted = true;
    return Row{ .schema = op.schema, .values = empty_values[0..], .tags = &.{}, .series_id = null, .ts = null };
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
        var ctx = expression.RowContext{ .schema = row.schema, .values = row.values, .tags = row.tags };
        const resolver = expression.rowResolver(&ctx);
        if (try expression.evaluateBoolean(payload.predicate, &resolver)) {
            return Row{ .schema = op.schema, .values = row.values, .tags = row.tags, .series_id = row.series_id, .ts = row.ts };
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
    errdefer child.destroy();
    return try createProjectOperator(allocator, child, node.columns);
}

fn createProjectOperator(allocator: std.mem.Allocator, child: *Operator, columns: []const plan.ColumnInfo) ExecuteError!*Operator {
    const buffer = try allocator.alloc(Value, columns.len);
    errdefer allocator.free(buffer);
    for (buffer) |*slot| slot.* = Value.null;
    const payload = Operator.Project{ .child = child, .buffer = buffer };
    return try createOperator(allocator, columns, "project", projectNext, projectDestroy, .{ .project = payload });
}

fn projectNext(op: *Operator) ExecuteError!?Row {
    var payload = &op.payload.project;
    const maybe_child = try payload.child.next();
    if (maybe_child == null) return null;
    const child_row = maybe_child.?;

    var ctx = expression.RowContext{ .schema = child_row.schema, .values = child_row.values, .tags = child_row.tags };
    const resolver = expression.rowResolver(&ctx);
    for (op.schema, 0..) |column, idx| {
        payload.buffer[idx] = try expression.evaluate(column.expr, &resolver);
    }

    return Row{ .schema = op.schema, .values = payload.buffer, .tags = child_row.tags, .series_id = child_row.series_id, .ts = child_row.ts };
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
        .fill = node.fill,
        .metric_kind = inferMetricKind(child),
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
            try exprs.append(.{
                .expr = expr,
                .kind = kind,
                .args = call.args,
                .quantile = try aggregateQuantile(call),
            });
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
        for (group.aggregates) |state| deinitAggregateState(op.allocator, state);
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
        var ctx = expression.RowContext{ .schema = row.schema, .values = row.values, .tags = row.tags };
        const resolver = expression.rowResolver(&ctx);

        try payload.key_buffer.ensureTotalCapacity(payload.group_exprs.len);
        payload.key_buffer.items.len = payload.group_exprs.len;
        for (payload.group_exprs, 0..) |group_expr, idx| {
            payload.key_buffer.items[idx] = try expression.evaluate(group_expr.expr, &resolver);
        }

        const key_slice = payload.key_buffer.items;
        const group_state = try findOrCreateGroup(allocator, payload, key_slice);
        try updateAggregateStates(payload, &resolver, group_state, row.series_id, row.ts);
    }
    if (payload.fill != null) try applyFill(allocator, payload);
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
        states[idx] = initState(allocator, agg);
    }

    try payload.groups.append(.{ .keys = key_copy, .aggregates = states });
    return &payload.groups.items[payload.groups.items.len - 1];
}

fn updateAggregateStates(
    payload: *Operator.Aggregate,
    resolver: *const expression.Resolver,
    group: *Operator.GroupState,
    series_id: ?types.SeriesId,
    ts: ?i64,
) ExecuteError!void {
    for (payload.aggregates, 0..) |agg, idx| {
        var maybe_value: ?Value = null;
        if (agg.args.len != 0) {
            maybe_value = try expression.evaluate(agg.args[0], resolver);
        }
        try updateState(&group.aggregates[idx], agg, maybe_value, payload.metric_kind, series_id, ts);
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

    const child_selector_stats = child.selectorStats();
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

    return try createOperator(allocator, schema, "sort", sortNext, sortDestroy, .{ .sort = .{ .rows = rows, .index = 0, .selector_stats = child_selector_stats } });
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
    return Row{ .schema = op.schema, .values = row.values, .tags = row.tags, .series_id = row.series_id, .ts = row.ts };
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
    const keys = try computeOrderingKeys(allocator, schema, ordering, copy, row.tags);
    return Operator.OwnedRow{ .values = copy, .keys = keys, .tags = row.tags, .series_id = row.series_id, .ts = row.ts };
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
    tags: []const expression.TagField,
) ExecuteError![]Value {
    const keys = try allocator.alloc(Value, ordering.len);
    errdefer allocator.free(keys);
    var ctx = expression.RowContext{ .schema = schema, .values = values, .tags = tags };
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
    if (std.ascii.eqlIgnoreCase(name, "min")) return .min;
    if (std.ascii.eqlIgnoreCase(name, "max")) return .max;
    if (std.ascii.eqlIgnoreCase(name, "first")) return .first;
    if (std.ascii.eqlIgnoreCase(name, "last")) return .last;
    if (std.ascii.eqlIgnoreCase(name, "percentile")) return .percentile;
    if (std.ascii.eqlIgnoreCase(name, "delta")) return .delta;
    if (std.ascii.eqlIgnoreCase(name, "rate")) return .rate;
    if (std.ascii.eqlIgnoreCase(name, "irate")) return .irate;
    return null;
}

fn aggregateQuantile(call: ast.Call) ExecuteError!f64 {
    if (!std.ascii.eqlIgnoreCase(call.callee.value, "percentile")) return 0;
    if (call.args.len < 2) return error.UnsupportedAggregate;
    const quantile = try (try expression.evaluateConstant(call.args[1])).asFloat();
    if (quantile < 0 or quantile > 1) return error.UnsupportedAggregate;
    return quantile;
}

fn initState(allocator: std.mem.Allocator, aggregate: Operator.AggregateExpr) Operator.AggregateState {
    return switch (aggregate.kind) {
        .avg => .{ .avg = .{ .total = 0, .count = 0 } },
        .sum => .{ .sum = 0 },
        .count => .{ .count = 0 },
        .min => .{ .min = .{} },
        .max => .{ .max = .{} },
        .first => .{ .first = .{} },
        .last => .{ .last = .{} },
        .percentile => .{ .percentile = .{ .values = ManagedArrayList(f64).init(allocator), .quantile = aggregate.quantile } },
        .delta => .{ .delta = .{ .series = ManagedArrayList(Operator.SeriesDerivativeState).init(allocator), .metric_kind = .gauge } },
        .rate => .{ .rate = .{ .series = ManagedArrayList(Operator.SeriesDerivativeState).init(allocator), .metric_kind = .gauge } },
        .irate => .{ .irate = .{ .series = ManagedArrayList(Operator.SeriesDerivativeState).init(allocator), .metric_kind = .gauge } },
    };
}

fn deinitAggregateState(allocator: std.mem.Allocator, state: Operator.AggregateState) void {
    switch (state) {
        .percentile => |payload| payload.values.deinit(),
        .delta => |payload| payload.series.deinit(),
        .rate => |payload| payload.series.deinit(),
        .irate => |payload| payload.series.deinit(),
        else => _ = allocator,
    }
}

fn updateState(
    state: *Operator.AggregateState,
    aggregate: Operator.AggregateExpr,
    maybe_value: ?Value,
    metric_kind: metric_catalog_mod.MetricKind,
    series_id: ?types.SeriesId,
    ts: ?i64,
) ExecuteError!void {
    switch (aggregate.kind) {
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
        .min => {
            if (maybe_value) |value| {
                if (!value.isNull()) {
                    switch (state.*) {
                        .min => |*min_state| {
                            if (!min_state.seen or compareValuesForSort(value, min_state.value) == .lt) {
                                min_state.* = .{ .seen = true, .value = value };
                            }
                        },
                        else => unreachable,
                    }
                }
            }
        },
        .max => {
            if (maybe_value) |value| {
                if (!value.isNull()) {
                    switch (state.*) {
                        .max => |*max_state| {
                            if (!max_state.seen or compareValuesForSort(value, max_state.value) == .gt) {
                                max_state.* = .{ .seen = true, .value = value };
                            }
                        },
                        else => unreachable,
                    }
                }
            }
        },
        .first => {
            if (maybe_value) |value| {
                if (!value.isNull()) {
                    switch (state.*) {
                        .first => |*first_state| {
                            if (!first_state.seen) {
                                first_state.* = .{ .seen = true, .value = value };
                            }
                        },
                        else => unreachable,
                    }
                }
            }
        },
        .last => {
            if (maybe_value) |value| {
                if (!value.isNull()) {
                    switch (state.*) {
                        .last => |*last_state| {
                            last_state.* = .{ .seen = true, .value = value };
                        },
                        else => unreachable,
                    }
                }
            }
        },
        .percentile => {
            if (maybe_value) |value| {
                if (!value.isNull()) {
                    switch (state.*) {
                        .percentile => |*percentile_state| try percentile_state.values.append(try value.asFloat()),
                        else => unreachable,
                    }
                }
            }
        },
        .delta, .rate, .irate => {
            if (maybe_value == null or series_id == null or ts == null) return;
            const numeric = try maybe_value.?.asFloat();
            switch (state.*) {
                .delta => |*payload| {
                    payload.metric_kind = metric_kind;
                    try updateDerivativeSeries(&payload.series, series_id.?, ts.?, numeric, metric_kind);
                },
                .rate => |*payload| {
                    payload.metric_kind = metric_kind;
                    try updateDerivativeSeries(&payload.series, series_id.?, ts.?, numeric, metric_kind);
                },
                .irate => |*payload| {
                    payload.metric_kind = metric_kind;
                    try updateDerivativeSeries(&payload.series, series_id.?, ts.?, numeric, metric_kind);
                },
                else => unreachable,
            }
        },
    }
}

fn finalizeState(state: Operator.AggregateState, kind: Operator.AggregateKind) Value {
    return switch (state) {
        .filled => |value| value,
        else => switch (kind) {
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
        .min => switch (state) {
            .min => |min_state| if (min_state.seen) min_state.value else Value.null,
            else => unreachable,
        },
        .max => switch (state) {
            .max => |max_state| if (max_state.seen) max_state.value else Value.null,
            else => unreachable,
        },
        .first => switch (state) {
            .first => |first_state| if (first_state.seen) first_state.value else Value.null,
            else => unreachable,
        },
        .last => switch (state) {
            .last => |last_state| if (last_state.seen) last_state.value else Value.null,
            else => unreachable,
        },
        .percentile => switch (state) {
            .percentile => |percentile_state| percentileValue(percentile_state.values.items, percentile_state.quantile),
            else => unreachable,
        },
        .delta => switch (state) {
            .delta => |payload| derivativeAggregateValue(payload.series.items, .delta, payload.metric_kind),
            else => unreachable,
        },
        .rate => switch (state) {
            .rate => |payload| derivativeAggregateValue(payload.series.items, .rate, payload.metric_kind),
            else => unreachable,
        },
        .irate => switch (state) {
            .irate => |payload| derivativeAggregateValue(payload.series.items, .irate, payload.metric_kind),
            else => unreachable,
        },
    } };
}

fn updateDerivativeSeries(
    states: *ManagedArrayList(Operator.SeriesDerivativeState),
    series_id: types.SeriesId,
    ts: i64,
    value: f64,
    metric_kind: metric_catalog_mod.MetricKind,
) !void {
    for (states.items) |*state| {
        if (state.series_id != series_id) continue;
        const previous_value = state.last_value;
        const previous_ts = state.last_ts;
        if (metric_kind == .counter and value < previous_value) {
            state.reset_accum += value;
            state.last_step_delta = value;
        } else {
            state.last_step_delta = value - previous_value;
        }
        state.last_step_dt = ts - previous_ts;
        state.last_ts = ts;
        state.last_value = value;
        return;
    }
    try states.append(.{
        .series_id = series_id,
        .first_ts = ts,
        .last_ts = ts,
        .first_value = value,
        .last_value = value,
    });
}

const DerivativeKind = enum { delta, rate, irate };

fn derivativeAggregateValue(
    states: []const Operator.SeriesDerivativeState,
    kind: DerivativeKind,
    metric_kind: metric_catalog_mod.MetricKind,
) Value {
    var saw = false;
    var total: f64 = 0;
    for (states) |state| {
        switch (kind) {
            .delta => {
                total += derivativeDelta(state, metric_kind);
                saw = true;
            },
            .rate => {
                const duration = state.last_ts - state.first_ts;
                if (duration <= 0) continue;
                total += derivativeDelta(state, metric_kind) / @as(f64, @floatFromInt(duration));
                saw = true;
            },
            .irate => {
                if (state.last_step_delta == null or state.last_step_dt == null or state.last_step_dt.? <= 0) continue;
                total += state.last_step_delta.? / @as(f64, @floatFromInt(state.last_step_dt.?));
                saw = true;
            },
        }
    }
    return if (saw) Value{ .float = total } else Value.null;
}

fn derivativeDelta(state: Operator.SeriesDerivativeState, metric_kind: metric_catalog_mod.MetricKind) f64 {
    return if (metric_kind == .counter)
        (state.last_value - state.first_value) + state.reset_accum
    else
        state.last_value - state.first_value;
}

fn percentileValue(values: []const f64, quantile: f64) Value {
    if (values.len == 0) return Value.null;
    const copy = std.heap.page_allocator.alloc(f64, values.len) catch return Value.null;
    defer std.heap.page_allocator.free(copy);
    @memcpy(copy, values);
    std.sort.block(f64, copy, {}, struct {
        fn lessThan(_: void, lhs: f64, rhs: f64) bool {
            return lhs < rhs;
        }
    }.lessThan);
    const index_float = quantile * @as(f64, @floatFromInt(copy.len - 1));
    const lower: usize = @intFromFloat(@floor(index_float));
    const upper: usize = @intFromFloat(@ceil(index_float));
    if (lower == upper) return .{ .float = copy[lower] };
    const weight = index_float - @as(f64, @floatFromInt(lower));
    return .{ .float = copy[lower] + (copy[upper] - copy[lower]) * weight };
}

fn inferMetricKind(child: *Operator) metric_catalog_mod.MetricKind {
    return switch (child.payload) {
        .scan => |payload| if (payload.series.len != 0) child.payload.scan.engine.metricKindOrDefault(scanMetricName(child.payload.scan.engine, payload.series[0].series_id) orelse "") else .gauge,
        .filter => |payload| inferMetricKind(payload.child),
        .project => |payload| inferMetricKind(payload.child),
        .limit => |payload| inferMetricKind(payload.child),
        .sort,
        .aggregate,
        .one_row,
        .test_source,
        => .gauge,
    };
}

fn scanMetricName(engine: *engine_mod.Engine, series_id: types.SeriesId) ?[]const u8 {
    const resolution = engine.resolveSelector(.{ .by_id = series_id }) catch return null;
    return resolution.series;
}

fn applyFill(allocator: std.mem.Allocator, payload: *Operator.Aggregate) ExecuteError!void {
    const fill = payload.fill orelse return;
    const bucket_idx = timeBucketGroupIndex(payload.group_exprs) orelse return error.UnsupportedFill;
    const bucket_step = timeBucketStep(payload.group_exprs[bucket_idx].expr) orelse return error.UnsupportedFill;

    std.sort.pdq(Operator.GroupState, payload.groups.items, FillSortContext{ .bucket_idx = bucket_idx }, FillSortContext.lessThan);

    var filled = ManagedArrayList(Operator.GroupState).init(allocator);
    errdefer {
        for (filled.items) |group| {
            for (group.aggregates) |state| deinitAggregateState(allocator, state);
            allocator.free(group.keys);
            allocator.free(group.aggregates);
        }
        filled.deinit();
    }

    var idx: usize = 0;
    while (idx < payload.groups.items.len) {
        try filled.append(payload.groups.items[idx]);
        var previous = payload.groups.items[idx];
        idx += 1;
        while (idx < payload.groups.items.len and sameFillPartition(previous.keys, payload.groups.items[idx].keys, bucket_idx)) : (idx += 1) {
            const next_group = payload.groups.items[idx];
            const current_bucket = try previous.keys[bucket_idx].asInt();
            const next_bucket = try next_group.keys[bucket_idx].asInt();
            var missing_bucket = current_bucket + bucket_step;
            while (missing_bucket < next_bucket) : (missing_bucket += bucket_step) {
                const fill_value = switch (fill.strategy) {
                    .previous => try filledValuesFromGroup(allocator, payload, previous),
                    .constant => |expr| blk: {
                        const value = try expression.evaluateConstant(expr);
                        break :blk try filledValuesConstant(allocator, payload, value);
                    },
                    else => return error.UnsupportedFill,
                };
                const filled_group = try makeFilledGroup(allocator, payload, previous, bucket_idx, missing_bucket, fill_value);
                try filled.append(filled_group);
            }
            try filled.append(next_group);
            previous = next_group;
        }
    }

    payload.groups.deinit();
    payload.groups = filled;
}

const FillSortContext = struct {
    bucket_idx: usize,

    fn lessThan(ctx: FillSortContext, lhs: Operator.GroupState, rhs: Operator.GroupState) bool {
        if (comparePartitionKeys(lhs.keys, rhs.keys, ctx.bucket_idx) == .lt) return true;
        if (comparePartitionKeys(lhs.keys, rhs.keys, ctx.bucket_idx) == .gt) return false;
        return valueToInt(lhs.keys[ctx.bucket_idx]) < valueToInt(rhs.keys[ctx.bucket_idx]);
    }
};

fn timeBucketGroupIndex(groupings: []const ast.GroupExpr) ?usize {
    for (groupings, 0..) |grouping, idx| {
        if (grouping.expr.* == .call and std.ascii.eqlIgnoreCase(grouping.expr.call.callee.value, "time_bucket")) return idx;
    }
    return null;
}

fn timeBucketStep(expr: *const ast.Expr) ?i64 {
    if (expr.* != .call or !std.ascii.eqlIgnoreCase(expr.call.callee.value, "time_bucket")) return null;
    if (expr.call.args.len == 0) return null;
    const value = expression.evaluateConstant(expr.call.args[0]) catch return null;
    return @intFromFloat(valueToFloat(value));
}

fn sameFillPartition(lhs: []const Value, rhs: []const Value, bucket_idx: usize) bool {
    return comparePartitionKeys(lhs, rhs, bucket_idx) == .eq;
}

fn comparePartitionKeys(lhs: []const Value, rhs: []const Value, bucket_idx: usize) std.math.Order {
    var idx: usize = 0;
    while (idx < lhs.len and idx < rhs.len) : (idx += 1) {
        if (idx == bucket_idx) continue;
        const order = compareValuesForSort(lhs[idx], rhs[idx]);
        if (order != .eq) return order;
    }
    return .eq;
}

fn valueToInt(value: Value) i64 {
    return switch (value) {
        .integer => |integer| integer,
        .float => |float| @intFromFloat(float),
        else => 0,
    };
}

fn filledValuesFromGroup(allocator: std.mem.Allocator, payload: *const Operator.Aggregate, group: Operator.GroupState) ![]Value {
    const values = try allocator.alloc(Value, payload.aggregates.len);
    for (payload.aggregates, 0..) |aggregate, idx| {
        values[idx] = finalizeState(group.aggregates[idx], aggregate.kind);
    }
    return values;
}

fn filledValuesConstant(allocator: std.mem.Allocator, payload: *const Operator.Aggregate, value: Value) ![]Value {
    const values = try allocator.alloc(Value, payload.aggregates.len);
    for (values) |*slot| slot.* = value;
    return values;
}

fn makeFilledGroup(
    allocator: std.mem.Allocator,
    payload: *const Operator.Aggregate,
    source: Operator.GroupState,
    bucket_idx: usize,
    bucket_value: i64,
    filled_values: []Value,
) !Operator.GroupState {
    defer allocator.free(filled_values);
    const keys = try Value.copySlice(allocator, source.keys);
    keys[bucket_idx] = .{ .integer = bucket_value };
    const states = try allocator.alloc(Operator.AggregateState, payload.aggregates.len);
    for (payload.aggregates, 0..) |aggregate, idx| {
        states[idx] = .{ .filled = filled_values[idx] };
        _ = aggregate;
    }
    return .{ .keys = keys, .aggregates = states };
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

fn hasTagLikePrefix(name: []const u8) bool {
    const dot = std.mem.indexOfScalar(u8, name, '.') orelse return false;
    const prefix = name[0..dot];
    return std.ascii.eqlIgnoreCase(prefix, "tag") or std.ascii.eqlIgnoreCase(prefix, "label");
}

fn tagKey(name: []const u8) []const u8 {
    const dot = std.mem.indexOfScalar(u8, name, '.') orelse return name;
    return name[dot + 1 ..];
}

pub fn createTestSourceOperator(allocator: std.mem.Allocator, schema: []const plan.ColumnInfo, rows: []([]Value)) ExecuteError!*Operator {
    const payload = Operator.TestSource{ .schema = schema, .rows = rows, .index = 0 };
    return try createOperator(allocator, schema, "test_source", testSourceNext, testSourceDestroy, .{ .test_source = payload });
}

fn testSourceNext(op: *Operator) ExecuteError!?Row {
    var payload = &op.payload.test_source;
    if (payload.index >= payload.rows.len) return null;
    const values = payload.rows[payload.index];
    payload.index += 1;
    return Row{ .schema = payload.schema, .values = values, .tags = &.{}, .series_id = null, .ts = null };
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

test "aggregate min max first and last without grouping" {
    const alloc = std.testing.allocator;
    const common = @import("common.zig");

    const time_name = try alloc.dupe(u8, "time");
    const value_name = try alloc.dupe(u8, "value");
    const base_span = common.Span.init(0, 0);

    const time_expr = try alloc.create(ast.Expr);
    defer alloc.destroy(time_expr);
    time_expr.* = .{ .identifier = .{ .value = time_name, .quoted = false, .span = base_span } };

    const value_expr = try alloc.create(ast.Expr);
    defer alloc.destroy(value_expr);
    value_expr.* = .{ .identifier = .{ .value = value_name, .quoted = false, .span = base_span } };

    const child_columns = try alloc.alloc(plan.ColumnInfo, 2);
    defer alloc.free(child_columns);
    child_columns[0] = .{ .name = time_name, .expr = time_expr };
    child_columns[1] = .{ .name = value_name, .expr = value_expr };

    var row1 = try alloc.alloc(Value, 2);
    defer alloc.free(row1);
    row1[0] = Value{ .integer = 0 };
    row1[1] = Value{ .float = 3.0 };
    var row2 = try alloc.alloc(Value, 2);
    defer alloc.free(row2);
    row2[0] = Value{ .integer = 60 };
    row2[1] = Value{ .float = 1.0 };
    var row3 = try alloc.alloc(Value, 2);
    defer alloc.free(row3);
    row3[0] = Value{ .integer = 120 };
    row3[1] = Value{ .float = 5.0 };

    const data = try alloc.alloc([]Value, 3);
    defer alloc.free(data);
    data[0] = row1;
    data[1] = row2;
    data[2] = row3;

    var child = try createTestSourceOperator(alloc, child_columns, data);
    var child_owned = false;
    defer if (!child_owned) child.destroy();

    const function_names = [_][]const u8{ "min", "max", "first", "last" };
    const output_names = [_][]const u8{ "min_value", "max_value", "first_value", "last_value" };
    const agg_columns = try alloc.alloc(plan.ColumnInfo, function_names.len);
    defer alloc.free(agg_columns);

    var call_exprs = try alloc.alloc(*ast.Expr, function_names.len);
    defer alloc.free(call_exprs);
    var call_args = try alloc.alloc([]*const ast.Expr, function_names.len);
    defer alloc.free(call_args);
    var owned_name_storage = try alloc.alloc([]u8, function_names.len * 2);
    defer {
        for (owned_name_storage) |name| alloc.free(name);
        alloc.free(owned_name_storage);
    }

    for (function_names, 0..) |fn_name, idx| {
        owned_name_storage[idx] = try alloc.dupe(u8, fn_name);
        owned_name_storage[function_names.len + idx] = try alloc.dupe(u8, output_names[idx]);

        const args = try alloc.alloc(*const ast.Expr, 1);
        args[0] = value_expr;
        call_args[idx] = args;

        const call_expr = try alloc.create(ast.Expr);
        call_expr.* = .{ .call = .{
            .callee = .{ .value = owned_name_storage[idx], .quoted = false, .span = base_span },
            .args = args,
            .span = base_span,
        } };
        call_exprs[idx] = call_expr;
        agg_columns[idx] = .{ .name = owned_name_storage[function_names.len + idx], .expr = call_expr };
    }
    defer {
        for (call_exprs) |expr| alloc.destroy(expr);
        for (call_args) |args| alloc.free(args);
    }

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
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), try row.values[0].asFloat(), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), try row.values[1].asFloat(), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), try row.values[2].asFloat(), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), try row.values[3].asFloat(), 1e-9);
    try std.testing.expect((try agg_op.next()) == null);

    alloc.free(time_name);
    alloc.free(value_name);
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
