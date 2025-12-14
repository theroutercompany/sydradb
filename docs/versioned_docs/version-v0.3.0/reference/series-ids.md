---
sidebar_position: 4
---

# Series IDs

Many surfaces refer to a `series_id` (an unsigned 64-bit integer).

## Hashing scheme

For HTTP ingest/query when specifying `series` (and optional `tags`), the series id is computed as:

```
xxhash64(series + "|" + tags_json)
```

Where `tags_json` is the JSON string for the tags object (or `{}` when absent).

## Important implications

- The tags JSON representation is part of the hash input. If clients send the same tags with different key order, they may produce different `series_id` values.
- `sydradb ingest` (CLI) currently hashes only `series` (no `|{}` suffix), so its ids do not match the HTTP `series_id` scheme unless explicitly aligned.

## Practical guidance

- Prefer using `/api/v1/ingest` and `/api/v1/query/range` consistently when working with tags.
- If you already have a `series_id`, prefer passing it directly (HTTP: `series_id`, CLI: `query <series_id> ...`).

