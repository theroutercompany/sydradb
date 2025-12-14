---
sidebar_position: 1
title: Compatibility layer overview (src/sydra/compat)
---

# Compatibility layer overview (`src/sydra/compat*`)

This set of modules provides SydraDB’s PostgreSQL-compatibility “edges”:

- A minimal SQLSTATE mapping and error payload format
- A tiny, in-memory catalog snapshot builder (namespaces/relations/attributes/types)
- A PostgreSQL wire-protocol (`pgwire`) listener that accepts clients like `psql`
- Translation telemetry (counters + JSONL event recorder)
- Test fixtures for SQL→sydraQL translation

## Module map

- Root re-exports: `src/sydra/compat.zig` → `compat-zig`
- Telemetry:
  - Counters: `src/sydra/compat/stats.zig` → `stats`
  - JSONL recorder: `src/sydra/compat/log.zig` → `log`
- Errors:
  - SQLSTATE subset + payload builder: `src/sydra/compat/sqlstate.zig` → `sqlstate`
- Catalog:
  - Snapshot builder/store: `src/sydra/compat/catalog.zig` → `catalog`
- Pgwire:
  - Re-exports: `src/sydra/compat/wire.zig` → `wire`
  - Startup + message writers: `src/sydra/compat/wire/protocol.zig` → `wire-protocol`
  - Handshake/session metadata: `src/sydra/compat/wire/session.zig` → `wire-session`
  - Listener + query loop: `src/sydra/compat/wire/server.zig` → `wire-server`
- Fixtures:
  - Translator test loader: `src/sydra/compat/fixtures/translator.zig` → `fixtures-translator`

## How pgwire executes a query (happy path)

1. `wire/protocol.readStartup` parses the startup packet (and declines SSL).
2. `wire/session.performHandshake` responds with:
   - `AuthenticationOk`
   - multiple `ParameterStatus`
   - `ReadyForQuery`
3. `wire/server.messageLoop` reads frontend messages.
4. For a Simple Query (`Q`) message, `wire/server.handleSimpleQuery`:
   - translates SQL → sydraQL via `src/sydra/query/translator.zig`
   - executes sydraQL via `src/sydra/query/exec.zig`
   - streams results as `RowDescription` + `DataRow*`
   - emits `NoticeResponse` diagnostics (schema, trace id, operator stats)
   - completes with `CommandComplete` and `ReadyForQuery`

## Key limitations (current code)

- SSL/TLS: not implemented (SSLRequest is declined).
- Cancel requests: not supported.
- Extended query protocol: not implemented (Parse message returns a `0A000` error).
- Types: `RowDescription` uses a single “default” type mapping for all columns.

