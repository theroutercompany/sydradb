---
sidebar_position: 4
title: src/sydra/compat/catalog.zig
---

# `src/sydra/compat/catalog.zig`

## Purpose

Builds an in-memory “catalog snapshot” representing a small subset of PostgreSQL system catalog concepts:

- namespaces (schemas)
- classes (relations: tables/views/indexes/sequences)
- attributes (columns)
- types

The snapshot is intended for Postgres-compatibility queries and metadata surfaces.

## Public constants

- `pub const namespace_oid_base: u32 = 11000`
- `pub const relation_oid_base: u32 = 22000`

These bases are used to assign deterministic OIDs for namespaces and relations created from specs.

## Specs (inputs to snapshot building)

### `pub const NamespaceSpec`

- `name: []const u8`
- `owner: u32 = 10`

### `pub const RelationKind = enum { table, index, view, sequence }`

Mapped to catalog `relkind` chars via an internal helper:

- `table` → `r`
- `index` → `i`
- `view` → `v`
- `sequence` → `S`

### `pub const Persistence = enum { permanent, temporary, unlogged }`

Mapped to catalog `relpersistence` chars:

- `permanent` → `p`
- `temporary` → `t`
- `unlogged` → `u`

### `pub const RelationSpec`

- `namespace: []const u8`
- `name: []const u8`
- `kind: RelationKind`
- `persistence: Persistence = .permanent`
- `has_primary_key: bool = false`
- `row_estimate: f64 = 0`
- `is_partition: bool = false`
- `toast_relation_oid: ?u32 = null`

### `pub const TypeKind = enum { base, enum_type, domain, pseudo }`

Mapped to catalog `typtype` chars:

- `base` → `b`
- `enum_type` → `e`
- `domain` → `d`
- `pseudo` → `p`

### `pub const TypeSpec`

Defines a type row. Notably:

- `oid: u32` is supplied by the caller (types do not use `*_oid_base`).
- `name`, `namespace` identify the row.
- `length: i16`, `by_value: bool`, `category: u8`, `delimiter: u8` align with common `pg_type` fields.
- Additional fields exist for arrays, element/base types, collation, and in/out regprocs.

### `pub const IdentityKind = enum { none, always, by_default }`

Mapped to `attidentity` chars:

- `none` → ` ` (space)
- `always` → `a`
- `by_default` → `d`

### `pub const GeneratedKind = enum { none, stored }`

Mapped to `attgenerated` chars:

- `none` → ` ` (space)
- `stored` → `s`

### `pub const ColumnSpec`

- `namespace: []const u8`
- `relation: []const u8`
- `name: []const u8`
- `type_oid: u32`
- `position: ?i16 = null` (optional `attnum` override)
- `not_null: bool = false`
- `has_default: bool = false`
- `is_dropped: bool = false`
- `type_length: i16 = -1`
- `type_modifier: i32 = -1`
- `identity: IdentityKind = .none`
- `generated: GeneratedKind = .none`
- `dimensions: i32 = 0`

## Snapshot rows (outputs)

The snapshot exposes “row structs” shaped similarly to Postgres catalog tables.

### `pub const NamespaceRow`

- `oid: u32`
- `nspname: []const u8`
- `nspowner: u32`

### `pub const ClassRow`

- `oid: u32`
- `relname: []const u8`
- `relnamespace: u32`
- `relkind: u8`
- `relpersistence: u8`
- `reltuples: f64`
- `relhaspkey: bool`
- `relispartition: bool`
- `reltoastrelid: u32`

### `pub const AttributeRow`

- `attrelid: u32`
- `attname: []const u8`
- `atttypid: u32`
- `attnum: i16`
- `attnotnull: bool`
- `atthasdef: bool`
- `attisdropped: bool`
- `attlen: i16`
- `atttypmod: i32`
- `attidentity: u8`
- `attgenerated: u8`
- `attndims: i32`

### `pub const TypeRow`

- `oid: u32`
- `typname: []const u8`
- `typnamespace: u32`
- `typlen: i16`
- `typbyval: bool`
- `typtype: u8`
- `typcategory: u8`
- `typdelim: u8`
- `typelem: u32`
- `typarray: u32`
- `typbasetype: u32`
- `typcollation: u32`
- `typinput: u32`
- `typoutput: u32`

## `pub const Snapshot`

Fields:

- `namespaces: []NamespaceRow`
- `classes: []ClassRow`
- `attributes: []AttributeRow`
- `types: []TypeRow`
- `owns_memory: bool`

### `pub fn deinit(self: *Snapshot, alloc) void`

If `owns_memory` is `true`, frees:

- owned strings (`nspname`, `relname`, `attname`, `typname`)
- the row slices themselves

Then resets `self` to `Snapshot{}`.

## Building snapshots

### `pub fn buildSnapshot(alloc, namespace_specs, relation_specs, type_specs, column_specs) !Snapshot`

High-level algorithm:

1. **Assemble namespaces**
   - Start with `namespace_specs`.
   - Ensure every `RelationSpec.namespace` exists; missing namespaces are inserted with default `NamespaceSpec{ .owner = 10 }`.
   - Namespaces are de-duplicated by name.
2. **Assign namespace OIDs**
   - Namespaces are sorted by name.
   - OIDs are assigned as `namespace_oid_base + idx`.
   - A lookup map `name → oid` is built for later stages.
3. **Build classes (relations)**
   - `relation_specs` are copied and sorted by `(namespace, name)`.
   - Each relation OID is assigned as `relation_oid_base + rel_index`.
   - Relation name strings are duplicated and owned by the snapshot.
4. **Build types**
   - `type_specs` are copied and sorted by `(namespace, name)`.
   - Each type name string is duplicated and owned by the snapshot.
   - `TypeRow.oid` comes from `TypeSpec.oid` (caller provided).
5. **Build attributes (columns)**
   - `column_specs` are copied and sorted by `(namespace, relation, position?, name)`.
   - The relation OID is discovered by scanning the built classes.
   - `attnum` is allocated per relation, starting at `1`, unless `ColumnSpec.position` overrides it.
   - Column name strings are duplicated and owned by the snapshot.

The returned snapshot sets `owns_memory = true`.

### Internal helpers (important invariants)

- `findRelationOid(classes, ns_oid, relname) !u32` is a linear scan; it fails with `error.MissingRelation`.
- `nextAttnum(map, rel_oid, override) !i16` tracks per-relation `attnum` and uses `override` when provided.

Practical implication: if callers provide conflicting `ColumnSpec.position` overrides for the same relation, the resulting attribute list can contain duplicate or non-monotonic `attnum` values.

## Store wrapper

### `pub const Store`

Holds a `Snapshot` and provides lifecycle helpers.

- `snapshot: Snapshot = .{}`
- `pub fn deinit(self: *Store, alloc) void`
- `pub fn load(self, alloc, namespace_specs, relation_specs, type_specs, column_specs) !void`
  - Builds a new snapshot and replaces the old one (deiniting the previous snapshot).
- `pub fn namespaces/classes/attributes/types(self) []const ...`

### Global store

- `pub fn global() *Store` returns a pointer to a file-scoped `global_store`.

