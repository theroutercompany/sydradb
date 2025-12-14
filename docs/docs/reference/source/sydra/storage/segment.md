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

```zig title="SYSEG2 header write (excerpt)"
try writer.writeAll("SYSEG2");

var tmp8: [8]u8 = undefined;
std.mem.writeInt(u64, &tmp8, series_id, .little);
try writer.writeAll(tmp8[0..8]);
std.mem.writeInt(i64, &tmp8, hour, .little);
try writer.writeAll(tmp8[0..8]);

var tmp4: [4]u8 = undefined;
const cnt_u32: u32 = @intCast(points.len);
std.mem.writeInt(u32, &tmp4, cnt_u32, .little);
try writer.writeAll(tmp4[0..4]);

std.mem.writeInt(i64, &tmp8, points[0].ts, .little);
try writer.writeAll(tmp8[0..8]);
std.mem.writeInt(i64, &tmp8, points[points.len - 1].ts, .little);
try writer.writeAll(tmp8[0..8]);

try writer.writeByte(1); // ts codec
try writer.writeByte(1); // val codec
```

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

```zig title="Codec usage (excerpt)"
// Encode timestamps (delta-of-delta zigzag varint)
try @import("../codec/gorilla.zig").encodeTsDoD(writer, points[0].ts, points);

// Encode values using gorilla-like XOR
var vals = try alloc.alloc(f64, points.len);
defer alloc.free(vals);
for (points, 0..) |p, i| vals[i] = p.value;
try @import("../codec/gorilla.zig").encodeF64(writer, vals);
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

```zig title="Manifest overlap checks (excerpt)"
for (manifest.entries.items) |e| {
    if (e.series_id != series_id) continue;
    if (e.end_ts < start_ts or e.start_ts > end_ts) continue;
    // open segment and scan points...
}
```

```zig title="Per-point filtering (excerpt)"
if (ts >= start_ts and ts <= end_ts) {
    try out.append(.{ .ts = ts, .value = val });
}
```
