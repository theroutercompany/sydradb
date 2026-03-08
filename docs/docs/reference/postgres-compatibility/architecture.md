---
sidebar_position: 2
sidebar_label: Architecture
---

# PostgreSQL Compatibility Architecture

This note describes the intended ownership boundaries of the PostgreSQL compatibility bridge. It currently mixes implemented pieces with planned ones; for the supported alpha surface, treat [`roadmap`](./roadmap.md) as the more important source of truth.

## High-Level Components

1. **Protocol Front-End**
   - Current: accepts TCP connections, performs the startup/auth-ok flow, and supports the implemented simple-query path.
   - Planned later: TLS, extended protocol, COPY, and richer session state.
   - Emits decoded SQL queries to the translator and receives sydraQL execution results from the engine.

2. **SQL Translator**
   - Parses incoming PostgreSQL SQL (leveraging the planned grammar work) and converts it into sydraQL AST nodes.
   - Applies rewrite rules (e.g., identifier casing, array indexing adjustments) and annotates semantic gaps with SQLSTATE codes.
   - Integrates with `compat.sqlstate` to standardise error payloads and with `compat.log` for structured observability.

3. **Catalog & Introspection Shim**
   - Current: a small in-memory catalog snapshot/debug surface.
   - Planned later: broader `pg_catalog` and `information_schema` coverage plus richer compatibility helpers.

4. **Execution Bridge**
   - Receives sydraQL plans from the translator, executes them against the engine, and maps results into PostgreSQL wire tuples.
   - Current focus: supported translator subset plus SQLSTATE/error mapping for the implemented path.
   - Planned later: COPY in/out streaming and broader compatibility semantics.

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

- Each client connection is currently handled in a straightforward connection loop against the existing sydra runtime.
- COPY-specific buffering and prepared-statement cache design remain future work.
- Translator caches and broader session-state design should stay explicit as the bridge expands.

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
