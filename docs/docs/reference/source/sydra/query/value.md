---
sidebar_position: 13
title: src/sydra/query/value.zig
---

# `src/sydra/query/value.zig`

## Purpose

Defines a runtime value representation used during query execution and expression evaluation.

## Definition index (public)

### `pub const ConvertError = error { ... }`

- `TypeMismatch`

### `pub const Value = union(enum)`

Variants:

- `null`
- `boolean: bool`
- `integer: i64`
- `float: f64`
- `string: []const u8`

Helpers:

- `isNull()`
- `asBool()`, `asFloat()`, `asInt()`, `asString()` (type-checked conversions)
- `equals(a, b)` – equality across compatible numeric types
- `compareNumeric(a, b)` – ordering comparison using float conversion
- `copySlice(allocator, values)` – shallow copy a `[]Value` slice

## Conversion rules (as implemented)

- `asBool` accepts only `.boolean`.
- `asInt` accepts only `.integer`.
- `asString` accepts only `.string`.
- `asFloat` accepts:
  - `.float` as-is
  - `.integer` by converting to `f64`

## Equality rules (as implemented)

- `.integer` and `.float` compare equal if their `f64` values are equal.
- Other mixed-type comparisons return `false`.
