---
sidebar_position: 6
title: src/sydra/catalog.zig
---

# `src/sydra/catalog.zig`

## Purpose

Bootstraps a minimal PostgreSQL-style catalog (schemas/relations/types/columns) into the global compatibility store (`compat.catalog.global()`).

This module is invoked during startup (`src/sydra/server.zig` calls `catalog.bootstrap`) so pgwire and compatibility queries have a baseline `pg_catalog` model available.

## Public API

### `pub const NamespaceInfo`

- `name: []const u8`
- `owner: u32 = 10`

### `pub const RelationInfo`

- `namespace: []const u8`
- `name: []const u8`
- `kind: compat.catalog.RelationKind`
- `persistence: compat.catalog.Persistence = .permanent`
- `has_primary_key: bool = false`
- `row_estimate: f64 = 0`
- `is_partition: bool = false`
- `toast_relation_oid: ?u32 = null`

### `pub const TypeInfo`

Maps directly onto `compat.catalog.TypeSpec` fields:

- `name`, `namespace`, `oid`, `length`, `by_value`
- `kind: compat.catalog.TypeKind = .base`
- `category: u8 = 'U'`, `delimiter: u8 = ','`
- array/element/base type OIDs, collation, input/output regprocs

### `pub const ColumnInfo`

Maps directly onto `compat.catalog.ColumnSpec` fields:

- `namespace`, `relation`, `name`, `type_oid`
- `position: ?i16 = null`
- nullability/default/drop flags
- type length/modifier
- identity/generated kind
- `dimensions: i32 = 0`

### `pub const Adapter`

An adapter is just a set of slices describing the desired catalog contents:

- `namespaces: []const NamespaceInfo`
- `relations: []const RelationInfo`
- `types: []const TypeInfo`
- `columns: []const ColumnInfo`

### `pub fn defaultAdapter() Adapter`

Returns an `Adapter` backed by file-scoped arrays that model:

- namespaces: `pg_catalog`, `public`
- relations: `pg_catalog.pg_type` (table)
- types: a small set of common scalar and array types (e.g. `int4`, `text`, `_int4`, `_text`, …)
- columns: a minimal `pg_type` “shape” with fields like `oid`, `typname`, `typlen`, `typbyval`, etc.

### `pub fn loadIntoStore(store: *compat.catalog.Store, alloc: std.mem.Allocator, adapter: Adapter) !void`

Loads the adapter into a compatibility catalog store:

1. Allocates temporary `[]compat.catalog.*Spec` arrays and fills them from the `*Info` slices.
2. Calls `store.load(alloc, ns_specs, rel_specs, type_specs, col_specs)`.
3. Frees the temporary spec arrays.

Note: `store.load` ultimately duplicates names into its own owned snapshot, so it is safe that the temporary spec arrays are freed immediately.

### `pub fn refreshGlobal(alloc: std.mem.Allocator, adapter: Adapter) !void`

Convenience wrapper:

- `loadIntoStore(compat.catalog.global(), alloc, adapter)`

### `pub fn bootstrap(alloc: std.mem.Allocator) !void`

Bootstraps the default catalog into the global store:

- `refreshGlobal(alloc, defaultAdapter())`

## Key internal helpers

The module contains conversion helpers that allocate and fill spec arrays:

- `toNamespaceSpecs`
- `toRelationSpecs`
- `toTypeSpecs`
- `toColumnSpecs`

Each returns an empty static slice (`&[_]T{}`) when the input slice is empty.

