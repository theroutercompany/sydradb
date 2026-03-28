const std = @import("std");

const ast = @import("../ast.zig");
const common = @import("../common.zig");
const stmt_mod = @import("stmt.zig");

pub const ParameterSlot = usize;

pub const Identifier = stmt_mod.Identifier;
pub const ById = stmt_mod.ById;
pub const LimitClause = stmt_mod.LimitClause;
pub const OrderDirection = stmt_mod.OrderDirection;
pub const IntegerLiteral = stmt_mod.IntegerLiteral;
pub const StringLiteral = stmt_mod.StringLiteral;
pub const ParameterKind = stmt_mod.ParameterKind;
pub const Parameter = stmt_mod.Parameter;
pub const ComparisonOp = stmt_mod.ComparisonOp;

pub const Statement = union(enum) {
    select: Select,
    insert: Insert,
    delete: Delete,
    explain: Explain,

    pub fn kind(self: @This()) stmt_mod.StatementKind {
        return switch (self) {
            .select => .select,
            .insert => .insert,
            .delete => .delete,
            .explain => .explain,
        };
    }

    pub fn span(self: @This()) common.Span {
        return switch (self) {
            .select => |select| select.span,
            .insert => |insert| insert.span,
            .delete => |delete| delete.span,
            .explain => |explain| explain.span,
        };
    }
};

pub const ExplainMode = stmt_mod.ExplainMode;

pub const Explain = struct {
    mode: ExplainMode,
    target: *const Statement,
    span: common.Span,
};

pub const Select = struct {
    projections: []const Projection,
    selector: ?Selector = null,
    predicate: ?*const Expr = null,
    groupings: []const Grouping = &.{},
    ordering: []const Ordering = &.{},
    limit: ?LimitClause = null,
    span: common.Span,
};

pub const Insert = struct {
    target: Identifier,
    columns: []const *const Expr = &.{},
    values: []const *const Expr = &.{},
    span: common.Span,
};

pub const Delete = struct {
    target: Identifier,
    predicate: ?*const Expr = null,
    span: common.Span,
};

pub const Selector = struct {
    series: SeriesRef,
    span: common.Span,
};

pub const SeriesRef = union(enum) {
    name: Identifier,
    by_id: ById,
};

pub const Projection = struct {
    expr: *const Expr,
    alias: ?Identifier = null,
    span: common.Span,
};

pub const Grouping = struct {
    expr: *const Expr,
    span: common.Span,
};

pub const Ordering = struct {
    expr: *const Expr,
    direction: OrderDirection = .asc,
    span: common.Span,
};

pub const Expr = union(enum) {
    identifier: Identifier,
    integer: IntegerLiteral,
    string: StringLiteral,
    parameter: Parameter,
    comparison: Comparison,
    call: Call,

    pub fn span(self: @This()) common.Span {
        return switch (self) {
            .identifier => |identifier| identifier.span,
            .integer => |literal| literal.span,
            .string => |literal| literal.span,
            .parameter => |parameter| parameter.span,
            .comparison => |comparison| comparison.span,
            .call => |call| call.span,
        };
    }
};

pub const Comparison = struct {
    op: ComparisonOp,
    left: *const Expr,
    right: *const Expr,
    span: common.Span,
};

pub const Call = struct {
    callee: Identifier,
    args: []const *const Expr,
    span: common.Span,
};

pub const ParameterBinding = struct {
    slot: ParameterSlot,
    raw: []const u8,
    kind: ParameterKind,
    name: ?[]const u8 = null,
    explicit_index: ?u32 = null,
    span: common.Span,
    occurrences: usize = 1,
};

pub const NamedParameterBinding = struct {
    name: []const u8,
    slot: ParameterSlot,
};

pub const NormalizedStmt = struct {
    statement: Statement,
    parameters: []const ParameterBinding = &.{},
    named_parameters: []const NamedParameterBinding = &.{},

    pub fn kind(self: @This()) stmt_mod.StatementKind {
        return self.statement.kind();
    }

    pub fn span(self: @This()) common.Span {
        return self.statement.span();
    }
};

pub const NormalizeError = std.mem.Allocator.Error || error{
    UnsupportedParameter,
    InvalidInsertColumn,
    UnsupportedAstStatement,
    UnsupportedAstExpression,
    UnsupportedTagFilter,
    UnsupportedFill,
    UnsupportedLiteral,
};

pub fn normalizeFrontendStmt(allocator: std.mem.Allocator, stmt: stmt_mod.FrontendStmt) NormalizeError!NormalizedStmt {
    const normalized_stmt = try normalizeStatement(allocator, stmt);
    var parameters = std.array_list.Managed(ParameterBinding).init(allocator);
    errdefer parameters.deinit();
    var named_parameters = std.array_list.Managed(NamedParameterBinding).init(allocator);
    errdefer named_parameters.deinit();
    var next_slot: usize = 1;
    try collectStatementParameters(allocator, normalized_stmt, &parameters, &named_parameters, &next_slot);
    const owned_parameters = try parameters.toOwnedSlice();
    errdefer allocator.free(owned_parameters);
    const owned_named_parameters = try named_parameters.toOwnedSlice();
    return .{
        .statement = normalized_stmt,
        .parameters = owned_parameters,
        .named_parameters = owned_named_parameters,
    };
}

pub fn normalizeAstStatement(allocator: std.mem.Allocator, statement: *const ast.Statement) NormalizeError!NormalizedStmt {
    const frontend_stmt = try frontendStmtFromAstStatement(allocator, statement);
    return normalizeFrontendStmt(allocator, frontend_stmt);
}

pub fn frontendStmtFromAstStatement(allocator: std.mem.Allocator, statement: *const ast.Statement) NormalizeError!stmt_mod.FrontendStmt {
    return switch (statement.*) {
        .select => |select| .{ .select = try fromAstSelect(allocator, select) },
        .insert => |insert| .{ .insert = try fromAstInsert(allocator, insert) },
        .delete => |delete| .{ .delete = try fromAstDelete(allocator, delete) },
        .explain => |explain| .{ .explain = try fromAstExplain(allocator, explain) },
        .invalid => error.UnsupportedAstStatement,
    };
}

pub fn toAstStatement(allocator: std.mem.Allocator, normalized: NormalizedStmt) NormalizeError!ast.Statement {
    return switch (normalized.statement) {
        .select => |select| .{ .select = try lowerSelect(allocator, select) },
        .insert => |insert| .{ .insert = try lowerInsert(allocator, insert) },
        .delete => |delete| .{ .delete = try lowerDelete(allocator, delete) },
        .explain => |explain| .{ .explain = try lowerExplain(allocator, explain) },
    };
}

fn fromAstSelect(allocator: std.mem.Allocator, select: *const ast.Select) NormalizeError!stmt_mod.Select {
    if (select.fill != null) return error.UnsupportedFill;

    const projections = try allocator.alloc(stmt_mod.Projection, select.projections.len);
    for (select.projections, 0..) |projection, idx| {
        projections[idx] = .{
            .expr = try fromAstExpr(allocator, projection.expr),
            .alias = if (projection.alias) |alias| try cloneIdentifier(allocator, alias) else null,
            .span = projection.span,
        };
    }

    const groupings = try allocator.alloc(stmt_mod.Grouping, select.groupings.len);
    for (select.groupings, 0..) |grouping, idx| {
        groupings[idx] = .{
            .expr = try fromAstExpr(allocator, grouping.expr),
            .span = grouping.span,
        };
    }

    const ordering = try allocator.alloc(stmt_mod.Ordering, select.ordering.len);
    for (select.ordering, 0..) |item, idx| {
        ordering[idx] = .{
            .expr = try fromAstExpr(allocator, item.expr),
            .direction = switch (item.direction) {
                .asc => .asc,
                .desc => .desc,
            },
            .span = item.span,
        };
    }

    return .{
        .projections = projections,
        .selector = if (select.selector) |selector| try fromAstSelector(allocator, selector) else null,
        .predicate = if (select.predicate) |predicate| try fromAstExpr(allocator, predicate) else null,
        .groupings = groupings,
        .ordering = ordering,
        .limit = if (select.limit) |limit| .{
            .limit = limit.limit,
            .offset = limit.offset,
            .span = limit.span,
        } else null,
        .span = select.span,
    };
}

fn fromAstInsert(allocator: std.mem.Allocator, insert: *const ast.Insert) NormalizeError!stmt_mod.Insert {
    const columns = try allocator.alloc(*const stmt_mod.Expr, insert.columns.len);
    for (insert.columns, 0..) |column, idx| {
        const expr = try allocator.create(stmt_mod.Expr);
        expr.* = .{ .identifier = try cloneIdentifier(allocator, column) };
        columns[idx] = expr;
    }

    const values = try allocator.alloc(*const stmt_mod.Expr, insert.values.len);
    for (insert.values, 0..) |value, idx| {
        values[idx] = try fromAstExpr(allocator, value);
    }

    return .{
        .target = try cloneIdentifier(allocator, insert.series),
        .columns = columns,
        .values = values,
        .span = insert.span,
    };
}

fn fromAstDelete(allocator: std.mem.Allocator, delete: *const ast.Delete) NormalizeError!stmt_mod.Delete {
    return .{
        .target = switch (delete.selector.series) {
            .name => |name| try cloneIdentifier(allocator, name),
            .by_id => return error.UnsupportedAstStatement,
        },
        .predicate = if (delete.predicate) |predicate| try fromAstExpr(allocator, predicate) else null,
        .span = delete.span,
    };
}

fn fromAstExplain(allocator: std.mem.Allocator, explain: *const ast.Explain) NormalizeError!stmt_mod.Explain {
    const target = try allocator.create(stmt_mod.FrontendStmt);
    target.* = try frontendStmtFromAstStatement(allocator, explain.target);
    return .{
        .mode = switch (explain.mode) {
            .standard => .standard,
            .bytecode => .bytecode,
        },
        .target = target,
        .span = explain.span,
    };
}

fn fromAstSelector(allocator: std.mem.Allocator, selector: ast.Selector) NormalizeError!stmt_mod.Selector {
    if (selector.tag_filter != null) return error.UnsupportedTagFilter;
    return .{
        .series = switch (selector.series) {
            .name => |name| .{ .name = try cloneIdentifier(allocator, name) },
            .by_id => |by_id| .{ .by_id = .{
                .value = by_id.value,
                .span = by_id.span,
            } },
        },
        .span = selector.span,
    };
}

fn fromAstExpr(allocator: std.mem.Allocator, expr: *const ast.Expr) NormalizeError!*const stmt_mod.Expr {
    const out = try allocator.create(stmt_mod.Expr);
    out.* = switch (expr.*) {
        .identifier => |identifier| .{ .identifier = try cloneIdentifier(allocator, identifier) },
        .literal => |literal| switch (literal.value) {
            .integer => |value| .{ .integer = .{
                .value = value,
                .text = try std.fmt.allocPrint(allocator, "{d}", .{value}),
                .span = literal.span,
            } },
            .string => |value| .{ .string = .{
                .value = try allocator.dupe(u8, value),
                .span = literal.span,
            } },
            else => return error.UnsupportedLiteral,
        },
        .call => |call| blk: {
            const args = try allocator.alloc(*const stmt_mod.Expr, call.args.len);
            for (call.args, 0..) |arg, idx| {
                args[idx] = try fromAstExpr(allocator, arg);
            }
            break :blk .{ .call = .{
                .callee = try cloneIdentifier(allocator, call.callee),
                .args = args,
                .span = call.span,
            } };
        },
        .binary => |binary| blk: {
            const op = switch (binary.op) {
                .equal => stmt_mod.ComparisonOp.equal,
                .not_equal => .not_equal,
                .less => .less,
                .less_equal => .less_equal,
                .greater => .greater,
                .greater_equal => .greater_equal,
                else => return error.UnsupportedAstExpression,
            };
            break :blk .{ .comparison = .{
                .op = op,
                .left = try fromAstExpr(allocator, binary.left),
                .right = try fromAstExpr(allocator, binary.right),
                .span = binary.span,
            } };
        },
        .unary => |unary| switch (unary.op) {
            .negate => try foldUnaryInteger(allocator, unary.operand, unary.span, true),
            .positive => try foldUnaryInteger(allocator, unary.operand, unary.span, false),
            else => return error.UnsupportedAstExpression,
        },
    };
    return out;
}

fn foldUnaryInteger(
    allocator: std.mem.Allocator,
    operand: *const ast.Expr,
    span: common.Span,
    negate: bool,
) NormalizeError!stmt_mod.Expr {
    if (operand.* != .literal or operand.literal.value != .integer) return error.UnsupportedAstExpression;
    const value = if (negate) -operand.literal.value.integer else operand.literal.value.integer;
    return .{ .integer = .{
        .value = value,
        .text = try std.fmt.allocPrint(allocator, "{d}", .{value}),
        .span = span,
    } };
}

fn normalizeStatement(allocator: std.mem.Allocator, stmt: stmt_mod.FrontendStmt) NormalizeError!Statement {
    return switch (stmt) {
        .select => |select| .{ .select = try normalizeSelect(allocator, select) },
        .insert => |insert| .{ .insert = try normalizeInsert(allocator, insert) },
        .delete => |delete| .{ .delete = try normalizeDelete(allocator, delete) },
        .explain => |explain| .{ .explain = try normalizeExplain(allocator, explain) },
    };
}

fn normalizeSelect(allocator: std.mem.Allocator, select: stmt_mod.Select) NormalizeError!Select {
    const projections = try allocator.alloc(Projection, select.projections.len);
    for (select.projections, 0..) |projection, idx| {
        projections[idx] = .{
            .expr = try normalizeExpr(allocator, projection.expr),
            .alias = if (projection.alias) |alias| try cloneIdentifier(allocator, alias) else null,
            .span = projection.span,
        };
    }

    const groupings = try allocator.alloc(Grouping, select.groupings.len);
    for (select.groupings, 0..) |grouping, idx| {
        groupings[idx] = .{
            .expr = try normalizeExpr(allocator, grouping.expr),
            .span = grouping.span,
        };
    }

    const ordering = try allocator.alloc(Ordering, select.ordering.len);
    for (select.ordering, 0..) |item, idx| {
        ordering[idx] = .{
            .expr = try normalizeExpr(allocator, item.expr),
            .direction = item.direction,
            .span = item.span,
        };
    }

    return .{
        .projections = projections,
        .selector = if (select.selector) |selector| try normalizeSelector(allocator, selector) else null,
        .predicate = if (select.predicate) |predicate| try normalizeExpr(allocator, predicate) else null,
        .groupings = groupings,
        .ordering = ordering,
        .limit = select.limit,
        .span = select.span,
    };
}

fn normalizeInsert(allocator: std.mem.Allocator, insert: stmt_mod.Insert) NormalizeError!Insert {
    const columns = try allocator.alloc(*const Expr, insert.columns.len);
    for (insert.columns, 0..) |column, idx| columns[idx] = try normalizeExpr(allocator, column);

    const values = try allocator.alloc(*const Expr, insert.values.len);
    for (insert.values, 0..) |value, idx| values[idx] = try normalizeExpr(allocator, value);

    return .{
        .target = try cloneIdentifier(allocator, insert.target),
        .columns = columns,
        .values = values,
        .span = insert.span,
    };
}

fn normalizeDelete(allocator: std.mem.Allocator, delete: stmt_mod.Delete) NormalizeError!Delete {
    return .{
        .target = try cloneIdentifier(allocator, delete.target),
        .predicate = if (delete.predicate) |predicate| try normalizeExpr(allocator, predicate) else null,
        .span = delete.span,
    };
}

fn normalizeExplain(allocator: std.mem.Allocator, explain: stmt_mod.Explain) NormalizeError!Explain {
    const target = try allocator.create(Statement);
    target.* = try normalizeStatement(allocator, explain.target.*);
    return .{
        .mode = explain.mode,
        .target = target,
        .span = explain.span,
    };
}

fn normalizeSelector(allocator: std.mem.Allocator, selector: stmt_mod.Selector) NormalizeError!Selector {
    return .{
        .series = switch (selector.series) {
            .name => |name| .{ .name = try cloneIdentifier(allocator, name) },
            .by_id => |by_id| .{ .by_id = by_id },
        },
        .span = selector.span,
    };
}

fn cloneIdentifier(allocator: std.mem.Allocator, identifier: anytype) !Identifier {
    return .{
        .value = try allocator.dupe(u8, identifier.value),
        .quoted = identifier.quoted,
        .span = identifier.span,
    };
}

fn normalizeExpr(allocator: std.mem.Allocator, expr: *const stmt_mod.Expr) NormalizeError!*const Expr {
    const out = try allocator.create(Expr);
    out.* = switch (expr.*) {
        .identifier => |identifier| .{ .identifier = try cloneIdentifier(allocator, identifier) },
        .integer => |integer| .{ .integer = .{
            .value = integer.value,
            .text = try allocator.dupe(u8, integer.text),
            .span = integer.span,
        } },
        .string => |string| .{ .string = .{
            .value = try allocator.dupe(u8, string.value),
            .span = string.span,
        } },
        .parameter => |parameter| .{ .parameter = .{
            .raw = try allocator.dupe(u8, parameter.raw),
            .kind = parameter.kind,
            .span = parameter.span,
        } },
        .comparison => |comparison| .{ .comparison = .{
            .op = comparison.op,
            .left = try normalizeExpr(allocator, comparison.left),
            .right = try normalizeExpr(allocator, comparison.right),
            .span = comparison.span,
        } },
        .call => |call| blk: {
            const args = try allocator.alloc(*const Expr, call.args.len);
            for (call.args, 0..) |arg, idx| args[idx] = try normalizeExpr(allocator, arg);
            break :blk .{ .call = .{
                .callee = try cloneIdentifier(allocator, call.callee),
                .args = args,
                .span = call.span,
            } };
        },
    };
    return out;
}

fn collectStatementParameters(
    allocator: std.mem.Allocator,
    stmt: Statement,
    parameters: *std.array_list.Managed(ParameterBinding),
    named_parameters: *std.array_list.Managed(NamedParameterBinding),
    next_slot: *usize,
) !void {
    switch (stmt) {
        .select => |select| {
            for (select.projections) |projection| try collectExprParameters(allocator, projection.expr, parameters, named_parameters, next_slot);
            if (select.predicate) |predicate| try collectExprParameters(allocator, predicate, parameters, named_parameters, next_slot);
            for (select.groupings) |grouping| try collectExprParameters(allocator, grouping.expr, parameters, named_parameters, next_slot);
            for (select.ordering) |ordering| try collectExprParameters(allocator, ordering.expr, parameters, named_parameters, next_slot);
        },
        .insert => |insert| {
            for (insert.columns) |column| try collectExprParameters(allocator, column, parameters, named_parameters, next_slot);
            for (insert.values) |value| try collectExprParameters(allocator, value, parameters, named_parameters, next_slot);
        },
        .delete => |delete| {
            if (delete.predicate) |predicate| try collectExprParameters(allocator, predicate, parameters, named_parameters, next_slot);
        },
        .explain => |explain| try collectStatementParameters(allocator, explain.target.*, parameters, named_parameters, next_slot),
    }
}

fn collectExprParameters(
    allocator: std.mem.Allocator,
    expr: *const Expr,
    parameters: *std.array_list.Managed(ParameterBinding),
    named_parameters: *std.array_list.Managed(NamedParameterBinding),
    next_slot: *usize,
) !void {
    switch (expr.*) {
        .identifier,
        .integer,
        .string,
        => {},
        .parameter => |parameter| try appendParameterBinding(allocator, parameter, parameters, named_parameters, next_slot),
        .comparison => |comparison| {
            try collectExprParameters(allocator, comparison.left, parameters, named_parameters, next_slot);
            try collectExprParameters(allocator, comparison.right, parameters, named_parameters, next_slot);
        },
        .call => |call| for (call.args) |arg| try collectExprParameters(allocator, arg, parameters, named_parameters, next_slot),
    }
}

fn appendParameterBinding(
    allocator: std.mem.Allocator,
    parameter: Parameter,
    parameters: *std.array_list.Managed(ParameterBinding),
    named_parameters: *std.array_list.Managed(NamedParameterBinding),
    next_slot: *usize,
) !void {
    const explicit_index = if (parameter.kind == .positional) parseExplicitIndex(parameter.raw) else null;
    const name = if (parameter.kind == .named) try parameterName(allocator, parameter.raw) else null;
    defer if (name) |owned_name| if (parameter.kind != .named) allocator.free(owned_name);

    if (findExistingBinding(parameters.items, parameter.kind, parameter.raw, name, explicit_index)) |existing_idx| {
        parameters.items[existing_idx].occurrences += 1;
        if (name) |owned_name| allocator.free(owned_name);
        return;
    }

    const slot: usize = if (explicit_index) |idx| blk: {
        const candidate: usize = @intCast(idx);
        if (candidate >= next_slot.*) next_slot.* = candidate + 1;
        break :blk candidate;
    } else blk: {
        const candidate = next_slot.*;
        next_slot.* += 1;
        break :blk candidate;
    };

    var owned_name: ?[]const u8 = null;
    if (name) |parsed_name| {
        owned_name = parsed_name;
        try named_parameters.append(.{
            .name = parsed_name,
            .slot = slot,
        });
    }

    try parameters.append(.{
        .slot = slot,
        .raw = parameter.raw,
        .kind = parameter.kind,
        .name = owned_name,
        .explicit_index = explicit_index,
        .span = parameter.span,
    });
}

fn findExistingBinding(
    bindings: []ParameterBinding,
    kind: ParameterKind,
    raw: []const u8,
    name: ?[]const u8,
    explicit_index: ?u32,
) ?usize {
    for (bindings, 0..) |binding, idx| {
        if (binding.kind != kind) continue;
        if (explicit_index != null and binding.explicit_index == explicit_index) return idx;
        if (name) |value| {
            if (binding.name) |binding_name| {
                if (std.mem.eql(u8, binding_name, value)) return idx;
            }
            continue;
        }
        if (std.mem.eql(u8, binding.raw, raw)) return idx;
    }
    return null;
}

fn parameterName(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const start = if (raw.len != 0 and (raw[0] == '$' or raw[0] == ':' or raw[0] == '@')) @as(usize, 1) else @as(usize, 0);
    return allocator.dupe(u8, raw[start..]);
}

fn parseExplicitIndex(raw: []const u8) ?u32 {
    if (raw.len < 2) return null;
    const payload = raw[1..];
    if (payload.len == 0) return null;
    for (payload) |ch| if (!std.ascii.isDigit(ch)) return null;
    return std.fmt.parseUnsigned(u32, payload, 10) catch null;
}

fn lowerSelect(allocator: std.mem.Allocator, select: Select) NormalizeError!*const ast.Select {
    const projections = try allocator.alloc(ast.Projection, select.projections.len);
    for (select.projections, 0..) |projection, idx| {
        projections[idx] = .{
            .expr = try lowerExpr(allocator, projection.expr),
            .alias = if (projection.alias) |alias| lowerIdentifier(alias) else null,
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

fn lowerInsert(allocator: std.mem.Allocator, insert: Insert) NormalizeError!*const ast.Insert {
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

fn lowerDelete(allocator: std.mem.Allocator, delete: Delete) NormalizeError!*const ast.Delete {
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

fn lowerExplain(allocator: std.mem.Allocator, explain: Explain) NormalizeError!*const ast.Explain {
    const target_stmt = try allocator.create(ast.Statement);
    target_stmt.* = try toAstStatement(allocator, .{ .statement = explain.target.* });

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

fn lowerSelector(selector: Selector) NormalizeError!ast.Selector {
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

fn lowerExpr(allocator: std.mem.Allocator, expr: *const Expr) NormalizeError!*const ast.Expr {
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

fn lowerInsertColumn(expr: *const Expr) NormalizeError!ast.Identifier {
    return switch (expr.*) {
        .identifier => |identifier| lowerIdentifier(identifier),
        else => error.InvalidInsertColumn,
    };
}

fn lowerIdentifier(identifier: Identifier) ast.Identifier {
    return .{
        .value = identifier.value,
        .quoted = identifier.quoted,
        .span = identifier.span,
    };
}

test "normalize frontend stmt preserves parameter inventory" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    const parameter_expr = try arena.allocator().create(stmt_mod.Expr);
    parameter_expr.* = .{ .parameter = .{
        .raw = "$1",
        .kind = .positional,
        .span = .{ .start = 20, .end = 22 },
    } };
    const second_parameter_expr = try arena.allocator().create(stmt_mod.Expr);
    second_parameter_expr.* = .{ .parameter = .{
        .raw = ":host",
        .kind = .named,
        .span = .{ .start = 30, .end = 35 },
    } };
    const predicate = try arena.allocator().create(stmt_mod.Expr);
    predicate.* = .{ .comparison = .{
        .op = .greater_equal,
        .left = parameter_expr,
        .right = second_parameter_expr,
        .span = .{ .start = 20, .end = 35 },
    } };

    const projection_expr = try arena.allocator().create(stmt_mod.Expr);
    projection_expr.* = .{ .identifier = .{
        .value = "value",
        .span = .{ .start = 7, .end = 12 },
    } };

    const normalized = try normalizeFrontendStmt(arena.allocator(), .{
        .select = .{
            .projections = &.{.{ .expr = projection_expr, .span = .{ .start = 7, .end = 12 } }},
            .predicate = predicate,
            .span = .{ .start = 0, .end = 35 },
        },
    });

    try std.testing.expectEqual(@as(usize, 2), normalized.parameters.len);
    try std.testing.expectEqual(@as(usize, 1), normalized.parameters[0].slot);
    try std.testing.expectEqual(@as(?u32, 1), normalized.parameters[0].explicit_index);
    try std.testing.expectEqual(@as(?[]const u8, null), normalized.parameters[0].name);
    try std.testing.expectEqual(@as(usize, 2), normalized.parameters[1].slot);
    try std.testing.expectEqualStrings("host", normalized.named_parameters[0].name);
    try std.testing.expectEqual(@as(usize, 2), normalized.named_parameters[0].slot);
}

test "normalize ast statement preserves aliases and selectors" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    const projection_expr = try arena.allocator().create(ast.Expr);
    projection_expr.* = .{ .identifier = .{
        .value = "value",
        .quoted = false,
        .span = .{ .start = 7, .end = 12 },
    } };

    const select = try arena.allocator().create(ast.Select);
    select.* = .{
        .projections = &.{.{ .expr = projection_expr, .alias = .{
            .value = "reading",
            .quoted = false,
            .span = .{ .start = 16, .end = 23 },
        }, .span = .{ .start = 7, .end = 23 } }},
        .selector = .{
            .series = .{ .by_id = .{
                .value = 41,
                .span = .{ .start = 29, .end = 38 },
            } },
            .tag_filter = null,
            .span = .{ .start = 29, .end = 38 },
        },
        .predicate = null,
        .groupings = &.{},
        .fill = null,
        .ordering = &.{},
        .limit = null,
        .span = .{ .start = 0, .end = 38 },
    };

    const normalized = try normalizeAstStatement(arena.allocator(), &ast.Statement{ .select = select });
    try std.testing.expect(normalized.statement == .select);
    try std.testing.expect(normalized.statement.select.selector != null);
    try std.testing.expect(normalized.statement.select.selector.?.series == .by_id);
    try std.testing.expectEqual(@as(u64, 41), normalized.statement.select.selector.?.series.by_id.value);
    try std.testing.expect(normalized.statement.select.projections[0].alias != null);
    try std.testing.expectEqualStrings("reading", normalized.statement.select.projections[0].alias.?.value);
}
