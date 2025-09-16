# Catalog Shim Design Notes

This memo captures the minimum viable definitions for the PostgreSQL catalog views we plan to emulate. It should be read alongside `docs/sydraDB_postgres_compat_matrix_v0.1.md` (§B) and updated as soon as implementations land.

## Goals
- Serve ORM introspection queries without requiring behavioural flags.
- Keep catalog data consistent with sydra metadata sources (`sydra_meta.*`).
- Produce stable OIDs so `regclass/regtype` casts round-trip across restarts.

## Core Relations

### pg_namespace
- Columns: `oid`, `nspname`, `nspowner`, `nspacl` (optional).
- Backed by `sydra_meta.namespaces()` enumerating logical databases/schemas.
- Persist namespace OIDs; propose `hash(namespace_name)` reserved range until full catalog persistence lands.

### pg_class
- Columns: `oid`, `relname`, `relnamespace`, `relkind`, `relpersistence`, `reltuples`, `relhaspkey`, `relispartition`, `reltoastrelid`.
- Source from `sydra_meta.objects()` returning tables, indexes, views, sequences.
- `relkind` mapping: table → `r`, index → `i`, view → `v`, sequence → `S`.
- `reltuples` uses row-estimate from sydra statistics; default to `0` if unavailable.

### pg_attribute
- Columns: `attrelid`, `attname`, `atttypid`, `attnum`, `attnotnull`, `atthasdef`, `attisdropped`, `attlen`, `atttypmod`, `attidentity`, `attgenerated`, `attndims`.
- `atttypid` links into `pg_type`. For arrays use dedicated array type OIDs.
- `attidentity` → `'a'` for identity columns, `'d'` for generated defaults we emulate, else `''`.

### pg_type
- Columns: `oid`, `typname`, `typnamespace`, `typlen`, `typbyval`, `typtype`, `typcategory`, `typdelim`, `typelem`, `typarray`, `typbasetype`, `typcollation`, `typinput`, `typoutput`.
- Mirror PostgreSQL OIDs for common scalars (`16` bool, `23` int4, `25` text, `2950` uuid) to keep drivers happy.
- Allocate a sydra-owned range (`900000`+) for composite/array/JSONB types we synthesise.

### pg_index
- Columns: `indexrelid`, `indrelid`, `indnatts`, `indnkeyatts`, `indisunique`, `indisprimary`, `indisexclusion`, `indimmediate`, `indisvalid`, `indkey`, `indcollation`, `indclass`, `indoption`.
- Translate sydra index metadata; map index columns into `int2vector` order following PostgreSQL conventions.

### pg_constraint
- Columns: `oid`, `conname`, `connamespace`, `contype`, `conrelid`, `conindid`, `confrelid`, `conkey`, `confkey`, `condeferrable`, `condeferred`, `confupdtype`, `confdeltype`, `confmatchtype`.
- `contype` mapping: PK `p`, unique `u`, FK `f`, check `c`.
- Generate `conkey` arrays from attribute numbers; build these alongside `pg_attribute` seeding to stay consistent.

### pg_attrdef
- Columns: `oid`, `adrelid`, `adnum`, `adbin`.
- `adbin` stores sydraQL expression text for defaults. Provide helper `pg_get_expr` that unwraps them as needed.

### pg_proc
- Populate for compatibility helper functions only (`version`, `current_setting`, `pg_get_*`, `to_reg*`, `sydra.eval`).
- Keep `prosrc` referencing the backing sydra internal or SQL wrapper.

## information_schema Views
- Define `schemata`, `tables`, `columns`, `table_constraints`, `key_column_usage`, `constraint_column_usage`, `referential_constraints`, `sequences` as views over the catalog relations above.
- Normalise casing rules to match PostgreSQL (`lower` for identifiers unless quoted).
- Document differences (e.g., sequence cache semantics) in `docs/compatibility.md` when deviations exist.

## Implementation Sketch
- Introduce `src/sydra/catalog.zig` exposing iterators for namespaces, relations, attributes, and constraints.
- Define view renderers that synthesise row structs consumed by the protocol front-end.
- Cache results per schema change epoch; invalidate on DDL events.

## Testing
- Add golden-result fixtures under `tests/catalog/` comparing our synthetic views against captured PostgreSQL outputs for reference schemas.
- Extend ORM smoke tests to snapshot `pg_class`, `pg_attribute`, and `information_schema.columns` to ensure shape compatibility.

## Open Items
- Decide on ownership of OID persistence (engine vs. catalog shim).
- Determine story for `pg_roles` / authentication tables once role management is implemented.
- Evaluate need for `pg_settings` vs. `SHOW` rewriters for early releases.

Update this file as schemas or mapping rules evolve.
