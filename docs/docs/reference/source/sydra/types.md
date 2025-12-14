---
sidebar_position: 3
title: src/sydra/types.zig
---

# `src/sydra/types.zig`

## Purpose

Defines core shared types and hashing helpers used across the engine and HTTP surfaces.

## Public API

### `pub const SeriesId = u64`

Canonical identifier for a time series.

### `pub const Point = struct { ts: i64, value: f64 }`

Minimal point representation used by ingest/query paths.

### `pub fn hash64(data: []const u8) SeriesId`

Computes `XxHash64` over `data` with seed `0`.

Used by some call sites as a simple series-id derivation when only a series name is available.

### `pub fn seriesIdFrom(series: []const u8, tags_json: []const u8) SeriesId`

Computes `XxHash64` over:

```
series + "|" + tags_json
```

Implications:

- The exact `tags_json` string participates in the hash; differing whitespace or key order will produce different series IDs.

See also: `Reference/Series IDs`.

