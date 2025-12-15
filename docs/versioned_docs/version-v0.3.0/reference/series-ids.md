---
sidebar_position: 4
tags:
  - series
  - hashing
---

# Series IDs

Many surfaces refer to a `series_id` (an unsigned 64-bit integer).

Implementation reference:

- [`types.seriesIdFrom(series, tags_json)`](./source/sydra/types.md#pub-fn-seriesidfromseries-const-u8-tags_json-const-u8-seriesid) (HTTP hashing input)
- [`types.hash64(series)`](./source/sydra/types.md#pub-fn-hash64data-const-u8-seriesid) (CLI hashing input)

## Hashing scheme

For HTTP ingest/query when specifying `series` (and optional `tags`), the series id is computed as:

```
xxhash64(series + "|" + tags_json)
```

Where `tags_json` is the JSON string for the tags object (or `{}` when absent).

## Important implications

- The tags JSON representation is part of the hash input. If clients send the same tags with different key order, they may produce different `series_id` values.
- `sydradb ingest` (CLI) currently hashes only `series` (no `|{}` suffix), so its ids do not match the HTTP `series_id` scheme unless explicitly aligned.

Where this happens in the implementation:

- HTTP ingest derives IDs in [`handleIngest`](./source/sydra/http.md#fn-handleingest-void).
- CLI ingest derives IDs in [`cmdIngest`](./source/sydra/server.md#fn-cmdingestalloc-stdmemallocator-args-0u8-void).

## Practical guidance

- Prefer using `/api/v1/ingest` and `/api/v1/query/range` consistently when working with tags.
- If you already have a `series_id`, prefer passing it directly (HTTP: `series_id`, CLI: `query <series_id> ...`).

See also:

- [HTTP API](./http-api.md)
- [Ingest and query](../getting-started/ingest-and-query.md)
