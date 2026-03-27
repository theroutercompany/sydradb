const std = @import("std");

const ast = @import("ast.zig");
const plan = @import("plan.zig");
const value_mod = @import("value.zig");

pub const Value = value_mod.Value;

pub const EvalError = value_mod.ConvertError || error{
    UnsupportedExpression,
    DivisionByZero,
};

pub const Resolver = struct {
    context: *const anyopaque,
    getIdentifier: *const fn (*const anyopaque, ast.Identifier) EvalError!Value,
    evalCall: *const fn (*const anyopaque, ast.Call, *const Resolver) EvalError!Value,
};

pub const RowContext = struct {
    schema: []const plan.ColumnInfo,
    values: []const Value,
};

pub fn evaluate(expr: *const ast.Expr, resolver: *const Resolver) EvalError!Value {
    return switch (expr.*) {
        .literal => |lit| literalToValue(lit),
        .identifier => |ident| try resolver.getIdentifier(resolver.context, ident),
        .unary => |unary| blk: {
            const operand = try evaluate(unary.operand, resolver);
            break :blk evaluateUnary(unary, operand);
        },
        .binary => |binary| try evaluateBinary(binary, resolver),
        .call => |call| try resolver.evalCall(resolver.context, call, resolver),
    };
}

pub fn evaluateBoolean(expr: *const ast.Expr, resolver: *const Resolver) EvalError!bool {
    const value = try evaluate(expr, resolver);
    return switch (value) {
        .boolean => |b| b,
        else => EvalError.UnsupportedExpression,
    };
}

pub fn evaluateRow(expr: *const ast.Expr, ctx: *const RowContext) EvalError!Value {
    const resolver = rowResolver(ctx);
    return evaluate(expr, &resolver);
}

pub fn evaluateRowBoolean(expr: *const ast.Expr, ctx: *const RowContext) EvalError!bool {
    const resolver = rowResolver(ctx);
    return evaluateBoolean(expr, &resolver);
}

pub fn rowResolver(ctx: *const RowContext) Resolver {
    return Resolver{
        .context = ctx,
        .getIdentifier = rowGetIdentifier,
        .evalCall = rowEvalCall,
    };
}

fn rowGetIdentifier(ctx_ptr: *const anyopaque, ident: ast.Identifier) EvalError!Value {
    const ctx = @as(*const RowContext, @ptrCast(@alignCast(ctx_ptr)));
    const name = ident.value;
    const unqualified = trailingSegment(name);
    for (ctx.schema, 0..) |column, idx| {
        if (namesEqual(column.name, name) or namesEqual(column.name, unqualified)) {
            return ctx.values[idx];
        }
        if (column.expr.* == .identifier) {
            const expr_ident = column.expr.identifier;
            if (namesEqual(expr_ident.value, name) or namesEqual(expr_ident.value, unqualified)) {
                return ctx.values[idx];
            }
        }
    }
    return EvalError.UnsupportedExpression;
}

fn rowEvalCall(ctx_ptr: *const anyopaque, call: ast.Call, resolver: *const Resolver) EvalError!Value {
    _ = ctx_ptr;
    return evaluateScalarCall(call, resolver);
}

fn evaluateUnary(unary: ast.Unary, operand: Value) EvalError!Value {
    return switch (unary.op) {
        .logical_not => Value{ .boolean = !(try operand.asBool()) },
        .negate => Value{ .float = -(try operand.asFloat()) },
        .positive => Value{ .float = try operand.asFloat() },
    };
}

fn evaluateBinary(binary: ast.Binary, resolver: *const Resolver) EvalError!Value {
    switch (binary.op) {
        .logical_and => {
            const left = try evaluateBoolean(binary.left, resolver);
            if (!left) return Value{ .boolean = false };
            const right = try evaluateBoolean(binary.right, resolver);
            return Value{ .boolean = right };
        },
        .logical_or => {
            const left = try evaluateBoolean(binary.left, resolver);
            if (left) return Value{ .boolean = true };
            const right = try evaluateBoolean(binary.right, resolver);
            return Value{ .boolean = right };
        },
        else => {},
    }

    const left = try evaluate(binary.left, resolver);
    const right = try evaluate(binary.right, resolver);

    return switch (binary.op) {
        .add => Value{ .float = (try left.asFloat()) + (try right.asFloat()) },
        .subtract => Value{ .float = (try left.asFloat()) - (try right.asFloat()) },
        .multiply => Value{ .float = (try left.asFloat()) * (try right.asFloat()) },
        .divide => blk: {
            const divisor = try right.asFloat();
            if (divisor == 0) break :blk EvalError.DivisionByZero;
            break :blk Value{ .float = (try left.asFloat()) / divisor };
        },
        .modulo => Value{ .integer = @mod(try left.asInt(), try right.asInt()) },
        .equal => Value{ .boolean = Value.equals(left, right) },
        .not_equal => Value{ .boolean = !Value.equals(left, right) },
        .less => Value{ .boolean = (try left.asFloat()) < (try right.asFloat()) },
        .less_equal => Value{ .boolean = (try left.asFloat()) <= (try right.asFloat()) },
        .greater => Value{ .boolean = (try left.asFloat()) > (try right.asFloat()) },
        .greater_equal => Value{ .boolean = (try left.asFloat()) >= (try right.asFloat()) },
        else => EvalError.UnsupportedExpression,
    };
}

fn evaluateScalarCall(call: ast.Call, resolver: *const Resolver) EvalError!Value {
    if (std.ascii.eqlIgnoreCase(call.callee.value, "time_bucket")) {
        return evalTimeBucket(call, resolver);
    }
    if (std.ascii.eqlIgnoreCase(call.callee.value, "abs")) {
        if (call.args.len != 1) return EvalError.UnsupportedExpression;
        const arg = try evaluate(call.args[0], resolver);
        return Value{ .float = @abs(try arg.asFloat()) };
    }
    if (std.ascii.eqlIgnoreCase(call.callee.value, "ceil")) {
        return try evalUnaryFloatCall(call, resolver, .ceil);
    }
    if (std.ascii.eqlIgnoreCase(call.callee.value, "floor")) {
        return try evalUnaryFloatCall(call, resolver, .floor);
    }
    if (std.ascii.eqlIgnoreCase(call.callee.value, "round")) {
        return try evalUnaryFloatCall(call, resolver, .round);
    }
    if (std.ascii.eqlIgnoreCase(call.callee.value, "sqrt")) {
        return try evalUnaryFloatCall(call, resolver, .sqrt);
    }
    if (std.ascii.eqlIgnoreCase(call.callee.value, "ln")) {
        return try evalUnaryFloatCall(call, resolver, .ln);
    }
    if (std.ascii.eqlIgnoreCase(call.callee.value, "pow")) {
        if (call.args.len != 2) return EvalError.UnsupportedExpression;
        const lhs = try (try evaluate(call.args[0], resolver)).asFloat();
        const rhs = try (try evaluate(call.args[1], resolver)).asFloat();
        return Value{ .float = std.math.pow(f64, lhs, rhs) };
    }
    return EvalError.UnsupportedExpression;
}

fn evalTimeBucket(call: ast.Call, resolver: *const Resolver) EvalError!Value {
    if (call.args.len != 2 and call.args.len != 3) return EvalError.UnsupportedExpression;
    const bucket_val = try evaluate(call.args[0], resolver);
    const ts_val = try evaluate(call.args[1], resolver);
    const bucket_size = try bucket_val.asFloat();
    if (bucket_size == 0) return EvalError.DivisionByZero;
    const timestamp = try ts_val.asFloat();
    const origin = if (call.args.len == 3) try (try evaluate(call.args[2], resolver)).asFloat() else 0.0;
    const bucket = std.math.floor((timestamp - origin) / bucket_size) * bucket_size + origin;
    return Value{ .integer = @intFromFloat(bucket) };
}

const UnaryMathOp = enum { ceil, floor, round, sqrt, ln };

fn evalUnaryFloatCall(call: ast.Call, resolver: *const Resolver, comptime op: UnaryMathOp) EvalError!Value {
    if (call.args.len != 1) return EvalError.UnsupportedExpression;
    const arg = try evaluate(call.args[0], resolver);
    const value = try arg.asFloat();
    return Value{ .float = switch (op) {
        .ceil => @ceil(value),
        .floor => @floor(value),
        .round => @round(value),
        .sqrt => @sqrt(value),
        .ln => @log(value),
    } };
}

fn literalToValue(literal: ast.Literal) Value {
    return switch (literal.value) {
        .integer => |i| Value{ .integer = i },
        .float => |f| Value{ .float = f },
        .boolean => |b| Value{ .boolean = b },
        .string => |s| Value{ .string = s },
        .null => Value.null,
    };
}

pub fn expressionsEqual(a: *const ast.Expr, b: *const ast.Expr) bool {
    if (std.meta.activeTag(a.*) != std.meta.activeTag(b.*)) return false;
    return switch (a.*) {
        .identifier => |aid| switch (b.*) {
            .identifier => |bid| namesEqual(aid.value, bid.value),
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
        .integer => |ai| switch (b.value) {
            .integer => |bi| ai == bi,
            else => false,
        },
        .float => |af| switch (b.value) {
            .float => |bf| af == bf,
            else => false,
        },
        .boolean => |ab| switch (b.value) {
            .boolean => |bb| ab == bb,
            else => false,
        },
        .string => |astr| switch (b.value) {
            .string => |bstr| std.mem.eql(u8, astr, bstr),
            else => false,
        },
        .null => switch (b.value) {
            .null => true,
            else => false,
        },
    };
}

fn callEqual(a: ast.Call, b: ast.Call) bool {
    if (!namesEqual(a.callee.value, b.callee.value)) return false;
    if (a.args.len != b.args.len) return false;
    for (a.args, 0..) |arg, idx| {
        if (!expressionsEqual(arg, b.args[idx])) return false;
    }
    return true;
}

fn namesEqual(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn trailingSegment(name: []const u8) []const u8 {
    if (name.len == 0) return name;
    var start: usize = 0;
    for (name, 0..) |ch, idx| {
        if (ch == '.') start = idx + 1;
    }
    return name[start..];
}

test "time_bucket supports explicit origin" {
    const common = @import("common.zig");

    const base_span = common.Span.init(0, 0);
    const bucket_expr = try std.testing.allocator.create(ast.Expr);
    defer std.testing.allocator.destroy(bucket_expr);
    bucket_expr.* = .{ .literal = .{ .value = .{ .integer = 60 }, .span = base_span } };

    const ts_expr = try std.testing.allocator.create(ast.Expr);
    defer std.testing.allocator.destroy(ts_expr);
    ts_expr.* = .{ .literal = .{ .value = .{ .integer = 125 }, .span = base_span } };

    const origin_expr = try std.testing.allocator.create(ast.Expr);
    defer std.testing.allocator.destroy(origin_expr);
    origin_expr.* = .{ .literal = .{ .value = .{ .integer = 5 }, .span = base_span } };

    const args = try std.testing.allocator.alloc(*const ast.Expr, 3);
    defer std.testing.allocator.free(args);
    args[0] = bucket_expr;
    args[1] = ts_expr;
    args[2] = origin_expr;

    const expr = try std.testing.allocator.create(ast.Expr);
    defer std.testing.allocator.destroy(expr);
    expr.* = .{ .call = .{
        .callee = .{ .value = "time_bucket", .quoted = false, .span = base_span },
        .args = args,
        .span = base_span,
    } };

    const ctx = RowContext{ .schema = &.{}, .values = &.{} };
    const value = try evaluateRow(expr, &ctx);
    try std.testing.expectEqual(@as(i64, 125), value.integer);
}

test "scalar math functions evaluate on row inputs" {
    const common = @import("common.zig");

    const alloc = std.testing.allocator;
    const base_span = common.Span.init(0, 0);
    const ident = try alloc.dupe(u8, "value");
    defer alloc.free(ident);

    const value_expr = try alloc.create(ast.Expr);
    defer alloc.destroy(value_expr);
    value_expr.* = .{ .identifier = .{ .value = ident, .quoted = false, .span = base_span } };

    const pow_name = try alloc.dupe(u8, "pow");
    defer alloc.free(pow_name);
    const two_expr = try alloc.create(ast.Expr);
    defer alloc.destroy(two_expr);
    two_expr.* = .{ .literal = .{ .value = .{ .integer = 2 }, .span = base_span } };
    const pow_args = try alloc.alloc(*const ast.Expr, 2);
    defer alloc.free(pow_args);
    pow_args[0] = value_expr;
    pow_args[1] = two_expr;
    const pow_expr = try alloc.create(ast.Expr);
    defer alloc.destroy(pow_expr);
    pow_expr.* = .{ .call = .{
        .callee = .{ .value = pow_name, .quoted = false, .span = base_span },
        .args = pow_args,
        .span = base_span,
    } };

    const ceil_name = try alloc.dupe(u8, "ceil");
    defer alloc.free(ceil_name);
    const ceil_args = try alloc.alloc(*const ast.Expr, 1);
    defer alloc.free(ceil_args);
    ceil_args[0] = value_expr;
    const ceil_expr = try alloc.create(ast.Expr);
    defer alloc.destroy(ceil_expr);
    ceil_expr.* = .{ .call = .{
        .callee = .{ .value = ceil_name, .quoted = false, .span = base_span },
        .args = ceil_args,
        .span = base_span,
    } };

    const schema = [_]plan.ColumnInfo{
        .{ .name = ident, .expr = value_expr },
    };
    const values = [_]Value{
        .{ .float = 1.5 },
    };
    const ctx = RowContext{ .schema = schema[0..], .values = values[0..] };

    try std.testing.expectApproxEqAbs(@as(f64, 2.25), (try evaluateRow(pow_expr, &ctx)).float, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), (try evaluateRow(ceil_expr, &ctx)).float, 1e-9);
}
