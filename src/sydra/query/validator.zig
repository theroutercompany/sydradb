const std = @import("std");
const ast = @import("ast.zig");
const errors = @import("errors.zig");
const functions = @import("functions.zig");
const common = @import("common.zig");
const infer = @import("type_inference.zig");

pub const AnalyzeError = std.mem.Allocator.Error;

pub const AnalyzeResult = struct {
    diagnostics: errors.DiagnosticList = .{},
    is_valid: bool = false,
};

pub const Analyzer = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Analyzer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Analyzer, result: *AnalyzeResult) void {
        for (result.diagnostics.items) |diag| {
            self.allocator.free(diag.message);
        }
        result.diagnostics.deinit(self.allocator);
        result.* = .{};
    }

    pub fn analyze(self: *Analyzer, statement: *ast.Statement) AnalyzeError!AnalyzeResult {
        var result = AnalyzeResult{};
        try self.validateStatement(statement, &result);
        result.is_valid = result.diagnostics.items.len == 0;
        return result;
    }

    fn validateStatement(self: *Analyzer, statement: *const ast.Statement, result: *AnalyzeResult) AnalyzeError!void {
        switch (statement.*) {
            .invalid => |invalid| {
                try self.addDiagnostic(result, .invalid_syntax, "invalid statement", invalid.span);
            },
            .select => |select_ptr| {
                try self.validateSelect(select_ptr, result);
            },
            .insert => |insert_ptr| {
                try self.validateInsert(insert_ptr, result);
            },
            .delete => |delete_ptr| {
                try self.validateDelete(delete_ptr, result);
            },
            .explain => |explain_ptr| {
                try self.validateStatement(explain_ptr.target, result);
            },
        }
    }

    fn validateSelect(self: *Analyzer, select: *const ast.Select, result: *AnalyzeResult) AnalyzeError!void {
        const requires_time_predicate = selectRequiresTimePredicate(select);
        if (select.predicate) |pred| {
            const predicate_has_time = try self.visitExpression(pred, result);
            if (requires_time_predicate and !predicate_has_time) {
                try self.addDiagnostic(result, .time_range_required, "time range predicate is required", exprSpan(pred));
            }
        } else if (requires_time_predicate) {
            try self.addDiagnostic(result, .time_range_required, "select requires time predicate", select.span);
        }

        for (select.projections) |proj| {
            _ = try self.visitExpression(proj.expr, result);
        }

        for (select.groupings) |group_expr| {
            _ = try self.visitExpression(group_expr.expr, result);
        }

        if (select.fill) |fill_clause| {
            switch (fill_clause.strategy) {
                .constant => |expr| {
                    _ = try self.visitExpression(expr, result);
                },
                else => {},
            }
        }

        for (select.ordering) |order_expr| {
            _ = try self.visitExpression(order_expr.expr, result);
        }
    }

    fn validateInsert(self: *Analyzer, insert_stmt: *const ast.Insert, result: *AnalyzeResult) AnalyzeError!void {
        for (insert_stmt.values) |expr| {
            _ = try self.visitExpression(expr, result);
        }
    }

    fn validateDelete(self: *Analyzer, delete_stmt: *const ast.Delete, result: *AnalyzeResult) AnalyzeError!void {
        if (delete_stmt.predicate) |pred| {
            const has_time = try self.visitExpression(pred, result);
            if (!has_time) {
                try self.addDiagnostic(result, .time_range_required, "delete requires time predicate", exprSpan(pred));
            }
        } else {
            try self.addDiagnostic(result, .time_range_required, "delete requires time predicate", delete_stmt.span);
        }
    }

    fn visitExpression(self: *Analyzer, expr: *const ast.Expr, result: *AnalyzeResult) AnalyzeError!bool {
        return switch (expr.*) {
            .identifier => |ident| {
                return identifierIsTime(ident);
            },
            .literal => |literal| {
                _ = literal;
                return false;
            },
            .unary => |unary| {
                return try self.visitExpression(unary.operand, result);
            },
            .binary => |binary| {
                const left = try self.visitExpression(binary.left, result);
                const right = try self.visitExpression(binary.right, result);
                return left or right;
            },
            .call => |call| {
                var has_time = false;
                for (call.args) |arg| {
                    if (try self.visitExpression(arg, result)) {
                        has_time = true;
                    }
                }

                if (functions.lookup(call.callee.value) == null) {
                    const msg = try std.fmt.allocPrint(self.allocator, "unknown function '{s}'", .{call.callee.value});
                    defer self.allocator.free(msg);
                    try self.addDiagnostic(result, .invalid_syntax, msg, call.span);
                }

                return has_time;
            },
        };
    }

    fn addDiagnostic(self: *Analyzer, result: *AnalyzeResult, code: errors.ErrorCode, message: []const u8, span: common.Span) AnalyzeError!void {
        const diag = try errors.initDiagnostic(self.allocator, code, message, span);
        try result.diagnostics.append(self.allocator, diag);
    }
};

fn selectRequiresTimePredicate(select: *const ast.Select) bool {
    if (select.selector == null) return false;
    if (select.groupings.len != 0) return false;
    if (!projectionsNeedTimePredicate(select.projections) and
        !orderingNeedsTimePredicate(select.ordering) and
        !predicateNeedsTimePredicate(select.predicate))
    {
        return false;
    }
    return true;
}

fn projectionsNeedTimePredicate(projections: []const ast.Projection) bool {
    for (projections) |projection| {
        if (!projectionIsMetadataOnly(projection.expr)) return true;
    }
    return false;
}

fn orderingNeedsTimePredicate(ordering: []const ast.OrderExpr) bool {
    for (ordering) |order_expr| {
        if (exprTouchesPointData(order_expr.expr)) return true;
    }
    return false;
}

fn predicateNeedsTimePredicate(predicate: ?*const ast.Expr) bool {
    if (predicate) |expr| return exprTouchesPointData(expr);
    return false;
}

fn projectionIsMetadataOnly(expr: *const ast.Expr) bool {
    return switch (expr.*) {
        .identifier => |ident| hasTagPrefix(ident.value),
        else => false,
    };
}

fn exprTouchesPointData(expr: *const ast.Expr) bool {
    return switch (expr.*) {
        .identifier => |ident| blk: {
            const segment = trailingSegment(ident.value);
            break :blk std.ascii.eqlIgnoreCase(segment, "time") or std.ascii.eqlIgnoreCase(segment, "value");
        },
        .literal => false,
        .unary => |unary| exprTouchesPointData(unary.operand),
        .binary => |binary| exprTouchesPointData(binary.left) or exprTouchesPointData(binary.right),
        .call => |call| blk: {
            for (call.args) |arg| {
                if (exprTouchesPointData(arg)) break :blk true;
            }
            break :blk false;
        },
    };
}

fn identifierIsTime(ident: ast.Identifier) bool {
    return std.ascii.eqlIgnoreCase(trailingSegment(ident.value), "time");
}

fn trailingSegment(slice: []const u8) []const u8 {
    if (slice.len == 0) return slice;
    var start: usize = 0;
    var idx = slice.len;
    while (idx > 0) {
        idx -= 1;
        if (slice[idx] == '.') {
            start = idx + 1;
            break;
        }
    }
    return slice[start..];
}

fn hasTagPrefix(slice: []const u8) bool {
    const dot = std.mem.indexOfScalar(u8, slice, '.') orelse return false;
    return std.ascii.eqlIgnoreCase(slice[0..dot], "tag");
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

test "analyzer returns failure on missing time predicate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser_inst = @import("parser.zig").Parser.init(arena.allocator(), "select value from metrics");
    var stmt = try parser_inst.parse();

    var analyzer = Analyzer.init(arena.allocator());
    var result = try analyzer.analyze(&stmt);
    defer analyzer.deinit(&result);
    try std.testing.expect(!result.is_valid);
    try std.testing.expectEqual(@as(usize, 1), result.diagnostics.items.len);
    try std.testing.expect(result.diagnostics.items[0].code == .time_range_required);
}

test "analyzer rejects unknown function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser_inst = @import("parser.zig").Parser.init(arena.allocator(), "select foo(value) from metrics where time > 0");
    var stmt = try parser_inst.parse();

    var analyzer = Analyzer.init(arena.allocator());
    var result = try analyzer.analyze(&stmt);
    defer analyzer.deinit(&result);
    try std.testing.expect(!result.is_valid);
    try std.testing.expect(result.diagnostics.items.len >= 1);
    var saw_unknown = false;
    for (result.diagnostics.items) |diag| {
        if (diag.code == .invalid_syntax) saw_unknown = true;
    }
    try std.testing.expect(saw_unknown);
}

test "analyzer accepts select with group fill order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const query = "select avg(value) from metrics where time >= 0 group by time_bucket(300, time) fill(previous) order by time desc";
    var parser_inst = @import("parser.zig").Parser.init(arena.allocator(), query);
    var stmt = try parser_inst.parse();

    var analyzer = Analyzer.init(arena.allocator());
    var result = try analyzer.analyze(&stmt);
    defer analyzer.deinit(&result);
    try std.testing.expect(result.is_valid);
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.len);
}
