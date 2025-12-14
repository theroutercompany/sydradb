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

