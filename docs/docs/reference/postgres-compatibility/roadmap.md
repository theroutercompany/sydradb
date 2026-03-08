---
sidebar_position: 5
sidebar_label: Roadmap
---

# PostgreSQL Compatibility Roadmap

SydraDB currently treats PostgreSQL compatibility as a narrow bridge, not as the identity of the product.

Short-term goal:

- let simple PostgreSQL clients connect
- translate a small SQL subset into sydraQL
- expose enough status/diagnostic information to make that bridge debuggable

See also:

- `./compat-matrix-v0.1`
- `./testing`

## What exists today

- a PG v3 listener and startup/auth flow
- simple-query execution
- a small SQL translator subset
- SQLSTATE mapping helpers
- compatibility counters and logs
- a small in-memory catalog snapshot/debug surface

## What this cycle is optimizing for

- startup/auth-ok flow that is honest and testable
- simple query execution with the current translator subset
- standard `CommandComplete` behavior for the implemented path
- docs and tests that describe the current bridge accurately

## Explicitly unsupported this cycle

- TLS
- SCRAM-SHA-256
- extended protocol
- prepared statements and portals
- COPY
- full `pg_catalog` / `information_schema` coverage
- migration tooling and CDC-based cutover flows
- broad ORM unlock work

## Near-term backlog

### 1. Make the simple-query path honest

- keep the current protocol surface clearly documented
- tighten smoke coverage for startup and simple query handling
- make unsupported paths fail with explicit SQLSTATE/documented messages

### 2. Keep translator/docs/tests in sync

- describe the supported SQL subset in one place
- keep translator fixtures aligned with current behavior
- document the escape hatch for direct sydraQL where relevant

### 3. Treat the catalog shim as scaffold, not parity

- maintain the current debug catalog snapshot for visibility
- avoid over-claiming parity until real coverage lands

## Deferred until after the current alpha reset

- deeper catalog emulation
- prepared statement/session state compatibility
- ORM trace harnesses and broader regression suites
- schema/data migration tooling
- low-downtime cutover support
