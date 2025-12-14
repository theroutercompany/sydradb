---
sidebar_position: 3
---

# Ingest and query

## Ingest (HTTP)

`POST /api/v1/ingest` accepts NDJSON (newline-delimited JSON). Each line is an object with:

- `series` (string, required)
- `ts` (integer, required)
- `value` (number, optional)
- `fields` (object, optional): if `value` is missing, the first numeric field is used
- `tags` (object, optional): converted to a JSON string and hashed into the series id

Example:

```sh
curl -XPOST localhost:8080/api/v1/ingest --data-binary $'{"series":"weather.room1","ts":1694300000,"value":24.2,"tags":{"site":"home","sensor":"a"}}\\n'
```

Response:

```json
{"ingested":1}
```

## Query range (HTTP)

### POST JSON

`POST /api/v1/query/range` takes JSON:

```json
{"series":"weather.room1","start":1694290000,"end":1694310000}
```

You can also pass `series_id` (integer) instead of `series`.

The response is a JSON array of points:

```json
[{"ts":1694300000,"value":24.2}]
```

### GET query parameters

`GET /api/v1/query/range` supports:

- `series_id=<u64>` (preferred) or `series=<string>`
- `tags=<string>` (defaults to `{}`) — passed into the series hash as-is
- `start=<i64>` (required)
- `end=<i64>` (required)

Example:

```sh
curl 'http://localhost:8080/api/v1/query/range?series=weather.room1&start=1694290000&end=1694310000'
```

## Find series by tags (HTTP)

`POST /api/v1/query/find` accepts JSON:

- `tags` (object): exact-match on tag key/value pairs
- `op` (string, optional): `"and"` (default) or `"or"` for combining tag filters

Response is an array of matching `series_id` values.

## sydraQL (HTTP)

`POST /api/v1/sydraql` expects the request body to be **plain text** containing a sydraQL query.

Response shape:

- `columns`: array of `{name,type,nullable}`
- `rows`: array of row arrays
- `stats`: timings and operator stats

## Ingest/query via CLI

`sydradb ingest` reads NDJSON from stdin and writes to the local WAL:

```sh
cat points.ndjson | ./zig-out/bin/sydradb ingest
```

`sydradb query <series_id> <start_ts> <end_ts>` prints `ts,value` rows:

```sh
./zig-out/bin/sydradb query 123 1694290000 1694310000
```

