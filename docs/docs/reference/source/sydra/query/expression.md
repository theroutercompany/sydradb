---
sidebar_position: 14
title: src/sydra/query/expression.zig
---

# `src/sydra/query/expression.zig`

## Purpose

Evaluates AST expressions against either:

- an abstract resolver (`Resolver`), or
- a concrete row (`RowContext`), for use in filter/project execution.

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
