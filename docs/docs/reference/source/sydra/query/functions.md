---
sidebar_position: 9
title: src/sydra/query/functions.zig
---

# `src/sydra/query/functions.zig`

## Purpose

Defines the sydraQL function registry and type-checking rules used by:

- validation (`validator.zig`)
- type inference (`type_inference.zig`)
- (indirectly) execution/planning decisions via planner hints

## Core types

- `FunctionKind`: `scalar`, `aggregate`, `window`, `fill`
- `TypeTag`: `any`, `null`, `boolean`, `integer`, `float`, `numeric`, `value`, `string`, `timestamp`, `duration`, `tags`
- `Type { tag, nullable }` with helpers `init` and `nonNull`
- `FunctionSignature { name, kind, params, return_strategy, hints }`
- `FunctionMatch { signature, return_type }`

## Public API

### `pub fn registry() []const FunctionSignature`

Returns the builtin registry (array of signatures).

### `pub fn lookup(name: []const u8) ?*const FunctionSignature`

Case-insensitive lookup by function name.

### `pub fn resolve(name: []const u8, args: []const Type) !FunctionMatch`

Performs arity/type validation and returns the matched signature plus inferred return type.

### `pub fn displayName(ty: Type) []const u8`

Human-readable type name used in API responses.

### `pub fn pgTypeInfo(ty: Type) PgTypeInfo`

Maps a type to PostgreSQL OID/length/modifier information (used by pgwire surfaces).

## Builtins

Builtins are defined in a static array (`builtin_registry`) with per-function:

- parameter expectations (including optional/variadic)
- return strategy (fixed or derived from an argument)
- planner hints (e.g. sorted-input requirements for `first`/`last`)

