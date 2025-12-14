---
sidebar_position: 14
title: src/sydra/query/expression.zig
---

# `src/sydra/query/expression.zig`

## Purpose

Evaluates AST expressions against either:

- an abstract resolver (`Resolver`), or
- a concrete row (`RowContext`), for use in filter/project execution.

## Public API

### `pub const Resolver`

An evaluation interface:

- `getIdentifier(ctx, ident)` → `Value`
- `evalCall(ctx, call, resolver)` → `Value`

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

### `pub fn evaluateRow(expr, ctx) !Value`

Convenience wrapper: builds a row resolver and evaluates the expression against row values.

### Supported scalar calls (as implemented)

- `time_bucket(bucket_size, ts)` – uses float math and floors into a bucket
- `abs(x)`

Other calls currently return `UnsupportedExpression`.

### `pub fn expressionsEqual(a, b) bool`

Structural equality helper for AST expressions (case-insensitive identifier and function name matching).

