const std = @import("std");
const lexer = @import("lexer.zig");
const ast = @import("ast.zig");
const common = @import("common.zig");

const ManagedArrayList = std.array_list.Managed;

pub const ParseError = lexer.LexError || std.mem.Allocator.Error || error{
    UnexpectedToken,
    UnexpectedStatement,
    UnexpectedExpression,
    UnterminatedParenthesis,
    InvalidNumber,
};

const ExprList = std.ArrayListUnmanaged(*const ast.Expr);
const ProjectionList = std.ArrayListUnmanaged(ast.Projection);
const IdentifierList = std.ArrayListUnmanaged(ast.Identifier);
const GroupList = std.ArrayListUnmanaged(ast.GroupExpr);
const OrderList = std.ArrayListUnmanaged(ast.OrderExpr);

pub const Parser = struct {
    allocator: std.mem.Allocator,
    lexer: lexer.Lexer,
    source: []const u8,

    current: lexer.Token = undefined,
    has_current: bool = false,
    last: lexer.Token = undefined,
    has_last: bool = false,

    pub fn init(allocator: std.mem.Allocator, source: []const u8) Parser {
        return .{
            .allocator = allocator,
            .lexer = lexer.Lexer.init(allocator, source),
            .source = source,
        };
    }

    pub fn parse(self: *Parser) ParseError!ast.Statement {
        const statement = try self.parseStatement();
        _ = try self.matchKind(.semicolon);
        const final = try self.peek();
        if (final.kind != .eof) return ParseError.UnexpectedToken;
        return statement;
    }

    fn parseStatement(self: *Parser) ParseError!ast.Statement {
        const token = try self.peek();
        if (token.kind != .keyword or token.keyword == null) {
            return ParseError.UnexpectedStatement;
        }

        switch (token.keyword.?) {
            .select => {
                const select_token = try self.advance();
                return self.parseSelect(select_token);
            },
            .insert => {
                const insert_token = try self.advance();
                return self.parseInsert(insert_token);
            },
            .delete => {
                const delete_token = try self.advance();
                return self.parseDelete(delete_token);
            },
            .explain => {
                const explain_token = try self.advance();
                const inner = try self.parseStatement();
                const explain_ptr = try self.allocExplain(.{
                    .target = try self.allocStatement(inner),
                    .span = common.Span.init(explain_token.span.start, self.lastEnd()),
                });
                return ast.Statement{ .explain = explain_ptr };
            },
            else => return ParseError.UnexpectedStatement,
        }
    }

    fn parseSelect(self: *Parser, select_token: lexer.Token) ParseError!ast.Statement {
        var projections = ProjectionList{};
        errdefer projections.deinit(self.allocator);

        try self.parseProjectionList(&projections);

        var selector: ?ast.Selector = null;
        if (try self.matchKeyword(.from)) {
            selector = try self.parseSelector();
        }

        var predicate: ?*const ast.Expr = null;
        if (try self.matchKeyword(.where)) {
            predicate = try self.parseExpression();
        }

        var groupings = GroupList{};
        errdefer groupings.deinit(self.allocator);
        if (try self.matchKeyword(.group)) {
            _ = try self.expectKeyword(.by);
            try self.parseGroupings(&groupings);
        }

        var fill_clause: ?ast.FillClause = null;
        if (try self.matchKeyword(.fill)) {
            fill_clause = try self.parseFillClause();
        }

        var ordering = OrderList{};
        errdefer ordering.deinit(self.allocator);
        if (try self.matchKeyword(.order)) {
            _ = try self.expectKeyword(.by);
            try self.parseOrderings(&ordering);
        }

        var limit_clause: ?ast.LimitClause = null;
        if (try self.matchKeyword(.limit)) {
            limit_clause = try self.parseLimitClause();
        }

        const projections_slice = try projections.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(projections_slice);

        const groupings_slice = try groupings.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(groupings_slice);

        const ordering_slice = try ordering.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(ordering_slice);

        const select_ptr = try self.allocSelect(.{
            .projections = projections_slice,
            .selector = selector,
            .predicate = predicate,
            .groupings = groupings_slice,
            .fill = fill_clause,
            .ordering = ordering_slice,
            .limit = limit_clause,
            .span = common.Span.init(select_token.span.start, self.lastEnd()),
        });

        return ast.Statement{ .select = select_ptr };
    }

    fn parseInsert(self: *Parser, insert_token: lexer.Token) ParseError!ast.Statement {
        _ = try self.expectKeyword(.into);
        const series_ident = try self.parseIdentifierPath();

        var columns = IdentifierList{};
        errdefer columns.deinit(self.allocator);

        if (try self.matchKind(.l_paren)) {
            if (!try self.matchKind(.r_paren)) {
                while (true) {
                    const ident = try self.parseIdentifierPath();
                    try columns.append(self.allocator, ident);
                    if (!(try self.matchKind(.comma))) break;
                }
                _ = try self.expectKind(.r_paren);
            }
        }

        _ = try self.expectKeyword(.values);
        _ = try self.expectKind(.l_paren);

        var values = ExprList{};
        errdefer values.deinit(self.allocator);

        if (!try self.matchKind(.r_paren)) {
            while (true) {
                const expr = try self.parseExpression();
                try values.append(self.allocator, expr);
                if (!(try self.matchKind(.comma))) break;
            }
            _ = try self.expectKind(.r_paren);
        }

        const columns_slice = try columns.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(columns_slice);

        const values_slice = try values.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(values_slice);

        const insert_ptr = try self.allocInsert(.{
            .series = series_ident,
            .columns = columns_slice,
            .values = values_slice,
            .span = common.Span.init(insert_token.span.start, self.lastEnd()),
        });

        return ast.Statement{ .insert = insert_ptr };
    }

    fn parseDelete(self: *Parser, delete_token: lexer.Token) ParseError!ast.Statement {
        _ = try self.expectKeyword(.from);
        const selector = try self.parseSelector();

        var predicate: ?*const ast.Expr = null;
        if (try self.matchKeyword(.where)) {
            predicate = try self.parseExpression();
        }

        const delete_ptr = try self.allocDelete(.{
            .selector = selector,
            .predicate = predicate,
            .span = common.Span.init(delete_token.span.start, self.lastEnd()),
        });

        return ast.Statement{ .delete = delete_ptr };
    }

    fn parseProjectionList(self: *Parser, list: *ProjectionList) ParseError!void {
        while (true) {
            const expr = try self.parseExpression();
            var alias: ?ast.Identifier = null;
            if (try self.matchKeyword(.as)) {
                alias = try self.parseAliasIdentifier();
            } else {
                const token = try self.peek();
                if (self.isAliasCandidate(token)) {
                    alias = try self.parseAliasIdentifier();
                }
            }
            const span = exprSpan(expr);
            try list.append(self.allocator, .{ .expr = expr, .alias = alias, .span = span });
            if (!(try self.matchKind(.comma))) {
                break;
            }
        }
    }

    fn parseAliasIdentifier(self: *Parser) ParseError!ast.Identifier {
        const token = try self.peek();
        if (token.kind == .quoted_identifier) {
            _ = try self.advance();
            return .{ .value = token.lexeme, .quoted = true, .span = token.span };
        }
        if (token.kind == .identifier) {
            _ = try self.advance();
            return .{ .value = token.lexeme, .quoted = false, .span = token.span };
        }
        if (token.kind == .keyword and token.keyword) |kw| {
            // allow keywords not reserved if used as alias?
            switch (kw) {
                .time, .tag => {
                    _ = try self.advance();
                    return .{ .value = token.lexeme, .quoted = false, .span = token.span };
                },
                else => {},
            }
        }
        return ParseError.UnexpectedToken;
    }

    fn isAliasCandidate(self: *Parser, token: lexer.Token) bool {
        _ = self;
        return switch (token.kind) {
            .identifier, .quoted_identifier => true,
            else => false,
        };
    }

    fn parseGroupings(self: *Parser, list: *GroupList) ParseError!void {
        while (true) {
            const expr = try self.parseExpression();
            const span = exprSpan(expr);
            try list.append(self.allocator, .{ .expr = expr, .span = span });
            if (!(try self.matchKind(.comma))) break;
        }
    }

    fn parseFillClause(self: *Parser) ParseError!ast.FillClause {
        const open = try self.expectKind(.l_paren);
        const start = open.span.start;

        var strategy: ast.FillStrategy = undefined;

        const token = try self.peek();
        if (token.kind == .keyword and token.keyword) |kw| {
            switch (kw) {
                .previous => {
                    _ = try self.advance();
                    strategy = .previous;
                },
                .linear => {
                    _ = try self.advance();
                    strategy = .linear;
                },
                .null_literal => {
                    _ = try self.advance();
                    strategy = .null_value;
                },
                else => {
                    const expr = try self.parseExpression();
                    strategy = ast.FillStrategy{ .constant = expr };
                },
            }
        } else {
            const expr = try self.parseExpression();
            strategy = ast.FillStrategy{ .constant = expr };
        }

        const close = try self.expectKind(.r_paren);
        const span = common.Span.init(start, close.span.end);

        return .{ .strategy = strategy, .span = span };
    }

    fn parseOrderings(self: *Parser, list: *OrderList) ParseError!void {
        while (true) {
            const expr = try self.parseExpression();
            var direction: ast.OrderDirection = .asc;
            if (try self.matchKeyword(.desc)) {
                direction = .desc;
            } else if (try self.matchKeyword(.asc)) {
                direction = .asc;
            }
            const span = exprSpan(expr);
            try list.append(self.allocator, .{ .expr = expr, .direction = direction, .span = span });
            if (!(try self.matchKind(.comma))) break;
        }
    }

    fn parseSelector(self: *Parser) ParseError!ast.Selector {
        const series_start = try self.peek();
        const series_ident = try self.parseIdentifierPath();

        if (std.ascii.eqlIgnoreCase(series_ident.value, "by_id")) {
            _ = try self.expectKind(.l_paren);
            const value_token = try self.expectKind(.number);
            const numeric = try self.parseUnsigned(value_token.lexeme);
            _ = try self.expectKind(.r_paren);
            const span = common.Span.init(series_start.span.start, self.lastEnd());
            return .{
                .series = ast.SeriesRef{ .by_id = .{ .value = @as(u64, @intCast(numeric)), .span = span } },
                .tag_filter = null,
                .span = span,
            };
        }

        return .{
            .series = ast.SeriesRef{ .name = series_ident },
            .tag_filter = null,
            .span = common.Span.init(series_start.span.start, self.lastEnd()),
        };
    }

    fn parseLimitClause(self: *Parser) ParseError!ast.LimitClause {
        const limit_token = try self.expectKind(.number);
        const limit_value = try self.parseUnsigned(limit_token.lexeme);

        var offset: ?usize = null;
        if (try self.matchKeyword(.offset)) {
            const offset_token = try self.expectKind(.number);
            offset = try self.parseUnsigned(offset_token.lexeme);
        }

        return .{
            .limit = limit_value,
            .offset = offset,
            .span = common.Span.init(limit_token.span.start, self.lastEnd()),
        };
    }

    fn parseExpression(self: *Parser) ParseError!*const ast.Expr {
        return self.parseLogicalOr();
    }

    fn parseLogicalOr(self: *Parser) ParseError!*const ast.Expr {
        var expr = try self.parseLogicalAnd();
        while (true) {
            if (try self.matchLogicalOr()) |_| {
                const right = try self.parseLogicalAnd();
                expr = try self.makeBinary(ast.BinaryOp.logical_or, expr, right);
                continue;
            }
            break;
        }
        return expr;
    }

    fn parseLogicalAnd(self: *Parser) ParseError!*const ast.Expr {
        var expr = try self.parseEquality();
        while (true) {
            if (try self.matchLogicalAnd()) |_| {
                const right = try self.parseEquality();
                expr = try self.makeBinary(ast.BinaryOp.logical_and, expr, right);
                continue;
            }
            break;
        }
        return expr;
    }

    fn parseEquality(self: *Parser) ParseError!*const ast.Expr {
        var expr = try self.parseComparison();
        while (true) {
            const token = try self.peek();
            const op = switch (token.kind) {
                .equal => ast.BinaryOp.equal,
                .bang_equal => ast.BinaryOp.not_equal,
                .regex_match => ast.BinaryOp.regex_match,
                .regex_not_match => ast.BinaryOp.regex_not_match,
                else => break,
            };
            _ = try self.advance();
            const right = try self.parseComparison();
            expr = try self.makeBinary(op, expr, right);
        }
        return expr;
    }

    fn parseComparison(self: *Parser) ParseError!*const ast.Expr {
        var expr = try self.parseTerm();
        while (true) {
            const token = try self.peek();
            const op = switch (token.kind) {
                .less => ast.BinaryOp.less,
                .less_equal => ast.BinaryOp.less_equal,
                .greater => ast.BinaryOp.greater,
                .greater_equal => ast.BinaryOp.greater_equal,
                else => break,
            };
            _ = try self.advance();
            const right = try self.parseTerm();
            expr = try self.makeBinary(op, expr, right);
        }
        return expr;
    }

    fn parseTerm(self: *Parser) ParseError!*const ast.Expr {
        var expr = try self.parseFactor();
        while (true) {
            const token = try self.peek();
            const op = switch (token.kind) {
                .plus => ast.BinaryOp.add,
                .minus => ast.BinaryOp.subtract,
                else => break,
            };
            _ = try self.advance();
            const right = try self.parseFactor();
            expr = try self.makeBinary(op, expr, right);
        }
        return expr;
    }

    fn parseFactor(self: *Parser) ParseError!*const ast.Expr {
        var expr = try self.parseUnary();
        while (true) {
            const token = try self.peek();
            const op = switch (token.kind) {
                .star => ast.BinaryOp.multiply,
                .slash => ast.BinaryOp.divide,
                .percent => ast.BinaryOp.modulo,
                else => break,
            };
            _ = try self.advance();
            const right = try self.parseUnary();
            expr = try self.makeBinary(op, expr, right);
        }
        return expr;
    }

    fn parseUnary(self: *Parser) ParseError!*const ast.Expr {
        if (try self.matchKind(.minus)) {
            const operand = try self.parseUnary();
            return self.makeUnary(ast.UnaryOp.negate, operand, self.last.span);
        }
        if (try self.matchKeyword(.logical_not)) {
            const operand = try self.parseUnary();
            return self.makeUnary(ast.UnaryOp.logical_not, operand, self.last.span);
        }
        return self.parseCall();
    }

    fn parseCall(self: *Parser) ParseError!*const ast.Expr {
        var expr = try self.parsePrimary();
        while (true) {
            if (try self.matchKind(.l_paren)) {
                expr = try self.finishCall(expr);
                continue;
            }
            break;
        }
        return expr;
    }

    fn parsePrimary(self: *Parser) ParseError!*const ast.Expr {
        const token = try self.peek();
        switch (token.kind) {
            .number => {
                _ = try self.advance();
                return self.makeNumberLiteral(token.lexeme, token.span);
            },
            .string => {
                _ = try self.advance();
                return self.makeStringLiteral(token.lexeme, token.span);
            },
            .identifier, .quoted_identifier => return self.makeIdentifierExpr(try self.parseIdentifierPath()),
            .keyword => {
                switch (token.keyword.?) {
                    .boolean_true => {
                        _ = try self.advance();
                        return self.makeBooleanLiteral(true, token.span);
                    },
                    .boolean_false => {
                        _ = try self.advance();
                        return self.makeBooleanLiteral(false, token.span);
                    },
                    .null_literal => {
                        _ = try self.advance();
                        return self.makeNullLiteral(token.span);
                    },
                    .tag, .time, .now, .previous, .linear => return self.makeIdentifierExpr(try self.parseIdentifierPath()),
                    else => {},
                }
            },
            .l_paren => {
                _ = try self.advance();
                const expr = try self.parseExpression();
                _ = try self.expectKind(.r_paren);
                return expr;
            },
            else => {},
        }
        return ParseError.UnexpectedExpression;
    }

    fn finishCall(self: *Parser, callee_expr: *const ast.Expr) ParseError!*const ast.Expr {
        var args = ExprList{};
        errdefer args.deinit(self.allocator);

        if (!try self.matchKind(.r_paren)) {
            while (true) {
                const arg = try self.parseExpression();
                try args.append(self.allocator, arg);
                if (!(try self.matchKind(.comma))) break;
            }
            _ = try self.expectKind(.r_paren);
        }

        const call_start = exprStart(callee_expr);
        const call_span = common.Span.init(call_start, self.lastEnd());
        const args_slice = try args.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(args_slice);

        const callee_id = switch (callee_expr.*) {
            .identifier => |id| id,
            else => return ParseError.UnexpectedExpression,
        };

        return self.allocExpr(.{
            .call = .{
                .callee = callee_id,
                .args = args_slice,
                .span = call_span,
            },
        });
    }

    fn makeBinary(self: *Parser, op: ast.BinaryOp, left: *const ast.Expr, right: *const ast.Expr) ParseError!*const ast.Expr {
        const span = common.Span.init(exprStart(left), exprEnd(right));
        return self.allocExpr(.{ .binary = .{ .op = op, .left = left, .right = right, .span = span } });
    }

    fn makeUnary(self: *Parser, op: ast.UnaryOp, operand: *const ast.Expr, operator_span: common.Span) ParseError!*const ast.Expr {
        const span = common.Span.init(operator_span.start, exprEnd(operand));
        return self.allocExpr(.{ .unary = .{ .op = op, .operand = operand, .span = span } });
    }

    fn makeIdentifierExpr(self: *Parser, ident: ast.Identifier) ParseError!*const ast.Expr {
        return self.allocExpr(.{ .identifier = ident });
    }

    fn makeNumberLiteral(self: *Parser, text: []const u8, span: common.Span) ParseError!*const ast.Expr {
        if (isFloatLiteral(text)) {
            const value = std.fmt.parseFloat(f64, text) catch return ParseError.InvalidNumber;
            return self.allocExpr(.{ .literal = .{ .value = .{ .float = value }, .span = span } });
        } else {
            const value = std.fmt.parseInt(i64, text, 10) catch return ParseError.InvalidNumber;
            return self.allocExpr(.{ .literal = .{ .value = .{ .integer = value }, .span = span } });
        }
    }

    fn makeStringLiteral(self: *Parser, text: []const u8, span: common.Span) ParseError!*const ast.Expr {
        const decoded = try self.decodeStringLiteral(text);
        return self.allocExpr(.{ .literal = .{ .value = .{ .string = decoded }, .span = span } });
    }

    fn makeBooleanLiteral(self: *Parser, value: bool, span: common.Span) ParseError!*const ast.Expr {
        return self.allocExpr(.{ .literal = .{ .value = .{ .boolean = value }, .span = span } });
    }

    fn makeNullLiteral(self: *Parser, span: common.Span) ParseError!*const ast.Expr {
        return self.allocExpr(.{ .literal = .{ .value = .null, .span = span } });
    }

    fn parseIdentifierPath(self: *Parser) ParseError!ast.Identifier {
        const first = try self.peek();
        if (!isIdentifierToken(first)) return ParseError.UnexpectedToken;

        var any_quoted = first.kind == .quoted_identifier;
        const start = first.span.start;

        _ = try self.advance();
        var end_pos = first.span.end;

        while (try self.matchKind(.period)) {
            const part = try self.peek();
            if (!isIdentifierToken(part)) return ParseError.UnexpectedToken;
            any_quoted = any_quoted or part.kind == .quoted_identifier;
            _ = try self.advance();
            end_pos = part.span.end;
        }

        const slice = self.source[start..end_pos];
        return .{
            .value = slice,
            .quoted = any_quoted,
            .span = common.Span.init(start, end_pos),
        };
    }

    fn matchLogicalOr(self: *Parser) ParseError!?lexer.Token {
        const token = try self.peek();
        if (token.kind == .or_or or (token.kind == .keyword and token.keyword == .logical_or)) {
            return try self.advance();
        }
        return null;
    }

    fn matchLogicalAnd(self: *Parser) ParseError!?lexer.Token {
        const token = try self.peek();
        if (token.kind == .and_and or (token.kind == .keyword and token.keyword == .logical_and)) {
            return try self.advance();
        }
        return null;
    }

    fn decodeStringLiteral(self: *Parser, text: []const u8) ParseError![]const u8 {
        std.debug.assert(text.len >= 2);
        var buf = ManagedArrayList(u8).init(self.allocator);
        errdefer buf.deinit();
        var i: usize = 1;
        while (i < text.len - 1) {
            const ch = text[i];
            if (ch == '\'' and i + 1 < text.len - 1 and text[i + 1] == '\'') {
                try buf.append('\'');
                i += 2;
                continue;
            }
            try buf.append(ch);
            i += 1;
        }
        return buf.toOwnedSlice();
    }

    fn allocExpr(self: *Parser, expr: ast.Expr) ParseError!*const ast.Expr {
        const ptr = try self.allocator.create(ast.Expr);
        ptr.* = expr;
        return ptr;
    }

    fn allocSelect(self: *Parser, select: ast.Select) ParseError!*const ast.Select {
        const ptr = try self.allocator.create(ast.Select);
        ptr.* = select;
        return ptr;
    }

    fn allocInsert(self: *Parser, insert: ast.Insert) ParseError!*const ast.Insert {
        const ptr = try self.allocator.create(ast.Insert);
        ptr.* = insert;
        return ptr;
    }

    fn allocDelete(self: *Parser, delete: ast.Delete) ParseError!*const ast.Delete {
        const ptr = try self.allocator.create(ast.Delete);
        ptr.* = delete;
        return ptr;
    }

    fn allocExplain(self: *Parser, explain: ast.Explain) ParseError!*const ast.Explain {
        const ptr = try self.allocator.create(ast.Explain);
        ptr.* = explain;
        return ptr;
    }

    fn allocStatement(self: *Parser, statement: ast.Statement) ParseError!*const ast.Statement {
        const ptr = try self.allocator.create(ast.Statement);
        ptr.* = statement;
        return ptr;
    }

    fn parseUnsigned(self: *Parser, text: []const u8) ParseError!usize {
        _ = self;
        const slice = text;
        return std.fmt.parseUnsigned(usize, slice, 10) catch ParseError.InvalidNumber;
    }

    fn peek(self: *Parser) ParseError!lexer.Token {
        if (!self.has_current) {
            self.current = try self.lexer.next();
            self.has_current = true;
        }
        return self.current;
    }

    fn advance(self: *Parser) ParseError!lexer.Token {
        const token = try self.peek();
        self.has_current = false;
        self.last = token;
        self.has_last = true;
        return token;
    }

    fn matchKind(self: *Parser, kind: lexer.TokenKind) ParseError!bool {
        const token = try self.peek();
        if (token.kind != kind) return false;
        _ = try self.advance();
        return true;
    }

    fn matchKeyword(self: *Parser, keyword: lexer.Keyword) ParseError!bool {
        const token = try self.peek();
        if (token.kind != .keyword or token.keyword == null or token.keyword.? != keyword) return false;
        _ = try self.advance();
        return true;
    }

    fn expectKind(self: *Parser, kind: lexer.TokenKind) ParseError!lexer.Token {
        const token = try self.peek();
        if (token.kind != kind) return ParseError.UnexpectedToken;
        return try self.advance();
    }

    fn expectKeyword(self: *Parser, keyword: lexer.Keyword) ParseError!lexer.Token {
        const token = try self.peek();
        if (token.kind != .keyword or token.keyword == null or token.keyword.? != keyword) {
            return ParseError.UnexpectedToken;
        }
        return try self.advance();
    }

    fn lastEnd(self: *Parser) usize {
        if (self.has_last) return self.last.span.end;
        return 0;
    }
};

fn isFloatLiteral(text: []const u8) bool {
    return std.mem.indexOfAny(u8, text, ".eE") != null;
}

fn isIdentifierToken(token: lexer.Token) bool {
    if (token.kind == .identifier or token.kind == .quoted_identifier) return true;
    if (token.kind == .keyword and token.keyword != null) {
        return switch (token.keyword.?) {
            .tag, .time, .now, .previous, .linear => true,
            else => false,
        };
    }
    return false;
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

fn exprSpan(expr: *const ast.Expr) common.Span {
    return common.Span.init(exprStart(expr), exprEnd(expr));
}

test "parse simple select" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser_inst = Parser.init(arena.allocator(), "select value from metrics where time > 1 limit 10");
    const statement = try parser_inst.parse();
    try std.testing.expect(statement == .select);
    const select_stmt = statement.select.*;
    try std.testing.expectEqual(@as(usize, 1), select_stmt.projections.len);
    try std.testing.expect(select_stmt.selector != null);
    const selector = select_stmt.selector.?;
    switch (selector.series) {
        .name => |name| try std.testing.expectEqualStrings("metrics", name.value),
        else => return error.TestFailure,
    }
    try std.testing.expect(select_stmt.limit != null);
    try std.testing.expectEqual(@as(usize, 10), select_stmt.limit.?.limit);
    try std.testing.expect(select_stmt.predicate != null);
    try std.testing.expectEqual(@as(usize, 0), select_stmt.groupings.len);
    try std.testing.expect(select_stmt.fill == null);
    try std.testing.expectEqual(@as(usize, 0), select_stmt.ordering.len);
}

test "parse select with alias" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser_inst = Parser.init(arena.allocator(), "select tag.host as site from metrics");
    const statement = try parser_inst.parse();
    try std.testing.expect(statement == .select);
    const select_stmt = statement.select.*;
    try std.testing.expectEqual(@as(usize, 1), select_stmt.projections.len);
    const projection = select_stmt.projections[0];
    try std.testing.expect(projection.alias != null);
    try std.testing.expectEqualStrings("site", projection.alias.?.value);
}

test "parse insert with values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser_inst = Parser.init(arena.allocator(), "insert into metrics values (now(), 42, 'ok')");
    const statement = try parser_inst.parse();
    try std.testing.expect(statement == .insert);
    const insert_stmt = statement.insert.*;
    try std.testing.expectEqual(@as(usize, 0), insert_stmt.columns.len);
    try std.testing.expectEqual(@as(usize, 3), insert_stmt.values.len);
}

test "parse delete statement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser_inst = Parser.init(arena.allocator(), "delete from metrics where value > 10");
    const statement = try parser_inst.parse();
    try std.testing.expect(statement == .delete);
    const delete_stmt = statement.delete.*;
    try std.testing.expect(delete_stmt.predicate != null);
}

test "parse select with group fill order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const query = "select avg(value) from metrics where time >= 0 group by time_bucket(300, time) fill(previous) order by time desc";
    var parser_inst = Parser.init(arena.allocator(), query);
    const statement = try parser_inst.parse();
    try std.testing.expect(statement == .select);
    const select_stmt = statement.select.*;
    try std.testing.expectEqual(@as(usize, 1), select_stmt.groupings.len);
    try std.testing.expect(select_stmt.fill != null);
    try std.testing.expectEqual(select_stmt.ordering.len, @as(usize, 1));

    const fill_clause = select_stmt.fill.?;
    try std.testing.expect(fill_clause.strategy == .previous);

    const order_clause = select_stmt.ordering[0];
    try std.testing.expect(order_clause.direction == .desc);
}
