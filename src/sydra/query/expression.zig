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
    return EvalError.UnsupportedExpression;
}

fn evalTimeBucket(call: ast.Call, resolver: *const Resolver) EvalError!Value {
    if (call.args.len != 2) return EvalError.UnsupportedExpression;
    const bucket_val = try evaluate(call.args[0], resolver);
    const ts_val = try evaluate(call.args[1], resolver);
    const bucket_size = try bucket_val.asFloat();
    if (bucket_size == 0) return EvalError.DivisionByZero;
    const timestamp = try ts_val.asFloat();
    const bucket = std.math.floor(timestamp / bucket_size) * bucket_size;
    return Value{ .integer = @intFromFloat(bucket) };
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
