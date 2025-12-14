---
sidebar_position: 3
title: src/sydra/storage/segment.zig
---

# `src/sydra/storage/segment.zig`

## Purpose

Reads and writes on-disk segment files containing points for a single series within an hour bucket.

The engine flush path writes segments; range queries read them back.

## Segment formats

### v1: `SYSEG2`

Header:

```
[magic:6 "SYSEG2"]
[series_id:u64][hour:i64][count:u32]
[start_ts:i64][end_ts:i64]
[ts_codec:u8][val_codec:u8]
```

Default codecs:

- `ts_codec = 1` – delta-of-delta + zigzag varint
- `val_codec = 1` – Gorilla-style XOR encoding

### v0 (back-compat): `SYSEG1`

- Timestamp deltas encoded as zigzag varints
- Values encoded as raw `f64` bits

## Public API

### `pub fn writeSegment(alloc, data_dir, series_id, hour, points) ![]const u8`

- Ensures `segments/<hour>/` exists.
- Writes a `SYSEG2` segment file.
- Uses codec helpers from `src/sydra/codec/gorilla.zig`:
  - `encodeTsDoD`
  - `encodeF64`
- Returns the created segment path as an owned string (`alloc.dupe`).

File naming pattern (under `segments/<hour>/`):

```
{series_id_hex}-{start_ts}-{end_ts}-{now_ms}.seg
```

### `pub fn readAll(alloc, data_dir, path) ![]Point`

Reads an entire segment file and returns a newly allocated `[]Point` slice.

### `pub fn queryRange(alloc, data_dir, manifest, series_id, start_ts, end_ts, out) !void`

Appends points within the time range to `out` by scanning relevant segment entries in the manifest.

Selection rules:

- Considers only entries where `e.series_id == series_id`.
- Skips segments whose `[start_ts,end_ts]` do not overlap the query.

Filtering rules (per point):

- Includes points where `ts >= start_ts` and `ts <= end_ts` (inclusive bounds).

Notes:

- This function appends results in manifest order; it does not perform global sorting or de-duplication across segments.

