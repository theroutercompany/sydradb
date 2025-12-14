---
sidebar_position: 0
title: Storage pipeline overview (src/sydra/storage)
---

# Storage pipeline overview (`src/sydra/storage/*`)

This directory contains the primitives that make SydraDB durable on disk and queryable:

- Durable ingest via the WAL
- Persisted point storage in segment files
- A manifest that indexes segment files and their time ranges
- Optional background maintenance (retention + compaction)
- A small tag index for lookup surfaces

Most “orchestration” (when these run, and in what order) lives in `src/sydra/engine.zig`. The files here implement the storage building blocks.

## Module map

- `wal.zig` – append-only WAL + replay (`wal/current.wal`, rotation at ~64 MiB)
- `segment.zig` – segment file writer/reader + `queryRange` over a manifest selection
- `manifest.zig` – in-memory entries + append-only on-disk `MANIFEST` (NDJSON)
- `tags.zig` – best-effort tag index persisted as `tags.json`
- `retention.zig` – TTL-based segment deletion using `entry.end_ts`
- `compact.zig` – compaction stub (merge + de-duplicate by timestamp; “last wins”)
- `memtable.zig` – placeholder for a future dedicated memtable implementation
- `object_store.zig` – Git-inspired content-addressed store (BLAKE3) used by the object/commit model

## Typical flows

### Ingest (durable)

1. Engine appends `(series_id, ts, value)` to the WAL.
2. Engine buffers the point in the in-memory memtable.
3. On flush, the engine writes one segment per `(series_id, hour_bucket)` and appends entries to the manifest.

See: `src/sydra/engine.zig` (writer loop + flush path).

### Range query

1. Engine selects relevant manifest entries for the `series_id`.
2. Segment query scans those segment files and appends matching points.

See: `segment.zig` → `queryRange`.

### Maintenance

- **Retention** deletes old segment files and prunes the in-memory manifest.
- **Compaction** merges multiple segments within an hour bucket into a consolidated segment.

## Related docs

- User-facing format notes: [On-Disk Format v0 (Draft)](../../../on-disk-format)
- Engine orchestration: `src/sydra/engine.zig`

## Code excerpt (range query selection)

`segment.queryRange` walks the manifest and only opens segment files that overlap the requested `(series_id, start_ts, end_ts)`:

```zig title="src/sydra/storage/segment.zig (queryRange excerpt)"
pub fn queryRange(
    alloc: std.mem.Allocator,
    data_dir: std.fs.Dir,
    manifest: *manifest_mod.Manifest,
    series_id: types.SeriesId,
    start_ts: i64,
    end_ts: i64,
    out: *std.array_list.Managed(types.Point),
) !void {
    for (manifest.entries.items) |e| {
        if (e.series_id != series_id) continue;
        if (e.end_ts < start_ts or e.start_ts > end_ts) continue;

        var f = try data_dir.openFile(e.path, .{});
        defer f.close();

        // ... decode segment header + payload and append matching points to `out`
    }
}
```
