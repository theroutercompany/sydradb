---
sidebar_position: 6
title: src/sydra/storage/compact.zig
---

# `src/sydra/storage/compact.zig`

## Purpose

Implements a size-tiered compaction stub:

- Groups segments by `(series_id, hour_bucket)`
- Merges multiple segments into a single consolidated segment
- De-duplicates points by timestamp (`ts`), “last wins”

## Public API

### `pub fn compactAll(alloc, data_dir, manifest) !void`

High-level behavior:

1. Groups manifest entries by `(series_id, hour_bucket)`.
2. For each group with more than one entry:
   - Reads all points from each segment (`segment.readAll`)
   - Sorts by `ts`
   - De-duplicates by `ts` (keeps the last point for the timestamp)
   - Writes a new segment (`segment.writeSegment`)
   - Deletes old segment files (best-effort)
   - Removes old entries from the in-memory manifest and adds a new entry via `manifest.add`

Notes:

- The manifest file (`MANIFEST`) is append-only; compaction does not rewrite it.
- The compactor is memory-heavy (loads all points for a group into memory).

```zig title="Grouping by (series_id, hour_bucket) (excerpt)"
const Key = struct { s: u64, h: i64 };
var groups = std.AutoHashMap(Key, std.array_list.Managed(usize)).init(alloc);
defer groups.deinit();

for (manifest.entries.items, 0..) |e, idx| {
    const key: Key = .{ .s = e.series_id, .h = e.hour_bucket };
    var gop = try groups.getOrPut(key);
    if (!gop.found_existing) gop.value_ptr.* = try std.array_list.Managed(usize).initCapacity(alloc, 0);
    try gop.value_ptr.append(idx);
}
```

```zig title="Sort + dedup last-wins (excerpt)"
std.sort.block(types.Point, all.items, {}, struct {
    fn lessThan(_: void, a: types.Point, b: types.Point) bool {
        return a.ts < b.ts;
    }
}.lessThan);

var dedup = try alloc.alloc(types.Point, all.items.len);
defer alloc.free(dedup);

var n: usize = 0;
var i: usize = 0;
while (i < all.items.len) : (i += 1) {
    const p = all.items[i];
    if (n == 0 or dedup[n - 1].ts != p.ts) {
        dedup[n] = p;
        n += 1;
    } else {
        dedup[n - 1] = p; // last wins
    }
}
const slice = dedup[0..n];
```

```zig title="Manifest rewrite-in-memory + append new entry (excerpt)"
// Rebuild manifest without old entries
var keep = std.ArrayListUnmanaged(manifest_mod.Entry){};
defer keep.deinit(alloc);
for (manifest.entries.items) |me| {
    if (me.series_id == sid and me.hour_bucket == hour) {
        alloc.free(me.path); // avoid leak
        continue;
    }
    try keep.append(alloc, me);
}
manifest.entries.deinit(manifest.alloc);
manifest.entries = keep;

// Add new consolidated entry (MANIFEST file is still append-only)
const cnt: u32 = @intCast(slice.len);
try manifest.add(data_dir, sid, hour, slice[0].ts, slice[slice.len - 1].ts, cnt, new_path);
```
