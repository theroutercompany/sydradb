---
sidebar_position: 14
title: src/sydra/query/expression.zig
---

# `src/sydra/query/expression.zig`

## Purpose

Evaluates AST expressions against either:

- an abstract resolver (`Resolver`), or
- a concrete row (`RowContext`), for use in filter/project execution.

## See also

- [AST types](./ast.md)
- [Value representation](./value.md)
- [Function registry](./functions.md)
- [Operator pipeline](./operator.md) (filter/project evaluation)

## Definition index (public)

### `pub const Value`

Alias:

- `value.Value` from `src/sydra/query/value.zig`

### `pub const EvalError`

Error set:

- `value.ConvertError` (type conversion failures)
- `UnsupportedExpression`
- `DivisionByZero`

### `pub const Resolver`

An evaluation interface:

- `context: *const anyopaque` — user-supplied pointer
- `getIdentifier: fn(context, ident) EvalError!Value`
- `evalCall: fn(context, call, resolver) EvalError!Value`

### `pub const RowContext`

- `schema: []const plan.ColumnInfo`
- `values: []const Value`

### `pub fn evaluate(expr, resolver) !Value`

Supports:

- literals
- identifiers (via resolver)
- unary ops (`not`, unary +/-)
- binary ops (arithmetic, comparisons, logical and/or)
- calls (via resolver)

### `pub fn evaluateBoolean(expr, resolver) !bool`

Evaluates an expression and requires a boolean result.

### `pub fn evaluateRow(expr, ctx) !Value`

Convenience wrapper: builds a row resolver and evaluates the expression against row values.

### `pub fn evaluateRowBoolean(expr, ctx) !bool`

Convenience wrapper for boolean evaluation against a row.

### `pub fn rowResolver(ctx) Resolver`

Creates a `Resolver` that resolves identifiers against `ctx.schema` and `ctx.values`.

### Supported scalar calls (as implemented)

- `time_bucket(bucket_size, ts)` – uses float math and floors into a bucket
- `abs(x)`

Other calls currently return `UnsupportedExpression`.

### `pub fn expressionsEqual(a, b) bool`

Structural equality helper for AST expressions (case-insensitive identifier and function name matching).

## Row resolver rules (as implemented)

Identifier lookup rules (`rowGetIdentifier`):

- Compare case-insensitively against:
  - the column `name`
  - the trailing segment after `.` (so `tag.host` can match `host` when appropriate)
- If `ColumnInfo.expr` is an identifier expression, also match against that identifier’s `value`.

If no match is found, evaluation fails with `UnsupportedExpression`.

## Code excerpt

```zig title="src/sydra/query/expression.zig (Resolver + evaluate excerpt)"
pub const Resolver = struct {
    context: *const anyopaque,
    getIdentifier: *const fn (*const anyopaque, ast.Identifier) EvalError!Value,
    evalCall: *const fn (*const anyopaque, ast.Call, *const Resolver) EvalError!Value,
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
```
