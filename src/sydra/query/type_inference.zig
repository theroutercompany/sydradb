const std = @import("std");
const ast = @import("ast.zig");
const functions = @import("functions.zig");

pub const ExprInfo = struct {
    ty: functions.Type,
    has_time: bool,
};

pub const default_value_type = functions.Type.init(.value, true);

pub fn inferExpression(allocator: std.mem.Allocator, expr: *const ast.Expr) (functions.TypeCheckError || std.mem.Allocator.Error)!ExprInfo {
    return switch (expr.*) {
        .identifier => |ident| ExprInfo{
            .ty = identifierType(ident),
            .has_time = identifierIsTime(ident),
        },
        .literal => |literal| ExprInfo{
            .ty = literalType(literal),
            .has_time = false,
        },
        .unary => |unary| blk: {
            const operand = try inferExpression(allocator, unary.operand);
            break :blk ExprInfo{
                .ty = typeForUnary(unary.op, operand.ty),
                .has_time = operand.has_time,
            };
        },
        .binary => |binary| blk: {
            const left = try inferExpression(allocator, binary.left);
            const right = try inferExpression(allocator, binary.right);
            break :blk ExprInfo{
                .ty = typeForBinary(binary.op, left.ty, right.ty),
                .has_time = left.has_time or right.has_time,
            };
        },
        .call => |call| blk: {
            var has_time = false;
            if (call.args.len == 0) {
                const match = try functions.resolve(call.callee.value, &[_]functions.Type{});
                break :blk ExprInfo{
                    .ty = match.return_type,
                    .has_time = false,
                };
            }

            var arg_types = try allocator.alloc(functions.Type, call.args.len);
            defer allocator.free(arg_types);

            var idx: usize = 0;
            while (idx < call.args.len) : (idx += 1) {
                const info = try inferExpression(allocator, call.args[idx]);
                arg_types[idx] = info.ty;
                if (info.has_time) has_time = true;
            }

            const match = try functions.resolve(call.callee.value, arg_types);
            break :blk ExprInfo{
                .ty = match.return_type,
                .has_time = has_time,
            };
        },
    };
}

pub fn expressionHasTime(expr: *const ast.Expr) bool {
    return switch (expr.*) {
        .identifier => |ident| identifierIsTime(ident),
        .literal => false,
        .unary => |unary| expressionHasTime(unary.operand),
        .binary => |binary| expressionHasTime(binary.left) or expressionHasTime(binary.right),
        .call => |call| blk: {
            var has_time = false;
            for (call.args) |arg| {
                if (expressionHasTime(arg)) {
                    has_time = true;
                    break;
                }
            }
            break :blk has_time;
        },
    };
}

pub fn identifierIsTime(ident: ast.Identifier) bool {
    const slice = ident.value;
    if (slice.len == 0) return false;
    const segment = trailingSegment(slice);
    return std.ascii.eqlIgnoreCase(segment, "time");
}

fn identifierType(ident: ast.Identifier) functions.Type {
    if (identifierIsTime(ident)) return functions.Type.init(.timestamp, false);
    if (hasTagPrefix(ident.value)) return functions.Type.init(.string, true);
    const segment = trailingSegment(ident.value);
    if (std.ascii.eqlIgnoreCase(segment, "value")) {
        return functions.Type.init(.value, true);
    }
    return default_value_type;
}

fn literalType(literal: ast.Literal) functions.Type {
    return switch (literal.value) {
        .integer => functions.Type.init(.integer, false),
        .float => functions.Type.init(.float, false),
        .string => functions.Type.init(.string, false),
        .boolean => functions.Type.init(.boolean, false),
        .null => default_value_type,
    };
}

fn typeForUnary(op: ast.UnaryOp, operand: functions.Type) functions.Type {
    return switch (op) {
        .logical_not => functions.Type.init(.boolean, operand.nullable),
        .negate, .positive => functions.Type.init(.value, operand.nullable),
    };
}

fn typeForBinary(op: ast.BinaryOp, left: functions.Type, right: functions.Type) functions.Type {
    const nullable = left.nullable or right.nullable;
    return switch (op) {
        .logical_and,
        .logical_or,
        .regex_match,
        .regex_not_match,
        .equal,
        .not_equal,
        .less,
        .less_equal,
        .greater,
        .greater_equal,
        => functions.Type.init(.boolean, nullable),
        else => functions.Type.init(.value, nullable),
    };
}

fn trailingSegment(slice: []const u8) []const u8 {
    if (slice.len == 0) return slice;
    var idx = slice.len;
    while (idx > 0) {
        idx -= 1;
        if (slice[idx] == '.') {
            return slice[idx + 1 ..];
        }
    }
    return slice;
}

fn hasTagPrefix(slice: []const u8) bool {
    const dot = std.mem.indexOfScalar(u8, slice, '.') orelse return false;
    return std.ascii.eqlIgnoreCase(slice[0..dot], "tag");
}
