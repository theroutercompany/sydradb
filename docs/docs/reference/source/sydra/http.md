---
sidebar_position: 4
title: src/sydra/http.zig
---

# `src/sydra/http.zig`

## Purpose

Implements SydraDB’s HTTP server:

- Accepts TCP connections and parses HTTP requests
- Routes requests to API handlers (`/api/v1/*`, `/metrics`, `/debug/*`)
- Bridges HTTP requests into the engine (ingest/query) and sydraQL execution

For the user-facing contract, see `Reference/HTTP API`.

## Public API

### `pub fn runHttp(handle: *alloc_mod.AllocatorHandle, eng: *Engine, port: u16) !void`

- Binds `0.0.0.0:<port>` with `reuse_address = true`.
- Accepts connections in a loop.
- Spawns a detached thread per connection (`connectionWorker`).

## Connection lifecycle

### `fn connectionWorker(...) void`

- Uses `std.heap.c_allocator` for request handling and JSON construction.
- Calls `handleConnection(...)`.

### `fn handleConnection(...) !void`

- Creates per-connection read/write buffers (`[4096]u8` each).
- Initializes `std.http.Server`.
- Loops `receiveHead()` and calls `handleRequest(...)`.

If `Expect: 100-continue` fails, the code replies `417 Expectation Failed` and closes the connection.

## Request routing and auth

### `fn handleRequest(...) !void`

Routing:

- Splits `req.head.target` into `path` and `query` at the first `?`.
- Enforces auth for `/api/*` only when `eng.config.auth_token` is non-empty:
  - Requires `Authorization: Bearer <token>`
  - Responds `401 unauthorized` with `keep_alive = false` on failure

Route table (path + method → handler):

- `GET /metrics` → `handleMetrics`
- `GET /debug/compat/stats` → `handleCompatStats`
- `GET /debug/compat/catalog` → `handleCompatCatalog`
- `GET /debug/alloc/stats` → `handleAllocStats`
- `GET /status` → `handleStatus` (see “Known issues” below)
- `POST /api/v1/ingest` → `handleIngest`
- `POST /api/v1/query/range` → `handleQuery`
- `GET /api/v1/query/range` → `handleQueryGet`
- `POST /api/v1/query/find` → `handleFind`
- `POST /api/v1/sydraql` → `handleSydraql`

## Handlers (high level)

### `fn handleMetrics(...) !void`

Emits Prometheus text exposition from engine counters, including:

- `sydradb_ingest_total`
- `sydradb_flush_total`
- `sydradb_flush_seconds_total`
- `sydradb_flush_points_total`
- `sydradb_wal_bytes_total`
- `sydradb_queue_depth`
- `sydradb_memtable_bytes`

### `fn handleIngest(...) !void`

Consumes NDJSON and ingests each line:

- Computes `series_id` using `types.seriesIdFrom(series, tags_json)`.
- If `tags` is present, it is stringified to JSON (`extractTagsJson`) and also recorded via `eng.noteTags(...)`.
- If `value` is missing, it will search `fields` for the first numeric value (iteration order dependent).

Returns `{"ingested":<count>}`.

### `fn handleQuery(...) !void` (POST JSON)

- Requires `Content-Length`.
- Expects JSON `{start,end,series_id|series[,tags]}`.
- Calls `queryAndRespond` and returns an array of points.

### `fn handleQueryGet(...) !void` (GET query string)

Supports query parameters:

- `series_id=<u64>` or `series=<string>`
- `tags=<string>` (defaults to `{}`)
- `start=<i64>` and `end=<i64>`

### `fn handleFind(...) !void`

Accepts JSON:

- `tags` (object): exact tag matches
- `op` (string): `"and"` (default) or `"or"`

Returns an array of `series_id` values.

### `fn handleSydraql(...) !void`

Executes sydraQL (`POST` body is plain text) and responds with:

- `columns`: column metadata
- `rows`: row arrays
- `stats`: timings + operator stats (via `writeStatsObject`)

## Utilities and local types

- `const default_tags_json = "{}"`
- `const TagsJson = struct { value: []const u8, owned: ?[]u8 }`
- `fn extractTagsJson(...) !TagsJson` – converts a JSON object into a JSON string
- `fn respondJsonError(...) !void` – `{"error":"..."}` error payloads
- `fn writeStatsObject(...) !void` – emits the `stats` object for sydraQL responses
- `fn findHeader(...) ?[]const u8` – case-insensitive header lookup

## Known issues (as observed in source)

- The `/status` route check uses `td.mem.eql` (typo) instead of `std.mem.eql`, which will prevent building until corrected in the source.

