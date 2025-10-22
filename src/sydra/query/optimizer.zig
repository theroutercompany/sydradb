const std = @import("std");
const plan = @import("plan.zig");
const ast = @import("ast.zig");
const common = @import("common.zig");
const meta = std.meta;

const ManagedArrayList = std.array_list.Managed;

pub const OptimizeError = plan.BuildError || std.mem.Allocator.Error;

pub fn optimize(allocator: std.mem.Allocator, root: *plan.Node) OptimizeError!*plan.Node {
    try pruneProjects(allocator, root);
    try pushdownPredicates(root, allocator);
    return root;
}

fn pruneProjects(allocator: std.mem.Allocator, node: *plan.Node) !void {
    switch (node.*) {
        .project => |project| {
            switch (project.input.*) {
                .project => |child| {
                    child.output = try mergeColumns(allocator, project.projections, child.output);
                    project.input = child.input;
                },
                .aggregate => |child| {
                    child.output = try mergeColumns(allocator, project.projections, child.output);
                },
                else => {},
            }
            try pruneProjects(allocator, project.input);
        },
        .filter => |filter| {
            try pruneProjects(allocator, filter.input);
        },
        .aggregate => |aggregate| {
            try pruneProjects(allocator, aggregate.input);
        },
        .sort => |sort| {
            try pruneProjects(allocator, sort.input);
        },
        .limit => |limit| {
            try pruneProjects(allocator, limit.input);
        },
        .scan => {},
    }
}

fn mergeColumns(allocator: std.mem.Allocator, projections: []const ast.Projection, child_columns: []const plan.ColumnInfo) ![]const plan.ColumnInfo {
    const merged = try allocator.alloc(plan.ColumnInfo, projections.len);
    for (projections, 0..) |projection, idx| {
        const expr = projection.expr;
        merged[idx] = findColumn(child_columns, expr) orelse plan.ColumnInfo{ .name = try columnAliasOrGenerated(allocator, projection, idx), .expr = expr };
    }
    return merged;
}

fn columnAliasOrGenerated(allocator: std.mem.Allocator, projection: ast.Projection, index: usize) ![]const u8 {
    if (projection.alias) |alias| return try allocator.dupe(u8, alias.value);
    return try std.fmt.allocPrint(allocator, "_col{d}", .{index});
}

fn findColumn(columns: []const plan.ColumnInfo, expr: *const ast.Expr) ?plan.ColumnInfo {
    for (columns) |col| {
        if (col.expr == expr) return col;
    }
    return null;
}

fn pushdownPredicates(node: *plan.Node, allocator: std.mem.Allocator) !void {
    switch (node.*) {
        .project => |project| try pushdownPredicates(project.input, allocator),
        .sort => |sort| try pushdownPredicates(sort.input, allocator),
        .limit => |limit| try pushdownPredicates(limit.input, allocator),
        .aggregate => |aggregate| try pushdownPredicates(aggregate.input, allocator),
        .filter => |_| {
            const child = node.filter.input;
            try pushdownPredicates(child, allocator);
            const child_tag = meta.activeTag(child.*);
            switch (child_tag) {
                .project => {
                    moveFilterBelowProject(node);
                    return try pushdownPredicates(node, allocator);
                },
                .sort => {
                    moveFilterBelowSort(node);
                    return try pushdownPredicates(node, allocator);
                },
                .limit => {
                    moveFilterBelowLimit(node);
                    return try pushdownPredicates(node, allocator);
                },
                .filter => {
                    try mergeFilters(&node.filter, child, allocator);
                    return try pushdownPredicates(node, allocator);
                },
                .aggregate => {
                    try pushFilterBelowAggregate(node, allocator);
                    return try pushdownPredicates(node, allocator);
                },
                .scan => {},
            }
        },
        .scan => {},
    }
}

fn moveFilterBelowProject(node_ptr: *plan.Node) void {
    const filter_data = node_ptr.filter;
    const project_ptr = filter_data.input;
    var project_data = project_ptr.project;

    var new_filter = filter_data;
    new_filter.input = project_data.input;
    new_filter.output = plan.nodeOutput(project_data.input);

    project_data.input = project_ptr;
    project_ptr.* = .{ .filter = new_filter };

    node_ptr.* = .{ .project = project_data };
}

fn moveFilterBelowSort(node_ptr: *plan.Node) void {
    const filter_data = node_ptr.filter;
    const sort_ptr = filter_data.input;
    var sort_data = sort_ptr.sort;

    var new_filter = filter_data;
    new_filter.input = sort_data.input;
    new_filter.output = plan.nodeOutput(sort_data.input);

    sort_data.input = sort_ptr;
    sort_ptr.* = .{ .filter = new_filter };

    node_ptr.* = .{ .sort = sort_data };
}

fn moveFilterBelowLimit(node_ptr: *plan.Node) void {
    const filter_data = node_ptr.filter;
    const limit_ptr = filter_data.input;
    var limit_data = limit_ptr.limit;

    var new_filter = filter_data;
    new_filter.input = limit_data.input;
    new_filter.output = plan.nodeOutput(limit_data.input);

    limit_data.input = limit_ptr;
    limit_ptr.* = .{ .filter = new_filter };

    node_ptr.* = .{ .limit = limit_data };
}

fn mergeFilters(parent: *plan.Filter, child_node: *plan.Node, allocator: std.mem.Allocator) !void {
    const child = child_node.filter;
    const new_len = parent.conjunctive_predicates.len + child.conjunctive_predicates.len;
    const merged = try allocator.alloc(*const ast.Expr, new_len);
    std.mem.copy(*const ast.Expr, merged[0..parent.conjunctive_predicates.len], parent.conjunctive_predicates);
    std.mem.copy(*const ast.Expr, merged[parent.conjunctive_predicates.len..], child.conjunctive_predicates);

    parent.conjunctive_predicates = merged;
    parent.input = child.input;
    parent.output = child.output;
    parent.predicate = try buildPredicateExpr(allocator, merged);
    child_node.* = child.input.*;
}

fn pushFilterBelowAggregate(node_ptr: *plan.Node, allocator: std.mem.Allocator) !void {
    if (node_ptr.* != .filter) return;
    const aggregate_node_ptr = node_ptr.filter.input;
    if (aggregate_node_ptr.* != .aggregate) return;

    var aggregate_data = aggregate_node_ptr.aggregate;
    if (aggregate_data.groupings.len == 0) return;

    var push_list = ManagedArrayList(*const ast.Expr).init(allocator);
    defer push_list.deinit();
    var keep_list = ManagedArrayList(*const ast.Expr).init(allocator);
    defer keep_list.deinit();

    for (node_ptr.filter.conjunctive_predicates) |expr| {
        if (exprUsesGrouping(expr, &aggregate_data)) {
            try push_list.append(expr);
        } else {
            try keep_list.append(expr);
        }
    }

    if (push_list.items.len == 0) return;

    const pushed_slice = try push_list.toOwnedSlice();
    const pushed_pred = try buildPredicateExpr(allocator, pushed_slice);

    const new_filter_node = try allocator.create(plan.Node);
    new_filter_node.* = .{
        .filter = .{
            .input = aggregate_data.input,
            .predicate = pushed_pred,
            .output = plan.nodeOutput(aggregate_data.input),
            .conjunctive_predicates = pushed_slice,
        },
    };
    aggregate_data.input = new_filter_node;

    if (keep_list.items.len == 0) {
        aggregate_node_ptr.* = .{ .aggregate = aggregate_data };
        node_ptr.* = aggregate_node_ptr.*;
    } else {
        const keep_slice = try keep_list.toOwnedSlice();
        const new_parent_pred = try buildPredicateExpr(allocator, keep_slice);
        node_ptr.* = .{
            .filter = .{
                .input = aggregate_node_ptr,
                .predicate = new_parent_pred,
                .output = plan.nodeOutput(aggregate_node_ptr),
                .conjunctive_predicates = keep_slice,
            },
        };
        aggregate_node_ptr.* = .{ .aggregate = aggregate_data };
    }
}

fn exprUsesGrouping(expr: *const ast.Expr, aggregate: *const plan.Aggregate) bool {
    return switch (expr.*) {
        .identifier => |id| exprIsGroupingKey(&id, aggregate),
        .literal => true,
        .binary => |binary| exprUsesGrouping(binary.left, aggregate) and exprUsesGrouping(binary.right, aggregate),
        .unary => |unary| exprUsesGrouping(unary.operand, aggregate),
        .call => |call| exprIsGroupingExpr(call.callee.value, aggregate, call.args),
    };
}

fn exprIsGroupingKey(identifier: *const ast.Identifier, aggregate: *const plan.Aggregate) bool {
    for (aggregate.groupings) |group_expr| {
        if (group_expr.expr.* == .identifier) {
            const other = group_expr.expr.identifier;
            if (std.mem.eql(u8, other.value, identifier.value)) return true;
        }
        if (group_expr.expr == @as(*const ast.Expr, @ptrCast(identifier))) return true;
    }
    if (identifierAliasMatchesGrouping(identifier.value, aggregate)) return true;
    return false;
}

fn exprIsGroupingExpr(function_name: []const u8, aggregate: *const plan.Aggregate, args: []const *const ast.Expr) bool {
    for (aggregate.groupings) |group_expr| {
        if (group_expr.expr.* == .call) {
            const call = group_expr.expr.call;
            if (std.ascii.eqlIgnoreCase(call.callee.value, function_name) and call.args.len == args.len) {
                var match = true;
                for (args, 0..) |arg, idx| {
                    if (call.args[idx] != arg) {
                        match = false;
                        break;
                    }
                }
                if (match) return true;
            }
        }
    }
    return false;
}

fn identifierAliasMatchesGrouping(name: []const u8, aggregate: *const plan.Aggregate) bool {
    for (aggregate.output) |col| {
        if (std.mem.eql(u8, col.name, name) and exprMatchesGrouping(col.expr, aggregate)) return true;
    }
    return false;
}

fn exprMatchesGrouping(expr: *const ast.Expr, aggregate: *const plan.Aggregate) bool {
    for (aggregate.groupings) |group_expr| {
        if (expr == group_expr.expr) return true;
        if (expressionsEqual(expr, group_expr.expr)) return true;
    }
    for (aggregate.groupings) |group_expr| {
        if (plan.nodeOutput(aggregate.input).len != 0 and expressionsEqual(expr, group_expr.expr)) return true;
    }
    return false;
}

fn expressionsEqual(a: *const ast.Expr, b: *const ast.Expr) bool {
    if (meta.activeTag(a.*) != meta.activeTag(b.*)) return false;
    return switch (a.*) {
        .identifier => |aid| switch (b.*) {
            .identifier => |bid| std.mem.eql(u8, aid.value, bid.value),
            else => false,
        },
        .literal => |alit| switch (b.*) {
            .literal => |blit| literalEqual(alit, blit),
            else => false,
        },
        .call => |acall| switch (b.*) {
            .call => |bcall| callEqual(acall, bcall),
            else => false,
        },
        .binary => |abin| switch (b.*) {
            .binary => |bbin| abin.op == bbin.op and expressionsEqual(abin.left, bbin.left) and expressionsEqual(abin.right, bbin.right),
            else => false,
        },
        .unary => |aun| switch (b.*) {
            .unary => |bun| aun.op == bun.op and expressionsEqual(aun.operand, bun.operand),
            else => false,
        },
    };
}

fn literalEqual(a: ast.Literal, b: ast.Literal) bool {
    return switch (a.value) {
        .integer => |aval| switch (b.value) {
            .integer => |bval| aval == bval,
            else => false,
        },
        .float => |aval| switch (b.value) {
            .float => |bval| aval == bval,
            else => false,
        },
        .string => |astr| switch (b.value) {
            .string => |bstr| std.mem.eql(u8, astr, bstr),
            else => false,
        },
        .boolean => |abool| switch (b.value) {
            .boolean => |bbool| abool == bbool,
            else => false,
        },
        .null => switch (b.value) {
            .null => true,
            else => false,
        },
    };
}

fn callEqual(a: ast.Call, b: ast.Call) bool {
    if (!std.mem.eql(u8, a.callee.value, b.callee.value)) return false;
    if (a.args.len != b.args.len) return false;
    for (a.args, 0..) |arg, idx| {
        if (!expressionsEqual(arg, b.args[idx])) return false;
    }
    return true;
}

fn buildPredicateExpr(allocator: std.mem.Allocator, predicates: []const *const ast.Expr) !*const ast.Expr {
    if (predicates.len == 0) return null;
    var result = predicates[0];
    for (predicates[1..]) |expr| {
        const span = spanUnion(exprSpan(result), exprSpan(expr));
        const new_expr = try allocator.create(ast.Expr);
        new_expr.* = .{
            .binary = .{
                .op = ast.BinaryOp.logical_and,
                .left = result,
                .right = expr,
                .span = span,
            },
        };
        result = new_expr;
    }
    return result;
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

test "optimizer returns original plan" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const query = "select value from metrics where time > 0";
    var parser_inst = @import("parser.zig").Parser.init(arena.allocator(), query);
    var statement = try parser_inst.parse();

    var analyzer = @import("validator.zig").Analyzer.init(arena.allocator());
    var analysis = try analyzer.analyze(&statement);
    defer analyzer.deinit(&analysis);
    try std.testing.expect(analysis.is_valid);

    var builder = plan.Builder.init(arena.allocator());
    const root = try builder.build(&statement);

    const optimized = try optimize(arena.allocator(), root);
    try std.testing.expect(optimized == root);
}

test "optimizer collapses stacked projects" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const query = "select value from metrics where time > 0";
    var parser_inst = @import("parser.zig").Parser.init(arena.allocator(), query);
    var statement = try parser_inst.parse();

    var analyzer = @import("validator.zig").Analyzer.init(arena.allocator());
    var analysis = try analyzer.analyze(&statement);
    defer analyzer.deinit(&analysis);
    try std.testing.expect(analysis.is_valid);

    var builder = plan.Builder.init(arena.allocator());
    const base_plan = try builder.build(&statement);

    const outer = try arena.allocator().create(plan.Node);
    outer.* = .{
        .project = .{
            .input = base_plan,
            .projections = base_plan.project.projections,
            .output = base_plan.project.output,
        },
    };

    const optimized = try optimize(arena.allocator(), outer);
    try std.testing.expect(optimized == outer);
    try std.testing.expect(meta.activeTag(optimized.project.input.*) != .project);
}

test "optimizer pushes filter through sort" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const query = "select value from metrics where time > 0 order by time";
    var parser_inst = @import("parser.zig").Parser.init(arena.allocator(), query);
    var statement = try parser_inst.parse();

    var analyzer = @import("validator.zig").Analyzer.init(arena.allocator());
    var analysis = try analyzer.analyze(&statement);
    defer analyzer.deinit(&analysis);
    try std.testing.expect(analysis.is_valid);

    var builder = plan.Builder.init(arena.allocator());
    const sort_root = try builder.build(&statement);
    const inner_project = sort_root.sort.input;
    const inner_filter_node = inner_project.project.input;
    const inner_filter = inner_filter_node.filter;

    const extra_preds = try arena.allocator().alloc(*const ast.Expr, 1);
    extra_preds[0] = inner_filter.conjunctive_predicates[0];

    const outer = try arena.allocator().create(plan.Node);
    outer.* = .{
        .filter = .{
            .input = sort_root,
            .predicate = inner_filter.conjunctive_predicates[0],
            .output = plan.nodeOutput(sort_root),
            .conjunctive_predicates = extra_preds,
        },
    };

    const optimized = try optimize(arena.allocator(), outer);
    try std.testing.expect(optimized.* == .sort);
    try std.testing.expect(meta.activeTag(optimized.sort.input.*) == .filter);
    const pushed_filter = optimized.sort.input.filter;
    try std.testing.expectEqual(@as(usize, 1), pushed_filter.conjunctive_predicates.len);
    try std.testing.expect(meta.activeTag(pushed_filter.input.*) == .project);
}

test "optimizer merges nested filters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const query = "select value from metrics where time > 0 and value > 5";
    var parser_inst = @import("parser.zig").Parser.init(arena.allocator(), query);
    var statement = try parser_inst.parse();

    var analyzer = @import("validator.zig").Analyzer.init(arena.allocator());
    var analysis = try analyzer.analyze(&statement);
    defer analyzer.deinit(&analysis);
    try std.testing.expect(analysis.is_valid);

    var builder = plan.Builder.init(arena.allocator());
    const project_root = try builder.build(&statement);
    const base_filter_node = project_root.project.input;
    const base_filter = base_filter_node.filter;

    const extra_preds = try arena.allocator().alloc(*const ast.Expr, 1);
    extra_preds[0] = base_filter.conjunctive_predicates[0];

    const outer_filter = try arena.allocator().create(plan.Node);
    outer_filter.* = .{
        .filter = .{
            .input = base_filter_node,
            .predicate = base_filter.conjunctive_predicates[0],
            .output = base_filter.output,
            .conjunctive_predicates = extra_preds,
        },
    };
    project_root.project.input = outer_filter;

    const optimized = try optimize(arena.allocator(), project_root);
    try std.testing.expect(meta.activeTag(optimized.project.input.*) == .filter);
    const merged_filter = optimized.project.input.filter;
    try std.testing.expectEqual(@as(usize, base_filter.conjunctive_predicates.len + 1), merged_filter.conjunctive_predicates.len);
    const merged_child_tag = meta.activeTag(merged_filter.input.*);
    try std.testing.expect(merged_child_tag == .filter or merged_child_tag == .scan or merged_child_tag == .project);
}

test "optimizer pushes grouping predicate below aggregate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const query = "select tag.host from metrics where tag.host = 'web' group by tag.host";
    var parser_inst = @import("parser.zig").Parser.init(arena.allocator(), query);
    var statement = try parser_inst.parse();

    var analyzer = @import("validator.zig").Analyzer.init(arena.allocator());
    var analysis = try analyzer.analyze(&statement);
    defer analyzer.deinit(&analysis);
    try std.testing.expect(analysis.is_valid);

    var builder = plan.Builder.init(arena.allocator());
    const base_root = try builder.build(&statement);
    // base_root: limit? no -> project -> aggregate -> filter -> scan.
    const aggregate_node = base_root.project.input;
    try std.testing.expect(meta.activeTag(aggregate_node.*) == .aggregate);
    const aggregate_data = aggregate_node.aggregate;

    const group_expr = aggregate_data.groupings[0].expr;
    const pushed_predicates = try arena.allocator().alloc(*const ast.Expr, 1);
    pushed_predicates[0] = group_expr;

    const filter_above = try arena.allocator().create(plan.Node);
    filter_above.* = .{
        .filter = .{
            .input = aggregate_node,
            .predicate = group_expr,
            .output = plan.nodeOutput(aggregate_node),
            .conjunctive_predicates = pushed_predicates,
        },
    };
    base_root.project.input = filter_above;

    const optimized = try optimize(arena.allocator(), base_root);
    try std.testing.expect(optimized.* == .project);
    const agg_after = optimized.project.input;
    try std.testing.expect(meta.activeTag(agg_after.*) == .aggregate);
    const agg_after_data = agg_after.aggregate;
    try std.testing.expect(meta.activeTag(agg_after_data.input.*) == .filter);
    const pushed_filter = agg_after_data.input.filter;
    try std.testing.expectEqual(@as(usize, 1), pushed_filter.conjunctive_predicates.len);
}

test "optimizer recognises alias grouping" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const query = "select tag.host as site from metrics where site = 'web' group by tag.host";
    var parser_inst = @import("parser.zig").Parser.init(arena.allocator(), query);
    var statement = try parser_inst.parse();

    var analyzer = @import("validator.zig").Analyzer.init(arena.allocator());
    var analysis = try analyzer.analyze(&statement);
    defer analyzer.deinit(&analysis);
    try std.testing.expect(analysis.is_valid);

    var builder = plan.Builder.init(arena.allocator());
    const base_root = try builder.build(&statement);
    const project_node = base_root;
    const aggregate_node = project_node.project.input;
    try std.testing.expect(meta.activeTag(aggregate_node.*) == .aggregate);

    const alias_projection = aggregate_node.aggregate.projections[0];
    const predicate_slice = try arena.allocator().alloc(*const ast.Expr, 1);
    predicate_slice[0] = alias_projection.expr;

    const outer_filter = try arena.allocator().create(plan.Node);
    outer_filter.* = .{
        .filter = .{
            .input = aggregate_node,
            .predicate = alias_projection.expr,
            .output = plan.nodeOutput(aggregate_node),
            .conjunctive_predicates = predicate_slice,
        },
    };
    project_node.project.input = outer_filter;

    const optimized = try optimize(arena.allocator(), project_node);
    try std.testing.expect(meta.activeTag(optimized.project.input.*) == .aggregate);
    try std.testing.expect(meta.activeTag(optimized.project.input.aggregate.input.*) == .filter);
}

test "optimizer recognises computed alias grouping" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const query = "select time_bucket(60, time) as bucket from metrics where bucket > time_bucket(60, now()) group by time_bucket(60, time)";
    var parser_inst = @import("parser.zig").Parser.init(arena.allocator(), query);
    var statement = try parser_inst.parse();

    var analyzer = @import("validator.zig").Analyzer.init(arena.allocator());
    var analysis = try analyzer.analyze(&statement);
    defer analyzer.deinit(&analysis);
    try std.testing.expect(analysis.is_valid);

    var builder = plan.Builder.init(arena.allocator());
    const base_root = try builder.build(&statement);
    try std.testing.expect(meta.activeTag(base_root.*) == .project);

    const aggregate_node = base_root.project.input;
    try std.testing.expect(meta.activeTag(aggregate_node.*) == .aggregate);
    const alias_projection = aggregate_node.aggregate.projections[0];

    const predicate_slice = try arena.allocator().alloc(*const ast.Expr, 1);
    predicate_slice[0] = alias_projection.expr;

    const outer_filter = try arena.allocator().create(plan.Node);
    outer_filter.* = .{
        .filter = .{
            .input = base_root,
            .predicate = alias_projection.expr,
            .output = plan.nodeOutput(base_root),
            .conjunctive_predicates = predicate_slice,
        },
    };

    const optimized = try optimize(arena.allocator(), outer_filter);
    try std.testing.expect(meta.activeTag(optimized.*) == .project);
    try std.testing.expect(meta.activeTag(optimized.project.input.*) == .aggregate);
    try std.testing.expect(meta.activeTag(optimized.project.input.aggregate.input.*) == .filter);
}

test "optimizer preserves aggregate predicate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const query = "select avg(value) from metrics where time > 0 group by tag.host";
    var parser_inst = @import("parser.zig").Parser.init(arena.allocator(), query);
    var statement = try parser_inst.parse();

    var analyzer = @import("validator.zig").Analyzer.init(arena.allocator());
    var analysis = try analyzer.analyze(&statement);
    defer analyzer.deinit(&analysis);
    try std.testing.expect(analysis.is_valid);

    var builder = plan.Builder.init(arena.allocator());
    const base_root = try builder.build(&statement);
    const aggregate_node = base_root.project.input;
    try std.testing.expect(meta.activeTag(aggregate_node.*) == .aggregate);
    const aggregate_data = aggregate_node.aggregate;
    const agg_projection = aggregate_data.projections[0];

    const preds = try arena.allocator().alloc(*const ast.Expr, 1);
    preds[0] = agg_projection.expr;

    const outer_filter = try arena.allocator().create(plan.Node);
    outer_filter.* = .{
        .filter = .{
            .input = aggregate_node,
            .predicate = agg_projection.expr,
            .output = plan.nodeOutput(aggregate_node),
            .conjunctive_predicates = preds,
        },
    };
    base_root.project.input = outer_filter;

    const optimized = try optimize(arena.allocator(), base_root);
    try std.testing.expect(meta.activeTag(optimized.project.input.*) == .filter);
    try std.testing.expect(meta.activeTag(optimized.project.input.filter.input.*) == .aggregate);
}

test "optimizer keeps rollup hint" {
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
    const base_root = try builder.build(&statement);
    try std.testing.expect(meta.activeTag(base_root.*) == .project);
    const aggregate_node = base_root.project.input;
    try std.testing.expect(meta.activeTag(aggregate_node.*) == .aggregate);
    try std.testing.expect(aggregate_node.aggregate.rollup_hint != null);

    const preds = try arena.allocator().alloc(*const ast.Expr, 1);
    preds[0] = aggregate_node.aggregate.groupings[0].expr;

    const outer_filter = try arena.allocator().create(plan.Node);
    outer_filter.* = .{
        .filter = .{
            .input = base_root,
            .predicate = aggregate_node.aggregate.groupings[0].expr,
            .output = plan.nodeOutput(base_root),
            .conjunctive_predicates = preds,
        },
    };

    const optimized = try optimize(arena.allocator(), outer_filter);
    try std.testing.expect(meta.activeTag(optimized.*) == .project);
    const agg_after = optimized.project.input;
    try std.testing.expect(meta.activeTag(agg_after.*) == .aggregate);
    try std.testing.expect(agg_after.aggregate.rollup_hint != null);
}
