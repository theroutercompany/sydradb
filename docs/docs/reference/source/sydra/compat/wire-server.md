---
sidebar_position: 11
title: src/sydra/compat/wire/server.zig
---

# `src/sydra/compat/wire/server.zig`

## Purpose

Provides a simple PostgreSQL wire-protocol (`pgwire`) listener suitable for basic compatibility testing with clients like `psql`.

The server:

- accepts a TCP connection
- performs a minimal startup handshake
- supports a small subset of frontend messages
- translates SQL → sydraQL and executes it via the regular query pipeline
- writes results as `RowDescription` + `DataRow` messages

## See also

- [wire protocol](./wire-protocol.md) (message framing + startup/response writers)
- [wire session](./wire-session.md) (handshake + session config)
- [wire re-exports](./wire.md)
- [SQL → sydraQL translator](../query/translator.md)
- [sydraQL execution entrypoint](../query/exec.md)
- [Reference: PostgreSQL Compatibility](../../../postgres-compatibility/architecture.md)

## Public API

### `pub const ServerConfig`

- `address: []const u8 = "127.0.0.1"`
- `port: u16 = 6432`
- `session: session_mod.SessionConfig = .{}`
- `engine: *engine_mod.Engine`

### `pub fn run(alloc, config) !void`

- Listens on `address:port` with `reuse_address = true`.
- Runs an accept loop; each connection is handled synchronously via `handleConnection`.

### `pub fn handleConnection(alloc, connection, session_config, engine) !void`

- Wraps the socket in buffered reader/writer states.
- Calls `session_mod.performHandshake`.
- On success enters `messageLoop`.

## Frontend message support

`messageLoop` reads:

- `type_byte: u8`
- `message_length: u32be` (includes the 4-byte length field)
- `payload: message_length - 4` bytes

It enforces:

- `message_length >= 4`
- `payload_len <= 16 MiB` (`max_message_size`)

Handled message types:

- `'X'` – Terminate: close the connection.
- `'Q'` – Simple Query: handled by `handleSimpleQuery` (SQL→sydraQL→execute).
- `'P'` – Parse (extended protocol): `handleParseMessage` validates framing but returns `0A000` on success (“not implemented yet”).
- `'S'` – Responds with `ReadyForQuery('I')` (acts as a simple sync/flush).
- Anything else:
  - `ErrorResponse("0A000", "message type not implemented")`
  - `ReadyForQuery('I')`

```zig title="messageLoop dispatch (excerpt)"
switch (type_byte) {
    'X' => return,
    'Q' => {
        try handleSimpleQuery(alloc, writer, payload_storage, engine);
    },
    'P' => {
        try handleParseMessage(alloc, writer, payload_storage);
    },
    'S' => {
        try protocol.writeReadyForQuery(writer, 'I');
    },
    else => {
        try protocol.writeErrorResponse(writer, "ERROR", "0A000", "message type not implemented");
        try protocol.writeReadyForQuery(writer, 'I');
    },
}
```

## Simple Query execution

### `fn handleSimpleQuery(alloc, writer, payload, engine) !void`

Behavior:

- Trims a trailing NUL byte from `payload` (C-string style).
- Trims whitespace.
- If empty:
  - writes `EmptyQueryResponse` then `ReadyForQuery('I')`
- Otherwise:
  - calls `translator.translate(alloc, sql)` (see [SQL → sydraQL translator](../query/translator.md))
    - on OOM: `ErrorResponse(FATAL, 53100, "out of memory during translation")`
  - on translation success:
    - calls `handleSydraqlQuery(…, sydraql)`
  - on translation failure:
    - writes `ErrorResponse(ERROR, failure.sqlstate, failure.message or "translation failed")`
- always ends with `ReadyForQuery('I')`

```zig title="SQL → sydraQL translation (excerpt)"
const translation = translator.translate(alloc, trimmed) catch |err| switch (err) {
    error.OutOfMemory => {
        try protocol.writeErrorResponse(writer, "FATAL", "53100", "out of memory during translation");
        try protocol.writeReadyForQuery(writer, 'I');
        return;
    },
};

switch (translation) {
    .success => |success| {
        defer alloc.free(success.sydraql);
        try handleSydraqlQuery(alloc, writer, engine, success.sydraql);
        try protocol.writeReadyForQuery(writer, 'I');
        return;
    },
    .failure => |failure| {
        const msg = if (failure.message.len == 0) "translation failed" else failure.message;
        try protocol.writeErrorResponse(writer, "ERROR", failure.sqlstate, msg);
        try protocol.writeReadyForQuery(writer, 'I');
    },
}
```

## Extended protocol parse (partial)

### `fn handleParseMessage(alloc, writer, payload) !void`

Parses enough of the frontend `Parse` message to report a deterministic response:

- Reads:
  - `statement_name` as NUL-terminated string
  - `query` as NUL-terminated string
  - `parameter_count` (`u16be`)
  - validates presence of `parameter_count * 4` bytes for parameter type OIDs
- Translates `query` via `translator.translate`.
- If translation succeeds, responds:
  - `ErrorResponse(ERROR, 0A000, "extended protocol not implemented yet")`
- If translation fails, responds with the translator’s SQLSTATE/message.
- Always ends with `ReadyForQuery('I')`.

No prepared statement state is stored, and no subsequent `Bind/Execute` messages are handled.

## SydraQL execution + result encoding

### `fn handleSydraqlQuery(alloc, writer, engine, sydraql) !void`

Execution:

- Calls [`query_exec.execute`](../query/exec.md) to create an `ExecutionCursor`.
- Streams:
  1. `RowDescription` (even for zero columns; then `columns.len` is `0`)
  2. `DataRow` for each row returned by `cursor.next()`

Diagnostics:

- Collects operator stats via `cursor.collectOperatorStats`.
- Computes:
  - `rows_emitted` (from stream count)
  - `rows_scanned` (sum of operator `rows_out` where operator name is `"scan"`, case-insensitive)
  - `stream_ms` from wall time
  - `plan_ms` from `cursor.stats.{parse,validate,optimize,physical,pipeline}_us`
- Emits `NoticeResponse` messages:
  - `schema=[{name:\"...\",type:\"...\",nullable:true}, ...]` (for non-empty schemas)
  - `trace_id=...` (when `cursor.stats.trace_id` is present)
  - `operator=... rows_out=... elapsed_ms=...` for each operator stat
- Completes with:
  - `CommandComplete` tag `SELECT rows=… scanned=… stream_ms=… plan_ms=… [trace_id=…]`
  - `ReadyForQuery('I')`

### `fn writeRowDescription(writer, columns) !void`

Writes pgwire `RowDescription` (`'T'`) using:

- the column name (`plan.ColumnInfo.name`)
- placeholder table/attribute identifiers (`0`)
- a single “default type” mapping for every column (`query_functions.pgTypeInfo(Type.init(.value, true))`; see [src/sydra/query/functions.zig](../query/functions.md))

### `fn writeDataRow(writer, values, row_buffer, value_buffer) !void`

Writes pgwire `DataRow` (`'D'`) in **text format** for every value:

- Each value is preceded by a 4-byte `i32be` length.
- Null values use length `-1`.

### `fn formatValue(value, buf) !?[]const u8`

Text formatting rules:

- `null` → `null` (caller encodes `-1`)
- `boolean` → `"t"` or `"f"`
- `integer` → decimal string
- `float` → decimal string via `{d}`
- `string` → byte slice as-is

## Other internal helpers

- `trimNullTerminator` trims a trailing `0` byte from query payloads.
- `readU32` reads big-endian lengths.
- `readCString` parses NUL-terminated strings from a buffer.
- `parseAddress` parses IPv4 or IPv6.
- `anyWriter` adapts a `std.Io.Writer` into `std.Io.AnyWriter`.
- `formatSelectTag` formats the `CommandComplete` tag (with optional `trace_id`).
