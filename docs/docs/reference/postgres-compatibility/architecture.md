---
sidebar_position: 2
sidebar_label: Architecture
---

# PostgreSQL Compatibility Architecture

This note decomposes the compatibility layer into the modules we are building and documents the current ownership boundaries. It should evolve alongside the implementation.

## High-Level Components

1. **Protocol Front-End**
   - Accepts TCP connections, performs SSL negotiation, and speaks the PostgreSQL v3 wire protocol (startup, authentication, simple/extended query cycle, COPY).
   - Owns session state: prepared statements, portals, transaction status, GUC overrides.
   - Emits decoded SQL queries to the translator and receives sydraQL execution results from the engine.

2. **SQL Translator**
   - Parses incoming PostgreSQL SQL (leveraging the planned grammar work) and converts it into sydraQL AST nodes.
   - Applies rewrite rules (e.g., identifier casing, array indexing adjustments) and annotates semantic gaps with SQLSTATE codes.
   - Integrates with `compat.sqlstate` to standardise error payloads and with `compat.log` for structured observability.

3. **Catalog & Introspection Shim**
   - Exposes `pg_catalog` tables and `information_schema` views backed by sydra metadata providers (`sydra_meta.tables()`, `columns()`, etc.).
   - Generates stable OIDs stored in catalog persistence so regclass/regtype casts behave as drivers expect.
   - Hosts compatibility functions (`version()`, `current_setting`, `pg_get_serial_sequence`, etc.) that bridge sydra internals.

4. **Execution Bridge**
   - Receives sydraQL plans from the translator, executes them against the engine, and maps results into PostgreSQL wire tuples.
   - Handles COPY in/out streaming, respecting backpressure semantics and transaction boundaries.
   - Converts sydra errors into PostgreSQL SQLSTATE payloads.

5. **Migration & Tooling**
   - A CLI pipeline that introspects source PostgreSQL schemas, emits sydra DDL, and orchestrates data movement (bulk load + CDC).
   - Compatibility linter that analyses SQL or ORM models and reports unsupported constructs referencing the matrix.

## Data Flow Overview

```
client SQL --> protocol frontend --> translator --> sydra engine --> protocol frontend --> client
                      ^                 |
                      |                 v
                 compat.log/stats   SQLSTATE mapper
```

- The translator is pure (stateless) aside from optional caches; global stats/logging modules collect metrics for `/debug/compat/stats` and operator insights.
- Catalog requests bypass the translator in many cases (e.g., `SELECT * FROM pg_type`) and are served directly by the catalog shim through synthetic sydraQL queries.

## Concurrency Model

- Each client connection runs in a dedicated async task. The protocol layer delegates execution to the existing sydra runtime (thread pool + event loop).
- COPY streaming uses bounded channels to avoid unbounded buffering; backpressure is surfaced to the client via standard PG CopyBoth flow control.
- Translator caches (e.g., prepared statement plans) are scoped to sessions; global caches must be lock-free or sharded to avoid contention.

## Observability Hooks

- `compat/stats`: atomic counters + (future) histograms; resets per test suite.
- `compat/log`: JSONL records to stderr by default; integrate with tracing backends later.
- `/debug/compat/stats`: HTTP endpoint for quick inspection; extend to include protocol state (connections, auth errors) as modules land.

## Extension Points

- **Fallback routing:** optional module to forward unsupported queries to a real PostgreSQL instance (`compat.fallback`).
- **Policy engine:** session GUCs such as `sydraql.strict` or `sydra.compat.profile` to toggle translator behaviour.
- **Test harnesses:** wire-level simulators that can be embedded into integration tests or fuzzing utilities.

Track open questions and decisions at the bottom of this file as they arise.

## Open Questions

- Do we persist OIDs inside sydra catalog storage or reconstruct them at boot from deterministic hashing?
- Should COPY buffering live in the protocol front-end or reuse existing bulk-ingest pipelines directly?
- What is the minimum subset of PostgreSQL extensions (uuid-ossp, pgcrypto) we are comfortable stubbing for v0.1?

Contributions welcome—update sections when components evolve.
