Awesome—here’s a **first‑pass compatibility matrix (v0.1)** plus the **exact pg_catalog / information_schema surface** I recommend synthesizing so Django, Rails/ActiveRecord, Prisma, SQLAlchemy, Hibernate, etc. “just work.”  
I’m assuming a typical modern engine baseline; where I don’t know sydraDB’s internals I mark items as **Target**, and you can flip them to **Native/Partial/Unsupported** as you confirm.

---

## Legend

- **Native** — implemented in sydraDB core (ideal).  
- **Shim** — emulated/translated by the PG‑compat layer (wire, translator, catalog views).  
- **Partial** — works for common cases; edge cases documented.  
- **Scaffold** — implementation scaffolding landed (builders, counters, fixtures) but not yet an end-to-end user-facing feature.  
- **Plan** — planned; treat as unsupported until implemented.

> **Progress note (2025-09-16):** Translator scaffolding, structured compat logging, and stats counters remain in-tree (`src/sydra/query/translator.zig`, `src/sydra/compat/log.zig`, `/debug/compat/stats`) with unit fixtures in `tests/translator/cases.jsonl` asserting translation/fallback counts. The catalog bootstrap now seeds pg_type scalar/array pairs via `src/sydra/catalog.zig`, surfaces them through `/debug/compat/catalog`, and the `bootstrap seeds global defaults` test locks relationships like `int4 ↔ _int4` and `jsonb ↔ _jsonb`.

---

## Verification touchpoints

- `zig build test` – executes translator fixtures (see `tests/translator/cases.jsonl`) and catalog bootstrap assertions (`src/sydra/catalog.zig:test "bootstrap seeds global defaults"`).  
- `/debug/compat/stats` – exposes translation/fallback/cache counters sourced from `src/sydra/compat/stats.zig`; reset between suites.  
- `/debug/compat/catalog` – renders the live namespace/class/type snapshot for validating catalog seeds while the shim evolves.

---

## A. Compatibility matrix (v0.1 proposal)

### A1. Connectivity & Protocol
| Area | Current | Target | Notes |
|---|---|---|---|
| Wire protocol v3 (Simple & Extended) | **Plan** | **Shim** | Parse/Bind/Describe/Execute/Sync; prepared statements & portals. |
| SSL/TLS & sslmode | **Plan** | **Shim** | `disable/prefer/require/verify-ca/verify-full`. |
| Auth: SCRAM‑SHA‑256 | **Plan** | **Shim** | MD5 fallback optional; prefer SCRAM only. |
| COPY (text, binary) | **Plan** | **Shim** | Map to sydra bulk loader; stream backpressure. |
| ParameterStatus / GUCs | **Plan** | **Shim** | Implement core ones below (A7). |

### A2. Transactions & Concurrency
| Feature | Current | Target | Notes |
|---|---|---|---|
| `BEGIN/COMMIT/ROLLBACK` | **Plan** | **Native / Shim** | Map to sydra txn API. |
| Savepoints | **Plan** | **Shim** | Nested txn handles. |
| Isolation: RC/RR/SER | **Plan** | **Partial** | RC & RR map directly; if SERIALIZABLE is weaker, raise `0A000` or fence with docs. |
| Locks: `FOR UPDATE/SHARE/SKIP LOCKED/NOWAIT` | **Plan** | **Partial** | Emulate with sydra primitives; `NOWAIT/SKIP LOCKED` especially. |

### A3. DDL
| Feature | Current | Target | Notes |
|---|---|---|---|
| `CREATE/ALTER/DROP TABLE/SCHEMA/VIEW` | **Plan** | **Shim / Native** | Translate to sydra DDL. |
| Indexes (btree, partial, expressions) | **Plan** | **Shim / Partial** | Ensure operator classes for common types; expression indices required by ORMs. |
| Sequences & identity columns | **Plan** | **Shim** | `nextval/currval/setval`, `pg_get_serial_sequence`. |
| Constraints: PK/UK/NN/CHECK | **Plan** | **Shim** | CHECK limited to deterministic exprs. |
| FKs | **Plan** | **Shim / Partial** | Enforce & expose in `pg_constraint`. |

### A4. DML & Query
| Feature | Current | Target | Notes |
|---|---|---|---|
| Basic `SELECT` projection + `WHERE` | **Scaffold** | **Native** | Translator rewrites `SELECT <cols> FROM <table> [WHERE ...]` into sydraQL (`src/sydra/query/translator.zig`); fixtures in `tests/translator/cases.jsonl`. |
| `INSERT` (single `VALUES`, optional `RETURNING`) | **Scaffold** | **Shim** | Translator rewrites to `insert into <table> (...) values (...) [returning ...]`; see `tests/translator/cases.jsonl`. |
| `UPDATE/DELETE ... RETURNING` | **Plan** | **Shim** | RETURNING must reflect final values. |
| Upsert (`ON CONFLICT`) | **Plan** | **Shim / Partial** | Matches arbiter semantics; composite keys. |
| CTEs (WITH) | **Plan** | **Shim / Partial** | Recursive optional (Plan if costly). |
| Window functions | **Plan** | **Partial** | Add subset later if not native. |
| Subselects, EXISTS/IN | **Plan** | **Shim** | Standard rewrites to sydraQL. |

### A5. Types (first wave)
| Type | Current | Target | Notes |
|---|---|---|---|
| `bool, smallint, int, bigint, numeric, real, double` | **Scaffold** | **Native** | Catalog bootstrap seeds these scalars with PostgreSQL OIDs (`src/sydra/catalog.zig`); engine semantics to follow. |
| `text, varchar(n), char(n)` | **Scaffold** | **Native / Partial** | Text types seeded; enforce truncation semantics once planner lands. |
| `bytea` | **Plan** | **Shim** | Hex text I/O; binary over wire. |
| `date, time, timestamp, timestamptz, interval` | **Scaffold** | **Native / Partial** | Scalar + array pairs preloaded; ensure UTC normalisation and `extract` parity later. |
| `uuid` | **Scaffold** | **Native** | Type seeded; `gen_random_uuid()` pending. |
| `json/jsonb` | **Scaffold** | **Native / Partial** | `jsonb` + `_jsonb` pairing locked by tests; operators still to map. |
| Arrays (1‑D) | **Scaffold** | **Partial** | `_type` rows emitted for seeded scalars; translator support upcoming. |
| Enums | **Plan** | **Shim** | Can be emulated with domains + CHECK initially. |

### A6. Operators & Functions (MVP set)
| Group | Current | Target | Notes |
|---|---|---|---|
| Comparisons, boolean, math, concat | **Plan** | **Native** | NULL semantics. |
| Text: `length, lower, upper, substring, position, regexp_*`, `LIKE/ILIKE` | **Plan** | **Native / Partial** | ILIKE collation aware. |
| Date/time: `now/current_timestamp, date_trunc, extract, age` | **Plan** | **Native** | |
| Aggregates: `count, sum, avg, min, max, array_agg` | **Plan** | **Native** | |
| JSONB ops & builders | **Plan** | **Native / Partial** | Index support for `@>` and `?`. |
| Misc: `coalesce, nullif, greatest, least` | **Plan** | **Native** | |
| Sequence funcs: `nextval, currval, setval` | **Plan** | **Shim** | |
| Introspection funcs (see A8) | **Plan** | **Shim** | |

### A7. Server identity & GUCs to support
_Current status: **Plan** (session layer not yet in place). Target values once the wire handler lands:_

Return sensible values on `SHOW`/`current_setting()`:

- `server_version`: **`13.99 (sydra-compat)`**  
- `server_version_num`: **`130099`**  
- `TimeZone`: `UTC` (configurable)  
- `DateStyle`: `ISO, MDY`  
- `IntervalStyle`: `postgres`  
- `integer_datetimes`: `on`  
- `standard_conforming_strings`: `on`  
- `client_encoding`: `UTF8`  
- `search_path`: `"$user", public`  
- `application_name`: passthrough  
- `default_transaction_isolation`: `read committed`  
- `extra_float_digits`: `1`

### A8. Introspection functions (must exist)
_Current status: **Plan** (helpers not yet wired). Target set:_

- `version()` → `PostgreSQL 13.99 (sydra-compat) on x86_64, ...`  
- `current_schema()` / `current_database()`  
- `current_setting(text)` / `set_config(text,text,bool)`  
- `pg_get_serial_sequence(regclass, text)`  
- `pg_get_expr(text, oid)` (or compatible wrapper)  
- `pg_get_indexdef(oid)` / `pg_get_constraintdef(oid)` / `pg_get_viewdef(oid)`  
- `to_regclass(text)` / `to_regtype(text)`  
- Size helpers (optional but nice): `pg_relation_size(regclass)`, `pg_total_relation_size(regclass)`, `pg_indexes_size(regclass)`

### A9. Error codes (SQLSTATE) mapping (top set)
_Current status: **Scaffold** (`src/sydra/compat/sqlstate.zig` enumerates these codes; wire integration pending)._  
- `23505` unique_violation • `23503` foreign_key_violation • `23514` check_violation • `23502` not_null_violation  
- `42601` syntax_error • `42703` undefined_column • `42P01` undefined_table • `42P07` duplicate_table • `42883` undefined_function  
- `22001` string_data_right_truncation • `22003` numeric_value_out_of_range • `22P02` invalid_text_representation  
- `40001` serialization_failure • `40P01` deadlock_detected • `0A000` feature_not_supported • `42501` insufficient_privilege

### A10. Index & search features
| Feature | Current | Target | Notes |
|---|---|---|---|
| B‑tree (equality, range) | **Plan** | **Native** | Default operator class. |
| GIN for JSONB/arrays | **Plan** | **Partial / Plan** | Provide containment and existence ops. |
| Expression indexes | **Plan** | **Partial** | Needed by ORMs for case-insensitive search etc. |
| Trigram-like search | **Plan** | **Plan** | Ship as `pg_trgm` shim that creates sydra index type. |

### A11. Extensions (surface only)
| Extension | Current | Target | Notes |
|---|---|---|---|
| `pgcrypto` subset | **Plan** | **Shim** | `gen_random_uuid()`, `digest(text,'sha256')`. |
| `uuid-ossp` | **Plan** | **Shim** | No-op creating functions that delegate to native uuid. |
| `pg_trgm` | **Plan** | **Plan** | If you have text-search index, wire here. |
| PostGIS | **Plan** | **Unsupported (explicit)** | Give helpful error & migration note. |

---

## B. Exact **pg_catalog** objects to synthesize (minimal columns that ORMs touch)

> Implement these as **read‑only views** over sydra metadata (or table‑valued functions). Column names & types should match PG 13–15. Provide stable synthetic OIDs per object.

### B1. Namespaces, classes, attributes
- **`pg_namespace`** *(Current: Plan)*: `oid`, `nspname`, `nspowner`(int), `nspacl`(aclitem[])  
- **`pg_class`** *(Current: Plan)*: `oid`, `relname`, `relnamespace`, `reltype`, `relowner`, `relkind`(`r` table/`i` index/`v` view/`S` sequence), `relpersistence`, `reltuples`(float4), `relhaspkey`(bool), `relispartition`(bool), `reltoastrelid`(oid, 0)  
- **`pg_attribute`** *(Current: Plan)*: `attrelid`, `attname`, `atttypid`, `attnum`(smallint), `attnotnull`, `atthasdef`, `attisdropped`, `attlen`(int2), `atttypmod`(int4), `attidentity`(char, `'a'|'d'|''`), `attgenerated`(char, `'s'|''`), `attndims`(int4)

### B2. Types & collation
- **`pg_type`** *(Current: Scaffold)*: `oid`, `typname`, `typnamespace`, `typlen`(int2), `typbyval`, `typtype`(`b` base/`e` enum/`d` domain/`p` pseudo), `typcategory`(char), `typdelim`, `typelem`, `typarray`, `typbasetype`, `typcollation`, `typinput`(regproc), `typoutput`(regproc)  
  *Tip*: map common scalar OIDs to PG equivalents (e.g., `23` for int4) only if you’re comfortable; otherwise assign stable **sydra OIDs** and ensure `to_regtype/regtype` work. Default scalar/array pairs are currently seeded by `src/sydra/catalog.zig`; inspect via `/debug/compat/catalog`.
- **`pg_collation`** *(Current: Plan)*: `oid`, `collname`, `collnamespace`, `collowner`, `collprovider`(char), `collisdeterministic`(bool), `collcollate`, `collctype`

### B3. Defaults, constraints, indexes
- **`pg_attrdef`** *(Current: Plan)*: `oid`, `adrelid`, `adnum`, `adbin`(text)  _(PG no longer exposes `adsrc`; clients call `pg_get_expr`)_
- **`pg_constraint`** *(Current: Plan)*: `oid`, `conname`, `connamespace`, `contype`(`p/u/f/c`), `conrelid`, `conindid`, `confrelid`, `conkey`(int2[]), `confkey`(int2[]), `condeferrable`, `condeferred`, `confupdtype`(char), `confdeltype`(char), `confmatchtype`(char)
- **`pg_index`** *(Current: Plan)*: `indexrelid`, `indrelid`, `indnatts`, `indnkeyatts`, `indisunique`, `indisprimary`, `indisexclusion`, `indimmediate`, `indisvalid`, `indkey`(int2vector), `indcollation`(oidvector), `indclass`(oidvector), `indoption`(int2vector)

### B4. Routines, sequences, descriptions, extensions
- **`pg_proc`** *(Current: Plan)*: `oid`, `proname`, `pronamespace`, `proowner`, `prolang`, `prokind`(`f` func/`p` proc), `prorettype`, `proretset`, `proargtypes`(oidvector), `proargnames`(text[]), `prosrc`(text)  
  _(Only populate for the introspection functions & shims you expose.)_
- **`pg_sequence`** *(Current: Plan)* (PG ≥10): `seqrelid`, `seqtypid`, `seqstart`, `seqincrement`, `seqmin`, `seqmax`, `seqcache`, `seqcycle`
- **`pg_description`** *(Current: Plan)*: optional but nice (`objoid`, `classoid`, `objsubid`, `description`)
- **`pg_extension`** *(Current: Plan)*: `oid`, `extname`, `extnamespace`, `extowner`, `extversion`

### B5. Settings & roles (read-only)
- **`pg_settings`** *(Current: Plan)*: expose rows for the GUCs you support (A7).  
- **`pg_roles`** / **`pg_authid`** (limited) *(Current: Plan)*: minimally `rolname`, `rolsuper`, `rolinherit`, `rolcreaterole`, `rolcreatedb`.  
  _Many ORMs don’t need roles; but tools like psql `\du` do._

### B6. Helper casts/regs (to avoid surprises)
Implement reg* parses as thin functions and consider views for:

- `pg_typeof(any)` (function)  
- `to_regclass(text)`, `to_regtype(text)`

> **Implementation tip:** back these views with **sydra_meta.*** TVFs, e.g. `sydra_meta.tables()`, `columns()`, `indexes()`, `constraints()`, `types()`, `sequences()`. Keep the mapping logic server‑side, not in the proxy.

---

## C. **information_schema** views to provide (ORM-heavy set)

_Current status: **Plan**. These can be simple views over `pg_catalog` shims once the catalog store feeds real metadata._

- `information_schema.schemata` → `schema_name`  
- `information_schema.tables` → `table_catalog, table_schema, table_name, table_type`  
- `information_schema.columns` → `table_schema, table_name, column_name, ordinal_position, column_default, is_nullable, data_type, character_maximum_length, numeric_precision, numeric_scale, datetime_precision, udt_schema, udt_name`  
- `information_schema.table_constraints` → `constraint_schema, constraint_name, table_schema, table_name, constraint_type`  
- `information_schema.key_column_usage` → `constraint_name, table_schema, table_name, column_name, ordinal_position`  
- `information_schema.constraint_column_usage` → `constraint_name, table_schema, table_name, column_name`  
- `information_schema.referential_constraints` → `constraint_name, unique_constraint_name, update_rule, delete_rule, match_option`  
- `information_schema.sequences` → `sequence_schema, sequence_name, data_type, start_value, minimum_value, maximum_value, increment, cycle_option`  
- `information_schema.routines` (optional) → minimal rows for your shimmed functions

---

## D. Functions to **implement or stub** (signatures that clients call)

_Current status: **Plan**. Implement with PG-compatible names & types; bodies can delegate to sydra._

- Introspection:  
  - `version() returns text`  
  - `current_schema() returns name`  
  - `current_database() returns name`  
  - `current_setting(name) returns text`  
  - `set_config(name, value, is_local boolean) returns text`  
  - `pg_get_serial_sequence(rel regclass, col text) returns text`  
  - `pg_get_expr(expr text, relid oid) returns text`  
  - `pg_get_indexdef(index oid) returns text`  
  - `pg_get_constraintdef(constraint oid) returns text`  
  - `pg_get_viewdef(view oid) returns text`  
  - `to_regclass(text) returns regclass` • `to_regtype(text) returns regtype`  
  - `pg_relation_size(rel regclass) returns bigint` (optional)  
  - `pg_total_relation_size(rel regclass) returns bigint` (optional)

- Sequences & UUID:  
  - `nextval(regclass) returns bigint`  
  - `currval(regclass) returns bigint`  
  - `setval(regclass, bigint, is_called boolean) returns bigint`  
  - `gen_random_uuid() returns uuid` (in `pgcrypto` or public)

- JSONB helpers if needed: thin wrappers that map to sydraQL intrinsics.

- **sydraQL escape hatch**:  
  - `sydra.eval(query text, params jsonb default '[]') returns setof jsonb` or a polymorphic table type.

---

## E. ORM coverage checklist (what each typically touches)

_Current status: **Plan** (no ORM smoke tests exercised yet)._  
- **Django**: `pg_type, pg_class, pg_attribute, pg_namespace, pg_constraint, pg_index, pg_attrdef`; functions: `version(), current_schema(), pg_get_serial_sequence(), pg_get_constraintdef(), pg_get_indexdef()`; `SHOW server_version`.  
- **Rails/ActiveRecord**: same as Django + `pg_description`, `information_schema.columns`, `pg_get_expr`.  
- **Prisma**: heavy on `information_schema.{tables,columns,table_constraints,key_column_usage,constraint_column_usage}`; `SHOW server_version`.  
- **SQLAlchemy/Alembic**: `version(), current_schema(), current_setting('server_version_num')`, `pg_type`, `pg_class`, `pg_attribute`, `pg_index`, `pg_constraint`, `information_schema.columns`.  
- **Hibernate (JDBC)**: tends to use `information_schema` plus `pg_type` for binding.

If you back the objects in **B** and **C**, all of these pass their introspection phases.

---

## F. OID strategy (to avoid driver surprises)

- Use a **stable OID namespace** per cluster.  
- Either (a) mirror PostgreSQL’s well‑known OIDs for common types (`23` int4, `25` text, `16` bool, etc.), **or** (b) allocate your own OIDs and ensure `pg_type.oid` ↔ `typname` is consistent and regtype casts resolve.  
- Never reuse OIDs across restarts; persist them in catalog storage.

---

## G. Behavior nits to align up front

- **Identifier case**: emulate PG (unquoted → lowercased; quoted preserved).  
- **NULL sort order**: honor explicit `NULLS FIRST/LAST`; document default.  
- **Arrays**: **1‑based indexing**; `array_length`, `unnest`, `= ANY(array)` translation.  
- **Time zones**: `timestamptz` displayed in session `TimeZone`, stored UTC.  
- **`RETURNING`**: ensure final defaults/identity/triggered values appear.  
- **`ON CONFLICT`**: arbiter selection matches PG rule ordering.

---

## H. “Quick start” synthetic definitions (pattern)

You don’t need real SQL here if these are virtualized, but this shows the shape:

```sql
-- Example: pg_catalog.pg_class as a view
CREATE VIEW pg_catalog.pg_class AS
SELECT
  obj.oid            AS oid,
  obj.name           AS relname,
  ns.oid             AS relnamespace,
  0::oid             AS reltype,
  10::int4           AS relowner,
  CASE obj.kind
    WHEN 'table' THEN 'r'::char
    WHEN 'index' THEN 'i'::char
    WHEN 'view'  THEN 'v'::char
    WHEN 'seq'   THEN 'S'::char
  END                AS relkind,
  'p'::char          AS relpersistence,
  obj.row_estimate   AS reltuples,
  obj.has_pkey       AS relhaspkey,
  false              AS relispartition,
  0::oid             AS reltoastrelid
FROM sydra_meta.objects() obj
JOIN pg_catalog.pg_namespace ns ON ns.nspname = obj.schema;
```

Replicate the idea for `pg_attribute`, `pg_type`, `pg_index`, `pg_constraint`, `pg_attrdef`, etc., sourcing from `sydra_meta.*` TVFs.

---

## I. “v0.1” deliverables (what to build/test first)

1. **Wire front-end** – Current: **Plan**; goal: PG v3, TLS, SCRAM, Simple+Extended, COPY.  
2. **GUC core** (A7) + **identity** (`version()`, `server_version_num`) – Current: **Plan**.  
3. **Catalog core** – Current: **Scaffold** (`pg_type` scalar/array seeds in `src/sydra/catalog.zig`, `/debug/compat/catalog` snapshot); next: wire real namespaces/classes/attributes and views.  
4. **Sequence & `uuid`** support + `pg_get_serial_sequence` – Current: **Plan**.  
5. **Error code mapper** (A9) – Current: **Scaffold** (`src/sydra/compat/sqlstate.zig`).  
6. **Translator coverage** for: DML + RETURNING, upsert, JSONB ops, arrays(1‑D), `SELECT … FOR UPDATE` – Current: **Scaffold** (simple `SELECT` flow + fixtures).  
7. **ORM smoke tests**: Django, Rails, Prisma, SQLAlchemy (run their introspection; create/migrate a small schema; basic CRUD) – Current: **Plan**.

---

## J. Execution backlog (next actionable slices)

- **Protocol front-end** – Build listener skeleton with Startup + SSL + Authentication negotiation; add `compat/stats` counters for handshake stages; unit harness pending under `zig build compat-wire-test`.
- **Catalog shim** – Extend `src/sydra/catalog.zig` adapter to ingest real namespace/relation lists from the engine and expose deterministic OIDs; backfill `/debug/compat/catalog` with row counts and checksum stats.
- **Translator** – Extend coverage beyond current SELECT + INSERT (VALUES/RETURNING) path to handle UPDATE/DELETE, bulk inserts, and SELECT locking clauses; expose cache-hit stats via `compat/log` sampling knobs.
- **SQLSTATE mapper** – Wire `compat/sqlstate.zig` into engine error surfaces so `/debug/compat/stats` fallbacks reflect actual failures; add tests that assert round-tripping of common codes.
- **Testing harness** – Draft protocol replay CLI (see `docs/compatibility_testing.md`) and add CI job skeleton invoking `zig build test` + placeholder `compat-wire-test`.

---

If you share which pieces of A–I are already **Native** in sydraDB, I can flip the statuses and produce a sharper “v0.1 reality matrix” plus a tiny **catalog conformance test pack** (SQL snippets) you can run in CI.
