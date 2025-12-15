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

- Root re-exports: [`src/sydra/compat.zig`](./compat-zig.md)
- Telemetry:
  - Counters: [`src/sydra/compat/stats.zig`](./stats.md)
  - JSONL recorder: [`src/sydra/compat/log.zig`](./log.md)
- Errors:
  - SQLSTATE subset + payload builder: [`src/sydra/compat/sqlstate.zig`](./sqlstate.md)
- Catalog:
  - Snapshot builder/store: [`src/sydra/compat/catalog.zig`](./catalog.md)
- Pgwire:
  - Re-exports: [`src/sydra/compat/wire.zig`](./wire.md)
  - Startup + message writers: [`src/sydra/compat/wire/protocol.zig`](./wire-protocol.md)
  - Handshake/session metadata: [`src/sydra/compat/wire/session.zig`](./wire-session.md)
  - Listener + query loop: [`src/sydra/compat/wire/server.zig`](./wire-server.md)
- Fixtures:
  - Translator test loader: [`src/sydra/compat/fixtures/translator.zig`](./fixtures-translator.md)

## See also

- [Reference: PostgreSQL Compatibility](../../../postgres-compatibility/architecture.md) (design notes)
- [Query pipeline overview](../query/overview.md)

## How pgwire executes a query (happy path)

1. [`wire/protocol.readStartup`](./wire-protocol.md) parses the startup packet (and declines SSL).
2. [`wire/session.performHandshake`](./wire-session.md) responds with:
   - `AuthenticationOk`
   - multiple `ParameterStatus`
   - `ReadyForQuery`
3. [`wire/server.messageLoop`](./wire-server.md) reads frontend messages.
4. For a Simple Query (`Q`) message, [`wire/server.handleSimpleQuery`](./wire-server.md) does:
   - SQL → sydraQL via [`src/sydra/query/translator.zig`](../query/translator.md)
   - execution via [`src/sydra/query/exec.zig`](../query/exec.md)
   - streams results as `RowDescription` + `DataRow*`
   - emits `NoticeResponse` diagnostics (schema, trace id, operator stats)
   - completes with `CommandComplete` and `ReadyForQuery`

## Key limitations (current code)

- SSL/TLS: not implemented (SSLRequest is declined).
- Cancel requests: not supported.
- Extended query protocol: not implemented (Parse message returns a `0A000` error).
- Types: `RowDescription` uses a single “default” type mapping for all columns.

## Code excerpt (root re-exports)

```zig title="src/sydra/compat.zig"
pub const stats = @import("compat/stats.zig");
pub const sqlstate = @import("compat/sqlstate.zig");
pub const clog = @import("compat/log.zig");
pub const fixtures = struct {
    pub const translator = @import("compat/fixtures/translator.zig");
};
pub const catalog = @import("compat/catalog.zig");
pub const wire = @import("compat/wire.zig");
```
