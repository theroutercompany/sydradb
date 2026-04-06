---
sidebar_position: 3
tags:
  - getting-started
  - api
---

# Ingest and query

## Ingest (HTTP)

[`POST /api/v1/ingest`](../reference/http-api.md#post-apiv1ingest) accepts NDJSON (newline-delimited JSON). Each line is an object with:

- Preferred telemetry envelope:
  - `metric` (string, required)
  - `ts` (integer, required)
  - `value` (number, optional)
  - `fields` (object, optional): numeric-only sibling metrics
  - `labels` (object, optional)
  - `kind`, `unit`, `description` (optional metric metadata)
- `series` (string, required)
- `ts` (integer, required)
- `value` (number, optional)
- `fields` (object, optional): if `value` is missing, the first numeric field is used
- `tags` (object, optional): converted to a JSON string and hashed into the series id (see [Series IDs](../reference/series-ids.md))

Example:

```sh
curl -XPOST localhost:8080/api/v1/ingest --data-binary $'{"metric":"requests_total","ts":1694300000,"value":42,"labels":{"service":"api","host":"edge-1"},"kind":"counter","unit":"requests"}\\n'
```

Response:

```json
{"ingested":1}
```

## Query range (HTTP)

### POST JSON

[`POST /api/v1/query/range`](../reference/http-api.md#post-apiv1queryrange) takes JSON:

```json
{"metric":"requests_total","labels":{"service":"api","host":"edge-1"},"start":1694290000,"end":1694310000}
```

You can also pass `series_id` (integer) instead of `series`.

The response is a JSON array of points:

```json
[{"ts":1694300000,"value":24.2}]
```

### GET query parameters

[`GET /api/v1/query/range`](../reference/http-api.md#get-apiv1queryrange) supports:

- `series_id=<u64>` (preferred) or `series=<string>`
- `metric=<string>`
- `labels=<string>` (canonical JSON object)
- `tags=<string>` (defaults to `{}`) — passed into the series hash as-is
- `start=<i64>` (required)
- `end=<i64>` (required)

Example:

```sh
curl 'http://localhost:8080/api/v1/query/range?series=weather.room1&start=1694290000&end=1694310000'
```

## Discover metrics and series (HTTP)

`POST /api/v1/metrics/find` returns metric descriptors such as `metric`, `kind`, `series_count`, `label_keys`, and time bounds.

`POST /api/v1/series/find` returns exact series descriptors for one metric family, including canonical `labels`.

`POST /api/v1/labels/values` returns known values for one label key, optionally scoped to a metric family.

`POST /api/v1/metrics/health` returns per-metric operator health such as missing metadata, inactive series counts, and last-seen timestamps.

## Compare windows (HTTP)

Use `POST /api/v1/query/compare` to compare one exact series across two time windows:

```json
{
  "metric":"requests_total",
  "labels":{"service":"api","host":"edge-1"},
  "start":1694300000,
  "end":1694303600,
  "baseline_start":1694296400,
  "baseline_end":1694300000,
  "aggregate":"delta"
}
```

For counters, `delta` is reset-aware, which makes this endpoint useful for before/after deploy checks.

## Write and query annotations (HTTP)

Use `POST /api/v1/annotations/write` to persist deploy markers, incident notes, or maintenance windows:

```json
{
  "kind":"deploy",
  "title":"api rollout",
  "metric":"requests_total",
  "labels":{"service":"api"},
  "start":1694300100,
  "message":"rolled out build 2026.04.06"
}
```

Use `POST /api/v1/annotations/query` to fetch those markers for a time range and metric scope.

## Find series by tags (legacy HTTP)

[`POST /api/v1/query/find`](../reference/http-api.md#post-apiv1queryfind) accepts JSON:

- `tags` (object): exact-match on tag key/value pairs
- `op` (string, optional): `"and"` (default) or `"or"` for combining tag filters

Response is an array of matching `series_id` values.

## sydraQL (HTTP)

[`POST /api/v1/sydraql`](../reference/http-api.md#post-apiv1sydraql) expects the request body to be **plain text** containing a sydraQL query.

See also:

- [sydraQL design](../concepts/sydraql-design.md)
- [Source: query execution entrypoint](../reference/source/sydra/query/exec.md)

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

See also:

- [CLI](../reference/cli.md)
- [On-disk format](../reference/on-disk-format.md)
