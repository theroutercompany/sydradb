---
sidebar_position: 1
---

# Architecture overview

This page provides a high-level map of SydraDB’s runtime surfaces and where they live in the source tree.

## Entry points and surfaces

- **Process entry**: `src/main.zig` → `src/sydra/server.zig`
- **HTTP server**: `src/sydra/http.zig`
- **Core engine**: `src/sydra/engine.zig`
- **PostgreSQL compatibility (pgwire)**: `src/sydra/compat/` (invoked via `sydradb pgwire`)
- **sydraQL**: `src/sydra/query/` (invoked via `POST /api/v1/sydraql`)

## Ingest and storage flow (high level)

1. Requests arrive via:
   - HTTP `POST /api/v1/ingest` (NDJSON), or
   - CLI `sydradb ingest` (NDJSON via stdin)
2. The engine enqueues ingest items.
3. A writer loop:
   - Appends to WAL
   - Inserts into the in-memory memtable
4. When flush conditions hit (time-based or size-based), the engine:
   - Writes per-series segments
   - Updates the manifest
   - Applies retention (best-effort, if enabled)

See also:

- On-disk structures: `Reference/On-Disk Format v0 (Draft)`

## Query flow (high level)

- **Range query**:
  - HTTP `POST /api/v1/query/range` or `GET /api/v1/query/range?...`
  - Delegates to the engine range-query path and returns a JSON array of points.
- **sydraQL**:
  - HTTP `POST /api/v1/sydraql` executes a query pipeline and returns columns, rows, and execution stats.
  - Design details: `Concepts/sydraQL Design`
  - Implementation notes (supplementary): `Architecture/sydraDB Architecture & Engineering Design (Supplementary, Oct 18 2025)`

