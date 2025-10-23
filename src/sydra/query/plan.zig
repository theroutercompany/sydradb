const std = @import("std");
const meta = std.meta;
const ast = @import("ast.zig");
const functions = @import("functions.zig");
const common = @import("common.zig");
const infer = @import("type_inference.zig");

const ManagedArrayList = std.array_list.Managed;

pub const BuildError = error{
    UnsupportedStatement,
};

pub const ColumnInfo = struct {
    name: []const u8,
    expr: *const ast.Expr,
};

pub const RollupHint = struct {
    bucket_expr: *const ast.Expr,
};

const empty_columns = [_]ColumnInfo{};

pub const Node = union(enum) {
    scan: Scan,
    filter: Filter,
    project: Project,
    aggregate: Aggregate,
    sort: Sort,
    limit: Limit,
};

pub const Scan = struct {
    source: *const ast.Select,
    selector: ?ast.Selector,
    output: []const ColumnInfo,
};

pub const Filter = struct {
    input: *Node,
    predicate: *const ast.Expr,
    output: []const ColumnInfo,
    conjunctive_predicates: []const *const ast.Expr,
};

pub const Project = struct {
    input: *Node,
    projections: []const ast.Projection,
    output: []const ColumnInfo,
};

pub const Aggregate = struct {
    input: *Node,
    groupings: []const ast.GroupExpr,
    projections: []const ast.Projection,
    fill: ?ast.FillClause,
    rollup_hint: ?RollupHint,
    output: []const ColumnInfo,
};

pub const Sort = struct {
    input: *Node,
    ordering: []const ast.OrderExpr,
    output: []const ColumnInfo,
};

pub const Limit = struct {
    input: *Node,
    limit: ast.LimitClause,
    output: []const ColumnInfo,
};

pub fn nodeOutput(node: *Node) []const ColumnInfo {
    return switch (node.*) {
        .scan => node.scan.output,
        .filter => node.filter.output,
        .project => node.project.output,
        .aggregate => node.aggregate.output,
        .sort => node.sort.output,
        .limit => node.limit.output,
    };
}

pub const Builder = struct {
    allocator: std.mem.Allocator,
    column_counter: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Builder {
        return .{ .allocator = allocator };
    }

    pub fn build(self: *Builder, statement: *const ast.Statement) (BuildError || std.mem.Allocator.Error)!*Node {
        switch (statement.*) {
            .select => |select_ptr| return self.buildSelect(select_ptr),
            else => return BuildError.UnsupportedStatement,
        }
    }

    fn buildSelect(self: *Builder, select: *const ast.Select) (BuildError || std.mem.Allocator.Error)!*Node {
        const projection_columns = try self.buildColumns(select.projections);
        self.column_counter += projection_columns.len;

        const scan_columns = try self.defaultScanColumns();
        var current = try self.makeNode(.{
            .scan = .{
                .source = select,
                .selector = select.selector,
                .output = scan_columns,
            },
        });
        var filter_list = ManagedArrayList(*const ast.Expr).init(self.allocator);
        try self.collectPredicates(select.predicate, &filter_list);
        var filter_conditions: []const *const ast.Expr = &.{};
        if (filter_list.items.len != 0) {
            filter_conditions = try filter_list.toOwnedSlice();
            const predicate = try self.combinePredicates(filter_conditions);
            current = try self.makeNode(.{
                .filter = .{
                    .input = current,
                    .predicate = predicate,
                    .output = nodeOutput(current),
                    .conjunctive_predicates = filter_conditions,
                },
            });
        }
        filter_list.deinit();

        if (needsAggregation(select)) {
            const rollup_hint = detectRollupHint(select.groupings);
            current = try self.makeNode(.{
                .aggregate = .{
                    .input = current,
                    .groupings = select.groupings,
                    .projections = select.projections,
                    .fill = select.fill,
                    .rollup_hint = rollup_hint,
                    .output = projection_columns,
                },
            });
        }

        current = try self.makeNode(.{
            .project = .{
                .input = current,
                .projections = select.projections,
                .output = projection_columns,
            },
        });

        if (select.ordering.len != 0) {
            current = try self.makeNode(.{
                .sort = .{
                    .input = current,
                    .ordering = select.ordering,
                    .output = projection_columns,
                },
            });
        }

        if (select.limit) |limit_clause| {
            current = try self.makeNode(.{
                .limit = .{
                    .input = current,
                    .limit = limit_clause,
                    .output = projection_columns,
                },
            });
        }

        return current;
    }

    fn buildColumns(self: *Builder, projections: []const ast.Projection) ![]const ColumnInfo {
        const cols = try self.allocator.alloc(ColumnInfo, projections.len);
        for (projections, 0..) |projection, idx| {
            const name = try self.inferProjectionName(projection, idx);
            cols[idx] = .{ .name = name, .expr = projection.expr };
        }
        return cols;
    }

    fn collectPredicates(self: *Builder, predicate: ?*const ast.Expr, list: *ManagedArrayList(*const ast.Expr)) !void {
        if (predicate) |expr| {
            switch (expr.*) {
                .binary => |binary| {
                    if (binary.op == .logical_and) {
                        try self.collectPredicates(binary.left, list);
                        try self.collectPredicates(binary.right, list);
                        return;
                    }
                },
                else => {},
            }
            try list.append(expr);
        }
    }

    fn combinePredicates(self: *Builder, predicates: []const *const ast.Expr) !*const ast.Expr {
        std.debug.assert(predicates.len != 0);
        var result = predicates[0];
        for (predicates[1..]) |expr| {
            const span = spanUnion(exprSpan(result), exprSpan(expr));
            result = try self.allocExpr(.{
                .binary = .{
                    .op = ast.BinaryOp.logical_and,
                    .left = result,
                    .right = expr,
                    .span = span,
                },
            });
        }
        return result;
    }

    fn allocExpr(self: *Builder, expr: ast.Expr) !*const ast.Expr {
        const ptr = try self.allocator.create(ast.Expr);
        ptr.* = expr;
        return ptr;
    }

    fn inferProjectionName(self: *Builder, projection: ast.Projection, index: usize) ![]const u8 {
        if (projection.alias) |alias| {
            return try self.allocator.dupe(u8, alias.value);
        }
        const expr = projection.expr;
        return switch (expr.*) {
            .identifier => |ident| try self.allocator.dupe(u8, ident.value),
            .call => |call| try std.fmt.allocPrint(self.allocator, "{s}_{d}", .{ call.callee.value, self.column_counter + index }),
            else => try std.fmt.allocPrint(self.allocator, "_col{d}", .{self.column_counter + index}),
        };
    }

    fn makeNode(self: *Builder, node: Node) !*Node {
        const ptr = try self.allocator.create(Node);
        ptr.* = node;
        return ptr;
    }

    fn defaultScanColumns(self: *Builder) ![]const ColumnInfo {
        const cols = try self.allocator.alloc(ColumnInfo, 2);
        const time_name = try self.allocator.dupe(u8, "time");
        const value_name = try self.allocator.dupe(u8, "value");

        const time_ident = ast.Identifier{
            .value = time_name,
            .quoted = false,
            .span = common.Span.init(0, 0),
        };
        const value_ident = ast.Identifier{
            .value = value_name,
            .quoted = false,
            .span = common.Span.init(0, 0),
        };

        cols[0] = .{
            .name = time_name,
            .expr = try self.allocExpr(.{ .identifier = time_ident }),
        };
        cols[1] = .{
            .name = value_name,
            .expr = try self.allocExpr(.{ .identifier = value_ident }),
        };
        return cols;
    }
};

fn detectRollupHint(groupings: []const ast.GroupExpr) ?RollupHint {
    for (groupings) |group_expr| {
        if (group_expr.expr.* == .call) {
            const call = group_expr.expr.call;
            if (std.ascii.eqlIgnoreCase(call.callee.value, "time_bucket")) {
                return RollupHint{ .bucket_expr = group_expr.expr };
            }
        }
    }
    return null;
}

fn exprSpan(expr: *const ast.Expr) common.Span {
    return common.Span.init(exprStart(expr), exprEnd(expr));
}

fn exprStart(expr: *const ast.Expr) usize {
    return switch (expr.*) {
        .identifier => |id| id.span.start,
        .literal => |lit| lit.span.start,
        .call => |call| call.span.start,
        .binary => |binary| binary.span.start,
        .unary => |unary| unary.span.start,
    };
}

fn exprEnd(expr: *const ast.Expr) usize {
    return switch (expr.*) {
        .identifier => |id| id.span.end,
        .literal => |lit| lit.span.end,
        .call => |call| call.span.end,
        .binary => |binary| binary.span.end,
        .unary => |unary| unary.span.end,
    };
}

fn spanUnion(a: common.Span, b: common.Span) common.Span {
    const start = if (a.start < b.start) a.start else b.start;
    const end = if (a.end > b.end) a.end else b.end;
    return common.Span.init(start, end);
}

fn needsAggregation(select: *const ast.Select) bool {
    if (select.groupings.len != 0) return true;
    for (select.projections) |projection| {
        if (containsAggregate(projection.expr)) return true;
    }
    return false;
}

fn containsAggregate(expr: *const ast.Expr) bool {
    return switch (expr.*) {
        .identifier => false,
        .literal => false,
        .unary => |unary| containsAggregate(unary.operand),
        .binary => |binary| containsAggregate(binary.left) or containsAggregate(binary.right),
        .call => |call| {
            if (functions.lookup(call.callee.value)) |entry| {
                if (entry.kind == .aggregate or entry.kind == .window) return true;
            }
            for (call.args) |arg| {
                if (containsAggregate(arg)) return true;
            }
            return false;
        },
    };
}

test "build simple select plan" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const query = "select value from metrics where time > 0 order by time asc limit 5";
    var parser_inst = @import("parser.zig").Parser.init(arena.allocator(), query);
    var statement = try parser_inst.parse();

    var analyzer = @import("validator.zig").Analyzer.init(arena.allocator());
    var analysis = try analyzer.analyze(&statement);
    defer analyzer.deinit(&analysis);
    try std.testing.expect(analysis.is_valid);

    var builder = Builder.init(arena.allocator());
    const plan = try builder.build(&statement);

    try std.testing.expect(meta.activeTag(plan.*) == .limit);
    const limit = plan.limit;
    try std.testing.expectEqual(@as(usize, 5), limit.limit.limit);
    try std.testing.expectEqual(@as(usize, 1), limit.output.len);

    const sort_node = limit.input;
    try std.testing.expect(meta.activeTag(sort_node.*) == .sort);
    const sort_plan = sort_node.sort;
    try std.testing.expectEqual(@as(usize, 1), sort_plan.ordering.len);
    try std.testing.expect(sort_plan.output.len == 1);

    const project_node = sort_plan.input;
    try std.testing.expect(meta.activeTag(project_node.*) == .project);
    const project_plan = project_node.project;
    try std.testing.expectEqual(@as(usize, 1), project_plan.output.len);
    try std.testing.expectEqualStrings("value", project_plan.output[0].name);

    const filter_node = project_plan.input;
    try std.testing.expect(meta.activeTag(filter_node.*) == .filter);
    const filter_plan = filter_node.filter;
    try std.testing.expect(meta.activeTag(filter_plan.input.*) == .scan);
    try std.testing.expectEqual(@as(usize, 1), filter_plan.conjunctive_predicates.len);
}

test "filter captures conjunctive predicates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const query = "select value from metrics where time >= 0 and value > 5";
    var parser_inst = @import("parser.zig").Parser.init(arena.allocator(), query);
    var statement = try parser_inst.parse();

    var analyzer = @import("validator.zig").Analyzer.init(arena.allocator());
    var analysis = try analyzer.analyze(&statement);
    defer analyzer.deinit(&analysis);
    try std.testing.expect(analysis.is_valid);

    var builder = Builder.init(arena.allocator());
    const plan_root = try builder.build(&statement);

    try std.testing.expect(plan_root.* == .project);
    const project_plan = plan_root.project;
    const filter_node = project_plan.input;
    try std.testing.expect(filter_node.* == .filter);
    const filter_plan = filter_node.filter;
    try std.testing.expectEqual(@as(usize, 2), filter_plan.conjunctive_predicates.len);
}

test "build aggregate plan with rollup hint" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const query = "select avg(value) from metrics where time >= 0 group by time_bucket(60, time)";
    var parser_inst = @import("parser.zig").Parser.init(arena.allocator(), query);
    var statement = try parser_inst.parse();

    var analyzer = @import("validator.zig").Analyzer.init(arena.allocator());
    var analysis = try analyzer.analyze(&statement);
    defer analyzer.deinit(&analysis);
    try std.testing.expect(analysis.is_valid);

    var builder = Builder.init(arena.allocator());
    const plan = try builder.build(&statement);

    try std.testing.expect(plan.* == .project);
    const project_plan = plan.project;
    try std.testing.expectEqual(@as(usize, 1), project_plan.output.len);

    const aggregate_node = project_plan.input;
    try std.testing.expect(meta.activeTag(aggregate_node.*) == .aggregate);
    const aggregate_plan = aggregate_node.aggregate;
    try std.testing.expectEqual(@as(usize, 1), aggregate_plan.groupings.len);
    try std.testing.expect(aggregate_plan.rollup_hint != null);
    try std.testing.expectEqual(@as(usize, 1), aggregate_plan.output.len);
    try std.testing.expectEqualStrings("avg_0", aggregate_plan.output[0].name);
    try std.testing.expect(meta.activeTag(aggregate_plan.input.*) == .filter);
    const filter_node = aggregate_plan.input;
    const filter_plan = filter_node.filter;
    if (filter_plan.conjunctive_predicates.len == 0) return error.TestFailure;
}

test "nodeOutput reports selected columns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const query = "select value from metrics where time > 0";
    var parser_inst = @import("parser.zig").Parser.init(arena.allocator(), query);
    var statement = try parser_inst.parse();

    var analyzer = @import("validator.zig").Analyzer.init(arena.allocator());
    var analysis = try analyzer.analyze(&statement);
    defer analyzer.deinit(&analysis);
    try std.testing.expect(analysis.is_valid);

    var builder = Builder.init(arena.allocator());
    const root = try builder.build(&statement);
    const columns = nodeOutput(root);
    try std.testing.expectEqual(@as(usize, 1), columns.len);
}

test "plan retains projection alias" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const query = "select tag.host as site from metrics";
    var parser_inst = @import("parser.zig").Parser.init(arena.allocator(), query);
    var statement = try parser_inst.parse();

    var analyzer = @import("validator.zig").Analyzer.init(arena.allocator());
    var analysis = try analyzer.analyze(&statement);
    defer analyzer.deinit(&analysis);
    try std.testing.expect(analysis.is_valid);

    var builder = Builder.init(arena.allocator());
    const root = try builder.build(&statement);
    try std.testing.expect(root.* == .project);
    const project_node = root.project;
    try std.testing.expectEqualStrings("site", project_node.output[0].name);
}
