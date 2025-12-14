---
sidebar_position: 3
---

# HTTP API

## Authentication

If `auth_token` is set in `sydradb.toml`, all routes under `/api/*` require:

```
Authorization: Bearer <auth_token>
```

## `GET /metrics`

Returns Prometheus text exposition.

## `POST /api/v1/ingest`

Consumes NDJSON (newline-delimited JSON). Each line is an object with:

- `series` (string, required)
- `ts` (integer, required)
- `value` (number, optional)
- `fields` (object, optional): if `value` is missing, the first numeric field is used
- `tags` (object, optional)

Returns:

```json
{"ingested":123}
```

Error cases:

- A line that exceeds the internal buffer fails the request with `413 Payload Too Large`.

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

## `GET /api/v1/query/range?...`

Query parameters:

- `series_id=<u64>` (preferred) or `series=<string>`
- `tags=<string>` (optional, defaults to `{}`)
- `start=<i64>` (required)
- `end=<i64>` (required)

Returns the same JSON array as the POST form.

## `POST /api/v1/query/find`

Request JSON:

- `tags` (object): exact-match tag constraints (string values)
- `op` (string, optional): `"and"` (default) or `"or"`

Response JSON: array of matching `series_id` values.

## `POST /api/v1/sydraql`

Request body is **plain text** sydraQL.

Response JSON object:

- `columns`: array of `{name,type,nullable}`
- `rows`: array of row arrays
- `stats`: execution timings and operator stats

## Debug endpoints

- `GET /debug/compat/stats` – JSON counters
- `GET /debug/compat/catalog` – JSON snapshot of compat catalog objects
- `GET /debug/alloc/stats` – JSON allocator stats (only in `small_pool` allocator mode)

