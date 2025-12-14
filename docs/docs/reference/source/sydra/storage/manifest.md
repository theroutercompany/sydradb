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

### `pub fn add(self, data_dir, sid, hour, start_ts, end_ts, count, path) !void`

- Appends a JSON line to the `MANIFEST` file.
- Appends a corresponding `Entry` to the in-memory `entries` list (duplicating `path`).

### `pub fn maxEndTs(self: *const Manifest, sid: SeriesId) ?i64`

Returns the maximum `end_ts` for a given series id, or `null` if no entries exist.

### `pub fn deinit(self: *Manifest) void`

Frees all owned `Entry.path` allocations and deinitializes the entries list.

