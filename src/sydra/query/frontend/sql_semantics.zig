const std = @import("std");

const common = @import("../common.zig");
const lexer = @import("../lexer.zig");
const literals = @import("../literals.zig");
const parsergen = @import("parsergen.zig");
const stmt_mod = @import("stmt.zig");

const SelectClauses = struct {
    predicate: ?*const stmt_mod.Expr = null,
    groupings: []const stmt_mod.Grouping = &.{},
    ordering: []const stmt_mod.Ordering = &.{},
    limit: ?stmt_mod.LimitClause = null,
};

const SemanticValue = union(enum) {
    token: TokenValue,
    stmt: stmt_mod.FrontendStmt,
    selector: stmt_mod.Selector,
    identifier_name: stmt_mod.Identifier,
    clauses: SelectClauses,
    projection: stmt_mod.Projection,
    projections: []const stmt_mod.Projection,
    expr: *const stmt_mod.Expr,
    exprs: []const *const stmt_mod.Expr,
    ordering: stmt_mod.Ordering,
    ordering_list: []const stmt_mod.Ordering,
    offset: usize,
};

const TokenValue = struct {
    lexeme: []const u8,
    span: common.Span,
    quoted: bool = false,
    parameter_kind: ?stmt_mod.ParameterKind = null,
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
            .parameter_kind = if (token.parameter) |parameter| switch (parameter.kind) {
                .positional => .positional,
                .named => .named,
            } else null,
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
        if (std.mem.eql(u8, action_name, "emitExplain()")) return try self.emitExplain(rhs, .standard);
        if (std.mem.eql(u8, action_name, "emitExplainBytecode()")) return try self.emitExplain(rhs, .bytecode);
        if (std.mem.eql(u8, action_name, "emitSelectConstant()")) return try self.emitSelectConstant(rhs);
        if (std.mem.eql(u8, action_name, "emitSelect()")) return try self.emitSelect(rhs);
        if (std.mem.eql(u8, action_name, "emitInsert()")) return try self.emitInsert(rhs);
        if (std.mem.eql(u8, action_name, "emitInsertValues()")) return try self.emitInsertValues(rhs);
        if (std.mem.eql(u8, action_name, "emitInsertBareValues()")) return try self.emitInsertBareValues(rhs);
        if (std.mem.eql(u8, action_name, "emitDelete()")) return try self.emitDelete(rhs);
        if (std.mem.eql(u8, action_name, "emitQualifiedNameStart()")) return try self.emitQualifiedNameStart(rhs);
        if (std.mem.eql(u8, action_name, "appendQualifiedName()")) return try self.appendQualifiedName(rhs);
        if (std.mem.eql(u8, action_name, "emitSourceName()")) return try self.emitSourceName(rhs);
        if (std.mem.eql(u8, action_name, "emitSourceCall()")) return try self.emitSourceCall(rhs);
        if (std.mem.eql(u8, action_name, "emitEmptyClauses()")) return .{ .clauses = .{} };
        if (std.mem.eql(u8, action_name, "attachWhere()")) return try mergeClauses(rhs);
        if (std.mem.eql(u8, action_name, "attachGroup()")) return try mergeClauses(rhs);
        if (std.mem.eql(u8, action_name, "attachOrder()")) return try mergeClauses(rhs);
        if (std.mem.eql(u8, action_name, "attachLimit()")) return try mergeClauses(rhs);
        if (std.mem.eql(u8, action_name, "attachGroupOrder()")) return try mergeClauses(rhs);
        if (std.mem.eql(u8, action_name, "attachGroupLimit()")) return try mergeClauses(rhs);
        if (std.mem.eql(u8, action_name, "attachOrderLimit()")) return try mergeClauses(rhs);
        if (std.mem.eql(u8, action_name, "attachGroupOrderLimit()")) return try mergeClauses(rhs);
        if (std.mem.eql(u8, action_name, "appendProjection()")) return try self.appendProjection(rhs);
        if (std.mem.eql(u8, action_name, "emitProjection()")) return try self.emitProjection(rhs);
        if (std.mem.eql(u8, action_name, "emitProjectionAlias()")) return try self.emitProjectionAlias(rhs);
        if (std.mem.eql(u8, action_name, "emitStar()")) return try self.emitStar(rhs);
        if (std.mem.eql(u8, action_name, "emitPrimaryExpr()")) return rhs[0];
        if (std.mem.eql(u8, action_name, "emitBinaryExpr()")) return try self.emitBinaryExpr(rhs);
        if (std.mem.eql(u8, action_name, "emitIdentifier()")) return try self.emitIdentifier(rhs);
        if (std.mem.eql(u8, action_name, "emitNumber()")) return try self.emitNumber(rhs);
        if (std.mem.eql(u8, action_name, "emitDuration()")) return try self.emitDuration(rhs);
        if (std.mem.eql(u8, action_name, "emitString()")) return try self.emitString(rhs);
        if (std.mem.eql(u8, action_name, "emitTimestamp()")) return try self.emitTimestamp(rhs);
        if (std.mem.eql(u8, action_name, "emitTrueLiteral()")) return try self.emitBooleanLiteral(rhs, true);
        if (std.mem.eql(u8, action_name, "emitFalseLiteral()")) return try self.emitBooleanLiteral(rhs, false);
        if (std.mem.eql(u8, action_name, "emitNullLiteral()")) return try self.emitNullLiteral(rhs);
        if (std.mem.eql(u8, action_name, "emitParameter()")) return try self.emitParameter(rhs);
        if (std.mem.eql(u8, action_name, "emitParenthesizedExpr()")) return rhs[1];
        if (std.mem.eql(u8, action_name, "emitCall()")) return try self.emitCall(rhs);
        if (std.mem.eql(u8, action_name, "appendExpr()")) return try self.appendExpr(rhs);
        if (std.mem.eql(u8, action_name, "emitWhere()")) return try self.emitWhere(rhs);
        if (std.mem.eql(u8, action_name, "emitGroup()")) return try self.emitGroup(rhs);
        if (std.mem.eql(u8, action_name, "emitOrder()")) return try self.emitOrder(rhs);
        if (std.mem.eql(u8, action_name, "appendOrder()")) return try self.appendOrder(rhs);
        if (std.mem.eql(u8, action_name, "emitOrderTerm()")) return try self.emitOrderTerm(rhs, .asc);
        if (std.mem.eql(u8, action_name, "emitOrderTermAsc()")) return try self.emitOrderTerm(rhs, .asc);
        if (std.mem.eql(u8, action_name, "emitOrderTermDesc()")) return try self.emitOrderTerm(rhs, .desc);
        if (std.mem.eql(u8, action_name, "emitLimit()")) return try self.emitLimit(rhs);
        if (std.mem.eql(u8, action_name, "emitLimitOffset()")) return try self.emitLimitOffset(rhs);
        if (std.mem.eql(u8, action_name, "emitOffset()")) return try self.emitOffset(rhs);
        return error.InvalidTrace;
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

    fn emitSelectConstant(_: *@This(), rhs: []const SemanticValue) !SemanticValue {
        return .{ .stmt = .{
            .select = .{
                .projections = try projectionsFromValue(rhs[1]),
                .span = combinedSpan(rhs),
            },
        } };
    }

    fn emitSelect(_: *@This(), rhs: []const SemanticValue) !SemanticValue {
        const target = try selectorFromValue(rhs[3]);
        const clauses = try clausesFromValue(rhs[4]);
        return .{ .stmt = .{
            .select = .{
                .projections = try projectionsFromValue(rhs[1]),
                .selector = target,
                .predicate = clauses.predicate,
                .groupings = clauses.groupings,
                .ordering = clauses.ordering,
                .limit = clauses.limit,
                .span = combinedSpan(rhs),
            },
        } };
    }

    fn emitInsert(_: *@This(), rhs: []const SemanticValue) !SemanticValue {
        const target = try identifierFromValue(rhs[2]);
        return .{ .stmt = .{
            .insert = .{
                .target = target,
                .columns = try exprListFromValue(rhs[4]),
                .span = combinedSpan(rhs),
            },
        } };
    }

    fn emitInsertValues(_: *@This(), rhs: []const SemanticValue) !SemanticValue {
        const target = try identifierFromValue(rhs[2]);
        return .{ .stmt = .{
            .insert = .{
                .target = target,
                .columns = try exprListFromValue(rhs[4]),
                .values = try exprListFromValue(rhs[8]),
                .span = combinedSpan(rhs),
            },
        } };
    }

    fn emitInsertBareValues(_: *@This(), rhs: []const SemanticValue) !SemanticValue {
        const target = try identifierFromValue(rhs[2]);
        return .{ .stmt = .{
            .insert = .{
                .target = target,
                .values = try exprListFromValue(rhs[5]),
                .span = combinedSpan(rhs),
            },
        } };
    }

    fn emitDelete(_: *@This(), rhs: []const SemanticValue) !SemanticValue {
        const target = try identifierFromValue(rhs[2]);
        const clauses = try clausesFromValue(rhs[3]);
        return .{ .stmt = .{
            .delete = .{
                .target = target,
                .predicate = clauses.predicate,
                .span = combinedSpan(rhs),
            },
        } };
    }

    fn emitQualifiedNameStart(_: *@This(), rhs: []const SemanticValue) !SemanticValue {
        return .{ .identifier_name = try identifierFromValue(rhs[0]) };
    }

    fn appendQualifiedName(self: *@This(), rhs: []const SemanticValue) !SemanticValue {
        const prefix = try identifierFromValue(rhs[0]);
        const suffix = try identifierFromValue(rhs[2]);
        const value = try std.fmt.allocPrint(self.arena, "{s}.{s}", .{ prefix.value, suffix.value });
        return .{ .identifier_name = .{
            .value = value,
            .quoted = prefix.quoted or suffix.quoted,
            .span = combinedSpan(rhs),
        } };
    }

    fn emitSourceName(_: *@This(), rhs: []const SemanticValue) !SemanticValue {
        const name = try identifierFromValue(rhs[0]);
        return .{ .selector = .{
            .series = .{ .name = name },
            .span = name.span,
        } };
    }

    fn emitSourceCall(_: *@This(), rhs: []const SemanticValue) !SemanticValue {
        const callee = try tokenFromValue(rhs[0]);
        if (!std.ascii.eqlIgnoreCase(callee.lexeme, "by_id")) return error.InvalidTrace;
        const number_token = try tokenFromValue(rhs[2]);
        const value = try std.fmt.parseInt(u64, number_token.lexeme, 10);
        return .{ .selector = .{
            .series = .{ .by_id = .{
                .value = value,
                .span = number_token.span,
            } },
            .span = combinedSpan(rhs),
        } };
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

    fn emitProjectionAlias(_: *@This(), rhs: []const SemanticValue) !SemanticValue {
        const expr = try exprFromValue(rhs[0]);
        const alias = try identifierFromValue(rhs[2]);
        return .{ .projection = .{
            .expr = expr,
            .alias = alias,
            .span = combinedSpan(rhs),
        } };
    }

    fn emitStar(self: *@This(), rhs: []const SemanticValue) !SemanticValue {
        const token = try tokenFromValue(rhs[0]);
        const expr = try self.arena.create(stmt_mod.Expr);
        expr.* = .{ .identifier = .{
            .value = token.lexeme,
            .span = token.span,
        } };
        return .{ .projection = .{
            .expr = expr,
            .span = token.span,
        } };
    }

    fn emitBinaryExpr(self: *@This(), rhs: []const SemanticValue) !SemanticValue {
        const left = try exprFromValue(rhs[0]);
        const op_token = try tokenFromValue(rhs[1]);
        const right = try exprFromValue(rhs[2]);
        const expr = try self.arena.create(stmt_mod.Expr);
        expr.* = .{ .comparison = .{
            .op = try comparisonOp(op_token.lexeme),
            .left = left,
            .right = right,
            .span = combinedSpan(rhs),
        } };
        return .{ .expr = expr };
    }

    fn emitIdentifier(self: *@This(), rhs: []const SemanticValue) !SemanticValue {
        const identifier = try identifierFromValue(rhs[0]);
        const expr = try self.arena.create(stmt_mod.Expr);
        expr.* = .{ .identifier = identifier };
        return .{ .expr = expr };
    }

    fn emitNumber(self: *@This(), rhs: []const SemanticValue) !SemanticValue {
        const token = try tokenFromValue(rhs[0]);
        const expr = try self.arena.create(stmt_mod.Expr);
        if (literals.isFloatLiteral(token.lexeme)) {
            expr.* = .{ .float = .{
                .value = try std.fmt.parseFloat(f64, token.lexeme),
                .text = token.lexeme,
                .span = token.span,
            } };
        } else {
            expr.* = .{ .integer = .{
                .value = try std.fmt.parseInt(i64, token.lexeme, 10),
                .text = token.lexeme,
                .span = token.span,
            } };
        }
        return .{ .expr = expr };
    }

    fn emitDuration(self: *@This(), rhs: []const SemanticValue) !SemanticValue {
        const token = try tokenFromValue(rhs[0]);
        const expr = try self.arena.create(stmt_mod.Expr);
        expr.* = .{ .duration = .{
            .value = try literals.parseDurationSeconds(token.lexeme),
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

    fn emitTimestamp(self: *@This(), rhs: []const SemanticValue) !SemanticValue {
        const token = try tokenFromValue(rhs[0]);
        const expr = try self.arena.create(stmt_mod.Expr);
        expr.* = .{ .timestamp = .{
            .value = try literals.parseTimestampSeconds(token.lexeme),
            .text = token.lexeme,
            .span = token.span,
        } };
        return .{ .expr = expr };
    }

    fn emitBooleanLiteral(self: *@This(), rhs: []const SemanticValue, value: bool) !SemanticValue {
        const token = try tokenFromValue(rhs[0]);
        const expr = try self.arena.create(stmt_mod.Expr);
        expr.* = .{ .boolean = .{
            .value = value,
            .span = token.span,
        } };
        return .{ .expr = expr };
    }

    fn emitNullLiteral(self: *@This(), rhs: []const SemanticValue) !SemanticValue {
        const token = try tokenFromValue(rhs[0]);
        const expr = try self.arena.create(stmt_mod.Expr);
        expr.* = .{ .null_value = .{ .span = token.span } };
        return .{ .expr = expr };
    }

    fn emitParameter(self: *@This(), rhs: []const SemanticValue) !SemanticValue {
        const token = try tokenFromValue(rhs[0]);
        const expr = try self.arena.create(stmt_mod.Expr);
        expr.* = .{ .parameter = .{
            .raw = token.lexeme,
            .kind = token.parameter_kind orelse return error.InvalidTrace,
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

    fn emitWhere(_: *@This(), rhs: []const SemanticValue) !SemanticValue {
        return .{ .clauses = .{
            .predicate = try exprFromValue(rhs[1]),
        } };
    }

    fn emitGroup(self: *@This(), rhs: []const SemanticValue) !SemanticValue {
        const exprs = try exprListFromValue(rhs[2]);
        const groupings = try self.arena.alloc(stmt_mod.Grouping, exprs.len);
        for (exprs, 0..) |expr, idx| {
            groupings[idx] = .{ .expr = expr, .span = expr.span() };
        }
        return .{ .clauses = .{
            .groupings = groupings,
        } };
    }

    fn emitOrder(_: *@This(), rhs: []const SemanticValue) !SemanticValue {
        return .{ .clauses = .{
            .ordering = try orderingListFromValue(rhs[2]),
        } };
    }

    fn appendOrder(self: *@This(), rhs: []const SemanticValue) !SemanticValue {
        if (rhs.len == 1) {
            const item = try orderingFromValue(rhs[0]);
            const owned = try self.arena.alloc(stmt_mod.Ordering, 1);
            owned[0] = item;
            return .{ .ordering_list = owned };
        }
        const existing = try orderingListFromValue(rhs[0]);
        const item = try orderingFromValue(rhs[2]);
        const owned = try self.arena.alloc(stmt_mod.Ordering, existing.len + 1);
        @memcpy(owned[0..existing.len], existing);
        owned[existing.len] = item;
        return .{ .ordering_list = owned };
    }

    fn emitOrderTerm(_: *@This(), rhs: []const SemanticValue, direction: stmt_mod.OrderDirection) !SemanticValue {
        const expr = try exprFromValue(rhs[0]);
        return .{ .ordering = .{
            .expr = expr,
            .direction = direction,
            .span = combinedSpan(rhs),
        } };
    }

    fn emitLimit(_: *@This(), rhs: []const SemanticValue) !SemanticValue {
        const token = try tokenFromValue(rhs[1]);
        const limit_value = try std.fmt.parseInt(i64, token.lexeme, 10);
        return .{ .clauses = .{
            .limit = .{
                .limit = @intCast(@max(limit_value, 0)),
                .span = combinedSpan(rhs),
            },
        } };
    }

    fn emitLimitOffset(_: *@This(), rhs: []const SemanticValue) !SemanticValue {
        const token = try tokenFromValue(rhs[1]);
        const limit_value = try std.fmt.parseInt(i64, token.lexeme, 10);
        const offset = try offsetFromValue(rhs[2]);
        return .{ .clauses = .{
            .limit = .{
                .limit = @intCast(@max(limit_value, 0)),
                .offset = offset,
                .span = combinedSpan(rhs),
            },
        } };
    }

    fn emitOffset(_: *@This(), rhs: []const SemanticValue) !SemanticValue {
        const token = try tokenFromValue(rhs[1]);
        const offset_value = try std.fmt.parseInt(i64, token.lexeme, 10);
        return .{ .offset = @intCast(@max(offset_value, 0)) };
    }
};

fn mergeClauses(values: []const SemanticValue) !SemanticValue {
    var merged = SelectClauses{};
    for (values) |value| switch (value) {
        .clauses => |clauses| {
            if (clauses.predicate) |predicate| merged.predicate = predicate;
            if (clauses.groupings.len != 0) merged.groupings = clauses.groupings;
            if (clauses.ordering.len != 0) merged.ordering = clauses.ordering;
            if (clauses.limit) |limit| merged.limit = limit;
        },
        else => {},
    };
    return .{ .clauses = merged };
}

fn stmtFromValue(value: SemanticValue) !stmt_mod.FrontendStmt {
    return switch (value) {
        .stmt => |stmt| stmt,
        else => error.InvalidTrace,
    };
}

fn clausesFromValue(value: SemanticValue) !SelectClauses {
    return switch (value) {
        .clauses => |clauses| clauses,
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

fn orderingFromValue(value: SemanticValue) !stmt_mod.Ordering {
    return switch (value) {
        .ordering => |ordering| ordering,
        else => error.InvalidTrace,
    };
}

fn orderingListFromValue(value: SemanticValue) ![]const stmt_mod.Ordering {
    return switch (value) {
        .ordering_list => |values| values,
        else => error.InvalidTrace,
    };
}

fn offsetFromValue(value: SemanticValue) !usize {
    return switch (value) {
        .offset => |offset| offset,
        else => error.InvalidTrace,
    };
}

fn identifierFromValue(value: SemanticValue) !stmt_mod.Identifier {
    return switch (value) {
        .identifier_name => |identifier| identifier,
        else => blk: {
            const token = try tokenFromValue(value);
            break :blk .{
                .value = token.lexeme,
                .quoted = token.quoted,
                .span = token.span,
            };
        },
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

fn comparisonOp(text: []const u8) !stmt_mod.ComparisonOp {
    if (std.mem.eql(u8, text, "=")) return .equal;
    if (std.mem.eql(u8, text, "!=")) return .not_equal;
    if (std.mem.eql(u8, text, "<")) return .less;
    if (std.mem.eql(u8, text, "<=")) return .less_equal;
    if (std.mem.eql(u8, text, ">")) return .greater;
    if (std.mem.eql(u8, text, ">=")) return .greater_equal;
    if (std.ascii.eqlIgnoreCase(text, "and")) return .logical_and;
    if (std.ascii.eqlIgnoreCase(text, "or")) return .logical_or;
    return error.InvalidTrace;
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
        .selector => |selector| selector.span,
        .identifier_name => |identifier| identifier.span,
        .clauses => |clauses| if (clauses.limit) |limit| limit.span else if (clauses.ordering.len != 0) common.Span.init(clauses.ordering[0].span.start, clauses.ordering[clauses.ordering.len - 1].span.end) else if (clauses.groupings.len != 0) common.Span.init(clauses.groupings[0].span.start, clauses.groupings[clauses.groupings.len - 1].span.end) else if (clauses.predicate) |predicate| predicate.span() else null,
        .projection => |projection| projection.span,
        .projections => |values| if (values.len == 0) null else common.Span.init(values[0].span.start, values[values.len - 1].span.end),
        .expr => |expr| expr.span(),
        .exprs => |values| if (values.len == 0) null else common.Span.init(values[0].span().start, values[values.len - 1].span().end),
        .ordering => |ordering| ordering.span,
        .ordering_list => |values| if (values.len == 0) null else common.Span.init(values[0].span.start, values[values.len - 1].span.end),
        .offset => null,
    };
}
