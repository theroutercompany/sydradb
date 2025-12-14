---
sidebar_position: 2
title: src/sydra/storage/manifest.zig
---

# `src/sydra/storage/manifest.zig`

## Purpose

Tracks persisted segment files and their time ranges.

The manifest is used to:

- Locate segments during range queries
- Build per-series “highwater” timestamps during WAL recovery

## Data model

### `pub const Entry`

Fields:

- `series_id: SeriesId`
- `hour_bucket: i64` – hour-aligned bucket timestamp
- `start_ts: i64`
- `end_ts: i64`
- `count: u32`
- `path: []u8` – segment file path (stored as an owned allocation)

```zig title="Entry (from src/sydra/storage/manifest.zig)"
pub const Entry = struct {
    series_id: types.SeriesId,
    hour_bucket: i64,
    start_ts: i64,
    end_ts: i64,
    count: u32,
    path: []u8,
};
```

### `pub const Manifest`

Fields:

- `alloc: std.mem.Allocator`
- `entries: std.ArrayListUnmanaged(Entry)`

## On-disk format

The manifest is stored in `MANIFEST` (in the data directory root) as newline-delimited JSON objects, one per segment entry.

## Public API

### `pub fn loadOrInit(alloc, data_dir) !Manifest`

- Ensures `segments/` exists.
- Ensures `MANIFEST` exists (creates an empty file if needed).
- Reads the full `MANIFEST` file (up to 64 MiB) and parses each non-empty line as JSON.
- Duplicates the `path` field per entry (`alloc.dupe`) so it remains valid after parsing.

```zig title="loadOrInit parsing loop (excerpt)"
const body = try file.readToEndAlloc(alloc, 1024 * 1024 * 64);
defer alloc.free(body);

var it = std.mem.tokenizeScalar(u8, body, '\n');
while (it.next()) |raw_line| {
    const s = std.mem.trim(u8, raw_line, " \t\r\n");
    if (s.len == 0) continue;

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, s, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    const sid = obj.get("series_id").?.integer;
    const hour = obj.get("hour_bucket").?.integer;
    const start_ts = obj.get("start_ts").?.integer;
    const end_ts = obj.get("end_ts").?.integer;
    const count = obj.get("count").?.integer;
    const path = obj.get("path").?.string;

    try mf.entries.append(alloc, .{
        .series_id = @intCast(sid),
        .hour_bucket = @intCast(hour),
        .start_ts = @intCast(start_ts),
        .end_ts = @intCast(end_ts),
        .count = @intCast(count),
        .path = try alloc.dupe(u8, path),
    });
}
```

### `pub fn add(self, data_dir, sid, hour, start_ts, end_ts, count, path) !void`

- Appends a JSON line to the `MANIFEST` file.
- Appends a corresponding `Entry` to the in-memory `entries` list (duplicating `path`).

```zig title="add() appends JSONL (excerpt)"
try file.seekFromEnd(0);
try writer.print(
    "{{\"series_id\":{d},\"hour_bucket\":{d},\"start_ts\":{d},\"end_ts\":{d},\"count\":{d},\"path\":\"{s}\"}}\n",
    .{ sid, hour, start_ts, end_ts, count, path },
);
try self.entries.append(self.alloc, .{
    .series_id = sid,
    .hour_bucket = hour,
    .start_ts = start_ts,
    .end_ts = end_ts,
    .count = count,
    .path = try self.alloc.dupe(u8, path),
});
```

### `pub fn maxEndTs(self: *const Manifest, sid: SeriesId) ?i64`

Returns the maximum `end_ts` for a given series id, or `null` if no entries exist.

### `pub fn deinit(self: *Manifest) void`

Frees all owned `Entry.path` allocations and deinitializes the entries list.
