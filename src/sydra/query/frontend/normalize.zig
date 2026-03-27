const std = @import("std");

const ast = @import("../ast.zig");
const common = @import("../common.zig");
const stmt_mod = @import("stmt.zig");

pub const NormalizeError = std.mem.Allocator.Error || error{
    UnsupportedParameter,
    InvalidInsertColumn,
};

pub fn toAstStatement(allocator: std.mem.Allocator, stmt: stmt_mod.FrontendStmt) NormalizeError!ast.Statement {
    return switch (stmt) {
        .select => |select| .{ .select = try lowerSelect(allocator, select) },
        .insert => |insert| .{ .insert = try lowerInsert(allocator, insert) },
        .delete => |delete| .{ .delete = try lowerDelete(allocator, delete) },
        .explain => |explain| .{ .explain = try lowerExplain(allocator, explain) },
    };
}

fn lowerSelect(allocator: std.mem.Allocator, select: stmt_mod.Select) NormalizeError!*const ast.Select {
    const projections = try allocator.alloc(ast.Projection, select.projections.len);
    for (select.projections, 0..) |projection, idx| {
        projections[idx] = .{
            .expr = try lowerExpr(allocator, projection.expr),
            .span = projection.span,
        };
    }

    const groupings = try allocator.alloc(ast.GroupExpr, select.groupings.len);
    for (select.groupings, 0..) |grouping, idx| {
        groupings[idx] = .{
            .expr = try lowerExpr(allocator, grouping.expr),
            .span = grouping.span,
        };
    }

    const ordering = try allocator.alloc(ast.OrderExpr, select.ordering.len);
    for (select.ordering, 0..) |item, idx| {
        ordering[idx] = .{
            .expr = try lowerExpr(allocator, item.expr),
            .direction = switch (item.direction) {
                .asc => .asc,
                .desc => .desc,
            },
            .span = item.span,
        };
    }

    const node = try allocator.create(ast.Select);
    node.* = .{
        .projections = projections,
        .selector = if (select.selector) |selector| try lowerSelector(selector) else null,
        .predicate = if (select.predicate) |predicate| try lowerExpr(allocator, predicate) else null,
        .groupings = groupings,
        .fill = null,
        .ordering = ordering,
        .limit = if (select.limit) |limit| .{
            .limit = limit.limit,
            .offset = limit.offset,
            .span = limit.span,
        } else null,
        .span = select.span,
    };
    return node;
}

fn lowerInsert(allocator: std.mem.Allocator, insert: stmt_mod.Insert) NormalizeError!*const ast.Insert {
    const columns = try allocator.alloc(ast.Identifier, insert.columns.len);
    for (insert.columns, 0..) |column_expr, idx| {
        columns[idx] = try lowerInsertColumn(column_expr);
    }

    const values = try allocator.alloc(*const ast.Expr, insert.values.len);
    for (insert.values, 0..) |expr, idx| {
        values[idx] = try lowerExpr(allocator, expr);
    }

    const node = try allocator.create(ast.Insert);
    node.* = .{
        .series = lowerIdentifier(insert.target),
        .columns = columns,
        .values = values,
        .span = insert.span,
    };
    return node;
}

fn lowerDelete(allocator: std.mem.Allocator, delete: stmt_mod.Delete) NormalizeError!*const ast.Delete {
    const node = try allocator.create(ast.Delete);
    node.* = .{
        .selector = .{
            .series = .{ .name = lowerIdentifier(delete.target) },
            .tag_filter = null,
            .span = delete.target.span,
        },
        .predicate = if (delete.predicate) |predicate| try lowerExpr(allocator, predicate) else null,
        .span = delete.span,
    };
    return node;
}

fn lowerExplain(allocator: std.mem.Allocator, explain: stmt_mod.Explain) NormalizeError!*const ast.Explain {
    const target_stmt = try allocator.create(ast.Statement);
    target_stmt.* = try toAstStatement(allocator, explain.target.*);

    const node = try allocator.create(ast.Explain);
    node.* = .{
        .mode = switch (explain.mode) {
            .standard => .standard,
            .bytecode => .bytecode,
        },
        .target = target_stmt,
        .span = explain.span,
    };
    return node;
}

fn lowerSelector(selector: stmt_mod.Selector) NormalizeError!ast.Selector {
    return .{
        .series = switch (selector.series) {
            .name => |identifier| .{ .name = lowerIdentifier(identifier) },
            .by_id => |by_id| .{ .by_id = .{
                .value = by_id.value,
                .span = by_id.span,
            } },
        },
        .tag_filter = null,
        .span = selector.span,
    };
}

fn lowerExpr(allocator: std.mem.Allocator, expr: *const stmt_mod.Expr) NormalizeError!*const ast.Expr {
    const node = try allocator.create(ast.Expr);
    node.* = switch (expr.*) {
        .identifier => |identifier| .{ .identifier = lowerIdentifier(identifier) },
        .integer => |integer| .{ .literal = .{
            .value = .{ .integer = integer.value },
            .span = integer.span,
        } },
        .string => |string| .{ .literal = .{
            .value = .{ .string = string.value },
            .span = string.span,
        } },
        .parameter => return error.UnsupportedParameter,
        .comparison => |comparison| .{ .binary = .{
            .op = switch (comparison.op) {
                .equal => .equal,
                .not_equal => .not_equal,
                .less => .less,
                .less_equal => .less_equal,
                .greater => .greater,
                .greater_equal => .greater_equal,
            },
            .left = try lowerExpr(allocator, comparison.left),
            .right = try lowerExpr(allocator, comparison.right),
            .span = comparison.span,
        } },
        .call => |call| blk: {
            const args = try allocator.alloc(*const ast.Expr, call.args.len);
            for (call.args, 0..) |arg, idx| {
                args[idx] = try lowerExpr(allocator, arg);
            }
            break :blk .{ .call = .{
                .callee = lowerIdentifier(call.callee),
                .args = args,
                .span = call.span,
            } };
        },
    };
    return node;
}

fn lowerInsertColumn(expr: *const stmt_mod.Expr) NormalizeError!ast.Identifier {
    return switch (expr.*) {
        .identifier => |identifier| lowerIdentifier(identifier),
        else => error.InvalidInsertColumn,
    };
}

fn lowerIdentifier(identifier: stmt_mod.Identifier) ast.Identifier {
    return .{
        .value = identifier.value,
        .quoted = identifier.quoted,
        .span = identifier.span,
    };
}
