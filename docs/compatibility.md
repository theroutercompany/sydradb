High‑level strategy

Speak the Postgres wire protocol (v3) Provide a network front‑end that looks like a PostgreSQL server to clients (psql, libpq, JDBC, Npgsql, Pgx, Prisma, Django, Rails, etc.). This avoids driver changes and preserves connection strings.

Translate SQL↔︎sydraQL

SQL→sydraQL compiler that maps PG SQL syntax, types, functions, and operators to sydraQL AST.

sydraQL escape hatch that can be called from SQL so teams can start using sydraQL without rewriting their entire application.

Catalog & semantics shim Emulate pg_catalog/information_schema, PG error codes, transaction semantics, and common server parameters so ORMs and tools “just work.”

Migration toolchain

Schema & data converter (pg_dump/introspection → sydra DDL + data).

Optional CDC/WAL ingestion for low‑downtime cutover.

Static analysis that flags constructs needing human intervention (e.g., complex triggers).

Compatibility surface tracked by a matrix Deliver an MVP that covers the 80–90% used by typical apps, then expand. Provide a linter/report for the remainder.

Additional recommendations

- Capture adversarial SQL traces from real apps (proxy in front of PG, record/playback) to harden the translator against oddball ORM behaviour.
- Maintain a deterministic SQLSTATE / error message catalogue so translation and tests lock behaviour down.
- Add plan/result diff tooling against a reference Postgres instance to catch semantic or performance drift.
- Automate pgbench-style performance budgets in CI so compatibility fixes never regress latency/QPS budgets.
- Expose observability hooks (per-statement counters, translation cache stats via `SHOW sydra.stats`, structured logs) for operators.
- Gate major compatibility features behind server toggles for staged rollouts and safe fallback.
- Perform parser/security audits around translation (string literal rewriting, JSON operators) to avoid new injection vectors.
- Generate the compatibility matrix and “Differences from PostgreSQL” docs from automated coverage to keep docs in sync.
- Offer a temporary fallback path (forward queries to upstream PG) for constructs not yet supported to ease migration.

Implementation notes (work-in-progress)

- Added `compat.stats` module and `/debug/compat/stats` HTTP endpoint exposing translation counters (translations, fallbacks, cache hits) to aid observability while building the translator.
- Introduced `compat.sqlstate` catalog with helper APIs for SQLSTATE lookups, payload construction, and formatting; meant to underpin consistent error reporting as the protocol front-end comes online.
- Added `compat.log` recorder utility for sampling SQL↔︎sydraQL translation events and emitting structured logs while feeding the stats counters.

ARCHITECTURE: see compatibility_architecture.md in the same folder

MVP compatibility scope (pragmatic defaults) Protocol

Startup: Version 3.0; parameter status; SSL negotiation; SCRAM‑SHA‑256 (and MD5 fallback if you must).

Simple & Extended Query flow: Parse/Bind/Describe/Execute/Sync; portal & prepared statement cache.

COPY in/out for bulk load.

Transactions & concurrency

BEGIN/COMMIT/ROLLBACK, savepoints.

Isolation level mapping: READ COMMITTED, REPEATABLE READ, SERIALIZABLE → nearest sydra equivalents.

SET TRANSACTION ISOLATION LEVEL ….

Row locks: SELECT … FOR UPDATE/SHARE/SKIP LOCKED NOWAIT → emulate with sydra primitives (or reject with clear SQLSTATE when not feasible).

DDL

CREATE/ALTER/DROP TABLE/INDEX/VIEW/SCHEMA/SEQUENCE.

Identity/serial mapping: SERIAL/BIGSERIAL → sequences/identity columns.

Constraints: PRIMARY KEY/UNIQUE/NOT NULL/CHECK (MVP: expression checks limited to deterministic expressions).

CREATE EXTENSION compat stubs for common ORMs (e.g., create no‑op stubs for uuid-ossp if you offer native gen_random_uuid()).

Types (first wave)

Scalars: bool, smallint, integer, bigint, numeric/decimal, real, double precision.

Text: text, varchar(n), char(n), bytea.

Temporal: date, time, timestamp, timestamptz, interval.

IDs/Utility: uuid.

JSON: json, jsonb (with core ops).

Arrays (1‑D) for scalars and text.

Type coercion and explicit casts consistent with PG where possible.

Operators & functions (prioritized set)

Comparisons, boolean logic, math, concatenation.

Text: length, lower, upper, substring, position, regexp_matches/replace, LIKE/ILIKE (optimize with index support).

Date/time: now(), current_timestamp, date_trunc, extract, age, make_interval.

Aggregates: count, sum, avg, min, max, array_agg.

JSONB: ->, ->>, #>, @>, ?, jsonb_build_object/array, to_jsonb.

Misc: coalesce, nullif, greatest, least.

Upsert: INSERT … ON CONFLICT … DO UPDATE/NOTHING.

RETURNING on DML.

Introspection & server identity

version(), SHOW server_version, SHOW search_path, current_schema(), current_setting/set_config.

pg_catalog views/tables needed by ORMs: pg_type, pg_class, pg_attribute, pg_namespace, pg_index, pg_constraint, pg_proc.

information_schema.tables/columns/constraints.

SQLSTATE error codes aligned with PG for common cases (unique violation 23505, null violation 23502, etc.).

SQL→sydraQL translation rules (illustrative)

These examples assume sydraQL is an expression‑oriented language with explicit operators but different surface syntax. Adjust to your actual grammar.

Identifiers & case

Preserve PG semantics: unquoted → lowercased; quoted → preserved.

Map to sydra identifiers with a reversible scheme.

Upsert

```sql
-- PG
INSERT INTO users(id,email,name)
VALUES($1,$2,$3)
ON CONFLICT (id) DO UPDATE SET email=EXCLUDED.email, name=EXCLUDED.name
RETURNING *;
```

sydraQL:

```
upsert users
  keys(id)
  set { email: $2, name: $3 }
  values { id: $1, email: $2, name: $3 }
  returning all;
```

JSONB containment

```sql
SELECT * FROM docs WHERE data @> '{"status":"ready"}';
```

sydraQL:

```
from docs where json_contains(data, {"status":"ready"});
```

Array ANY/ALL

```sql
SELECT * FROM t WHERE $1 = ANY(tags);
```

sydraQL

```
from t where array_any(tags, x -> x = $1);
```

Date truncation

```sql
SELECT date_trunc('day', created_at) AS d, count(*) FROM events GROUP BY d;
```

sydraQL

```
from events
  group by date_trunc("day", created_at) as d
  select d, count();
```

Keep a rule catalog that maps PG function/operator → sydraQL intrinsic or library call, with tests and edge‑cases annotated.

pg_catalog & GUC shim (what to fake vs. map)

Provide synthetic rows for pg_type, pg_class, pg_namespace, etc., reflecting sydra objects.

Implement SHOW/SET for common GUCs used by clients: search_path, application_name, standard_conforming_strings, client_min_messages. Unsupported GUCs should return a sane default or raise 0A000 (feature not supported) with human‑readable hints.

Server identity: return PostgreSQL 13.99 (sydra-compat) style version() string so ORMs unlock the expected feature set but see a suffix indicating the compat layer (helps debugging).

Type mapping details (selected) Postgres	sydraDB internal	Notes / caveats serial/bigserial	sequence/identity	Implement nextval/currval/setval. Respect RETURNING. jsonb	native JSON	Emulate containment & path ops; ensure indexing strategy for @> and ? queries. timestamptz	UTC instant	Normalize to UTC internally; preserve display offset per session TimeZone. Arrays	list/vector	1‑based indexing in PG → emulate or translate. Provide unnest, array_length. numeric(p,s)	decimal	Match rounding/overflow semantics; avoid silent downcasts. bytea	bytes/blob	PG hex format in text I/O; binary mode via wire protocol.

Transaction semantics f sydraDB uses MVCC, map isolation levels directly.

If not, emulate READ COMMITTED via statement‑level snapshots; emulate REPEATABLE READ via transaction snapshots; reject or fence SERIALIZABLE if not achievable, with clear guidance.

Implement savepoints & rollbacks via nested txn handles in the engine.

Authentication & TLS

SCRAM‑SHA‑256 preferred.

sslmode compatibility (disable, prefer, require, verify-ca, verify-full).

Expose pg_hba.conf‑like rules via sydra config for familiarity.

Extensions strategy

Shim pack: ship sydra-pg-ext that provides:

pgcrypto subset: gen_random_uuid, digest(text, 'sha256').

uuid-ossp stub that delegates to native uuid.

pg_trgm-like search via a native index operator class (or surface as CREATE EXTENSION pg_trgm that creates indexes of sydra type behind the scenes).

PostGIS: if out of scope, provide a clear “unsupported” error with migration hints.

“Use sydraQL with minimal effort” (dual‑dialect)

SQL surface remains so apps run unchanged.

Introduce a safe callout:

```sql
-- Call sydraQL from SQL
SELECT sydra.eval($$
  from orders
  where total > 100
  select id, total
  order by total desc
  limit 10
$$) AS result;
```

sydra.eval(text, params jsonb DEFAULT '[]') returns tabular results.

Also allow PREPARE/EXECUTE on sydra.eval to keep perf.

Session toggle (optional):

```sql
SET sydraql.strict = on;     -- stricter translator, fail if lossy
SET sydraql.compat = 'pg15'; -- pick translation profile
```

This lets teams gradually port hot paths to sydraQL while the rest of the app keeps using PG SQL.

Migration tooling

Discovery & report

Connect to PG, inventory: tables, indexes, constraints, sequences, functions, triggers, extensions.

Emit a compatibility report: Supported / Emulated / Partial / Manual‑work.

Schema translation

pg_dump -s → sydra DDL (create schemas, tables, indexes, sequences).

Rewrite defaults (now() etc.), identity, enum → check or domain (or native enum if available).

Data move

Fast path: COPY … TO STDOUT (FORMAT binary) → stream → sydra bulk loader.

CDC for cutover: logical decoding (e.g., wal2json equivalent) to tail changes into sydra until switch.

App cutover

Flip connection strings to the PG‑compat endpoint.

Keep CDC running for a fallback window if needed, then disable.

Validation

Row counts, checksums, sampled query diff (compare results between PG and sydra on a corpus).

Edge cases & gotchas (design for them up front)

NULL sort order: PG: NULLS FIRST/LAST explicit; default varies. Respect explicit clauses and document defaults.

Text collation: PG ICU vs. sydra collation—ensure deterministic indexes; expose COLLATE where possible.

ON CONFLICT determinism with composite keys; make sure conflict arbiter matches PG rules.

RETURNING with triggers: if sydra doesn’t run row‑level triggers, document differences.

Sequences across multi‑writer: guarantee currval() session semantics.

Time zones: Test DST boundaries; align date_trunc & extract.

Arrays are 1‑based in PG; decide to emulate (recommended) rather than silently shifting to 0‑based.

Testing strategy (must‑pass suites)

ORM smoke tests: Django, Rails, SQLAlchemy, Prisma, Hibernate.

psql behavior: \d relies on pg_catalog.

PG regression subset: parser, aggregates, JSON, arrays, upsert, transactions.

Real‑world introspection queries: capture via proxy from sample apps and add to CI.

Performance: pgbench‑like harness on typical CRUD patterns; COPY throughput tests.

Observability & tooling

SHOW sydra.stats → per‑statement counters (hits, translated ops, fallbacks).

Compat logs: emit both the incoming SQL and the derived sydraQL (sampled), redact literals.

EXPLAIN compatibility: present PG‑like text while linking to native sydra plan for deeper debug.

Minimal change for developers

Keep existing connection strings (only host/port changes).

No code change to SQL; optional: start using sydra.eval() for new features/perf.

Familiar introspection and psql workflows continue to work.

Deliverables checklist

PG wire front‑end (SSL, SCRAM, simple+extended, COPY).

SQL→sydraQL translator with rule catalog & test corpus.

pg_catalog/information_schema/GUC shim.

Error code mapper (SQLSTATE).

sydra.eval() function & session toggles.

Schema & data migrator; optional CDC replicator.

Compatibility matrix (HTML/CLI) generated from actual engine capabilities.

CI pipelines running ORM test suites and PG regression subsets.

Docs with “Differences from PostgreSQL” that are short, explicit, and linked from error hints.

Risk register (with mitigations)

Feature gaps discovered late → Ship a compatibility linter that devs run against their app/sql and CI gates on it.

Subtle semantic drift (timezones, numeric rounding) → Golden‑result tests; high‑precision comparison modes; explicit docs.

Performance surprises → Provide native sydraQL escape hatch plus query hints only used by translator (never exposed to apps).
