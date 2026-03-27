const std = @import("std");

const common = @import("../common.zig");
const lexer = @import("../lexer.zig");
const parsergen = @import("parsergen.zig");
const stmt_mod = @import("stmt.zig");

const SemanticValue = union(enum) {
    token: TokenValue,
    stmt: stmt_mod.FrontendStmt,
    select: stmt_mod.Select,
    selector: stmt_mod.Selector,
    projection: stmt_mod.Projection,
    projections: []const stmt_mod.Projection,
    expr: *const stmt_mod.Expr,
    exprs: []const *const stmt_mod.Expr,
    groupings: []const stmt_mod.Grouping,
    ordering: []const stmt_mod.Ordering,
    limit: stmt_mod.LimitClause,
};

const TokenValue = struct {
    lexeme: []const u8,
    span: common.Span,
    quoted: bool = false,
};

pub fn buildStmt(
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    tokens: []const lexer.Token,
    tables: *const parsergen.ParserTables,
    artifact: parsergen.ParseArtifact,
) !parsergen.SemanticArtifact(stmt_mod.FrontendStmt) {
    var token_values = try allocator.alloc(SemanticValue, tokens.len);
    defer allocator.free(token_values);

    for (tokens, 0..) |token, idx| {
        token_values[idx] = .{ .token = .{
            .lexeme = token.lexeme,
            .span = token.span,
            .quoted = token.kind == .quoted_identifier,
        } };
    }

    var dispatcher = Dispatcher{ .arena = arena };
    const root = try parsergen.replaySemanticActions(SemanticValue, allocator, tables, token_values, artifact, &dispatcher);
    return .{
        .parse = artifact,
        .stmt = try stmtFromValue(root),
    };
}

const Dispatcher = struct {
    arena: std.mem.Allocator,

    pub fn reduce(self: *@This(), _: std.mem.Allocator, _: u16, action: ?[]const u8, rhs: []const SemanticValue) !SemanticValue {
        const action_name = action orelse return rhs[rhs.len - 1];

        if (std.mem.eql(u8, action_name, "emitComplete()")) return rhs[0];
        if (std.mem.eql(u8, action_name, "emitStatement()")) return rhs[0];
        if (std.mem.eql(u8, action_name, "emitInsert()")) return try self.emitInsert(rhs);
        if (std.mem.eql(u8, action_name, "emitDelete()")) return try self.emitDelete(rhs);
        if (std.mem.eql(u8, action_name, "emitExplain()")) return try self.emitExplain(rhs, .standard);
        if (std.mem.eql(u8, action_name, "emitExplainBytecode()")) return try self.emitExplain(rhs, .bytecode);
        if (std.mem.eql(u8, action_name, "beginSelect()")) return try self.beginSelect(rhs);
        if (std.mem.eql(u8, action_name, "attachSelector()")) return try self.attachSelector(rhs);
        if (std.mem.eql(u8, action_name, "attachPredicate()")) return try self.attachPredicate(rhs);
        if (std.mem.eql(u8, action_name, "appendProjection()")) return try self.appendProjection(rhs);
        if (std.mem.eql(u8, action_name, "emitProjection()")) return try self.emitProjection(rhs);
        if (std.mem.eql(u8, action_name, "emitSelector()")) return try self.emitSelector(rhs);
        if (std.mem.eql(u8, action_name, "emitByIdSelector()")) return try self.emitByIdSelector(rhs);
        if (std.mem.eql(u8, action_name, "emitIdentifier()")) return try self.emitIdentifier(rhs);
        if (std.mem.eql(u8, action_name, "emitNumber()")) return try self.emitNumber(rhs);
        if (std.mem.eql(u8, action_name, "emitString()")) return try self.emitString(rhs);
        if (std.mem.eql(u8, action_name, "emitCall()")) return try self.emitCall(rhs);
        if (std.mem.eql(u8, action_name, "appendExpr()")) return try self.appendExpr(rhs);
        if (std.mem.eql(u8, action_name, "appendGroup()")) return try self.appendGroup(rhs);
        if (std.mem.eql(u8, action_name, "appendOrder()")) return try self.appendOrder(rhs);
        if (std.mem.eql(u8, action_name, "emitLimit()")) return try self.emitLimit(rhs);
        return error.InvalidTrace;
    }

    fn emitInsert(_: *@This(), rhs: []const SemanticValue) !SemanticValue {
        const target = try identifierFromValue(rhs[1]);
        return .{ .stmt = .{
            .insert = .{
                .target = target,
                .span = combinedSpan(rhs),
            },
        } };
    }

    fn emitDelete(_: *@This(), rhs: []const SemanticValue) !SemanticValue {
        const target = try identifierFromValue(rhs[1]);
        return .{ .stmt = .{
            .delete = .{
                .target = target,
                .span = combinedSpan(rhs),
            },
        } };
    }

    fn emitExplain(self: *@This(), rhs: []const SemanticValue, mode: stmt_mod.ExplainMode) !SemanticValue {
        const target_stmt = try stmtFromValue(rhs[rhs.len - 1]);
        const target = try self.arena.create(stmt_mod.FrontendStmt);
        target.* = target_stmt;
        return .{ .stmt = .{
            .explain = .{
                .mode = mode,
                .target = target,
                .span = combinedSpan(rhs),
            },
        } };
    }

    fn beginSelect(_: *@This(), rhs: []const SemanticValue) !SemanticValue {
        return .{ .select = .{
            .projections = try projectionsFromValue(rhs[1]),
            .span = combinedSpan(rhs),
        } };
    }

    fn attachSelector(_: *@This(), rhs: []const SemanticValue) !SemanticValue {
        var select = try selectFromValue(rhs[0]);
        select.selector = try selectorFromValue(rhs[3]);
        select.span = combinedSpan(rhs);
        return .{ .select = select };
    }

    fn attachPredicate(_: *@This(), rhs: []const SemanticValue) !SemanticValue {
        var select = try selectFromValue(rhs[0]);
        select.predicate = try exprFromValue(rhs[5]);
        select.span = combinedSpan(rhs);
        return .{ .select = select };
    }

    fn appendProjection(self: *@This(), rhs: []const SemanticValue) !SemanticValue {
        if (rhs.len == 1) {
            const projection = try projectionFromValue(rhs[0]);
            const owned = try self.arena.alloc(stmt_mod.Projection, 1);
            owned[0] = projection;
            return .{ .projections = owned };
        }

        const existing = try projectionsFromValue(rhs[0]);
        const projection = try projectionFromValue(rhs[2]);
        const owned = try self.arena.alloc(stmt_mod.Projection, existing.len + 1);
        @memcpy(owned[0..existing.len], existing);
        owned[existing.len] = projection;
        return .{ .projections = owned };
    }

    fn emitProjection(_: *@This(), rhs: []const SemanticValue) !SemanticValue {
        const expr = try exprFromValue(rhs[0]);
        return .{ .projection = .{
            .expr = expr,
            .alias = null,
            .span = expr.span(),
        } };
    }

    fn emitSelector(_: *@This(), rhs: []const SemanticValue) !SemanticValue {
        const identifier = try identifierFromValue(rhs[0]);
        return .{ .selector = .{
            .series = .{ .name = identifier },
            .span = identifier.span,
        } };
    }

    fn emitByIdSelector(_: *@This(), rhs: []const SemanticValue) !SemanticValue {
        const token = try tokenFromValue(rhs[2]);
        const value = try std.fmt.parseInt(i64, token.lexeme, 10);
        return .{ .selector = .{
            .series = .{ .by_id = .{
                .value = @intCast(@max(value, 0)),
                .span = token.span,
            } },
            .span = combinedSpan(rhs),
        } };
    }

    fn emitIdentifier(self: *@This(), rhs: []const SemanticValue) !SemanticValue {
        const identifier = try identifierFromValue(rhs[0]);
        const expr = try self.arena.create(stmt_mod.Expr);
        expr.* = .{ .identifier = identifier };
        return .{ .expr = expr };
    }

    fn emitNumber(self: *@This(), rhs: []const SemanticValue) !SemanticValue {
        const token = try tokenFromValue(rhs[0]);
        const value = try std.fmt.parseInt(i64, token.lexeme, 10);
        const expr = try self.arena.create(stmt_mod.Expr);
        expr.* = .{ .integer = .{
            .value = value,
            .text = token.lexeme,
            .span = token.span,
        } };
        return .{ .expr = expr };
    }

    fn emitString(self: *@This(), rhs: []const SemanticValue) !SemanticValue {
        const token = try tokenFromValue(rhs[0]);
        const expr = try self.arena.create(stmt_mod.Expr);
        expr.* = .{ .string = .{
            .value = trimQuotes(token.lexeme),
            .span = token.span,
        } };
        return .{ .expr = expr };
    }

    fn emitCall(self: *@This(), rhs: []const SemanticValue) !SemanticValue {
        const callee = try identifierFromValue(rhs[0]);
        const args = try exprListFromValue(rhs[2]);
        const expr = try self.arena.create(stmt_mod.Expr);
        expr.* = .{ .call = .{
            .callee = callee,
            .args = args,
            .span = combinedSpan(rhs),
        } };
        return .{ .expr = expr };
    }

    fn appendExpr(self: *@This(), rhs: []const SemanticValue) !SemanticValue {
        if (rhs.len == 1) {
            const expr = try exprFromValue(rhs[0]);
            const owned = try self.arena.alloc(*const stmt_mod.Expr, 1);
            owned[0] = expr;
            return .{ .exprs = owned };
        }

        const existing = try exprListFromValue(rhs[0]);
        const expr = try exprFromValue(rhs[2]);
        const owned = try self.arena.alloc(*const stmt_mod.Expr, existing.len + 1);
        @memcpy(owned[0..existing.len], existing);
        owned[existing.len] = expr;
        return .{ .exprs = owned };
    }

    fn appendGroup(self: *@This(), rhs: []const SemanticValue) !SemanticValue {
        const expr = try exprFromValue(rhs[rhs.len - 1]);
        if (rhs.len == 1) {
            const owned = try self.arena.alloc(stmt_mod.Grouping, 1);
            owned[0] = .{ .expr = expr, .span = expr.span() };
            return .{ .groupings = owned };
        }

        const existing = switch (rhs[0]) {
            .groupings => |values| values,
            else => return error.InvalidTrace,
        };
        const owned = try self.arena.alloc(stmt_mod.Grouping, existing.len + 1);
        @memcpy(owned[0..existing.len], existing);
        owned[existing.len] = .{ .expr = expr, .span = expr.span() };
        return .{ .groupings = owned };
    }

    fn appendOrder(self: *@This(), rhs: []const SemanticValue) !SemanticValue {
        const expr = try exprFromValue(rhs[rhs.len - 1]);
        if (rhs.len == 1) {
            const owned = try self.arena.alloc(stmt_mod.Ordering, 1);
            owned[0] = .{ .expr = expr, .span = expr.span() };
            return .{ .ordering = owned };
        }

        const existing = switch (rhs[0]) {
            .ordering => |values| values,
            else => return error.InvalidTrace,
        };
        const owned = try self.arena.alloc(stmt_mod.Ordering, existing.len + 1);
        @memcpy(owned[0..existing.len], existing);
        owned[existing.len] = .{ .expr = expr, .span = expr.span() };
        return .{ .ordering = owned };
    }

    fn emitLimit(_: *@This(), rhs: []const SemanticValue) !SemanticValue {
        const token = try tokenFromValue(rhs[1]);
        const value = try std.fmt.parseInt(i64, token.lexeme, 10);
        return .{ .limit = .{
            .limit = @intCast(@max(value, 0)),
            .span = combinedSpan(rhs),
        } };
    }
};

fn stmtFromValue(value: SemanticValue) !stmt_mod.FrontendStmt {
    return switch (value) {
        .stmt => |stmt| stmt,
        .select => |select| .{ .select = select },
        else => error.InvalidTrace,
    };
}

fn selectFromValue(value: SemanticValue) !stmt_mod.Select {
    return switch (value) {
        .select => |select| select,
        else => error.InvalidTrace,
    };
}

fn selectorFromValue(value: SemanticValue) !stmt_mod.Selector {
    return switch (value) {
        .selector => |selector| selector,
        else => error.InvalidTrace,
    };
}

fn projectionFromValue(value: SemanticValue) !stmt_mod.Projection {
    return switch (value) {
        .projection => |projection| projection,
        else => error.InvalidTrace,
    };
}

fn projectionsFromValue(value: SemanticValue) ![]const stmt_mod.Projection {
    return switch (value) {
        .projections => |values| values,
        else => error.InvalidTrace,
    };
}

fn exprFromValue(value: SemanticValue) !*const stmt_mod.Expr {
    return switch (value) {
        .expr => |expr| expr,
        else => error.InvalidTrace,
    };
}

fn exprListFromValue(value: SemanticValue) ![]const *const stmt_mod.Expr {
    return switch (value) {
        .exprs => |values| values,
        else => error.InvalidTrace,
    };
}

fn identifierFromValue(value: SemanticValue) !stmt_mod.Identifier {
    const token = try tokenFromValue(value);
    return .{
        .value = token.lexeme,
        .quoted = token.quoted,
        .span = token.span,
    };
}

fn integerLiteralFromValue(value: SemanticValue) !stmt_mod.IntegerLiteral {
    return switch ((try exprFromValue(value)).*) {
        .integer => |integer| integer,
        else => error.InvalidTrace,
    };
}

fn tokenFromValue(value: SemanticValue) !TokenValue {
    return switch (value) {
        .token => |token| token,
        else => error.InvalidTrace,
    };
}

fn trimQuotes(value: []const u8) []const u8 {
    if (value.len >= 2 and (value[0] == '"' or value[0] == '\'') and value[value.len - 1] == value[0]) {
        return value[1 .. value.len - 1];
    }
    return value;
}

fn combinedSpan(values: []const SemanticValue) common.Span {
    var first: ?common.Span = null;
    var last: ?common.Span = null;
    for (values) |value| {
        if (spanOf(value)) |span| {
            if (first == null) first = span;
            last = span;
        }
    }
    return if (first != null and last != null) common.Span.init(first.?.start, last.?.end) else common.Span.init(0, 0);
}

fn spanOf(value: SemanticValue) ?common.Span {
    return switch (value) {
        .token => |token| token.span,
        .stmt => |stmt| stmt.span(),
        .select => |select| select.span,
        .selector => |selector| selector.span,
        .projection => |projection| projection.span,
        .projections => |projections| if (projections.len == 0) null else common.Span.init(projections[0].span.start, projections[projections.len - 1].span.end),
        .expr => |expr| expr.span(),
        .exprs => |exprs| if (exprs.len == 0) null else common.Span.init(exprs[0].span().start, exprs[exprs.len - 1].span().end),
        .groupings => |groupings| if (groupings.len == 0) null else common.Span.init(groupings[0].span.start, groupings[groupings.len - 1].span.end),
        .ordering => |ordering| if (ordering.len == 0) null else common.Span.init(ordering[0].span.start, ordering[ordering.len - 1].span.end),
        .limit => |limit| limit.span,
    };
}
