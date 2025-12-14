# PostgreSQL Compatibility Roadmap

This document explains how we are bringing a PostgreSQL-compatible surface to sydraDB. It partners with `./compat-matrix-v0.1` (feature status) and `./testing` (test plan).

## Objectives
- Provide a PG v3 wire endpoint so existing clients connect without code changes.
- Translate common PostgreSQL SQL into sydraQL while offering a vetted escape hatch for native sydraQL.
- Emulate the catalog, GUCs, and SQLSTATE behaviour that ORMs and tooling rely on.
- Deliver migration tooling that moves schemas and data from Postgres with predictable downtime.

## Execution Pillars
### 1. Protocol & Session Layer
- Implement startup, SSL negotiation, SCRAM-SHA-256, simple/extended query flow, and COPY.
- Surface GUCs listed in the compatibility matrix (`server_version`, `search_path`, etc.).
- Maintain session state (prepared statements, portals, transaction settings) compatible with libpq semantics.

### 2. SQL→sydraQL Translator
- Expand the translator to cover DML/DDL/SELECT constructs in the matrix, using fixtures in `tests/translator/` to lock behaviour.
- Maintain a deterministic SQLSTATE mapper (`compat/sqlstate.zig`) so fallbacks and errors mimic PostgreSQL codes.
- Provide `sydra.eval(...)` for direct sydraQL execution and document how to opt in per session.

### 3. Catalog & Metadata Shim
- Materialise `pg_catalog` and `information_schema` views backed by sydra metadata APIs (`sydra_meta.*`).
- Stabilise OID allocation (see matrix §F) and expose helper functions such as `pg_get_indexdef`, `to_regclass`, and `current_setting`.
- Keep `./compat-matrix-v0.1` updated as features graduate from _Plan_ → _Shim_ → _Native_.

### 4. Migration & Tooling
- Provide schema conversion (pg_dump → sydra DDL) and bulk load via COPY adapters.
- Offer CDC-based catch-up for low-downtime cutovers.
- Ship a compatibility linter that highlights unsupported SQL before migration.

## Observability & Operations
- `compat/stats` exposes counters surfaced at `/debug/compat/stats`; expand with latency histograms as we add protocol stages.
- `compat/log` streams structured translation events (sampled) with SQL, sydraQL, cache usage, and duration.
- Add admin toggles (e.g., `SET sydraql.strict = on`) to make behaviour changes explicit during rollouts.

## Testing Commitments
- Unit fixtures (`zig build test`) validate translator rewrites and SQLSTATE fallbacks.
- Protocol harness (`zig build compat-wire-test`) will simulate libpq sessions for startup/auth/query flows.
- Trace replay targets ORM smoke tests (Django, Rails, Prisma, SQLAlchemy, Hibernate) using anonymised SQL traces.
- Nightly runs of curated PostgreSQL regression subsets guard semantic parity (JSONB, arrays, upsert, transactions).

## Roadmap Milestones
| Quarter | Focus | Key Deliverables |
|---------|-------|------------------|
| Q1 | Translator foundation | SELECT/INSERT/UPDATE coverage, SQLSTATE mapper, logging/stats plumbing |
| Q2 | Wire front-end alpha | PG v3 listener, prepared statement cache, COPY, basic GUC handling |
| Q3 | Catalog & ORM unlock | pg_catalog/info_schema views, OID allocator, ORM smoke tests green |
| Q4 | Migration tooling | Schema/data converter, CDC catch-up, compatibility linter, performance budgets |

## Risks & Mitigations
- **Semantic drift** (time zones, NULL ordering): enforce via golden-result tests and document intentional variances.
- **Performance regressions**: track translation latency and pgbench-style workloads; add thresholds to CI.
- **Feature creep**: drive scope through the compatibility matrix; new asks land as matrix entries before development.

For architectural internals (component boundaries, threading, and data flow) see `./architecture`.
