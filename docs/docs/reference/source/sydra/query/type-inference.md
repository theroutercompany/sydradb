---
sidebar_position: 8
title: src/sydra/query/type_inference.zig
---

# `src/sydra/query/type_inference.zig`

## Purpose

Infers expression types (and whether an expression references time) to support planning and validation.

## See also

- [Function registry](./functions.md) (type rules + return strategies)
- [Validator](./validator.md)
- [Logical plan builder](./plan.md)

## Definition index (public)

### `pub const ExprInfo`

- `ty: functions.Type`
- `has_time: bool`

### `pub const default_value_type`

Default type used when the system cannot infer a tighter type: `Type(.value, nullable=true)`.

### `pub fn inferExpression(allocator, expr) !ExprInfo`

Error set:

- `functions.TypeCheckError`
- `std.mem.Allocator.Error`

Inference rules (high level):

- `identifier`:
  - trailing segment `time` → `timestamp` (non-null)
  - `tag.*` → `string` (nullable)
  - trailing segment `value` → `value` (nullable)
  - otherwise → `default_value_type`
- `literal` → type based on literal kind
- `unary` / `binary` → type based on operator category
- `call` → uses `functions.resolve(name, arg_types)` for return type

### `pub fn expressionHasTime(expr) bool`

Fast boolean check for time presence.

### `pub fn identifierIsTime(ident) bool`

Trailing-segment check for `time`.

## Internal helpers (non-public)

The implementation uses internal helpers for the core decisions:

- `identifierType(ident)`:
  - `time` → `timestamp` (non-null)
  - `tag.*` → `string` (nullable)
  - trailing segment `value` → `value` (nullable)
  - fallback to `default_value_type`
- `literalType(literal)` maps AST literals into `functions.Type`
- `typeForUnary` and `typeForBinary` define operator typing rules
- `hasTagPrefix(slice)` treats `tag.<k>` as tag lookups

## Code excerpt

```zig title="src/sydra/query/type_inference.zig (inferExpression excerpt)"
pub fn inferExpression(
    allocator: std.mem.Allocator,
    expr: *const ast.Expr,
) (functions.TypeCheckError || std.mem.Allocator.Error)!ExprInfo {
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
```
