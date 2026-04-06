---
sidebar_position: 3
tags:
  - http
  - api
---

# HTTP API

Implementation reference: [`src/sydra/http.zig`](./source/sydra/http.md).

## Authentication

If [`auth_token`](./configuration.md#auth_token-string) is set in `sydradb.toml`, all routes under `/api/*` require:

```
Authorization: Bearer <auth_token>
```

Implementation: [`handleRequest` auth guard](./source/sydra/http.md#request-routing-and-auth).

## `GET /metrics`

Returns Prometheus text exposition.

Implementation: [`handleMetrics`](./source/sydra/http.md#fn-handlemetrics-void).

## `GET /status`

Returns a lightweight JSON health snapshot with:

- `status`
- `cas_mode`
- `metadata_read_mode`
- `query_compiler_mode`
- `compatibility_debt.legacy_segment_descriptors`
- `compatibility_debt.legacy_wal_descriptors`
- `compatibility_debt.loose_refs_present`
- `runtime.queue_depth`
- `runtime.memtable_bytes`
- `runtime.flush_total`
- `runtime.flush_points_total`
- `runtime.flush_seconds_total`
- `runtime.wal_append_total`
- `runtime.wal_append_seconds_total`
- `runtime.ingest_total`
- `runtime.ingest_rejected_total`
- `runtime.ingest_rejected_mem_limit_total`
- `runtime.wal_bytes_total`
- `runtime.wal_append_failed_total`
- `runtime.memtable_append_failed_total`
- `runtime.ingest_quarantined_total`
- `runtime.ingest_quarantine_write_failed_total`
- `runtime.cas_sync_total`
- `runtime.cas_sync_failed_total`
- `runtime.cas_sync_seconds_total`
- `runtime.query_compile_attempts_total`
- `runtime.query_compile_success_total`
- `runtime.query_compile_fallback_total`
- `runtime.query_compile_unsupported_total`
- `runtime.query_compile_series_not_found_total`
- `runtime.query_compile_ambiguous_selector_total`
- `runtime.query_compile_shadow_mismatch_total`
- `runtime.cas_shadow_mismatch_total`

Example:

```json
{
  "status": "ok",
  "cas_mode": "dual_write",
  "metadata_read_mode": "primary",
  "query_compiler_mode": "compiled",
  "compatibility_debt": {
    "legacy_segment_descriptors": 0,
    "legacy_wal_descriptors": 0,
    "loose_refs_present": 0
  },
  "runtime": {
    "queue_depth": 0,
    "memtable_bytes": 0,
    "flush_total": 3,
    "flush_points_total": 17,
    "flush_seconds_total": 0.125,
    "wal_append_total": 19,
    "wal_append_seconds_total": 0.004,
    "ingest_total": 42,
    "ingest_rejected_total": 1,
    "ingest_rejected_mem_limit_total": 1,
    "wal_bytes_total": 2048,
    "wal_append_failed_total": 0,
    "memtable_append_failed_total": 0,
    "ingest_quarantined_total": 0,
    "ingest_quarantine_write_failed_total": 0,
    "cas_sync_total": 3,
    "cas_sync_failed_total": 0,
    "cas_sync_seconds_total": 0.031,
    "query_compile_attempts_total": 9,
    "query_compile_success_total": 6,
    "query_compile_fallback_total": 3,
    "query_compile_unsupported_total": 2,
    "query_compile_series_not_found_total": 1,
    "query_compile_ambiguous_selector_total": 0,
    "query_compile_shadow_mismatch_total": 0,
    "cas_shadow_mismatch_total": 0
  }
}
```

## `POST /api/v1/ingest`

Consumes NDJSON (newline-delimited JSON). Each line is an object with:

- `series` (string, required)
- `ts` (integer, required)
- `value` (number, optional)
- `fields` (object, optional): if `value` is missing, the first numeric field is used
- `tags` (object, optional)

Implementation: [`handleIngest`](./source/sydra/http.md#fn-handleingest-void).

Returns:

```json
{"ingested":123}
```

Error cases:

- A line that exceeds the internal buffer fails the request with `413 Payload Too Large`.
- If ingest backpressure is hit, the request fails with a JSON error and `503 Service Unavailable`.

## `POST /api/v1/query/range`

Requires `Content-Length` and a JSON body:

- `start` (integer, required)
- `end` (integer, required)
- `series_id` (integer) **or** `series` (string)
- `tags` (object, optional; used when hashing `series` → `series_id`)

Returns a JSON array:

```json
[{"ts":1694300000,"value":24.2}]
```

Implementation: [`handleQuery` (POST JSON)](./source/sydra/http.md#fn-handlequery-void-post-json).

## `GET /api/v1/query/range?...`

Query parameters:

- `series_id=<u64>` (preferred) or `series=<string>`
- `tags=<string>` (optional, defaults to `{}`)
- `start=<i64>` (required)
- `end=<i64>` (required)

Returns the same JSON array as the POST form.

Implementation: [`handleQueryGet` (GET query string)](./source/sydra/http.md#fn-handlequeryget-void-get-query-string).

## `POST /api/v1/query/find`

Request JSON:

- `tags` (object): exact-match tag constraints (string values)
- `op` (string, optional): `"and"` (default) or `"or"`

Response JSON: array of matching `series_id` values.

Implementation: [`handleFind`](./source/sydra/http.md#fn-handlefind-void).

## `POST /api/v1/sydraql`

Request body is **plain text** sydraQL.

Response JSON object:

- `columns`: array of `{name,type,nullable}`
- `rows`: array of row arrays
- `stats`: execution timings and operator stats

Error responses for `/api/*` are JSON:

```json
{"error":"query required","code":"query_required","status":400}
```

For sydraQL specifically, `code` now distinguishes:

- `parse_failed` – lexer/parser failures such as unexpected tokens or malformed literals
- `validation_failed` – syntactically valid queries that fail semantic validation
- `unsupported_query_shape` – shapes that the current compiled/runtime contract does not support
- `shadow_mismatch` – shadow-mode verification failures
- `query_too_large` – query text exceeds the current `65536` byte execution ceiling
- `execution_error` – other runtime failures that do not fit the categories above

Implementation:

- [`handleSydraql`](./source/sydra/http.md#fn-handlesydraql-void)
- [Query execution entrypoint (`exec.execute`)](./source/sydra/query/exec.md)

## Debug endpoints

- `GET /debug/compat/stats` – JSON counters
- `GET /debug/compat/catalog` – JSON snapshot of compat catalog objects
- `GET /debug/alloc/stats` – JSON allocator stats (only in `small_pool` allocator mode)

See also:

- [`SeriesId` derivation and caveats](./series-ids.md)
- [Configuration](./configuration.md) (auth, ports, data dir)
