---
sidebar_position: 8
title: src/sydra/query/type_inference.zig
---

# `src/sydra/query/type_inference.zig`

## Purpose

Infers expression types (and whether an expression references time) to support planning and validation.

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
